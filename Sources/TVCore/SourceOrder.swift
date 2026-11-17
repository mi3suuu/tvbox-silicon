import Foundation
import Observation

/// The viewer's own source order. While it is on, it replaces the automatic one (`SourceStrategy`):
/// the Sources page lists sources in it, and search asks sources and lists their matches in it, top first.
/// Keys are subscription-qualified like `PinnedSources`, so the order survives re-imports.
///
/// A second list ranks *groups* (`preferredGroups`). Source order alone answers "which of these two
/// sources first", but the question that actually decides a search is "do I want this whole feed
/// before that one" — 300 sources dragged one by one is not a thing anyone does, while six groups
/// are. Group rank is applied first and the source list breaks ties inside a group, so arranging
/// groups re-ranks the page without discarding the per-source work.
@MainActor @Observable public final class SourceOrder {
    /// The environment whose order this is. The source order, the group ranking and the switch are
    /// preferences rather than records, so they are partitioned by storage key (`Environments.scopedKey`):
    /// the default environment keeps the bare keys, so an upgrade keeps everything already arranged,
    /// and each other environment reads its own. Left global, switching environments carried the
    /// previous one's order into the new one and re-sorted its sources.
    public var environmentID: UUID?
    public var defaultEnvironmentID: UUID?
    private var enabledKey: String { EnvironmentScopedKey.key(Self.enabledBaseKey, environment: environmentID, default: defaultEnvironmentID) }
    private var orderKey: String { EnvironmentScopedKey.key(Self.orderBaseKey, environment: environmentID, default: defaultEnvironmentID) }
    private var groupOrderScopedKey: String { EnvironmentScopedKey.key(Self.groupOrderKey, environment: environmentID, default: defaultEnvironmentID) }
    public var enabled: Bool {
        get { enabledStorage }
        set {
            guard newValue != enabledStorage else { return }
            enabledStorage = newValue
            defaults.set(newValue, forKey: enabledKey)
            revision += 1
            onChange?()
        }
    }
    private var enabledStorage: Bool
    private var keys: [String]
    /// Group ids in the viewer's priority order: a subscription address, `group:<id>`, `pinned`,
    /// `builtIn`. A source in a group this list does not name follows every source it does.
    private var preferredGroups: [String]
    /// Bumps when the saved order or its switch changes, so a cached source row can be reused until then.
    public private(set) var revision = 0
    private let defaults: UserDefaults
    /// Called after the list changes here (not after `adopt`), for iCloud sync.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 与 enabled / keys 同一口径：构造时环境尚未加载，`EnvironmentScopedKey.key` 会因
        // `defaultID == nil` 退回裸 key（默认环境），随后 `reloadForEnvironment` 再按实际环境重读。
        // 三处必须一起读裸 key，否则切环境后只有一项串台。
        enabledStorage = defaults.bool(forKey: Self.enabledBaseKey)
        keys = defaults.stringArray(forKey: Self.orderBaseKey) ?? []
        preferredGroups = defaults.stringArray(forKey: Self.groupOrderKey) ?? []
    }

    /// Re-reads the order, the group ranking and the switch for whatever environment is now current.
    /// Without it a switch left the previous environment's arrangement in memory, and `arrange` kept
    /// applying it to the new one's sources.
    public func reloadForEnvironment() {
        let nextEnabled = defaults.bool(forKey: enabledKey)
        let nextKeys = defaults.stringArray(forKey: orderKey) ?? []
        let nextGroups = defaults.stringArray(forKey: groupOrderScopedKey) ?? []
        guard nextEnabled != enabledStorage || nextKeys != keys || nextGroups != preferredGroups else { return }
        // The observed `enabled` must go through its own assignment without echoing a write back to
        // the key it just came from; suppressing the didSet is not possible here, so write the same
        // value back, which is a no-op for `persist`.
        enabledStorage = nextEnabled
        keys = nextKeys
        preferredGroups = nextGroups
        revision += 1
    }

    /// Forgets everything a deleted environment arranged. The sources themselves are untouched:
    /// they live on their subscriptions.
    public static func delete(environment: UUID, defaults: UserDefaults = .standard, default defaultID: UUID?) {
        guard let defaultID, environment != defaultID else { return }
        for base in [enabledBaseKey, orderBaseKey, groupOrderKey] {
            defaults.removeObject(forKey: EnvironmentScopedKey.key(base, environment: environment, default: defaultID))
        }
    }

    private static let enabledBaseKey = "sourceOrder.enabled"
    private static let orderBaseKey = "sourceOrder.v1"
    /// Nothing arranged yet: `arrange` keeps the order it is given.
    public var isEmpty: Bool { keys.isEmpty }
    private static let groupOrderKey = "sourceOrder.groups.v1"
    private func key(_ site: Site, origin: URL) -> String { EpisodeSkipSettings.scope(origin: site.origin(or: origin), source: site.sourceKey, video: "") }

    /// `sites` in the saved order; sources it has not seen yet (a new subscription's) follow, in the order given.
    public func arrange(_ sites: [Site], origin: URL) -> [Site] {
        let rank = Dictionary(keys.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return sites.enumerated().sorted {
            let lhs = rank[key($0.element, origin: origin)] ?? Int.max
            let rhs = rank[key($1.element, origin: origin)] ?? Int.max
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
    }

    /// Each group's sources in the saved order, so moving a source on the Sources page moves it inside its group.
    ///
    /// The groups keep the order they are given: their place on the page is theirs to set (dragging a
    /// header, `Store.moveSourceGroup`), while `preferredGroups` ranks them for *search*. Two orders
    /// on purpose — a reader who wants a feed searched first has not thereby asked for its section to
    /// jump to the top of the page.
    public func arrange(_ groups: [SourceGroup], origin: URL) -> [SourceGroup] {
        groups.map { group in
            var group = group
            group.sites = arrange(group.sites, origin: origin)
            return group
        }
    }

    /// `sites` ordered by their group's rank first, then by the viewer's own source order inside it.
    ///
    /// Search asks sources in one flat list, so it needs the group dimension without the grouping:
    /// `group` names each source's group id (`SourceGroup.id`). Sources in a group the viewer never
    /// ranked follow every group that was, and keep the order they came in — ranking six feeds must
    /// not scramble the sections nobody touched.
    public func arrange(_ sites: [Site], origin: URL, group: (Site) -> String) -> [Site] {
        guard !preferredGroups.isEmpty else {
            // No group ranking: the source order alone, or the order given — and only while its
            // switch is on. A saved list from before the switch was turned off must not keep
            // re-sorting the page.
            return enabled ? arrange(sites, origin: origin) : sites
        }
        // The hand order breaks ties inside a group **only while its switch is on**. Reading `keys`
        // unconditionally would mean a viewer who turned the custom order off still got the sources
        // inside each group in that old hand order, which is the exact thing the switch promised to
        // stop. Groups are ranked by the group list, which has no switch of its own.
        let sourceRank = enabled
            ? Dictionary(keys.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
            : [:]
        let groupRank = Dictionary(preferredGroups.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return sites.enumerated().sorted { lhs, rhs in
            let left = groupRank[group(lhs.element)] ?? Int.max
            let right = groupRank[group(rhs.element)] ?? Int.max
            if left != right { return left < right }
            let a = sourceRank[key(lhs.element, origin: origin)] ?? Int.max
            let b = sourceRank[key(rhs.element, origin: origin)] ?? Int.max
            return a == b ? lhs.offset < rhs.offset : a < b
        }.map(\.element)
    }

    // MARK: - Group priority

    /// The group ids the viewer ranked, first to last.
    public var savedGroupOrder: [String] { preferredGroups }

    /// Whether any group has been ranked yet; a page can hide an empty reorder control with it.
    public var hasGroupOrder: Bool { !preferredGroups.isEmpty }

    /// Saves the ranking. Groups not among `ids` lose their place: they follow, as given.
    public func saveGroupOrder(_ ids: [String]) {
        guard ids != preferredGroups else { return }
        preferredGroups = ids
        defaults.set(ids, forKey: groupOrderScopedKey)
        revision += 1
        onChange?()
    }

    /// Drops ids that no longer name a group — a deleted group, a removed subscription — so a stale
    /// entry cannot push a real group down the list forever.
    public func pruneGroupOrder(keeping known: Set<String>) {
        let next = preferredGroups.filter { known.contains($0) }
        guard next != preferredGroups else { return }
        preferredGroups = next
        defaults.set(next, forKey: groupOrderScopedKey)
        revision += 1
        onChange?()
    }

    /// The ranking after `id` steps `offset` places (negative = earlier). Clamped, and a no-op at the ends.
    public func moveGroup(_ id: String, by offset: Int, among known: [String]) {
        // Always work on the full list, never on the ranked subset: with only the ranked ids in hand,
        // "move the last one down" is a no-op, because there is nothing below it in that list even
        // though the page has more groups. The ranking is a prefix of this list, not the list.
        var order = known.isEmpty ? preferredGroups : known
        if preferredGroups.isEmpty, let first = order.first, !preferredGroups.contains(first) {
            // A first press writes the page's order as the starting ranking — the order the reader
            // already sees, with one group moved in it.
        }
        if order.isEmpty { return }
        if !order.contains(id) {
            order = known.filter { order.contains($0) || $0 == id } + order.filter { !known.contains($0) }
        }
        guard let from = order.firstIndex(of: id) else { return }
        let to = max(0, min(order.count - 1, from + offset))
        guard to != from else { return }
        order.remove(at: from)
        order.insert(id, at: to)
        // Everything after the one that moved keeps its relative place; anything the caller knows
        // about but the list does not yet name is appended, so one step-up does not silently drop it.
        var next = order.filter { known.isEmpty || known.contains($0) }
        next += known.filter { !next.contains($0) }
        saveGroupOrder(next)
    }

    /// Saves `sites` as the order. Saved sources not among them (a subscription that is turned off)
    /// keep their places after them, so turning it back on doesn't lose its order.
    public func save(_ sites: [Site], origin: URL) {
        let ordered = sites.map { key($0, origin: origin) }, listed = Set(ordered)
        keys = ordered + keys.filter { !listed.contains($0) }
        defaults.set(keys, forKey: orderKey)
        revision += 1
        onChange?()
    }

    /// Keys saved under a subscription's old address, moved to its new one (#982).
    public func moveOrigin(from old: URL, to new: URL) {
        let next = EpisodeSkipSettings.rescope(keys, from: old, to: new)
        guard next != keys else { return }
        keys = next
        defaults.set(keys, forKey: "sourceOrder.v1")
        revision += 1
        onChange?()
    }

    /// The saved keys, in order, as iCloud sync compares them.
    public var savedKeys: [String] { keys }
    /// The list merged with other devices'.
    public func adopt(_ keys: [String]) {
        guard keys != self.keys else { return }
        self.keys = keys
        defaults.set(keys, forKey: orderKey)
        revision += 1
    }

    // MARK: - 按测速结果自动重排

    /// 测速之后把源重新排序：**得分高的排前面**，写入顺序键。
    ///
    /// ## 为什么要有这一步
    ///
    /// 探针一直在算 `SourceProbeResult.sortScore`（可达性 + 速度 + 延迟 + 分辨率 +
    /// 码率余量 + 色域 + 文件大小，满分 100+），但**没有任何一处把它写成顺序** ——
    /// 得分只用来显示颜色与单次择优，源的优先顺序永远停在用户手排或导入时的原样。
    /// 于是「测完速」对搜索与列表顺序毫无影响。
    ///
    /// ## 什么会被覆盖，什么不会
    ///
    /// 只有**测过**的源参与重排；没测过的源原地保留相对次序，排在测过的之后。
    /// 并且在 `pinned` 里钉住的源永远排最前 —— 用户明确钉过的意图高于任何测量结果。
    ///
    /// - Parameters:
    ///   - sites: 参与本次重排的源。
    ///   - origin: 订阅源地址（键要按 origin 归一，见 `key(_:origin:)`）。
    ///   - score: 从源键取分数的闭包；返回 nil 表示「没测过」，不参与比较。
    ///   - pinnedKeys: 已钉住的键，永远排最前。
    /// - Returns: 是否有任何顺序变化（调用方据此决定是否刷新界面）。
    /// 重排的**纯**核心：输入键与分数，输出新顺序。不碰 Site、不碰 UserDefaults，
    /// 所以排序规则可以被单测钉死（`Site` 是 Codable 解码构造，测试里造实例很别扭）。
    ///
    /// 三条优先级，顺序不可换：
    ///   1. `pinnedKeys` 里的永远最前，且它们之间保持原有次序；
    ///   2. 测过的按 `score` 降序，同分保持原有次序（否则每次测速都乱跳）；
    ///   3. 没测过的按原有次序垫后 —— 没测过 ≠ 坏，但也不该压过测过的。
    public static func probeOrder(_ keys: [String],
                                  existing: [String],
                                  score: (String) -> Int?,
                                  pinnedKeys: Set<String> = []) -> [String] {
        let existingRank = Dictionary(existing.enumerated().map { ($0.element, $0.offset) },
                                     uniquingKeysWith: min)
        var next: [String] = []
        var seen = Set<String>()

        let pinned = keys.filter { pinnedKeys.contains($0) }
            .sorted { (existingRank[$0] ?? Int.max) < (existingRank[$1] ?? Int.max) }
        for key in pinned where seen.insert(key).inserted { next.append(key) }

        let measured = keys.filter { !pinnedKeys.contains($0) && score($0) != nil }
            .sorted {
                let ls = score($0) ?? 0, rs = score($1) ?? 0
                if ls != rs { return ls > rs }
                return (existingRank[$0] ?? Int.max) < (existingRank[$1] ?? Int.max)
            }
        for key in measured where seen.insert(key).inserted { next.append(key) }

        let unmeasured = keys.filter { !seen.contains($0) }
            .sorted { (existingRank[$0] ?? Int.max) < (existingRank[$1] ?? Int.max) }
        for key in unmeasured where seen.insert(key).inserted { next.append(key) }

        return next
    }

    /// 按**键**重排（供测试与无 `Site` 的场景用）。与 `reorderByProbe(_ sites:...)` 同一实现，
    /// 只是跳过 `Site → key` 那一步 —— `Site` 是 Codable 解码构造，测试里造实例很别扭，
    /// 而排序规则的正确性必须能被单测钉住。
    @discardableResult
    public func reorderByProbe(keysForTesting probeKeys: [String],
                               score: (String) -> Int?,
                               pinnedKeys: Set<String> = []) -> Bool {
        applyProbeOrder(probeKeys, score: score, pinnedKeys: pinnedKeys)
    }

    /// 两者共用的实现：算出新顺序、与 `save` 同一条不变量合并、写盘。
    @discardableResult
    private func applyProbeOrder(_ probeKeys: [String],
                                 score: (String) -> Int?,
                                 pinnedKeys: Set<String>) -> Bool {
        // ⛔ 空输入必须早退：`probeOrder([], ...)` 返回空数组，
        //    继续往下会经下面的合并逻辑保留原有键（不会清空），但「什么都没测」时
        //    本来就不该触发一次写盘与云端同步。
        guard !probeKeys.isEmpty else { return false }

        let next = Self.probeOrder(probeKeys, existing: keys, score: score, pinnedKeys: pinnedKeys)

        // ⛔ 必须与 `save` 同一条不变量：**本次没列出的键要保留在尾部**。
        //
        // `probeOrder` 的输出只由入参键构成，而实际调用方传的是
        // `sourceGroups(includeHidden: false).filter { $0.kind != .hidden }` ——
        // 隐藏源、已关闭的订阅、保险库锁定的源**都不在里面**。
        // 直接 `keys = next` 整份覆盖，就会把这些源的顺序键**永久抹掉**，
        // 与 `save`（`keys = ordered + keys.filter { !listed.contains($0) }`）的承诺冲突。
        // （并行审查的子代理 A1 抓出这一条；旧测试因为 existing 恰好只含被测键而绕开。）
        let listed = Set(next)
        let written = next + keys.filter { !listed.contains($0) }
        guard written != keys else { return false }

        keys = written
        defaults.set(written, forKey: orderKey)
        revision += 1
        onChange?()
        return true
    }

    /// 按测速得分重排。**`score` 收的是 `Site`，不是键。**
    ///
    /// ⛔ 上一版的签名是 `score: (String) -> Int?`，而调用方 `Store.reorderSourcesByProbeResult`
    /// 传进来的键是 `key(_:origin:)` 生成的 **scope-JSON**（`["origin","sourceKey",""]`），
    /// 却拿去查以**裸 `sourceKey`** 为键的 `SourceProbeStore` —— 每一次查都返回 nil，
    /// `probeOrder` 于是把全部源归进 `unmeasured`、按原序返回。**「测速后自动排序」从上线起
    /// 是空操作，且无报错、无日志。** 测试也测不出：`reorderByProbe(keysForTesting:)` 用的是
    /// 调用方直接给的键，绕过了 `Site → key` 那一步。
    ///
    /// 收 `Site` 就没有这个问题：调用方不需要知道内部用什么键，也就不可能用错一套。
    @discardableResult
    public func reorderByProbe(_ sites: [Site],
                               origin: URL,
                               score: (Site) -> Int?,
                               pinnedKeys: Set<String> = []) -> Bool {
        // 内部仍然按键排序，但「键 → 得分」的对照建在这里，`score` 只面对 `Site`。
        // ⛔ 不要在这里往 `pinnedKeys` 里塞东西：钉住的判定是调用方的事（它才知道哪个源被钉住），
        // 混进来会把每个源都当成钉住的。
        var scoreByKey: [String: Int] = [:]
        var measured = Set<String>()
        for site in sites {
            let k = key(site, origin: origin)
            if let value = score(site) { scoreByKey[k] = value; measured.insert(k) }
        }
        return applyProbeOrder(sites.map { key($0, origin: origin) },
                               score: { measured.contains($0) ? scoreByKey[$0] : nil },
                               pinnedKeys: pinnedKeys)
    }
}
