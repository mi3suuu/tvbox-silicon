#if os(iOS) || os(tvOS)
import SwiftUI
// ⚠️ 本文件在 tvOS 也可编译：只用 CGFloat/CGRect 与 `UIApplication`（tvOS 有）。
import TVCore   // OneSkinSafeArea.topUp（遮挡补量的唯一真源）

// MARK: - 折叠分界层（对齐 One 1.7.0 的 FoldSplit 体系）
//
// 为什么需要这一层
// ----------------
// 此前形态判定是「推导链」：
//     duoExpanded(size class + 宽度) → sideways(interfaceOrientation) → 布局分支
// 每一环都是**间接推断**，而 Duo 折叠/展开会同时改变多个输入，
// 于是同一时刻可能推出互相矛盾的形态 —— 表现为「切个形态就错位 / 控件漂移」。
//
// One 1.7.0 的做法（静态实证见 `Docs/duo/One-1.7.0-旋转与折叠适配审查.md`）：
// 它**不推导**，而是把折叠直接表示成几何：
//     struct FoldGap { var minX: CGFloat; var maxX: CGFloat }   // 折叠是 x 区间
//     struct FoldSplitLayout { spacing; fold: FoldGap?; containerWidth }  // : Layout, Animatable
//     struct VideoDetailPage { var __division: State<CGRect?> }  // 分界区矩形，nil = 未折叠
// 且它**完全不用** reservedRegions / onHingeChange / ArrangementView
// （`strings` 零命中），全靠自己这 7 个 SwiftUI 类型。
//
// 本文件复刻其中三件最关键、且与我们的问题直接相关的：
//   1. `FoldGap`        —— 折叠线的 x 区间（唯一真源）
//   2. `FoldSplitLayout` —— 同时是 Layout + Animatable：折叠线移动是**动画参数**，
//                          视图树不重建，所以形态切换不跳变
//   3. `OcclusionInsets` —— 遮挡按 top/bottom 两条 inset（Duo 展开时遮挡在左右，
//                         用 safeAreaInsets 一把梭会错方向）
//
// 与 One 的差异：我们保留 `UIInterfaceOrientation` 驱动的 split/fullBleed 分支
// （那是真正的「横持」概念），但**折叠带本身的几何**改由这一层提供，
// 不再靠 `duoExpanded` 这个布尔二次推断。

/// 折叠线在容器坐标系里的 x 区间。`minX == maxX` 表示折叠带宽度为 0。
///
/// One 的原始定义只有这两个字段（`swift-dump` L184 附近），
/// 语义是「屏幕上那一条不可用的竖带」。用区间而不是中心线 + 宽度，
/// 是因为左右边界各自可能被系统胶囊/圆角吃掉，用区间能同时表达不对称。
struct FoldGap: Equatable, Sendable {
    var minX: CGFloat
    var maxX: CGFloat

    var width: CGFloat { max(0, maxX - minX) }
    var centerX: CGFloat { (minX + maxX) / 2 }
    var isVertical: Bool { width > 0 }

    static let none = FoldGap(minX: 0, maxX: 0)

