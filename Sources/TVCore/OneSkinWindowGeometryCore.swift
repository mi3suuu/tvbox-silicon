import Foundation
import CoreGraphics

// MARK: - 播放器窗口几何（纯计算，可测）

/// 画面窗口的**唯一几何来源**。
///
/// 为什么在 TVCore 而不是 App：这里的每一行都是纯算术，没有 SwiftUI 依赖，
/// 而「转屏时窗口越界」正是这类算术最容易错的地方 —— 放在 TVCore 才能被单测覆盖。
/// App 侧 `OneSkinWindowGeometry.swift` 里已改为 `typealias` 引用本文件。
///
/// 由此产生的硬约束（`OneSkinWindowGeometryTests` 全量钉住）：
///   · 任何容器尺寸下，`winY + winH ≤ colH`、`winX + winW ≤ colW`；
///   · 两个分支**只读 `colW / colH`**，绝不读 `UIScreen`；
///   · 窗口尺寸与片源比例无关（1.819 固定版式比例）。
public struct OneSkinWindowGeometry {
    public let colW: CGFloat
    public let colH: CGFloat
    public let inset: CGFloat
    /// 把几何值**取整到整点**。
    ///
    /// ★ 存在的唯一原因：UIView 的 `bounds` 渲染时会取整，若我们传小数
    /// （实测 `winH = 305/1.819 = 167.675`），同一份 SwiftUI 状态会在
    /// 167 / 168 之间来回落整 —— `updateUIView` 每帧被触发，
    /// `pictureColumn` 每秒重建 34 次，视频画面上下抖 1pt。
    ///
    /// 日志铁证：`fixedLayer view=305x167` 与 `view=305x168` **交替**出现。
    /// 取整后 frame 恒定，`updateUIView` 只在真实尺寸变化时才调用。
    @inline(__always)
    static func px(_ v: CGFloat) -> CGFloat { max((v).rounded(), 0) }

    public let winX: CGFloat
    public let winY: CGFloat
    public let winW: CGFloat
    public let winH: CGFloat

