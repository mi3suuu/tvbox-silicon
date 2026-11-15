import SwiftUI
import TVCore

#if os(iOS) || os(tvOS)
// ⚠️ 本文件在 tvOS 也可编译：零 iOS-only 依赖（纯数据模型 + UserDefaults/L10n）。
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
    /// 广告标注。
    ///
    /// 它原先直接写死在「更多」菜单的 `.anotherPlayer` 分支里 —— 那样新加的按钮既不进
    /// `PlayerControl` 这张表，也就**既不能隐藏、也不能摆位置**（设置页只认这张表）。
    /// 新按钮一律走同一张表：默认落在「更多」，用户想摆到控制栏就拖上去。
    case markAd = "markAd"
    /// 广告拦截开关（`player.skipAds`）。
    ///
    /// 与 `.markAd` 是两件事：`.markAd` 是播到广告时「把这段记下来」，
    /// `.adBlock` 是「以后认出这类画面就自动跳过」的总开关。
    ///
    /// 此前这个开关只存在于「设置 › 播放 › 广告跳过」那一页，
    /// `PlayerControl` 里根本没有它 —— 于是设置页的拖拽表里
    /// **根本列不出「广告拦截」这一项**，用户看到的就是
    /// 「这个按钮我无法设置」。开关本身早就在（`AdSkip.key`），
    /// 缺的只是把它做成一个和其它控件同等的、可摆放可隐藏的条目。
    case adBlock = "adBlock"

    // Transport controls (historically the bottom row).
    case backTen = "backTen"
    case playPause = "playPause"
    case forwardTen = "forwardTen"
    case previousEpisode = "previousEpisode"
    case nextEpisode = "nextEpisode"
    case fullScreen = "fullScreen"

    // 底栏那一条进度行上的三件「不是按钮」的东西。
    //
    // 用户的要求是「进度条也要，播放器的所有内容都要可以自定义」——
    // 它们此前是 `bottomBar` 里写死的 `Text` 与 `seekTrack`，既不能挪位置、
    // 也不能删掉。收进同一张表之后，它们和别的控件一样可拖、可隐藏。
    case timecode = "timecode"
    case progressBar = "progressBar"
    case remaining = "remaining"

    // 这四项原先只在 `CatalogPlaybackActions`（上游那套菜单）里有，
    // One 页另起一个「更多」菜单时它们没有对应 case —— 于是两套菜单重复且功能不等。
    // 收进枚举后只有一套，用户可以在设置页里决定它们出不出现。
    case autoPlayNext = "autoPlayNext"
    case moreInSeries = "moreInSeries"
    case skipIntroAuto = "skipIntroAuto"
    case skipIntroManual = "skipIntroManual"

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
        case .markAd: L10n.text("Mark Ad")
        case .adBlock: L10n.text("Ad Blocking")
        case .backTen: L10n.text("Back 10 seconds")
        case .playPause: L10n.text("Play / Pause")
        case .forwardTen: L10n.text("Forward 10 seconds")
        case .previousEpisode: L10n.text("Previous Episode")
        case .nextEpisode: L10n.text("Next Episode")
        case .fullScreen: L10n.text("Full Screen")
        case .timecode: L10n.text("Time Elapsed")
        case .progressBar: L10n.text("Progress Bar")
        case .remaining: L10n.text("Time Remaining")
        case .autoPlayNext: L10n.text("Auto-play next episode")
        case .moreInSeries: L10n.text("More in This Series")
        case .skipIntroAuto: L10n.text("Automatically skip intro and outro")
        case .skipIntroManual: L10n.text("Skip intro / outro")
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
        case .markAd: "megaphone"
        case .adBlock: "shield.lefthalf.filled"
        case .backTen: "gobackward.10"
        case .playPause: "play.fill"
        case .forwardTen: "goforward.10"
        case .previousEpisode: "backward.end.fill"
        case .nextEpisode: "forward.end.fill"
        case .fullScreen: "arrow.up.left.and.arrow.down.right"
        case .timecode: "timer"
        case .progressBar: "slider.horizontal.3"
        case .remaining: "hourglass"
        case .autoPlayNext: "play.circle"
        case .moreInSeries: "rectangle.stack"
        case .skipIntroAuto: "forward.end.alt"
        case .skipIntroManual: "forward.end"
        }
    }

    /// Whether this control belongs to the round-button rows (top or bottom) as opposed to being
    /// inherently a menu item. All of them can sit in a bar; `.airPlay` is the one exception that
    /// only ever renders as its system button in a bar.
    var isRoundButton: Bool {
        switch self {
        case .backTen, .playPause, .forwardTen, .previousEpisode, .nextEpisode, .fullScreen,
             .timecode, .progressBar, .remaining:
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
    /// 画面中央那一组（传输类）。
    ///
    /// 设置页、播放器、预览三处共用这一张表：把控件从顶栏摘下来时，
    /// 属于这一组的回中央，其余的进「更多」。
    static let centerControls: Set<PlayerControl> =
        [.backTen, .playPause, .forwardTen, .previousEpisode, .nextEpisode]

    /// 只能待在进度行那一条上的三项（它们不是按钮，没有顶栏形态）。
    static let progressRowOnly: Set<PlayerControl> = [.timecode, .progressBar, .remaining]

    // MARK: 三处能力表（设置页与播放器共用）

    /// 一个控件在播放器里**能落在哪几处**。
    enum Placement: String, CaseIterable {
        /// 顶栏（画面顶部一行）。
        case topBar
        /// 画面正中的传输组。
        case middle
        /// 贴着进度条的那一行。
        case progressRow

        var title: String {
            switch self {
            case .topBar:      return L10n.text("Add to Top Bar")
            case .middle:      return L10n.text("Add to the Middle")
            case .progressRow: return L10n.text("Add to Progress Row")
            }
        }

        var symbol: String {
            switch self {
            case .topBar:      return "arrow.up"
            case .middle:      return "play.rectangle"
            case .progressRow: return "arrow.down"
            }
        }
    }

    /// 三处能力**不对称**，而播放器早就按这份规则过滤了
    ///（`OneSkinChrome.topSlotRow` / `centerSlotRow` / `bottomSlotRow`）。
    ///
    /// 设置页此前不知道这份规则，于是菜单里那两个「加到顶部 / 加到进度行」对某些控件是
    /// **静默无效**的 —— 用户点了、列表里也确实加了，播放器里却什么都不变：
    ///   · 时间码 / 进度条 / 剩余时间：顶栏没有画法，写进去会被 `setTopOrder` 滤掉；
    ///   · 播放 / ±10 秒 / 选集键：只画在画面中央，写进顶栏会被挪回底栏；
    ///   · 锁定键：底栏在锁定态根本不画，放进进度行等于锁上之后再没有解锁入口。
    ///
    /// 这张表现在是唯一来源：设置页照它决定菜单给哪几项、拖拽允不允许跨区。
    var placements: [Placement] {
        if Self.fixedKeys.contains(self) { return [] }
        if Self.centerControls.contains(self) { return [.middle] }
        if Self.progressRowOnly.contains(self) { return [.progressRow] }
        return [.topBar, .progressRow]
    }

    /// 播放器上**位置固定、不由布局表摆放**的控件。
    ///
    /// 目前只有锁定键。它以前既在顶栏兜底、又在「更多」里有同名菜单项 ——
    /// 同一个动作两个入口，且设置页把它当普通控件列出来让人拖，拖到「更多」里
    /// 顶上那颗兜底照样画着（见 `!topSlotRow.contains(.lock)`）。
    /// 现在统一成**右上角那颗固定键**：`placements` 为空、不进能力分组、
    /// 「更多」里也不再重复列一项。
    ///
    /// 为什么不能交给用户摆：锁定态下顶栏控件与「更多」全都不画，
    /// 它必须有一个锁上之后仍然画得出来的位置，否则锁死就再也解不开。
    static let fixedKeys: Set<PlayerControl> = [.lock]

    static var standardBottom: [PlayerControl] {
        [.backTen, .playPause, .forwardTen, .previousEpisode, .nextEpisode,
         .timecode, .progressBar, .remaining, .fullScreen]
    }
    static var standardMore: [PlayerControl] {
        [.quality, .audio, .subtitles, .speed, .pictureSize, .pictureInPicture, .miniPlayer,
         .rotate, .danmaku, .videoInfo, .speechSubtitles, .anotherPlayer, .markAd,
         .adBlock, .autoPlayNext, .moreInSeries, .skipIntroAuto, .skipIntroManual]
    }

    /// 播放器「更多」面板的真实分组 —— **能力清单的唯一来源**。
    ///
    /// 设置页此前自己维护一份表，播放器 `OneSkinPlayerChrome.visibleMoreGroups`
    /// 又维护一份，两边一旦不同步就会出现「设置里能摆、播放器里没有对应分支」
    /// （本项目反复出现的「能勾但不生效」）。现在两张表合成这一张：
    ///   · 顺序 = 「更多」面板里的分组顺序；
    ///   · 成员 = `allCases` 的**完整划分**（不重不漏，`assert` 在 Debug 下守着）。
    static var capabilityGroups: [CapabilityGroup] {
        let groups: [CapabilityGroup] = [
            CapabilityGroup(title: L10n.text("Playback"), symbol: "play.rectangle",
                            controls: [.episodes, .previousEpisode, .nextEpisode, .rotate,
                                       .pictureInPicture, .miniPlayer, .anotherPlayer,
                                       .playPause, .backTen, .forwardTen, .fullScreen]),
            CapabilityGroup(title: L10n.text("Picture"), symbol: "rectangle.on.rectangle",
                            controls: [.quality, .pictureSize]),
            CapabilityGroup(title: L10n.text("Sound"), symbol: "speaker.wave.2",
                            controls: [.audio, .subtitles, .speed, .danmaku, .speechSubtitles]),
            CapabilityGroup(title: L10n.text("Series"), symbol: "rectangle.stack",
                            controls: [.autoPlayNext, .moreInSeries, .skipIntroAuto, .skipIntroManual]),
            CapabilityGroup(title: L10n.text("Progress"), symbol: "slider.horizontal.3",
                            controls: [.timecode, .progressBar, .remaining]),
            CapabilityGroup(title: L10n.text("Ads"), symbol: "megaphone",
                            controls: [.markAd, .adBlock]),
            CapabilityGroup(title: L10n.text("Info"), symbol: "info.circle",
                            controls: [.videoInfo, .airPlay])
        ]
        // 固定键（锁定）不在分组里：它在播放器上位置固定，设置页单独一节说明。
        assert(Set(groups.flatMap(\.controls)) == Set(allCases).subtracting(fixedKeys),
               "能力分组必须正好覆盖全部可摆放控件：漏掉的那个在设置页里找不到，多出的那个没有渲染分支。")
        return groups
    }

    /// 某项在播放器里「什么时候才真的画得出来」，给设置页做一句人话说明。
    ///
    /// 这不是装饰：`available()` 里有些控件依赖内容（单码率没有画质菜单、
    /// 单音轨没有音轨菜单、直播没有倍速）。用户排好了却看不到，必须知道原因，
    /// 否则又是一次「设置了不生效」。
    var availabilityNote: String? {
        switch self {
        case .quality: L10n.text("Only when the source offers more than one quality.")
        case .audio: L10n.text("Only when the source offers more than one audio track.")
        case .subtitles: L10n.text("Only when the source has subtitles.")
        case .danmaku: L10n.text("Only when the source has comments.")
        case .speed: L10n.text("Never in a live stream.")
        case .episodes, .moreInSeries, .nextEpisode, .previousEpisode:
            L10n.text("Only when the title has more than one episode.")
        case .markAd: L10n.text("Only for on-demand video longer than a minute.")
        case .speechSubtitles: L10n.text("Only when speech recognition works in your language.")
        default: nil
        }
    }

    /// 能摆进控制栏的那些控件 —— 设置页的调色板就是它。
    ///
    /// ⛔ 这里曾经是 `allCases.filter { $0.isRoundButton && $0 != .rotate && $0 != .lock }`，
    /// 于是**播放暂停 / ±10 秒 / 上一集 / 下一集 / 全屏 / 转屏 / 锁定**七项根本
    /// 不出现在勾选表里。用户的原话是「选集播放、全屏播放、视频播放器的任意控件
    /// 都需要可以调节任意槽位」—— 缺的首先就是这张表：他连勾都没法勾。
    ///
    /// 现在列出**全部**控件。这不只是把表列长，前提是三处渲染都已经吃得住它们：
    ///   · One 皮肤 `OneSkinPlayerChrome.controlButton` 覆盖全部分支；
    ///   · 原版 `MobilePlayer.topControlButton` / `transportButton` 也覆盖全部；
    ///   · 勾上时 `surfaceInTopRow` 会把它摆进顶栏第一个空槽（并自动从底栏摘走），
    ///     所以「勾了就有位置、有位置就能看见」——「能勾但不生效」不再成立。
    ///
    /// 仍然不在这张表里的是**不属于 `PlayerControl` 的结构键**：全屏态的返回、
    /// 「更多」菜单。它们不是可配置项，也就不存在「设置里勾了却没有」的矛盾。
    static var barControls: [PlayerControl] { allCases }

    /// 这个名字在**本机**真的能画出来吗。
    ///
    /// SF Symbols 名字写错时 `Image(systemName:)` 不报错、不崩溃 —— 它画出来的是一颗
    /// **有底无图标的空圆**。设置页能勾、能拖，播放器里却什么都没有，正是
    /// 「控件没实现完整」最难看懂的一种。`megaphone.badge.xmark` 与
    /// `forward.to.end.alt` 都曾这样躺了很久（两个名字在系统符号库里根本不存在）。
    ///
    /// 这是一道**兜底**，不是常规路径：名字对的时候它什么都不做。
    static func fallbackSymbol(_ name: String, to replacement: String) -> String {
        #if os(iOS)
        return UIImage(systemName: name) != nil ? name : replacement
        #elseif os(macOS)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : replacement
        #else
        return name
        #endif
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
        case .markAd: .pink
        case .adBlock: .green
        case .backTen: .gray
        case .playPause: .white
        case .forwardTen: .gray
        case .previousEpisode: .gray
        case .nextEpisode: .gray
        case .fullScreen: .gray
        case .timecode: .gray
        case .progressBar: .gray
        case .remaining: .gray
        case .autoPlayNext: Brand.teal
        case .moreInSeries: .purple
        case .skipIntroAuto: Brand.amber
        case .skipIntroManual: Brand.amber
        }
    }
}

