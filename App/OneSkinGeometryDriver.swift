#if os(iOS)
import SwiftUI

// MARK: - One 播放页几何驱动（哔哩哔哩折叠屏适配架构移植）
//
// 参考实现：哔哩哔哩 9.18.0（实测数据，非推断）
//   · `__cstring "GeometryReader"` → **0 命中**；`mas_*` selector 66 个
//     ⇒ 正文页/直播间/迷你窗纯 UIKit + Auto Layout(Masonry)，不用 GeometryReader
//   · `+sizeClassOfWidth:` @0x102692d3c 按宽度硬断点分三档并**缓存**：
//       w ≥ 840 → 3(expanded)；w ≥ 600 → 2(regular)；else → 1(compact)
//   · `swift5_fieldmd` @0x119f83a94 字段表：
//       `hingeObserver, currentHingeStatus, appliedRightInset`
//     ⇒ **「离散状态」与「已应用值」成对缓存**，状态没跨档就不重排
//   · `applyFoldablePlayerAvoidanceWithRightMargin:` @0x110e6f828：
//       `if (fabs(m - applied) <= 0.5) return;`  ← 幂等门（常数 0.5 实测）
//   · `p_handleHingeStatusChange:` @0x1149c70d0 门控 `(new-2) <= 2`
//     ⇒ 只有 {2,3,4} 三档需要重排，{0,1} 静默
//
// 移植后的三条铁律：
//   ① 布局只吃**枚举 + 常量**，绝不吃连续尺寸
//   ② 形态判据 = 宽度硬断点 → 三档枚举，结果缓存
//   ③ 每次变更过**幂等门**（abs 差 ≤ 0.5）+ 相等检查，不满足就完全不碰布局

// MARK: - 宽度分档（B 站 600 / 840 死区）

enum OneSkinWidthClass: Int, Equatable {
    case compact = 1
    case regular = 2
    case expanded = 3

    init(width: CGFloat) {
        if width >= 840 { self = .expanded }
        else if width >= 600 { self = .regular }
        else { self = .compact }
    }

    /// B 站 `+isWideScreen` 只认最宽一档。
    var isWideScreen: Bool { self == .expanded }
}

// MARK: - 折叠态（B 站 HingeStatus 5 值，{2,3,4} 是活跃档）

enum OneSkinHingeStatus: Int, Equatable {
    case unavailable = 0
    case flat = 1
    case halfOpen = 2
    case folded = 3
    case transitioning = 4

    /// 对齐 B 站 `(new - 2) <= 2` 门控：只有 {2,3,4} 需要重排。
    var needsRelayout: Bool {
        self == .halfOpen || self == .folded || self == .transitioning
    }
}

// MARK: - 遮挡内缩（对应 B 站 `+horizontalOcclusionInsets`）

struct OneSkinOcclusionInsets: Equatable {
    var left: CGFloat = 0
    var right: CGFloat = 0
    var top: CGFloat = 0
    var bottom: CGFloat = 0

    static let zero = OneSkinOcclusionInsets()

    /// 幂等门用：任一维变化超过阈值才算真变化。
    func differs(from other: Self, by threshold: CGFloat = 0.5) -> Bool {
        abs(left - other.left) > threshold
            || abs(right - other.right) > threshold
            || abs(top - other.top) > threshold
            || abs(bottom - other.bottom) > threshold
    }
}

// MARK: - 几何快照（纯算术，来源全是离散量）

struct OneSkinGeometry: Equatable {
    /// 物理屏幕尺寸（`screen.bounds`，Duo 上不随方向交换）。
    var screenSize: CGSize
    /// 窗口安全区。
    var safeInsets: EdgeInsets
    /// 遮挡内缩。
    var occlusion: OneSkinOcclusionInsets
    /// 折叠态。
    var hinge: OneSkinHingeStatus
    /// 版式形态。
    var shape: OneSkinShape
    /// 是否全屏。必须参与 `box` 的计算 —— 见 `box` 里「与修饰符链逐项对齐」那段。
    ///
    /// 放在**最后**并给默认值：这样既有构造点（`Only shape`）不用一次改全。
    var fullScreen: Bool = false

    var widthClass: OneSkinWidthClass { .init(width: screenSize.width) }

