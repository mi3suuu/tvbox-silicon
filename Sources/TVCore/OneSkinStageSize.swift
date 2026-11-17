import Foundation
import CoreGraphics

// MARK: - 选集页「容器可用尺寸」（纯计算，可测）

/// 从根部 `GeometryReader` 的连续 `proxy.size` 推导**可用于排版**的容器尺寸。
///
/// 为什么单独抽出来并放进 TVCore：这里出过的两次事故都是**纯算术**错误，
/// 而它们只能靠「极端输入」才暴露 —— 真机上要转屏、折叠、抖动才能碰到，
/// 人工试永远试不全。放在 App 层就等于写不了单测。
///
/// ## 两次事故（都由 `OneSkinStageSizeTests` 钉住）
///
/// 1. **只夹宽度、高度原样透传**（2026-11-10）。
///    排版用的 `box` 取自**静态**屏幕尺寸，而这里是**每帧变化的** `proxy.size`。
///    两个来源不同源 → `pictureHeightOf(avail)` 跟着 proxy 抖 →
///    控件条与详情列的分界每帧重算。
///    实测症状：同一颗「倍速 1x」的 y 在 0.484→0.730 之间乱跳，
///    系统绘制的 TabBar 也在动（0.953→0.975）—— **整页容器在重排**，不是单个控件算错。
///    数值：screen 678×466、proxy 在 951×669 / 678×466 / 951×700 间抖时，
///    画面区高算成 460.4 / 335.5 / 464.4，摆幅约 129pt。
///
/// 2. **等比缩到短边**（更早）。
///    `shortSide > limit*1.12` 就整页等比缩 → 竖屏 proxy=577×576、screen=466×678 时
///    被压成 467×466（屏幕高 678），画面列只剩 309pt、底栏全键点不到。
///
/// ## 现在的语义
/// - **全屏**：proxy 就是真实可视区，直接铺满，不做任何夹取。
/// - **非全屏**：宽度与高度**各自**独立地按屏幕上限夹一次，不做等比缩放。
///   「超限」判定留 12% 余量，避免 1pt 的正常误差触发夹取。
///   只夹超限的那一边，另一边保持 proxy 原值。
public enum OneSkinStageSize {
    /// 超限判定的余量：1.12 倍以内视为正常误差，不夹。
    public static let slack: CGFloat = 1.12

    public static func quantized(_ size: CGSize) -> CGSize {
        CGSize(width: (size.width * 2).rounded() / 2,
               height: (size.height * 2).rounded() / 2)
    }

    /// 这次尺寸变化算不算「版式变了」（转屏 / Duo 折叠 / 展开）。
    ///
    /// ⛔ 判据必须是**逐轴**的，不能用面积。
    ///
    /// Duo 内屏竖持 669×951 与横持 951×669 的**面积完全相同**（636,219 pt²）。
    /// 用面积差（`|after-before| / max`）判，这一对永远算出 0 —— 于是
    /// 「竖持 ⇄ 横持」被当成「什么都没变」，`layoutChangedAt` 不更新，
    /// 退场裁决 `PlaybackExit.decide` 里 `layoutJustChanged == false`，
    /// 只要那一刻恰好在后台（合盖正好收起手机），就会被判成「离开 App」
    /// 而**浮出一个应用外小窗** —— 用户报的「转个方向小窗自己飞出来」。
    ///
    /// 逐轴判就不会漏：951↔669 在宽、高两个方向各自差 29.6%，远超 8% 余量。
    /// 8% 足够滤掉键盘 / 安全区 / 半像素取整带来的抖动，又抓得住
    /// 466→669（+43%）、678→951（+40%）这种量级。
    ///
    /// - Parameters:
    ///   - before: 上一次观测到的容器尺寸。任一分量为 0 时返回 false（首帧）。
    ///   - after: 这一帧的容器尺寸。
    ///   - tolerance: 任一轴的相对变化超过它即算版式变化。
    public static func isLayoutChange(from before: CGSize,
                                      to after: CGSize,
                                      tolerance: CGFloat = 0.08) -> Bool {
        guard before.width > 1, before.height > 1,
              after.width > 1, after.height > 1 else { return false }
        let dw = abs(after.width - before.width) / max(before.width, after.width)
        let dh = abs(after.height - before.height) / max(before.height, after.height)
        return dw > tolerance || dh > tolerance
    }