/// 一组能力（与播放器「更多」面板的标题一一对应）。
///
/// 用 struct 而不是元组：`ForEach` 需要 `KeyPath`，而 Swift 的 KeyPath
/// 取不到元组成员（`\.title` 在元组上编译不过）。
struct CapabilityGroup: Identifiable {
    let title: String
    let symbol: String
    let controls: [PlayerControl]
    var id: String { title }
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
    /// 选集页控制栏里**直接显示**的控件（其余仍在「更多」里）。
    static let watchSurfacedKey = "playerControlsWatchSurfaced"
    /// 全屏态控制栏里**直接显示**的控件。
    static let fullSurfacedKey = "playerControlsFullSurfaced"

    // MARK: - 一份布局，三种形态共用
    //
    // ⛔ 这里曾经按形态分三份存（`playerControlsOrder.folded/.unfolded/.sideways`），
    // 理由是「外屏顶栏只放得下 2–3 个，横持能放 6 个，一套槽位不可能同时合适」。
    //
    // 那个理由本身没错，但**解法错了**：它把「空间不够」这个运行时问题变成了
    // 用户的配置负担 —— 设置页顶部先选形态，再一份一份排。实际后果有两个：
    //   ① 用户在外屏页排了半天，播放器当前在横持，读的是另一份 ⇒「改了完全没反应」；
    //   ② 三份配置互相独立，改了一份另外两个形态还是老样子 ⇒「每个形态都要设置一次」。
    //
    // 正确的解法是工具栏的通用做法：**用户只排一份先后顺序，运行时按实际宽度
    // 能放几颗放几颗，放不下的自动收进「更多」**（见 `OneSkinPlayerChrome.topOverflow`）。
    // 空间问题由代码解决，不再让用户替每个形态各排一遍。
    //
    // 现在只有 `storageKey` 一个键。`Shape` 仍然保留，但只用于
    // **预览选形态**与**旧键迁移**，不再参与存储选择。
    enum Shape: String, CaseIterable {
        /// 合起外屏 466×678。
        case folded
        /// 展开竖持 669×951。
        case unfolded
        /// 展开横持 951×669（以及手机横持）。
        case sideways

