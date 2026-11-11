import Foundation
import TVCore

/// Filing many sources at once.
///
/// Every one of these ends in `reassignSource`, the same call a drag onto another group's header
/// makes, so a batch is exactly a drag repeated — nothing here is a second way to store a move. That
/// matters for the safety net: "Put Every Source Back" on the Moved Sources page undoes a batch as
/// readily as it undoes a drag, and a subscription refresh cannot lose either.
extension Store {

    /// The sources this group shows, in the order the page shows them.
    func sources(inGroup id: String, includeHidden: Bool = false) -> [Site] {
        sourceGroups(includeHidden: includeHidden).first { $0.id == id }?.sites ?? []
    }

    /// Adds a group, or hands back the one that already has that name.
    @discardableResult
    func createSourceGroup(named name: String) -> CustomSourceGroup? {
        sourceGroupBook.add(name: name)
    }

    /// Files `sites` under one of the viewer's groups.
    ///
    /// One rebuild for the whole batch, not one per source: `reassignSource` reclassifies the merged
    /// list, and doing that 300 times to move 300 cards is why a batch this size was not attempted.
    @discardableResult
    func fileSources(_ sites: [Site], intoGroup id: String) -> Int {
        guard let group = sourceGroupBook.group(id) else { return 0 }
        var touched = 0
        performBatch {
            // Built-in sources belong to no subscription and `reassignSource` refuses them; counting
            // them would make the report say "12 filed" over a group holding 11.
            for site in sites where !site.isBuiltIn {
                reassignSource(site, to: group.target)
                touched += 1
            }
        }
        return touched
    }

    /// Files `sites` under another subscription — the batch form of dragging them onto its header.
    @discardableResult
    func fileSources(_ sites: [Site], underSubscription address: String) -> Int {
        var touched = 0
        performBatch {
            for site in sites where !site.isBuiltIn {
                reassignSource(site, to: address)
                touched += 1
            }
        }
        return touched
    }

    /// Reorders the viewer's own groups — a group's title dropped onto another's on the Sources page.
    /// Subscriptions keep their own order (`moveSourceGroup`); pinned and built-in groups keep theirs,
    /// because "pinned first" is the promise that makes pinning worth doing.
    func moveCustomGroup(_ id: String, onto target: String) {
        sourceGroupBook.move(id, onto: target)
    }

    /// Steps a group one place up or down: the same reorder without a drag.
    func moveCustomGroup(_ id: String, by offset: Int) {
        sourceGroupBook.move(id, by: offset)
    }

    /// Whether a group can step up or down, so a menu does not offer a move that does nothing.
    func canMoveCustomGroup(_ id: String, by offset: Int) -> Bool {
        let groups = sourceGroupBook.groups
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        return groups.indices.contains(index + offset)
    }

    /// Sends `sites` back to the subscription they came from — the move is deleted, not rewritten.
    @discardableResult
    func returnSourcesToTheirSubscription(_ sites: [Site]) -> Int {
        var touched = 0
        performBatch {
            for site in sites where !site.isBuiltIn {
                reassignSource(site, to: nil)
                touched += 1
            }
        }
        return touched
    }

    // MARK: - Acting on a sweep

    /// Sets one route for many sources at once: the batch behind "everything that answered goes
    /// direct, everything that did not goes through the relay".
    ///
    /// The two halves are deliberately one call rather than two menu items: a half-applied rule is
    /// the state that leaves a source both routed wrongly and unmentioned, and the runner needs to
    /// report how many it touched.
    @discardableResult
    func setRoute(_ route: SourceRoute, for sites: [Site]) -> Int {
        guard let config = subscription else { return 0 }
        var touched = 0
        // Wrapped so `routeByReachability`'s two calls rebuild once at the end, not twice. The outer
        // `performBatch` in that function owns the rebuild; a batch that leaves the list stale would
        // be worse than a redundant one, so a direct per-source call still rebuilds.
        performBatch {
            for site in sites {
                sourceRouting.set(route, for: site, origin: site.origin(or: config.origin))
                touched += 1
            }
        }
        return touched
    }