    public static func available(proxy: CGSize, screen: CGSize, fullScreen: Bool = false) -> CGSize {
        // 首帧 proxy 可能是 0，退回屏幕值。
        guard proxy.width > 1, proxy.height > 1 else {
            return quantized(screen.width > 1 && screen.height > 1 ? screen : proxy)
        }
        // 全屏：侧栏已隐藏，proxy 就是可视区，不拿 screen 夹（VM 上 screen 会报错误的外屏值）。
        if fullScreen { return quantized(proxy) }

        let limitW = screen.width > 1 ? screen.width : proxy.width
        let limitH = screen.height > 1 ? screen.height : proxy.height
        let widthOver = limitW > 0 && proxy.width > limitW * slack
        let heightOver = limitH > 0 && proxy.height > limitH * slack
        guard widthOver || heightOver else { return quantized(proxy) }

        // 只压超限的那一边；不乘比例，避免把另一边也拖下水。
        return quantized(CGSize(width: widthOver ? limitW : proxy.width,
                                height: heightOver ? limitH : proxy.height))
    }
}


// MARK: - 宽屏判据（对齐 One 的 LargeCanvas）

/// One 用 `LargeCanvas` 判「宽屏 / 窄屏」，它的两个成员都是 **size class 环境值**：
///
/// ```
/// struct LargeCanvas {
///     var _horizontal: Environment<UserInterfaceSizeClass?>
///     var _vertical:   Environment<UserInterfaceSizeClass?>
/// }
/// ```
///
/// 这一点很重要，因为它决定了**旋转时布局稳不稳定**：
///
/// - `size class` 是**离散**的（`.compact` / `.regular`），旋转时一次到位，
///   动画进行到哪一帧读到的都是终值；
/// - 而 `screen.bounds` / `window.bounds` 在旋转动画期间会**滞后**
///   （实测 Fig-clone 横屏时 `window.bounds` 仍报 466×678）。
///
/// 所以判方向必须用 size class；屏幕尺寸只用来算**多大**，不用来算**哪个方向**。
/// 混用就会出现「横切竖时播放器宽度没跟上、整页推移」。
public enum OneSkinCanvasWidth {
    /// 是否宽屏（≈ One 的 `LargeCanvas` 为真）。
    ///
    /// 竖持手机：`compact × regular` → 窄屏。
    /// 横持手机：`compact × compact` → 宽屏。
    /// 展开的 Duo / iPad：`regular × regular` → 宽屏。
    ///
    /// 判据（**两条之一成立即宽屏**）：
    ///
    /// 1. `vertical == .compact` —— 横持手机。这是「横过来了」最硬的信号。
    /// 2. `horizontal == .regular && vertical == .regular` —— 展开的 Duo / iPad，
    ///    屏幕本身就是大画布，按 One 的两列排。
    ///
    /// ⛔ 不能只看 `vertical`：那会把 `regular × regular`（iPad / Duo 展开）
    ///    误判成窄屏，整页塌成单列 —— 这条是测试 `wideCanvasOnlyLooksAtTheVerticalSizeClass`
    ///    第一版写错时自己抓出来的。
    /// ⛔ 也不能只看 `horizontal == .regular`：Duo 外屏竖持会报 `regular × compact`，
    ///    那是窄屏，按横屏排会把详情栏挤没。
    public static func isWide(horizontal: Any?, vertical: Any?) -> Bool {
        // 用字符串比较，避免 TVCore 依赖 SwiftUI 的 UserInterfaceSizeClass。
        let h = horizontal.map { String(describing: $0) } ?? ""
        let v = vertical.map { String(describing: $0) } ?? ""
        guard !v.isEmpty else { return false }   // 环境值未就绪：退回形态兜底
        if v.contains("compact") { return true }                       // 横持手机
        if h.contains("regular") && v.contains("regular") { return true } // iPad / Duo 展开
        return false
    }
}

