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

// MARK: - 形态判据（唯一真源 · 纯函数）

/// **正向判据**：`w > h` → 横，`h > w` → 竖。这是防回归的唯一机器判据。
///
/// 这两条是「判据只剩一次比较」的直接断言 —— 任何未来改动若重新引入
/// 阈值 / 宽高比 / 滞回带 / 分档，真机上 669×950 这类尺寸就会翻错，
/// 而这两个用例会先红。
@Test func widerThanTallIsLandscape() {
    #expect(OneSkinAxis.isLandscape(containerSize: CGSize(width: 951, height: 669)))
    #expect(OneSkinAxis.isLandscape(containerSize: CGSize(width: 678, height: 466)))
}

@Test func tallerThanWideIsPortrait() {
    #expect(!OneSkinAxis.isLandscape(containerSize: CGSize(width: 669, height: 951)))
    #expect(!OneSkinAxis.isLandscape(containerSize: CGSize(width: 466, height: 678)))
}

/// **边界**：`w == h` 归竖（`.column`）。正方形没有「更宽」这个事实。
///
/// ⛔ 这条必须显式钉住：`w == h` 是唯一的翻转点。若哪天有人把判据改成
/// `w >= h`，正方形会变横、双列在等宽容器里对半分（两列都窄），
/// 而这条断言会先红。
///
/// 注：`810×810` 只用来钉「正方形边界」这一条，**它不是滞回灰带里的点**
/// （旧灰带是 `h/w ∈ (1.05, 1.15]`，`810×810` 的 `h/w = 1.0` 不在其中）。
@Test func squareContainerIsPortrait() {
    #expect(!OneSkinAxis.isLandscape(containerSize: CGSize(width: 810, height: 810)))
}

/// **纯函数性**：同一尺寸反复求值必须恒同答案（无隐藏状态）。
///
/// 这是「无滞回」的结构性断言 —— 旧的 `OneSkinShapeResolver.isLandscape` 带
/// `wasPortrait` 入参，同一个尺寸在灰带内有两个合法答案，取哪个由历史决定。
/// 现在换成纯函数，这条用例把「无历史依赖」钉死：
/// 用一转屏序列（竖 → 中点 → 横 → 中点 → 竖）逐帧求值，每个尺寸两次求值必须相同。
@Test func theSameSizeAlwaysGivesTheSameAnswer() {
    let sequence = [
        CGSize(width: 669, height: 951),   // 内屏竖持
        CGSize(width: 810, height: 810),   // 转屏中点
        CGSize(width: 951, height: 669),   // 内屏横持
        CGSize(width: 810, height: 810),   // 反向转屏中点（与上面同尺寸！）
        CGSize(width: 669, height: 951),   // 回到竖持
    ]
    var seen: [String: Bool] = [:]
    for size in sequence {
        let key = "\(size.width)x\(size.height)"
        let now = OneSkinAxis.isLandscape(containerSize: size)
        if let prev = seen[key] {
            #expect(prev == now, "同尺寸 \(key) 两次求值给出了不同答案")
        }
        seen[key] = now
    }
    // 中点那两帧必须同答案，且必须是竖（w == h 归竖）。
    #expect(seen["810.0x810.0"] == false)
}

/// **退化帧**：0 宽 / 0 高不构成「横」的方向事实。
///
/// 真机首帧实测 `geo.size = 0x88`（`oneskin-device-1655.log` 9 帧），
/// 那时读不到任何方向；必须判竖而不是判横，否则首帧会按双列排版、
/// 而容器宽度是 0 → 整页零宽（同一份日志的 `box=0x54` 黑屏帧）。
@Test func degenerateFramesAreNotLandscape() {
    #expect(!OneSkinAxis.isLandscape(containerSize: CGSize(width: 0, height: 88)))
    #expect(!OneSkinAxis.isLandscape(containerSize: CGSize(width: 88, height: 0)))
    #expect(!OneSkinAxis.isLandscape(containerSize: .zero))
}
