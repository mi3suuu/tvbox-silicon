import Foundation
import Testing
@testable import TVCore

/// 锁住探针名额的**排队**语义：抢不到时要等，而不是静默丢弃。
///
/// ## 为什么这条值得单独测
///
/// 原来的写法是 `guard claimProbeSlot() else { return }` —— 名额被别的入口占满时，
/// 用户点的这一条被**静默丢弃**：界面上不显示数字、也不报错。看起来就是"点了没反应"，
/// 而且没有任何 UI 能捕捉这种失败（它就是"什么都没发生"）。
///
/// 现在改成排队，并且**名额由 `releaseProbeSlot` 一对一移交**，不是"唤醒后重抢" ——
/// 后者会让同批等待者互相抢，排在后面的可能永远轮不到（饥饿）。
@Suite struct ProbeSlotQueueTests {

    @MainActor
    private func store() -> SourceProbeStore {
        SourceProbeStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    /// 名额满时 `waitForProbeSlot` 不返回，直到有人归还。
    ///
    /// 判据用"归还前拿不到、归还后立刻拿到"，而不是断言耗时 ——
    /// 耗时在 CI 上不稳定，而"顺序"才是这条语义的本质。
    @MainActor
    @Test func waitingForaSlotSucceedsOnceOneIsReleased() async {
        let probes = store()
        // 占满全部名额。
        var claimed = 0
        while probes.claimProbeSlot() { claimed += 1 }
        #expect(claimed == SourceProbeStore.maxGlobalProbes)

        // 起一个等待者。
        let waiter = Task { @MainActor in
            await probes.waitForProbeSlot()
        }

        // 给它一点时间真的排进去。
        try? await Task.sleep(for: .milliseconds(50))
        #expect(probes.slotBacklog == 1, "等待者应当已经排进队列")

        // 归还一个名额 → 应当直接移交给他。
        probes.releaseProbeSlot()
        let got = await waiter.value
        #expect(got, "有名额空出来时，等待者必须拿到")
        // 名额是**移交**不是新增：总数不应超过上限。
        #expect(probes.inflightProbes <= SourceProbeStore.maxGlobalProbes)
    }

    /// 名额移交后，全局在飞数不变（不是"先减再加"）。
    ///
    /// 这一条防的是把移交写成 `inflight -= 1` 然后让等待者自己 `+= 1`：
    /// 中间那一瞬计数偏低，别的调用方会趁隙多领，最终超发。
    @MainActor
    @Test func theHandoffKeepsTheCountSteady() async {
        let probes = store()
        while probes.claimProbeSlot() {}
        let full = probes.inflightProbes

        let waiter = Task { @MainActor in await probes.waitForProbeSlot() }
        try? await Task.sleep(for: .milliseconds(50))

        probes.releaseProbeSlot()          // 移交给等待者
        _ = await waiter.value
        #expect(probes.inflightProbes == full, "移交不应改变在飞总数")
    }

    /// 没有等待者时，归还是正常减一。
    @MainActor
    @Test func releasingWithoutWaitersDecrements() {
        let probes = store()
        _ = probes.claimProbeSlot()
        let before = probes.inflightProbes
        probes.releaseProbeSlot()
        #expect(probes.inflightProbes == before - 1)
    }

    /// 预算耗尽要返回 false，并且**把自己从队列摘掉** —— 不能留一个永远不被唤醒的挂起者。
    ///
    /// 留着的后果：`slotBacklog` 永远大于 0，之后每次 `releaseProbeSlot` 都去唤醒一个
    /// 已经没人等的 continuation（崩溃或泄漏），而且真正的排队者排到一个死位置后面。
    @MainActor
    @Test func aTimedOutWaiterLeavesTheQueue() async {
        let probes = store()
        while probes.claimProbeSlot() {}

        let got = await probes.waitForProbeSlot(budget: .milliseconds(80))
        #expect(!got, "预算耗尽必须返回 false，不能假装拿到")
        // 给超时清理一点时间落定。
        try? await Task.sleep(for: .milliseconds(120))
        #expect(probes.slotBacklog == 0, "超时的等待者必须离开队列")
    }

    /// 取消（用户换线路 / 关面板）也要把自己摘掉。
    @MainActor
    @Test func aCancelledWaiterLeavesTheQueue() async {
        let probes = store()
        while probes.claimProbeSlot() {}

        let waiter = Task { @MainActor in await probes.waitForProbeSlot(budget: .seconds(30)) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(probes.slotBacklog == 1)

        waiter.cancel()
        _ = await waiter.value
        try? await Task.sleep(for: .milliseconds(80))
        #expect(probes.slotBacklog == 0, "被取消的等待者必须离开队列")
    }
}
