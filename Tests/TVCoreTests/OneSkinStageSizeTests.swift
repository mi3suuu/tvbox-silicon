import Foundation
import Testing
@testable import TVCore

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// 选集页「容器可用尺寸」：**宽度与高度必须各自独立地被屏幕夹住**。
///
/// 用户报的是「控件一直在推移」。根因不是某个控件算错坐标，而是：
///   · 排版用的 `box` 取自**静态**屏幕尺寸；
///   · 这里返回的 `avail` 跟着**每帧变化**的 `proxy.size` 走。
/// 两个来源不同源 → `pictureHeightOf(avail)` 每帧重算 → 控件条与详情列的分界跟着抖。
///
/// 症状特征（用来区分「单控件错位」与「整页重排」）：
/// 连**系统绘制的 TabBar** 的 y 都在动（实测 0.953→0.975）。
///
/// 下面用「同一屏幕 + proxy 抖动」的矩阵把这条钉死。

private let phone = CGSize(width: 678, height: 466)   // Fig-clone 实测屏幕

// MARK: - 高度也必须夹

/// proxy 比屏幕高时（VM 的 `.ignoresSafeArea()` 多加了一层坐标容器，
/// 实测报 951×669 而屏幕只有 678×466），高度必须收敛到屏幕值。
///
/// 旧实现只夹宽度、`height: proxy.height` 原样透传 —— 这条会红。
@Test func aTallerProxyIsClampedToTheScreenHeight() {
    let got = OneSkinStageSize.available(proxy: CGSize(width: 951, height: 669), screen: phone)
    #expect(got.height <= phone.height, "高度没被夹：\(got.height) > \(phone.height)")
    #expect(got.width <= phone.width)
}

/// **核心回归**：同一块屏幕、proxy 在合理范围内抖动时，返回的高度必须**恒定**。
///
/// 旧实现下高度会随 proxy 变（460.4 / 335.5 / 464.4），摆幅约 129pt，
/// 正好对应实测的控件漂移幅度。这条是本轮的主判据。
@Test func theAvailableHeightDoesNotFollowA_JitteringProxy() {
    // 只取**都超限**的那几个 proxy：它们必须收敛到同一个（屏幕）尺寸。
    // 不该把「本来就没超限、原样透传」的 proxy 混进来 —— 那种情况透传才是对的。
    let overshooting: [CGSize] = [
        CGSize(width: 951, height: 669),
        CGSize(width: 951, height: 700),
        CGSize(width: 900, height: 620),
    ]
    let heights = overshooting.map { OneSkinStageSize.available(proxy: $0, screen: phone).height }
    #expect(Set(heights).count == 1, "超限 proxy 的高度没收敛：\(heights)")
    #expect(heights.allSatisfy { $0 <= phone.height }, "高度超屏：\(heights)")

    let widths = overshooting.map { OneSkinStageSize.available(proxy: $0, screen: phone).width }
    #expect(Set(widths).count == 1, "超限 proxy 的宽度没收敛：\(widths)")
    #expect(widths.allSatisfy { $0 <= phone.width }, "宽度超屏：\(widths)")
}

/// 抖动的 proxy 算出来的 `pictureHeightOf` 必须恒定 —— 这是真正喂给版式的那个数。
///
/// 用与 `OneSkin.pictureHeightOf` 相同的公式（竖屏分支）：
///   min(h·portraitTop + winW/1.819 + h·0.04, h·0.72)
@Test func thePictureHeightIsStableAcrossAJitteringProxy() {
    func pictureHeight(_ avail: CGSize) -> CGFloat {
        let winW = max(avail.width, 1)
        let winH = winW / 1.819
        let h = max(avail.height, 1)
        return min(h * 0.091 + winH + h * 0.04, h * 0.72)
    }
    let overshooting: [CGSize] = [
        CGSize(width: 951, height: 669),
        CGSize(width: 951, height: 700),
        CGSize(width: 900, height: 620),
    ]
    let values = overshooting.map { pictureHeight(OneSkinStageSize.available(proxy: $0, screen: phone)) }
    #expect(Set(values).count == 1, "画面区高度随 proxy 抖了：\(values)")
}

