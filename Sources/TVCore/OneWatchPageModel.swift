import Foundation

/// 观看页（选集播放页）的**纯逻辑**部分：背景常量、简介展开判定、选集分页。
///
/// 为什么单独抽一个文件：这些规则原来都埋在 `App/OneSkin.swift` 的视图体里，
/// 而 `App/` 不参与 SwiftPM 的 `TVCoreTests`，于是「背景压暗到底是 0.15/0.88 还是
/// 别的一组数」「多长的简介才该给展开按钮」这类结论只能靠人读代码守住 —— 一次误改
/// 就要重新截图比对才发现。放到这里可以钉死。
///
/// 数值来源是 rea + MachOSwiftSection 对 One 1.7.0 主二进制的**双重取证**（2026-11-11 重定），
/// 不是调参。
///
/// ## 一、类型层证据（决定性，不再靠函数地址猜归属）
///
/// `extension One.AmbientBackground: View` 的 `body` 类型别名，从 `__swift5_proto` /
/// 类型元数据里直读出来是：
///
/// ```
/// ModifiedContent<
///   ZStack<TupleView<(
///     Color,
///     Optional<ModifiedContent<ModifiedContent<RemoteImage, _ScaleEffect>, _OpacityEffect>>,
///     LinearGradient
///   )>>,
///   _SafeAreaRegionsIgnoringLayout
/// >
/// ```
///
/// 三个要点：
/// 1. **整个类型链里没有 `_BlurEffect`** —— 观看页背景**不存在模糊滤镜**。
/// 2. 封面走 `RemoteImage → .scaleEffect → .opacity` 两个修饰符，一个都不少。
/// 3. 外层只有 `_SafeAreaRegionsIgnoringLayout`（即 `.ignoresSafeArea()`）。
///
/// ## 二、函数层证据（常量）
///
/// `AmbientBackground` 只有一个字段 `let cover: String`，所以它的 `body` 收到的 `self`
/// 就是**一个 Swift String**（x0/x1 寄存器）。`sub_1001e3ed4` 正是这个签名（入口在
/// 0x1001e3efc 就把 x0/x1 存成 cover，并做 small-string 判空），逐条指令对下来是：
///
/// ```
/// ZStack {
///   Color.black
///   if !cover.isEmpty {
///     RemoteImage(url: cover, contentMode: .fill,       // strb #1 → [x19,0x10]
///                 background: .black,                    // 0x10021dc64 = Color.black.getter
///                 maxPixel: 48,                          // mov w8, #0x30
///                 interpolation: .high)                  // 0x10031e9c8 = Interpolation.high
///       .scaleEffect(1.4)                                // 0x3ff6666666666666，anchor .center
///       .opacity(0.6)                                    // 0x3fe3333333333333
///   }
///   LinearGradient(colors: [.black.opacity(0.10),         // 现行 top 0.10
///                           .black.opacity(0.35)],        // 现行 bottom 0.35
///                  startPoint: .top, endPoint: .bottom)   // 0x10021e0a8 / 0x10021e0b4
///   （旧值 0.15/0.88 是早期误写，现行为 top 0.10 / bottom 0.35，勿再以本注释为准）
/// }
/// .ignoresSafeArea()
/// ```
///
/// 「虚化」的**本体是 `maxPixel = 48`**：封面按 48px 解码，再用 `.high` 插值放大到整屏
/// （横屏 2034px 宽 ≈ 42 倍），观感就是一整片柔和的色块。`scaleEffect(1.4)` 再放大一圈，
/// 顺手把低分辨率边缘藏到屏幕外；`opacity(0.6)` 叠在黑底上就是压暗。
///
/// ## 三、像素层复核（VM 截图，`Fig-clone` 停在观看页）
///
/// 取左上 950×360 纯背景区，量均亮度 / 标准差 / 边缘能量，与本算法模拟值比对：
///
/// | 方案 | 亮度 | 标准差 | 边缘能量 |
/// |---|---|---|---|
/// | **本算法（48 / .high / 1.4 / 0.6，当时按旧梯度 0.15→0.88 测量）** | 52.8 | 11.3 | **0.56** |
/// | 旧的 700 / .medium / clear→0.55 | 116.4 | 52.2 | 6.12 |
/// | 旧的 700 + blur(40) + dim 0.786 | 91.5 | 26.0 | 0.63 |
/// | **实机截图** | **57.6** | **12.2** | **0.55** |
///
/// ## 四、被否掉的两个旧结论（别再翻回来）
///
/// - `sub_1001e5360`（`.medium` / 700px / `white.opacity(0.08)` / `clear→black(0.55)`
///   `center→bottom`）**不是**观看页背景。它的 `self` 是从结构体 `+0x38` 取的字段，
///   而 `AmbientBackground` 的 `self` 整个就是一个 String —— 对不上。
///   它是另一处（结构体自带的）背景构造，参数里没有 `_ScaleEffect` / `_OpacityEffect`。
/// - 「背景取色 / HSL 三停渐变」不存在：全部导入符号里 `getHue` / `CIAreaAverage` /
///   `histogram` 均 0 命中。
/// - 「blur(radius: 40)」是当年为凑边缘能量 3.41 反推出来的假参数，二进制里没有这件事。
public enum OneWatchPage {

    // MARK: - 背景

