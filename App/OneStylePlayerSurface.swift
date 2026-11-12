import SwiftUI
import AVKit

// MARK: - [mi3s] 二开：用 AVPlayerViewController 承载画面（对齐 One 的播放机制）

/// One 的播放页用 `AVPlayerViewController` 承载画面，PiP 由 AVKit 自己托管。
/// 我们用 `AVPlayerLayer` + 自建 `AVPictureInPictureController`，于是每次折叠/转向/切页
/// 换 layer 时，AVKit 都误判成「用户离开 App」并弹一次 PiP —— 同一集播两遍。
///
/// 这个文件把**画面载体**换成 `AVPlayerViewController`，拿到 One 的播放机制：
///   - PiP 由 AVKit 托管，不再有换 layer 的误触发；
///   - `canStartPictureInPictureAutomaticallyFromInline` 可以安全打开；
///   - Now Playing、远程控制、AirPlay 归 AVKit 管。
///
/// ## AVKit 的真实约束（已核对 iOS 27.1 SDK 头文件）
///
/// `AVPlayerViewController` 只暴露三个 PiP 相关的**属性**：
/// ```
/// allowsPictureInPicturePlayback
/// canStartPictureInPictureAutomaticallyFromInline
/// ```
/// 以及 `AVPlayerViewControllerDelegate` 的回调（Will/Did Start/Stop、failed、restoreUI）。
/// **它不暴露 `AVPictureInPictureController`，也没有 `startPictureInPicture()`。**
///
/// 所以：
///   - 自动浮起 = 打开 `canStartPictureInPictureAutomaticallyFromInline`，离开 App 时 AVKit 自己起；
///   - 手动按钮 = 没有 AVKit 提供的入口，只能由我们自己的 controller 服务（见 `PictureInPicture`）。
///
/// 本文件因此只负责「画面 + 自动 PiP + 状态汇报」，按钮仍走原有通道。
///
/// 只用于 iOS：Mac/tvOS 仍走原来的 `PlayerLayerView`。
#if os(iOS)

/// 画面：一个 `AVPlayerViewController`，关掉它自带的控件，只借它的画面与 PiP 能力。
///
/// 关掉 `showsPlaybackControls` 是必须的 —— 我们的播放页有一整套自绘控件（进度、倍速、
/// 弹幕、字幕、手势），AVKit 的控件叠上来会打架。我们要的只是「它的画面 + 它的 PiP」。
struct OneStylePlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity
    /// 允许 AVKit 在离开 App 时自动浮起 —— 这是 One 的行为。
    let automaticPiP: Bool
    /// 把 PiP 的开始/结束报给我们的协调器，让页面里的占位与按钮状态跟着走。
    let pip: PictureInPicture

    /// 承接 `AVPlayerViewControllerDelegate` 的 PiP 回调，转给 `PictureInPicture`。
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        weak var pip: PictureInPicture?

        /// AVKit 的回调不保证在主线程，`PictureInPicture` 是 `@MainActor`，跳一下再报。
        nonisolated private func report(_ active: Bool) {
            let pip = self.pip
            Task { @MainActor in pip?.report(active: active) }
        }

        func playerViewControllerWillStartPictureInPicture(_ controller: AVPlayerViewController) {
            report(true)
        }
        func playerViewControllerDidStopPictureInPicture(_ controller: AVPlayerViewController) {
            report(false)
        }
        func playerViewController(_ controller: AVPlayerViewController,
                                  failedToStartPictureInPictureWithError error: Error) {
            report(false)
        }
        func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(
            _ controller: AVPlayerViewController
        ) -> Bool {
            // 浮起后不要自动关掉这个播放器：回到 App 时画面要留在页面上。
            false
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.pip = pip
        return coordinator
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = context.coordinator
        // 我们的页面自己画一切；AVKit 的控件层一出现就会抢手势，也会在 PiP 里多画一套。
        controller.showsPlaybackControls = false
        controller.videoGravity = gravity
        controller.allowsPictureInPicturePlayback = true
        // ⛔ 重挂载窗口内（折叠 / 展开 / 转屏 / 进出自绘页）必须压成 false。
        //
        // 原生皮肤走 AVKit 的 `AVPlayerViewController`，它的这个开关不在
        // `PictureInPicture.registry` 里（那是自建 controller），
        // 所以 `suspendAutomaticFloating()` 关不到它 —— 由全局闸补上。
        // 不补的话：Duo 折叠一次 = inline layer 离屏一次 = AVKit 判成「用户离开 App」
        // = 画面在自己家里飞出一个应用外小窗。
        controller.canStartPictureInPictureAutomaticallyFromInline =
            automaticPiP && !PictureInPicture.isAutomaticFloatingSuspended
        // Now Playing 由我们自己的 session 负责（它有更完整的标题/集数/进度）。
        controller.updatesNowPlayingInfoCenter = false
        controller.view.backgroundColor = .clear
        pip.register(host: controller)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.pip = pip
        if controller.player !== player { controller.player = player }
        if controller.videoGravity != gravity { controller.videoGravity = gravity }
        let wanted = automaticPiP && !PictureInPicture.isAutomaticFloatingSuspended
        if controller.canStartPictureInPictureAutomaticallyFromInline != wanted {
            controller.canStartPictureInPictureAutomaticallyFromInline = wanted
        }
        pip.register(host: controller)
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        controller.delegate = nil
        coordinator.pip?.register(host: nil)
    }
}

#endif
