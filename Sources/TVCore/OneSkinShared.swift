import Foundation
import AVFoundation
import CoreGraphics

/// The parts of the One skin that more than one platform needs.
///
/// `App/OneSkin.swift` is an iOS-only view layer (it is built on `UIView` / `UIViewRepresentable`
/// and the iOS-only `PictureInPicture`), so the whole file is behind `#if os(iOS)`. But four of the
/// things it declares are consumed by files that **do** build on macOS and tvOS — the cross-source
/// probe result, the two `UserDefaults` keys the settings screens write, and the fit-mode enum the
/// Bilibili skin reuses. Keeping those inside the guarded file made macOS/tvOS fail with
/// `cannot find 'OneSkinLineSample' / 'OneSkin'`, which is why they live here instead.
/// **One 皮肤全部 `UserDefaults` 键名的唯一真源（single source of truth）。**
///
/// 口径（2026-11-13 定）：**全量对齐，不做平台子集。**
///
/// 为什么不按「tvOS 只用得到哪几个」裁剪：
///   · 裁剪后必须维护一份「某键为什么 tvOS 不需要」的清单，而这份清单没有机器校验，
///     它会随需求漂移 —— 那就是「一套状态两套键」这个缺陷族的复发入口（本项目已出三例）；
///   · 全部收在这里的边际成本只是几个字符串常量（编译期字面量，零运行期开销）；
///   · 收全之后 `App/OneSkin.swift` 里**一个键名字面量都不剩**，只剩对这里的引用，
///     于是「两边字面量分叉」在结构上不可能发生，而不是靠断言在运行期去发现。
///
/// ⚠️ 键名是**落盘契约**：改字符串 = 所有用户已存的皮肤偏好静默回落到默认值。
///    `Scripts/audit-oneskin-keys.sh` 把这份字面量钉住，改键必须同时改那个脚本并有意识地过。
public enum OneSkinKeys {
    /// The skin switch itself. `@AppStorage` reads and writes this one value everywhere.
    public static let enabledKey = "oneSkinEnabled"
    /// Picture fit mode (fit / fill / cover / stretch). The older Boolean `fillKey` is still read.
    public static let fitModeKey = "oneSkinFitMode"
    public static let speedKey = "oneSkinSpeed"
    public static let loopKey = "oneSkinLoop"
    public static let fillKey = "oneSkinFill"
    /// 「自动全屏」开关（参考截图里那颗蓝底蓝字的 chip）。开播即进全屏。
    /// 消费点在 iOS 皮肤视图里，但键名仍归此处 —— 见上面的「全量对齐」口径。
    public static let autoFullScreenKey = "oneSkinAutoFullScreen"
    /// 双列 / 合拢开关。用户手动切换并持久化的偏好，不按屏幕尺寸自动判断。
    public static let twoColumnKey = "oneSkinTwoColumn"
}

/// One line's resolved address and headers, produced by the cross-source probe and the episode
/// picker — both of which build on every platform.
public struct OneSkinLineSample: Equatable, Sendable {
    public var url: URL
    public var headers: [String: String]

    public init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }
}

/// How the picture sits inside the fixed One window — One's four modes.
///
/// It only changes how the picture is drawn, never the window's geometry. The Bilibili skin reuses
/// it (its stored values extend the same key), so it is platform-neutral and lives here rather than
/// in the iOS-only view file.
public enum OneSkinFitMode: String, CaseIterable, Identifiable, Sendable {
    case fit        // 适应：完整画面 + 上下/左右黑边（resizeAspect）
    case fill       // 填充：铺满窗口、裁掉溢出（resizeAspectFill）
    case cover      // 铺满：等比放大到窗口短边贴满，超出裁切
    case stretch    // 拉伸：不留黑边、不裁切，比例可能变形

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fit: "适应"
        case .fill: "填充"
        case .cover: "铺满"
        case .stretch: "拉伸"
        }
    }

    /// The gravity handed to `AVPlayerLayer`. Cover and stretch first fill the window, then the
    /// surrounding view applies an equal/unequal `scaleEffect`.
    public var gravity: AVLayerVideoGravity {
        switch self {
        case .fit: .resizeAspect
        case .fill, .cover, .stretch: .resizeAspectFill
        }
    }

    /// The额外 equal-ratio scale applied after `fill`. Only "cover" needs one extra step
    /// (`fill` already fills, so 1 means no extra); "stretch" uses the separate non-uniform path.
    public var scaleX: CGFloat { 1.0 }
    public var scaleY: CGFloat { 1.0 }
}

/// 观看页用哪一套外观。
///
/// Three states, not a Boolean: the original (upstream), the One skin, and the Bilibili skin.
/// Independent of each other — turning one off never brings the other back. Stored under
/// `playSkin`; the older single Boolean `oneSkinEnabled` is only a migration source.
///
/// Lives in TVCore because the **settings screens for every platform** read and write it. It used
/// to sit inside the iOS-only BiliSkin.swift, which is why macOS/tvOS failed with
/// `cannot find 'PlaySkin' in scope` in SettingsPlayback.
public enum PlaySkin: String, CaseIterable, Identifiable, Sendable {
    case native
    case one
    case bilibili

    public var id: String { rawValue }

    /// The defaults key.
    public static let key = "playSkin"

    public var title: String {
        switch self {
        case .native: return L10n.text("Original")
        case .one: return "One"
        case .bilibili: return "哔哩哔哩"
        }
    }

    public var detail: String {
        switch self {
        case .native: return L10n.text("The player exactly as it ships.")
        case .one: return L10n.text("Black page, controls over the picture, episodes in a row.")
        case .bilibili: return L10n.text("Half-screen card, drawer of episodes, settings sliding out from the right.")
        }
    }

    public var symbol: String {
        switch self {
        case .native: return "rectangle.on.rectangle"
        case .one: return "circle.lefthalf.filled"
        case .bilibili: return "play.rectangle.fill"
        }
    }

    /// The current value; when nothing was ever stored, migrate from the old Boolean.
    ///
    /// ⚠️ An empty string counts as "never stored". `@AppStorage(PlaySkin.key)` defaults to `""`
    /// and writes it on first read, so without excluding it the migration branch would never run
    /// and an upgrading viewer would silently fall back to the original skin.
    public static var current: PlaySkin {
        if let raw = UserDefaults.standard.string(forKey: key), !raw.isEmpty,
           let skin = PlaySkin(rawValue: raw) {
            return skin
        }
        let oneWasOn = UserDefaults.standard.object(forKey: OneSkinKeys.enabledKey) == nil
            || UserDefaults.standard.bool(forKey: OneSkinKeys.enabledKey)
        return oneWasOn ? .one : .native
    }

    /// Writes the value once so `@AppStorage(PlaySkin.key)` has something to read from then on.
    public static func adoptCurrentIfNeeded() {
        guard UserDefaults.standard.string(forKey: key) == nil else { return }
        UserDefaults.standard.set(current.rawValue, forKey: key)
    }
}
