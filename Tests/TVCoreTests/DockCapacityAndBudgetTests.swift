import Foundation
import Testing
@testable import TVCore

// MARK: - 坞的容量、解码预算与卡片钳位

@Suite("DockCapacityAndBudget")
struct DockCapacityAndBudgetTests {

    // MARK: 容量

    /// 卡片上限必须够用（用户报「只能四个」）。
    @Test func theDockHoldsEnoughCards() {
        #expect(PlaybackCapacity.dock >= 8, "用户报「只能四个」，至少要能挂到 8")
    }

    /// 2026-11-16 用户明确要求「就要同时解码」：解码上限必须等于卡片上限。
    ///
    /// ⛔ 这条与上一版**正好相反**（上一版要求 dock > decoding，好让第 5–8 路挂起）。
    ///    改方向是用户的明确取舍：宁可 8 路一起解、可能互相抢带宽，
    ///    也不要「切过去要等一秒」。判据跟着需求走，不能留着旧断言自相矛盾。
    @Test func everyCardDecodesAtOnce() {
        #expect(PlaybackCapacity.decoding == PlaybackCapacity.dock,
                "用户要求同时解码：解码上限必须等于卡片上限，否则会有路被挂起")
        // 挂起数因此恒为 0 —— 管理器里那条状态行才会显示「N 路同时播放」。
        let ids = (0..<PlaybackCapacity.dock).map { _ in UUID() }
        #expect(DockDecodingBudget.suspendedCount(order: ids, budget: PlaybackCapacity.decoding) == 0)
    }

    /// 流槽位必须覆盖「全部同时解码 + 前台 + 换集重叠」。
    ///
    /// 8 路全解时这条尤其重要：槽位不够会把**正在播的那一路**踢掉（历史缺陷）。
    @Test func streamSlotsCoverEveryDecodingPath() {
        #expect(PlaybackCapacity.streamLimit
                >= PlaybackCapacity.decoding + PlaybackCapacity.foreground,
                "槽位不够时，新起的那一路会把正在播的一路踢掉")
    }

    /// 流槽位必须由 dock/foreground 推导，不能是独立字面量。
    ///
    /// 这条守的是「坞涨了、流没涨」那类老毛病：槽位写死会让新加的那几路
    /// 把正在播的一路挤掉（历史缺陷：坞 4 + 前台 1 却只有 4 个槽位）。
    @Test func streamSlotsFollowFromTheCardLimit() {
        #expect(PlaybackCapacity.streamSlots
                == (PlaybackCapacity.dock + PlaybackCapacity.foreground) * PlaybackCapacity.streamsPerTask)
        #expect(PlaybackCapacity.streamLimit == PlaybackCapacity.streamSlots)
        // 至少要盖住「所有解码中的路 + 前台 + 换集重叠」。
        #expect(PlaybackCapacity.streamLimit >= PlaybackCapacity.decoding + PlaybackCapacity.foreground)
    }

    // MARK: 解码预算

    /// 预算内解码、超出预算暂停；且**最近激活的优先**。
    @Test func theMostRecentlyUsedPathsKeepDecoding() {
        let ids = (0..<8).map { _ in UUID() }
        let decode = DockDecodingBudget.decodeSet(order: ids, budget: 4)
        #expect(decode.count == 4)
        #expect(decode == Set(ids.prefix(4)), "必须是最近激活的前 4 个（order 热的在前）")
        // 靠后的那几个不该解码。
        for id in ids.suffix(4) { #expect(!decode.contains(id)) }
    }

    /// 卡片不超过预算时，全部解码 —— 不能因为引入预算就把小坞也暂停了。
    @Test func aSmallDockDecodesEverything() {
        let ids = (0..<3).map { _ in UUID() }
        #expect(DockDecodingBudget.decodeSet(order: ids, budget: 4) == Set(ids))
        #expect(DockDecodingBudget.suspendedCount(order: ids, budget: 4) == 0)
    }

    /// 预算为 0 或负数时给空集合，不崩、不返回全部。
    @Test func aNonPositiveBudgetDecodesNothing() {
        let ids = (0..<3).map { _ in UUID() }
        #expect(DockDecodingBudget.decodeSet(order: ids, budget: 0).isEmpty)
        #expect(DockDecodingBudget.decodeSet(order: ids, budget: -5).isEmpty)
    }

    /// 挂起数 = 总数 − 预算，且不为负。
    @Test func suspendedCountNeverGoesNegative() {
        let ids = (0..<8).map { _ in UUID() }
        #expect(DockDecodingBudget.suspendedCount(order: ids, budget: 4) == 4)
        #expect(DockDecodingBudget.suspendedCount(order: Array(ids.prefix(2)), budget: 4) == 0)
        #expect(DockDecodingBudget.suspendedCount(order: [], budget: 4) == 0)
    }
}