    /// The sources among `sites` whose last reading says they answered. Unmeasured sources are not
    /// here: a source with no reading is not "reachable", it is unknown, and routing it as if it had
    /// answered would bake a guess into a setting the reader will not think to revisit.
    ///
    /// Written as an explicit case list rather than `!= .unreachable`. That comparison read a missing
    /// reading as "answered" too — `nil != .unreachable` is true — so this function disagreed with its
    /// own paragraph above, and every caller that subtracted the three buckets saw `unknown == 0`
    /// for ever. A `.unknown` reading is excluded for the same reason: the sweep reached the source
    /// but could not say how it performs, which is not a yes.
    func answered(_ sites: [Site]) -> [Site] {
        let probes = SourceProbeStore.shared
        return sites.filter {
            switch probes.latest(sourceKey: $0.sourceKey)?.reachability {
            case .reachable, .slow: true
            case .unreachable, .unknown, nil: false
            }
        }
    }

    /// The ones whose last reading says they did not.
    func silent(_ sites: [Site]) -> [Site] {
        let probes = SourceProbeStore.shared
        return sites.filter { probes.latest(sourceKey: $0.sourceKey)?.reachability == .unreachable }
    }

    /// The ones nothing has been measured for yet.
    func unmeasured(_ sites: [Site]) -> [Site] {
        let probes = SourceProbeStore.shared
        return sites.filter { probes.latest(sourceKey: $0.sourceKey) == nil }
    }

    /// Both halves of "reachable direct, unreachable through the relay", in one call.
    /// Returns how many each half touched, so the page can report what it did.
    @discardableResult
    func routeByReachability(_ sites: [Site]) -> (direct: Int, relay: Int, unknown: Int) {
        // The three counts come from the same list, and "unknown" is counted rather than subtracted:
        // a raw `sites.count` minus two deduplicated halves could report a negative number.
        let up = answered(sites), down = silent(sites)
        let neither = sites.filter { site in
            !up.contains { $0.id == site.id } && !down.contains { $0.id == site.id }
        }
        // One rebuild for both halves, not one per half.
        var direct = 0, relay = 0
        performBatch {
            if !up.isEmpty { direct = setRoute(.direct, for: up) }
            if !down.isEmpty { relay = setRoute(.proxy, for: down) }
        }
        return (direct, relay, neither.count)
    }

    /// Writes down what the sweep found: the sources that answered go under `reachableName`, the ones
    /// that did not under `unreachableName`, each group created when it is missing.
    ///
    /// Sources with no reading are left where they are. Filing an unmeasured source as dead would be a
    /// guess, and the one thing worse than a slow source is a working one hidden in "不通".
    @discardableResult
    func fileByReachability(_ sites: [Site], reachableName: String, unreachableName: String) -> (reachable: Int, unreachable: Int) {
        // One implementation, not two: the numbered-group rule and the batch rebuild both live in
        // the `into:silent:` form, and a second copy here would drift the first time either changed.
        let result = fileByReachability(sites, into: reachableName, silentGroup: unreachableName)
        return (reachable: result.answered, unreachable: result.silent)
    }
}

// MARK: - 批量动作（多选 / 指定订阅 / 测速结果）

/// Every batch entry point below funnels into two calls: `reassignSource` (a move, identical to
/// dropping one card on a header) and `hiddenSources.setHidden` (a hide, identical to the menu item).
/// Nothing here is a second way to store a move, so "Put Every Source Back" on the Moved Sources page
/// undoes a batch as readily as it undoes a drag, and a subscription refresh cannot lose either.
///
/// Rebuilding is deferred. `reassignSource` calls `rebuildSubscription()` on every source, which
/// reclassifies the whole merged list — doing that 300 times to move 300 sources is why a batch of
/// this size was not attempted before. `performBatch` runs the writes with rebuilding switched off
/// and rebuilds once at the end.
extension Store {

