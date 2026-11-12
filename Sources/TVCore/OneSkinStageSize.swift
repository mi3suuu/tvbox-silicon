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

// MARK: - 形态与实际容器方向的和解（Duo 内屏竖持）

/// 声明的形态是「展开横屏」，但容器其实是竖的 —— 这时必须以容器为准。
///
/// ## 为什么 `interfaceOrientation` 在 Duo 内屏不可信
///
/// 实测（Duo 内屏，真机 + 模拟器 hinge）：内屏**竖持**时
/// `UIWindowScene.interfaceOrientation` 仍报 `.landscapeLeft/.right`，
/// 于是 `sideways = duoExpanded && landscapeScreen` 被算成 true，
/// 页面按「展开横屏」分成左右双列。
///
/// 而同一时刻 SwiftUI 根部 `GeometryReader` 拿到的容器是 **669×780**（竖的）。
/// 两者的分歧直接变成用户看到的错位：
///   · 排版用的 `box` 是 951×669（按横屏摆的静态矩形）；
///   · 实际可用空间只有 669 宽；
///   · 结果三栏按 951 分（左列 507 + 间隙 + 右栏 427）铺到 669 上 ——
///     横向溢出 282pt，右栏被推出屏幕，看起来「整页往左推移、右边被切掉」。
///
/// ## 为什么不能直接每帧用 `proxy.size`
///
/// 容器尺寸在折叠/转屏动画期间**连续变化**，每帧据此改形态会在临界点反复翻转
/// （项目历史上「控件疯狂推移」的根因）。所以这里用**滞回**：
/// 竖的判据与横的判据不是同一个阈值，中间留出一段「不改变决定」的带宽，
/// 动画扫过临界点时形态不会跟着抖，稳定后一次到位。
public enum OneSkinShapeResolver {
    /// 进入竖持的宽高比阈值（高/宽）。
    ///
    /// 1.15 ≈ 8.4° 的倾斜余量：正常竖持的内屏是 780/669 = 1.166，刚过线；
    /// 而横持是 547/951 = 0.575，离得很远，两者不会互相干扰。
    public static let portraitEnter: CGFloat = 1.15
    /// 退回横持的阈值。必须**小于** `portraitEnter`，这段差就是滞回带。
    public static let portraitExit: CGFloat = 1.05

    /// 一次判定。
    ///
    /// - Parameters:
    ///   - declaredIsLandscape: 调用方按 `interfaceOrientation` 等信号给出的形态。
    ///   - containerSize: 这一帧容器真实尺寸（根部 `GeometryReader` 的 proxy）。
    ///   - wasPortrait: 上一次判定结果，用来实现滞回。首次判定传 nil。
    ///   - isLargeScreen: 只有大屏（摊开的内屏 / iPad）才做这个校正。
    ///     普通手机横持时容器是 678×466（比例 0.69），本来就远离阈值；
    ///     但明确加上这道门，可以保证这个校正永远不会改写手机的行为。
    public static func isLandscape(declaredIsLandscape: Bool,
                                  containerSize: CGSize,
                                  wasPortrait: Bool?,
                                  isLargeScreen: Bool) -> Bool {
        guard isLargeScreen, declaredIsLandscape else { return declaredIsLandscape }
        guard containerSize.width > 1, containerSize.height > 1 else { return declaredIsLandscape }
        let ratio = containerSize.height / containerSize.width
        // 已经有结论时用更松的退出阈值，避免在临界点来回翻。
        if wasPortrait == true {
            return ratio < portraitExit
        }
        return ratio <= portraitEnter
    }

}