    /// 0.5pt 容差比较（对齐 B 站 `if (fabs(m - applied) <= 0.5) return;` 的幂等门）。
    ///
    /// ⛔ 原来 `apply` 里是 `fold != nextFold` —— 合成 `==` 精确到浮点位，
    ///   半折态折缝随铰链角**连续移动**，0.25s 一次的轮询每次都能落出一个
    ///   新值：`foldGap` 变 → `oneSkinShape` 重判 → 整页重排，4Hz 持续抖动。
    ///   0.5pt 是「肉眼看不见、但明显折动仍跟手」的量级（同 B 站实测常数）。
    static func isSame(_ a: FoldGap?, _ b: FoldGap?, tolerance: CGFloat = 0.5) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?):
            return abs(x.minX - y.minX) <= tolerance && abs(x.maxX - y.maxX) <= tolerance
        default: return false
        }
    }

    /// 从 `reservedRegions(kind: .division)` 的矩形换出来。
    ///
    /// iOS 27.1 起 SwiftUI 有 `GeometryProxy.reservedRegions(kind:)`
    /// （`ReservedRegion.Kind.division` / `.occlusion`，`@available(anyAppleOS 27.1)`），
    /// 这是系统给的**权威分界线**。拿不到时（更早系统 / 非折叠设备）返回 `.none`，
    /// 调用方据此退回原推导 —— 不是「假设没有折叠」，而是「这条信息不可用」。
    init(minX: CGFloat, maxX: CGFloat) {
        self.minX = minX
        self.maxX = maxX
    }

    init?(divisionRects: [CGRect]) {
        // 只取竖直方向的带；水平分界（书本/帐篷半折）由下面的 `horizontalBand` 处理。
        let vertical = divisionRects.filter { $0.height > $0.width }
        guard let widest = vertical.max(by: { $0.width < $1.width }), widest.width > 0 else {
            return nil
        }
        self.init(minX: widest.minX, maxX: widest.maxX)
    }

    /// 横向折痕（书本 / 帐篷半折）：折痕是**一条横带**，上下各半屏。
    ///
    /// `FoldGap` 本身只表达 x 区间（竖向折），所以横折另立一个结构而不是硬塞进
    /// `minX/maxX` —— 两者语义不同，混用会让「摊开」和「半折」互相污染。
    struct HorizontalBand: Equatable, Sendable {
        var minY: CGFloat
        var maxY: CGFloat

        var height: CGFloat { max(0, maxY - minY) }
        var centerY: CGFloat { (minY + maxY) / 2 }
        var isHorizontal: Bool { height > 0 }
        /// 折痕中心是否落在容器中部。
        ///
        /// ⛔ 2026-11-12 实测修正：原来用 `0.25 < ratio < 0.75`，
        /// 而真机/模拟器实测的三个折缝中心比是 **0.600 / 0.554 / 0.507**
        /// —— 全部落在该区间内，等于「只要有折缝就判半折」，包括摊开态。
        ///
        /// 正确的物理事实：**摊开时折缝在正中（ratio≈0.5），半折时折缝偏移**。
        /// 但实测显示摊开态的 0.600 与半折态的 0.554 只差 0.046（44pt），
        /// 单靠这个比例分不开。
        ///
        /// 所以这个判据不再单独决定形态，只作为「折缝存在且在中部」的粗筛；
        /// 摊开/半折的真判据改用**折缝绝对位置表**（见 `OneSkinShape` 的实测锚点）。
        func splitsContainer(_ containerHeight: CGFloat) -> Bool {
            guard isHorizontal, containerHeight > 0 else { return false }
            let ratio = centerY / containerHeight
            // 放宽到 0.15–0.85：只要折缝确实横穿中部区域就算「参与了分割」，
            // 交给上层用绝对位置区分摊开/半折，不再在这里武断二分。
            return ratio > 0.15 && ratio < 0.85
        }

        /// 0.5pt 容差比较 —— 与 `FoldGap.isSame` 同一套幂等门，理由见那里。
        static func isSame(_ a: HorizontalBand?, _ b: HorizontalBand?,
                           tolerance: CGFloat = 0.5) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (x?, y?):
                return abs(x.minY - y.minY) <= tolerance && abs(x.maxY - y.maxY) <= tolerance
            default: return false
            }
        }
    }

    /// 从同一批 division 矩形里取横向那条。没有则 nil。
    static func horizontalBand(in divisionRects: [CGRect]) -> HorizontalBand? {
        let horizontal = divisionRects.filter { $0.width > $0.height }
        guard let thickest = horizontal.max(by: { $0.height < $1.height }), thickest.height > 0 else {
            return nil
        }
        return HorizontalBand(minY: thickest.minY, maxY: thickest.maxY)
    }
}