    /// Runs `body` with the per-source rebuild suppressed, then rebuilds once.
    ///
    /// `withoutRebuild` is the only knob: it does not change what is stored, only how often the merged
    /// list is rebuilt, so a batch ends in exactly the state the same moves made one at a time would.
    func performBatch(_ body: () -> Void) {
        let previous = suppressRebuild
        suppressRebuild = true
        defer {
            suppressRebuild = previous
            if !previous { rebuildSubscription() }
        }
        body()
    }

    /// The `SourceReassignment` target a page-supplied identifier means.
    ///
    /// A page hands over what it naturally has: `CustomSourceGroup.id` for one of the viewer's own
    /// groups, a subscription's address for a feed, and the empty string for "back where it came
    /// from". Only the first is *not* already a move target — a custom group is stored in moves as
    /// `group:<id>` (`CustomSourceGroup.target`), and `SourceGroups.make` files a source by comparing
    /// that target. Passing the bare id through would have every moved source land in "Other Sources"
    /// while the page reported success, so the conversion happens here, once, instead of at each of
    /// the three call sites that would each have to remember.
    ///
    /// Returns nil for the empty string, which `reassignSource(_:to: nil)` reads as "its own
    /// subscription".
    static func moveTarget(named id: String, groups: SourceGroupBook) -> String? {
        guard !id.isEmpty else { return nil }
        if let group = groups.group(id) { return group.target }
        // Already a target (a custom group's `target`, or a subscription address): unchanged.
        return id
    }

    /// Files `sites` under a group id (`SourceGroup.id`), which may name a subscription, one of the
    /// viewer's own groups, or `nil` to send them back where they came from.
    ///
    /// Ids come from the page, so this accepts all three forms: `group:<id>` for a custom group, a
    /// subscription's address, and the empty string for "back to its own subscription".
    @discardableResult
    func fileSources(_ sites: [Site], intoGroupTarget target: String?) -> Int {
        guard let target else { return 0 }
        // An empty target means "back to its own subscription", which is `reassignSource(_:to:)` with
        // nil — the drop onto "Other Sources".
        let destination = Self.moveTarget(named: target, groups: sourceGroupBook)
        var touched = 0
        performBatch {
            for site in sites where !site.isBuiltIn {
                reassignSource(site, to: destination)
                touched += 1
            }
        }
        return touched
    }

    /// Files one source under a target the page supplies — the group-aware form of
    /// `reassignSourceByKey`, for the drag that lands on one of the viewer's own groups.
    ///
    /// The page has the group's `id`, not its move target; converting here keeps a drop and a menu
    /// pick the same move. Without it a card dragged onto a custom group's header disappeared into
    /// "Other Sources" — the drop said it worked, and the group it was dropped on stayed empty.
    func reassignSourceByKey(_ key: String, origin: String, groupID: String) {
        guard let config = subscription,
              let site = config.sites.first(where: {
                  $0.sourceKey == key && $0.origin(or: config.origin).absoluteString == origin
              }) else { return }
        reassignSource(site, to: Self.moveTarget(named: groupID, groups: sourceGroupBook))
    }

    /// Hides or shows many sources at once. One write for the whole list: `setHidden` already takes
    /// a list, and calling it per source would bump the revision — and redraw every reader — once per card.
    ///
    /// Counts only what actually changed. `HiddenSources.setHidden` is a no-op when nothing moves,
    /// and reporting `sites.count` there would have the page say "hid 12" over a list it did not touch
    /// — the same lie the built-in-source case used to tell.
    @discardableResult
    func setHidden(_ hidden: Bool, for sites: [Site]) -> Int {
        guard let config = subscription, !sites.isEmpty else { return 0 }
        let before = hiddenSources.revision
        hiddenSources.setHidden(sites, origin: config.origin, hidden: hidden)
        guard hiddenSources.revision != before else { return 0 }
        return sites.filter { hiddenSources.contains($0, origin: config.origin) == hidden }.count
    }

