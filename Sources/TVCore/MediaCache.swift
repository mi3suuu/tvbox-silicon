import Foundation
import CryptoKit

/// Disposable data only. History, subscriptions, pins and skip settings never live here.
/// A ticket prevents a download started before deletion from recreating deleted data.
public final class MediaCache: @unchecked Sendable {
    public static let shared = MediaCache()
    public enum Kind: String, Codable, Sendable { case artwork, danmaku, lookup, catalog }
    public struct Ticket: Sendable { fileprivate let generation: UInt64 }
    public struct Summary: Sendable {
        public let bytes: Int
        public let artwork: Int
        public let danmaku: Int
        public let lookups: Int
        public let catalogs: Int
    }
    private struct Entry: Codable {
        let kind: Kind
        let scope: String
        let bytes: Int
        let expires: Date
        var used: Date
    }
    private let lock = NSLock()
    private let root: URL
    private let budget: Int
    private var entries: [String: Entry] = [:]
    private var generation: UInt64 = 0
    private var frequentScopes = Set<String>()
    /// When the index was last written to disk, for throttling `persist`. The index is disposable
    /// (the blob files are the source of truth), so collapsing rapid rewrites is safe: at worst a
    /// freshly-added entry is re-downloaded after a crash, never a broken cache.
    private var lastPersist: Date = .distantPast
    public func prioritize(_ scopes: Set<String>) { lock.withLock { frequentScopes = scopes } }
    public var revision: UInt64 { lock.withLock { generation } }

