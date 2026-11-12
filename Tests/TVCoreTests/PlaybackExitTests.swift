import Foundation
import Testing
@testable import TVCore

/// 播放退场裁决。
///
/// 这套规则存在的理由是一条真实缺陷：**音频在后台响、界面上一片空白**。
/// 它出现的原因是「应用内小窗 / 应用外悬浮窗 / 真正登出」三者没有统一裁决，
/// 每处退场各自猜一遍，于是漏出了第四种状态。
///
/// 下面每条断言都对着一个**用户明确提出的要求**或一个已知回归。

private func context(
    isBackground: Bool = false,
    layoutJustChanged: Bool = false,
    hasInlinePicture: Bool = true,
    miniPlayerOn: Bool = false,
    pipActive: Bool = false,
    pipPossible: Bool = true,
    pipAllowed: Bool = true,
    miniIntent: Bool = false,
    absenceSettled: Bool = true
) -> PlaybackExit.Context {
    PlaybackExit.Context(isBackground: isBackground, layoutJustChanged: layoutJustChanged,
                         hasInlinePicture: hasInlinePicture, miniPlayerOn: miniPlayerOn,
                         pipActive: pipActive, pipPossible: pipPossible,
                         pipAllowed: pipAllowed, miniIntent: miniIntent,
                         absenceSettled: absenceSettled)
}

// MARK: - 要求一：没有可见载体就必须登出

/// 「不管什么页面，如果没有弹出应用内小窗，那么音频不应该继续在后台播放」。
///
/// 这是本轮最重要的一条：没有任何画面时继续播，用户既回不去也关不掉。
@Test func noVisibleCarrierMeansLogOut() {
    let bare = context(hasInlinePicture: false, miniPlayerOn: false, pipActive: false)
    #expect(PlaybackExit.presentation(bare) == .hidden)
    #expect(PlaybackExit.decide(bare, leavingApp: false) == .logOut)
}

/// 页面还在画就不是空载体，不能登出。
@Test func anInlinePictureIsNeverLoggedOut() {
    #expect(PlaybackExit.decide(context(hasInlinePicture: true), leavingApp: false) == .keep)
}

/// 应用内小窗开着也算有载体。
@Test func theInAppMiniCountsAsAVisibleCarrier() {
    let mini = context(hasInlinePicture: false, miniPlayerOn: true)
    #expect(PlaybackExit.presentation(mini) == .inAppMini)
    #expect(PlaybackExit.decide(mini, leavingApp: false) == .keep)
}

// MARK: - 要求二：上滑回主界面要有应用外悬浮窗

/// 「如果上滑到主界面应该有应用外的悬浮窗」。
@Test func goingToTheHomeScreenRaisesTheSystemFloatingWindow() {
    let left = context(isBackground: true, hasInlinePicture: false, miniPlayerOn: false)
    #expect(PlaybackExit.decide(left, leavingApp: true) == .startPictureInPicture)
}

/// 不允许 PiP 的播放（下载回放、音频源）退到后台就登出，而不是留一个没画面的声音。
@Test func aPlaybackThatMayNotFloatLogsOutInstead() {
    let left = context(isBackground: true, hasInlinePicture: false, pipAllowed: false)
    #expect(PlaybackExit.decide(left, leavingApp: true) == .logOut)
}

/// 应用内小窗已经开着时不再起 PiP —— 否则会有两层画面。
@Test func theInAppMiniAndPictureInPictureNeverStack() {
    let mini = context(isBackground: true, hasInlinePicture: false, miniPlayerOn: true)
    #expect(PlaybackExit.decide(mini, leavingApp: true) == .keep)
}

// MARK: - 要求三：转屏 / 折叠 / 展开绝不浮起悬浮窗

/// 「不能切个横竖屏、展开个横竖屏就跳出应用外小窗」。
///
/// 这条必须**优先于**任何「看起来像离开」的信号，所以它排在 PiP 判定之前。
@Test func aLayoutChangeNeverRaisesTheFloatingWindow() {
    let rotated = context(isBackground: true, layoutJustChanged: true,
                          hasInlinePicture: false, miniPlayerOn: false)
    #expect(PlaybackExit.decide(rotated, leavingApp: true) == .keep)
}