    /// 顶部/底部 padding —— 必须与 `stage` 真正施加的一致。
    /// `stage` 用的是：
    ///   `.padding(.top,    landscape ? 8 : 0)`
    ///   `.padding(.bottom, landscape ? layout.margin : 28)`
    /// 其中 `margin = max(10, 列宽 × 0.0147)`（**不是**列高的比例）。
    // ===== 版式常量（One 1.7.0 逐像素实测）=====
    //
    // 这些数字原先散落在 8 个地方各写一遍：
    //   0.0333 ×4、0.0236 ×3、0.5334 ×4、0.4499 ×2、0.0167 ×2、0.091 ×3、466.0 ×1
    // 改一处不同步一处就会错位（R10 那次只改了 pictureColumn 的 winY，
    // 按钮立刻画到画面外）。现在**只在这里定义**，别的地方一律引用。
    public enum Metrics {
        /// 横屏左列宽 / 间隙 / 右栏宽（合计 1.0）
        /// ★ 2026-11-11 真机实测修正：0.5334 → 0.4501
        ///
        /// 数据来源：Duo 内屏横持 951×669pt 截图（1–6 号，存储帧旋转 90° 后量测）。
        ///   · 左列内容   0.0 .. 428.0pt  = 45.01%
        ///   · 纯黑竖缝 428.0 .. 483.3pt  = 55.3pt
        ///   · 右栏内容 483.3 .. 951.0pt  = 49.18%
        ///
        /// 旧的 0.5334 来自 Fig VM 2034×1398 的另一套实测，两者差 8.3 个百分点
        /// （79pt）。用户口头确认「差不多一半」，与 45.01% 一致，故以真机为准。
        public static let columnLeft: CGFloat = 0.4501
        /// 竖缝占屏宽：55.3 / 951 = 5.82%
        public static let columnGap: CGFloat = 0.0582
        /// 右栏：483.3 .. 951 = 49.18%
        public static let columnRight: CGFloat = 0.4918
        /// 画面窗口的水平内缩（相对列宽）
        public static let insetLandscape: CGFloat = 0.0333
        public static let insetPortrait: CGFloat = 0.0236
        /// 竖屏画面窗口顶部起点（相对列高）
        public static let portraitTop: CGFloat = 0.091
        /// 横屏窗口垂直中心（相对可用高度）
        // ★ 2026-11-12 真机 AX 实测修正：0.455 → 0.4365
        //
        // 真 One（内屏展开横持，播放中）：播放器 y=158.33 h=267.33 容器高 669
        //   垂直中心 = 158.33 + 267.33/2 = 291.995 → 291.995/669 = 0.4365
        // 旧值 0.455 算出中心 304.4，对应 y≈170.7（实测我方 171，吻合旧常量）
        // 改用 0.4365 后 y ≈ 158.3，与真 One 一致。
        // ★ 2026-11-12 真机 AX 实测：0.4365 → 0.4431
        //
        // 注意 centre 是相对 **usableH（659 = 669 - margin 10）**，不是 colH。
        // 真机目标：播放器 y=158.33, h=267.33
        //   centre = (158.33 + 267.33/2) / 659.03 = 0.4431
        // 用 0.4365 时 y=154.00（差 -4.33）。
        public static let landscapeCentre: CGFloat = 0.4431
        /// 字号缩放基准列高
        public static let fontBaseHeight: CGFloat = 466
        /// 画面窗口最小高度
        public static let minPictureHeight: CGFloat = 120
        /// 竖屏时**底部必须给控件条留的比例**（占容器高）。
        ///
        /// 6% 与 `thePortraitWindowLeavesRoomForTheControlBar` 的判据一致。
        /// 存在的理由：容器异常矮（如转屏动画中间帧 colH=300）时，
        /// 窗口若一直撑到底（`colH - top`），底边正好压住「倍速 1x」那排键 ——
        /// 画面把控件条盖住，用户点不到任何东西。
        /// 正常手机高度下窗口本来就够不到这个上限，所以这条只在极端尺寸生效。
        public static let controlBarRoom: CGFloat = 0.06
        /// **画面窗口的版式比例（固定，不随片源变）**。
        /// One 实测 1015×558 px = 1.819。窗口尺寸必须恒定 ——
        /// 一旦由片源比例决定，初始兜底值（0.4）会把 winH 算成 842pt
        /// 超出屏幕、画面被裁到看不见，用户点「填充」才看得到；
        /// 等 presentationSize 轮询读到真值，窗口又跳一次。
        /// 片源不匹配时由 `videoGravity`(.resizeAspect) 在**窗口内部** letterbox。
        public static let windowAspect: CGFloat = 1.819
        /// 播放器容器的宽高比 = **片源比例**（16:9）。
        ///
        /// 2026-11-12 真机 AX 实测：真 One 播放器 475.0 × 267.33 = 1.7768，
        /// 与 16:9 的 1.7778 差 0.0010（1pt 内）。而 `windowAspect 1.819`
        /// 会算出 261.13，比真值矮 6.2pt。
        /// 播放器是片源容器，形状由片源决定，不由设备窗口决定。
        public static let playerAspect: CGFloat = 16.0 / 9.0
        /// 横持播放器容器的**左侧内缩**（绝对 pt）。
        /// 2026-11-12 真机 AX 实测：真 One 播放器 x = 16.0。
        public static let playerInsetLandscape: CGFloat = 16.0
        /// 横持播放器容器的**右侧留白**（绝对 pt）。
        /// 2026-11-12 真机 AX 实测：播放器右边界 491，右栏起点 523 ⇒ 右边距 32.0。
        /// 这条留白在视觉上就是那条「黑缝」。
        public static let playerTrailingLandscape: CGFloat = 32.0
        /// 竖持播放器的**右侧留白**（绝对 pt）。
        ///
        /// 2026-11-12 真机实测（外屏竖持 466×678）：
        ///   视频 x=16 w=350 ⇒ 右留白 = 466-366 = **100**
        /// 与横持的 32 不同 —— 竖持右缘有竖排胶囊轨道（真机截图可见），
        /// 横持那 32 只是「视觉缝」。
        public static let playerTrailingPortrait: CGFloat = 100.0
        /// ★ 内屏竖持播放态**专属**版式比例（2026-11-11 真机实测，用户裁决「分形态常量」）。
        ///
        /// 数据来源：内屏竖持播放态（9 号帧，669×951pt）视频矩形实测
        /// 宽 669 / 高 311.67 = **2.146**（窗口底 397.33，顶 85.67）。
        /// 与固定 1.819 差 18%：按 1.819 窗口高算 368pt，多出 56.3pt，
        /// 把 chip 行与标题区往下挤 —— 这是「竖持播放态错乱」的根因之一。
        /// 外屏竖持、横屏双列、全屏**不适用**（外屏要满宽、横屏未实测、全屏铺满）。
        /// 只在内屏竖持（列宽 ≥ 500pt，即 Duo 摊开内屏）的播放态生效。
        public static let portraitWindowAspectLarge: CGFloat = 2.146
        /// 竖屏分支取用的窗口比例：内屏竖持走专属 2.146，外屏维持 1.819。
        @inline(__always)
        public static func portraitAspect(forColumnWidth colW: CGFloat) -> CGFloat {
            colW >= 500 ? portraitWindowAspectLarge : windowAspect
        }
    }