/// 遮挡（挖孔 / 摄像头 / 系统胶囊）在容器四边上的内缩。
///
/// One 用 `OcclusionAvoider { let band: CGFloat; var _insets: State<OcclusionInsets> }`
/// + `GeometryValueReader` 读出来。这里保留同样的形状，但**必须是四边**：
/// Duo 合盖时挖孔在**顶部**，摊开时在**右上角** —— 只建 top/bottom 两条，
/// 摊开态那个孔会被判成「贴顶 → 内容整体下推」，而它其实贴在右缘。
///
/// ⛔ 2026-11-12 修正（P1-8）：此前只有 `top` / `bottom`，且
///   `init(occlusionRects:containerHeight:)` 里用 `containerHeight * 0.33 / 0.67`
///   两条线判「贴顶还是贴底」。三个问题：
///   ① 没有 left / right —— 展开态挖孔在侧边，被当成顶部下推（顶栏整体多推一段）；
///   ② `containerHeight` 传的是 `screen.bounds.height`（Duo 上**不随方向交换**），
///      横持时容器 ≈466 而那个值 ≈951，两条线全部错位，贴底的会被判成贴顶；
///   ③ 矩形本身是探针局部坐标，带内容原点偏移（见 P0-1）。
///   现在：四边 + 由调用方传入**容器尺寸**（不再跨源读 screen）+ 角部规则。
struct OcclusionInsets: Equatable, Sendable {
    var top: CGFloat
    var bottom: CGFloat
    var left: CGFloat
    var right: CGFloat

    static let zero = OcclusionInsets(top: 0, bottom: 0, left: 0, right: 0)

    /// 从 occlusion 矩形换出来：每条边取「所有贴该边的矩形里侵入最深的那一个」。
    init(top: CGFloat, bottom: CGFloat, left: CGFloat = 0, right: CGFloat = 0) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }

    /// - Parameters:
    ///   - occlusionRects: 系统报的遮挡矩形（应与 `containerSize` 同一坐标系）。
    ///   - containerSize: **容器**尺寸（不是物理屏）。横持时它的高是 466 而不是 951。
    init(occlusionRects: [CGRect], containerSize: CGSize) {
        let w = max(containerSize.width, 1)
        let h = max(containerSize.height, 1)
        // 「贴着这条边」的判定容差。取 8% 而不是固定 8pt：
        // 矩形坐标带内容原点偏移（顶部安全区可达 60pt），固定小容差会漏判；
        // 8% 在 951 高上是 76pt、466 高上是 37pt，足够吸收偏移又不会把
        // 「屏中部的东西」误判成贴边。
        let tolY = max(24, h * 0.08)
        let tolX = max(24, w * 0.08)

        var top: CGFloat = 0, bottom: CGFloat = 0, left: CGFloat = 0, right: CGFloat = 0
        for rect in occlusionRects {
            let touchesTop = rect.minY <= tolY
            let touchesBottom = rect.maxY >= h - tolY
            let touchesLeft = rect.minX <= tolX
            let touchesRight = rect.maxX >= w - tolX

            // 形状先验：这条矩形**可能是什么**。
            //   · `canBeSide`   —— 不宽于 30%：可能是一条竖着的侧边遮挡（挖孔/竖胶囊）；
            //   · `canBeTB`     —— 不高于 30%：可能是一条横着的上/下遮挡（状态栏/手势条）。
            // ⛔ 必须双向排除，否则「横贯整宽的顶部状态栏带」同时满足
            //    `touchesLeft && touchesRight`，于是 left = 整宽、right = 整宽，
            //    内容区被两边各挤掉一整个屏宽 —— 直接消失。
            let canBeSide = rect.width <= w * 0.30
            let canBeTB = rect.height <= h * 0.30
            // ★ 角部规则：既贴上下、又贴左右的**小孔**（展开态右上角摄像头）只算侧边。
            //
            // 算成 top 会让整页内容下推一个孔高（历史现象：展开后顶栏按钮位置错乱）；
            // 算成 right 只是让内容避开右缘那一条 —— 那正是孔所在的位置。
            let isCornerHole = canBeSide && (touchesLeft || touchesRight)
            if touchesTop, canBeTB, !isCornerHole {
                top = max(top, rect.maxY)
            }
            if touchesBottom, canBeTB, !isCornerHole {
                bottom = max(bottom, h - rect.minY)
            }
            if touchesLeft, canBeSide {
                left = max(left, rect.maxX)
            }
            if touchesRight, canBeSide {
                right = max(right, w - rect.minX)
            }
        }
        self.init(top: top, bottom: bottom, left: left, right: right)
    }
}