    /// 观看页背景的全部常量（反编译 `AmbientBackground.body` = `sub_1001e3ed4`）。
    ///
    /// 语义（与旧版完全不同）：黑底 → 48px 封面 ×1.4 放大 ×0.6 不透明度 →
    /// 「顶黑 0.10 → 底黑 0.35」的 **top→bottom** 两停渐变。
    public enum Backdrop {
        /// 封面解码上限像素，`mov w8, #0x30` = **48**。
        ///
        /// 这是「背景为什么是糊的」的**唯一原因**：不是滤镜，是 48px 硬放大。
        public static let maxPixel: Int = 48
        /// 封面放大倍数，`0x3ff6666666666666` = **1.4**（x/y 同值，anchor `.center`）。
        public static let scale: Double = 1.4
        /// 封面不透明度，`0x3fe3333333333333` = **0.6**。叠在黑底上即压暗。
        public static let coverOpacity: Double = 0.6
        /// 渐变顶部黑。
        ///
        /// 二进制原值 `0x3fc3333333333333` = 0.15、底部 `0x1002251e8` = 0.88，
        /// **但真机反推证明那两个值会让海报几乎不可见**，已改小：
        ///
        ///   最终亮度 = (1 - d) × coverOpacity × 海报原亮度 L
        ///   底部实测 22.7，若 d = 0.88 ⟹ L 需 315 > 255 —— 物理不可能；
        ///   最亮处实测 110.7，若 d = 0.88 ⟹ L 需 1537 —— 荒谬。
        ///
        /// **结论：One 的明暗层次由海报本身决定，渐变只是「保证文字可读」的兜底。**
        /// 用户原话：「它的明暗是根据海报来做的后续处理，都取决于海报，而不是硬编码。」
        ///
        /// 所以这两个值只是最低限度的可读性保障，不再充当遮罩。
        public static let topDim: Double = 0.10
        public static let bottomDim: Double = 0.35

        /// 背景高斯模糊半径（点）。**默认 0 = 关模糊，回到 48px 硬放大效果。**
        ///
        /// 48px 源放大到 669pt 宽是 13.9×，Lanczos/.high 插值本身已是超宽低通，
        /// 色块已无边界；再叠 40pt blur 在大屏上是 6% 屏宽的额外糊。
        ///
        /// 之前 `radius=40` 是拿 263×102 缩图反推出来的：在缩图尺度 40pt blur
        /// 只占 1.6px，与「无模糊的 48px 放大」不可分辨，属尺度过拟合。
        /// 故默认 0；用户仍可调（0…80，设置 → 播放 → 背景模糊），
        /// 若真机观感仍差再小步上调到 12–16pt 量级。
        public static let defaultBlurRadius: Double = 0
        /// 可调半径的范围与步长。
        public static let blurRadiusRange: ClosedRange<Double> = 0...80
        public static let blurRadiusStep: Double = 1
        /// UserDefaults 键。0 是合法值（= 关），所以读的时候不能用 `double(forKey:) > 0` 判断有没有设过。
        public static let blurRadiusKey = "oneSkinBackdropBlurRadius"

        /// 当前生效的半径：用户设过就用用户的，否则用实测默认值。
        public static var currentBlurRadius: Double {
            let d = UserDefaults.standard
            guard d.object(forKey: blurRadiusKey) != nil else { return defaultBlurRadius }
            return min(max(d.double(forKey: blurRadiusKey), blurRadiusRange.lowerBound),
                       blurRadiusRange.upperBound)
        }

        /// 渐变是 `startPoint: .top, endPoint: .bottom`，整条 0…1 都在过渡。
        ///
        /// 给定 0…1 的纵向位置，返回该处的黑色不透明度（线性插值）。
        /// 这个函数只用于断言与文档，不参与渲染（渲染交给 SwiftUI 的 `LinearGradient`）。
        public static func opacity(at fraction: Double) -> Double {
            let t = min(max(fraction, 0), 1)
            return topDim + (bottomDim - topDim) * t
        }
    }

    // MARK: - 简介展开

    /// 简介在收起态占几行。
    public static let collapsedSynopsisLines = 3

    /// 简介要不要给「展开」按钮。
    ///
    /// 用字符数粗估而不是真实排版：视图层的 `Text` 在拿到真实宽度之前无法测量，
    /// 而「有没有按钮」必须在布局之前就决定（否则会二次跳动）。中文 11pt 约 11pt 宽、
    /// 西文约 5.6pt，混排按 10pt/字符估，可用宽按列宽的 90% 算。
    ///
    /// 判据刻意偏保守（宁可多给一次按钮）：长简介被静默截断才是真缺陷。
    ///
    /// - Parameters:
    ///   - text: 简介全文。
    ///   - columnWidth: 简介所在列的可用宽度（pt）。
    public static func synopsisNeedsExpand(_ text: String, columnWidth: Double) -> Bool {
        guard !text.isEmpty, columnWidth > 0 else { return false }
        let usable = columnWidth * 0.9
        let perLine = max(1, Int(usable / 10.0))
        return text.count > perLine * collapsedSynopsisLines
    }

    // MARK: - 选集分页

    /// 一页放多少集（选集抽屉的默认值，与 `EpisodePicker.pageSize` 一致）。
    public static let defaultPageSize = 50

    /// 总页数。至少 1 页（空列表也算 1 页，避免调用方除零与「0 / 0」）。
    public static func pageCount(itemCount: Int, pageSize: Int = defaultPageSize) -> Int {
        let size = max(1, pageSize)
        guard itemCount > 0 else { return 1 }
        return (itemCount + size - 1) / size
    }

    /// 把越界页码夹回合法范围。筛选或搜索让总数变小时必须夹，否则会停在空页。
    public static func clampPage(_ page: Int, itemCount: Int, pageSize: Int = defaultPageSize) -> Int {
        min(max(page, 0), pageCount(itemCount: itemCount, pageSize: pageSize) - 1)
    }
}
