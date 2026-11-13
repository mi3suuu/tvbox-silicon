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
         .lock, .rotate, .danmaku, .videoInfo, .speechSubtitles, .anotherPlayer, .markAd,
         .adBlock, .autoPlayNext, .moreInSeries, .skipIntroAuto, .skipIntroManual]
    }

    /// 能摆进顶栏的那些控件 —— 设置页的两个「直接显示」勾选表就是它。
    ///
    /// 转屏与锁定是顶栏的**结构位**（一直在，不归布局管），transport 那几个属于底栏，
    /// 因此不在这张表里：把它们勾上不会有任何可见变化，那就是在骗人。
    static var barControls: [PlayerControl] {
        allCases.filter { $0.isRoundButton && $0 != .rotate && $0 != .lock }
    }

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
        case .autoPlayNext: Brand.teal
        case .moreInSeries: .purple
        case .skipIntroAuto: Brand.amber
        case .skipIntroManual: Brand.amber
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
    /// 选集页控制栏里**直接显示**的控件（其余仍在「更多」里）。
    static let watchSurfacedKey = "playerControlsWatchSurfaced"
    /// 全屏态控制栏里**直接显示**的控件。
    static let fullSurfacedKey = "playerControlsFullSurfaced"

    // MARK: - 按形态分别存（三形态各自独立的控制栏）
    //
    // 用户要求：**各自互补，各自有独立的播放控件设置页**。
    // 折叠外屏、展开竖持、展开横持三种形态的可用空间差一倍，
    // 一套槽位不可能同时合适：外屏顶栏只放得下 2–3 个，横持能放 6 个。
    // 共用一套的结果就是「在外屏删掉的按钮，横持时也没了」。
    //
    // 键名规则：`playerControlsOrder.<形态>`。形态用名字而不是序号，
    // 因为序号会在将来插入新形态时错位。
    //
    // ⛔ 向后兼容：`playerControlsOrder`（无后缀）仍是**默认值来源**。
    // 用户从旧版升上来时三份都还没有 → 各自回退到旧键；
    // 一旦某个形态自己保存过，就用自己那份，不再被旧键覆盖。
    enum Shape: String, CaseIterable {
        /// 合起外屏 466×678。
        case folded
        /// 展开竖持 669×951。
        case unfolded
        /// 展开横持 951×669（以及手机横持）。
        case sideways

        /// 本形态的存储键。`folded` 直接复用旧键，用户的现有配置原样保留。
        var storageKey: String {
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
    }

    /// 按形态读一份布局。该形态没存过时**回退到旧键**，再没有就用 standard。
    static func stored(for shape: Shape) -> String {
        if let own = UserDefaults.standard.string(forKey: shape.storageKey), !own.isEmpty {
            return own
        }
        // 折叠态直接就是旧键本身（见 `Shape.storageKey`），走到这里说明确实还没写过。
        return PlayerControlsLayout.standard.stored
    }

    /// 该形态是否已经有自己的配置（设置页据此显示「已自定义 / 跟随默认」）。
    static func hasOwnConfiguration(for shape: Shape) -> Bool {
        guard let own = UserDefaults.standard.string(forKey: shape.storageKey) else { return false }
        return !own.isEmpty
    }

    /// 把当前形态的配置清掉，重新回到默认。
    static func reset(_ shape: Shape) {
        UserDefaults.standard.removeObject(forKey: shape.storageKey)
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

    /// 按页面形态读一份布局（皮肤层首选；见 `shape(for:width:)`）。
    @MainActor
    static func current(forSkinShape skinShape: OneSkinShape, width: CGFloat) -> PlayerControlsLayout {
        PlayerControlsLayout(stored: stored(for: shape(for: skinShape, width: width)))
    }
    #endif

    /// 按当前形态读一份布局（播放器与皮肤都走这个，不要再自己读裸键）。
    ///
    /// 传入的是**当前可用空间**（不是屏幕尺寸）：Duo 的两块屏、Split View 半边、
    /// 被 PiP 压短的高度，都应当影响这一份配置的选择。
    @MainActor
    static func current(forSize size: CGSize) -> PlayerControlsLayout {
        PlayerControlsLayout(stored: stored(for: currentShape(width: size.width, height: size.height)))
    }

    /// 只有宽度时的便捷入口（旧调用点保留）。高度未知 → 按竖持处理。
    @MainActor
    static func current(forWidth width: CGFloat) -> PlayerControlsLayout {
        current(forSize: CGSize(width: width, height: 0))
    }

    /// The number of fixed slots in the top bar and in the bottom bar.
    static let slotCount = 10
    /// The empty-slot marker in the stored form.
    private static let empty = "-"

    var topSlots: [PlayerControl?]
    var bottomSlots: [PlayerControl?]
    var more: [PlayerControl]

    /// 选集页控制栏直接显示的控件集合（其余进「更多」菜单）。
    ///
    /// 与 `topSlots` 的区别：槽位决定**顺序与位置**，这两个集合决定
    /// **在哪种播放状态下真的出现在控制栏里**。一个控件可以同时在两个集合里
    /// （选集页和全屏都直接显示），互不冲突 —— 这是用户明确要求的形式。
    var watchSurfaced: [PlayerControl]
    /// 全屏态控制栏直接显示的控件集合。
    var fullSurfaced: [PlayerControl]

    /// The non-empty controls in each row, in slot order.
    var top: [PlayerControl] { topSlots.compactMap { $0 } }
    var bottom: [PlayerControl] { bottomSlots.compactMap { $0 } }

    init(topSlots: [PlayerControl?], bottomSlots: [PlayerControl?], more: [PlayerControl],
         watchSurfaced: [PlayerControl]? = nil, fullSurfaced: [PlayerControl]? = nil) {
        self.topSlots = Self.normalized(topSlots)
        self.bottomSlots = Self.normalized(bottomSlots)
        self.more = more
        // 没给就走默认：选集页显示常用那几个，全屏只显示 transport 相关。
        self.watchSurfaced = watchSurfaced ?? Self.defaultWatchSurfaced
        self.fullSurfaced = fullSurfaced ?? Self.defaultFullSurfaced
    }

    /// 选集页默认直接显示：顶栏标配的那两颗（AirPlay、选集）。
    ///
    /// 这里曾经写着「画中画、小窗、外播、视频信息、选集」，但那四项并不在顶栏槽位里 ——
    /// 可见性集合与槽位必须同时成立才会画出来，于是默认值里有四项**永远画不出来**，
    /// 而设置页却把它们显示成「已勾选」。默认值只列真能出现的，其余由用户勾（勾上即补位）。
    static let defaultWatchSurfaced: [PlayerControl] = [.airPlay, .episodes]
    /// 全屏默认只显示 playback 类（其余全屏里没意义，或会盖住画面）。
    static let defaultFullSurfaced: [PlayerControl] = []

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
            self.init(topSlots: parseSlots(parts[0]), bottomSlots: parseSlots(parts[1]),
                      more: parts[2].split(separator: ",").compactMap { PlayerControl(rawValue: String($0)) },
                      watchSurfaced: parts[3].split(separator: ",").compactMap { PlayerControl(rawValue: String($0)) },
                      fullSurfaced: parts[4].split(separator: ",").compactMap { PlayerControl(rawValue: String($0)) })
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
        let surfacedWatch = self.watchSurfaced
        let surfacedFull = self.fullSurfaced
        var top = self.top, bottom = self.bottom, more = self.more
        let placed = Set(top + bottom + more)
        for control in PlayerControl.standardTop where !placed.contains(control) { top.append(control) }
        for control in PlayerControl.standardBottom where !placed.contains(control) { bottom.append(control) }
        for control in PlayerControl.standardMore where !placed.contains(control) { more.append(control) }
        self.init(topSlots: top.map(Optional.some), bottomSlots: bottom.map(Optional.some), more: more,
                  watchSurfaced: surfacedWatch, fullSurfaced: surfacedFull)
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

    /// 勾上「直接显示」时把控件摆进顶栏第一个空位。
    ///
    /// 顶栏槽位决定位置、勾选集合决定可见性，两者**必须同时成立**控件才画出来。只勾不摆，
    /// 就是「设置里勾了、播放器里没有」—— 所以勾选顺手补位，摆在哪里之后再拖。顶栏满了、
    /// 或它本来就在顶栏，就原地不动（不挤掉别人）。
    mutating func surfaceInTopRow(_ control: PlayerControl) {
        guard !top.contains(control), let free = topSlots.firstIndex(where: { $0 == nil }) else { return }
        remove(control)
        topSlots[free] = control
    }
}
#endif
