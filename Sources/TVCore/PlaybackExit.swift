import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// 播放该怎么退场：保持、转应用外悬浮窗、还是真正登出。
///
/// 为什么需要一条统一规则
/// --------------------
/// 「音频还在后台响，但界面上什么都没有」这个状态本身就是 bug —— 用户没有任何入口
/// 回到那一集，也没有入口关掉它。它出现的原因不是某处写错，而是**三种退场没有统一裁决**：
///
///   1. **留在应用内小窗**：`store.miniPlayerActive == true`。
///   2. **转到应用外悬浮窗**（PiP）：用户上滑回主界面，画面浮起来继续播。
///   3. **真正登出**：既没有应用内小窗、也不该起 PiP —— 此时必须 `stopPlaying()`。
///
/// 这三者是**互斥**的，而此前每一处退场各自猜一遍，于是漏出了第 4 种状态（音频在跑、没有界面）。
/// 本文件把裁决收成一个纯函数：给「现在在什么状态」和「离开了什么」，返回唯一该做的事。
///
/// 两条用户明确提出的边界
/// --------------------
/// · **转屏 / 折叠 / 展开绝不能起 PiP**。那不是「离开 App」，只是换了个版式；
///   把它当成离开，就会「转个横屏飞出一个小窗」。
/// · **上滑回主界面（真正进后台）应当起 PiP**，这是用户的预期，也是 iOS 的惯例。
///
/// 判据的取舍
/// ---------
/// 区分「转屏」与「上滑」不能靠 `scenePhase` 单独判断 —— 旋转时它也可能瞬间变成
/// `.inactive`（下拉通知中心、来电横幅同理）。所以要求**两个条件同时成立**：
/// `scenePhase == .background` **且** 界面确实退到了根（没有观看页在屏幕上）。
/// 旋转永远不满足前者，锁屏进后台但界面没退到根则不满足后者。
public enum PlaybackExit {

    /// 现在播放处于什么展示状态。
    public enum Presentation: String, Sendable {
        /// 画面就在当前页面上（详情页 / 全屏播放器 / One 皮肤）。
        case inline
        /// 应用内小窗（`RootView` 那个可拖动的卡片）。
        case inAppMini
        /// 应用外悬浮窗（PiP）。
        case pictureInPicture
        /// 什么都没有 —— 这种情况不该继续播。
        case hidden

        /// 用户此刻看得到画面吗。
        public var isVisible: Bool { self != .hidden }
    }

    /// 一次退场所面对的事实。全部是**已经观测到的事实**，不含推测。
    public struct Context: Sendable {
        /// App 的 `scenePhase`。`.background` 表示真的退到主界面或锁屏。
        public var isBackground: Bool
        /// 设备的下一帧尺寸是不是刚发生过宽高互换（转屏 / Duo 折叠展开）。
        ///
        /// 注意：折叠与展开**不改变**宽高关系以外的任何东西，所以只要它变了，
        /// 这次退场就一定是「版式变化」而不是「离开 App」。
        public var layoutJustChanged: Bool
        /// 当前页面还有没有挂着一个正在播的画面（`inline`）。
        public var hasInlinePicture: Bool
        /// 应用内小窗是否被用户打开。
        public var miniPlayerOn: Bool
        /// PiP 此刻是否在跑。
        public var pipActive: Bool
        /// 画面这一侧有没有能力起 PiP。
        ///
        /// ⛔ 与「允许不允许」是两件事，必须分开：
        ///   · `pipAllowed`  = 业务上想不想（下载回放不想）
        ///   · `pipPossible` = 技术上能不能（裸 `AVPlayerLayer` 不能）
        ///
        /// One 皮肤用裸 `AVPlayerLayer` 画画面（为了不让 AVKit 抢走布局），
        /// 它**没有** `AVPictureInPictureController` 的宿主，`PictureInPicture.current` 永远是 nil，
        /// 于是 `startCurrent()` 是空操作 —— 那种情况「上滑起悬浮窗」根本不会发生。
        ///
        /// 既然做不到，就**不要假装做到了**：判据返回 `.keep`，让播放留在后台继续（音频还在），
        /// 而不是走进一条什么都不会发生的分支，还让调用方以为已经交给系统了。
        public var pipPossible: Bool
        /// 这个播放是否**允许**起 PiP（本地下载、音频源等不应起）。
        public var pipAllowed: Bool
        /// 用户是否在视频控件里按过「缩成小窗」。
        ///
        /// 与 `miniPlayerOn` 的区别：那个是「小窗现在画不画」，这个是「用户表达过这个意图」。
        /// 缩成小窗后页面被 pop，`miniPlayerOn` 会短暂为 true；但如果用户接着又上滑回主界面，
        /// 意图已经满足过了，不该再起 PiP。
        public var miniIntent: Bool
        /// 「没有任何可见载体」这个状态已经稳定下来了（过了过渡宽限窗）。
        ///
        /// 由调用方维护：载体为空开始计时，超过 ~0.4 s 仍为空才算稳定。
        /// 不这么做就会把 push/pop 与进/退全屏的过渡帧当成登出。
        public var absenceSettled: Bool