/// 转屏时即使 `scenePhase` 一瞬间变成 background 也不动播放。
@Test func aRotationWithAnInlinePictureChangesNothing() {
    let rotated = context(isBackground: true, layoutJustChanged: true, hasInlinePicture: true)
    #expect(PlaybackExit.decide(rotated, leavingApp: true) == .keep)
}

// MARK: - 回到 App 要收回悬浮窗

/// 回到 App 且画面已经回到页面上时，悬浮窗必须收 —— 否则双画面。
@Test func returningToTheAppStopsTheFloatingWindow() {
    let back = context(isBackground: false, hasInlinePicture: true, pipActive: true)
    #expect(PlaybackExit.presentation(back) == .pictureInPicture)
    #expect(PlaybackExit.decide(back, leavingApp: false) == .stopPictureInPicture)
}

/// 悬浮窗在跑、人还没回来：什么都不做。
@Test func aRunningFloatingWindowIsLeftAloneWhileAway() {
    let away = context(isBackground: true, hasInlinePicture: false, pipActive: true)
    #expect(PlaybackExit.decide(away, leavingApp: true) == .keep)
}

// MARK: - 展示态优先级

/// PiP 一定在执行层，页面内那一份是被它盖住的 —— 所以优先报 PiP。
@Test func pictureInPictureOutranksTheInlinePicture() {
    let both = context(hasInlinePicture: true, pipActive: true)
    #expect(PlaybackExit.presentation(both) == .pictureInPicture)
}

@Test func thePresentationOrderIsStable() {
    #expect(PlaybackExit.presentation(context(hasInlinePicture: true, miniPlayerOn: true, pipActive: true)) == .pictureInPicture)
    #expect(PlaybackExit.presentation(context(hasInlinePicture: true, miniPlayerOn: true)) == .inline)
    #expect(PlaybackExit.presentation(context(hasInlinePicture: false, miniPlayerOn: true)) == .inAppMini)
    #expect(PlaybackExit.presentation(context(hasInlinePicture: false, miniPlayerOn: false)) == .hidden)
}


// MARK: - 过渡态不能登出

/// push / pop 动画、进 / 退全屏、Duo 折叠重挂的那一两帧，载体都会短暂为空。
///
/// 这种「空」不是登出：用户在选集页点一下返回、或者切个全屏，音乐就停掉是明显的 bug。
/// 所以空态要稳定下来才算登出。
@Test func aTransientEmptyCarrierDoesNotLogOut() {
    let inTransition = context(hasInlinePicture: false, absenceSettled: false)
    #expect(PlaybackExit.decide(inTransition, leavingApp: false) == .keep)
}

/// 空态稳定之后才登出 —— 这才是「音频空转」的修复点。
@Test func aSettledEmptyCarrierLogsOut() {
    let settled = context(hasInlinePicture: false, absenceSettled: true)
    #expect(PlaybackExit.decide(settled, leavingApp: false) == .logOut)
}

/// 有载体时 `absenceSettled` 无关紧要 —— 不该因为宽限窗没满就改变「继续播」。
@Test func presenceIsUnaffectedByTheGraceWindow() {
    #expect(PlaybackExit.decide(context(hasInlinePicture: true, absenceSettled: false), leavingApp: false) == .keep)
    #expect(PlaybackExit.decide(context(hasInlinePicture: true, absenceSettled: true), leavingApp: false) == .keep)
}


// MARK: - 能力 vs 意愿

/// One / 哔哩哔哩皮肤用裸 `AVPlayerLayer`，没有 `AVPictureInPictureController` 宿主，
/// 所以「上滑起悬浮窗」在那些界面上**做不到**。
///
/// 做不到就不能假装：那种情况必须留在 `.keep`（播放继续、音频留在后台、回来能接上），
/// 而不是走进一条什么都不会发生的分支，更不是把播放杀掉。
@Test func aSurfaceWithoutPictureInPictureKeepsPlayingInstead() {
    let skin = context(isBackground: true, hasInlinePicture: false, pipPossible: false)
    #expect(PlaybackExit.decide(skin, leavingApp: true) == .keep)
}

