import Foundation
import CoreGraphics

// MARK: - 传感器避让（灵动岛 / 刘海 / 挖孔）

/// 顶栏控件与**传感器遮挡区**（灵动岛、刘海、挖孔）的避让计算。
///
/// 为什么单独抽成纯函数并放进 TVCore：这完全是几何，而它只能用「设备形状矩阵」
/// 才覆盖得全 —— 真机上要换 Duo 内屏/外屏、折叠、横竖、全屏才能碰到，
/// 人工试永远试不全。留在视图层就等于写不了单测。
///
/// ## 为什么 `safeAreaInsets.top` 不够
///
/// `safeAreaInsets.top` 只回答「**最高的**那个遮挡物的下边缘在哪」，
/// 它**不区分水平位置**。于是有两种情况会漏：
///
/// 1. **竖屏灵动岛**：岛只在水平**中间**一段（约 126pt 宽），左右两侧其实完全空着。
///    把整个顶栏统一压下 59pt，两侧控件明明可以更靠上，白白浪费一条；
///    反过来若顶栏某颗控件**正好居中**，它仍然落在岛下面 —— 压的是整条，却不保证那颗躲开。
/// 2. **横屏**：刘海在**左边缘**且是竖向一条，`top` 往往是 0，
///    这时 `safeAreaInsets.top` 完全不报警，最左边那颗返回键直接陷进刘海 ——
///    这正是用户报的「最边缘不能正常点击」。
///
/// 所以避让必须按**两个维度**分别判：垂直是否进了遮挡带的纵向范围，
/// 水平是否与遮挡物的横向范围有交叠。两者同时成立才需要下压。
public enum OneSkinSafeArea {
    /// 传感器遮挡区（屏幕坐标系）。
    public struct Housing: Equatable, Sendable {
        /// 遮挡带的下边缘（pt）。控件上沿低于它就算垂直方向已让开。
        public var bottom: CGFloat
        /// 水平起点（pt）。
        public var left: CGFloat
        /// 水平终点（pt）。
        public var right: CGFloat

        public init(bottom: CGFloat, left: CGFloat, right: CGFloat) {
            self.bottom = bottom
            self.left = left
            self.right = right
        }

        /// 没有遮挡。
        public static let none = Housing(bottom: 0, left: 0, right: 0)

        /// 该遮挡物是否覆盖「水平 [x0, x1] 这段」。
        ///
        /// 用**严格小于**做边界：刚好贴边不算撞上，避免 1pt 误差引起整条重排。
        public func overlaps(_ x0: CGFloat, _ x1: CGFloat) -> Bool {
            guard bottom > 0 else { return false }
            let lo = min(x0, x1), hi = max(x0, x1)
            return hi > left && lo < right
        }
    }