    /// Pins or unpins many sources at once, counting only the ones that changed.
    @discardableResult
    func setPinned(_ pinned: Bool, for sites: [Site]) -> Int {
        guard let config = subscription, !sites.isEmpty else { return 0 }
        let before = pinnedSources.revision
        pinnedSources.setPinned(sites, origin: config.origin, pinned: pinned)
        guard pinnedSources.revision != before else { return 0 }
        return sites.filter { pinnedSources.contains($0, origin: config.origin) == pinned }.count
    }

    // MARK: - 按测速结果批量归档（任意源集合）

    /// Files everything among `sites` that answered into one group, and everything silent into
    /// another, creating either group when it is missing.
    ///
    /// `fileByReachability` already did this for the whole library. This is the same rule for a
    /// subset — one subscription, one group, or the cards the reader ticked — because "these twelve
    /// answer and those nine do not" is a decision about the twenty-one in front of them, not about
    /// all 300. Sources with no reading are left alone in both halves; filing an unmeasured source as
    /// dead is a guess, and a working source hidden inside "不通" is worse than a slow one.
    ///
    /// When a group of that name already exists the batch is *filed into it* rather than a second
    /// group being made: "measure this subscription, then file what answered" repeated later in the
    /// day should add to the same place, not grow a shelf of "Reachable 2, Reachable 3". Making a
    /// genuinely new group is `New Group…` in the batch bar, where the reader asked for one.
    ///
    /// The name is looked up in both the current language and the language the group was made in,
    /// because a group's *identity* is its name here. A reader who switches the interface language
    /// between two sweeps would otherwise get a second "可连接" beside the older "Reachable" — two
    /// groups, each holding half of what they meant as one. Callers pass the localised name plus the
    /// names already used for this purpose, so a match in any of them wins.
    @discardableResult
    func fileByReachability(_ sites: [Site],
                            into answeredGroup: String,
                            silentGroup: String,
                            alsoMatching answeredAliases: [String] = [],
                            silentAliases: [String] = []) -> (answered: Int, silent: Int, unknown: Int) {
        let probes = SourceProbeStore.shared
        var up: [Site] = [], down: [Site] = [], unknown: [Site] = []
        var seen = Set<String>()
        for site in sites where seen.insert(site.id).inserted {
            guard let reading = probes.latest(sourceKey: site.sourceKey) else { unknown.append(site); continue }
            // A reading of `.unknown` is not a verdict: the sweep reached the source but could not
            // say how it performs. Filing that under "answered" would put a source in the good group
            // on the strength of a non-answer, so it goes with the unmeasured ones.
            switch reading.reachability {
            case .reachable, .slow: up.append(site)
            case .unreachable: down.append(site)
            case .unknown: unknown.append(site)
            }
        }
        var result = (answered: 0, silent: 0, unknown: unknown.count)
        performBatch {
            // Any group already carrying one of the names wins, so a language switch between two
            // sweeps does not split one group into two.
            if !up.isEmpty, let group = existingGroup(named: answeredGroup, orAnyOf: answeredAliases)
                ?? sourceGroupBook.add(name: answeredGroup) {
                result.answered = fileSources(up, intoGroup: group.id)
            }
            if !down.isEmpty, let group = existingGroup(named: silentGroup, orAnyOf: silentAliases)
                ?? sourceGroupBook.add(name: silentGroup) {
                result.silent = fileSources(down, intoGroup: group.id)
            }
        }
        return result
    }