        /// 旧版每形态各自的键（仅迁移用）。
        var legacyStorageKey: String {
            switch self {
            case .folded: return PlayerControlsLayout.storageKey
            default: return PlayerControlsLayout.storageKey + "." + rawValue
            }
        }

        var title: String {
            switch self {
            case .folded:   return L10n.text("Folded outer screen")
            case .unfolded: return L10n.text("Unfolded, upright")
            case .sideways: return L10n.text("Unfolded, sideways")
            }
        }

        /// 这块屏的真实点数尺寸（预览按它 1:1 画，再整体缩放）。
        var screenSize: CGSize {
            switch self {
            case .folded:   return CGSize(width: 466, height: 678)
            case .unfolded: return CGSize(width: 669, height: 951)
            case .sideways: return CGSize(width: 951, height: 669)
            }
        }
    }

    /// 当前布局的原始串。没写过就用标准布局。
    static var rawStored: String {
        guard let own = UserDefaults.standard.string(forKey: storageKey), !own.isEmpty else {
            return standard.stored
        }
        return own
    }

    /// 唯一入口：所有形态、所有皮肤都读这一份。
    static var current: PlayerControlsLayout { PlayerControlsLayout(stored: rawStored) }

    /// 这个键是否被用户改过。
    static var hasOwnConfiguration: Bool {
        guard let own = UserDefaults.standard.string(forKey: storageKey) else { return false }
        return !own.isEmpty
    }