// MARK: - 形态判据（唯一真源）

/// 横竖的**唯一**判据：容器宽 > 高，一次比较。
///
/// ## 为什么这里只有一次比较
///
/// 对齐 One 1.7.1 原身语义（`__pageSize: State<CGSize>` → `width > height`）：
/// 没有阈值、没有宽高比、没有滞回带、没有分档。
/// 证据：`Docs/duo/evidence-2026-11-11/One-1.7.1.interface.swift:1630/3271`；
/// `LargeCanvas` 只有两个 `Environment<UserInterfaceSizeClass?>`，无任何像素字段，
/// 所以它只决定大屏/小屏**档位**，不参与横竖判定。
///
/// ## 为什么曾经用过滞回，以及为什么必须删掉
///
/// 旧实现在这里放了 `portraitEnter = 1.15` / `portraitExit = 1.05` 两个阈值，
/// 并把「上一次是竖是横」(`wasPortrait`) 当入参 —— 判定因此从
/// `f(size)` 退化成 `f(size, 历史)`，同一个尺寸会有**两个合法答案**，
/// 取哪个由历史决定。后果是可复现的转屏滞留：
///
/// - 灰带 = `h/w ∈ (1.05, 1.15]`；
/// - 内屏竖持实测 `669×780` 的 `h/w = 1.1659`，**距 1.15 仅 1.4%** ——
///   高度掉到 769（`h/w = 1.1495`）就翻成横，8pt 分桶也救不回（769→768 得 1.1480）；
/// - 带内每帧答案都可能翻，翻一次就要写一次 `@State`；
/// - 写入源 `keyWindow.bounds` 既是**连续量**（动画每帧都变，`onChange` 每帧触发）
///   又是**不可靠的方向信号**（Duo 内屏竖持仍可能报横值）；
/// - 写错之后纠正需要「更极端」的尺寸，而动画已结束、尺寸不再变化 ⇒
///   **错误跨帧永久保留** —— 用户报的「转屏后形态回不来」。
///
/// 一次比较没有这个结构：
/// - **无记忆**：同帧两次求值必得同值，不存在两个自洽态互相锁定；
/// - **翻转点是单点**（`w == h`，测度为零），不是有宽度的区间，几何抖动无处驻留；
/// - **穿界必然且只穿一次**：转屏时宽高交换，`w/h` 单调扫过 1.0；
/// - **不依赖任何事件**：`geo.size` 一变，下一次求值立刻给新答案，
///   与 `onChange` / `keyWindow` / 屏幕方向 / size class 全部解耦；
/// - **错只持续一帧**：一帧读到的还是旧方向，排出来的版式自洽、装得下、不闪，
///   下一帧自动纠正，不跨帧累积。
///
/// ## 边界语义
///
/// `w == h` 归**竖**（`.column`）：正方形没有「更宽」这个事实，
/// 而竖持单列是唯一对两种方向都装得下的版式（双列在等宽容器里对半分，两列都窄）。
public enum OneSkinAxis {
    /// 容器是否横持。**纯函数**：同输入恒同输出，无任何历史入参。
    ///
    /// - Parameter containerSize: 根部 `GeometryReader` 的 `geo.size`，或
    ///   与之同源的容器尺寸。**不得**传 `fixedScreenSize()` / `keyWindow.bounds` /
    ///   `liveGeometry.box` —— 那三条在 Duo 上不是「本视图拿到的容器」，会与渲染不同源。
    public static func isLandscape(containerSize: CGSize) -> Bool {
        // 退化帧（首帧 proxy 可能是 0）不算横：0×88 之类没有任何方向事实。
        // 这不是阈值，是「方向未知」与「横」的区分。
        guard containerSize.width > 1, containerSize.height > 1 else { return false }
        return containerSize.width > containerSize.height
    }
}
