import Foundation
import Observation

/// Common base for the source and line settings stores: a `[String: Value]` map persisted in
/// `UserDefaults`, with revision tracking, a change hook for iCloud sync, and the
/// `savedValues`/`adopt` pair `CloudSync` reads. The four concrete stores (`SourceRouting`,
/// `SourceOverrides`, `LineSettings`, `SourceReassignment`) share this plumbing and differ only in
/// their key scheme, their on-disk format, and how a merge from another device should notify.
@MainActor @Observable open class KeyedPersistedStore<Value: Codable & Equatable> {
    /// The in-memory map.
    var values: [String: Value]
    /// Bumps when a choice changes, so a cached source list can be reused until then.
    public private(set) var revision = 0
    /// The `UserDefaults` suite the map is persisted to.
    public let defaults: UserDefaults
    /// Called after the list changes here (not after `adopt`), for iCloud sync.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    /// When true, `adopt` also fires `onChange` and bumps `revision`. Defaults to false: a merge
    /// from another device should be silent, so it does not trigger a redundant sync write-back.
    public var notifyOnAdopt = false
    /// The `UserDefaults` key the map is persisted under.
    public let storageKey: String

    public init(defaults: UserDefaults = .standard, storageKey: String, values: [String: Value] = [:]) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.values = values
    }

    /// The saved map, as iCloud sync compares them.
    public var savedValues: [String: Value] { values }

    /// Merge in the map from another device. By default silent: writes the new map but neither bumps
    /// `revision` nor fires `onChange`, so a merge does not trigger a redundant sync write-back.
    public func adopt(_ synced: [String: Value]) {
        guard synced != values else { return }
        values = synced
        persist(notify: notifyOnAdopt)
    }

    /// Writes `values`, then (when `notify`) bumps `revision` and fires `onChange`.
    open func persist(notify: Bool = true) {
        write()
        if notify { bump(notify: true) }
    }

    /// The raw write half of `persist`: JSON-encodes `values` under `storageKey`. Override to store
    /// a different on-disk format (for example raw strings).
    open func write() {
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: storageKey) }
    }

    /// Bumps `revision`, and fires `onChange` when `notify`.
    public func bump(notify: Bool = true) {
        revision += 1
        if notify { onChange?() }
    }
}
