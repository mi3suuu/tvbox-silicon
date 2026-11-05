import Foundation
import Testing
@testable import TVCore

// 环境（沙箱）隔离是映匣的护城河能力之一：订阅、收藏、播放历史都按 `environmentID` 分开，
// 而这条链路此前只有间接覆盖（PlaybackHistoryTests / SubscriptionTests 走过滤路径时顺带）。
// 本文件补直接单测，锁住六组语义：默认环境不可删 / 切换未知 id 无效 / nil 归属默认 / stamp /
// 外部同步互斥 / 新增即激活。

@Test func aFreshInstallHasOneDefaultEnvironment() {
    let environments = Environments()
    #expect(environments.all.count == 1)
    #expect(environments.all[0].name == Environments.defaultName)
    #expect(environments.activeID == environments.all[0].id)
    #expect(environments.active.id == environments.all[0].id)
}

@Test func anEmptyListStillYieldsTheDefaultEnvironment() {
    // 老数据或损坏的存档解出来是空表：不能让 App 进入「没有环境」的状态，否则订阅/收藏全无所属。
    let environments = Environments(all: [])
    #expect(environments.all.count == 1)
    #expect(environments.all[0].name == Environments.defaultName)
}

@Test func anUnknownActiveIDFallsBackToTheFirstEnvironment() {
    let stale = UUID()
    let environments = Environments(activeID: stale)
    // 存档里的 activeID 指向一个已删除的环境：回落到第一个，而不是留一个悬空 id。
    #expect(environments.activeID == environments.all[0].id)
    #expect(environments.activeID != stale)
}

@Test func addingAnEnvironmentActivatesIt() {
    var environments = Environments()
    let second = environments.add(name: "Guest")
    #expect(environments.all.count == 2)
    #expect(environments.activeID == second.id)
    #expect(environments.active.name == "Guest")
    // 新环境默认「不对外上报、不外部同步」—— 建第二个环境的目的通常就是让它安静。
    #expect(second.reportsActivity == false)
    #expect(second.syncsExternally == false)
}

@Test func theDefaultEnvironmentCannotBeDeleted() {
    var environments = Environments()
    let defaultID = environments.all[0].id
    #expect(environments.remove(defaultID) == false)
    #expect(environments.all.count == 1)
}

@Test func theOnlyEnvironmentCannotBeDeletedEvenIfItIsNotTheDefaultSlot() {
    // 只剩一个时，无论它是不是 all[0]，都拒绝 —— 否则 App 会没有环境可用。
    var environments = Environments()
    let only = environments.all[0].id
    #expect(environments.remove(only) == false)
    #expect(environments.all.count == 1)
}

@Test func removingTheActiveEnvironmentFallsBackToTheFirst() {
    var environments = Environments()
    let second = environments.add(name: "Guest")
    #expect(environments.activeID == second.id)
    #expect(environments.remove(second.id) == true)
    #expect(environments.all.count == 1)
    // 删掉正在看的环境后必须回落到默认，否则 UI 会指着一个不存在的分区。
    #expect(environments.activeID == environments.all[0].id)
}

@Test func removingAnUnknownIDDoesNothing() {
    var environments = Environments()
    _ = environments.add(name: "Guest")
    let before = environments.all
    #expect(environments.remove(UUID()) == false)
    #expect(environments.all == before)
}

@Test func activatingAnUnknownIDIsRefused() {
    var environments = Environments()
    let before = environments.activeID
    // 一个过期按钮点了之后什么也不该发生 —— 返回 false 让调用方能忽略它。
    #expect(environments.activate(UUID()) == false)
    #expect(environments.activeID == before)
}

@Test func activatingAKnownIDSwitchesTheActiveEnvironment() {
    var environments = Environments()
    let defaultID = environments.all[0].id
    let second = environments.add(name: "Guest")
    #expect(environments.activate(defaultID) == true)
    #expect(environments.activeID == defaultID)
    #expect(environments.activeID != second.id)
}

@Test func aRecordWithoutAnEnvironmentBelongsToTheDefaultOne() {
    // 升级上来的数据没有 environmentID。它们必须继续可见（默认环境里），
    // 否则一次升级就把所有人的订阅和收藏都藏起来了。
    let environments = Environments()
    let defaultID = environments.all[0].id
    #expect(environments.shows(nil) == true)
    #expect(environments.shows(defaultID) == true)

    var switched = environments
    let second = switched.add(name: "Guest")
    #expect(switched.shows(nil) == false)
    #expect(switched.shows(second.id) == true)
    #expect(switched.shows(defaultID) == false)
}

@Test func stampFollowsTheActiveEnvironment() {
    var environments = Environments()
    let defaultID = environments.stamp
    let second = environments.add(name: "Guest")
    // 新建的记录要盖当前环境的章，不是默认环境的。
    #expect(environments.stamp == second.id)
    #expect(environments.stamp != defaultID)
}

@Test func onlyOneEnvironmentSyncsExternally() {
    var environments = Environments()
    let defaultID = environments.all[0].id
    let second = environments.add(name: "Guest", syncsExternally: true)
    // 服务端认的是「人」不是「环境」，两个环境同时同步会把历史交织进同一个远端账号。
    #expect(environments.syncingEnvironment?.id == second.id)
    #expect(environments.environment(defaultID)?.syncsExternally == false)

    environments.setSyncsExternally(true, for: defaultID)
    #expect(environments.syncingEnvironment?.id == defaultID)
    #expect(environments.environment(second.id)?.syncsExternally == false)
}

@Test func turningSyncOffLeavesNoEnvironmentSyncing() {
    var environments = Environments()
    let second = environments.add(name: "Guest", syncsExternally: true)
    environments.setSyncsExternally(false, for: second.id)
    #expect(environments.syncingEnvironment == nil)
}

@Test func renamingTrimsAndRefusesAnEmptyName() {
    var environments = Environments()
    let id = environments.all[0].id
    environments.rename(id, to: "  Living Room  ")
    #expect(environments.environment(id)?.name == "Living Room")
    // 空名字拒绝：导航栏上会变成一个点不中的空白项。
    environments.rename(id, to: "   ")
    #expect(environments.environment(id)?.name == "Living Room")
}

@Test func togglingReportsActivityOnlyTouchesThatEnvironment() {
    var environments = Environments()
    let defaultID = environments.all[0].id
    let second = environments.add(name: "Guest")
    environments.setReportsActivity(false, for: defaultID)
    #expect(environments.environment(defaultID)?.reportsActivity == false)
    #expect(environments.environment(second.id)?.reportsActivity == false)
}

@Test func environmentsRoundTripThroughCodable() throws {
    var environments = Environments()
    _ = environments.add(name: "Guest", reportsActivity: false, syncsExternally: true)
    let data = try JSONEncoder().encode(environments)
    let decoded = try JSONDecoder().decode(Environments.self, from: data)
    #expect(decoded == environments)
    #expect(decoded.all.count == 2)
    // 外壳（隔离）必须活过重启，否则重启后所有环境的记录会混在一起。
    #expect(decoded.syncingEnvironment != nil)
}
