import Foundation
import Testing
@testable import TVCore

@Test @MainActor func sourceOrderPersistsAndKeepsSourcesItDoesNotList() throws {
    let suite = "order." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let origin = URL(string: "https://example.com/sub")!
    let config = try Subscription.parse(Data(#"{"sites":[{"key":"a","name":"A","type":1,"api":"https://example.com/a"},{"key":"b","name":"B","type":1,"api":"https://example.com/b"},{"key":"c","name":"C","type":1,"api":"https://example.com/c"},{"key":"d","name":"D","type":1,"api":"https://example.com/d"}]}"#.utf8), origin: origin)
    let sites = config.sites
    let order = SourceOrder(defaults: defaults)
    #expect(order.isEmpty && !order.enabled)
    #expect(order.arrange(sites, origin: origin).map(\.key) == ["a", "b", "c", "d"])
    order.save([sites[2], sites[0], sites[1]], origin: origin)
    order.enabled = true
    // "d" is new: it follows, in the order given.
    #expect(order.arrange(sites, origin: origin).map(\.key) == ["c", "a", "b", "d"])
    let reloaded = SourceOrder(defaults: defaults)
    #expect(reloaded.enabled)
    #expect(reloaded.arrange(sites, origin: origin).map(\.key) == ["c", "a", "b", "d"])
    // Saving only some sources (another subscription turned off) keeps the rest after them.
    reloaded.save([sites[1], sites[0]], origin: origin)
    #expect(reloaded.arrange(sites, origin: origin).map(\.key) == ["b", "a", "c", "d"])
    // Keys are subscription-qualified: another subscription's "a" is not this one's.
    #expect(reloaded.arrange(sites, origin: URL(string: "https://other.example/sub")!).map(\.key) == ["a", "b", "c", "d"])
}

@Test @MainActor func sourceOrderArrangesEachGroup() throws {
    let suite = "order." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let origin = URL(string: "https://example.com/sub")!
    let config = try Subscription.parse(Data(#"{"sites":[{"key":"a","name":"A","type":1,"api":"https://example.com/a"},{"key":"b","name":"B","type":1,"api":"https://example.com/b"},{"key":"c","name":"C","type":1,"api":"https://example.com/c"},{"key":"d","name":"D","type":1,"api":"https://example.com/d"}]}"#.utf8), origin: origin)
    let sites = config.sites
    let groups = [
        SourceGroup(kind: .pinned, title: "Pinned Group", sites: [sites[0], sites[1]]),
        SourceGroup(kind: .subscription("https://example.com/sub"), title: "Sub", sites: [sites[2], sites[3]]),
    ]
    let order = SourceOrder(defaults: defaults)
    // Moving "d" to the top of the whole order moves it to the top of its own group; groups keep their places.
    order.save([sites[3], sites[1], sites[0], sites[2]], origin: origin)
    let arranged = order.arrange(groups, origin: origin)
    #expect(arranged.map(\.id) == ["pinned", "https://example.com/sub"])
    #expect(arranged.map { $0.sites.map(\.key) } == [["b", "a"], ["d", "c"]])
}

@Test @MainActor func groupPriorityOrdersSourcesAndSurvivesARelaunch() throws {
    let suite = "order." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let origin = URL(string: "https://example.com/sub")!
    let config = try Subscription.parse(Data(#"{"sites":[{"key":"a","name":"A","type":1,"api":"https://example.com/a"},{"key":"b","name":"B","type":1,"api":"https://example.com/b"},{"key":"c","name":"C","type":1,"api":"https://example.com/c"}]}"#.utf8), origin: origin)
    let sites = config.sites
    // Every source declares which group it is listed in; the order ranks the groups, not the rows.
    let groups = ["a": "group:late", "b": "group:early", "c": "group:early"]
    let order = SourceOrder(defaults: defaults)
    #expect(!order.hasGroupOrder)
    // Nothing ranked: the order it was given, untouched.
    #expect(order.arrange(sites, origin: origin, group: { groups[$0.key]! }).map(\.key) == ["a", "b", "c"])
    order.saveGroupOrder(["group:early", "group:late"])
    #expect(order.hasGroupOrder)
    #expect(order.arrange(sites, origin: origin, group: { groups[$0.key]! }).map(\.key) == ["b", "c", "a"])
    // A group the viewer never ranked follows every ranked one, and keeps the order it came in.
    let more = ["a": "group:late", "b": "group:early", "c": "group:unranked"]
    #expect(order.arrange(sites, origin: origin, group: { more[$0.key]! }).map(\.key) == ["b", "a", "c"])
    // It survives a relaunch.
    let reloaded = SourceOrder(defaults: defaults)
    #expect(reloaded.savedGroupOrder == ["group:early", "group:late"])
}

@Test @MainActor func groupPriorityIsIndependentOfTheSourceSwitch() throws {
    let suite = "order." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let origin = URL(string: "https://example.com/sub")!
    let config = try Subscription.parse(Data(#"{"sites":[{"key":"a","name":"A","type":1,"api":"https://example.com/a"},{"key":"b","name":"B","type":1,"api":"https://example.com/b"}]}"#.utf8), origin: origin)
    let sites = config.sites
    let groups = ["a": "group:second", "b": "group:first"]
    let order = SourceOrder(defaults: defaults)
    // A hand order that says "a before b" is not a statement about groups: ranking the groups wins,
    // because the reader asked for that bucket first.
    order.save([sites[0], sites[1]], origin: origin)
    order.enabled = true
    #expect(order.arrange(sites, origin: origin).map(\.key) == ["a", "b"])
    order.saveGroupOrder(["group:first", "group:second"])
    #expect(order.arrange(sites, origin: origin, group: { groups[$0.key]! }).map(\.key) == ["b", "a"])
    // Rows inside a group still follow the hand order.
    let sameGroup = ["a": "group:one", "b": "group:one"]
    order.saveGroupOrder(["group:one"])
    #expect(order.arrange(sites, origin: origin, group: { sameGroup[$0.key]! }).map(\.key) == ["a", "b"])
}

@Test @MainActor func steppingAGroupTakesItsOwnTurn() throws {
    let suite = "order." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let order = SourceOrder(defaults: defaults)
    let all = ["pinned", "builtIn", "group:a", "group:b"]
    // Nothing ranked yet: a first step writes the page's order with one group moved in it.
    order.moveGroup("group:b", by: -1, among: all)
    #expect(order.savedGroupOrder == ["pinned", "builtIn", "group:b", "group:a"])
    // At the top, stepping up does nothing rather than rotating the list.
    order.moveGroup("pinned", by: -1, among: all)
    #expect(order.savedGroupOrder == ["pinned", "builtIn", "group:b", "group:a"])
    // A group the ranking does not name yet can still be stepped, and lands next to the ranked ones.
    order.moveGroup("group:a", by: 1, among: all)
    #expect(order.savedGroupOrder == ["pinned", "builtIn", "group:b", "group:a"])
}

@Test @MainActor func aDeletedGroupIsDroppedFromTheRanking() throws {
    let suite = "order." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let order = SourceOrder(defaults: defaults)
    order.saveGroupOrder(["group:a", "group:gone", "group:b"])
    // A stale id would hold a place in the ranking for ever: prune it against what still exists.
    order.pruneGroupOrder(keeping: ["group:a", "group:b"])
    #expect(order.savedGroupOrder == ["group:a", "group:b"])
}

@Test @MainActor func groupPriorityDoesNotResurrectATurnedOffSourceOrder() throws {
    let suite = "order." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let origin = URL(string: "https://example.com/sub")!
    let config = try Subscription.parse(Data(#"{"sites":[{"key":"a","name":"A","type":1,"api":"https://example.com/a"},{"key":"b","name":"B","type":1,"api":"https://example.com/b"}]}"#.utf8), origin: origin)
    let sites = config.sites
    let sameGroup = ["a": "group:one", "b": "group:one"]
    let order = SourceOrder(defaults: defaults)
    // A hand order that says "b before a", then the switch is turned off. Ranking that one group must
    // not bring the hand order back: off means off, for the rows inside a group too.
    order.save([sites[1], sites[0]], origin: origin)
    order.enabled = false
    order.saveGroupOrder(["group:one"])
    #expect(order.arrange(sites, origin: origin, group: { sameGroup[$0.key]! }).map(\.key) == ["a", "b"])
    // With no group ranking at all, the order given is returned untouched while the switch is off.
    order.saveGroupOrder([])
    #expect(order.arrange(sites, origin: origin, group: { sameGroup[$0.key]! }).map(\.key) == ["a", "b"])
    // Turned back on, the hand order applies again — and only then.
    order.enabled = true
    #expect(order.arrange(sites, origin: origin, group: { sameGroup[$0.key]! }).map(\.key) == ["b", "a"])
}

@Test @MainActor func theLastRankedGroupCanStillStepDown() throws {
    let suite = "order." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let order = SourceOrder(defaults: defaults)
    let all = ["pinned", "builtIn", "group:a", "group:b", "group:c"]
    // One group ranked, and it is the last of the ranked ones. Stepping it down must move it past the
    // unranked group that follows it, not be swallowed because the *ranked* list has nothing below.
    // The first press also writes the page's full order as the ranking — the order the reader already
    // sees, with one group moved in it — so the unranked groups keep their places.
    order.saveGroupOrder(["group:a"])
    order.moveGroup("group:a", by: 1, among: all)
    #expect(order.savedGroupOrder == ["pinned", "builtIn", "group:b", "group:a", "group:c"])
    // At the far end, pressing down is a no-op rather than a wrap-around.
    order.saveGroupOrder(["group:c"])
    order.moveGroup("group:c", by: 1, among: all)
    #expect(order.savedGroupOrder == ["group:c"])
}

@Test @MainActor func anEmptyGroupKeepsItsPlaceWhenANeighbourMoves() throws {
    let suite = "order." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let order = SourceOrder(defaults: defaults)
    // "group:empty" is a group the viewer made and has not filled yet. It is in `among`, so a move of
    // its neighbour must carry it along rather than write a ranking that forgets it existed.
    let all = ["group:a", "group:empty", "group:b"]
    order.saveGroupOrder(all)
    order.moveGroup("group:b", by: -1, among: all)
    #expect(order.savedGroupOrder == ["group:a", "group:b", "group:empty"])
    #expect(Set(order.savedGroupOrder) == Set(all))
}

/// 「测速后自动排序」的接线测试：走**真实的键生成器**，而不是 `keysForTesting`。
///
/// 之所以必须有这一条：`reorderByProbe(keysForTesting:)` 收的是调用方直接给的键，测试全用它，
/// 于是「`SourceOrder` 保存的是 scope-JSON、`SourceProbeStore` 索引用裸 sourceKey」这条缝
/// 从来没有被测过。生产路径传进来的键是 `["origin","sourceKey",""]` 的 JSON，拿它去查裸键
/// 索引必然全 nil，`probeOrder` 就把每个源都归进 `unmeasured`、按原序返回 —— 一次静默的空操作。
@Test @MainActor func theSweepReorderLooksTheReadingUpThroughTheRealKeyScheme() throws {
    let suite = "order." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let origin = URL(string: "https://example.com/sub")!
    let config = try Subscription.parse(Data(#"{"sites":[{"key":"slow","name":"Slow","type":1,"api":"https://example.com/s"},{"key":"fast","name":"Fast","type":1,"api":"https://example.com/f"}]}"#.utf8), origin: origin)
    let sites = config.sites
    let order = SourceOrder(defaults: defaults)
    // "fast" 排在后面；测速给它的分更高，重排后它应该到前面去。
    order.save(sites, origin: origin)
    // 真实调用点传的是 scope-JSON 键；这里用同一生成器造键，再按 `sourceKey` 查分 ——
    // 也就是让 `score` 闭包**必须**自己把键还原成 sourceKey 才能查到分。
    let didReorder = order.reorderByProbe(sites, origin: origin, score: { site in
        site.sourceKey == "fast" ? 90 : 10
    })
    #expect(didReorder)
    #expect(order.arrange(sites, origin: origin).map(\.key) == ["fast", "slow"])
}
