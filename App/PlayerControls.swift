import SwiftUI
import TVCore

#if os(iOS)
/// One control the player can place in its top bar, its bottom transport row, or leave in the "⋯" menu.
///
/// The player's chrome is a row of round glass buttons over the picture, a row of transport controls
/// along the bottom, and a "⋯" menu holding the rest. Every one of those is a `PlayerControl`; the
/// viewer's layout decides which sit in the top bar, which in the bottom row, and which collapse into
/// More — and in what left-to-right order within each place. Controls can move freely between the top
/// and bottom rows, exactly like the tab bar's sections.
enum PlayerControl: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    // Round glass buttons (historically the top row).
    case airPlay = "airPlay"
    case episodes = "episodes"
    case pictureInPicture = "pictureInPicture"
    case miniPlayer = "miniPlayer"
    case lock = "lock"
    case rotate = "rotate"
    case danmaku = "danmaku"
    case quality = "quality"
    case audio = "audio"
    case subtitles = "subtitles"
    case speed = "speed"
    case pictureSize = "pictureSize"
    case videoInfo = "videoInfo"
    case speechSubtitles = "speechSubtitles"
    case anotherPlayer = "anotherPlayer"

    // Transport controls (historically the bottom row).
    case backTen = "backTen"
    case playPause = "playPause"
    case forwardTen = "forwardTen"
    case previousEpisode = "previousEpisode"
    case nextEpisode = "nextEpisode"
    case fullScreen = "fullScreen"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .airPlay: L10n.text("AirPlay")
        case .episodes: L10n.text("Episodes")
        case .pictureInPicture: L10n.text("Picture in Picture")
        case .miniPlayer: L10n.text("Mini Player")
        case .lock: L10n.text("Lock Controls")
        case .rotate: L10n.text("Rotate")
        case .danmaku: L10n.text("Danmaku")
        case .quality: L10n.text("Quality")
        case .audio: L10n.text("Audio")
        case .subtitles: L10n.text("Subtitles")
        case .speed: L10n.text("Playback Speed")
        case .pictureSize: L10n.text("Picture Size")
        case .videoInfo: L10n.text("Show Video Info")
        case .speechSubtitles: L10n.text("Write Subtitles From the Sound")
        case .anotherPlayer: L10n.text("Open in Another Player")
        case .backTen: L10n.text("Back 10 seconds")
        case .playPause: L10n.text("Play / Pause")
        case .forwardTen: L10n.text("Forward 10 seconds")
        case .previousEpisode: L10n.text("Previous Episode")
        case .nextEpisode: L10n.text("Next Episode")
        case .fullScreen: L10n.text("Full Screen")
        }
    }

    var symbol: String {
        switch self {
        case .airPlay: "airplayvideo"
        case .episodes: "list.bullet.rectangle"
        case .pictureInPicture: "pip.enter"
        case .miniPlayer: "rectangle.inset.bottomright.filled"
        case .lock: "lock.open"
        case .rotate: "rectangle.landscape.rotate"
        case .danmaku: "text.bubble"
        case .quality: "sparkles.tv"
        case .audio: "speaker.wave.2"
        case .subtitles: "captions.bubble"
        case .speed: "gauge.with.needle"
        case .pictureSize: "arrow.up.left.and.arrow.down.right"
        case .videoInfo: "info.circle"
        case .speechSubtitles: "waveform.badge.plus"
        case .anotherPlayer: "play.rectangle.on.rectangle"
        case .backTen: "gobackward.10"
        case .playPause: "play.fill"
        case .forwardTen: "goforward.10"
        case .previousEpisode: "backward.end.fill"
        case .nextEpisode: "forward.end.fill"
        case .fullScreen: "arrow.up.left.and.arrow.down.right"
        }
    }

    /// Whether this control belongs to the round-button rows (top or bottom) as opposed to being
    /// inherently a menu item. All of them can sit in a bar; `.airPlay` is the one exception that
    /// only ever renders as its system button in a bar.
    var isRoundButton: Bool {
        switch self {
        case .backTen, .playPause, .forwardTen, .previousEpisode, .nextEpisode, .fullScreen:
            false
        default:
            true
        }
    }

    /// Where a fresh install puts each control. This is what the player showed before controls
    /// became rearrangeable: AirPlay and episodes in the top bar, transport along the bottom, and
    /// everything else in the "⋯" menu. The standard layout drops these into the first slots of each
    /// row, leaving the rest empty.
    static var standardTop: [PlayerControl] { [.airPlay, .episodes] }
    static var standardBottom: [PlayerControl] { [.backTen, .playPause, .forwardTen, .previousEpisode, .nextEpisode, .fullScreen] }
    static var standardMore: [PlayerControl] {
        [.quality, .audio, .subtitles, .speed, .pictureSize, .pictureInPicture, .miniPlayer,
         .lock, .rotate, .danmaku, .videoInfo, .speechSubtitles, .anotherPlayer]
    }

    var tint: Color {
        switch self {
        case .airPlay: .cyan
        case .episodes: Brand.cyan
        case .pictureInPicture: Brand.rose
        case .miniPlayer: Brand.amber
        case .lock: .gray
        case .rotate: .indigo
        case .danmaku: .teal
        case .quality: .purple
        case .audio: .blue
        case .subtitles: .orange
        case .speed: Brand.teal
        case .pictureSize: Brand.cyan
        case .videoInfo: .blue
        case .speechSubtitles: .pink
        case .anotherPlayer: .indigo
        case .backTen: .gray
        case .playPause: .white
        case .forwardTen: .gray
        case .previousEpisode: .gray
        case .nextEpisode: .gray
        case .fullScreen: .gray
        }
    }
}