// MARK: - 遮挡 → 几何层
extension OcclusionInsets {
    /// 交给 `OneSkinGeometryDriver` 的形状（P1-8 / 16.1）。
    ///
    /// 两套类型长得一样但语义不同：本文件的 `OcclusionInsets` 是**读数**，
    /// `OneSkinOcclusionInsets` 是**几何输入**（带 0.5pt 幂等门）。
    /// 转换只写在这一切，别在各处手写 `OneSkinOcclusionInsets(left:right:top:bottom:)`。
    var geometryInsets: OneSkinOcclusionInsets {
        OneSkinOcclusionInsets(left: left, right: right, top: top, bottom: bottom)
    }
}

// MARK: - 折叠感知的双列布局

/// 把「左 / 右」两块按折叠带排开。`fold == nil` 时退化为普通 HStack。
///
/// 同时实现 `Layout` 与 `Animatable` —— 这一点是 One 的关键设计
/// （`protocol conformance One.FoldSplitLayout : SwiftUI.Layout` / `: SwiftUI.Animatable`）：
/// 折叠线移动时，SwiftUI 会对 `animatableData` 做插值并逐帧重跑 `placeSubviews`，
/// **子视图 identity 不变**。于是：
///   · 播放器 layer 不会被撕掉重挂（不会触发 AVKit 误判「离开 App」而起 PiP）；
///   · 控件不会因为视图树重建而跳位。
/// 我们此前的 `if shape == .split { HStack } else { VStack }` 每次形态变化都换视图树，
/// 正是「切换时 UI 错绘 + 控件漂移」的结构性来源。
/// ⚠️ 必须写成 `SwiftUI.Layout`：本工程 `App/DesignSystem/Tokens/Layout.swift` 里
/// 有一个自己的 `enum Layout`（放 gutter / maxWidth 常量），它会把 SwiftUI 的
/// `Layout` 协议遮蔽掉 —— 直接写 `: Layout` 会报
/// `inheritance from non-protocol type 'Layout'`，连带 `Subviews` 也找不到。
struct FoldSplitLayout: SwiftUI.Layout, Animatable {
    var spacing: CGFloat
    var fold: FoldGap?
    var containerWidth: CGFloat

    /// 动画参数。折叠带的位置与宽度一起插值，所以「折到一半」也是合法中间态。
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get {
            AnimatablePair(
                AnimatablePair(fold?.minX ?? 0, fold?.maxX ?? 0),
                spacing
            )
        }
        set {
            if fold != nil {
                fold = FoldGap(minX: newValue.first.first, maxX: newValue.first.second)
            }
            spacing = newValue.second
        }
    }

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: SwiftUI.LayoutSubviews,
                      cache: inout ()) -> CGSize {
        let width = proposal.width ?? containerWidth
        let height = proposal.height ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: SwiftUI.LayoutSubviews,
                       cache: inout ()) {
        guard subviews.count >= 2 else {
            if let only = subviews.first {
                only.place(at: bounds.origin,
                           proposal: ProposedViewSize(bounds.size))
            }
            return
        }
        let leading = subviews[0]
        let trailing = subviews[1]

        // 没有折叠带：普通左右分栏，中间留 spacing。
        guard let fold, fold.isVertical else {
            let half = (bounds.width - spacing) / 2
            leading.place(at: bounds.origin,
                          proposal: ProposedViewSize(width: half, height: bounds.height))
            trailing.place(at: CGPoint(x: bounds.minX + half + spacing, y: bounds.minY),
                           proposal: ProposedViewSize(width: half, height: bounds.height))
            return
        }

        // 有折叠带：左右两块各自贴到折叠带外侧，带内不放内容。
        // 这就是「内容避开折痕」的准确表达 —— 不是给整个容器加 padding，
        // 而是把两块**分别**推到折痕两边。
        let leadingWidth = max(0, fold.minX - bounds.minX)
        let trailingStart = fold.maxX
        let trailingWidth = max(0, bounds.maxX - trailingStart)

        leading.place(at: bounds.origin,
                      proposal: ProposedViewSize(width: leadingWidth, height: bounds.height))
        trailing.place(at: CGPoint(x: trailingStart, y: bounds.minY),
                       proposal: ProposedViewSize(width: trailingWidth, height: bounds.height))
    }
}