        // 显式写出逐成员初始化器：结构体是 public，但自动合成的那个只有 internal，
        /// App 目标（另一个模块）调不到 —— 这正是第一次编译报
        /// 「initializer is inaccessible due to 'internal' protection level」的原因。
        public init(isBackground: Bool, layoutJustChanged: Bool, hasInlinePicture: Bool,
                    miniPlayerOn: Bool, pipActive: Bool, pipPossible: Bool = true,
                    pipAllowed: Bool, miniIntent: Bool, absenceSettled: Bool = true) {
            self.isBackground = isBackground
            self.layoutJustChanged = layoutJustChanged
            self.hasInlinePicture = hasInlinePicture
            self.miniPlayerOn = miniPlayerOn
            self.pipActive = pipActive
            self.pipPossible = pipPossible
            self.pipAllowed = pipAllowed
            self.miniIntent = miniIntent
            self.absenceSettled = absenceSettled
        }
    }

    /// 该做什么。
    public enum Action: String, Sendable {
        /// 什么都不做，继续播。
        case keep
        /// 起应用外悬浮窗（PiP），画面浮到系统层。
        case startPictureInPicture
        /// 停掉 PiP，画面收回本轮。
        case stopPictureInPicture
        /// 真正登出：停播、清 `playing`、清小窗与 PiP。
        case logOut
    }

    /// 现在处于哪种展示态。
    ///
    /// 顺序有意义：PiP 优先（它一定在执行层，`inline` 那一份是被盖住的），
    /// 其次才是页面内、小窗，最后什么都没有。
    public static func presentation(_ context: Context) -> Presentation {
        if context.pipActive { return .pictureInPicture }
        if context.hasInlinePicture { return .inline }
        if context.miniPlayerOn { return .inAppMini }
        return .hidden
    }

    /// 裁决：这一次退场该做什么。
    ///
    /// - Parameter leavingApp: 这次事件的语义是不是「离开 App」。
    ///   由调用方按自己的时序决定（页面 `onDisappear`、`scenePhase` 变化、折叠回调各有各的时机），
    ///   本函数只负责**给定事实后的唯一答案**，不猜时序。
    public static func decide(_ context: Context, leavingApp: Bool) -> Action {
        // ① 先处理 PiP 该收的时候：回到 App 且画面已经在页面上，悬浮窗就该收回去。
        //    不收的话会出现「页面里有画面、系统层又浮一个」的双画面。
        if context.pipActive, !leavingApp, context.hasInlinePicture || context.miniPlayerOn {
            return .stopPictureInPicture
        }
        if context.pipActive { return .keep }

        // ② 版式刚变（转屏 / 折叠 / 展开）—— 一律不碰播放状态。
        //
        //    这是用户明确提过的要求：「不能切个横竖屏、展开个横竖屏就跳出应用外小窗」。
        //    放在 PiP 判定之前，保证这条**优先于**任何「看起来像离开」的信号。
        if context.layoutJustChanged { return .keep }

        // ③ 真的离开 App，且此刻界面上没有画面 —— 起应用外悬浮窗。
        //
        //    条件是「没有画面」而不是「没有小窗」：用户按过缩成小窗、小窗还没画出来时
        //    就已经满足「有画面」了，再起 PiP 会变成两层。
        if leavingApp, context.isBackground,
           context.pipAllowed, context.pipPossible,
           !context.hasInlinePicture, !context.miniPlayerOn {
            return .startPictureInPicture
        }

        // ③b 该起浮但画面那侧没有 PiP 能力（裸 `AVPlayerLayer` 的皮肤路径）：
        //     退到「有载体」的语义 —— 播放继续，音频留在后台，用户回来还能接上。
        //     不做登出：那是把用户的播放直接杀掉，比「浮窗没出来」更糟。
        if leavingApp, context.isBackground, context.pipAllowed, !context.pipPossible {
            return .keep
        }

        // ④ 什么都不显示 —— 登出。
        //
        //    这一条就是「音频还在后台响、界面上一片空白」的修复点：
        //    只要没有任何可见载体，就不允许继续播。
        //
        //    ⚠️ 但「载体为空」有一类是**过渡态**，不是真的登出：push / pop 动画期间、
        //    进 / 退全屏的那一两帧、Duo 折叠重挂图层，载体都会短暂为空。
        //    这些情况直接登出会把正常操作打断（用户在选集页点一下返回，音乐就停了）。
        //    所以要求调用方传 `absenceSettled`：给这个空态一个宽限窗，窗口过后仍为空才登出。
        if !presentation(context).isVisible {
            return context.absenceSettled ? .logOut : .keep
        }

        return .keep
    }
}
