import Foundation
import Observation

/// A group the viewer made up.
///
/// The source page's groups used to be facts about where a source came from: one per subscription,
/// plus the pinned and built-in ones. That is the right default — a feed arrives as a group — but it
/// left no way to say "these twelve answer, those thirty do not", which is the one thing a sweep
/// makes obvious and a viewer wants to keep.
///
/// Membership is deliberately not stored here. A source belongs to a group when its move
/// (`SourceReassignment`) targets `group:<id>`, so:
/// - renaming a group changes no source at all,
/// - deleting a group files its sources back where they came from, losing nothing,
/// - and the "put every source back" button on the Moved Sources page still undoes all of it.
public struct CustomSourceGroup: Codable, Identifiable, Hashable, Sendable {
    public static let targetPrefix = "group:"

    public var id: String
    public var name: String

    public init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }

    /// What a source's move points at while it is filed under this group.
    public var target: String { Self.targetPrefix + id }

    /// The group id a move target names, or nil when it names a subscription.
    public static func id(inTarget target: String) -> String? {
        guard target.hasPrefix(targetPrefix) else { return nil }
        return String(target.dropFirst(targetPrefix.count))
    }
}

/// The viewer's own groups, saved on this device.
@MainActor @Observable public final class SourceGroupBook {
    public private(set) var groups: [CustomSourceGroup] = []
    /// Bumps on every change, so pages that cache a source list know to rebuild it.
    public private(set) var revision = 0
    private let defaults: UserDefaults
    private static let storageKey = "sourceGroups.v1"
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        groups = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([CustomSourceGroup].self, from: $0) } ?? []
    }

    /// Adds a group, or returns the one that already has that name — a batch action that runs twice
    /// must not end up with two "可用" groups.
    @discardableResult
    public func add(name: String) -> CustomSourceGroup? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if let existing = group(named: clean) { return existing }
        let group = CustomSourceGroup(name: clean)
        groups.append(group)
        save()
        return group
    }

    public func rename(_ id: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = groups.firstIndex(where: { $0.id == id }), groups[index].name != clean else { return }
        groups[index].name = clean
        save()
    }

    /// Forgets the group. Its sources are not touched here: their moves now name a group that is
    /// gone, which `SourceGroups.make` files back under their own subscription.
    public func remove(_ id: String) {
        guard groups.contains(where: { $0.id == id }) else { return }
        groups.removeAll { $0.id == id }
        save()
    }

    public func group(_ id: String) -> CustomSourceGroup? { groups.first { $0.id == id } }

    public func group(named name: String) -> CustomSourceGroup? {
        groups.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The group a move target names, when it is one of ours.
    public func group(forTarget target: String) -> CustomSourceGroup? {
        CustomSourceGroup.id(inTarget: target).flatMap { self.group($0) }
    }

    public var isEmpty: Bool { groups.isEmpty }

    private func save() {
        defaults.set(try? JSONEncoder().encode(groups), forKey: Self.storageKey)
        revision += 1
        onChange?()
    }

    /// Another device's groups, merged by name: sync must not leave two groups with one title.
    public func adopt(_ other: [CustomSourceGroup]) {
        guard other != groups else { return }
        var merged = groups
        for group in other where !merged.contains(where: { $0.name.caseInsensitiveCompare(group.name) == .orderedSame }) {
            merged.append(group)
        }
        guard merged != groups else { return }
        groups = merged
        save()
    }
}