// MARK: - 不能把另一边也拖下水（等比缩的事故）

/// 竖屏 proxy=577×576、screen=466×678：旧实现等比缩成 467×466，
/// 屏幕高 678 却只用了 466 —— 画面列被压到 309pt。
/// 现在的语义是**只压超限的那一边**，高度不许被宽度连累。
@Test func narrowingTheWidthNeverShrinksTheHeight() {
    let got = OneSkinStageSize.available(proxy: CGSize(width: 577, height: 576),
                                        screen: CGSize(width: 466, height: 678))
    #expect(got.width <= 466, "宽度没夹：\(got.width)")
    #expect(got.height == 576, "高度被宽度连累了：\(got.height) ≠ 576")
}

/// 正常范围内的 proxy 一个像素都不该动 —— 夹取只在真超限时发生。
@Test func aNormalProxyPassesThroughUntouched() {
    let proxy = CGSize(width: 400, height: 800)
    #expect(OneSkinStageSize.available(proxy: proxy, screen: CGSize(width: 430, height: 932)) == proxy)
}

/// 12% 余量：轻微超出不触发夹取，避免 1pt 误差引起整页重排。
@Test func aSlightOvershootWithinSlackIsNotClamped() {
    let screen = CGSize(width: 400, height: 800)
    let proxy = CGSize(width: 440, height: 800)   // 10% 宽，未到 12%
    #expect(OneSkinStageSize.available(proxy: proxy, screen: screen).width == 440)
}

// MARK: - 全屏与首帧

/// 全屏时 proxy 就是真实可视区，**不拿 screen 夹** ——
/// VM 上 screen 会报错误的外屏值，夹了会把全屏缩成一小块巨黑边。
@Test func fullScreenTakesTheProxyAsItIs() {
    let proxy = CGSize(width: 951, height: 669)
    #expect(OneSkinStageSize.available(proxy: proxy, screen: phone, fullScreen: true) == proxy)
}

/// 首帧 proxy 可能是 0，必须退回屏幕值而不是返回 0（否则整页塌成 0 高）。
@Test func aZeroProxyFallsBackToTheScreen() {
    let got = OneSkinStageSize.available(proxy: .zero, screen: phone)
    #expect(got.width > 1 && got.height > 1, "首帧兜底失效：\(got)")
}

/// 量化到 0.5pt：亚点抖动不该触发整页重排。
@Test func theResultIsQuantizedToHalfPoints() {
    let got = OneSkinStageSize.available(proxy: CGSize(width: 400.3, height: 800.7),
                                        screen: CGSize(width: 430, height: 932))
    #expect(got.width * 2 == (got.width * 2).rounded())
    #expect(got.height * 2 == (got.height * 2).rounded())
}

// MARK: - 版式变化的判据必须**逐轴**

/// Duo 内屏竖持⇄横持：面积完全相同，逐轴差 29.6%。
///
/// 这是「转个方向就浮出应用外小窗」的判据根因：面积差恒为 0，
/// `layoutJustChanged` 一直是 false，只要那一刻在后台就被判成「离开 App」。
@Test func aQuarterTurnThatKeepsTheAreaStillCounts() {
    let portrait = CGSize(width: 669, height: 951)
    let landscape = CGSize(width: 951, height: 669)
    // 先证明旧判据在这个输入上确实为 0 —— 否则这条测试守的不是真 bug。
    let before = portrait.width * portrait.height
    let after = landscape.width * landscape.height
    #expect(abs(after - before) / max(before, after) == 0, "面积差不为 0，判据前提失效")
    #expect(OneSkinStageSize.isLayoutChange(from: portrait, to: landscape))
    #expect(OneSkinStageSize.isLayoutChange(from: landscape, to: portrait))
}

