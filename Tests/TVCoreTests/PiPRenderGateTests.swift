import Foundation
import Testing
@testable import TVCore

/// 画中画出帧闸：**「时间在走、像素不动」的唯一判定点**。
///
/// ## 为什么这组断言必须存在
///
/// `PiPRenderGate.verdict` 返回 `renders == false` 时，`OneSkinFixedPlayerLayer`
/// 会执行 `view.update(player: nil)` —— 把 player 从 `AVPlayerLayer` 上摘掉。
/// 这不报错、不失败、`AVPlayerItem.status` 仍是 `.readyToPlay`、
/// `presentationSize` 仍然正确、播放时间**照常前进**。
/// 用户看到的只是「压暗的海报底」，与「片源没画面」「窗口算错」完全同形。
///
/// 所以这里钉的不是「代码风格」，是**四条互相矛盾的语义不能被合并成一条**：
///
///   ① 没有浮窗                      → 必须渲染
///   ② AVKit 托管的浮窗（不给 layer） → 必须渲染（它不占用我们的 layer）
///   ③ 自建浮窗、本层就是内容源       → 必须渲染（浮窗画的就是它）
///   ④ 自建浮窗、确实在别的 layer 上  → 必须**让出**（否则浮窗只剩声音）
///
/// ②与④在旧实现里长得一模一样（`isActive == true` + `sourceLayer` 不是本层），
/// 但结论**完全相反**。把它们并成一支持久化下来，就是本轮那个缺陷。

private func state(
    isActive: Bool = true,
    avkitHostedActive: Bool = false,
    hasController: Bool = true,
    hasSource: Bool = true,
    sourceMatchesLayer: Bool = false,
    sourceDetached: Bool = false
) -> PiPRenderGate.State {
    PiPRenderGate.State(isActive: isActive,
                        avkitHostedActive: avkitHostedActive,
                        hasController: hasController,
                        hasSource: hasSource,
                        sourceMatchesLayer: sourceMatchesLayer,
                        sourceDetached: sourceDetached)
}

// MARK: - ① 没有浮窗

@Test func withNoPictureInPictureEveryLayerRenders() {
    // 这是绝大多数帧：其余五格无论取值如何，都不该影响结论。
    for hasController in [true, false] {
        for hasSource in [true, false] {
            for matches in [true, false] {
                for detached in [true, false] {
                    let v = PiPRenderGate.verdict(state(isActive: false,
                                                        hasController: hasController,
                                                        hasSource: hasSource,
                                                        sourceMatchesLayer: matches,
                                                        sourceDetached: detached))
                    #expect(v == .noPiP, "没浮窗时必须渲染（其余格只是噪声）")
                    #expect(v.renders)
                    #expect(!v.clearsGlobals, "没浮窗时不该有东西可清")
                }
            }
        }
    }
}

// MARK: - ② AVKit 托管的浮窗

/// 本轮缺陷的核心断言。
///
/// AVKit（全屏播放器的 `AVPlayerViewController`）起浮时只写 `isActive = true`，
/// **不会**写 `sourceLayer`（AVKit 不把它的画面层交给我们）。因此
/// `isActive == true` + `hasSource == false` 是**正常且合法**的状态，
/// 结论必须是「继续渲染」。
@Test func anAVKitHostedFloatingWindowStillRendersTheInlineLayer() {
    let v = PiPRenderGate.verdict(state(avkitHostedActive: true,
                                        hasController: false,
                                        hasSource: false))
    #expect(v == .avkitHosted)
    #expect(v.renders, "AVKit 的浮窗不占用我们的 AVPlayerLayer，内嵌层必须继续画")
    #expect(!v.clearsGlobals, "AVKit 正浮着，绝不能把它的全局标记当僵尸清掉")
}

/// 上一个用例的**反证**：把 `avkitHostedActive` 拿掉，同样的输入必须判成僵尸。
///
/// 没有这一条，上面那条断言无法证明「这个字段真的在起作用」——
/// 它可能只是因为别的分支先命中了才通过。
@Test func theSameStateWithoutTheAVKitFlagIsTreatedAsStale() {
    let v = PiPRenderGate.verdict(state(avkitHostedActive: false,
                                        hasController: false,
                                        hasSource: false))
    #expect(v == .staleNoController)
    #expect(v.clearsGlobals)
    #expect(v != .avkitHosted, "两个字段必须真的分开两支")
}

// MARK: - ③ 自建浮窗、本层即内容源

@Test func theLayerThatIsTheFloatingWindowsSourceAlwaysRenders() {
    let v = PiPRenderGate.verdict(state(sourceMatchesLayer: true))
    #expect(v == .mine)
    #expect(v.renders, "浮窗画的就是这条 layer，摘掉 player 等于把浮窗画面摘掉")
    #expect(!v.clearsGlobals, "这是正常在用，不是僵尸")
}

/// 内容源命中必须**优先于**僵尸判定：即使控制器/槽位的事实看起来可疑，
/// 只要本层就是内容源，就不能摘它。
@Test func beingTheSourceOutranksEveryStaleSignal() {
    let v = PiPRenderGate.verdict(state(hasController: false,
                                        hasSource: true,
                                        sourceMatchesLayer: true,
                                        sourceDetached: true))
    #expect(v == .mine, "先比内容源，再判僵尸 —— 顺序不可重排")
    #expect(v.renders)
}