    /// 从屏幕宽高与安全区推出遮挡带。
    ///
    /// - `portrait`：灵动岛/刘海在**顶部居中**，宽度按屏幕宽的固定比例估；
    /// - `landscape`：刘海在**左侧**，是一条竖向缺口，纵向贯穿到 `safeTop`。
    ///
    /// 比例取 0.27（iPhone 灵动岛 126pt ÷ 466pt ≈ 0.27），这是唯一可用的
    /// 静态近似 —— `safeAreaInsets` 本身不暴露遮挡物的横向范围。
    public static func housing(screen: CGSize, safeTop: CGFloat,
                              safeLeft: CGFloat, portrait: Bool) -> Housing {
        // ⛔ 这里原来是一句 `guard safeTop > 0 else { return .none }`，它让**横屏分支整段成了死代码**。
        //
        // 横屏时 `safeAreaInsets.top` 通常是 0（刘海在**左缘**，是竖向缺口），
        // 于是 guard 直接返回 `.none` → `Housing.bottom = 0` →
        // `overlaps` 里的 `guard bottom > 0 else { return false }` 恒 false →
        // 下面那句 `let notch = max(safeLeft, 44)` **永远执行不到**。
        // 用户报的「最边缘不能正常点击」正是这一支没生效造成的
        // —— 函数自己的文档注释（本文件开头第 20–22 行）就写着这个场景，实现却没兑现。
        //
        // 判据修正：**竖屏看 safeTop，横屏看 safeLeft**。两者任一为 0 才算「没有遮挡」。
        if portrait {
            guard safeTop > 0 else { return .none }
        } else {
            // 横屏：遮挡带高度取 safeTop（可能为 0），横向宽度取刘海宽度（至少 44）。
            // 只要刘海有宽度就要让开 —— 不让的话最左那颗按钮就落在缺口里。
            guard safeLeft > 0 || safeTop > 0 else { return .none }
        }
        if portrait {
            // ⚠️ iPhone Duo 的灵动岛是**竖排贴边**的，不是直板机那种「水平居中一条」。
            //
            // `device-facts.md`（mirzaaghazadeh/iphone-duo-skills，取自 Apple 官方材料）：
            //   "The Dynamic Island is redesigned to run **vertically along the side**
            //    of both displays, and expands vertically as Live Activities arrive."
            // 而这里的 `islandWidth = 屏宽 × 0.27` + 水平居中，是**直板 iPhone** 的形状
            // （126pt ÷ 466pt ≈ 0.27）—— 用它给 Duo 算避让带，横向范围整个是错的：
            // 真正的遮挡贴在一侧，中间那块是空的，于是「居中的顶栏被无谓地下压、
            // 而真正压住控件的侧边没让开」。
            //
            // 在 Duo 上（竖持内屏 669 宽、safe 顶 84）宁可**整条顶栏都让开**：
            // 遮挡带取满宽，代价只是顶栏整体下移，但绝不会把控件留在遮挡下面。
            // 这比「猜一个错误的横向范围」安全 —— 后者会漏让。
            //
            // 判断依据用屏宽：Duo 两块屏的短边分别是 466 / 669，都 ≥ 460；
            // 直板机最宽 440。≥460 就按「竖排岛、整宽让开」处理。
            if screen.width >= 460 {
                return Housing(bottom: safeTop, left: 0, right: max(0, screen.width))
            }
            let width = max(0, screen.width)
            let islandWidth = min(width * 0.27, 160)
            let mid = width / 2
            return Housing(bottom: safeTop, left: mid - islandWidth / 2, right: mid + islandWidth / 2)
        }
        // 横屏：缺口贴左缘，宽度取 safeLeft（刘海实测 44–59pt）；safeLeft 为 0 时退回 44。
        //
        // `bottom` 取 `safeTop`，而横屏它常常是 0 —— 那会让 `overlaps` 的
        // `guard bottom > 0` 再次把这条判据废掉。所以这里取一个**有意义的纵向范围**：
        // 刘海是贯穿屏幕左上角的竖向缺口，纵向至少覆盖顶栏身高的量级。
        // 顶栏按钮热区约 44–52pt，取 56 保证「顶栏这一排」全部落在遮挡带纵向范围内。
        let notch = max(safeLeft, 44)
        let bottom = max(safeTop, 56)
        return Housing(bottom: bottom, left: 0, right: notch)
    }

    /// 遮挡带与系统安全区重叠时，**只补差额**。
    ///
    /// `reservedRegions(.occlusion)` 报的矩形下边界是**绝对坐标**（从容器顶算起），
    /// 而系统已经把内容推到了 `safeAreaInsets.top`。两者语义重叠，直接相加 = 推两遍：
    ///
    /// | safeAreaInsets.top | occlusion.top | 直接相加 | 该补 |
    /// |---|---|---|---|
    /// | 84 | 60  | 144 | **0** |
    /// | 84 | 100 | 184 | **16** |
    /// | 0  | 84  | 84  | **84** |
    ///
    /// - Parameters:
    ///   - occlusion: 遮挡带的下边界 / 上边界（绝对坐标）。
    ///   - safe: 系统已给的安全区（同一坐标系）。
    /// - Returns: 还需要额外补的 (top, bottom)；全为零表示安全区已经盖住。
    public static func topUp(occlusion: CGFloat, safe: CGFloat) -> CGFloat {
        max(0, occlusion - safe)
    }

    /// 把一条控件的中心 y 下压到「上沿刚好让开遮挡带」。
    ///
    /// 只有当控件的**水平范围**和遮挡物相交时才下压；不相交就原样返回 ——
    /// 这就是「灵动岛两侧的控件不必陪葬」的判据。
    ///
    /// - Parameters:
    ///   - centreY: 控件原本的中心 y（窗口坐标系）。
    ///   - halfHeight: 控件热区的一半高度。
    ///   - windowTop: 窗口顶边在屏幕坐标系里的位置。
    ///   - x0/x1: 控件在屏幕坐标系里的水平范围。
    ///   - margin: 额外留白。
    public static func clearedCentreY(_ centreY: CGFloat,
                                     halfHeight: CGFloat,
                                     windowTop: CGFloat,
                                     x0: CGFloat,
                                     x1: CGFloat,
                                     housing: Housing,
                                     margin: CGFloat) -> CGFloat {
        guard housing.overlaps(x0, x1) else { return centreY }
        // 控件上沿在屏幕坐标里的位置。
        let topOnScreen = windowTop + centreY - halfHeight
        guard topOnScreen < housing.bottom + margin else { return centreY }
        // 需要下压的量，换算回窗口坐标。
        return centreY + (housing.bottom + margin - topOnScreen)
    }
}