/// The viewer's player-control layout: which controls occupy which of the ten slots in the top bar,
/// which occupy the ten slots in the bottom transport row, and which wait in More. Both rows share
/// the same fixed ten-slot grid, so a control's horizontal place is an explicit slot number (1–10)
/// rather than an implicit list order, and an empty slot leaves a gap. One layout serves every
/// player shape — folded outer screen, unfolded upright, unfolded sideways — so the arrangement is
/// identical across all three.
///
/// Stored as `top|bottom|more`: each of the first two halves is ten comma-separated raw values (or
/// `-` for an empty slot), and the third is the More list.
struct PlayerControlsLayout: Equatable {
    static let storageKey = "playerControlsOrder"
    /// The number of fixed slots in the top bar and in the bottom bar.
    static let slotCount = 10
    /// The empty-slot marker in the stored form.
    private static let empty = "-"

    var topSlots: [PlayerControl?]
    var bottomSlots: [PlayerControl?]
    var more: [PlayerControl]

    /// The non-empty controls in each row, in slot order.
    var top: [PlayerControl] { topSlots.compactMap { $0 } }
    var bottom: [PlayerControl] { bottomSlots.compactMap { $0 } }

    init(topSlots: [PlayerControl?], bottomSlots: [PlayerControl?], more: [PlayerControl]) {
        self.topSlots = Self.normalized(topSlots)
        self.bottomSlots = Self.normalized(bottomSlots)
        self.more = more
    }

    /// Pads or trims a slot list to exactly `slotCount` entries.
    private static func normalized(_ slots: [PlayerControl?]) -> [PlayerControl?] {
        var result = Array(slots.prefix(slotCount))
        while result.count < slotCount { result.append(nil) }
        return result
    }

    static let standard = PlayerControlsLayout(
        topSlots: PlayerControl.standardTop.map(Optional.some),
        bottomSlots: PlayerControl.standardBottom.map(Optional.some),
        more: PlayerControl.standardMore
    )

    init(stored: String) {
        let parts = stored.split(separator: "|", omittingEmptySubsequences: false)
        func parseSlots(_ s: Substring) -> [PlayerControl?] {
            s.split(separator: ",", omittingEmptySubsequences: false).map {
                $0 == Substring(Self.empty) ? nil : PlayerControl(rawValue: String($0))
            }
        }
        switch parts.count {
        case 3:
            self.init(topSlots: parseSlots(parts[0]), bottomSlots: parseSlots(parts[1]),
                      more: parts[2].split(separator: ",").compactMap { PlayerControl(rawValue: String($0)) })
        case 2:
            // Legacy `bar|more` from the two-zone build: the bar was the top row, transport stayed
            // fixed at the bottom.
            let top = parts[0].split(separator: ",").compactMap { PlayerControl(rawValue: String($0)) }
            self.init(topSlots: top.map(Optional.some), bottomSlots: PlayerControl.standardBottom.map(Optional.some),
                      more: parts[1].split(separator: ",").compactMap { PlayerControl(rawValue: String($0)) })
        default:
            self = .standard
            return
        }
        // Any control a newer build added lands in its standard home; a control that vanished is
        // dropped. This keeps every control present exactly once.
        var top = self.top, bottom = self.bottom, more = self.more
        let placed = Set(top + bottom + more)
        for control in PlayerControl.standardTop where !placed.contains(control) { top.append(control) }
        for control in PlayerControl.standardBottom where !placed.contains(control) { bottom.append(control) }
        for control in PlayerControl.standardMore where !placed.contains(control) { more.append(control) }
        self.init(topSlots: top.map(Optional.some), bottomSlots: bottom.map(Optional.some), more: more)
    }

    var stored: String {
        func slots(_ s: [PlayerControl?]) -> String {
            s.map { $0.map(\.rawValue) ?? Self.empty }.joined(separator: ",")
        }
        return slots(topSlots) + "|" + slots(bottomSlots) + "|" + more.map(\.rawValue).joined(separator: ",")
    }

    /// Which zone a control is in, so the player can route its rendering.
    enum Zone { case top, bottom, more }
    func zone(of control: PlayerControl) -> Zone {
        if top.contains(control) { return .top }
        if bottom.contains(control) { return .bottom }
        return .more
    }

    /// Moves a control into a specific slot of a row, removing it from wherever it was.
    mutating func place(_ control: PlayerControl, in zone: Zone, slot: Int) {
        remove(control)
        let index = min(max(slot, 0), Self.slotCount - 1)
        switch zone {
        case .top: topSlots[index] = control
        case .bottom: bottomSlots[index] = control
        case .more: more.append(control)
        }
    }

    /// Removes a control from every row and More.
    mutating func remove(_ control: PlayerControl) {
        topSlots = topSlots.map { $0 == control ? nil : $0 }
        bottomSlots = bottomSlots.map { $0 == control ? nil : $0 }
        more.removeAll { $0 == control }
    }
}
#endif