    /// 恢复默认。
    static func reset() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// 把旧的「每形态一份」并成一份。
    ///
    /// 判据与取舍：
    ///  · 共用键（`playerControlsOrder`，老版本里就是「折叠外屏」那份）**已存在** ⇒ 用它。
    ///    那是老用户实际在用的那份，迁移不能覆盖它。
    ///  · 共用键不存在、某个形态自己存过 ⇒ 用**第一个存过的**（顺序 folded → unfolded → sideways），
    ///    至少把用户排过的东西带过来，而不是直接掉回默认。
    ///  · 都没有 ⇒ 什么都不写，读的时候自然回落到 `standard`。
    ///
    /// 幂等：只在一个 marker 没记过时跑一次；旧键保留不删（回滚到旧版本仍可用）。
    @MainActor
    static func migrateToUnifiedIfNeeded() {
        let defaults = UserDefaults.standard
        let marker = "playerControlsUnified.migrated.v1"
        guard defaults.object(forKey: marker) == nil else { return }
        defer { defaults.set(true, forKey: marker) }

        if let own = defaults.string(forKey: storageKey), !own.isEmpty { return }
        for shape in Shape.allCases {
            let key = shape.legacyStorageKey
            guard key != storageKey,
                  let legacy = defaults.string(forKey: key), !legacy.isEmpty else { continue }
            defaults.set(legacy, forKey: storageKey)
            #if DEBUG
            print("[PlayerControls] unified layout seeded from \(shape.rawValue)")
            #endif
            return
        }
    }


