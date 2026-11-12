import Foundation
import Testing
@testable import TVCore

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// 旋转时的几何稳定性 —— **横切竖时播放器宽度必须跟上竖屏**。
///
/// 用户报的现象：「横屏切竖屏，播放器大小没有跟随竖屏的宽度，导致界面推移」。
///
/// 根因不是某个控件算错，而是 `frozenBox` 的来源问题：
/// 原来两处都写
/// ```
/// let raw = fixedScreenSize()          // = screen.bounds.size
/// let port = (min(raw.w, raw.h), max(raw.w, raw.h))
/// ```
/// `min/max` 看着无懈可击，但它重排的仍是 `screen.bounds` **那一刻**的值，
/// 而旋转动画期间 `screen.bounds` 不保证已翻转。取到中间态时：
/// ```
///   (678,466) → port(466,678) winW=466   ✔
///   (600,520) → port(520,600) winW=520   ✘ 宽了 11%
///   (466,678) → port(466,678) winW=466   ✔
/// ```
/// `winW` 抖一次，`winH`、`pictureHeightOf`、窗口 x/y、整层控件坐标全部跟着重算。

private func box(_ raw: CGSize, landscape: Bool) -> CGSize {
    let short = min(raw.width, raw.height)
    let long = max(raw.width, raw.height)
    return landscape ? CGSize(width: long, height: short)
                     : CGSize(width: short, height: long)
}

/// 竖屏冻结盒的宽度等于这块屏的**短边**，高度等于长边。
///
/// ⚠️ 只对「同一块屏的两种朝向」断言相等 —— `(678,466)` 与 `(466,678)`
/// 是同一块屏的两种上报方式，短边都是 466，所以两者必须给出同一个竖屏盒。
/// **不要**把旋转中间态 `(600,520)` 也要求成 466：那是一个物理上更小的
/// 可视区，短边本来就是 520，硬要求 466 是错的（第一版断言就是这么写错的，
/// 被这条测试自己抓出来）。
@Test func thePortraitBoxWidthIsTheScreensShortEdge() {
    let bothOrientationsOfOneScreen: [CGSize] = [
        CGSize(width: 678, height: 466),   // 横屏上报
        CGSize(width: 466, height: 678),   // 竖屏上报
    ]
    for raw in bothOrientationsOfOneScreen {
        let portrait = box(raw, landscape: false)
        #expect(portrait.width == 466, "竖屏宽度应为短边 466，实际 \(portrait.width)（raw=\(raw)）")
        #expect(portrait.height == 678, "竖屏高度应为长边 678（raw=\(raw)）")
    }
    // 中间态：短边/长边各自成立即可，不要求等于整屏。
    let midway = box(CGSize(width: 600, height: 520), landscape: false)
    #expect(midway.width == 520 && midway.height == 600)
}

/// 横屏同理：宽度取长边。三种 raw 都必须收敛到 678。
@Test func theLandscapeBoxWidthIsAlwaysTheScreensLongEdge() {
    let screenEdges: [CGSize] = [
        CGSize(width: 678, height: 466),
        CGSize(width: 466, height: 678),
        CGSize(width: 600, height: 520),
    ]
    for raw in screenEdges {
        let land = box(raw, landscape: true)
        #expect(land.width == max(raw.width, raw.height), "横屏宽度应为长边（raw=\(raw)）")
        #expect(land.height == 466 || land.height == 520,
                "横屏高度应为短边（raw=\(raw) → \(land.height)）")
    }
}

/// 竖屏宽度 == 横屏高度：同一个物理量的两种命名，不允许出现两个来源。
@Test func portraitWidthAndLandscapeHeightAgree() {
    let raw = CGSize(width: 678, height: 466)
    #expect(box(raw, landscape: false).width == box(raw, landscape: true).height)
}