// MARK: - 折叠带读取

/// 读数探针：**0×0 尺寸**地读 `reservedRegions`。
///
/// ⛔ 为什么不能用裸 `GeometryReader { Color.clear }` 挂在 `.background` 上：
/// 真机实测（Duo 外屏，`-qaSection home -qaPage detail:qa2:1 -qaOneSkin`）——
/// `GeometryReader` 会**撑满父视图并向兄弟层提出 ProposedViewSize**，
/// 皮肤分支（One / 哔哩哔哩）拿到退化提议后整页不构建，表现为纯白
/// （4×4 网格采样 15/16 命中项目纯白判据）；而原版 `upstreamWatchBody`
/// 因外层多一层 `AnyLayout` 没被影响，所以只有两个皮肤白屏。
///
/// 现在把读数层压成 0×0：它拿不到真实尺寸也没关系 —— 我们要的是
/// **父容器**的分界区矩形，`reservedRegions` 报的是相对容器坐标系的，
/// 与探针自身尺寸无关。
struct FoldRegionProbe: View {
    /// 容器尺寸（调用方传入的 `layoutSize` / 窗口尺寸）。
    ///
    /// ⛔ 不要在这里读 `screen.bounds`：Duo 上它是**物理固定值**，不随方向交换，
    ///    横持时容器高 466 而它报 951 —— 遮挡矩形的「贴顶/贴底」判定会全部错位（P1-8）。
    var containerSize: CGSize
    var onChange: ([CGRect], [CGRect]) -> Void

    // 探针自身是 0×0，`proxy.size` 不会变 —— 只能借外部信号判断「该重读了」。
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    /// 低频轮询源。
    ///
    /// ⛔ 必须是 `static`：写成 body 里的 `Timer.publish(...).autoconnect()`
    ///    会在**每次 body 求值**时新建一条定时器（订阅换一个就丢一个），
    ///    既多分配又让节流形同虚设。
    private static let poll = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    /// 当前窗口所在屏的尺寸（静态值，不随旋转动画逐帧变化）。
    private var screenSize: CGSize {
        UIApplication.shared.appWindowScene?.screen.bounds.size
            ?? UIApplication.shared.appScreenBounds.size
    }