    /// 当前设备的形态（给播放器各读取点用）。
    ///
    /// ⛔ 判据**不能**读 `interfaceOrientation`（BUG-L）。
    ///
    /// 原来这里是：`width < 560 ? .folded : (interfaceOrientation 是横 ? .sideways : .unfolded)`。
    /// 而 Apple 对 iPhone Duo 的事实是：**内屏不遵守 `supportedInterfaceOrientations`**，
    /// 它自己转（`mirzaaghazadeh/iphone-duo-skills` 的 `device-facts.md`：
    /// "The inner display does not honor your supported interface orientations —
    /// it rotates regardless"；`duo-continuity` 同样写明「不要让 supported orientations
    /// 作判据」）。实测内屏竖持时它仍报 `.landscapeLeft`。
    ///
    /// 后果很具体：内屏竖持（669×951）被算成 `.sideways`，
    /// 于是用户在设置页为「展开竖持」排的那套 `playerControlsOrder.unfolded`
    /// **一次都读不到**，永远读到 sideways 那份 —— 「设置里改了没反应」。
    ///
    /// 现在只按**实际空间**判：先看宽度分窄屏，再用宽高比定横竖。
    /// 这与 `OneSkinShapeResolver` 的口径一致（都只看空间，不看方向声明），
    /// 只是这里拿不到滞回状态，所以阈值取两档之间一个保守值。
    ///
    /// - Parameter width: 可用**宽度**（窄屏判据）。
    /// - Parameter height: 可用**高度**；缺省 0 表示调用方没有高度，
    ///   此时退回 `.unfolded`（宽屏、非横向），而不是去猜方向。
    @MainActor
    static func currentShape(width: CGFloat, height: CGFloat = 0) -> Shape {
        guard width > 0 else { return .folded }
        if width < 560 { return .folded }
        // 宽屏之后再分横竖：宽 > 高即横持。高度未知时不猜，按竖持处理。
        guard height > 1 else { return .unfolded }
        return width > height ? .sideways : .unfolded
    }