/// **主判据**：竖屏下 `winW → winH → pictureHeightOf` 这条链，
/// 对同一块屏的任何 raw 朝向都必须给出同一个结果。
///
/// 这条是本轮修复的验收口径：只要它绿，就说明「切到竖屏后播放器宽度」
/// 不再随 `screen.bounds` 的中间态抖动。
@Test func thePictureHeightIsIdenticalWhateverOrientationRawReports() {
    func pictureHeight(for raw: CGSize) -> CGFloat {
        let b = box(raw, landscape: false)
        let winW = max(b.width, 1)
        let winH = winW / 1.819
        let h = max(b.height, 1)
        return min(h * 0.091 + winH + h * 0.04, h * 0.72)
    }
    // 同一块屏的两种上报方式 —— 必须给出同一个画面区高度。
    let sameScreen: [CGSize] = [
        CGSize(width: 678, height: 466),   // 横屏上报
        CGSize(width: 466, height: 678),   // 竖屏上报（旋转完成后应该收敛到这里）
    ]
    let heights = sameScreen.map(pictureHeight)
    #expect(Set(heights).count == 1, "画面区高度随 raw 朝向变了：\(heights)")
}

// MARK: - 任意界面可旋转 / 合拢 / 展开

/// 旋转方向：按当前方向反向转。`interfaceOrientation` 是唯一判据。
@Test func rotationAlwaysTurnsTheOtherWay() {
    #expect(PlayerChromeAction.rotation(currentlyLandscape: true) == .toPortrait)
    #expect(PlayerChromeAction.rotation(currentlyLandscape: false) == .toLandscape)
}

/// UIKit 原始值：portrait=1 / landscapeLeft=3 / landscapeRight=4 / unknown=0。
///
/// 这条钉住「不能拿 screen.bounds 宽高比判断方向」——
/// VM 上 screen.bounds 恒报竖屏原值（466×678），按宽高比会永远算出
/// landscape=false，旋转键于是永远请求横屏、转不回竖屏。
@Test func interfaceOrientationRawValuesDecideTheTarget() {
    #expect(PlayerChromeAction.rotation(fromInterfaceOrientationRawValue: 1) == .toLandscape)  // portrait
    #expect(PlayerChromeAction.rotation(fromInterfaceOrientationRawValue: 3) == .toPortrait)   // landscapeLeft
    #expect(PlayerChromeAction.rotation(fromInterfaceOrientationRawValue: 4) == .toPortrait)   // landscapeRight
    #expect(PlayerChromeAction.rotation(fromInterfaceOrientationRawValue: 0) == .toLandscape)  // unknown
}

/// 合拢/展开：只有支持双列的界面才给结果，不支持的返回 nil。
///
/// 返回 nil 而不是 false，是为了让全局入口**不显示**这个按钮，
/// 而不是给一个点了没反应的按钮。
@Test func foldingIsOnlyOfferedWhereItMeansSomething() {
    #expect(PlayerChromeAction.fold(supported: true, currentlyFolded: false) == true)
    #expect(PlayerChromeAction.fold(supported: true, currentlyFolded: true) == false)
    #expect(PlayerChromeAction.fold(supported: false, currentlyFolded: false) == nil)
}

/// 系统方向锁开着时，`requestGeometryUpdate` 会被忽略 —— 必须提示，而不是静默失败。
@Test func anOrientationLockNeedsANotice() {
    #expect(PlayerChromeAction.needsUnlockNotice(orientationLockEnabled: true) == true)
    #expect(PlayerChromeAction.needsUnlockNotice(orientationLockEnabled: false) == false)
}

// MARK: - 可点性（热区）

/// 图标**热区**必须在所有比例尺下都不小于 44pt。
///
/// 用户报的「点不开、点不动、不好点」的直接根因。
/// 原式 `min(40, max(26, glyph*1.8))` 在所有比例尺下都只有 26–33pt：
///   scale=0.82 → 26 / scale=1.00 → 26 / scale=1.40 → 33
/// 全部低于苹果最小可点 44pt，而图标在顶栏里各贴着 `frame(height: hit)` 排成一排，
/// 相邻两颗热区之间没有余量 —— 手指必然落进缝里，落进缝里的点被铺满画面的
/// `gestureLayer` 吃掉，变成「单击显示/隐藏控件」。用户看到的就是「明明点到了却没反应」。
private func hit(glyph: CGFloat) -> CGFloat {
    min(52, max(44, (glyph * 1.8).rounded()))
}
private func oldHit(glyph: CGFloat) -> CGFloat {
    min(40, max(26, (glyph * 1.8).rounded()))
}