    /// 横屏内容区上方的内缩量。
    ///
    /// 原来 8pt —— 对应 `stage` 上的 `.padding(.top, 8)`。两者必须同步：
    /// 那个 padding 已经删掉（它让屏幕最上沿露出 8pt 黑条），这里也必须归零，
    /// 否则 `usableH` 少算 8、窗口会凭空上移 8pt，顶栏跟着一起偏。
    public static let topPaddingLandscape: CGFloat = 0
    public static let bottomPaddingPortrait: CGFloat = 28
    public static func margin(forColumnWidth width: CGFloat) -> CGFloat {
        max(10, width * 0.0147)
    }

    /// 「全出血」形态里画面列（画框）的版式比例。
    ///
    /// One 内屏竖持实测：669 宽 → 画面列 376.3 高 = 1.7778。
    ///
    /// ⛔ 这是**画框的比例**，不是片源比例。两者的区别正是 2026-11-13 那次回归：
    /// 拿片源比例算画框，竖源就把画面列拉成 1189pt（整页被撑爆、详情栏压成 1pt），
    /// 宽银幕又把画面列压到 285pt（详情列白多 90pt、画面反而更小）。
    /// 片源只决定框内怎么 letterbox，框恒定。
    public static let fullBleedColumnAspect: CGFloat = 16.0 / 9.0

    /// 「全出血」形态里画面列的高度 —— **唯一来源**（App 只准调这里）。
    ///
    /// ⛔ 结果不得依赖容器高度：容器高由「画面列 + 详情列」拼出来，
    /// 拿它当输入就是环（实测列高 213→378 爬升，每秒 291 次重排）。
    /// 所以只读列宽 —— 宽度由屏幕/分栏决定，不随内容变。
    public static func fullBleedPictureColumnHeight(columnWidth: CGFloat) -> CGFloat {
        let w = max(columnWidth, 1)
        return max((w / fullBleedColumnAspect).rounded(), Metrics.minPictureHeight)
    }

