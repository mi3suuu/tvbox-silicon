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

    private static let storageKey = "sourceOverrides.v1"

    public init(defaults: UserDefaults = .standard) {
        let overrides = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: Override].self, from: $0) } ?? [:]
        super.init(defaults: defaults, storageKey: Self.storageKey, values: overrides)
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
