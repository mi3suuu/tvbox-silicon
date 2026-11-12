import Foundation
import CoreGraphics

// MARK: - 任意界面可用的旋转 / 合拢 / 展开

/// 「任何界面都能直接旋转、合拢、展开」的**统一决策层**。
///
/// 为什么需要它：这三个动作原来只存在于观看页的控件条里 ——
/// 控件条只在 `OneSkinChrome` / `MobilePlayer` / `BiliPortraitPage` 这些
/// **播放界面**内渲染，于是用户在任何非播放界面（首页、发现、下载、设置…）
/// 都无法旋转，也没有合拢/展开的入口。
///
/// 这里把「在当前界面，这个动作意味着什么」收成一个纯函数，
/// 让全局入口（手势 / 工具栏 / 菜单）只负责调用，不各自判断：
/// 各写一遍判据必然分叉 —— 这正是之前「横屏没有菜单栏、竖屏又有」的成因。
///
/// ## 为什么旋转要看 `interfaceOrientation` 而不是尺寸
///
/// `screen.bounds` / `window.bounds` 在旋转动画期间**都会滞后**
/// （实测 Fig-clone 横屏时 window.bounds 仍报 466×678）。
/// 用宽高比判断方向会在临界点反复翻转，请求方向也会算反 ——
/// 用户看到的是「点旋转键转不回去」。`interfaceOrientation` 是离散信号，转一次跳一档。
public enum PlayerChromeAction {
    /// 旋转：按**当前方向**反向转。
    public enum Rotation: Equatable, Sendable {
        case toLandscape
        case toPortrait

        public var target: Rotation { self == .toLandscape ? .toPortrait : .toLandscape }
    }

    /// 由「当前是否横屏」推出这次点击要去哪儿。
    ///
    /// - Parameter currentlyLandscape: 来自 `interfaceOrientation` 的离散值。
    public static func rotation(currentlyLandscape: Bool) -> Rotation {
        currentlyLandscape ? .toPortrait : .toLandscape
    }

    /// 由 `UIInterfaceOrientation.isLandscape` 语义的原始值推出，避免调用方各写一遍 switch。
    ///
    /// 传入 `.landscapeLeft` / `.landscapeRight` / `.portrait` / `.portraitUpsideDown` /
    /// `.unknown` 对应的整数（UIKit 原始值），这里只区分「横 / 非横」。
    public static func rotation(fromInterfaceOrientationRawValue raw: Int) -> Rotation {
        // UIInterfaceOrientation: unknown=0, portrait=1, portraitUpsideDown=2,
        // landscapeLeft=3, landscapeRight=4
        let isLandscape = raw == 3 || raw == 4
        return rotation(currentlyLandscape: isLandscape)
    }

    /// 合拢 / 展开：在「看画面为主」与「看详情为主」之间翻。
    ///
    /// 与旋转不同，它**没有跨页语义** —— 只对拥有双列版式的界面有意义。
    /// 因此显式区分「当前界面是否支持」，而不是硬给一个结果：
    /// 不支持时返回 `nil`，全局入口据此不显示该按钮，而不是点了没反应。
    public static func fold(supported: Bool, currentlyFolded: Bool) -> Bool? {
        guard supported else { return nil }
        return !currentlyFolded
    }

    /// 方向解锁：用户在任何界面点「旋转」时，必须先确认设备方向锁不会把请求吃掉。
    ///
    /// 播放器以外的界面通常仍受系统方向锁约束（用户在控制中心开了竖屏锁定）。
    /// 这时 `requestGeometryUpdate` 会被系统忽略，用户看到的就是「点了旋转没反应」。
    /// 返回 `true` 表示调用方应当提示用户「已尝试旋转，但系统方向锁仍开启」。
    public static func needsUnlockNotice(orientationLockEnabled: Bool) -> Bool {
        orientationLockEnabled
    }
}