/// 有能力时照常起浮 —— 能力判定不能把正常路径也挡掉。
@Test func aCapableSurfaceStillRaisesTheFloatingWindow() {
    let full = context(isBackground: true, hasInlinePicture: false, pipPossible: true)
    #expect(PlaybackExit.decide(full, leavingApp: true) == .startPictureInPicture)
}

/// 「能力」与「意愿」是两件事：下载回放是**有意愿限制**（pipAllowed=false），
/// 但即便它有能力，也不该起浮 —— 那条仍然要走登出。
@Test func willingnessStillWinsOverCapability() {
    let download = context(isBackground: true, hasInlinePicture: false,
                           pipPossible: true, pipAllowed: false)
    #expect(PlaybackExit.decide(download, leavingApp: true) == .logOut)
}


// MARK: - AVKit 承载画面时的起浮

/// 全屏播放器的画面由 `AVPlayerViewController` 承载：它没有 `startPictureInPicture()`，
/// 但可以临时打开 `canStartPictureInPictureAutomaticallyFromInline` 让系统自己起浮。
///
/// 所以「有 AVKit 宿主」必须算**有能力** —— 以前只认自建 controller，
/// 于是全屏播放走「没能力」分支被 `.keep` 掉，返回主屏幕没有浮窗。
@Test func anAVKitHostCountsAsCapable() {
    let full = context(isBackground: true, hasInlinePicture: false, pipPossible: true)
    #expect(PlaybackExit.decide(full, leavingApp: true) == .startPictureInPicture)
}

/// 两条路都不通（既没有自建 controller，也没有 AVKit 宿主）时才退到 `.keep`。
@Test func onlyWhenNeitherPathExistsDoesItStayQuiet() {
    let nothing = context(isBackground: true, hasInlinePicture: false, pipPossible: false)
    #expect(PlaybackExit.decide(nothing, leavingApp: true) == .keep)
}


// MARK: - Duo 三形态：折叠 / 展开 / 转屏一对动作

/// 「合盖外屏（466×678 竖）⇄ 展开竖持（669×951 竖）」的宽高关系**没变**，
/// 所以旧判据（`w>h` 是否翻转）认不出这是一次版式变化。
///
/// 后果不只是「少判一次」：那一刻载体记录（`onAppear/onDisappear`）还没更新，
/// `hasInlinePicture` 会是假，只要顺手退到后台（合盖正好收起手机）就会被判「离开 App」
/// 而浮出应用外小窗 —— 正是用户报的「展开一下就飞出小窗」。
///
/// 这条钉住的是**判据必须来自尺寸变化**：给 `layoutJustChanged = true`，
/// 无论 `isBackground` 是什么、载体看起来多空，都只许 `.keep`。
@Test func aFoldThatKeepsTheAspectRatioStillCountsAsALayoutChange() {
    // 合盖 ⇄ 展开竖持：都是 w<h，但面积从 466×678 变成 669×951。
    let foldedToUpright = context(isBackground: true, layoutJustChanged: true,
                                  hasInlinePicture: false, miniPlayerOn: false)
    #expect(PlaybackExit.decide(foldedToUpright, leavingApp: true) == .keep)

    // 展开竖持 ⇄ 展开横持：这一次宽高关系确实翻转了，也必须是 `.keep`。
    let uprightToSideways = context(isBackground: true, layoutJustChanged: true,
                                    hasInlinePicture: false, miniPlayerOn: false)
    #expect(PlaybackExit.decide(uprightToSideways, leavingApp: true) == .keep)
}

/// 版式变化优先于「看起来像离开」的任何信号 —— 包括 PiP 已经开着。
@Test func aLayoutChangeOutranksEveryLeavingSignal() {
    let floating = context(isBackground: true, layoutJustChanged: true,
                           hasInlinePicture: false, pipActive: true)
    #expect(PlaybackExit.decide(floating, leavingApp: true) == .keep)
}

/// 宽限期未过时即使载体为空也不许登出（折叠重挂那一两帧就是这个状态）。
@Test func aFoldRebuildingItsLayersIsNotALogOut() {
    let rebuilding = context(hasInlinePicture: false, miniPlayerOn: false,
                             pipActive: false, absenceSettled: false)
    #expect(PlaybackExit.decide(rebuilding, leavingApp: false) == .keep)
}