    public init(root: URL = URL.cachesDirectory.appending(path: "YingxiaMedia-v1"), budget: Int = 256 * 1024 * 1024) {
        self.root = root; self.budget = max(0, budget)
        if let data = try? Data(contentsOf: root.appending(path: "index.json")), data.count <= 4 * 1024 * 1024,
           let loaded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = loaded.filter { $0.key.count == 64 && $0.key.allSatisfy { $0.isHexDigit } && $0.value.bytes >= 0 }
        }
        let evicted = lock.withLock { let e = prune(now: Date()); persist(force: true); return e }
        deleteBlobs(evicted)
    }
    public func ticket() -> Ticket { lock.withLock { Ticket(generation: generation) } }
    private func id(_ key: String, _ kind: Kind, _ scope: String) -> String {
        let data = (try? JSONEncoder().encode([kind.rawValue, scope, key])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public func data(for key: String, kind: Kind, scope: String = "", now: Date = Date()) -> Data? {
        let key = id(key, kind, scope)
        let file = root.appending(path: key)
        // Snapshot the entry's metadata under the lock, then read its blob outside it: a poster grid
        // flings many reads at once, and none of them may hold the lock across its own disk I/O.
        let snapshot = lock.withLock { entries[key].map { ($0.bytes, $0.expires) } }
        guard let snapshot else { return nil }
        guard snapshot.1 > now, let data = try? Data(contentsOf: file), data.count == snapshot.0 else {
            // An expired, missing or truncated blob is forgotten: the dictionary under the lock, the file outside it.
            let removed = lock.withLock {
                let removed = entries.removeValue(forKey: key) != nil
                if removed { persist(force: true) }
                return removed
            }
            if removed { try? FileManager.default.removeItem(at: file) }
            return nil
        }
        lock.withLock {
            guard var entry = entries[key] else { return }
            let needsSave = now.timeIntervalSince(entry.used) > 60
            entry.used = now; entries[key] = entry
            if needsSave { persist() }
        }
        return data
    }
    @discardableResult public func store(_ data: Data, for key: String, kind: Kind, scope: String = "",
                                         ttl: TimeInterval, ticket: Ticket, now: Date = Date()) -> Bool {
        guard !data.isEmpty, data.count <= min(budget, 8 * 1024 * 1024), ttl > 0 else { return false }
        guard lock.withLock({ ticket.generation == generation }) else { return false }
        let key = id(key, kind, scope)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: root.appending(path: key), options: .atomic)
        } catch { return false } // Cache failures never prevent playback.
        // The blob is on disk; index it and evict what no longer fits under the lock, then delete the
        // evicted files outside it.
        let evicted = lock.withLock {
            entries[key] = Entry(kind: kind, scope: scope, bytes: data.count, expires: now.addingTimeInterval(ttl), used: now)
            let evicted = prune(now: now)
            persist(force: true)
            return evicted
        }
        deleteBlobs(evicted)
        return true
    }
    public func remove(scope: String) {
        let keys = lock.withLock {
            generation &+= 1
            let keys = entries.keys.filter({ entries[$0]?.scope == scope })
            for key in keys { entries[key] = nil }
            persist(force: true)
            return keys
        }
        deleteBlobs(keys)
    }
    /// Remove one category in a work's scope, invalidating downloads started before the deletion.
    public func remove(kind: Kind, scope: String) {
        lock.withLock {
            generation &+= 1
            for key in entries.keys.filter({ entries[$0]?.scope == scope && entries[$0]?.kind == kind }) { erase(key) }
            persist()
        }
    }
    public func remove(_ key: String, kind: Kind, scope: String = "") {
        let keys = lock.withLock {
            generation &+= 1
            let key = id(key, kind, scope)
            let removed = entries.removeValue(forKey: key) != nil
            persist(force: true)
            return removed ? [key] : []
        }
        deleteBlobs(keys)
    }
    public func clear() {
        lock.withLock {
            generation &+= 1; entries.removeAll()
        }
        try? FileManager.default.removeItem(at: root)
    }
    public func summary(now: Date = Date()) -> Summary {
        let evicted = lock.withLock { () -> [String] in
            let e = prune(now: now); persist(force: true); return e
        }
        deleteBlobs(evicted)
        return lock.withLock {
            Summary(bytes: entries.values.reduce(0) { $0 + $1.bytes }, artwork: entries.values.filter { $0.kind == .artwork }.count,
                    danmaku: entries.values.filter { $0.kind == .danmaku }.count, lookups: entries.values.filter { $0.kind == .lookup }.count,
                    catalogs: entries.values.filter { $0.kind == .catalog }.count)
        }
    }
    /// 上游 1.8.23 用 `erase` 做「立即删条目 + 删 blob」，本文件是我方版（用 `deleteBlobs` 批量删）。
    /// 合并后上游的 `remove(kind:scope:)` 调用点仍指向 `erase`，这里补上等价实现。
    private func erase(_ key: String) {
        entries[key] = nil
        try? FileManager.default.removeItem(at: root.appending(path: key))
    }

    private func deleteBlobs(_ keys: [String]) {
        for key in keys { try? FileManager.default.removeItem(at: root.appending(path: key)) }
    }
    /// Evicts expired, overflow and over-quota entries from the index, returning the blob keys to delete
    /// so the caller can remove the files outside the lock.
    private func prune(now: Date) -> [String] {
        var removed: [String] = []
        for key in entries.keys.filter({ entries[$0]!.expires <= now }) { entries[key] = nil; removed.append(key) }
        // Lookup scope is a work, not an episode. Retain only the last 20 successful work mappings.
        let lookups = entries.filter { $0.value.kind == .lookup }.sorted { $0.value.used > $1.value.used }
        for (key, _) in lookups.dropFirst(20) { entries[key] = nil; removed.append(key) }
        var size = entries.values.reduce(0) { $0 + $1.bytes }
        let evictionOrder = entries.sorted {
            let left = frequentScopes.contains($0.value.scope), right = frequentScopes.contains($1.value.scope)
            return left == right ? $0.value.used < $1.value.used : !left
        }
        for (key, entry) in evictionOrder where size > budget {
            size -= entry.bytes; entries[key] = nil; removed.append(key)
        }
        return removed
    }
    /// Writes the index.
    ///
    /// [mi3s] 二开修正：`force` 区分「结构变化」与「使用时间刷新」。
    /// 原实现无条件节流，导致 `store()` 写好 blob 后 1 秒内不再写索引 —— 同一进程里新实例
    /// （或崩溃后重启）读到的索引里没有这条记录，缓存明明在盘上却取不到（MediaCacheTests 实证）。
    /// 现在：新增/删除/初始化/prune 一律 `force: true`；只有 `data(for:)` 里刷新 `used` 才允许节流。
    private func persist(force: Bool = false) {
        // Collapse rapid rewrites of the *usage* timestamps (a grid fling reads many posters at once):
        // encoding the whole index and rewriting the file every time was a synchronous I/O spike.
        let now = Date()
        guard force || now.timeIntervalSince(lastPersist) >= 1.0 else { return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: root.appending(path: "index.json"), options: .atomic)
        lastPersist = now
    }
}