    /// - Parameters:
    ///   - size: 这一列的尺寸
    ///   - landscape: 由容器决定，**不要**用 `colW > colH` 反推
    ///     （双列时左列是 361×466 的窄高矩形，反推会永远判成竖屏）
    ///   - fullScreen: 全屏态铺满可用空间并 letterbox 居中
    ///   - portraitTopInset: 竖屏窗口顶边到**本列顶边**的距离。
    ///
    ///     ⛔ 必须能由调用方指定，不能一律用 `colH * portraitTop`。
    ///
    ///     竖屏单列时这一列**不是整屏**：它的高度是 `pictureHeightOf` 算出的
    ///     「画面区高度」= 屏高×0.091 + 窗口高 + 屏高×0.04，列顶就是屏幕顶。
    ///     若这里再乘一次 `portraitTop`，得到的是「画面区高度的 9.1%」，
    ///     而正确值是「**屏幕**高度的 9.1%」—— 两者差一个列高比：
    ///       外屏 466×678：正确 61.7pt，实际 33.9pt（上移 27.8pt）
    ///       内屏 669×951：正确 86.5pt，实际 44.8pt（上移 41.7pt）
    ///     窗口整体上移，顶栏就压进灵动岛/挖孔那一条 ——
    ///     用户报的「竖屏时控件没有避让摄像头」。
    ///
    ///     传 nil 时退回 `colH * portraitTop`（老行为，全屏与双列不受影响）。
    public init(size: CGSize, landscape: Bool, fullScreen: Bool,
                /// `true` = 用户按了全屏键（铺满整屏，顶部也铺）。
                /// `false` + `fullScreen: true` = 展开宽屏的「全出血」（横向铺满，纵向让开遮挡）。
                /// 两者此前共用一个分支，导致**按全屏键时顶部被让出一整块**
                /// （竖持 58pt 空白，菜单/控件被往下顶）—— 就是这个参数要修的回归。
                edgeToEdgeOnly: Bool = false,
                portraitTopInset: CGFloat? = nil) {
        // ⛔⛔ 构造器**不接受任何片源参数**，这是刻意的。
        //
        // 2026-11-13：窗口尺寸第一次被接到片源比例上（`winH = innerW / playerAspect`），
        // 竖屏源（9:16）直接把 523×294 的窗口算成 371×659 ——
        // 左列变成「一根 71% 宽的窄高条 + 29% 压暗海报底」，winY 被夹到 0 顶穿屏幕。
        // 用户看到的就是「横持只剩海报、双栏设计没了」。
        //
        // 更阴的是它**看起来是对的**：横源 16:9 算出来 523/1.7778 = 294.2，
        // 与固定版式 523/1.819 = 287.5 只差 6.7pt（2.4%），肉眼不可辨。
        // 缺陷只在竖源上暴露，而当时的 QA 入口写死 16:9，四条验收通道结构上跑不到。
        //
        // 所以这条缝必须**在类型层面焊死**：谁想按片源改窗口，只能改这个构造器，
        // 而它一个 aspect 参数都不收。片源只决定窗口**内部**怎么 letterbox
        //（`OneSkinFixedPicture` 的 `.resizeAspect`），绝不决定窗口本身。
        // 回归护栏见 `OneSkinWindowGeometryTests`（含竖源/宽银幕/4:3 逐字段对照）。
        let colW = size.width
        let colH = size.height
        self.colW = colW
        self.colH = colH

        let inset = landscape ? colW * Metrics.insetLandscape : colW * Metrics.insetPortrait
        // ⚠️ 只作旧版式记录，**不参与任何窗口几何计算**。
        // 外壳满宽后这两个比例只剩史料价值；谁再拿它去减 winW 就是把边距带回来。
        self.inset = inset

        if fullScreen {
            // 全屏 / 全出血：窗口铺满整列，由 `.resizeAspect` 在内部 letterbox。
            //
            // ★★ 2026-11-12：**必须让出顶部遮挡区**，不能 `winY = 0`。
            //
            // 实测（`-qaOneShape fullBleed`）：winY=0 时画面顶到屏幕最上沿，
            // 上半截被摄像头/挖孔挡住；而 `column` 形态的 winY=58 是对的。
            // 两者在同一种持握下不该差 58pt。
            //
            // 全出血的语义是「横向铺满」（winX=0、winW=colW），
            // **不是**「纵向也顶到 0」—— 顶部遮挡与横竖无关，必须始终让开。
            // 按全屏键：铺满整屏，顶部**不**让开（用户要看满画面）。
            // 展开宽屏的全出血：横向铺满，纵向仍让开摄像头。
            let top = edgeToEdgeOnly
                ? max(portraitTopInset ?? (colH * Metrics.portraitTop), 0)
                : 0
            self.winW = Self.px(colW)
            self.winH = Self.px(max(colH - top, 1))
            self.winX = 0
            self.winY = Self.px(top)
        } else {
            // ★ 播放器外壳**满宽**（用户明确要求）：
            //   · 竖屏播放态：占满整个屏幕宽度；
            //   · 横屏双栏：占满整个左列宽度（winX = 0）。
            let innerW = max(colW, 1)

            // ⛔ 竖屏与横屏**独立定义**（用户明确：不能共用一个公式）。
            //
            // 越界根因：竖屏的 `colH` 是 `pictureHeightOf` 算出的「画面区高度」，
            // 它**已经包含**窗口高度（= screenH*0.091 + winH + screenH*0.04）。
            // 旧代码又用 `colH*0.091` 当 winY、用 `colH` 当 maxH 基准 ——
            // 对「含窗口高的高度」再套一次「顶部留白比例 + 窗口高」，双重计算。
            // 屏幕较矮时 colH 被 0.72 夹住，winY + winH 就超出 colH，
            // 窗口底部压进 detailColumn —— 用户报的「越界」。
            //
            // 正解：竖屏窗口几何直接用**屏幕尺寸**（离散值，不随动画变），
            // 与 colH/picH 完全解耦：
            //   winW = 屏幕宽（满宽）
            //   winH = 屏幕宽 ÷ 1.819（固定版式比例，不夹 maxH）
            //   winY = 屏幕高 × 0.091（顶部留白，基于屏幕高）
            // 窗口底 = 屏幕高×0.091 + 屏宽÷1.819，天然 ≤ 屏幕高（屏宽÷1.819 < 屏高）。
            // ⛔ 这里**不再**读 `OneSkin.fixedScreenSize()`。
            //
            // 那个值在旋转动画期间报的是**旧方向**的尺寸，与同一帧里已经按新方向
            // 重算好的 `colW/colH` 不同步 —— 混用就必然在「横切竖」的那几帧越界。
            // 现在两个分支都只用容器自身的 `colW/colH`，同源同帧，转屏时一起变。
            if landscape {
                // 横屏：窗口在左列内，winW=左列宽、winH=winW/1.819、中心 45.5%。
                let usableH = max(
                    colH - Self.topPaddingLandscape - Self.margin(forColumnWidth: colW),
                    1
                )
                // ★ 2026-11-12 真机 AX 实测修正：高度按**片源比例**，不用 windowAspect。
                //
                // 真 One（内屏展开横持，AX 实测）：播放器 475.0 × 267.33
                //   475 / 267.33 = 1.7768 ≈ 16:9 的 1.7778（差 0.001，1pt 内）
                //   而 windowAspect 1.819 → 475/1.819 = 261.13，比真值矮 6.2pt
                //
                // 我方旧值：win = 468 × 257，比例 1.8210 ≈ windowAspect 1.819
                //   ⇒ 高度多算、宽度少算，与真 One 差 (+7, +10.3)
                //
                // 正解：高度 = 宽度 ÷ 片源比例。播放器是「片源容器」，
                // 它的形状必须由片源决定，不能由设备窗口比例决定。
                // ★★★ 2026-11-12 用户明确要求：横持播放器**占满左半栏**。
                //
                // 此前按真机实测做了「左 16 + 右 32」内缩（winW = 523-48 = 475）。
                // 用户要求改成占满整栏：
                //   winX = 0
                //   winW = innerW（= 整列宽 523）
                //   winH = 高度按左半栏的宽高比，填到可用高
                //
                // 高度：占满栏目后按**版式比例**算，再夹到可用高。
                // 窗口 = **固定版式的画框**：宽度吃满列宽，高度 = 宽 ÷ 1.819。
                //
                // 片源只决定框内怎么 letterbox（`OneSkinFixedPicture` 的 `.resizeAspect`），
                // 绝不决定框本身 —— 理由见构造器头部那段（2026-11-13 竖源回归）。
                let fixedH = min(innerW / Metrics.windowAspect, usableH)
                let fittedW = innerW
                let fittedH = max(fixedH, min(Metrics.minPictureHeight, colH))
                self.winW = Self.px(fittedW)
                self.winH = Self.px(fittedH)
                self.winX = 0
                // 居中后再夹进容器：`usableH*centre - fittedH/2` 在
                // fittedH 接近 usableH 时会**算成负数**，窗口顶就跑到列外，
                // 表现为「播放器往上越界、顶部被切掉」。夹到 [0, usableH - fittedH]
                // 之后，最坏情况只是贴顶/贴底，绝不会露到容器之外。
                let centred = usableH * Metrics.landscapeCentre - fittedH / 2
                self.winY = Self.px(min(max(centred, 0), max(usableH - fittedH, 0)))
            } else {
                // 竖屏：**只从 colH / innerW 推导，不再跨来源读屏幕尺寸。**
                //
                // ⛔ 原来这里是 `winY = screenH * portraitTop`（screenH 来自
                // `OneSkin.fixedScreenSize()`），而 `winH = innerW / windowAspect`
                // （innerW 来自列宽）。两个数来自**两个不同来源**，转屏那一刻
                // 它们不同步：
                //   · `UIScreen.bounds` 在旋转动画期间仍报**旧方向**的值；
                //   · 列宽却已经按新方向重算过了。
                // 于是「横切竖」的若干帧里，winY 用的是横屏的屏幕高（小），
                // winH 用的是竖屏的列宽（大）→ 窗口底 = winY + winH 冲出容器，
                // 用户看到的就是**播放器越界**。
                //
                // 现在统一用容器自身的 `colH` 当基准：colH 与 innerW 同源
                // （都来自这一帧的 pictureColumn 尺寸），转屏时一起变、一起稳。
                // 顺带把窗口底夹在 colH 之内 —— 即使 colH 因为动画短暂偏小，
                // 也只是窗口变矮，绝不会溢出到 detailColumn 上。
                // ★★ 2026-11-12 真机实测修正：竖屏也用左 16 / 右 100 内缩。
                //
                // 真 One 外屏竖持（466×678）AX 实测（经真实截图交叉验证）：
                //   视频 x=16  y=43  w=350  h=197
                //   466 − 16(左) − 100(右) = 350 ✓ 精确吻合
                //   350 / (16/9) = 196.9 ≈ 197 ✓
                //
                // 我方旧值 winW = innerW = 464（几乎满宽）、winX = 0，
                // 比真机宽 114pt、左移 16pt。
                // ★★★ 2026-11-12 用户明确要求（覆盖此前「复刻真机」的做法）：
                //
                //   ① 往下一些，避开摄像头
                //   ② **占满宽度**
                //   ③ 长度到「倍速 1x」那个按钮的**上方**
                //
                // 真机实测（外屏竖持 466×678，截图亮度扫描 + AX 双重验证）：
                //   视频 x=16 y=43 w=350 h=197，右边界 366 ⇒ **右侧空 100pt**
                //   播放器控制条（含倍速 1x）y=353~371
                //
                // ⇒ 真机右侧那一大块是浪费的。按用户要求改成满宽 + 拉到控制条：
                //   x = 0        （满宽，不再扣左右内缩）
                //   y = 43       （摄像头下方，与真机一致）
                //   w = innerW   （占满整列）
                //   h = 353 − 43 = 310（拉到控制条上沿）
                self.winW = Self.px(innerW)

                // 顶边：避开摄像头（真机实测 43pt @466 宽）
                let top = max(portraitTopInset ?? (colH * Metrics.portraitTop), 0)

                // 高度 = 列宽 ÷ 竖屏版式比例（内屏 2.146 / 外屏 1.819）。
                //
                // ⛔ 这里原来是「拉到播放器控制条上沿」：
                //       colW < 500 → 控制条硬编码 y=353（外屏真机实测）
                //       否则        → colH × 0.553
                //    两个分支**都不是**由列宽决定的，于是同一块屏会算出不同的窗高：
                //       466 宽：colH=700 → 289，colH=951 → 266
                //       669 宽：colH=700 → 323，colH=951 → 439
                //    后者尤其糟：窗口高度跟着**容器高度**线性变（0.553 倍），
                //    而容器高度在转屏/折叠动画里是连续变化的 —— 窗口会跟着一起胀缩。
                //    这条也是「画框必须是常量、只能由列宽决定」的同一条铁律，
                //    只是漏在竖屏这一支。2026-11-13 与横屏一起收掉。
                //
                // 控制条那 353 的诉求（「长度到控制条上方」）此后由**画面列高度**表达：
                // `pictureHeightOf` 就是 `顶边 + 窗高 + 底部呼吸位`，
                // 胶囊条贴画面列下沿，不再反过来用控制条位置定窗高。
                let wantedH = innerW / Metrics.portraitAspect(forColumnWidth: colW)
                // 容器异常矮（转屏中间帧）时才压扁，绝不让窗口越过底部控件条。
                let limit = max(colH * (1 - Metrics.controlBarRoom) - top, 1)
                self.winH = Self.px(min(wantedH, limit))
                self.winX = 0
                self.winY = Self.px(min(top, max(colH - self.winH, 0)))
            }
        }
    }

    /// 窗口内归一化坐标 → 列坐标
    public func x(_ fx: CGFloat) -> CGFloat { winX + winW * fx }
    public func y(_ fy: CGFloat) -> CGFloat { winY + winH * fy }
}
