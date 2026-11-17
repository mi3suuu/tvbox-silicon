import Foundation
import Testing
@testable import TVCore

// MARK: - 坞的容量、解码预算与卡片钳位

@Suite("DockCapacityAndBudget")
struct DockCapacityAndBudgetTests {

    // MARK: 容量

    /// 卡片上限必须够用（用户报「只能四个」；2026-11-17 又提「10 个 20 个一起挂」）。
    @Test func theDockHoldsEnoughCards() {
        #expect(PlaybackCapacity.dock >= 20, "用户要求 10–20 个迷你小窗同时挂着")
    }

    /// 2026-11-17：卡片不再等于解码路数。
    ///
    /// ⛔ 这条与 2026-11-16 那条**正好相反**（当时要求 decoding == dock）。
    ///    改方向的理由不是喜好变了，是物理限制暴露了：dock 涨到 20 时
    ///    「20 路同时解码」在 iOS 上做不到（解码会话有硬上限），硬上得到的是黑屏。
    ///    所以现在要求：**解码 ≤ 卡片**，且解码有一个与机型无关的上限。
    @Test func decodingStaysBelowTheCardLimit() {
        #expect(PlaybackCapacity.decoding <= PlaybackCapacity.dock,
                "解码路数不能超过卡片数（不然预算没有意义）")
        #expect(PlaybackCapacity.decoding >= 4, "至少要能同时解 4 路，否则多窗没法用")
        #expect(PlaybackCapacity.decoding <= 8, "iOS 的解码会话有限，8 是保守上限")
        // 挂起数是「卡片 − 解码」，20 张卡时必须 > 0。
        let ids = (0..<PlaybackCapacity.dock).map { _ in UUID() }
        #expect(DockDecodingBudget.suspendedCount(order: ids, budget: PlaybackCapacity.decoding)
                == PlaybackCapacity.dock - PlaybackCapacity.decoding)
    }

    /// 解码预算按设备内存分档：内存小的机器必须更保守。
    @Test func theDecodeBudgetFollowsDeviceMemory() {
        let gb = UInt64(1) << 30
        #expect(PlaybackCapacity.decodingBudget(cards: 20, memoryBytes: 3 * gb) == 4)
        #expect(PlaybackCapacity.decodingBudget(cards: 20, memoryBytes: 4 * gb) == 6)
        #expect(PlaybackCapacity.decodingBudget(cards: 20, memoryBytes: 8 * gb) == 8)
        // 卡片比上限少时按卡片数（挂 3 个就没必要说「预算 8」）。
        #expect(PlaybackCapacity.decodingBudget(cards: 3, memoryBytes: 8 * gb) == 3)
        // 极端输入不返回 0/负数（预算 0 会让整坞都不解码）。
        #expect(PlaybackCapacity.decodingBudget(cards: 0, memoryBytes: 8 * gb) == 1)
    }

    /// 按位置判挂起，与按 id 判必须等价（卡片视图只有位置）。
    @Test func suspensionByPositionMatchesTheDecodeSet() {
        let ids = (0..<20).map { _ in UUID() }
        let budget = 8
        let decoding = DockDecodingBudget.decodeSet(order: ids, budget: budget)
        for (index, id) in ids.enumerated() {
            #expect(DockDecodingBudget.isSuspended(index: index, budget: budget) == !decoding.contains(id))
        }
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


// MARK: - 画质增强的准入（20 个小窗那一轮）

/// 「20 个窗 + sharper」在真机上是 2700 MB OOM。根因不是画质增强本身，
/// 而是 `PlaybackSession` **每一路都持有一个 `VideoEnhancer`**，而开关是全局的 ——
/// 于是 20 个窗各建一条 Metal + VideoToolbox 管线。
///
/// 这套断言锁住准入判据：**没有画面层的、有别人在解码的、内存紧张的，一律不许开**。
@Suite("EnhancementBudget")
struct EnhancementBudgetTests {

    private func decide(hasSurface: Bool = true, otherDecoding: Int = 0,
                        memoryPressure: Bool = false, constrained: Bool = false,
                        externalPlayback: Bool = false) -> EnhancementBudget.Decision {
        EnhancementBudget.decide(hasSurface: hasSurface, otherDecoding: otherDecoding,
                                 memoryPressure: memoryPressure, constrained: constrained,
                                 externalPlayback: externalPlayback)
    }

    /// 唯一的正经情形：屏上那一路、没有别的窗在解、系统状态良好。
    @Test func aSingleForegroundPlayerMayEnhance() {
        #expect(decide() == .on)
    }

    /// 坞卡片从来不 attach 画面层 —— 20 张卡片就是 20 个「不许」。
    @Test func aWindowWithNoSurfaceNeverEnhances() {
        #expect(!decide(hasSurface: false).isOn)
    }

    /// 坞里有别的路在解码时让路：这是真机 OOM 的组合（前台增强 + 小窗解码）。
    @Test func otherDecodingWindowsMakeEnhancementYield() {
        let decision = decide(otherDecoding: 3)
        #expect(!decision.isOn)
        #expect(decision.reason.contains("decoding"))
    }

    /// 内存压力 / 发热省电 / AirPlay 各自都能单独把它关掉，且原因可读（诊断要用）。
    @Test func everyResourceReasonTurnsItOff() {
        for decision in [decide(memoryPressure: true), decide(constrained: true),
                         decide(externalPlayback: true)] {
            #expect(!decision.isOn)
            #expect(!decision.reason.isEmpty)
        }
    }
}