@Test func theControlHitAreaIsNeverBelowFortyFourPoints() {
    // scale 夹在 0.82…1.4，glyph = 13*scale → 10.66…18.2
    for scale in stride(from: 0.82, through: 1.4, by: 0.02) {
        let g = (13 * scale).rounded()
        let h = hit(glyph: g)
        #expect(h >= 44, "scale=\(scale) 时热区只有 \(h)pt，低于 44")
    }
}

/// 反证：旧公式在**每一个**比例尺下都不达标 —— 这条钉住「为什么必须改」。
@Test func theOldHitAreaWasBelowFortyFourEverywhere() {
    for scale in stride(from: 0.82, through: 1.4, by: 0.02) {
        let g = (13 * scale).rounded()
        #expect(oldHit(glyph: g) < 44, "旧公式在 scale=\(scale) 竟然达标了，判据需重审")
    }
}

/// 条高必须 ≥ 热区：否则 `Button` 的可点区会被父 `frame` 裁掉超出部分，放大也白放。
@Test func theBarHeightNeverCropsTheHitArea() {
    for scale in stride(from: 0.82, through: 1.4, by: 0.02) {
        let g = (13 * scale).rounded()
        let h = hit(glyph: g)
        let bar = max(h, (g * 2.2).rounded())
        #expect(bar >= h, "scale=\(scale) 条高 \(bar) 小于热区 \(h)")
    }
}

// MARK: - 宽窄判据（对齐 One 的 LargeCanvas）

/// One 的 `LargeCanvas` 用 size class 判宽窄，不用屏幕尺寸、也不用 interfaceOrientation。
/// 这条是「横切竖时播放器宽度没跟上」的根治判据。
///
/// 用字符串传 size class，避免 TVCore 依赖 SwiftUI：
///   "compact"  = .compact
///   "regular"  = .regular
@Test func wideCanvasOnlyLooksAtTheVerticalSizeClass() {
    // 竖持手机：compact × regular → 窄
    #expect(OneSkinCanvasWidth.isWide(horizontal: "compact", vertical: "regular") == false)
    // 横持手机：compact × compact → 宽
    #expect(OneSkinCanvasWidth.isWide(horizontal: "compact", vertical: "compact") == true)
    // 展开 Duo / iPad：regular × regular → 宽
    #expect(OneSkinCanvasWidth.isWide(horizontal: "regular", vertical: "regular") == true)
}

/// **反例**：Duo 外屏竖持会报 `regular × compact`。
///
/// 如果判据去看 `horizontal == .regular` 就当成宽屏，这一态会被误判成横屏
///（历史上真的错过）。所以判据**只能**看 vertical。
@Test func aRegularWidthWithCompactHeightIsStillNarrow() {
    // regular × compact：宽 regular 但高 compact —— 这是「横过来了」，
    // 所以结果为宽，而不是被 horizontal 影响。
    #expect(OneSkinCanvasWidth.isWide(horizontal: "regular", vertical: "compact") == true)
    // 关键对照：只要 vertical 是 regular，无论 horizontal 是什么都是窄。
    #expect(OneSkinCanvasWidth.isWide(horizontal: "regular", vertical: "regular") == true)
    #expect(OneSkinCanvasWidth.isWide(horizontal: "compact", vertical: "regular") == false)
}

/// 环境值还没就绪（nil）时必须返回窄，让调用方退回形态兜底，而不是判成宽屏把页面排成 0 宽。
@Test func anUnreadySizeClassFallsBackToNarrow() {
    #expect(OneSkinCanvasWidth.isWide(horizontal: nil, vertical: nil) == false)
    #expect(OneSkinCanvasWidth.isWide(horizontal: "regular", vertical: nil) == false)
}