    /// 由**页面形态**直接映射到控制栏配置 —— 播放器皮肤的**首选**入口。
    ///
    /// ⛔ 为什么不能从窗口尺寸反推横竖（这一步是上一版修法的漏洞）：
    ///
    /// 播放器**窗口本身永远是横向的**。竖屏窗口的版式比例固定 1.819
    /// （`OneSkinWindowGeometry.Metrics.windowAspect`），所以：
    ///   内屏竖持 fullBleed → 窗口 669×532（宽>高）
    ///   内屏竖持单列      → 窗口 669×345（宽>高）
    /// 拿窗口宽高比判，两种竖持都会被判成 `.sideways`。而
    /// `appScreenBounds.width` 在内屏恒为 669（物理固定值），同样分不开。
    /// 「窗口是横的」和「设备是横的」是两件事，混用就永远选错配置。
    ///
    /// `OneSkinShape` 已经由调用方用**离散信号**判好了（`duoExpanded` +
    /// 空间比例 + 折叠带），是页面形态的唯一真源。这里直接把形态映射成
    /// 配置档位，不再二次推断。
    ///
    /// - 合拢 / 展开竖持（`.column` / `.fullBleed`）→ `.unfolded`
    ///   两者都是竖持语义，共用「展开竖持」那一套；窄屏再单独落 `.folded`。
    /// - 展开横持（`.split`）→ `.sideways`
    #if os(iOS)
    // 仅 iOS：参数类型 `OneSkinShape` 属 OneSkin 文件簇（整体只在 iOS 编译）。
    // 两个方法的调用方 `current(forSkinShape:)` 与 `OneSkin.swift` 都在簇内。
    @MainActor
    static func shape(for skinShape: OneSkinShape, width: CGFloat) -> Shape {
        // ⛔ `split` 必须**先于**任何宽度闸门返回。
        //
        // 上一版写成「先 `width < 560 → .folded`，再 `case .split → .sideways`」，
        // 而两个调用点传的 `width` 是**播放器窗口宽 winW = 左列宽 ≈ 屏宽 × 0.5334**：
        //   内屏横持 split: 951 × 0.5334 = 507.3 < 560 → .folded（应 sideways）
        //   手机横持 split: 678 × 0.5334 = 361.6 < 560 → .folded
        //   iPad 横持:      1024 × 0.5334 = 546.2 < 560 → .folded
        // 于是「凡 split 形态，winW 恒 < 560」——`case .split` 整段是**不可达代码**，
        // 用户单独配的 `playerControlsOrder.sideways` **一次都读不到**。
        // 这是「设置里改了没反应」换个成因复发。
        //
        // 判据修正：**形态本身已经是可靠信号**（调用方用 duoExpanded + 空间比例 +
        // 折叠带判出来的），横竖不需要再看窗口宽度。宽度只用于区分
        // 「宽屏竖持」与「窄屏竖持」这一件事。
        switch skinShape {
        case .split:
            return .sideways
        case .fullBleed:
            return .unfolded
        case .halfFold:
            // 半折是**竖持语义**（帐篷立起来），不是横屏。
            // 但它的控制台在下半屏、横向空间受限，所以走 `.folded` 的紧凑档位
            // 而不是 `.unfolded` 的宽屏档 —— `.unfolded` 的双列控件塞进
            // 半个屏宽会挤成一团。
            return .folded
        case .column:
            // 合盖外屏 466 → folded；宽屏单列 → unfolded。
            // `width <= 0`（尚未布局）时按 folded —— 与旧行为一致，不会闪成双列。
            return width > 0 && width >= 560 ? .unfolded : .folded
        }
    }

    /// 皮肤层入口。**保留形参、忽略它们** —— 现在三种形态共用一份布局。
    ///
    /// 签名不改是为了让 `OneSkin` / `MobilePlayer` 的调用点保持一行，
    /// 将来若要恢复「按形态微调」，改动点仍在这里。
    @MainActor
    static func current(forSkinShape skinShape: OneSkinShape, width: CGFloat) -> PlayerControlsLayout {
        current
    }
    #endif

    /// 播放器入口（原版皮肤）。同样忽略尺寸，返回同一份布局。
    ///
    /// 传进来的仍然是**当前可用空间**，将来做「按形态微调」时它是唯一需要的输入。
    @MainActor
    static func current(forSize size: CGSize) -> PlayerControlsLayout {
        current
    }

    /// 只有宽度时的便捷入口（旧调用点保留）。
    @MainActor
    static func current(forWidth width: CGFloat) -> PlayerControlsLayout {
        current
    }

    /// The number of fixed slots in the top bar and in the bottom bar.
    static let slotCount = 10
    /// The empty-slot marker in the stored form.
    private static let empty = "-"

    var topSlots: [PlayerControl?]
    var bottomSlots: [PlayerControl?]
    var more: [PlayerControl]

