import Foundation
import Observation

/// Subscription-qualified keys survive imports and cannot pin an unrelated site's reused key.
///
/// Pins are a *preference*, not a record, so there is no field to stamp with an environment the way
/// `SubscriptionEntry` does. They are partitioned by storage key instead (`Environments.scopedKey`):
/// the default environment keeps the bare key so an upgrade keeps every pin, and each other
/// environment reads and writes its own. Without this, switching environments left the previous
/// one's pins in force — pinned rows appeared under sources this environment never pinned.
@MainActor @Observable public final class PinnedSources {
    private static let baseKey = "pinnedSources.v1"
    private var keys: [String]
    /// Bumps when the pin list changes, so a cached source row can be reused until then.
    public private(set) var revision = 0
    private let defaults: UserDefaults
    /// Called after the list changes here (not after `adopt`), for iCloud sync.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    /// The environment whose pins `keys` holds. The app keeps this in step with
    /// `Environments.activeID`; nil means "not set yet", which reads the default environment.
    public var environmentID: UUID?
    /// The default environment's id, so a legacy bare key and an explicitly stamped default match.
    public var defaultEnvironmentID: UUID?
    private var storageKey: String {
        EnvironmentScopedKey.key(Self.baseKey, environment: environmentID, default: defaultEnvironmentID)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keys = defaults.stringArray(forKey: Self.baseKey) ?? []
    }

    /// Re-reads the list for whatever environment is now current. Called on a switch: without it the
    /// pins of the environment left behind stay in memory and keep matching.
    public func reloadForEnvironment() {
        let next = defaults.stringArray(forKey: storageKey) ?? []
        guard next != keys else { return }
        keys = next
        revision += 1
    }

    /// Drops the pins a deleted environment owned. Only that environment's key goes: the sources
    /// themselves live on the subscription and are untouched.
    public static func delete(environment: UUID, defaults: UserDefaults = .standard, default defaultID: UUID?) {
        guard let defaultID, environment != defaultID else { return }
        defaults.removeObject(forKey: EnvironmentScopedKey.key(baseKey, environment: environment, default: defaultID))
    }

    private func key(_ site: Site, origin: URL) -> String { EpisodeSkipSettings.scope(origin: site.origin(or: origin), source: site.sourceKey, video: "") }
    public func contains(_ site: Site, origin: URL) -> Bool { keys.contains(key(site, origin: origin)) }
    public var isEmpty: Bool { keys.isEmpty }
    public func toggle(_ site: Site, origin: URL) {
        let key = key(site, origin: origin)
        if keys.contains(key) { keys.removeAll { $0 == key } } else { keys.append(key) }
        defaults.set(keys, forKey: storageKey)
        revision += 1
        onChange?()
    }

    /// Pins or unpins many sources in one change: one save, one revision, one sync. A batch of 200
    /// cards pinned one at a time would bump `revision` 200 times, and every bump redraws the page.
    public func setPinned(_ sites: [Site], origin: URL, pinned: Bool) {
        var next = keys
        if pinned {
            for site in sites {
                let key = key(site, origin: origin)
                if !next.contains(key) { next.append(key) }
            }
        } else {
            let dropping = Set(sites.map { key($0, origin: origin) })
            next.removeAll { dropping.contains($0) }
        }
        guard next != keys else { return }
        keys = next
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
    public func arrange(_ sites: [Site], origin: URL) -> [Site] {
        let rank = Dictionary(keys.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return sites.enumerated().sorted {
            let lhs = rank[key($0.element, origin: origin)] ?? Int.max
            let rhs = rank[key($1.element, origin: origin)] ?? Int.max
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
    }
}