    /// 排版该按横还是竖 —— **半折必须是「跟容器」而不是「钉死在枚举上」**。
    ///
    /// ⛔ 16.4：`OneSkinShape.isLandscape` 对 `.halfFold` 恒为 false（这是对的：
    ///    半折不是「横屏版式」，它没有左右双列）。但 `box` / `ratioBase` 是
    ///    **几何**，它问的是「屏幕现在哪条边长」。
    ///    机器转 90° 后半折（趴着时折缝变横），容器是 951×669，`box` 却按
    ///    669×951 给：宽少 282、高多 282 → 整页越界、下半控制台被推出屏幕。
    ///    `screenSize` 来自 `keyWindow.bounds`（随方向交换），是这里唯一可用的离散量。
    var layoutLandscape: Bool {
        guard shape == .halfFold else { return shape.isLandscape }
        guard screenSize.width > 1, screenSize.height > 1 else { return false }
        return screenSize.width > screenSize.height
    }

    /// 排版基准盒 —— **只由上面这些离散量算出**，不读任何容器。
    ///
    /// 扣减规则与 `oneSkinBody` 上的 `.ignoresSafeArea(edges: [.top, .horizontal])`
    /// 严格对齐：
    ///   · 顶部与左右**已被忽略** → 不扣
    ///   · **底部没被忽略** → 扣 `bottom` 安全区
    /// `screen.bounds` 是物理全屏（含状态栏/Home 条），直接用会让内容高出可用区，
    /// 外屏竖持实测溢出 129pt —— 这就是「一进页面尺寸不对 + 推移」的根。
    /// 比例坐标的乘法基准 = **物理全屏**（含状态栏/Home），与 One 截图逐像素实测一致。
    ///
    /// ⛔ 不要和下面的 `box` 混用。两者是**不同**的量：
    ///   · `ratioBase` —— 「0.868 / 0.928 / 0.091 这些比例乘什么」。
    ///     One 原版按整块屏幕排版（截图 669×951 = 物理全屏），
    ///     所以比例基准必须是全屏，否则全部坐标等比缩小。
    ///   · `box` —— 「内容最多能占多少」，必须扣掉底部让位，否则溢出成环。
    ///
    /// 混成一个值的两种错误都实测过：
    ///   · 都用全屏 678 → 比例对，但内容比容器高 70pt → 溢出 → 重协商 → 环（每秒 200+ 次）
    ///   · 都用扣除 608 → 环断了，但所有比例坐标缩 10.3%，胶囊条偏上 60.8pt
    var ratioBase: CGSize {
        let long = max(screenSize.width, screenSize.height)
        let short = min(screenSize.width, screenSize.height)
        return layoutLandscape
            ? CGSize(width: long, height: short)
            : CGSize(width: short, height: long)
    }