    /// 兼容字段 —— 早期版本用它们决定「工具栏里画不画这颗」。
    ///
    /// ⛔ 现在**槽位本身才是唯一事实**：排进顶栏/底栏就画，排进「更多」就在菜单里。
    /// 这两个集合恒等于「全部控件」，保留它们只有两个理由：
    ///   ① 旧存储串还是五段格式，解析器要能读；
    ///   ② 原版皮肤走 `PlayerControlSurfacing.allowed(...)`，传「全部」= 不过滤。
    ///
    /// 历史教训：可见性集合与槽位是**两个与条件**，于是「勾了但没摆进槽位」和
    /// 「摆进槽位但没勾」都表现为「设置里改了、播放器里没有」。这正是用户说的
    /// 「甚至没有生效」。一个条件（槽位）就够，多出来的那个只会制造矛盾。
    private(set) var watchSurfaced: [PlayerControl]
    private(set) var fullSurfaced: [PlayerControl]

    /// 一维顺序写入顶栏 —— 设置页「拖拽排序」的唯一写入口。
    ///
    /// 规则（越简单越好）：
    ///   · 传入的数组就是顶栏从左到右的顺序；
    ///   · 从顶栏摘下去的**传输类**回到画面中央（它的老家），其余进「更多」；
    ///   · 同一个控件不会同时出现在两处。
    mutating func setTopOrder(_ controls: [PlayerControl]) {
        // 只接「顶栏画得出来」的：进度行三件没有顶栏形态，传输类只画在画面中央，
        // 固定键（锁定）压根不参与摆放。以前只滤了第一条，后两种会被写进
        // `topSlots` 再被播放器忽略 —— 「加了没反应」。
        let wanted = controls.filter { $0.placements.contains(.topBar) }
        var bottom = self.bottom.filter { !wanted.contains($0) }
        var more = self.more.filter { !wanted.contains($0) }
        for control in self.top where !wanted.contains(control) {
            if PlayerControl.centerControls.contains(control), !bottom.contains(control) {
                bottom.append(control)
            } else if !more.contains(control) {
                more.append(control)
            }
        }
        topSlots = wanted.map(Optional.some)
        bottomSlots = bottom.map(Optional.some)
        self.more = more
        assertComplete("setTopOrder")
    }

    /// 一维顺序写入底栏（进度那一行）—— 与 `setTopOrder` 同构。
    ///
    /// 底栏里既有传输类（显示在画面中央），也有时间码 / 进度条 / 剩余时间 / 全屏，
    /// 顺序就是这一行从左到右的顺序。从这一行摘下去的控件进「更多」。
    mutating func setBottomOrder(_ controls: [PlayerControl]) {
        // 锁定键没有底栏形态（锁定态底栏不画），写进来也画不出来。
        let wanted = controls.filter {
            $0.placements.contains(.progressRow) || $0.placements.contains(.middle)
        }
        let top = self.top.filter { !wanted.contains($0) }
        var more = self.more.filter { !wanted.contains($0) }
        for control in self.bottom where !wanted.contains(control) {
            if !more.contains(control) { more.append(control) }
        }
        topSlots = top.map(Optional.some)
        bottomSlots = wanted.map(Optional.some)
        self.more = more
        assertComplete("setBottomOrder")
    }

    /// 把控件放回它**唯一恰当的位置**（设置页「加回来」用）。
    ///
    /// 三处能力不对称，所以不做「加到哪一行」的二次选择：菜单里一项就是一个落点。
    mutating func add(_ control: PlayerControl, to placement: PlayerControl.Placement) {
        guard control.placements.contains(placement) else { return }
        switch placement {
        case .topBar:
            setTopOrder(top + [control])
        case .middle, .progressRow:
            setBottomOrder(bottom + [control])
        }
    }

    /// The non-empty controls in each row, in slot order.
    var top: [PlayerControl] { topSlots.compactMap { $0 } }
    var bottom: [PlayerControl] { bottomSlots.compactMap { $0 } }

    init(topSlots: [PlayerControl?], bottomSlots: [PlayerControl?], more: [PlayerControl]) {
        // 固定键（锁定）不参与摆放：旧串里它可能还躺在顶栏/底栏/更多里，
        // 进来时一律剔掉 —— 否则设置页会列一个拖不动的行，播放器那边还会多出一颗。
        self.topSlots = Self.strippingFixedKeys(Self.normalized(topSlots))
        self.bottomSlots = Self.strippingFixedKeys(Self.normalized(bottomSlots))
        self.more = more.filter { !PlayerControl.fixedKeys.contains($0) }
        // 不过滤：工具栏里有什么就画什么（见 `watchSurfaced` 的注释）。
        self.watchSurfaced = PlayerControl.allCases
        self.fullSurfaced = PlayerControl.allCases
    }

