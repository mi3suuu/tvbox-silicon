import Foundation
import Observation

/// Per-line (per `Episode.flag`) settings, one level finer than `SourceRouting`/`CustomProxyRouter`:
/// a single line can be forced direct or through a custom proxy even when its source is on another
/// route, and a line can be hidden from the picker (with a small button to bring it back).
///
/// Keyed like `PinnedSources` / `HiddenSources` so choices survive re-imports and merges, and sync
/// through iCloud alongside the other source-level settings.
/// The per-line setting value: a forced route and whether the line is hidden.
public struct LineSetting: Codable, Hashable, Sendable {
    /// A forced route for this line, or nil to follow the source's route.
    public var route: CustomProxyRoute?
    /// Whether this line is hidden from the picker and search. Hidden lines stay listed in the
    /// subscription's full detail, so a small button can restore them.
    public var hidden: Bool = false
    public init(route: CustomProxyRoute? = nil, hidden: Bool = false) {
        self.route = route; self.hidden = hidden
    }
}

@MainActor @Observable public final class LineSettings: KeyedPersistedStore<LineSetting> {
    /// Backwards-compatible name for the per-line setting value.
    public typealias Setting = LineSetting

    /// The instance the app reads.
    ///
    /// Assignable so a Store built on its own defaults (QA's isolated data, tests) can point every
    /// reader at the same suite. `PlaybackSession` and the source editor have no `Store` to ask, and
    /// reading `.shared` there while the app wrote through `playbackDefaults` meant a line route set
    /// in one place was invisible in the other.
    @MainActor public static var shared = LineSettings()

    private static let baseKey = "lineSettings.v1"
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
            .flatMap { try? JSONDecoder().decode([String: LineSetting].self, from: $0) } ?? [:]
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
        // 同 `SourceOverrides`：先读原 key，环境确定后由 `reloadForEnvironment()` 换成该环境那份。
        let values = defaults.data(forKey: Self.baseKey)
            .flatMap { try? JSONDecoder().decode([String: Setting].self, from: $0) } ?? [:]
        super.init(defaults: defaults, storageKey: Self.baseKey, values: values)
    }

    private func key(origin: URL, sourceKey: String, flag: String) -> String {
        EpisodeSkipSettings.scope(origin: origin, source: sourceKey, video: flag)
    }

    public func setting(origin: URL, sourceKey: String, flag: String) -> Setting? {
        values[key(origin: origin, sourceKey: sourceKey, flag: flag)]
    }

    /// The forced route for a line, or nil when it follows its source.
    public func route(origin: URL, sourceKey: String, flag: String) -> CustomProxyRoute? {
        values[key(origin: origin, sourceKey: sourceKey, flag: flag)]?.route
    }

    /// Whether a line is hidden from the picker.
    public func isHidden(origin: URL, sourceKey: String, flag: String) -> Bool {
        values[key(origin: origin, sourceKey: sourceKey, flag: flag)]?.hidden ?? false
    }

    public func setRoute(_ route: CustomProxyRoute?, origin: URL, sourceKey: String, flag: String) {
        mutate(origin: origin, sourceKey: sourceKey, flag: flag) { $0.route = route }
    }

    public func setHidden(_ hidden: Bool, origin: URL, sourceKey: String, flag: String) {
        mutate(origin: origin, sourceKey: sourceKey, flag: flag) { $0.hidden = hidden }
    }

    /// Toggles hiding, returning the new state for the button's label.
    @discardableResult
    public func toggleHidden(origin: URL, sourceKey: String, flag: String) -> Bool {
        let k = key(origin: origin, sourceKey: sourceKey, flag: flag)
        var current = values[k] ?? Setting()
        current.hidden.toggle()
        values[k] = current
        persist()
        return current.hidden
    }

    /// All flags hidden for a source, so a bulk "hide every dead line" can be offered.
    public func hiddenFlags(origin: URL, sourceKey: String) -> Set<String> {
        var found = Set<String>()
        for (k, v) in values where v.hidden {
            if let flag = flag(in: k, origin: origin, sourceKey: sourceKey) { found.insert(flag) }
        }
        return found
    }

    /// Restores every hidden line of a source at once.
    public func restoreAll(origin: URL, sourceKey: String) {
        for (k, var v) in values where v.hidden && flag(in: k, origin: origin, sourceKey: sourceKey) != nil {
            v.hidden = false
            values[k] = v
        }
        persist()
    }

    /// Extracts the flag from a stored key when it belongs to `origin`/`sourceKey`. The key is the
    /// JSON array `["origin","source","flag"]` produced by `EpisodeSkipSettings.scope`, so the flag is
    /// the last decoded element rather than a `|`-separated tail.
    private func flag(in key: String, origin: URL, sourceKey: String) -> String? {
        guard let parts = try? JSONDecoder().decode([String].self, from: Data(key.utf8)),
              parts.count == 3, parts[0] == origin.absoluteString, parts[1] == sourceKey else { return nil }
        return parts[2]
    }

    private func mutate(origin: URL, sourceKey: String, flag: String, _ change: (inout Setting) -> Void) {
        let k = key(origin: origin, sourceKey: sourceKey, flag: flag)
        var current = values[k] ?? Setting()
        change(&current)
        if current.route == nil && !current.hidden { values.removeValue(forKey: k) } else { values[k] = current }
        persist()
    }
}