/// 内容源命中同样必须优先于 AVKit 标记。
///
/// 两条浮窗通路的标记是进程级共享的，极端时序下可以同时为真
/// （自建刚起浮、AVKit 那边仍留着上一帧的 true）。此时「本层就是内容源」
/// 是**可以逐位比对**的硬事实，布尔标记只是转述 —— 硬事实优先。
@Test func beingTheSourceOutranksTheAVKitFlagToo() {
    let v = PiPRenderGate.verdict(state(avkitHostedActive: true,
                                        hasController: true,
                                        hasSource: true,
                                        sourceMatchesLayer: true))
    #expect(v == .mine, "本层就是内容源时，不该因为 AVKit 标记而被判成别人的浮窗")
    #expect(v.renders)
}

// MARK: - ④ 确实在另一条 layer 上跑：必须让出

@Test func aLayerOtherThanTheRunningSourceYieldsThePlayer() {
    let v = PiPRenderGate.verdict(state(sourceMatchesLayer: false))
    #expect(v == .yieldedToOtherLayer)
    #expect(!v.renders, "一个 AVPlayer 只驱动一条 layer；不让出，浮窗就只剩声音")
    #expect(!v.clearsGlobals, "这是合法让出，清掉它会把浮窗画面抢回来")
}

// MARK: - ⑤ 僵尸标记三支

/// 说在跑、却没有控制器 → 铁定僵尸。这一支旧实现**只写在注释里、没写进代码**。
@Test func noControllerAtAllMeansTheFlagIsStale() {
    let v = PiPRenderGate.verdict(state(hasController: false, hasSource: true))
    #expect(v == .staleNoController)
    #expect(v.renders, "不能让一个不存在的浮窗永久挡死画面")
    #expect(v.clearsGlobals)
}

@Test func aControllerWithAnEmptySourceSlotIsStale() {
    let v = PiPRenderGate.verdict(state(hasController: true, hasSource: false))
    #expect(v == .staleNoSource)
    #expect(v.renders)
    #expect(v.clearsGlobals)
}

@Test func aDetachedSourceLayerIsStale() {
    let v = PiPRenderGate.verdict(state(sourceDetached: true))
    #expect(v == .staleDetachedSource)
    #expect(v.renders)
    #expect(v.clearsGlobals)
}

/// 三支僵尸**各自**都必须被判成「要清」，而合法让出必须被判成「不清」。
///
/// 这是「清僵尸」这个副作用的唯一护栏：清错了会把浮窗的画面抢回来，
/// 不清则画面永久黑掉。两个方向都得钉住。
@Test func onlyTheStaleVerdictsClearTheGlobals() {
    let all: [PiPRenderGate.State] = [
        state(isActive: false),
        state(avkitHostedActive: true, hasSource: false),
        state(sourceMatchesLayer: true),
        state(),                                     // 合法让出
        state(hasController: false),                 // 僵尸
        state(hasSource: false),                     // 僵尸
        state(sourceDetached: true),                 // 僵尸
    ]
    for s in all {
        let v = PiPRenderGate.verdict(s)
        let shouldClear: Bool
        switch v {
        case .staleNoController, .staleNoSource, .staleDetachedSource: shouldClear = true
        default: shouldClear = false
        }
        #expect(v.clearsGlobals == shouldClear, "\(v.name) 的清除语义不对")
    }
}

// MARK: - 判决与渲染的一致性

/// `renders == false` **只允许**出现在「确实在别处跑」这一支。
///
/// 这条是回归护栏：将来若有人再加一支返回 false，这里会立刻红，
/// 而不是等到真机上「又只剩海报」再查一轮。
@Test func onlyTheYieldVerdictStopsRendering() {
    #expect(PiPRenderGate.Verdict.yieldedToOtherLayer.renders == false)
    let mustRender: [PiPRenderGate.Verdict] = [
        .noPiP, .avkitHosted, .mine,
        .staleNoController, .staleNoSource, .staleDetachedSource,
    ]
    for v in mustRender {
        #expect(v.renders, "\(v.name) 必须渲染")
    }
}

/// 日志短名唯一：`PICGATE dec=` 这一格要能被真机日志直接搜到，
/// 两个判决共用一个名字就等于这条判据失效。
@Test func everyVerdictHasItsOwnLogName() {
    let names = [
        PiPRenderGate.Verdict.noPiP.name,
        PiPRenderGate.Verdict.avkitHosted.name,
        PiPRenderGate.Verdict.mine.name,
        PiPRenderGate.Verdict.staleNoController.name,
        PiPRenderGate.Verdict.staleNoSource.name,
        PiPRenderGate.Verdict.staleDetachedSource.name,
        PiPRenderGate.Verdict.yieldedToOtherLayer.name,
    ]
    #expect(Set(names).count == names.count, "判决短名必须唯一，否则日志分不出病因")
    #expect(names.allSatisfy { !$0.isEmpty })
}
