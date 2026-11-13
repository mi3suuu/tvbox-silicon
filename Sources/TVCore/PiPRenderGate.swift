import Foundation

// MARK: - 画中画出帧闸（纯函数，可测）

/// 「这一条 `AVPlayerLayer` 现在该不该挂 player」的**唯一判定**。
///
/// ## 为什么必须抽成纯函数
///
/// 这个判定原来写在 `App/MobilePlayer.swift` 的 `PictureInPicture.shouldRender` 里，
/// 是 iOS-only 文件，进不了测试目标。它的失败形态极其昂贵：
///
///   · 返回 false 时，`OneSkinFixedPlayerLayer.updateUIView` 会执行
///     `view.update(player: nil)` —— 把 player 从 layer 上**静默摘掉**；
///   · 不报错、不打日志、`AVPlayerItem.status` 仍是 `.readyToPlay`、
///     `presentationSize` 仍正确、播放时间**照常前进**；
///   · 用户看到的就只是「压暗的海报底」，看起来与「片源没画面」「窗口算错」
///     完全同形 —— 这两种假说此前各自消耗了数轮排查，且都被证伪。
///
/// 所以这里把判定从视图层剥出来：输入是六个布尔/可选事实，输出是唯一的判决。
/// 任何一支写错都能被 `PiPRenderGateTests` 直接撞出来，不需要真机。
///
/// ## 两条浮窗通路共用一个进程级标记
///
/// 这是本类型存在的核心原因。App 里有两条互不相干的画中画通路：
///
///   ① **自建**（One / 哔哩哔哩皮肤）：`AVPictureInPictureController(contentSource: .init(playerLayer:))`。
///      起浮时同时写 `isActive = true` **和** `sourceLayer = <那一条 layer>`。
///   ② **AVKit 托管**（全屏播放器）：`AVPlayerViewController` 自己管浮窗。
///      起浮回调里只能写 `isActive = true` —— AVKit **不把它的画面层交给我们**，
///      `sourceLayer` 保持 nil。
///
/// 于是「`isActive == true` + `sourceLayer == nil`」有两种**语义相反**的来源：
///
///   · AVKit 真浮着 → 我们的内嵌层**必须继续渲染**（AVKit 不占用它）；
///   · 标记是僵尸（controller 已被回收）→ **必须清掉**，否则永久挡死画面。
///
/// 旧实现把两者合并成同一支、按「僵尸」处理，后果是：全屏播放器起过一次浮窗后，
/// 全局标记被错误清零，而 One 皮肤那一侧同时读同一个全局量 —— 内嵌画面被摘掉、
/// 占位撤回，item 依然 ready、时间依然走。用 `avkitHostedActive` 把这条语义显式化，
/// 两种来源才分得开。
public enum PiPRenderGate {

    /// 判定的全部输入。**没有视图对象**，所以可以在任何地方构造与断言。
    public struct State: Equatable, Sendable {
        /// 进程级「有浮窗在跑」标记（两条通路共用）。
        public var isActive: Bool
        /// 这次浮窗是 AVKit 托管的（`AVPlayerViewController`），而不是我们自建的 controller。
        public var avkitHostedActive: Bool
        /// 全进程是否存在一个活跃的自建 `AVPictureInPictureController`。
        public var hasController: Bool
        /// 全局内容源槽位是否已经被填上（`sourceLayer != nil`）。
        public var hasSource: Bool
        /// 待判定的这条 layer 是否**就是**那个内容源。
        public var sourceMatchesLayer: Bool
        /// 内容源那条 layer 是否已经脱离视图树且不再持有 player
        /// （`superlayer == nil && player == nil`）——它画不出任何东西了。
        public var sourceDetached: Bool

        public init(isActive: Bool,
                    avkitHostedActive: Bool,
                    hasController: Bool,
                    hasSource: Bool,
                    sourceMatchesLayer: Bool,
                    sourceDetached: Bool) {
            self.isActive = isActive
            self.avkitHostedActive = avkitHostedActive
            self.hasController = hasController
            self.hasSource = hasSource
            self.sourceMatchesLayer = sourceMatchesLayer
            self.sourceDetached = sourceDetached
        }
    }