    var body: some View {
        if #available(iOS 27.1, tvOS 27.1, *) {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { read(proxy) }
                    // ⛔ 原来这里写的是 `.onChange(of: proxy.size)` —— **它永远不会触发**。
                    //
                    // 探针被 `.frame(width: 0, height: 0)` 压成零尺寸，所以
                    // `proxy.size` 恒为 `.zero`，永远不变，这个回调形同虚设。
                    // 整个折叠检测只剩 `onAppear` 那一次，于是：
                    //   · 进页面时是摊开的 → foldGap 一直 nil，后来折到半折也不更新；
                    //   · 进页面时是半折的 → foldGap 一直有值，摊开后也不会清掉。
                    // 表现就是「半折形态识别不到 / 摊开了还按半折排版」。
                    //
                    // 换成一个**会真的变化**的信号：
                    //   · `verticalSizeClass` —— 折叠/展开会翻转（compact ⇄ regular）；
                    //   · 屏幕尺寸 —— 换屏/分屏会变；
                    //   · `scenePhase` —— 进出前台兜底重读一次。
                    // 三者任一变化就重读。重读是幂等的（`apply` 里逐项比对后才写回）。
                    // ⛔ 上面这三个信号在 Duo 折叠时**全都不变**（实测 987/987 全 nil）：
                    //   · `verticalSizeClass` —— 内屏横竖都报 regular×compact，折叠不翻转；
                    //   · `screenSize` —— screen.bounds 是物理固定值，折叠不变；
                    //   · `scenePhase` —— 只在切前后台时变。
                    // 所以 foldGap 实际只在 onAppear 读过一次，之后永久冻结。
                    //
                    // ★ 折叠没有可靠的 SwiftUI 通知（`onHingeChange` 也未生效），
                    //   只能用**低频轮询**：每 0.5s 触发一次 read。
                    //   `read` 本身是幂等的（`apply` 逐项比对后才写回），
                    //   同一个值不会引起 body 重算，因此不会形成反馈环。
                    //
                    // ★ 2026-11-12（P1-7）两个修正：
                    //   ① **轮询降到 0.5s 且只在前台读**。
                    //      原来 0.25s 常开：只要选集页在栈里就跑，进后台、被 sheet
                    //      盖住也每 250ms 查一次 `reservedRegions`（还带两条 DEBUG
                    //      拼串）。四态都白付这个代价。现在 `scenePhase != .active`
                    //      直接跳过 —— 定时器本身几乎零成本，贵的是那次系统查询。
                    //   ② **`apply` 改成 0.5pt 容差比较**（`FoldGap.isSame`）。
                    //      原来 `fold != nextFold` 是精确相等，半折态折缝随角度
                    //      连续移动 → 每 0.25s 都落一个新值 → 形态重判 → 整页重排，
                    //      4Hz 持续抖动。有容差之后，轮询频率不再是抖动来源。
                    .onChange(of: verticalSizeClass) { _, _ in read(proxy) }
                    .onChange(of: scenePhase) { _, _ in read(proxy) }
                    .onReceive(Self.poll) { _ in
                        guard scenePhase == .active else { return }
                        read(proxy)
                    }
            }
            .frame(width: 0, height: 0)
            .clipped()
            .allowsHitTesting(false)
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    @available(iOS 27.1, tvOS 27.1, *)
    private func read(_ proxy: GeometryProxy) {
        #if DEBUG
        // 直接打印系统返回的原始区域数，确认是「系统不给」还是「我们解析错」。
        let d = proxy.reservedRegions(kind: .division)
        let o = proxy.reservedRegions(kind: .occlusion)
        OneSkinProbe.log("FOLDRAW division=\(d.count) occlusion=\(o.count) frames=\(d.map { "\(Int($0.frame.minX)),\(Int($0.frame.maxX)),\(Int($0.frame.minY)),\(Int($0.frame.maxY))" }.joined(separator: "|"))")
        #endif
        onChange(proxy.reservedRegions(kind: .division).map(\.frame),
                 proxy.reservedRegions(kind: .occlusion).map(\.frame))
    }
}

/// 铰链状态一变化就让探针重读。低版本系统上是空操作。
///
/// 同时把**铰链状态本身**回传出去（`onStatus`）——
/// 这是判「摊开 vs 半折」唯一权威的信号：
///   `DeviceHinge.status` 只有 `closed / partiallyOpen / fullyOpen` 三档
///   （已核 `SwiftUICore.swiftinterface` L16799-16826），而折缝的**位置**不可靠：
///   摊开态实测折缝中心比就有 0.507 / 0.554 / 0.600 三种（斜着拿手机都会变），
///   拿「偏离正中多少」猜半折必然误判（P0-1）。
private struct RereadFoldOnHingeChange: ViewModifier {
    let onChange: () -> Void
    /// `nil` = 系统没给（旧系统 / 非折叠设备）。
    let onStatus: (Bool?) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 27.1, tvOS 27.1, *) {
            content.onHingeChange { old, new in
                // 只在**折痕状态**真的变了时重读；纯角度抖动（半折时手抖）不重读，
                // 否则每一帧都要重查 reserved regions。
                if old.hinge?.status != new.hinge?.status {
                    onChange()
                    onStatus(new.hinge.map { $0.status == .partiallyOpen })
                }
            }
        } else {
            content
        }
    }
}

