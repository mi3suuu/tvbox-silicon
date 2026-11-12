import Foundation
import Observation

/// Sub-sources the viewer **deleted**, as opposed to merely hid.
///
/// Why this is a second list and not a flag on `HiddenSources`:
///
/// - The sources page has a "Hidden Sources" section with an unhide button. Deleting and hiding
///   both drop a source from the list, so one list cannot tell the section which is which — a
///   deleted source reappeared there under the name "hidden", which reads as the delete having
///   silently failed.
/// - Deletion has to survive a subscription refresh. `subscription.sites` is a read-only snapshot
///   parsed from the feed, so removing from it locally is undone by the next rebuild. Keying by
///   `origin|sourceKey` (exactly like `HiddenSources`) survives that.
///
/// So a delete writes both lists: this one marks it as deleted (keeps it out of the hidden
/// section), `HiddenSources` does the actual list filtering that every reader already consults.
///
/// Partitioned by storage key per environment for the same reason as `HiddenSources`: the same
/// subscription has identical `origin + sourceKey` in every environment, so a shared list would
/// delete a source in environments the viewer never touched.
@MainActor @Observable public final class DeletedSources {
    private var keys: [String]
    /// Bumps when the list changes, so cached source rows rebuild.
    public private(set) var revision = 0
    private let defaults: UserDefaults
    /// Called after the list changes here (not after `adopt`), for iCloud sync.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    private static let baseKey = "deletedSources.v1"
    /// The environment whose deletions `keys` holds. The default environment keeps the bare key so
    /// an upgrade keeps everything deleted before environments existed.
    public var environmentID: UUID?
    public var defaultEnvironmentID: UUID?
    private var storageKey: String {
        EnvironmentScopedKey.key(Self.baseKey, environment: environmentID, default: defaultEnvironmentID)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keys = defaults.stringArray(forKey: Self.baseKey) ?? []
    }

    /// Re-reads the list for whatever environment is now current.
    public func reloadForEnvironment() {
        let next = defaults.stringArray(forKey: storageKey) ?? []
        guard next != keys else { return }
        keys = next
        revision += 1
    }

    /// Drops the deletions a deleted environment owned, so the key does not outlive its environment.
    public static func delete(environment: UUID, defaults: UserDefaults = .standard, default defaultID: UUID?) {
        guard let defaultID, environment != defaultID else { return }
        defaults.removeObject(forKey: EnvironmentScopedKey.key(baseKey, environment: environment, default: defaultID))
    }

    /// Same key scheme as `HiddenSources` / `PinnedSources` — a hostless `origin` would make two
    /// subscriptions' same-keyed sources collide, and `EpisodeSkipSettings.scope` already solved it.
    private func key(_ site: Site, origin: URL) -> String {
        EpisodeSkipSettings.scope(origin: site.origin(or: origin), source: site.sourceKey, video: "")
    }

    public func contains(_ site: Site, origin: URL) -> Bool { keys.contains(key(site, origin: origin)) }

    public func insert(_ site: Site, origin: URL) {
        let key = key(site, origin: origin)
        guard !keys.contains(key) else { return }
        keys.append(key)
        defaults.set(keys, forKey: storageKey)
        revision += 1
        onChange?()
    }

    /// Forgets every deletion that belongs to `origin`.
    ///
    /// Called when a subscription is removed. Without it the keys outlive the feed: re-adding the
    /// same subscription address later restores sources that are still marked deleted, so they stay
    /// invisible and the re-add looks half-broken.
    ///
    /// ⛔ The key is `EpisodeSkipSettings.scope(...)`, which returns a **JSON array**
    /// (`["<url>","<source>","<video>"]`), not a delimiter-joined string. So the match is done by
    /// decoding the first element back into a URL and comparing it, rather than by string prefix —
    /// a `hasPrefix` on the raw JSON would also match `["https://a.com.evil/...`.
    public func forget(origin: URL) { forget(origins: [origin]) }

    /// Same, for several addresses at once.
    ///
    /// ⛔ **必须按集合匹配，不能只传一个地址。** 键里存的是 `site.origin(or:)`，
    /// 也就是 `provenance?.origin ?? 订阅地址` —— 发生重定向 / 镜像 / http→https 时，
    /// 它与用户在「添加订阅」里输入的 `entry.address` **不是一回事**。
    /// 只传地址会漏掉这类订阅的真删记账，后果是「删掉订阅再重新加回来，
    /// 那批源永远不出现，而且没有任何入口能救」。
    /// 本项目已为同一对键写过两次映射（`SourceGroups.addressOfOrigin`、
    /// `SourceReassignment` 的 address/origin 双字段），这是第三次。
    public func forget(origins: [URL]) {
        let targets = Set(origins.map(\.absoluteString))
        guard !targets.isEmpty else { return }
        let kept = keys.filter { key in
            guard let data = key.data(using: .utf8),
                  let parts = try? JSONDecoder().decode([String].self, from: data),
                  let first = parts.first else { return true }
            return !targets.contains(first)
        }
        guard kept != keys else { return }
        keys = kept
        defaults.set(keys, forKey: storageKey)
        revision += 1
        onChange?()
    }

    /// Drops keys whose subscription (`origin`) is no longer present.
    ///
    /// Without this the list only ever grows:删掉一个订阅、重建、再加一个新的，
    /// 旧订阅那批键会永久留着。它们本身无害（键永不命中），但会跟着 iCloud 同步
    /// 与整机备份无限膨胀，且 `forget` 一旦漏掉某条路径就再也无从发现。
    ///
    /// `live` 是「当前所有订阅的地址集合」—— 注意键里存的是 `site.origin(or:)`，
    /// 而这里给的是 `entry.address`，所以两边都算一遍（同 `forget(origins:)` 的取舍）。
    public func prune(live: Set<String>) {
        guard !live.isEmpty else { return }
        let kept = keys.filter { key in
            guard let data = key.data(using: .utf8),
                  let parts = try? JSONDecoder().decode([String].self, from: data),
                  let first = parts.first else { return true }
            return live.contains(first)
        }
        guard kept.count != keys.count else { return }
        keys = kept
        defaults.set(keys, forKey: storageKey)
        revision += 1
        onChange?()
    }

    /// The saved keys, in order, as iCloud sync compares them.
    public var savedKeys: [String] { keys }

    /// The list merged with other devices'.
    public func adopt(_ keys: [String]) {
        guard keys != self.keys else { return }
        self.keys = keys
        defaults.set(keys, forKey: storageKey)
        revision += 1
    }
}