    var box: CGSize {
        let long = max(screenSize.width, screenSize.height)
        let short = min(screenSize.width, screenSize.height)
        // 竖持：短边为宽、长边为高；横持：长边为宽、短边为高。
        let w = layoutLandscape ? long : short
        let h = layoutLandscape ? short : long

        // ★ 必须和 `oneSkinBody` 的修饰符链**逐项对齐**，一项不能漏：
        //
        //   stage(...)
        //     .ignoresSafeArea(edges: fullScreen ? .all : [.top, .horizontal])
        //
        // 现版本**没有**任何 `.padding(.bottom/.trailing)` 了
        // （`VideoDetailView.swift:1851` 明确删掉，改成「让位量由本函数算」），
        // 所以内容能占多少完全由 `ignoresSafeArea` 的边决定：
        //   · 顶 / 左右：被忽略 → 不扣（内容就铺到状态栏下面，控件自己避让）
        //   · **底部：没被忽略 → 必须扣 `safeInsets.bottom`**
        //   · 全屏：四边全忽略 → 一个都不扣
        //
        // ⛔ 2026-11-12 修正：这里此前**只扣了 `occlusion.bottom`**，而
        //    `occlusion` 恒为 `.zero`（`occlusionDidChange` 全仓 0 调用），
        //    于是 `box.height` 恒等于物理高，比真实容器多出底部整条安全区：
        //      外屏竖持 678 容器只有 644 → 溢出 34
        //      外屏横持 466 容器只有 446 → 溢出 20
        //    表现：底部胶囊条偏低、最后一排卡片被 Home 指示条吃掉。
        //    而紧邻的注释却写着「678 − 34 − 36 = 608」，**文档与代码相反** ——
        //    下一个改这块的人一定会照着注释把扣减方向改错。
        //
        // 现在的对齐口径（外屏竖持）：678 − 34 = **644** = 真实容器高。
        // 旧注释里的额外 36 是当年 stage 上那条 `.padding(.bottom, 36)`，
        // 那条 padding 已经删除，36 不再从这里扣 —— 胶囊是浮层，
        // 它自己的让位由 `chipBar` 的 `barBottom` 负责，不再缩内容盒。
        //
        // 顶部/左右**故意不扣**：`.ignoresSafeArea(.top/.horizontal)` 就是让内容
        // 铺到状态栏下面 —— 这正是 B 站竖屏播放页的做法（画面溢出状态栏），
        // 控件自己再按 safeInsets 避让。
        // ★★★ 几何的扣减必须和 `oneSkinBody` 的修饰符链**完全一致**。
        //     多扣一次、少扣一次，都会让所有控件整体错位 —— 这是反复踩的坑。
        //
        // ★ 2026-11-12 坐标系裁决（captain 亲自 OCR + 列黑度剖面复核）：
        //   1–6 号横持截图的**正立帧** = PIL rotate(90) CCW（≡ ocr 原图 270）；
        //   rotate(-90) / ROTATE_270 是 180° 倒立帧（ccw == rot180(cw)）。
        //   正立帧实测：播放器列 x0..467.667 / 纯黑缝 x467.667..523（55.333pt）
        //   / 详情列 x523..951（428pt），三段和 = 951.000 铺满全屏。
        //   x904..951 在正立帧有墨迹（luma 31.86），**不是纯黑让位带**；
        //   47pt 是倒立帧把左缘 letterbox 暗带（x0..47, luma 3.05）镜像误读。
        //   ⇒ 旧文档「右留 47 / 内容 0..904」是倒立帧坐标，rightReserve 归零。
        //   HStack 子视图顺序 pictureColumn→detailColumn 保持不变，只换宽度。
        //
        // 【对齐结论】
        //   · 横持：宽 = 屏宽 951（不让位），高 = 屏高 669 − 底部安全区
        //   · 竖持：宽 = 屏宽，高 = 屏高 − 底部安全区
        //   · 全屏：宽高 = 屏宽高（四边都不扣）
        //   · `oneSkinBody` 上**不能**再加 `.padding(.bottom/.trailing)` ——
        //     那些 padding 会把几何已经算好的尺寸再缩一次（双重扣减）。
        let rightReserve: CGFloat = 0
        // 全屏（`.ignoresSafeArea(.all)`）时底部也被忽略，一个点都不扣。
        //
        // ⛔ 安全区与遮挡是**同一坐标系里语义重叠**的两个量，不能相加（16.1）：
        //    `occlusion.bottom` 是「从容器底往上被挡住多高」，`safeInsets.bottom`
        //    是「系统已经让开多高」。遮挡大多落在安全区里（Home 条区域），
        //    相加 = 扣两遍 → 内容凭空矮一条。
        //    取 `max` 才是「至少要让这么多」。
        let bottomReserve: CGFloat = fullScreen ? 0 : max(safeInsets.bottom, occlusion.bottom)

        let usableW = max(w - rightReserve - occlusion.left - occlusion.right, 1)
        let usableH = max(h - bottomReserve, 1)
        return CGSize(width: usableW, height: usableH)
    }

    /// 容差相等：亚点级抖动不算变化（对齐 B 站 0.5 阈值）。
    static func == (a: Self, b: Self) -> Bool {
        abs(a.screenSize.width - b.screenSize.width) < 1
            && abs(a.screenSize.height - b.screenSize.height) < 1
            && !a.occlusion.differs(from: b.occlusion)
            && a.hinge == b.hinge
            && a.shape == b.shape
            && a.fullScreen == b.fullScreen
            && abs(a.safeInsets.bottom - b.safeInsets.bottom) < 1
    }
}

// MARK: - 驱动（三道幂等门，对齐 `currentHingeStatus` + `appliedRightInset`）