/// 合盖外屏 ⇄ 展开竖持：宽高关系不变（都是 w<h），但逐轴差 43% / 40%。
@Test func foldingOutwardIsALayoutChangeEvenThoughItStaysUpright() {
    #expect(OneSkinStageSize.isLayoutChange(from: CGSize(width: 466, height: 678),
                                           to: CGSize(width: 669, height: 951)))
}

/// 半像素抖动、键盘、安全区变化都不许被当成版式变化，否则每次都得拦一次退场。
@Test func subPercentJitterIsNotALayoutChange() {
    #expect(!OneSkinStageSize.isLayoutChange(from: CGSize(width: 669, height: 951),
                                             to: CGSize(width: 670, height: 950)))
    // 8% 余量之内保持原判（含恰好 5%）。
    #expect(!OneSkinStageSize.isLayoutChange(from: CGSize(width: 400, height: 800),
                                             to: CGSize(width: 420, height: 800)))
}

/// 首帧（上一尺寸为空）不能算版式变化 —— 否则冷启动第一帧就会压住自动浮起。
@Test func theFirstFrameIsNotALayoutChange() {
    #expect(!OneSkinStageSize.isLayoutChange(from: .zero, to: CGSize(width: 669, height: 951)))
    #expect(!OneSkinStageSize.isLayoutChange(from: CGSize(width: 669, height: 951), to: .zero))
}

// MARK: - 形态与容器方向的和解

/// **Duo 内屏竖持**：`interfaceOrientation` 报 landscape，但窗口是 669×780（竖）。
/// 不校正 → 排版基准算成 951×669，三栏铺到 669 宽上横向溢出 282pt。
@Test func anUprightInnerDisplayIsNotLandscapeWhateverTheInterfaceSays() {
    let upright = CGSize(width: 669, height: 780)
    #expect(!OneSkinShapeResolver.isLandscape(declaredIsLandscape: true,
                                              containerSize: upright,
                                              wasPortrait: nil,
                                              isLargeScreen: true),
            "内屏竖持（780/669=1.166）被判成横屏")
}

/// 内屏**横持**必须仍然是横屏：951×547（比例 0.575）。
@Test func aSidewaysInnerDisplayStaysLandscape() {
    #expect(OneSkinShapeResolver.isLandscape(declaredIsLandscape: true,
                                             containerSize: CGSize(width: 951, height: 547),
                                             wasPortrait: nil,
                                             isLargeScreen: true))
}

/// 滞回：竖持结论已成立后，要回到比例 < 1.05 才翻回横屏，
/// 避免动画扫过临界点时形态反复翻转（那就是「控件疯狂推移」）。
@Test func theHysteresisBandDoesNotFlipFlop() {
    // 1.166 进竖；退到 1.10（仍在带内）不该翻。
    #expect(!OneSkinShapeResolver.isLandscape(declaredIsLandscape: true,
                                              containerSize: CGSize(width: 600, height: 660),
                                              wasPortrait: true,
                                              isLargeScreen: true))
    // 退到 1.00 才翻回横屏。
    #expect(OneSkinShapeResolver.isLandscape(declaredIsLandscape: true,
                                             containerSize: CGSize(width: 660, height: 660),
                                             wasPortrait: true,
                                             isLargeScreen: true))
}

/// 非大屏（外屏 466×678、iPhone 393×852）**一律不改写**声明值，
/// 保证这个校正永远碰不到外屏与普通手机的既有行为。
@Test func theCorrectionNeverTouchesTheOuterOrNormalPhone() {
    for size in [CGSize(width: 466, height: 678), CGSize(width: 393, height: 852)] {
        #expect(!OneSkinShapeResolver.isLandscape(declaredIsLandscape: false,
                                                  containerSize: size,
                                                  wasPortrait: nil,
                                                  isLargeScreen: false))
        #expect(OneSkinShapeResolver.isLandscape(declaredIsLandscape: true,
                                                 containerSize: size,
                                                 wasPortrait: nil,
                                                 isLargeScreen: false))
    }
}