    public enum Verdict: Equatable, Sendable {
        /// 没有浮窗在跑：本层照常渲染。绝大多数帧走这里。
        case noPiP
        /// 浮窗由 AVKit 托管：它不占用我们的 `AVPlayerLayer`，本层必须继续渲染。
        case avkitHosted
        /// 本层就是浮窗的内容源：浮窗画的就是它，必须继续渲染。
        case mine
        /// 标记说在跑，但全进程没有任何控制器 → 僵尸标记，清掉。
        case staleNoController
        /// 控制器在、内容源槽位却空了 → 标记与事实不符，清掉。
        case staleNoSource
        /// 内容源那条 layer 已经脱离视图树 → 僵尸，清掉。
        case staleDetachedSource
        /// 浮窗**真的**在另一条 layer 上跑：本层必须让出 player，否则浮窗只剩声音。
        case yieldedToOtherLayer

        /// 这条 layer 现在该不该绑 player。
        public var renders: Bool {
            switch self {
            case .noPiP, .avkitHosted, .mine,
                 .staleNoController, .staleNoSource, .staleDetachedSource:
                return true
            case .yieldedToOtherLayer:
                return false
            }
        }

        /// 是否顺手清掉进程级僵尸标记。
        ///
        /// ⚠️ 只有**证明**失效的三支才清。`yieldedToOtherLayer` 是合法的「让出」，
        /// 清掉它会把浮窗的画面抢回来 —— 那正是这个闸最初要防的事（浮窗只剩声音）。
        public var clearsGlobals: Bool {
            switch self {
            case .staleNoController, .staleNoSource, .staleDetachedSource: return true
            default: return false
            }
        }

        /// 日志用短名。与 `PICGATE dec=` 字段逐字对应。
        public var name: String {
            switch self {
            case .noPiP:               return "NOPIP"
            case .avkitHosted:         return "AVKIT"
            case .mine:                return "MINE"
            case .staleNoController:   return "STALE-nocontroller"
            case .staleNoSource:       return "STALE-nosource"
            case .staleDetachedSource: return "STALE-detached"
            case .yieldedToOtherLayer: return "YIELD"
            }
        }
    }

    /// 唯一的判定实现。
    ///
    /// 顺序即优先级，不可重排：②必须排在③之前（AVKit 那条通路根本没有 sourceLayer，
    /// 先比 `===` 会永远落到「不同一条」上）；④⑤⑥必须排在⑦之前
    /// （僵尸标记与「合法让出」在输入上无法区分，只能靠「有没有控制器」先分流）。
    public static func verdict(_ s: State) -> Verdict {
        // ① 没有浮窗：本层照常渲染。
        if !s.isActive { return .noPiP }

        // ② 本层就是内容源：浮窗画的就是它，无条件渲染。
        //
        // ⛔ 这一支必须排在 AVKit 那支**之前**。两条浮窗通路的标记是进程级共享的，
        // 极端时序下（自建刚才起浮、AVKit 那边还留着上一帧的 true）两者可以同时为真。
        // 「本层就是内容源」是**更硬的事实**（可以逐位比对 layer 身份），
        // 而 `avkitHostedActive` 只是一个布尔标记 —— 硬事实优先。
        if s.sourceMatchesLayer { return .mine }

        // ③ AVKit 托管的浮窗不占用我们的 layer。
        if s.avkitHostedActive { return .avkitHosted }

        // ④ 说在跑，但全进程没有控制器 → 铁定是僵尸标记。
        //
        // ⛔ 这一支旧实现**只写在注释里、没写进代码**。
        // 结果是：`current == nil` 时，只要 `sourceLayer` 还「看起来正常」
        // （在视图树里、还挂着 player），本层就被永久判成「该让出」，
        // 画面再也回不来，而且没有任何日志。
        if !s.hasController { return .staleNoController }

        // ⑤ 控制器在，内容源槽位却空 → 标记与事实不符。
        if !s.hasSource { return .staleNoSource }

        // ⑥ 内容源那条 layer 已经脱离视图树 → 它画不出浮窗。
        if s.sourceDetached { return .staleDetachedSource }

        // ⑦ 浮窗真的在另一条 layer 上跑：本层让出。
        return .yieldedToOtherLayer
    }
}
