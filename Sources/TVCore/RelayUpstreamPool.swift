import Foundation
import Network

/// 收回来的上游连接池：**同一个目标的下一次请求不必再握一次手**。
///
/// ## 这个池子存在的唯一理由
///
/// HLS 一片一个请求。中继原来对每片都新建 TCP + TLS 到节点，
/// 真机实测只有 140–190 KB/s —— 其中很大一块不是带宽，是每片一次握手。
/// 复用之后，第一条请求付握手，后面的只付一次往返。
///
/// ## 为什么键里要塞这么多东西
///
/// 同一条连接一旦复用，就带着它**建立时的全部属性**：走的哪台代理、拨的哪个地址、
/// 有没有占着端口段里的源端口。这些属性决定 Loon 会把它判成代理还是直连 ——
/// 键里少一个，就可能把「代理腿的连接」拿去跑「直连腿的请求」，
/// 症状是出口选择莫名其妙地反了，而且只在有缓存命中时出现。
///
/// ## 保守到极致的几条规矩
///
/// 1. 只收「响应体长度可判定」的连接（见 `RelayBodyFraming`）；
/// 2. 目标回了 `Connection: close` 就不收；
/// 3. 取出时再验一次 `state == .ready`，不 ready 直接丢掉；
/// 4. 空闲超过 `ttl` 一律关掉（节点那边可能已经掐了）；
/// 5. 池子满了丢最老的（`cap` 条，够覆盖 20 个小窗的几条主力 CDN）。
///
/// 任何一条不满足，行为就退回改动前（一条请求一条连接）—— 慢一点，但一定对。
public final class RelayUpstreamPool: @unchecked Sendable {
    public static let shared = RelayUpstreamPool()

    /// 总开关。真机上万一出现「复用后画面坏了」，关掉它就能退回逐条连接。
    public static var enabled: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: key) == nil { return true }
            return defaults.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static let key = "relayKeepAlive"

    /// 空闲连接最多留几条。
    public static let cap = 8
    /// 空闲多久算失效。
    public static let ttl: TimeInterval = 20

    public struct Entry {
        public let connection: NWConnection
        public let sourcePort: UInt16?
        let addedAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// 诊断计数：命中了多少次、放回来多少次、因为不合格丢了多少次。
    nonisolated(unsafe) private static var hits = 0
    nonisolated(unsafe) private static var returns = 0
    nonisolated(unsafe) private static var discards = 0
    private static let statsLock = NSLock()

    public init() {}

    /// 键：**决定这条连接走哪条路的一切**。
    public static func key(proxyID: String?, dialHost: String?, scheme: String, host: String, port: UInt16) -> String {
        [proxyID ?? "direct", dialHost ?? "-", scheme.lowercased(), host.lowercased(), String(port)]
            .joined(separator: "|")
    }

    /// 取一条可用的空闲连接；没有返回 nil（调用方照常拨号）。
    public func take(key: String) -> Entry? {
        let now = Date()
        var stale: [Entry] = []
        let found: Entry? = lock.withLock {
            guard let entry = entries.removeValue(forKey: key) else { return nil }
            if now.timeIntervalSince(entry.addedAt) > Self.ttl || entry.connection.state != .ready {
                stale.append(entry)
                return nil
            }
            return entry
        }
        for entry in stale {
            entry.connection.cancel()
            if let port = entry.sourcePort { SRCPortPool.shared.release(port) }
            Self.note(.discard)
        }
        if found != nil { Self.note(.hit) }
        return found
    }

    /// 把一条用完的连接放回来。调用方**不能再碰它**（包括 cancel）。
    ///
    /// 连接在池子里挂掉（节点掐了 / 对端 closed）时由这里负责清理与归还源端口。
    public func put(key: String, connection: NWConnection, sourcePort: UInt16?) {
        // 空闲期掉线必须由池子收尾：否则源端口永远回不到 `SRCPortPool`，
        // 415xx 那一段用完之后新的代理连接就没有「能让 Loon 认出来」的端口了。
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                guard let self else { return }
                let removed: Entry? = self.lock.withLock { self.entries.removeValue(forKey: key) }
                if let removed { if let port = removed.sourcePort { SRCPortPool.shared.release(port) } }
            case .waiting:
                // 节点那边暂时不收：不要留着它占位。
                guard let self else { return }
                let removed: Entry? = self.lock.withLock { self.entries.removeValue(forKey: key) }
                if let removed {
                    removed.connection.cancel()
                    if let port = removed.sourcePort { SRCPortPool.shared.release(port) }
                }
            default:
                break
            }
        }
        var evicted: [Entry] = []
        lock.withLock {
            entries[key] = Entry(connection: connection, sourcePort: sourcePort, addedAt: Date())
            while entries.count > Self.cap {
                guard let oldest = entries.min(by: { $0.value.addedAt < $1.value.addedAt })?.key else { break }
                if let entry = entries.removeValue(forKey: oldest) { evicted.append(entry) }
            }
        }
        for entry in evicted {
            entry.connection.cancel()
            if let port = entry.sourcePort { SRCPortPool.shared.release(port) }
        }
        Self.note(.put)
    }

    /// 清空（换节点、删代理、进后台时用）。
    public func drain() {
        let all: [Entry] = lock.withLock {
            let values = Array(entries.values)
            entries.removeAll()
            return values
        }
        for entry in all {
            entry.connection.cancel()
            if let port = entry.sourcePort { SRCPortPool.shared.release(port) }
        }
    }

    /// 现在池子里有几条空闲连接（诊断用）。
    public var count: Int { lock.withLock { entries.count } }

    // MARK: 统计

    private enum Note { case hit, put, discard }

    private static func note(_ note: Note) {
        statsLock.lock()
        switch note {
        case .hit: hits += 1
        case .put: returns += 1
        case .discard: discards += 1
        }
        let (h, r, d) = (hits, returns, discards)
        statsLock.unlock()
        // 每 20 次记一行，别把日志刷爆。
        if (h + r + d) % 20 == 0 {
            Diagnostics.shared.record(.debug, "proxy",
                "upstream pool hits=\(h) returns=\(r) discards=\(d)")
        }
    }
}