// MARK: - 卡片拖出屏幕的问题

/// 「窗口不许出屏」的守卫。
///
/// 卡片的偏移是相对右下角锚点的，拖动时是纯累加 —— 能拖到任意远。
/// 上一版只保证「留一角可触摸」，用户的实际感受是「窗口被屏幕吃掉半截」：
/// 压到状态栏/手势条上的那部分既看不见也点不到。现在要求**整块**留在容器内。
@Suite("DockCardClamp")
struct DockCardClampTests {

    private let container = CGSize(width: 466, height: 678)
    private let card = CGSize(width: 200, height: 150)

    /// 拖得再远，整块也必须留在容器里。
    @Test func aCardDraggedFarAwayIsFullyPulledBackInside() {
        let margin = DockCardClamp.margin
        for raw in [CGSize(width: -5000, height: 0), CGSize(width: 0, height: -5000),
                    CGSize(width: 5000, height: 5000), CGSize(width: -5000, height: 5000),
                    CGSize(width: -60, height: -40)] {
            let c = DockCardClamp.clamp(raw, card: card, in: container)
            let rightEdge = container.width + c.width
            let leftEdge = rightEdge - card.width
            #expect(leftEdge >= margin - 0.001, "左边出界：\(leftEdge)")
            #expect(rightEdge <= container.width - margin + 0.001, "右边出界：\(rightEdge)")
            let bottomEdge = container.height + c.height
            let topEdge = bottomEdge - card.height
            #expect(topEdge >= margin - 0.001, "上边出界：\(topEdge)")
            #expect(bottomEdge <= container.height - margin + 0.001, "下边出界：\(bottomEdge)")
        }
    }

    /// 正常范围内的拖动不能被钳掉 —— 用户拖到中间就该待在中间。
    @Test func aReasonableOffsetPassesThroughUntouched() {
        let raw = CGSize(width: -100, height: -200)
        #expect(DockCardClamp.clamp(raw, card: card, in: container) == raw)
    }

    /// 捏到比屏幕还大的卡片：尺寸先被 `fit` 压回来，再钳位就一定有解。
    @Test func anOversizedCardIsShrunkBeforeClamping() {
        let huge = CGSize(width: 900, height: 700)
        let fitted = DockCardClamp.fit(huge, in: container)
        #expect(fitted.width <= container.width - DockCardClamp.margin * 2 + 0.001)
        #expect(fitted.height <= container.height - DockCardClamp.margin * 2 + 0.001)
        // 宽高比保持不变（不能被拉扁）。
        #expect(abs(fitted.width / fitted.height - huge.width / huge.height) < 0.001)

        let c = DockCardClamp.clamp(CGSize(width: 5000, height: 5000), card: fitted, in: container)
        #expect(container.width + c.width <= container.width - DockCardClamp.margin + 0.001)
        #expect(container.height + c.height <= container.height - DockCardClamp.margin + 0.001)
    }
}

