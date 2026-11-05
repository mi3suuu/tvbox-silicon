import AVFoundation
import SwiftUI
import TVCore

// 上游 1.8.11 的 #547 字幕外观（`SubtitleCues` + `SubtitleOverlay` + `SubtitleStyle`）在融合版里
// **没有接线**：`App/PlaybackView.swift` 的 `makeItem(_:url:)` 少了 `textStyleRules` 和
// `subtitles.attach`，`PlaybackSession` 也没有 `subtitles` 这个成员。结果是设置页里调好的字幕
// 外观在播放时不生效——功能在、入口在、链路断了。
//
// `PlaybackView.swift` 是 W4-playback 的文件，本文件不改它，只把上游 `PlaybackView` 里那个
// `private static` 与两处内联动作封装成可复用的一行调用，让 W4 只加三行接入：
//
//   1. `PlaybackSession` 里加一个存储属性（Swift 的 extension 加不了存储属性）：
//          let subtitles = SubtitleCues()
//   2. `makeItem(_:url:)` 里 `AVPlayerItem(asset:)` 之后加一行：
//          subtitles.prepare(item)
//   3. `currentItem` 就绪处加一行：
//          subtitles.follow(player.currentItem)
//
// 这三处与上游 22180e4 的 `App/PlaybackView.swift:491 / 604-605 / 475` 一一对应，等于把上游原样接回来。

extension SubtitleCues {
    /// The item's subtitle text rules, from the saved style.
    ///
    /// AVPlayer applies these to the cues it draws itself — the ones it draws in Picture in
    /// Picture, where the app's own overlay is not on screen. Its renderer keeps the system's box
    /// behind the letters whatever a rule says, so `SubtitleStyle.attributes` sets neither the box
    /// nor the place.
    ///
    /// Upstream keeps this as a `private static` on `PlaybackSession`; it lives here so the same
    /// rules can be re-applied when the viewer changes the style mid-playback, without copying the
    /// line into a second file.
    static func rules(_ style: SubtitleStyle = .load()) -> [AVTextStyleRule] {
        AVTextStyleRule(textMarkupAttributes: style.attributes).map { [$0] } ?? []
    }

    /// Gives `item` the app's subtitle pipeline: the style rules for the player's own renderer, and
    /// an output for the overlay the app draws.
    ///
    /// Every item the queue may play needs this, so call it wherever an item is made rather than
    /// only on the one playing now.
    func prepare(_ item: AVPlayerItem) {
        item.textStyleRules = Self.rules()
        attach(item)
    }

    /// Re-applies the saved style to the item on screen, after the viewer changed it in Settings.
    ///
    /// AVPlayer caches the rules on the item, so a new style only reaches the player's own renderer
    /// (Picture in Picture) once they are set again. The overlay reads `style` through
    /// `SubtitleStyle.changed` on its own.
    func restyle(_ item: AVPlayerItem?, _ style: SubtitleStyle = .load()) {
        guard let item else { return }
        item.textStyleRules = Self.rules(style)
    }
}

/// Keeps the player's own subtitle renderer in step with the style the viewer picks.
///
/// Upstream registers this observer inline in `PlaybackSession`. It is a separate type here so the
/// observation can be started from wherever the session is built and stopped by the same token —
/// an observer left behind keeps a snapshot of a dead session alive.
@MainActor
final class Mi3sSubtitleStyleObserver {
    // `nonisolated(unsafe)` on a value only the main actor touches: the deinit has to unregister
    // it, and a `deinit` is never isolated, so Swift 6 would otherwise refuse to read the token
    // from there. The observer is registered and removed on the main thread by construction.
    nonisolated(unsafe) private var token: NSObjectProtocol?
    private let apply: () -> Void

    /// `apply` runs on the main thread each time the saved style changes.
    init(apply: @escaping () -> Void) {
        self.apply = apply
    }

    func start() {
        guard token == nil else { return }
        token = NotificationCenter.default.addObserver(forName: SubtitleStyle.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}