    /// The group already used for this purpose: under the current name, or under any name it had
    /// when it was made. A language switch is the case this exists for.
    private func existingGroup(named name: String, orAnyOf aliases: [String]) -> CustomSourceGroup? {
        if let match = sourceGroupBook.group(named: name) { return match }
        for alias in aliases {
            if let match = sourceGroupBook.group(named: alias) { return match }
        }
        return nil
    }

    // MARK: - 订阅内选源

    /// Every source that came from one subscription, before any move — the list a "this subscription"
    /// scope needs. A source the viewer filed elsewhere is still this subscription's to measure: the
    /// move changes which section lists it, not which feed it resolves against.
    func sources(inSubscription address: String, includeHidden: Bool = false) -> [Site] {
        sourceGroups(includeHidden: includeHidden)
            .filter { group in
                if case .subscription(let own) = group.kind { return own == address }
                return false
            }
            .flatMap(\.sites)
    }
}


// MARK: - 一轮扫描之后的自动整理

/// 测速结束之后自动做什么。
///
/// 从前这三件事是三个独立的手动步骤：测速 → 手动点「按结果分组」→ 手动点「按得分排序」→
/// 想改路由还得再点一次。而它们其实是同一个决定的四个面：**这一批源里，哪些还能用、该怎么摆。**
/// 分开做的时候，用户得记着自己还没点哪一步；忘一步，列表就停在半整理的状态。
///
/// 默认只开「排序」：它不是破坏性的（不移动源、不建组、不改地址），而另外两项都会改变用户
/// 亲手整理过的东西。默认开一个会动他分组的开关，是替他做决定。
public struct PostSweepTidy: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// 按测速得分重排搜索顺序。幂等、不移动源所属分组。
    public static let reorder = PostSweepTidy(rawValue: 1 << 0)
    /// 把「能连的」和「连不上的」分进两个组。会移动源。
    public static let fileByResult = PostSweepTidy(rawValue: 1 << 1)
    /// 能连的走直连、连不上的走代理。会改源地址的取值方式。
    public static let routeByResult = PostSweepTidy(rawValue: 1 << 2)

    /// 默认：只重排。见类型注释。
    public static let standard: PostSweepTidy = [.reorder]
}

extension Store {
    /// 一轮扫描结束后的整理。`tidy` 为空则什么也不做（用户全部关掉时的合法状态）。
    ///
    /// 顺序是有意的：先分组、再路由、最后排序。排序读的是「这批源现在长什么样」，
    /// 排在移动之后能反映移动的结果；而分组与路由互不影响，谁先都一样。
    ///
    /// 分组**只碰它自己认得的那两类**：`fileByReachability` 只移动「有读数」的源，
    /// 没测过的原地不动 —— 所以手工整理过的分组不会被整体抹平，只会被「按结果重新归档」
    /// 的那些源改变。用户如果连这个也不想要，把 `fileByResult` 关掉即可。
    @discardableResult
    func tidyAfterSweep(_ sites: [Site], tidy: PostSweepTidy) -> String? {
        guard !tidy.isEmpty, !sites.isEmpty else { return nil }
        var said: [String] = []
        if tidy.contains(.fileByResult) {
            let result = fileByReachability(sites,
                                            into: L10n.text("Reachable"),
                                            silentGroup: L10n.text("Unreachable"),
                                            alsoMatching: L10n.everyRendering(of: "Reachable"),
                                            silentAliases: L10n.everyRendering(of: "Unreachable"))
            if result.answered + result.silent > 0 {
                said.append(L10n.text("Filed %lld answered and %lld silent.", result.answered, result.silent))
            }
        }
        if tidy.contains(.routeByResult) {
            let result = routeByReachability(sites)
            if result.direct + result.relay > 0 {
                said.append(L10n.text("%lld to Direct, %lld to Proxy, %lld left unmeasured.",
                                      result.direct, result.relay, result.unknown))
            }
        }
        if tidy.contains(.reorder) {
            reorderSourcesByProbeResult()
        }
        return said.isEmpty ? nil : said.joined(separator: " ")
    }
}