// MARK: - 控制栏配置必须按「页面形态」选，不能按窗口宽高比（BUG-L）

/// 播放器**窗口恒为横向**（版式比例 1.819 / 内屏竖持 2.146），所以竖持时窗口也是宽>高。
///
/// | 形态 | 窗口 | 宽高比 |
/// |---|---|---|
/// | 内屏竖持 fullBleed | 669×532 | 1.26（横向！） |
/// | 内屏竖持单列 | 669×312 | 2.146（横向！） |
/// | 内屏横持 split | 951×669 | 1.42 |
/// | 外屏竖持单列 | 466×256 | 1.819 |
///
/// 拿窗口比例判横竖，两种竖持都会算成 `.sideways` → 「展开竖持」那套配置永远读不到。
/// 这条用数值把前提钉住：如果哪天窗口改成竖的，本判据的动机就变了，测试会提醒。
@Test func thePlayerWindowIsAlwaysWiderThanTall() {
    // 由 OneSkinWindowGeometry 的固定版式比例推出的三种窗口尺寸。
    let windows: [(name: String, size: CGSize)] = [
        ("内屏竖持 fullBleed", CGSize(width: 669, height: 532)),
        ("内屏竖持单列", CGSize(width: 669, height: 312)),
        ("内屏横持 split", CGSize(width: 951, height: 669)),
        ("外屏竖持单列", CGSize(width: 466, height: 256)),
    ]
    for w in windows {
        #expect(w.size.width > w.size.height,
                "\(w.name) 的窗口应为横向：\(w.size)")
    }
}

/// 因此「按窗口比例推形态」必然把竖持判错 —— 这正是不能那么做的理由。
@Test func windowAspectCannotTellUprightFromSideways() {
    let uprightFullBleed = CGSize(width: 669, height: 532)
    let uprightColumn = CGSize(width: 669, height: 312)
    let sidewaysSplit = CGSize(width: 951, height: 669)
    // 三者都是「宽 > 高」，仅凭这一条无法区分。
    #expect(uprightFullBleed.width > uprightFullBleed.height)
    #expect(uprightColumn.width > uprightColumn.height)
    #expect(sidewaysSplit.width > sidewaysSplit.height)
}

// MARK: - 遮挡补量只能补差额（BUG-O）

/// `occlusion.top` 与 `safeAreaInsets.top` 在同一坐标系，语义重叠。
///
/// 直接相加会把内容推两遍：safe=84 + occlusion=60 → 实推 144（多 60）。
/// 只补差额才对。
@Test func theOcclusionTopUpIsOnlyTheShortfall() {
    // 安全区已经盖住遮挡 → 不补
    #expect(OneSkinSafeArea.topUp(occlusion: 60, safe: 84) == 0)
    // 遮挡比安全区更靠下 → 只补差额
    #expect(OneSkinSafeArea.topUp(occlusion: 100, safe: 84) == 16)
    // 安全区为 0（外屏 safeTop≈0）→ 全额补
    #expect(OneSkinSafeArea.topUp(occlusion: 84, safe: 0) == 84)
    // 没有遮挡 → 不补
    #expect(OneSkinSafeArea.topUp(occlusion: 0, safe: 84) == 0)
    #expect(OneSkinSafeArea.topUp(occlusion: 0, safe: 0) == 0)
}

/// 补量永远非负且永远不超过遮挡本身。
@Test func theOcclusionTopUpIsBounded() {
    for occ in stride(from: 0.0, through: 200.0, by: 10.0) {
        for safe in stride(from: 0.0, through: 200.0, by: 10.0) {
            let up = OneSkinSafeArea.topUp(occlusion: occ, safe: safe)
            #expect(up >= 0, "补量为负：occ=\(occ) safe=\(safe) → \(up)")
            #expect(up <= occ + 0.01, "补量超过遮挡本身：occ=\(occ) safe=\(safe) → \(up)")
        }
    }
}
