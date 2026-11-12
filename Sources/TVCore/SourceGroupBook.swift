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

    /// The target a move carries when the viewer deliberately takes a source **out** of every group
    /// and every subscription — 「未分组」.
    ///
    /// Why a sentinel target rather than "no move at all": no move means "put it back where it came
    /// from", which is exactly what deleting a group does. The viewer needs one more state —
    /// "put it nowhere". Storing it as a move keeps it on the same rail as every other filing
    /// decision, so 「全部放回」 on the moved-sources page still undoes it, and it survives a
    /// subscription refresh like any other move.
    public static let ungroupedTarget = "ungrouped"

    /// Whether this target names the「未分组」bucket rather than a real subscription or group.
    public static func isUngrouped(_ target: String) -> Bool { target == ungroupedTarget }

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
    private static let baseKey = "sourceGroups.v1"
    /// The environment whose groups these are. Groups are a preference with no record to stamp, so
    /// they are partitioned by storage key: the default environment keeps the bare key, each other
    /// environment reads its own. Left global, the previous environment's groups kept appearing over
    /// this environment's sources page.
    public var environmentID: UUID?
    public var defaultEnvironmentID: UUID?
    private var storageKey: String {
        EnvironmentScopedKey.key(Self.baseKey, environment: environmentID, default: defaultEnvironmentID)
    }
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        groups = defaults.data(forKey: Self.baseKey)
            .flatMap { try? JSONDecoder().decode([CustomSourceGroup].self, from: $0) } ?? []
    }

    /// Re-reads the groups for whatever environment is now current.
    public func reloadForEnvironment() {
        let next = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([CustomSourceGroup].self, from: $0) } ?? []
        guard next != groups else { return }
        groups = next
        revision += 1
    }

    /// Forgets the groups a deleted environment made. Their sources are untouched: a move that
    /// named one of them now names nothing, so `SourceGroups.make` files those sources back under
    /// the subscription they came from — losing no source.
    public static func delete(environment: UUID, defaults: UserDefaults = .standard, default defaultID: UUID?) {
        guard let defaultID, environment != defaultID else { return }
        defaults.removeObject(forKey: EnvironmentScopedKey.key(baseKey, environment: environment, default: defaultID))
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

    /// The order after `id` is dropped onto `target`'s title: onto an earlier title it takes that
    /// place, onto a later one it lands just after it — the same rule the subscription headers use,
    /// so a drag means one thing on this page. The list is the display order; nothing else is stored.
    public static func moving(_ groups: [CustomSourceGroup], id: String, onto target: String) -> [CustomSourceGroup] {
        guard id != target,
              let from = groups.firstIndex(where: { $0.id == id }),
              let to = groups.firstIndex(where: { $0.id == target }) else { return groups }
        var next = groups
        let group = next.remove(at: from)
        // After the removal a later target sits at `to - 1`, so inserting at `to` lands after it.
        next.insert(group, at: to)
        return next
    }

    /// The order after `id` steps `offset` places up (negative) or down (positive). The drag in menu
    /// form, for a phone in one hand, a Mac without a trackpad, or VoiceOver.
    public static func moving(_ groups: [CustomSourceGroup], id: String, by offset: Int) -> [CustomSourceGroup] {
        guard let from = groups.firstIndex(where: { $0.id == id }) else { return groups }
        let to = from + offset
        guard to != from, groups.indices.contains(to) else { return groups }
        var next = groups
        let group = next.remove(at: from)
        next.insert(group, at: to)
        return next
    }

    /// Reorders the viewer's own groups. Membership is untouched: a group's place on the page is its
    /// place in this list, and a source's group is still the target of its move.
    public func move(_ id: String, onto target: String) {
        apply(Self.moving(groups, id: id, onto: target))
    }

    public func move(_ id: String, by offset: Int) {
        apply(Self.moving(groups, id: id, by: offset))
    }

    private func apply(_ next: [CustomSourceGroup]) {
        guard next != groups else { return }
        groups = next
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
        defaults.set(try? JSONEncoder().encode(groups), forKey: storageKey)
        revision += 1
        onChange?()
    }

    /// 另一台设备的分组，按名合并 —— 同步不能让两个组同名。
    ///
    /// `complete` 是「远端这一份就是全部」的意思，此时**本地多出来的会被删掉**。
    /// 不这样做，「删掉一个分组」在同步里永远不生效：远端列表里已经没有它了，
    /// 而只增不删的合并会把本地那条留着，下一轮 flush 又以更新的戳把它推回云端 ——
    /// 删除被永久复活，两台设备来回拉锯。传 false 的是「只带来一部分」的场景
    /// （比如早期只推送过新增），那时不能据此删本地。
    public func adopt(_ other: [CustomSourceGroup], complete: Bool = false) {
        var merged = groups
        var changed = false
        if complete {
            // 远端有、按名对得上的那条以远端为准（id 也跟着换，move 的 target 会跟着指到新 id）；
            // 远端没有的本地组删掉。
            let remoteNames = Set(other.map { $0.name.lowercased() })
            let kept = merged.filter { remoteNames.contains($0.name.lowercased()) }
            if kept.count != merged.count { changed = true }
            merged = kept
        }
        for group in other where !merged.contains(where: { $0.name.caseInsensitiveCompare(group.name) == .orderedSame }) {
            merged.append(group)
            changed = true
        }
        guard changed, merged != groups else { return }
        groups = merged
        save()
    }
}
