import Foundation
import Observation

/// Local edits to a subscription sub-source: a new display name, or a replacement API address.
/// These override what the subscription file says, without rewriting the file, so the viewer's
/// changes survive a refresh. Keyed like `PinnedSources` / `HiddenSources` / `BlockedSources`.
///
/// Removal is `BlockedSources`'s job: a sub-source the viewer removes is blocked, which drops it
/// from every list and search. Keeping a separate `removed` flag here duplicated that and left
/// dead code, so this type only carries the two edits that have no other home.
/// The per-sub-source edit value: an optional display name and an optional replacement API address.
public struct SourceOverride: Codable, Hashable, Sendable {
    public var name: String?
    public var api: String?
    public init(name: String? = nil, api: String? = nil) {
        self.name = name; self.api = api
    }
}

@MainActor @Observable public final class SourceOverrides: KeyedPersistedStore<SourceOverride> {
    /// Backwards-compatible name for the per-sub-source edit value.
    public typealias Override = SourceOverride

    /// The instance the app reads.
    ///
    /// Assignable so a Store built on its own defaults (QA's isolated data, tests) can point every
    /// reader at the same suite. `PlaybackSession` and the source editor have no `Store` to ask, and
    /// reading `.shared` there while the app wrote through `playbackDefaults` meant a line route set
    /// in one place was invisible in the other.
    @MainActor public static var shared = SourceOverrides()

    private static let baseKey = "sourceOverrides.v1"
    /// 该环境下的 key。源改名 / 改 API、线路开关、源路由都是**偏好**，没有记录可打戳，
    /// 只能按 storage key 分环境（口径同 `PinnedSources`）：默认环境保留原 key，升级不丢旧偏好。
    /// 不分环境时，A 环境里把某源改名成「我的源」、或把某条线路设为代理/隐藏，切到 B 环境
    /// 照样生效 —— 同一份订阅在两个环境下 `origin + sourceKey` 完全一致，必中。
    public var environmentID: UUID?
    public var defaultEnvironmentID: UUID?
    private var scopedKey: String {
        EnvironmentScopedKey.key(Self.baseKey, environment: environmentID, default: defaultEnvironmentID)
    }

    /// 切环境后按新 key 重读，否则内存里仍是上一个环境那一份。
    public func reloadForEnvironment() {
        let next = defaults.data(forKey: scopedKey)
            .flatMap { try? JSONDecoder().decode([String: SourceOverride].self, from: $0) } ?? [:]
        guard next != values else { return }
        values = next
        bump(notify: false)
    }

    /// 写入**当前环境**那个 key。
    ///
    /// 父类 `KeyedPersistedStore.write()` 写的是构造时传入的 `storageKey`（这里给的是 baseKey，
    /// 因为 init 时还不知道当前环境）。不覆写的话就成了「读 scoped、写裸 key」：在非默认环境里
    /// 改名/改 API 会落进默认环境的 key，再 reload 时改动凭空消失 —— 正是「切环境后残留」的镜像。
    /// 三兄弟里 `SourceRouting` 从一开始就覆写了，这两个漏了。
    public override func write() {
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: scopedKey) }
    }

    /// 删环境时清掉它名下的偏好 key。
    public static func delete(environment: UUID, defaults: UserDefaults = .standard, default defaultID: UUID?) {
        guard let defaultID, environment != defaultID else { return }
        defaults.removeObject(forKey: EnvironmentScopedKey.key(baseKey, environment: environment, default: defaultID))
    }

    public init(defaults: UserDefaults = .standard) {
        // 先按原 key 读（此刻还不知道当前环境）；`applyEnvironment` 会写好 environmentID
        // 再调 `reloadForEnvironment()` 换成该环境那一份。默认环境本来就用原 key，所以这一步
        // 对默认环境就是最终结果。
        let overrides = defaults.data(forKey: Self.baseKey)
            .flatMap { try? JSONDecoder().decode([String: Override].self, from: $0) } ?? [:]
        super.init(defaults: defaults, storageKey: Self.baseKey, values: overrides)
    }

    private func key(_ site: Site, origin: URL) -> String {
        EpisodeSkipSettings.scope(origin: site.origin(or: origin), source: site.sourceKey, video: "")
    }

    public func override(for site: Site, origin: URL) -> Override? { values[key(site, origin: origin)] }

    public func rename(_ site: Site, origin: URL, to name: String) {
        let key = key(site, origin: origin)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var value = values[key] ?? Override()
        value.name = trimmed.isEmpty ? nil : trimmed
        if value.name == nil && value.api == nil { values.removeValue(forKey: key) } else { values[key] = value }
        persist(); bump()
    }

    public func setAPI(_ site: Site, origin: URL, to api: String) {
        let key = key(site, origin: origin)
        let trimmed = api.trimmingCharacters(in: .whitespacesAndNewlines)
        var value = values[key] ?? Override()
        value.api = trimmed.isEmpty ? nil : trimmed
        if value.name == nil && value.api == nil { values.removeValue(forKey: key) } else { values[key] = value }
        persist(); bump()
    }

    /// A copy of `site` with the viewer's name and address edits applied.
    public func apply(to site: Site, origin: URL) -> Site {
        guard let value = override(for: site, origin: origin) else { return site }
        return Site(key: site.key,
                    name: value.name ?? site.name,
                    type: site.type,
                    api: value.api ?? site.api,
                    raw: site.raw,
                    provenance: site.provenance,
                    detectedRuntime: site.detectedRuntime)
    }

    public var savedKeys: [String] { values.keys.sorted() }
    public override func adopt(_ synced: [String: Override]) {
        guard synced != values else { return }
        values = synced
        persist(); bump(notify: false)
    }

    /// This store persists without notifying; callers bump `revision` and fire `onChange` themselves.
    public override func persist(notify: Bool = true) {
        write()
    }
}
