#if os(iOS)
import SwiftUI
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
        /// 折痕中心是否落在容器中部（书本/帐篷的特征）。
        func splitsContainer(_ containerHeight: CGFloat) -> Bool {
            guard isHorizontal, containerHeight > 0 else { return false }
            let ratio = centerY / containerHeight
            return ratio > 0.25 && ratio < 0.75
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

/// 遮挡（挖孔 / 摄像头 / 系统胶囊）在容器上、下两侧的内缩。
///
/// One 用 `OcclusionAvoider { let band: CGFloat; var _insets: State<OcclusionInsets> }`
/// + `GeometryValueReader` 读出来。这里保留同样的形状（top/bottom 两个数），
/// 因为**方向是有意义的**：Duo 合盖时挖孔在顶部，展开时在右上角，
/// 统一塞进 `safeAreaInsets` 会让内容在展开态被多推半个屏。
struct OcclusionInsets: Equatable, Sendable {
    var top: CGFloat
    var bottom: CGFloat

    static let zero = OcclusionInsets(top: 0, bottom: 0)

    /// 从 occlusion 矩形换出来：取所有矩形里最靠上的下边界与最靠下的上边界。
    init(top: CGFloat, bottom: CGFloat) {
        self.top = top
        self.bottom = bottom
    }

    init(occlusionRects: [CGRect], containerHeight: CGFloat) {
        var top: CGFloat = 0
        var bottom: CGFloat = 0
        for rect in occlusionRects {
            // 贴顶部的那条 → 决定 top 内缩
            if rect.minY <= containerHeight * 0.33 {
                top = max(top, rect.maxY)
            }
            // 贴底部的那条 → 决定 bottom 内缩
            if rect.maxY >= containerHeight * 0.67 {
                bottom = max(bottom, containerHeight - rect.minY)
            }
        }
        self.init(top: top, bottom: bottom)
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
    var onChange: ([CGRect], [CGRect]) -> Void

    // 探针自身是 0×0，`proxy.size` 不会变 —— 只能借外部信号判断「该重读了」。
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    /// 当前窗口所在屏的尺寸（静态值，不随旋转动画逐帧变化）。
    private var screenSize: CGSize {
        UIApplication.shared.appWindowScene?.screen.bounds.size
            ?? UIApplication.shared.appScreenBounds.size
    }

    var body: some View {
        if #available(iOS 27.1, *) {
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
                    .onChange(of: verticalSizeClass) { _, _ in read(proxy) }
                    .onChange(of: screenSize) { _, _ in read(proxy) }
                    .onChange(of: scenePhase) { _, _ in read(proxy) }
            }
            .frame(width: 0, height: 0)
            .clipped()
            .allowsHitTesting(false)
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    @available(iOS 27.1, *)
    private func read(_ proxy: GeometryProxy) {
        onChange(proxy.reservedRegions(kind: .division).map(\.frame),
                 proxy.reservedRegions(kind: .occlusion).map(\.frame))
    }
}

/// 铰链状态一变化就让探针重读。低版本系统上是空操作。
private struct RereadFoldOnHingeChange: ViewModifier {
    let onChange: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { old, new in
                // 只在**折痕状态**真的变了时重读；纯角度抖动（半折时手抖）不重读，
                // 否则每一帧都要重查 reserved regions。
                if old.hinge?.status != new.hinge?.status { onChange() }
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
            }))
            .background(alignment: .topLeading) {
                // 计数器变化 → 重建探针 → `onAppear` 再次执行 → 重读
                FoldRegionProbe { division, occlusionRects in
                    apply(division: division, occlusion: occlusionRects)
                }
                .id(foldReadTick)
            }
    }

    /// 把读到的原始矩形写进状态。只在真的变了时写回 ——
    /// 否则几何回调会把状态搅成自激环（这个坑 `OneSkin` 的 frozenBox 也踩过）。
    private func apply(division: [CGRect], occlusion occlusionRects: [CGRect]) {
        let nextFold = FoldGap(divisionRects: division)
        let nextHorizontal = FoldGap.horizontalBand(in: division)
        // 遮挡的容器高度用**屏幕**高度：探针自身是 0×0，拿不到有意义的 height。
        let nextOcclusion = OcclusionInsets(occlusionRects: occlusionRects,
                                            containerHeight: UIApplication.shared.appScreenBounds.height)
        if fold != nextFold { fold = nextFold }
        if horizontalFold != nextHorizontal { horizontalFold = nextHorizontal }
        if occlusion != nextOcclusion { occlusion = nextOcclusion }
    }
}

extension View {
    /// 读折叠带与遮挡。两个绑定都可为 nil / zero —— 表示「这条信息不可用」。
    func readFoldRegion(fold: Binding<FoldGap?>,
                        horizontalFold: Binding<FoldGap.HorizontalBand?>,
                        occlusion: Binding<OcclusionInsets>) -> some View {
        modifier(FoldRegionReader(fold: fold, horizontalFold: horizontalFold, occlusion: occlusion))
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
        let topUp = fullScreen ? 0 : OneSkinSafeArea.topUp(occlusion: insets.top, safe: safe.top)
        let bottomUp = fullScreen ? 0 : OneSkinSafeArea.topUp(occlusion: insets.bottom, safe: safe.bottom)
        content
            .safeAreaPadding(.top, topUp)
            .safeAreaPadding(.bottom, bottomUp)
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