struct FoldRegionReader: ViewModifier {
    /// 探针重建计数器：铰链状态变化时 +1，`.id()` 随之改变 → 探针重建 → `onAppear` 重读。
    ///
    /// 为什么要绕这一圈：探针被压成 0×0，`proxy.size` 永远不变，
    /// 没有可观察的尺寸信号；而「摊开 ⇄ 半折」尺寸和 size class 也都不变。
    /// 用 `.id()` 强制重建是最直接的「请重新执行一次读取」。
    @State private var foldReadTick: Int = 0

    @Binding var fold: FoldGap?
    /// 横向折痕（书本 / 帐篷半折）。有它才是「半折」形态。
    @Binding var horizontalFold: FoldGap.HorizontalBand?
    @Binding var occlusion: OcclusionInsets
    /// 铰链是否处于 **partiallyOpen**。`nil` = 系统没报（旧系统 / 非折叠设备）。
    ///
    /// 这是判半折的**权威**信号，比「折缝偏离正中」可靠得多（P0-1）。
    @Binding var hingePartiallyOpen: Bool?
    /// 容器尺寸：遮挡矩形的「贴哪条边」必须按**容器**判，不能按物理屏（P1-8）。
    var containerSize: CGSize

    func body(content: Content) -> some View {
        content
            // ★ 铰链状态变化时立刻重读（BUG-Q 的关键补丁）。
            //
            // 「摊开 ⇄ 半折」这一对转换里，**尺寸和 size class 都不变**
            // （都是内屏 regular×regular、都是 669×951），只有**折痕本身**出现或消失。
            // 所以靠 `verticalSizeClass` / 屏幕尺寸 / `scenePhase` 都抓不到，
            // 必须用铰链信号 —— 这正是 `onHingeChange` 存在的意义
            // （`@available(anyAppleOS 27.1, *)`，已核 SDK swiftinterface）。
            //
            // `duo-media` / `adaptive-layout` 也强调：铰链角只用于**交互/信号**，
            // 布局仍由 reserved regions 决定 —— 这里正是这么用的：
            // 只用它当「该重读 reserved regions 了」的触发，不拿角度算布局。
            .modifier(RereadFoldOnHingeChange(onChange: {
                // 铰链变了 → 让探针重新读一次。
                // 探针是 0×0，没有尺寸可观察，所以用这个计数器当驱动。
                foldReadTick &+= 1
            }, onStatus: { open in
                // 只有在**结论真的变了**时才写，避免无谓的 body 重算。
                if hingePartiallyOpen != open { hingePartiallyOpen = open }
            }))
            .background(alignment: .topLeading) {
                // 计数器变化 → 重建探针 → `onAppear` 再次执行 → 重读
                FoldRegionProbe(containerSize: containerSize) { division, occlusionRects in
                    apply(division: division, occlusion: occlusionRects)
                }
                .id(foldReadTick)
            }
    }

    /// 把读到的原始矩形写进状态。只在真的变了时写回 ——
    /// 否则几何回调会把状态搅成自激环（这个坑 `OneSkin` 的 frozenBox 也踩过）。
    ///
    /// ⛔ 「变了」用 **0.5pt 容差**判（`FoldGap.isSame` / `HorizontalBand.isSame`），
    ///    不是精确相等：半折时折缝随铰链角连续移动，精确比较等于每轮询一次
    ///    就写一次状态 → 整页重排（P1-7）。
    private func apply(division: [CGRect], occlusion occlusionRects: [CGRect]) {
        let nextFold = FoldGap(divisionRects: division)
        let nextHorizontal = FoldGap.horizontalBand(in: division)
        // ★ 遮挡按**容器**尺寸判边（旧代码传的是 `appScreenBounds.height`，
        //   Duo 上不随方向交换，横持时整条判据错位 —— P1-8）。
        let nextOcclusion = OcclusionInsets(occlusionRects: occlusionRects,
                                            containerSize: containerSize)
        if !FoldGap.isSame(fold, nextFold) { fold = nextFold }
        if !FoldGap.HorizontalBand.isSame(horizontalFold, nextHorizontal) {
            horizontalFold = nextHorizontal
        }
        if occlusion != nextOcclusion { occlusion = nextOcclusion }
    }
}

