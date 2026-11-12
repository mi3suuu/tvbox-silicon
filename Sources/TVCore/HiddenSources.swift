import Foundation
import Observation

/// Subscription-qualified hides. The same key scheme as `PinnedSources`.
@MainActor @Observable public final class HiddenSources {
    private var keys: [String]
    /// Bumps when a source is hidden or shown, so a cached source row can be reused until then.
    public private(set) var revision = 0
    private let defaults: UserDefaults
    /// Called after the list changes here (not after `adopt`), for iCloud sync.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    private static let baseKey = "hiddenSources.v1"
    private static let builtInRestoreBaseKey = "hiddenSources.builtInRestore.v1"
    private static let autoRestoreBaseKey = "hiddenSources.autoRestore.v1"
    /// 这两个是「一次性迁移是否已经做过」的标记，守的是**每个环境自己那份 `keys`**，
    /// 所以必须跟着 keys 一起分环境。共用一个全局标记的话：A 环境启动时把它烧掉，
    /// 切到 B 环境后 `restoreBuiltIns` / `restoreAutoHidden` 直接 return，
    /// B 里被 1.7.13 自动隐藏的那批源就永远恢复不了 —— 表现是「新环境少了一批源」。
    private var builtInRestoreKey: String {
        EnvironmentScopedKey.key(Self.builtInRestoreBaseKey, environment: environmentID, default: defaultEnvironmentID)
    }
    private var autoRestoreKey: String {
        EnvironmentScopedKey.key(Self.autoRestoreBaseKey, environment: environmentID, default: defaultEnvironmentID)
    }
    /// The environment whose hides `keys` holds. Hides are a preference with no record to stamp, so
    /// they are partitioned by storage key; the default environment keeps the bare key so an upgrade
    /// keeps everything the viewer hid before environments existed.
    public var environmentID: UUID?
    public var defaultEnvironmentID: UUID?
    private var storageKey: String {
        EnvironmentScopedKey.key(Self.baseKey, environment: environmentID, default: defaultEnvironmentID)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keys = defaults.stringArray(forKey: Self.baseKey) ?? []
    }

    /// Re-reads the list for whatever environment is now current, so a switch does not leave the
    /// previous environment's hides in force.
    public func reloadForEnvironment() {
        let next = defaults.stringArray(forKey: storageKey) ?? []
        guard next != keys else { return }
        keys = next
        revision += 1
    }

    /// Drops the hides a deleted environment owned, so the key does not outlive its environment.
    public static func delete(environment: UUID, defaults: UserDefaults = .standard, default defaultID: UUID?) {
        guard let defaultID, environment != defaultID else { return }
        defaults.removeObject(forKey: EnvironmentScopedKey.key(baseKey, environment: environment, default: defaultID))
    }

    private func key(_ site: Site, origin: URL) -> String {
        EpisodeSkipSettings.scope(origin: site.origin(or: origin), source: site.sourceKey, video: "")
    }

    public func contains(_ site: Site, origin: URL) -> Bool { keys.contains(key(site, origin: origin)) }

    public func toggle(_ site: Site, origin: URL) {
        let key = key(site, origin: origin)
        if keys.contains(key) { keys.removeAll { $0 == key } } else { keys.append(key) }
        defaults.set(keys, forKey: storageKey)
        revision += 1
        onChange?()
    }

    public func insert(_ site: Site, origin: URL) {
        let key = key(site, origin: origin)
        guard !keys.contains(key) else { return }
        keys.append(key)
        defaults.set(keys, forKey: storageKey)
        revision += 1
        onChange?()
    }

    /// Hides or shows many sources in one change: one save, one revision, one sync.
    public func setHidden(_ sites: [Site], origin: URL, hidden: Bool) {
        let changed = Set(sites.map { key($0, origin: origin) })
        var next = keys
        if hidden {
            for site in sites {
                let key = key(site, origin: origin)
                if !next.contains(key) { next.append(key) }
            }
        } else {
            next.removeAll { changed.contains($0) }
        }
        guard next != keys else { return }
        keys = next
        defaults.set(keys, forKey: storageKey)
        revision += 1
        onChange?()
    }

    /// Forgets every hide that belongs to one of `origins`.
    ///
    /// Called when a subscription goes away: its hides must go with it, or re-adding the same
    /// address later brings sources back in the **hidden** state — the viewer reads that as
    /// "the re-import lost half my sources". `DeletedSources.forget(origins:)` is the twin.
    ///
    /// ⛔ Match by decoding the JSON array `EpisodeSkipSettings.scope(...)` produces and comparing
    /// its first element. A `hasPrefix` on the raw JSON would also match `["https://a.com.evil/…`.
    public func forget(origins: [URL]) {
        let targets = Set(origins.map(\.absoluteString))
        guard !targets.isEmpty, !keys.isEmpty else { return }
        let kept = keys.filter { key in
            guard let data = key.data(using: .utf8),
                  let parts = try? JSONDecoder().decode([String].self, from: data),
                  let first = parts.first else { return true }
            return !targets.contains(first)
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

    /// Built-in sources used to be hidden automatically like any other, so once, every hidden
    /// built-in shows again. One the viewer hides afterwards stays hidden.
    public func restoreBuiltIns(_ sites: [Site], origin: URL) {
        guard !defaults.bool(forKey: builtInRestoreKey), !sites.isEmpty else { return }
        let restored = Set(sites.filter(\.isBuiltIn).map { key($0, origin: origin) })
        if keys.contains(where: restored.contains) {
            keys.removeAll { restored.contains($0) }
            defaults.set(keys, forKey: storageKey)
            revision += 1
            onChange?()
        }
        defaults.set(true, forKey: builtInRestoreKey)
    }

    /// 1.7.13 hid a source automatically once it went red, in the same list as the viewer's own hides,
    /// and nothing brought it back. Failing sources are now only paused in search (`SourceHealth.paused`),
    /// so once, every hidden source that failed repeatedly shows again. One hidden while it worked was
    /// the viewer's choice and stays hidden. An empty list waits for the real subscription.
    public func restoreAutoHidden(_ sites: [Site], origin: URL, health: SourceHealth) {
        guard !defaults.bool(forKey: autoRestoreKey), !sites.isEmpty else { return }
        let restored = Set(sites.filter { health.failedRepeatedly($0, origin: origin) }.map { key($0, origin: origin) })
        if keys.contains(where: restored.contains) {
            keys.removeAll { restored.contains($0) }
            defaults.set(keys, forKey: storageKey)
            revision += 1
            onChange?()
        }
        defaults.set(true, forKey: autoRestoreKey)
    }
}