    /// 构造/写入完成后检查「控件都有家」，不合格就在 Debug 里当场炸。
    ///
    /// 刻意不放在指定 init 里：`init(stored:)` 会先按原样解析一遍、再补齐缺失项
    /// （见那段「Any control a newer build added…」），中间态本来就不完整 ——
    /// 在中间态断言，等于给「旧串缺了新控件」这种正常情况判死刑。
    func assertComplete(_ context: String) {
        assert(isComplete, """
            布局不完整（\(context)）：每个可摆放控件必须**恰好**待在顶栏 / 底栏 / 更多其中一处。
            漏掉的那个会在播放器里凭空消失（设置页还列着），重复的那个会画两遍。
            top=\(top.map(\.rawValue)) bottom=\(bottom.map(\.rawValue)) more=\(more.map(\.rawValue))
            """)
    }

    /// 控件是否「都有家」：三处不重不漏地覆盖全部可摆放控件。
    ///
    /// 这就是「三形态共用一份控件表、放不下就叠进更多」这条规则的落点：
    /// 任何没有被摆进某一行的控件，都必须在 `more` 里 —— 不能被丢掉。
    var isComplete: Bool {
        let placed = top + bottom + more
        return Set(placed).count == placed.count
            && Set(placed) == Set(PlayerControl.allCases).subtracting(PlayerControl.fixedKeys)
    }

    private static func strippingFixedKeys(_ slots: [PlayerControl?]) -> [PlayerControl?] {
        slots.map { slot in slot.flatMap { PlayerControl.fixedKeys.contains($0) ? nil : $0 } }
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
        case 5:
            // 第 4、5 段（两个「直接显示」集合）**读进来但不采用** ——
            // 槽位即事实。旧串照旧能解析，改成三段的时机不与本次改动绑定。
            self.init(topSlots: parseSlots(parts[0]), bottomSlots: parseSlots(parts[1]),
                      more: parts[2].split(separator: ",").compactMap { PlayerControl(rawValue: String($0)) })
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
        //
        // 注意把两个「直接显示」集合原样带回：这一段补的是槽位，不是可见性。
        // （曾经在这里用不带集合的 init 重建，五段串里刚解析出来的
        //  watchSurfaced / fullSurfaced 被默认值覆盖 —— 设置页勾完、播放器不认、
        //  重启后勾选框还退回默认，也就是「显示/隐藏 不起作用」。）
        var top = self.top, bottom = self.bottom, more = self.more
        let placed = Set(top + bottom + more)
        for control in PlayerControl.standardTop where !placed.contains(control) { top.append(control) }
        for control in PlayerControl.standardBottom where !placed.contains(control) { bottom.append(control) }
        for control in PlayerControl.standardMore where !placed.contains(control) { more.append(control) }
        self.init(topSlots: top.map(Optional.some), bottomSlots: bottom.map(Optional.some), more: more)
        assertComplete("load")
    }

    var stored: String {
        func slots(_ s: [PlayerControl?]) -> String {
            s.map { $0.map(\.rawValue) ?? Self.empty }.joined(separator: ",")
        }
        // 五段：top|bottom|more|watchSurfaced|fullSurfaced
        // 老的四段/三段串照旧能读（见 init(stored:)），新段缺省走默认值。
        return slots(topSlots) + "|" + slots(bottomSlots) + "|" + more.map(\.rawValue).joined(separator: ",")
            + "|" + watchSurfaced.map(\.rawValue).joined(separator: ",")
            + "|" + fullSurfaced.map(\.rawValue).joined(separator: ",")
    }

    // ⛔ 已删除 `Zone` / `zone(of:)` / `place(_:in:slot:)` / `remove(_:)` / `surfaceInTopRow(_:)`：
    //   整套是**槽位 + 勾选**两维模型的残留（「勾上→顺手补位」「落到第几格」）。
    //   现在只有一维顺序（`setTopOrder` / `setBottomOrder` / `add(_:to:)`），
    //   留着它就是**第三套摆放规则** —— 谁再调它，写出来的串与设置页/播放器都不同源，
    //   正是「设置里排好了、播放器里是空槽」那一类问题的温床。
}
#endif