extension View {
    /// 读折叠带与遮挡。两个绑定都可为 nil / zero —— 表示「这条信息不可用」。
    func readFoldRegion(fold: Binding<FoldGap?>,
                        horizontalFold: Binding<FoldGap.HorizontalBand?>,
                        occlusion: Binding<OcclusionInsets>,
                        hingePartiallyOpen: Binding<Bool?>,
                        containerSize: CGSize) -> some View {
        modifier(FoldRegionReader(fold: fold, horizontalFold: horizontalFold,
                                  occlusion: occlusion,
                                  hingePartiallyOpen: hingePartiallyOpen,
                                  containerSize: containerSize))
    }
}

// MARK: - 遮挡补量（只补系统安全区没盖住的那一段）

/// 把 `reservedRegions(.occlusion)` 报出的遮挡带**补到**系统安全区之上，
/// 而不是在其之上再叠一遍。
///
/// ## 为什么需要它（BUG-O）
///
/// `OcclusionInsets.top` 是 occlusion 矩形的**绝对下边界**（`rect.maxY`，从容器顶算起）。
/// 系统**已经**把内容推到了 `safeAreaInsets.top`。两者在同一坐标系里语义重叠：
///
/// | safeAreaInsets.top | occlusion.top | 直接叠 | 实际该补 |
/// |---|---|---|---|
/// | 84 | 60  | 144 | **0**（安全区已经盖住了） |
/// | 84 | 100 | 184 | **16**（只差这一段） |
/// | 0  | 84  | 84  | **84**（安全区没盖住，全额补） |
///
/// 前两行就是「竖屏控件被推得过分靠下 / 画面被压扁」的来源。
///
/// 全屏是沉浸态，不补（画面要铺满）。
struct OcclusionTopUp: ViewModifier {
    let insets: OcclusionInsets
    let fullScreen: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        let safe = UIApplication.shared.appWindowScene?.keyWindow?.safeAreaInsets
            ?? .zero
        // ⛔ 用 `OneSkinSafeArea.topUp` 这个**唯一真源**，不要在这里自己再写一遍
        //    `max(0, a - b)`。上一版就是这么写的 —— 于是同一套算术存在两份，
        //    其中一份（这个 modifier）没有单测覆盖，改真源时它会静默不同步。
        //
        // ★ 四边都补（P1-8）：遮挡模型已经是四边了，这里只补上下就等于
        //   把展开态「右上角挖孔」算出来的 right 白扔了。左右同样只补
        //   「系统安全区没盖住的那一段」。
        let topUp = fullScreen ? 0 : OneSkinSafeArea.topUp(occlusion: insets.top, safe: safe.top)
        let bottomUp = fullScreen ? 0 : OneSkinSafeArea.topUp(occlusion: insets.bottom, safe: safe.bottom)
        let leftUp = fullScreen ? 0 : OneSkinSafeArea.topUp(occlusion: insets.left, safe: safe.left)
        let rightUp = fullScreen ? 0 : OneSkinSafeArea.topUp(occlusion: insets.right, safe: safe.right)
        content
            .safeAreaPadding(.top, topUp)
            .safeAreaPadding(.bottom, bottomUp)
            .safeAreaPadding(.leading, leftUp)
            .safeAreaPadding(.trailing, rightUp)
        #else
        content
        #endif
    }
}

extension View {
    /// 补遮挡带与系统安全区的差额；`fullScreen` 时不补。
    func occlusionTopUp(_ insets: OcclusionInsets, fullScreen: Bool) -> some View {
        modifier(OcclusionTopUp(insets: insets, fullScreen: fullScreen))
    }
}

#endif