@MainActor
final class OneSkinGeometryDriver: ObservableObject {
    @Published private(set) var geometry: OneSkinGeometry

    /// 上一次已应用的折叠态（B 站 `currentHingeStatus`）。
    private var lastHinge: OneSkinHingeStatus = .unavailable
    /// 上一次已应用的遮挡（B 站 `appliedRightInset`）。
    private var lastOcclusion: OneSkinOcclusionInsets = .zero

    init(shape: OneSkinShape) {
        geometry = OneSkinGeometry(screenSize: OneSkin.fixedScreenSize(),
                                   safeInsets: Self.currentSafeInsets(),
                                   occlusion: .zero,
                                   hinge: .unavailable,
                                   shape: shape,
                                   fullScreen: false)
    }

    static func currentSafeInsets() -> EdgeInsets {
        guard let ins = UIApplication.shared.appWindowScene?.windows.first?.safeAreaInsets
        else { return EdgeInsets() }
        return EdgeInsets(top: ins.top, leading: ins.left,
                          bottom: ins.bottom, trailing: ins.right)
    }

    /// B 站 `p_handleHingeStatusChange:` —— 门①相等检查，门②活跃档门控。
    func hingeDidChange(to status: OneSkinHingeStatus) {
        guard status != lastHinge else { return }          // 门①
        let wasActive = lastHinge.needsRelayout
        lastHinge = status
        // B 站 `(new-2) <= 2`：进入与离开活跃档都要重排，中间档位静默。
        guard status.needsRelayout || wasActive else { return }   // 门②
        rebuild()
    }

    /// B 站 `_foldableRelayoutForOcclusion` —— 门②幂等（abs ≤ 0.5）。
    func occlusionDidChange(to insets: OneSkinOcclusionInsets) {
        guard insets.differs(from: lastOcclusion) else { return }  // 门②
        lastOcclusion = insets
        rebuild()
    }

    /// 形态变化（旋转 / 合拢 / 全屏）。
    func shapeDidChange(to newShape: OneSkinShape) {
        guard newShape != geometry.shape else { return }
        rebuild(shape: newShape)
    }

    /// 全屏 / 退出全屏。
    ///
    /// 必须让 driver 知道：全屏时 `oneSkinBody` 是 `.ignoresSafeArea(.all)`，
    /// 四边都不扣；非全屏底部要扣安全区（见 `OneSkinGeometry.box`）。
    /// 这是**离散**事件（两个值），一步到位，不做插值。
    func fullScreenDidChange(to value: Bool) {
        guard value != geometry.fullScreen else { return }
        rebuild(fullScreen: value)
    }

    /// 屏幕尺寸变化（Split View / PiP 压窄）。
    func screenDidChange() { rebuild() }

    /// **不落状态**地按指定形态现算一份快照（首帧用）。
    ///
    /// ⛔ 16.7：`geoDriver` 是用 `shape: .column` 建立的，`onAppear` 才改成真实形态。
    ///    以横屏 / 展开宽屏直接进页面时，第一帧 `box` 是 669×951，
    ///    而 `stage` 已按横屏排 → 首帧越界 + 闪一下。
    ///    `body` 里发现 driver 还没跟上时，用这个方法现算一次（纯算术、不写状态），
    ///    下一帧 `onAppear/onChange` 落地后两者一致。
    func preview(shape: OneSkinShape, fullScreen: Bool) -> OneSkinGeometry {
        OneSkinGeometry(screenSize: OneSkin.fixedScreenSize(),
                        safeInsets: Self.currentSafeInsets(),
                        occlusion: lastOcclusion,
                        hinge: lastHinge,
                        shape: shape,
                        fullScreen: fullScreen)
    }

    /// 门③整体相等检查 —— 不满足就完全不碰布局。
    private func rebuild(shape: OneSkinShape? = nil, fullScreen: Bool? = nil) {
        let next = OneSkinGeometry(screenSize: OneSkin.fixedScreenSize(),
                                   safeInsets: Self.currentSafeInsets(),
                                   occlusion: lastOcclusion,
                                   hinge: lastHinge,
                                   shape: shape ?? geometry.shape,
                                   fullScreen: fullScreen ?? geometry.fullScreen)
        guard next != geometry else { return }             // 门③
        geometry = next
    }
}
#endif
