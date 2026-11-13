#if os(iOS)
import SwiftUI
import AVKit
import MediaPlayer
import TVCore

/// How the picture meets the box the page gives it.
///
/// Every shape used to force its own answer: held sideways, unfolded, or on the Duo's cover screen the picture
/// was cropped to fill, because a fitted frame left bands the page could not use. That was a guess about the
/// stream — a 2.35:1 film on the inner display lost a third of its width, a 4:3 one lost its top and bottom.
/// The box now follows the stream itself unless the viewer says otherwise, and the choice is one setting shared
/// by every shape, so a picture the viewer decided on stays that way when the Duo folds or the phone turns.
enum PictureScaling: String, CaseIterable, Identifiable {
    /// 适应片源: the box takes the stream's own shape, so the whole picture shows and nothing is cropped.
    /// Where the layout fixes the box instead (a split column, full screen), the picture fits inside it
    /// and black bands take the rest — the same result as the "fill with bars" pick this replaced, but
    /// without asking the viewer to choose between two options that drew the identical picture.
    case source
    /// 铺满: the box stays, the picture grows until it covers it, edges cropped.
    case fill
    /// 拉伸: the box stays, the picture is stretched onto it, whatever its shape.
    case stretch

    var id: String { rawValue }

    /// Stored under one key: the pick follows the viewer across titles, shapes and launches.
    static let key = "pictureScaling"

    /// Only this one changes the box; the rest keep it and change the picture inside it.
    var followsSource: Bool { self == .source }

    var gravity: AVLayerVideoGravity {
        switch self {
        case .source: return .resizeAspect
        case .fill: return .resizeAspectFill
        case .stretch: return .resize
        }
    }

    var title: String {
        switch self {
        case .source: return L10n.text("Fit to Source")
        case .fill: return L10n.text("Crop to Fill")
        case .stretch: return L10n.text("Stretch")
        }
    }

    var symbol: String {
        switch self {
        case .source: return "aspectratio"
        case .fill: return "rectangle.fill"
        case .stretch: return "arrow.left.and.right"
        }
    }
}

/// The iPhone and iPad player. The picture plays in a layer of our own and every control is drawn here: AVKit's
/// controls on iOS keep AirPlay and volume in a row of their own above anything laid over them and take no buttons
/// of ours, so the title, our buttons, AirPlay and Picture in Picture couldn't share one row. Back and the title sit
/// on the left of the top row, the buttons on the right, play and skip in the middle, and the seek bar at the bottom.
struct MobilePlayerView: View {
    let channel: Channel
    let session: PlaybackSession
    @Binding var showsDanmaku: Bool
    @Binding var upscalesVideo: Bool
    @Binding var smoothsVideo: Bool
    var waiting: PlaybackWaitContent?
    /// Whether the controls show. The player screen runs the timer that hides them.
    let chromeVisible: Bool
    /// A tap on the picture shows or hides the controls.
    let toggleChrome: () -> Void
    /// A control was used: the controls stay up a while longer.
    let poke: () -> Void
    /// The seek bar is held (true) or let go (false): the controls stay up until it is let go.
    let hold: (Bool) -> Void
    let close: () -> Void
    /// The whole screen, or the top of an iPhone watch page.
    var layout: MobilePlayerLayout = .screen
    /// The picture on a watch page owns a full-height column (held sideways, unfolded) rather than a
    /// strip at the top, so its chrome is the roomy kind and keeps clear of the notch and the home
    /// indicator instead of hugging the box's edges.
    var immersive: Bool = false
    /// On a watch page: Full Screen, or back to the page.
    var toggleFullScreen: (() -> Void)? = nil
    /// Open the episode picker from the options menu.
    var openEpisodes: () -> Void = {}
    /// Float the video in-app: back to the main interface while it keeps playing in the mini player.
    var miniplayer: () -> Void = {}
    /// The picture's width over height, once the stream is known: the page sizes its box from it.
    var aspect: (CGFloat) -> Void = { _ in }

    /// The subtitle file on screen, or nil when the channel offers none or it has not loaded.
    private var activeSubtitleTrack: SubtitleTrack? {
        guard let id = chosenSubtitle else { return subtitleTracks.first }
        return subtitleTracks.first { $0.id == id }
    }

    /// Reads the stored appearance and positions, then loads this channel's subtitle files.
    /// Called from the view's task so a title change reloads rather than reusing the old cues.
    private func loadSubtitles() async {
        if let style = try? JSONDecoder().decode(Mi3sSubtitleStyle.self, from: subtitleStyleData) {
            subtitleStyle = style.sanitized
        } else if subtitleStyleData.isEmpty,
                  let legacy = UserDefaults.standard.data(forKey: Mi3sSubtitleStyle.legacyStorageKey),
                  let style = try? JSONDecoder().decode(Mi3sSubtitleStyle.self, from: legacy) {
            // [mi3s] 二开：升级一次性迁移。旧版把自绘外观存在上游那个键上；能按我方模型解出来就
            // 说明是我们自己写的那份，接过来并落到新键。上游 `SubtitleStyle` 的 JSON 字段完全不同，
            // 在这里解不出来，因此不会被误当成自绘外观搬走。
            subtitleStyle = style.sanitized
            saveSubtitleStyle()
        }
        if let memory = try? JSONDecoder().decode(SubtitlePositionMemory.self, from: subtitlePositionsData) {
            subtitlePositions = memory
        }
        // Put the bubble back where it was left for this title.
        let remembered = subtitlePositions.position(for: channel.url.absoluteString)
        subtitleStyle.centerX = remembered.x
        subtitleStyle.centerY = remembered.y

        let files = channel.subtitles
        guard !files.isEmpty else { subtitleTracks = []; return }
        subtitleTracks = await SubtitleTrack.loadAll(files, headers: channel.headers)
        // While the overlay is drawing a track, the player must not draw its own, or both appear.
        // Selecting nothing is how AVPlayer turns a legible track off.
        if !subtitleTracks.isEmpty, let group = tracks.legible { tracks.select(nil, in: group) }
    }

    /// The segment the playhead is inside, if any. Credits win at the end of a file, and the intro
    /// wins anywhere else, so a marker that overlaps another cannot show two buttons.
    private var currentSkipSegment: SkipSegmentSources.Segment? {
        let position = clock.position
        if let credits = skipCredits, position >= credits.start, position < credits.end { return credits }
        return skipSegment
    }

    /// Asks each configured source for an intro/credits marker and keeps the first usable one.
    ///
    /// Only file-level sources are trusted directly. A title-level database describes a different
    /// cut, so its segment is accepted only when the timing actually fits this file — the check
    /// lives in `SkipSegmentSources.choose`, and `skipIsFileLevel` records which kind won so the
    /// button can behave accordingly.
    private func loadSkipSegment() async {
        skipSegment = nil
        skipCredits = nil
        skipIsFileLevel = false
        guard let item = clock.item else { return }
        let duration = clock.duration > 0 ? clock.duration : 0

        // One dictionary per kind: a dictionary can hold one segment per source, and the viewer's
        // markers can name both an intro and a credits segment.
        var intro: [SkipSegmentSources.Source: SkipSegmentSources.Segment] = [:]
        var credits: [SkipSegmentSources.Source: SkipSegmentSources.Segment] = [:]

        // The viewer's own markers: the intro end and outro length they set on the episode skip
        // page. Highest authority, and the only source that works offline with no chapters.
        if store.skipSources.isActive(.manual), let scope = channel.skipScope {
            let settings = EpisodeSkipSettings.load(scope: scope)
            if settings.introEnd > 0 {
                intro[.manual] = SkipSegmentSources.Segment(kind: .intro, start: 0, end: settings.introEnd)
            }
            if settings.outroLength > 0, duration > settings.outroLength {
                credits[.manual] = SkipSegmentSources.Segment(
                    kind: .credits, start: duration - settings.outroLength, end: duration)
            }
        }
        // Chapters are the other file-level source, available without a network call.
        if store.skipSources.isActive(.mediaServer),
           let chapters = chapterSegments(of: item) {
            intro[.mediaServer] = chapters
        }
        guard !intro.isEmpty || !credits.isEmpty else { return }

        if let chosen = store.skipSources.choose(kind: .intro, duration: duration, reported: intro) {
            skipSegment = chosen.segment
            skipIsFileLevel = chosen.source.isFileLevel
        }
        if let chosen = store.skipSources.choose(kind: .credits, duration: duration, reported: credits) {
            skipCredits = chosen.segment
            skipIsFileLevel = skipIsFileLevel || chosen.source.isFileLevel
        }
    }

    /// Reads the asset's own chapters as candidate intro/credits segments.
    ///
    /// A "chapter" is only useful here when there are at least three of them: with one or two, the
    /// chapter is the whole file or half of it, and neither is an intro.
    private func chapterSegments(of item: AVPlayerItem) -> SkipSegmentSources.Segment? {
        // No async variant of this property exists; it reads from metadata already loaded with the
        // asset, so calling it on the player's queue is cheap.
        let groups = item.asset.chapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)
        guard groups.count >= 3 else { return nil }
        let first = groups.first
        guard let start = first?.timeRange.start.seconds,
              let length = first?.timeRange.duration.seconds,
              start.isFinite, length.isFinite, length > 3 else { return nil }
        return SkipSegmentSources.Segment(kind: .intro, start: start, end: start + length)
    }

    /// Records what the picture is, and warns only when the answer is "this cannot be shown".
    ///
    /// The decision itself lives in `HDRDisplay`; this only reads the track's format description.
    /// Nothing is tone-mapped by hand — when the display cannot take HDR the system does it, and
    /// doing it here as well would clip the highlights twice.
    private func inspectColour() async {
        hdrNotice = nil
        guard let item = clock.item else { return }
        guard let track = try? await item.asset.loadTracks(withMediaType: .video).first,
              let descriptions = try? await track.load(.formatDescriptions),
              let description = descriptions.first else { return }

        let transfer = HDRDisplay.transfer(of: description)
        let action = HDRDisplay().action(
            for: transfer,
            displaySupportsHDR: await HDRDisplay.displaySupportsHDR()
        )
        if case let .unsupportedDolbyVision(reason) = action {
            hdrNotice = reason
        }
    }

    /// Writes the appearance back whenever it changes.
    /// Reports the picture's shape to the page, once, when it is known.
    ///
    /// The page sizes the player's box from this. Assuming 16:9 leaves letterbox bars *inside* the
    /// player for a 4:3 or 2.35:1 film — which is what the white strip at the right edge was.
    private func reportAspect() {
        guard let size = clock.item?.presentationSize, size.width > 0, size.height > 0 else { return }
        let ratio = size.width / size.height
        guard ratio.isFinite, ratio > 0.2, ratio < 6 else { return }
        // Kept here too: `.source` gives the picture this exact shape, so the box is the stream's
        // frame rather than a guess that leaves the page's own background at the edges.
        pictureAspect = ratio
        aspect(ratio)
    }

    private func saveSubtitleStyle() {
        if let blob = try? JSONEncoder().encode(subtitleStyle.sanitized) { subtitleStyleData = blob }
    }

    #if canImport(Speech)
    /// The language the viewer picked on the settings page, if any.
    @AppStorage(SpeechSubtitles.preferredLanguageKey) private var speechLanguageCode = ""

    /// The language to recognise in: the viewer's pick first, then the phone's own, then the two
    /// this app is most used in.
    ///
    /// Checked against the on-device models before the item is offered at all. A row that fails the
    /// moment it is tapped teaches the viewer the feature is broken, when the truth is that this
    /// device has no model for that language and nothing was ever going to happen.
    private var speechLanguage: String? {
        SpeechSubtitles.preferredLanguage(stored: speechLanguageCode)
    }

    /// Recognises the sound track and appends the result as another subtitle file.
    @MainActor
    private func generateSubtitles(language: String) {
        guard !generatingSubtitles else { return }
        generatingSubtitles = true
        subtitleProgress = 0
        subtitleError = nil
        // The headers matter: a source that needs a Referer answers nothing without them, and the
        // recogniser would read an error page as silence.
        let headers = channel.headers
        let asset = AVURLAsset(url: channel.url,
                               options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let name = L10n.text("Subtitles From the Sound")
        let hint = channel.name
        // Keep the handle so leaving the player cancels the export/recognition rather than
        // letting it run to completion with no one watching.
        speechTask = Task {
            do {
                let track = try await SpeechSubtitles().transcribe(asset: asset, language: language, name: name,
                                                                   hint: [hint]) { value in
                    Task { @MainActor in subtitleProgress = value }
                }
                subtitleTracks.removeAll { $0.id == track.id }
                subtitleTracks.append(track)
                chosenSubtitle = track.id
                generatingSubtitles = false
            } catch is CancellationError {
                generatingSubtitles = false
            } catch {
                subtitleError = Self.describe(error)
                generatingSubtitles = false
            }
        }
    }

    private static func describe(_ error: any Error) -> String {
        guard let failure = error as? SpeechSubtitles.Failure else { return error.localizedDescription }
        switch failure {
        case .languageUnavailable(let language): return L10n.text("No on-device speech model for %@.", language)
        case .notAuthorized: return L10n.text("Allow Speech Recognition in Settings to write subtitles.")
        case .noAudio: return L10n.text("This video has no sound track to read.")
        case .empty: return L10n.text("Nothing was recognised in this video's sound.")
        case .cancelled: return L10n.text("Cancelled.")
        case .failed(let reason): return reason
        }
    }
    #endif

    @Environment(Store.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// The viewer's player-control layout: which top-row buttons draw directly and which wait in More.
    @AppStorage(PlayerControlsLayout.storageKey) private var controlsOrder = PlayerControlsLayout.standard.stored
    @State private var pip = PictureInPicture()
    @State private var clock = PlayerClock()
    @State private var tracks = MediaTracks()
    @State private var nowPlaying = VideoNowPlaying()
    /// How the picture meets its box. Persisted, and the same in every shape.
    @AppStorage(PictureScaling.key) private var scalingRaw = PictureScaling.source.rawValue
    /// The stream's own shape, once the item reports it: the box follows it in `.source`.
    @State private var pictureAspect: CGFloat?
    @State private var speed: Float = 1
    @AppStorage(DanmakuArea.key) private var danmakuArea = DanmakuArea.standard
    /// 广告拦截总开关。与设置页、One 皮肤、HLS 代理**同一个键**（`player.skipAds`）。
    /// 用 `@AppStorage` 而不是读 `AdSkip.enabled`：后者是计算属性，
    /// SwiftUI 不知道它变了，开关点了图标不换。
    @AppStorage(AdSkip.key) private var skipsAds = true
    @State private var showsDanmakuList = false
    /// 「更多本剧」/「跳过片头片尾」两个 sheet。
    ///
    /// 这两项在 One 皮肤里就有，收进 `PlayerControl` 枚举之后，原版播放器的
    /// 设置页也会把它们列出来 —— 但这里的渲染分支原先一律 `EmptyView()`，
    /// 用户在原版里把它们摆到控制栏得到的是空槽。现在补齐实现，
    /// 两套皮肤用同一对上游视图（`SeriesSuggestionSheet` / `EpisodeSkipSettingsView`）。
    @State private var showsSeries = false
    @State private var showsSkip = false
    /// 正在标注广告（防止连点，顺带给按钮一个忙碌态）。
    @State private var markingAd = false
    /// Set to the stream's address when the viewer asks to hand it to another app.
    @State private var externalPlayerStream: HandoffStream?
    /// The intro or credits segment for this item, once a source has claimed one.
    @State private var skipSegment: SkipSegmentSources.Segment?
    /// The end-of-episode segment, kept apart because the playhead can be in either one.
    @State private var skipCredits: SkipSegmentSources.Segment?
    /// Whether that segment came from a source that knows this exact file.
    @State private var skipIsFileLevel = false
    /// Set when the file is Dolby Vision this device cannot decode; shown once, not as a dialog.
    @State private var hdrNotice: String?
    /// The subtitle files this channel offers, parsed once per title. Drawn by `SubtitleOverlay`
    /// rather than by the player, so size, opacity and position can be set.
    @State private var subtitleTracks: [SubtitleTrack] = []
    @State private var chosenSubtitle: String?
    /// Set while the on-device recogniser is working through this title's sound track.
    @State private var generatingSubtitles = false
    /// The running speech-to-subtitle task, so leaving the player cancels it instead of
    /// letting a 40-minute export finish on its own with no one watching.
    @State private var speechTask: Task<Void, Never>?
    @State private var subtitleProgress: Double = 0
    /// Why the last attempt produced nothing, shown in place of the menu item.
    @State private var subtitleError: String?
    /// Persisted appearance, shared by every title.
    // [mi3s] 二开：键位与上游分开（见 `Mi3sSubtitleStyle.storageKey`）。共用一个键时，
    // 设置页的「Subtitle Style」与这里各自把对方写成默认值。
    @AppStorage(Mi3sSubtitleStyle.storageKey) private var subtitleStyleData = Data()
    /// Where the bubble was dragged to, per title.
    @AppStorage("subtitlePositions") private var subtitlePositionsData = Data()
    @State private var subtitleStyle = Mi3sSubtitleStyle.standard
    @State private var subtitlePositions = SubtitlePositionMemory()
    /// Devices with Yingxia open, for the Play On button; and the one the video was sent to.
    @State private var tvBrowser = PlayOnBrowser()
    @State private var playingOn: String?
    /// Touching and holding the picture plays faster while the finger is down, or after sliding down kept it.
    @State private var boost: SpeedBoost?
    @State private var holding = false
    @AppStorage(SpeedBoost.key) private var holdSpeed = SpeedBoost.standard
    @AppStorage(PlaybackInfo.key) private var showsPlaybackInfo = false
    /// Double taps on a side skip (YouTube); the run's total shows on that side for a moment.
    @State private var taps = PictureTaps()
    @State private var skipped: (forward: Bool, total: Double)?
    @State private var skippedTask: Task<Void, Never>?
    /// Controls a tap just brought up let a second tap through to the picture, which may be a double tap.
    @State private var settling = false
    @State private var settleTask: Task<Void, Never>?
    /// Sliding sideways across the picture: where the slide began.
    @State private var swipeStart: Double?
    /// Sliding up or down: the brightness on the left, the volume on the right, from where the slide began.
    @AppStorage(PictureLevel.key) private var slidesLevels = true
    /// 双击左右跳过 10 秒；关掉后双击改为播放/暂停（上游 1.8.12 的开关）。
    ///
    /// ⛔ 融合时这条判据丢了：上游 `972a75a` 在这一行加了 `doubleTapSkips &&`，
    /// 我方 `41930c4` 在同一行加了 `!controlsLocked &&` —— 两侧改同一行，
    /// 融合只能留一份，我方版本留存，开关的行为层整条消失（UI 也一并没了）。
    @AppStorage(PictureDoubleTap.key) private var doubleTapSkips = true
    @State private var level: (volume: Bool, start: Double, value: Double)?
    @State private var leveling = false
    @State private var levelTask: Task<Void, Never>?
    /// The system's volume slider, on screen only around a slide, which keeps the system's own volume overlay away.
    @State private var systemVolume = MusicVolumeSlider.SystemSlider()
    @State private var mountsVolume = false
    /// The screen's brightness before the first slide changed it, put back when the player closes.
    @State private var brightnessBefore: CGFloat?
    /// The viewer locked the controls: the picture's taps and slides do nothing, and the orientation
    /// stays put whatever the gyroscope says, until they unlock again.
    @State private var controlsLocked = false

    var body: some View {
        ZStack {
            // The picture no longer stretches to this box on every shape: `.source` gives it the stream's
            // own shape and this black sits behind the bands that leaves. Every other mode fills the box
            // and the black never shows, which is also what a letterboxed picture needs.
            Color.black.playerBleed(!inline)
            // [mi3s] 二开：画面载体按 One 的做法换成 `AVPlayerViewController`。
            //
            // 上游用 `AVPlayerLayer` + 自建 `AVPictureInPictureController`。那条路的代价写在
            // `PictureInPicture.makeController` 的注释里：折叠、转向、切页都会换一次 layer，
            // AVKit 每次都当成「用户离开 App」，于是自动 PiP 只能关掉（`= false`），
            // 悬浮窗也就只有手动点一下才有。
            //
            // One 用 `AVPlayerViewController`，PiP 由 AVKit 托管，不存在换 layer 的误判，
            // 所以它能开自动 PiP。这里照它的机制走：iOS 上用 AVKit 的控制器承载画面，
            // 其余平台（Mac/tvOS）仍用原来的 `PlayerLayerView`。
            //
            // 悬浮窗的**样子**不受影响：浮起来的是系统 PiP 窗口，里面画的是同一个
            // `AVPlayer`，字幕仍按 `pip.active` 交还给 AVPlayer 自绘（见下面的 onChange）。
            pictureCarrier
                // [mi3s] 与上游一致：Picture in Picture 只显示 player layer，自绘的
                // Mi3sSubtitleOverlay 进不去那个窗口。进 PiP 时把字幕交还给 AVPlayer 自己画
                // （`native = true`），退出时收回自绘层。不这样 PiP 里就没有字幕。
                .onChange(of: pip.active) { _, active in session.subtitles.native = active }
                .onChange(of: PictureInPicture.isActive) { _, active in session.subtitles.native = active }
            // The enhanced picture covers the layer's own, under everything else. It bleeds exactly the
            // edges the AVPlayer layer does, so the two pictures never disagree and leave a strip of page
            // down one side. On a watch page it stays inside the box the page measured: bleeding sideways
            // there made the picture wider than the column it was given, and the page's clip cut the film.
            EnhancedVideoSurface(enhancer: session.enhancer, gravity: pictureGravity,
                                 bleeds: inline ? [] : .all)
                .pictureBox(scaling, aspect: pictureAspect)
            if showsDanmaku && !session.danmaku.isEmpty {
                DanmakuOverlay(player: session.player, comments: session.danmaku, opacity: session.danmakuOpacity, revision: session.danmakuRevision)
                    // Across the whole width, but below the Dynamic Island and above the home indicator when upright.
                    .playerBleed(!inline, edges: .horizontal)
            }
            // Parsed subtitle tracks are drawn here, not by the player, so they can be resized and
            // moved. Empty when the channel offers no subtitle files, so a film without them is
            // untouched.
            Mi3sSubtitleOverlay(
                track: activeSubtitleTrack,
                position: clock.position,
                style: $subtitleStyle,
                positionKey: channel.url.absoluteString,
                memory: $subtitlePositions
            )
            .playerBleed(!inline, edges: .horizontal)
            .allowsHitTesting(activeSubtitleTrack != nil)
            // Floating, not a sheet: an intro is short, and dismissing a dialog takes longer than
            // the intro does.
            if let segment = currentSkipSegment {
                SkipSegmentButton(segment: segment, position: clock.position, isFileLevel: skipIsFileLevel) {
                    clock.seek(to: segment.end)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 20)
                .padding(.bottom, inline ? 84 : 128)
                .playerBleed(!inline, edges: .horizontal)
            }
            if let hdrNotice {
                VStack {
                    Spacer(minLength: 0)
                    // The reason, not a generic sentence: "this file's Dolby Vision profile cannot
                    // be decoded here" tells the viewer to pick another source, which a bare
                    // "Unsupported" does not.
                    Label(hdrNotice, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.black.opacity(0.66), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.bottom, inline ? 60 : 110)
                }
                .allowsHitTesting(false)
            }
            stallNotice
            // The artwork dissolves into the first frame.
            if let waiting {
                if inline {
                    // On a watch page: the cover across the player, blurred, as before it started; the full-screen
                    // player keeps its own wait.
                    Group {
                        if waiting.starting { WatchCoverBackdrop(poster: waiting.artwork.poster, headers: waiting.artwork.headers, loading: session.error == nil) }
                        else { WaitSpinner(status: waiting.state) }
                    }
                    .transition(.opacity)
                } else {
                    waiting.view.playerBleed(true).transition(.opacity)
                }
            }
            if pip.active || PictureInPicture.isActive { pipPlaceholder }
            if playingOn != nil { Color.black.playerBleed(!inline) }
            // A tap on the picture shows or hides the controls; a tap on a control keeps them up (see `rows`).
            // Two taps on a side skip, touching and holding plays faster, and sliding sideways seeks.
            PictureGestures(tap: tapped, hold: held, swipe: swiped, levels: slidesLevels) { wider in
                withAnimation(.easeInOut(duration: 0.25)) { setScaling(wider ? .fill : .source) }
            }
            .playerBleed(!inline)
            .accessibilityHidden(true)
            if mountsVolume {
                MusicVolumeSlider.HiddenVolumeView(system: systemVolume).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
            }
            boostLabel
            skippedLabel
            swipeLabel
            levelLabel
            if let playingOn {
                PlayOnPlaceholder(receiver: playingOn) {
                    self.playingOn = nil
                    if session.paused { session.togglePlayback() }
                }
            }
            // The controls take its corner while they show; it comes back with the bare picture.
            if showsPlaybackInfo && session.error == nil && session.showsPicture && !pip.active && playingOn == nil {
                PlaybackInfoPanel(session: session)
                    .padding(inline ? 8 : 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .opacity(chromeVisible ? 0 : 1)
                    .animation(.smooth(duration: 0.25), value: chromeVisible)
            }
            controls.opacity(chromeVisible ? 1 : 0).allowsHitTesting(chromeVisible && !settling && !controlsLocked)
            // Locked: the whole chrome goes read-only (the picture's taps still reveal it, but nothing
            // in it reacts) and a single unlock button floats over the picture as the only way out.
            if controlsLocked {
                Button { toggleLock() } label: {
                    Image(systemName: "lock.fill")
                }
                .buttonStyle(PlayerCircleStyle(size: 56))
                .accessibilityLabel(L10n.text("Unlock Controls"))
                .accessibilityIdentifier("player.unlock")
                .opacity(chromeVisible ? 1 : 0)
                .allowsHitTesting(chromeVisible)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .animation(.easeInOut(duration: 0.7), value: waiting == nil)
        .animation(.easeInOut(duration: 0.4), value: waiting?.starting)
        .onAppear {
            clock.attach(session.player)
            speed = session.player.defaultRate
            nowPlaying.start(session)
            nowPlaying.update(title: channel.name, session: session)
            tvBrowser.start()
            // AVKit's queued advance is unreliable inside the floating window, so while PiP is up the
            // session falls back to the ordinary end-of-episode switch, which works everywhere. Sync the
            // current state too: this view can be rebuilt (a Duo fold/unfold) while PiP is already active,
            // and a rebuild re-runs onAppear but never re-fires onActiveChange — leaving the queue enabled
            // inside the floating window would silently break auto-advance there.
            session.queueingDisabled = pip.active || PictureInPicture.isActive
            pip.onActiveChange = { session.queueingDisabled = $0 }
        }
        .onDisappear {
            clock.detach(); nowPlaying.stop(); tvBrowser.stop()
            speechTask?.cancel(); speechTask = nil
            if let brightnessBefore { screen?.brightness = brightnessBefore }
        }
        // Played here again (the Lock Screen, say): the other device no longer has it to itself.
        .onChange(of: session.paused) { _, paused in if !paused { playingOn = nil } }
        .onChange(of: nowPlayingState, initial: true) { nowPlaying.update(title: channel.name, session: session) }
        .onChange(of: nowPlayingArtwork, initial: true) { _, artwork in nowPlaying.show(artwork, session: session) }
        // Pausing ends the faster speed in the session; another episode or quality plays at the chosen one.
        .onChange(of: session.boost == nil) { _, ended in if ended { boost = nil } }
        .onChange(of: clock.item) { endBoost() }
        .sensoryFeedback(trigger: boost) { old, new in
            guard let new else { return nil }
            guard let old else { return .impact(weight: .light) }
            return new.locked != old.locked ? .impact(weight: .medium) : new.rate != old.rate ? .selection : nil
        }
        .sheet(item: $externalPlayerStream) { handoff in
            Mi3sExternalPlayerMenu(stream: handoff.url, headers: channel.headers)
        }
        .task(id: clock.item.map(ObjectIdentifier.init)) {
            await tracks.load(clock.item)
            await loadSubtitles()
            await loadSkipSegment()
            await inspectColour()
            reportAspect()
            // `presentationSize` is zero until the item is ready, so the shape is polled for a few
            // seconds rather than read once and lost: without it `.source` would fall back to filling
            // the box, which is the crop this setting exists to remove.
            for _ in 0 ..< 40 where pictureAspect == nil {
                try? await Task.sleep(for: .milliseconds(150))
                reportAspect()
            }
        }
        // The duration arrives after the item does, and the credit roll is measured back from the
        // end of the file: resolved once at item load, when it is still zero, the skip-credits
        // marker could never be placed. Resolve again the first time it becomes known.
        .onChange(of: clock.duration > 0) { _, known in
            guard known else { return }
            Task { await loadSkipSegment() }
        }
        // Persist the caption appearance whenever it changes, so a resize survives the next launch.
        .onChange(of: subtitleStyle) { _, _ in saveSubtitleStyle() }
        .onChange(of: subtitlePositions) { _, _ in
            if let blob = try? JSONEncoder().encode(subtitlePositions) { subtitlePositionsData = blob }
        }
        .sheet(isPresented: $showsDanmakuList) {
            DanmakuListView(player: session.player, comments: session.danmaku) { showsDanmakuList = false }
                .danmakuListPresentation()
        }
        // 广告拦截开关当场生效（见 `PlaybackSession.adBlockingDidChange`）。
        .onChange(of: skipsAds) { _, enabled in
            session.adBlockingDidChange(enabled: enabled)
        }
        .sheet(isPresented: $showsSeries) { SeriesSuggestionSheet(channel: channel) }
        .sheet(isPresented: $showsSkip) { EpisodeSkipSettingsView(session: session) }
    }

    /// What the Lock Screen's Now Playing shows, besides the position the system runs on from the rate.
    private struct NowPlayingState: Equatable {
        var title: String
        var paused: Bool
        var live: Bool
        var timeline: Bool
        var duration: Double
        var speed: Float
        var boost: Float?
    }

    private var nowPlayingState: NowPlayingState {
        NowPlayingState(title: channel.name, paused: session.paused, live: session.isLive, timeline: session.hasTimeline,
                        duration: clock.duration, speed: speed, boost: session.boost)
    }

    /// The poster the waiting screen shows, for the Lock Screen and Control Center.
    private var nowPlayingArtwork: PlaybackArtwork {
        let catalog = store.catalog(for: channel)
        return PlaybackArtwork(poster: catalog?.video.poster ?? channel.historyContext?.poster,
                               headers: catalog?.video.posterHeaders ?? channel.historyContext?.posterHeaders ?? [:])
    }

    // MARK: Taps and slides

    private func tapped(_ x: CGFloat, _ width: CGFloat) {
        // Locked controls: a tap only shows or hides them; it never pauses or skips.
        // `doubleTapSkips` off: two taps anywhere play or pause, and the sides don't skip.
        let zone = PictureTaps.zone(x: x, width: width, seekable: doubleTapSkips && !controlsLocked && seekable && showsTransport && playingOn == nil && !pip.active)
        switch taps.tap(at: ProcessInfo.processInfo.systemUptime, in: zone) {
        case .toggleControls:
            // Locked controls stay put: a tap may reveal the chrome (so the lock button stays reachable)
            // but never hides it or pauses — "lock" means the picture and the controls both stop reacting.
            if controlsLocked {
                if !chromeVisible { toggleChrome() }
                return
            }
            let showing = !chromeVisible
            toggleChrome()
            if showing { settle(); clearLabels() }
        case .togglePlayback:
            if controlsLocked { break }
            toggleChrome()
            session.togglePlayback()
        case .skip(let seconds, let total, _):
            // Hidden whether the first tap showed the controls or hid them.
            hideChrome()
            session.skip(seconds)
            nowPlaying.update(title: channel.name, session: session)
            withAnimation(.snappy(duration: 0.25)) { skipped = (seconds > 0, total) }
            skippedTask?.cancel()
            skippedTask = Task {
                try? await Task.sleep(for: .seconds(PictureTaps.streak + 0.1))
                if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { skipped = nil } }
            }
        }
    }

    /// For as long as a second tap would make a double tap, it reaches the picture rather than the controls it showed.
    private func settle() {
        settling = true
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(for: .seconds(PictureTaps.interval))
            if !Task.isCancelled { settling = false }
        }
    }

    /// A gesture's label has the picture to itself: the controls make way, unless loading or a failure keeps them up.
    private func hideChrome() {
        if chromeVisible && showsTransport { toggleChrome() }
    }

    /// The controls a tap brings up replace the labels a skip or a slide leaves for a moment.
    private func clearLabels() {
        skippedTask?.cancel(); skipped = nil
        guard !leveling else { return }
        levelTask?.cancel(); level = nil; mountsVolume = false
    }

    private var screen: UIScreen? { UIApplication.shared.appWindowScene?.screen }

    private func swiped(_ phase: PictureGestures.Swipe) {
        if controlsLocked { return }
        switch phase {
        case .began(.seek):
            guard showsTransport, seekable, clock.duration > 0, playingOn == nil, !pip.active else { return }
            let start = clock.currentPosition
            swipeStart = start
            clock.scrub(to: start)
            hideChrome()
        case .began(let slide):
            let volume = slide == .volume
            guard volume || screen != nil else { return }
            let start = volume ? Double(AVAudioSession.sharedInstance().outputVolume) : Double(screen?.brightness ?? 0)
            if !volume, brightnessBefore == nil { brightnessBefore = screen?.brightness }
            levelTask?.cancel()
            if volume { mountsVolume = true }
            level = (volume, start, start)
            leveling = true
            hideChrome()
        case .moved(let moved, let size):
            if let swipeStart {
                clock.scrub(to: PictureSeek.target(from: swipeStart, moved: moved.width, width: size.width, duration: clock.duration))
            } else if leveling, var level {
                level.value = PictureLevel.value(from: level.start, moved: moved.height, height: size.height)
                self.level = level
                if level.volume { systemVolume.set(level.value) } else { screen?.brightness = CGFloat(level.value) }
            }
        case .ended:
            if swipeStart != nil {
                swipeStart = nil
                clock.endScrub()
                nowPlaying.update(title: channel.name, session: session)
            }
            if leveling {
                leveling = false
                levelTask = Task {
                    try? await Task.sleep(for: .seconds(0.8))
                    guard !Task.isCancelled else { return }
                    level = nil; mountsVolume = false
                }
            }
        }
    }

    /// The brightness or the volume a slide up or down sets, in the middle.
    @ViewBuilder private var levelLabel: some View {
        if let level {
            HStack(spacing: 12) {
                Image(systemName: level.volume ? (level.value <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill") : "sun.max.fill")
                    .frame(width: 26)
                Capsule().fill(.white.opacity(0.3)).frame(width: 150, height: 6)
                    .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 150 * level.value, height: 6) }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 14)
            .glassSurface(.regular, in: Capsule())
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text(level.volume ? "Volume" : "Brightness"))
            .accessibilityValue(Text(level.value, format: .percent.precision(.fractionLength(0))))
            .accessibilityIdentifier("player.level")
        }
    }

    /// How far a run of double taps skipped, on its side.
    @ViewBuilder private var skippedLabel: some View {
        if let skipped {
            // Glass like the other gesture labels, with the skip buttons' symbol; it bounces on each further tap.
            VStack(spacing: 4) {
                Image(systemName: skipped.forward ? "goforward.10" : "gobackward.10")
                    .font(.system(size: 30, weight: .medium))
                    .symbolEffect(.bounce, value: skipped.total)
                Text((skipped.forward ? "+" : "\u{2212}") + L10n.text("%lld s", Int(skipped.total)))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText(value: skipped.total))
            }
            .foregroundStyle(.white)
            .frame(width: 96, height: 96)
            .glassSurface(.regular, in: Circle())
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: skipped.forward ? .trailing : .leading)
            .padding(.horizontal, 48)
            .allowsHitTesting(false)
            .transition(.scale(scale: 0.8, anchor: skipped.forward ? .trailing : .leading).combined(with: .opacity))
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("player.tapSkip")
            .accessibilityValue("\(skipped.forward ? "+" : "-")\(Int(skipped.total))")
        }
    }

    /// Where a slide across the picture will seek to: the frame there, the time and how far it moves.
    @ViewBuilder private var swipeLabel: some View {
        if let swipeStart {
            let target = clock.scrubbing ?? swipeStart
            let moved = target - swipeStart
            VStack(spacing: 10) {
                if let preview = clock.preview {
                    Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Text(SeekBar<EmptyView>.format(target) + " / " + SeekBar<EmptyView>.format(clock.duration))
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text((moved < 0 ? "\u{2212}" : "+") + SeekBar<EmptyView>.format(abs(moved)))
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
            }
            .foregroundStyle(.white)
            .padding(16)
            .glassSurface(.regular, in: RoundedRectangle(cornerRadius: 20))
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("player.swipeSeek")
            .accessibilityValue("\(Int(target))")
        }
    }

    // MARK: Touch and hold

    /// Only while a video with a timeline plays here.
    private var boosts: Bool { showsTransport && seekable && !session.paused && playingOn == nil && !pip.active }

    private func held(_ phase: PictureGestures.Hold) {
        if controlsLocked { return }
        switch phase {
        case .began:
            guard boosts else { return }
            // A new hold replaces a kept speed: it ends with the finger unless slid down again.
            let started = SpeedBoost(rate: holdSpeed)
            boost = started; holding = true
            session.setBoost(Float(started.rate))
            // The picture to itself, as in YouTube and Douyin.
            hideChrome()
        case .moved(let offset):
            guard holding, var moved = boost else { return }
            moved.moved(x: offset.width, y: offset.height)
            guard moved != boost else { return }
            if moved.rate != boost?.rate { session.setBoost(Float(moved.rate)) }
            boost = moved
        case .ended:
            guard holding else { return }
            holding = false
            if boost?.locked != true { endBoost() }
        }
    }

    private func endBoost() {
        boost = nil; holding = false
        session.setBoost(nil)
    }

    /// The faster speed at the top, as in Douyin and YouTube; once kept, a tap on it goes back to the chosen speed.
    @ViewBuilder private var boostLabel: some View {
        if let boost {
            let rate = session.boost ?? Float(boost.rate)
            VStack(spacing: 8) {
                Button(action: endBoost) {
                    HStack(spacing: 6) {
                        if boost.locked { Image(systemName: "lock.fill") }
                        Text(Self.speedLabel(rate))
                        // Held lower than asked: the connection can't keep up with the faster speed.
                        if let wanted = session.boostWanted { Text(Self.speedLabel(wanted)).strikethrough().opacity(0.55) }
                        Image(systemName: "forward.fill")
                    }
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassSurface(.regular, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(boost.locked)
                .accessibilityLabel(L10n.text("Back to Normal Speed"))
                .accessibilityValue(Self.speedLabel(rate))
                .accessibilityIdentifier("player.boost")
                if session.boostWanted != nil {
                    Text(L10n.text("Slowed down to keep up with the connection"))
                        .font(.caption).shadow(color: .black.opacity(0.6), radius: 4)
                        .accessibilityHidden(true)
                } else if holding && !boost.locked {
                    Text(L10n.text("Slide sideways to change the speed, or down to keep it"))
                        .font(.caption).shadow(color: .black.opacity(0.6), radius: 4)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            // Below the top row when the controls show.
            .padding(.top, inline ? (chromeVisible ? 58 : 10) : chromeVisible ? 112 : 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.easeOut(duration: 0.2), value: chromeVisible)
            .transition(.opacity)
        }
    }

    /// Play, skip and the seek bar wait for the stream: while it connects or after it fails, only the top row shows.
    private var showsTransport: Bool { !session.loading && session.error == nil }
    /// A line that stopped making progress. Shown as a thin strip over the picture rather than a
    /// dialog: the picture stays visible, and the strip goes away by itself once progress resumes.
    ///
    /// Tapping it opens the episode picker, where the other lines for this episode are listed with
    /// their health. It used to say "Switching…" and switch nothing — there was no code behind the
    /// word, so the strip promised a recovery that never came and the viewer waited on a dead line.
    @ViewBuilder private var stallNotice: some View {
        if clock.stalled, showsTransport {
            VStack {
                Spacer(minLength: 0)
                Button { openEpisodes() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.footnote)
                        Text(L10n.text("This line has stopped. Choose another line"))
                            .font(.footnote)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.black.opacity(0.66), in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.bottom, inline ? 60 : 110)
                .transition(.opacity)
                .accessibilityIdentifier("player.stalled")
            }
            .animation(.easeOut(duration: 0.2), value: clock.stalled)
        }
    }
    /// At the top of a watch page: smaller controls, and the page has the title.
    private var inline: Bool { layout == .inline }

    /// Whether the screen itself is genuinely sideways. The Duo's folded outer display in portrait
    /// reports `regular × compact` — the *same* size classes as a phone held sideways — so
    /// `verticalSizeClass == .compact` alone mistook the upright outer screen for a landscape one.
    /// `screen.bounds.width > height` is also wrong: the Duo's inner display reports its *native*
    /// portrait bounds (2007×2853) even while `currentOrientation == .landscapeLeft/Right` (rot90),
    /// so a bounds comparison always read "upright" and the unfolded landscape used the portrait
    /// full-bleed layout — the picture flew off the edges. The interface orientation is the one
    /// signal that cannot lie: it is a discrete landscape/portrait, not a continuous width:height
    /// that sits at the critical point during the unfold/rotate animation and flips every frame.
    private var landscapeScreen: Bool {
        switch UIApplication.shared.appWindowScene?.interfaceOrientation {
        case .landscapeLeft, .landscapeRight: return true
        default: return false
        }
    }
    /// The viewer's pick, defaulting to the stream's own shape when nothing is stored yet.
    private var scaling: PictureScaling { PictureScaling(rawValue: scalingRaw) ?? .source }

    private func setScaling(_ mode: PictureScaling) {
        scalingRaw = mode.rawValue
    }

    /// The layer's gravity. While Picture in Picture is up the inline layer stays a fit: the floating
    /// window sizes itself from the source layer's gravity, and a fill would pin the window to the
    /// portrait box and crop the film inside it.
    private var pictureGravity: AVLayerVideoGravity {
        pip.active || PictureInPicture.isActive ? .resizeAspect : scaling.gravity
    }

    private var seekable: Bool { session.hasTimeline && !session.isLive }

    /// The picture on a watch page can own a full-height column (held sideways, or on the unfolded Duo),
    /// so its chrome gets the full-screen size even while the player is `.inline` — compact chrome would
    /// look lost on a picture that tall. A strip at the top of the page keeps the compact chrome.
    private var roomyChrome: Bool { !inline || immersive }

    private var controls: some View {
        ZStack {
            // Scrims, so white controls read over a bright picture.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: roomyChrome ? 150 : 70)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom).frame(height: roomyChrome ? 150 : 80)
            }
            // A full-height picture reaches the screen's edges; its scrim must too.
            .playerBleed(!inline)
            .allowsHitTesting(false)
            // One arrangement for every shape — folded, unfolded upright, held sideways. The Duo's
            // inner display used to switch to a sideways layout the moment it unfolded, tall or wide,
            // which put the transport in a column down the left of the picture and the buttons in a
            // column down the right: two bands of glass over a tall film, on the one screen with the
            // most room to show it.
            VStack(spacing: 0) {
                topRow
                Spacer(minLength: 0)
                if showsTransport { bottomRow }
                if showsTransport { bottomBar }
            }
            // Full Screen and a full-height watch column put the picture over the safe area, which
            // leaves the controls no inset of their own: Back sat under the notch on a landscape column
            // and the seek bar under the home indicator. Restore the inset here, on every shape that
            // bleeds — a strip at the top of the page is already inside the safe area.
            .safeAreaPadding(!inline ? .all : [])
            .padding(roomyChrome ? 16 : 8)
            // The picture keeps its middle: a face, a subtitle, a wide shot is never covered by a
            // button. Paused is the one time nothing is being watched, so that is the one time the
            // centre carries a play button — large, unmissable, and gone the moment it resumes.
            if session.paused, showsTransport, chromeVisible, playingOn == nil, !pip.active, !controlsLocked {
                centerPlay
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Top row

    /// One row when it fits; on a phone held upright, Back and the buttons share the first row and the title has the
    /// next one to itself, as in YouTube's player.
    @ViewBuilder private var topRow: some View {
        if inline {
            HStack(spacing: 8) {
                Button(action: close) { Image(systemName: "chevron.backward").font(.headline).frame(width: 22, height: 22) }
                    .chromeButton()
                    .accessibilityLabel(L10n.text("Back"))
                    .accessibilityIdentifier("player.close")
                Spacer(minLength: 0)
                // The buttons the viewer put in the bar, then the "more" menu with the rest. On a
                // watch page the episodes are listed right below the picture anyway.
                toolbar
            }
            .simultaneousGesture(TapGesture().onEnded { poke() })
        } else {
            screenTopRow
        }
    }

    private var screenTopRow: some View {
        PlayerTopBar {
            Button(action: close) { Image(systemName: "chevron.backward").font(.headline).frame(width: 22, height: 22) }
                .chromeButton()
                .accessibilityLabel(L10n.text("Back"))
                .accessibilityIdentifier("player.close")
                .keyboardShortcut(.cancelAction)
            Text(channel.name).font(.headline).lineLimit(1)
                .shadow(color: .black.opacity(0.6), radius: 4)
            toolbar
        }
        .simultaneousGesture(TapGesture().onEnded { poke() })
    }

    /// 按**当前形态**读控制栏排布（三形态各自独立，见 `PlayerControlsLayout.Shape`）。
    ///
    /// 仍然保留 `@AppStorage(storageKey)`（折叠态那个键）是为了让 SwiftUI 在设置页
    /// 改动后触发重绘：形态键是动态的，`@AppStorage` 无法动态选键，
    /// 所以这里用「折叠键变化」当刷新信号，实际值按形态现取。
    private var controlsLayout: PlayerControlsLayout {
        _ = controlsOrder   // 建立依赖，让设置页改动能重算
        return PlayerControlsLayout.current(forSize: sizeForShape)
    }

    /// 形态判定用的**尺寸**（宽 + 离散的横竖信号）。
    ///
    /// ⛔ 原来只给宽度（`current(forWidth:)` → `current(forSize: height: 0)` →
    /// `currentShape(height: 0)`），而 `currentShape` 在 `height <= 1` 时**直接返回 `.unfolded`**。
    /// 后果：设置页给了「折叠外屏 / 展开竖持 / 展开横持」三份独立配置，**原版永远只读第二份**。
    ///
    /// 现在：宽度取 `appScreenBounds.width`（判窄屏足够 —— 外屏 466 / 内屏 669 / 951 都分得开，
    /// 且它是静态值，旋转动画期间不抖）；横竖取本文件既有的 `landscapeScreen`
    /// （离散的 `interfaceOrientation`，不是宽高比连续量，不会在临界点每帧翻转）。
    ///
    /// ⚠️ 已知局限（待真机复验）：Duo 内屏不遵守 `supportedInterfaceOrientations`，
    /// `interfaceOrientation` 在内屏可能恒报 landscape，此时内屏竖持会被判成 `.sideways`。
    /// 用 `landscapeScreen` 而不是自造一套新判据，是为了与本文件其它地方保持同一口径 ——
    /// 换判据要么全文件一起换，要么就分叉。这一条已记入交接账本的待复验项。
    private var sizeForShape: CGSize {
        let width = UIApplication.shared.appScreenBounds.width
        guard width > 0 else { return CGSize(width: 400, height: 0) }
        // 用「高度 = 宽度 ± 1pt」把横竖这个**离散**结论编码给 `currentShape`：
        // 它只做 `width > height` 比较，不关心真实高度。
        return landscapeScreen
            ? CGSize(width: width, height: width - 1)   // 横：宽 > 高
            : CGSize(width: width, height: width + 1)   // 竖：高 > 宽
    }

    /// Whether a top control applies right now. Contextual controls (quality, audio, subtitles,
    /// danmaku) drop out when there is nothing to choose, and a few depend on the device or shape.
    private func available(_ control: PlayerControl) -> Bool {
        switch control {
        // 这几项此前一律 `false` —— 设置页把它们列在「直接显示」勾选表里，
        // 勾上却永远不会出现，是「设置不起作用」里最沉默的一种。
        // 现在按各自**真实依赖**给判据，而不是拿「这条路径没实现」一句话糊过去。
        case .autoPlayNext: store.catalog(for: channel) != nil
        case .moreInSeries: channel.historyContext != nil
        // 还要能**存下来**：没有 `skipScope` 的频道（设置页手工建的播放 URL）
        // `applySkipSettings` 会静默返回，开关点了会弹回 —— 那种情况不如不显示。
        case .skipIntroAuto, .skipIntroManual: !session.isLive && session.hasTimeline && session.canPersistSkipSettings
        // 广告标注：`PlaybackSession.markAd(at:)` 用的是 `AVAssetImageGenerator`
        // 对 `item.asset` **离线抓帧**（见 `AdFrameSampler.hashes`），
        // 不依赖任何自绘层 —— 所以原版这条路本来就能标注。
        // 此前把它写死 `false` 是错误归因（「AVKit 承载所以抓不到帧」并不成立），
        // 结果是设置里勾了却永远不出现。判据与 One 皮肤同一套：有时间轴、不是直播、够长。
        case .markAd: session.hasTimeline && !session.isLive && clock.duration > 60
        case .adBlock: true
        case .airPlay: true
        case .episodes: !inline && channel.historyContext != nil
        // 设备支持 ≠ 按钮能用：AVKit 承载画面的那条路上我们没有 controller，
        // 自动浮起又已经关掉，按钮会变成死键 —— 这种情况直接不列出来。
        case .pictureInPicture: pip.canToggle
        case .miniPlayer: true
        case .lock: !inline
        case .rotate: !inline && PlayerOrientation.available && (horizontalSizeClass == .compact || verticalSizeClass == .compact)
        case .danmaku: !session.danmaku.isEmpty
        case .quality: session.qualities.count > 1
        case .audio: session.audioChoices.count > 1 || (tracks.audio?.options.count ?? 0) > 1
        case .subtitles: subtitleTracks.isEmpty && !(tracks.legible?.options.isEmpty ?? true)
        case .speed: !session.isLive
        case .pictureSize: true
        case .videoInfo: true
        case .speechSubtitles: speechLanguage != nil
        case .anotherPlayer: true
        case .backTen: seekable && !inline
        case .forwardTen: seekable && !inline
        case .playPause: true
        case .previousEpisode: store.step(back: true, from: channel, session: session) != nil
        case .nextEpisode: store.step(back: false, from: channel, session: session) != nil
        case .fullScreen: toggleFullScreen != nil
        }
    }

    /// 当前布局下「直接显示」允许画出来的控件（#7b）。
    ///
    /// ⛔ 原来这里**根本没有读取点**：`grep -c "surfaced" App/MobilePlayer.swift` = 0，
    /// 而设置页 `PlayerControlsSettingsView` 明写「This layout applies to the Original
    /// and One skins」—— 原版皮肤就是本文件。于是那套勾选对它完全无效：
    ///   · 勾上 → `setSurfaced` 顺手 `surfaceInTopRow` 摆进槽位 ⇒ 看起来生效
    ///   · 取消 → 只从集合删，槽位不动 ⇒ 没有效果
    ///
    /// 三形态分流（不是「全屏/非全屏」两支）：
    ///   · `.inline`         → `watchSurfaced`
    ///   · `.pageFullScreen` → `fullSurfaced`
    ///   · `.screen`         → **放行全部**（没有观看页，两份集合的语义都不适用；
    ///                          若硬套 `fullSurfaced`（默认空数组），独立全屏播放器顶栏会整体清空）
    ///
    /// 判据与负对照见 `Sources/TVCore/PlayerControlSurfacing.swift` 的注释与 TVCore 测试。
    private var surfacedAllowed: Set<String> {
        _ = controlsOrder   // 与 `controlsLayout` 同源建立依赖，设置页改动能重算
        // `MobilePlayerLayout` 不是 RawRepresentable（App 层枚举，无 rawValue），
        // 这里显式映射，避免依赖字符串。
        let surfacingLayout: PlayerControlSurfacing.Layout
        switch self.layout {
        case .screen: surfacingLayout = .screen
        case .inline: surfacingLayout = .inline
        case .pageFullScreen: surfacingLayout = .pageFullScreen
        }
        let layout = surfacingLayout
        return PlayerControlSurfacing.allowed(
            layout: layout,
            watchSurfaced: controlsLayout.watchSurfaced.map(\.rawValue),
            fullSurfaced: controlsLayout.fullSurfaced.map(\.rawValue),
            allControls: PlayerControl.allCases.map(\.rawValue)
        )
    }

    /// The top-row slots, with controls that do not apply right now left as gaps — so a control the
    /// viewer placed in slot 7 sits at the seventh position whatever the current content offers.
    ///
    /// ⛔ 同时过两道：`available`（内容可用性）与 `surfacedAllowed`（用户勾选）。
    /// 只过前者就是 #7b —— 取消勾选无效。
    ///
    /// ⚠️ **只有顶栏过 `surfacedAllowed`。** 设置页的判据是
    /// `isShownInBar = set.contains(control) && layout.top.contains(control)`
    /// （`PlayerControlsSettingsView:229-231`）—— 两个集合的语义是
    /// 「**顶栏**里哪些控件直接显示」，底栏与「更多」不受它管。
    /// 底栏是传输控制（播放/进度/上下集），「更多」是折叠收纳区，
    /// 把它们也过滤会让 bottom 6→0、more 19→0，等于把播放器掏空。
    private var topSlots: [PlayerControl?] {
        let allowed = surfacedAllowed
        return controlsLayout.topSlots.map { control in
            control.flatMap { available($0) && allowed.contains($0.rawValue) ? $0 : nil }
        }
    }

    /// 底栏只不过 surfaced —— 见 `topSlots` 的说明。
    private var bottomSlots: [PlayerControl?] {
        controlsLayout.bottomSlots.map { control in control.flatMap { available($0) ? $0 : nil } }
    }

    /// The controls left in More, only when they apply. 同样不过 surfaced —— 理由同上。
    private var moreControls: [PlayerControl] { controlsLayout.more.filter(available) }

    /// Whether the "more" menu has anything to show: a collapsed control or the picture switches.
    private var showsMoreMenu: Bool { !moreControls.isEmpty || pictureSwitches }

    private var toolbar: some View {
        HStack(spacing: 10) {
            ForEach(Array(topSlots.enumerated()), id: \.offset) { _, control in
                if let control {
                    topControlButton(control)
                } else {
                    // An empty slot keeps its place on the X axis as a button-sized gap.
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            // A More menu appears only when something actually collapsed into it.
            if showsMoreMenu {
                topControlsMenu
            }
        }
    }

    /// The round glass button for one top control drawn in the bar.
    @ViewBuilder private func topControlButton(_ control: PlayerControl) -> some View {
        switch control {
        // ⛔ 原先这里是 `EmptyView()`：用户把这几项排进顶栏，得到的是**空槽**。
        //    现在走与 One 皮肤同一套「这些控件长什么样」的实现（见 `seriesEntry`）。
        case .markAd: markAdButton(size: 44)
        case .autoPlayNext, .moreInSeries, .skipIntroAuto, .skipIntroManual:
            menuEntryButton(control, size: 44)
        case .adBlock:
            Button { skipsAds.toggle() } label: {
                Image(systemName: skipsAds ? "shield.lefthalf.filled" : "shield.slash")
                    .font(.headline).frame(width: 22, height: 22)
            }
            .chromeButton()
            .accessibilityLabel(L10n.text(skipsAds ? "Ad Blocking On" : "Ad Blocking Off"))
        case .airPlay:
            if tvBrowser.receivers.isEmpty {
                AirPlayButton()
                    .frame(width: 44, height: 44)
                    .glassSurface(.regular.interactive(), in: Circle())
                    .contentShape(Circle())
                    .accessibilityLabel(L10n.text("AirPlay"))
            } else {
                PlayOnButton(channel: channel, session: session, browser: tvBrowser) { receiver in
                    session.player.pause()
                    playingOn = receiver
                }
            }
        case .episodes:
            CatalogPlaybackActions(channel: channel, session: session, openEpisodes: openEpisodes)
        case .pictureInPicture:
            Button { pip.toggle() } label: {
                Image(systemName: pip.active ? "pip.exit" : "pip.enter").font(.headline).frame(width: 22, height: 22)
            }
            .chromeButton()
            .disabled(!pip.canToggle)
            .accessibilityLabel(L10n.text("Picture in Picture"))
        case .miniPlayer:
            Button { miniplayer() } label: {
                Image(systemName: "rectangle.inset.bottomright.filled").font(.headline).frame(width: 22, height: 22)
            }
            .chromeButton()
            .accessibilityLabel(L10n.text("Mini Player"))
        case .lock:
            Button { toggleLock() } label: {
                Image(systemName: controlsLocked ? "lock.fill" : "lock.open").font(.headline).frame(width: 22, height: 22)
            }
            .chromeButton()
            .accessibilityLabel(L10n.text(controlsLocked ? "Unlock Controls" : "Lock Controls"))
        case .rotate:
            Button { rotate() } label: {
                Image(systemName: landscapeScreen ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate").font(.headline).frame(width: 22, height: 22)
            }
            .chromeButton()
            .accessibilityLabel(L10n.text("Rotate"))
        case .danmaku:
            danmakuTopButton
        case .quality:
            Menu { QualityPicker(session: session) } label: {
                Image(systemName: "sparkles.tv").font(.headline).frame(width: 22, height: 22)
            }
            .chromeButton()
            .accessibilityLabel(L10n.text("Quality"))
        case .audio:
            Menu { audioPicker } label: {
                Image(systemName: "speaker.wave.2").font(.headline).frame(width: 22, height: 22)
            }
            .chromeButton()
            .accessibilityLabel(L10n.text("Audio"))
        case .subtitles:
            Menu { subtitlePicker } label: {
                Image(systemName: "captions.bubble").font(.headline).frame(width: 22, height: 22)
            }
            .chromeButton()
            .accessibilityLabel(L10n.text("Subtitles"))
        case .speed:
            Menu {
                Picker(L10n.text("Playback Speed"), selection: Binding(get: { speed }, set: { speed = $0; session.setSpeed($0) })) {
                    ForEach(Self.speeds, id: \.self) { Text(Self.speedLabel($0)).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "gauge.with.needle").font(.headline).frame(width: 22, height: 22)
            }
            .chromeButton()
            .accessibilityLabel(L10n.text("Playback Speed"))
        case .pictureSize:
            Menu {
                Picker(L10n.text("Picture Size"), selection: Binding(get: { scaling }, set: { setScaling($0) })) {
                    ForEach(PictureScaling.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.headline).frame(width: 22, height: 22)
            }
            .chromeButton()
            .accessibilityLabel(L10n.text("Picture Size"))
        case .videoInfo:
            Button { showsPlaybackInfo.toggle() } label: {
                Image(systemName: showsPlaybackInfo ? "info.circle.fill" : "info.circle").font(.headline).frame(width: 22, height: 22)
            }
            .chromeButton()
            .accessibilityLabel(L10n.text("Show Video Info"))
        case .speechSubtitles:
            Button { generateSubtitles(language: speechLanguage ?? "") } label: {
                Image(systemName: generatingSubtitles ? "waveform" : "waveform.badge.plus").font(.headline).frame(width: 22, height: 22)
            }
            .chromeButton()
            .disabled(generatingSubtitles || !session.hasTimeline)
            .accessibilityLabel(L10n.text("Write Subtitles From the Sound"))
        case .anotherPlayer:
            Button { externalPlayerStream = HandoffStream(url: channel.url) } label: {
                Image(systemName: "play.rectangle.on.rectangle").font(.headline).frame(width: 22, height: 22)
            }
            .chromeButton()
            .accessibilityLabel(L10n.text("Open in Another Player"))
        case .backTen:
            Button { session.skip(-10); sought() } label: {
                Image(systemName: "gobackward.10").font(.headline).frame(width: 22, height: 22)
            }
            .chromeButton()
            .accessibilityLabel(L10n.text("Back 10 seconds"))
        case .playPause:
            Button { session.togglePlayback(); poke() } label: {
                Image(systemName: session.paused ? "play.fill" : "pause.fill").contentTransition(.symbolEffect(.replace))
                    .font(.headline).frame(width: 22, height: 22)
            }
            .chromeButton()
            .accessibilityLabel(L10n.text(session.paused ? "Play" : "Pause"))
            .accessibilityIdentifier("player.playPause")
        case .forwardTen:
            Button { session.skip(10); sought() } label: {
                Image(systemName: "goforward.10").font(.headline).frame(width: 22, height: 22)
            }
            .chromeButton()
            .accessibilityLabel(L10n.text("Forward 10 seconds"))
        case .previousEpisode:
            if let previous = store.step(back: true, from: channel, session: session) {
                Button { previous.go() } label: {
                    Image(systemName: "backward.end.fill").font(.headline).frame(width: 22, height: 22)
                }
                .chromeButton()
                .disabled(previous.busy)
                .accessibilityLabel(L10n.text("Previous Episode"))
            }
        case .nextEpisode:
            if let next = store.step(back: false, from: channel, session: session) {
                Button { next.go() } label: {
                    Image(systemName: "forward.end.fill").font(.headline).frame(width: 22, height: 22)
                }
                .chromeButton()
                .disabled(next.busy)
                .accessibilityLabel(L10n.text("Next Episode"))
            }
        case .fullScreen:
            if let toggleFullScreen {
                let full = layout == .pageFullScreen
                Button(action: toggleFullScreen) {
                    Image(systemName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.headline).frame(width: 22, height: 22)
                }
                .chromeButton()
                .accessibilityLabel(L10n.text(full ? "Exit Full Screen" : "Full Screen"))
                .accessibilityIdentifier("player.fullScreen")
            }
        }
    }

    /// The danmaku top button: a menu for its settings, or a plain toggle.
    private var danmakuTopButton: some View {
        Menu {
            Toggle(isOn: $showsDanmaku) { Label(L10n.text("Show Danmaku"), systemImage: "text.bubble") }
            Picker(selection: $danmakuArea) {
                ForEach(DanmakuArea.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { Label(L10n.text("Danmaku Area"), systemImage: "rectangle.tophalf.inset.filled") }
            .pickerStyle(.menu)
            DanmakuStylePickers(model: session.catalogDanmaku)
            Button { showsDanmakuList = true } label: { Label(L10n.text("Danmaku List"), systemImage: "list.bullet.rectangle") }
        } label: {
            Image(systemName: showsDanmaku ? "text.bubble.fill" : "text.bubble").font(.headline).frame(width: 22, height: 22)
        }
        .chromeButton()
        .accessibilityLabel(L10n.text("Danmaku"))
    }

    /// The "⋯" menu that holds every control not drawn in a bar.
    private var topControlsMenu: some View {
        Menu {
            ForEach(moreControls) { control in
                topControlMenuEntry(control)
            }
            // The picture switches never leave the menu: they are not a transport control.
            if pictureSwitches {
                Section(L10n.text("Picture")) {
                    if VideoEnhancement.canSmooth { Toggle(L10n.text("Smooth Motion (60 fps)"), isOn: $smoothsVideo) }
                    if VideoEnhancement.canUpscale { Toggle(L10n.text("Sharper Picture"), isOn: $upscalesVideo) }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.headline).frame(width: 22, height: 22)
        }
        .chromeButton()
        .accessibilityLabel(L10n.text("Playback Options"))
        .accessibilityIdentifier("player.catalogOptions")
    }

    /// The menu entry for one top control collapsed into More.
    @ViewBuilder private func topControlMenuEntry(_ control: PlayerControl) -> some View {
        switch control {
        // 原先这四项是 `EmptyView()` —— 它们被收进枚举、设置页能排，
        // 但「更多」里一个都不渲染。现在走与顶栏同一份内容（`seriesEntry`）。
        case .markAd:
            Button { Task { await markAdHere() } } label: {
                Label(markingAd ? L10n.text("Marking…") : L10n.text("Mark This as an Ad"),
                      systemImage: "megaphone")
            }
            .disabled(markingAd)
        case .autoPlayNext, .moreInSeries, .skipIntroAuto, .skipIntroManual, .adBlock:
            seriesEntry(control)
        case .airPlay:
            // AirPlay is represented by the system button; in a menu it has no equivalent, so it
            // stays out of More.
            EmptyView()
        case .episodes:
            Button(action: openEpisodes) {
                Label(L10n.text("Episodes"), systemImage: "list.bullet.rectangle")
            }
            .disabled(store.resolvingEpisode != nil)
            .accessibilityIdentifier("player.episodes")
        case .pictureInPicture:
            Button { pip.toggle() } label: {
                Label(L10n.text("Picture in Picture"), systemImage: pip.active ? "pip.exit" : "pip.enter")
            }
            .disabled(!pip.canToggle)
        case .miniPlayer:
            Button { miniplayer() } label: {
                Label(L10n.text("Mini Player"), systemImage: "rectangle.inset.bottomright.filled")
            }
        case .lock:
            Button { toggleLock() } label: {
                Label(L10n.text(controlsLocked ? "Unlock Controls" : "Lock Controls"),
                      systemImage: controlsLocked ? "lock.fill" : "lock.open")
            }
        case .rotate:
            Button { rotate() } label: {
                Label(L10n.text("Rotate"), systemImage: landscapeScreen ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
            }
        case .danmaku:
            danmakuTopButton
        case .quality:
            Menu(L10n.text("Quality")) { QualityPicker(session: session) }
        case .audio:
            Menu(L10n.text("Audio")) { audioPicker }
        case .subtitles:
            Menu(L10n.text("Subtitles")) { subtitlePicker }
        case .speed:
            Menu(L10n.text("Playback Speed")) {
                Picker(L10n.text("Playback Speed"), selection: Binding(get: { speed }, set: { speed = $0; session.setSpeed($0) })) {
                    ForEach(Self.speeds, id: \.self) { Text(Self.speedLabel($0)).tag($0) }
                }
                .pickerStyle(.inline)
            }
        case .pictureSize:
            Menu(L10n.text("Picture Size")) {
                Picker(L10n.text("Picture Size"), selection: Binding(get: { scaling }, set: { setScaling($0) })) {
                    ForEach(PictureScaling.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
                }
                .pickerStyle(.inline)
            }
        case .videoInfo:
            Toggle(L10n.text("Show Video Info"), isOn: $showsPlaybackInfo)
        case .speechSubtitles:
            speechSubtitleEntry
        case .anotherPlayer:
            Button {
                externalPlayerStream = HandoffStream(url: channel.url)
            } label: {
                Label(L10n.text("Open in Another Player"), systemImage: "play.rectangle.on.rectangle")
            }
        case .backTen:
            Button { session.skip(-10); sought() } label: {
                Label(L10n.text("Back 10 seconds"), systemImage: "gobackward.10")
            }
        case .playPause:
            Button { session.togglePlayback(); poke() } label: {
                Label(L10n.text(session.paused ? "Play" : "Pause"), systemImage: session.paused ? "play.fill" : "pause.fill")
            }
        case .forwardTen:
            Button { session.skip(10); sought() } label: {
                Label(L10n.text("Forward 10 seconds"), systemImage: "goforward.10")
            }
        case .previousEpisode:
            if let previous = store.step(back: true, from: channel, session: session) {
                Button { previous.go() } label: {
                    Label(L10n.text("Previous Episode"), systemImage: "backward.end.fill")
                }
                .disabled(previous.busy)
            }
        case .nextEpisode:
            if let next = store.step(back: false, from: channel, session: session) {
                Button { next.go() } label: {
                    Label(L10n.text("Next Episode"), systemImage: "forward.end.fill")
                }
                .disabled(next.busy)
            }
        case .fullScreen:
            if let toggleFullScreen {
                let full = layout == .pageFullScreen
                Button(action: toggleFullScreen) {
                    Label(L10n.text(full ? "Exit Full Screen" : "Full Screen"),
                          systemImage: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
            }
        }
    }

    /// The audio picker, drawing from AVFoundation's own choice when the tracks API offers none.
    @ViewBuilder private var audioPicker: some View {
        if let audio = tracks.audio, audio.options.count > 1 {
            Picker(L10n.text("Audio"), selection: Binding(get: { tracks.selected(in: audio) }, set: { tracks.select($0, in: audio) })) {
                ForEach(audio.options, id: \.self) { Text($0.displayName).tag(Optional($0)) }
            }
            .pickerStyle(.inline)
        } else if session.audioChoices.count > 1 {
            Picker(L10n.text("Audio"), selection: Binding(get: { session.audioChoice }, set: { if let id = $0 { session.chooseAudio(id) } })) {
                ForEach(session.audioChoices) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.inline)
        }
    }

    @ViewBuilder private var subtitlePicker: some View {
        if let legible = tracks.legible, !legible.options.isEmpty {
            Picker(L10n.text("Subtitles"), selection: Binding(get: { tracks.selected(in: legible) }, set: { tracks.select($0, in: legible) })) {
                if legible.group.allowsEmptySelection { Text(L10n.text("Off")).tag(AVMediaSelectionOption?.none) }
                ForEach(legible.options, id: \.self) { Text($0.displayName).tag(Optional($0)) }
            }
            .pickerStyle(.inline)
        }
    }

    @ViewBuilder private var speechSubtitleEntry: some View {
        if let language = speechLanguage {
            Button {
                generateSubtitles(language: language)
            } label: {
                if generatingSubtitles {
                    Label(L10n.text("Writing Subtitles…"), systemImage: "waveform")
                    Text("\(Int(subtitleProgress * 100))%")
                } else if let subtitleError {
                    Label(L10n.text("Subtitles Could Not Be Written: %@", subtitleError), systemImage: "exclamationmark.triangle")
                } else {
                    Label(L10n.text("Write Subtitles From the Sound"), systemImage: "waveform.badge.plus")
                }
            }
            .disabled(generatingSubtitles || !session.hasTimeline)
        } else {
            Button {} label: { Label(L10n.text("No On-Device Speech Model"), systemImage: "speaker.slash") }
                .disabled(true)
        }
    }


    /// Whether the options have the smoothing and upscaling switches (iPhone and iPad on OS 26).
    private var pictureSwitches: Bool { VideoEnhancement.canUpscale || VideoEnhancement.canSmooth }

    private static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]
    private static func speedLabel(_ speed: Float) -> String {
        Double(speed).formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    // MARK: Middle and bottom

    /// The one control the middle ever holds, and only while the picture is still. Big enough to be
    /// the obvious thing to press when playback stops, and it disappears the moment it resumes, so a
    /// running film is never watched through a button.
    private var centerPlay: some View {
        Button { session.togglePlayback(); poke() } label: {
            Image(systemName: "play.fill").contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PlayerCircleStyle(size: roomyChrome ? 72 : 56))
        .accessibilityLabel(L10n.text("Play"))
        .accessibilityIdentifier("player.playPause")
    }

    /// The controls along the bottom edge, in one line: the viewer's bottom-row controls in their
    /// slot order (an empty slot leaves a button-sized gap), with the exact time at the far right.
    private var bottomBar: some View {
        ZStack {
            HStack(spacing: roomyChrome ? 10 : 8) {
                ForEach(Array(bottomSlots.enumerated()), id: \.offset) { _, control in
                    if let control {
                        transportButton(control)
                    } else {
                        Color.clear.frame(width: roomyChrome ? 42 : 36, height: roomyChrome ? 42 : 36)
                    }
                }
                Spacer(minLength: 0)
                if session.isLive {
                    Text(L10n.text("LIVE")).font(.caption.weight(.bold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.red, in: Capsule())
                } else if session.hasTimeline {
                    timeLabel
                }
            }
        }
        .simultaneousGesture(TapGesture().onEnded { poke() })
    }

    /// One round transport button for the bottom row, whatever kind of control it is. Transport
    /// controls keep their existing behaviour; a round-button control dragged down from the top bar
    /// renders here as a menu or a button in the same transport style.
    @ViewBuilder private func transportButton(_ control: PlayerControl) -> some View {
        switch control {
        case .backTen:
            Button { session.skip(-10); sought() } label: { Image(systemName: "gobackward.10") }
                .buttonStyle(PlayerCircleStyle(size: roomyChrome ? 42 : 36))
                .accessibilityLabel(L10n.text("Back 10 seconds"))
        case .playPause:
            Button { session.togglePlayback(); poke() } label: {
                Image(systemName: session.paused ? "play.fill" : "pause.fill").contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PlayerCircleStyle(size: roomyChrome ? 46 : 40))
            .accessibilityLabel(L10n.text(session.paused ? "Play" : "Pause"))
            .accessibilityIdentifier("player.playPause")
        case .forwardTen:
            Button { session.skip(10); sought() } label: { Image(systemName: "goforward.10") }
                .buttonStyle(PlayerCircleStyle(size: roomyChrome ? 42 : 36))
                .accessibilityLabel(L10n.text("Forward 10 seconds"))
        case .previousEpisode:
            if let previous = store.step(back: true, from: channel, session: session) {
                Button { previous.go() } label: { Image(systemName: "backward.end.fill") }
                    .buttonStyle(PlayerCircleStyle(size: 36))
                    .disabled(previous.busy)
                    .accessibilityLabel(L10n.text("Previous Episode"))
            }
        case .nextEpisode:
            if let next = store.step(back: false, from: channel, session: session) {
                Button { next.go() } label: { Image(systemName: "forward.end.fill") }
                    .buttonStyle(PlayerCircleStyle(size: 36))
                    .disabled(next.busy)
                    .accessibilityLabel(L10n.text("Next Episode"))
            }
        case .fullScreen:
            if let toggleFullScreen {
                let full = layout == .pageFullScreen
                Button(action: toggleFullScreen) {
                    Image(systemName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(PlayerCircleStyle(size: 36))
                .accessibilityLabel(L10n.text(full ? "Exit Full Screen" : "Full Screen"))
                .accessibilityIdentifier("player.fullScreen")
            }
        default:
            // A round-button control dragged down into the transport row.
            compactButton(control)
        }
    }

    /// A top-row control rendered as a compact transport button (36 pt circle) for the bottom row.
    @ViewBuilder private func compactButton(_ control: PlayerControl) -> some View {
        switch control {
        case .markAd: markAdButton(size: 36)
        case .autoPlayNext, .moreInSeries, .skipIntroAuto, .skipIntroManual:
            menuEntryButton(control, size: 36)
        case .adBlock:
            Button { skipsAds.toggle() } label: {
                Image(systemName: skipsAds ? "shield.lefthalf.filled" : "shield.slash")
            }
            .buttonStyle(PlayerCircleStyle(size: 36))
            .accessibilityLabel(L10n.text(skipsAds ? "Ad Blocking On" : "Ad Blocking Off"))
        case .airPlay:
            if tvBrowser.receivers.isEmpty {
                AirPlayButton()
                    .frame(width: 36, height: 36)
                    .glassSurface(.regular.interactive(), in: Circle())
                    .contentShape(Circle())
                    .accessibilityLabel(L10n.text("AirPlay"))
            } else {
                PlayOnButton(channel: channel, session: session, browser: tvBrowser) { receiver in
                    session.player.pause(); playingOn = receiver
                }
            }
        case .episodes:
            CatalogPlaybackActions(channel: channel, session: session, openEpisodes: openEpisodes)
        case .pictureInPicture:
            Button { pip.toggle() } label: {
                Image(systemName: pip.active ? "pip.exit" : "pip.enter")
            }
            .buttonStyle(PlayerCircleStyle(size: 36))
            .disabled(!pip.canToggle)
            .accessibilityLabel(L10n.text("Picture in Picture"))
        case .miniPlayer:
            Button { miniplayer() } label: { Image(systemName: "rectangle.inset.bottomright.filled") }
                .buttonStyle(PlayerCircleStyle(size: 36))
                .accessibilityLabel(L10n.text("Mini Player"))
        case .lock:
            Button { toggleLock() } label: { Image(systemName: controlsLocked ? "lock.fill" : "lock.open") }
                .buttonStyle(PlayerCircleStyle(size: 36))
                .accessibilityLabel(L10n.text(controlsLocked ? "Unlock Controls" : "Lock Controls"))
        case .rotate:
            Button { rotate() } label: {
                Image(systemName: landscapeScreen ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
            }
            .buttonStyle(PlayerCircleStyle(size: 36))
            .accessibilityLabel(L10n.text("Rotate"))
        case .danmaku:
            Menu {
                Toggle(isOn: $showsDanmaku) { Label(L10n.text("Show Danmaku"), systemImage: "text.bubble") }
                Picker(selection: $danmakuArea) {
                    ForEach(DanmakuArea.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { Label(L10n.text("Danmaku Area"), systemImage: "rectangle.tophalf.inset.filled") }
                .pickerStyle(.menu)
                DanmakuStylePickers(model: session.catalogDanmaku)
                Button { showsDanmakuList = true } label: { Label(L10n.text("Danmaku List"), systemImage: "list.bullet.rectangle") }
            } label: {
                Image(systemName: showsDanmaku ? "text.bubble.fill" : "text.bubble")
            }
            .buttonStyle(PlayerCircleStyle(size: 36))
            .accessibilityLabel(L10n.text("Danmaku"))
        case .quality:
            Menu { QualityPicker(session: session) } label: { Image(systemName: "sparkles.tv") }
                .buttonStyle(PlayerCircleStyle(size: 36))
                .accessibilityLabel(L10n.text("Quality"))
        case .audio:
            Menu { audioPicker } label: { Image(systemName: "speaker.wave.2") }
                .buttonStyle(PlayerCircleStyle(size: 36))
                .accessibilityLabel(L10n.text("Audio"))
        case .subtitles:
            Menu { subtitlePicker } label: { Image(systemName: "captions.bubble") }
                .buttonStyle(PlayerCircleStyle(size: 36))
                .accessibilityLabel(L10n.text("Subtitles"))
        case .speed:
            Menu {
                Picker(L10n.text("Playback Speed"), selection: Binding(get: { speed }, set: { speed = $0; session.setSpeed($0) })) {
                    ForEach(Self.speeds, id: \.self) { Text(Self.speedLabel($0)).tag($0) }
                }
                .pickerStyle(.inline)
            } label: { Image(systemName: "gauge.with.needle") }
                .buttonStyle(PlayerCircleStyle(size: 36))
                .accessibilityLabel(L10n.text("Playback Speed"))
        case .pictureSize:
            Menu {
                Picker(L10n.text("Picture Size"), selection: Binding(get: { scaling }, set: { setScaling($0) })) {
                    ForEach(PictureScaling.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
                }
                .pickerStyle(.inline)
            } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(PlayerCircleStyle(size: 36))
                .accessibilityLabel(L10n.text("Picture Size"))
        case .videoInfo:
            Button { showsPlaybackInfo.toggle() } label: {
                Image(systemName: showsPlaybackInfo ? "info.circle.fill" : "info.circle")
            }
            .buttonStyle(PlayerCircleStyle(size: 36))
            .accessibilityLabel(L10n.text("Show Video Info"))
        case .speechSubtitles:
            Button { generateSubtitles(language: speechLanguage ?? "") } label: {
                Image(systemName: generatingSubtitles ? "waveform" : "waveform.badge.plus")
            }
            .buttonStyle(PlayerCircleStyle(size: 36))
            .disabled(generatingSubtitles || !session.hasTimeline)
            .accessibilityLabel(L10n.text("Write Subtitles From the Sound"))
        case .anotherPlayer:
            Button { externalPlayerStream = HandoffStream(url: channel.url) } label: {
                Image(systemName: "play.rectangle.on.rectangle")
            }
            .buttonStyle(PlayerCircleStyle(size: 36))
            .accessibilityLabel(L10n.text("Open in Another Player"))
        case .backTen, .playPause, .forwardTen, .previousEpisode, .nextEpisode, .fullScreen:
            EmptyView()
        }
    }

    /// 原版播放器里的「标注广告」键。
    ///
    /// 走的是 `PlaybackSession.markAd(at:)` —— 它用 `AVAssetImageGenerator`
    /// 对 `item.asset` 离线抓帧，与自绘层无关，所以原版这条路能标。
    /// 标注点是 `clock.position`（当前播放位置），边界由 `AdBoundary` 自己找。
    @ViewBuilder private func markAdButton(size: CGFloat) -> some View {
        Button { Task { await markAdHere() } } label: {
            Image(systemName: markingAd ? "megaphone.fill" : "megaphone")
        }
        .buttonStyle(PlayerCircleStyle(size: size))
        .disabled(markingAd)
        .accessibilityLabel(L10n.text("Mark Ad"))
    }

    /// 标注一次：把当前位置标成广告，边界自动找，成功后刷新广告库。
    @MainActor private func markAdHere() async {
        guard !markingAd else { return }
        markingAd = true
        defer { markingAd = false }
        await session.markAd(at: clock.position)
    }

    /// 顶栏/底栏上的「自动连播 / 更多本剧 / 自动跳片头片尾 / 跳过片头片尾」图标键。
    ///
    /// 这四项都是**二态或一次性动作**，没有对应的 SF Symbol 语义色，所以图标取
    /// 开/关两种形态；菜单里那条（`seriesEntry`）才是带文字、可读的那份。
    @ViewBuilder private func menuEntryButton(_ control: PlayerControl, size: CGFloat) -> some View {
        Button {
            perform(control)
        } label: {
            Image(systemName: symbolFor(control))
        }
        .buttonStyle(PlayerCircleStyle(size: size))
        .accessibilityLabel(L10n.text(control.title))
    }

    /// 这四项在「更多」菜单里的带文字条目。
    @ViewBuilder private func seriesEntry(_ control: PlayerControl) -> some View {
        switch control {
        case .autoPlayNext:
            Toggle(L10n.text("Auto-play next episode"), isOn: Binding(
                get: { store.autoPlayNext }, set: { store.autoPlayNext = $0 }))
        case .moreInSeries:
            Button { showsSeries = true } label: {
                Label(L10n.text("More in This Series"), systemImage: "rectangle.stack")
            }
        case .skipIntroAuto:
            Toggle(L10n.text("Automatically skip intro and outro"), isOn: Binding(
                get: { session.skipSettings.enabled },
                set: { value in
                    var settings = session.skipSettings
                    settings.enabled = value
                    session.applySkipSettings(settings)
                }))
        case .skipIntroManual:
            Button { showsSkip = true } label: {
                Label(L10n.text("Skip intro / outro"), systemImage: "forward.end")
            }
        case .adBlock:
            Toggle(L10n.text("Ad Blocking"), isOn: $skipsAds)
        default:
            EmptyView()
        }
    }

    /// 图标键按下去做的那件事 —— 与 `seriesEntry` 里同名条目一一对应。
    private func perform(_ control: PlayerControl) {
        switch control {
        case .autoPlayNext:
            store.autoPlayNext.toggle()
        case .moreInSeries:
            showsSeries = true
        case .skipIntroAuto:
            var settings = session.skipSettings
            settings.enabled.toggle()
            session.applySkipSettings(settings)
        case .skipIntroManual:
            showsSkip = true
        default:
            break
        }
    }

    /// 图标键的图标：开/关两种形态。
    private func symbolFor(_ control: PlayerControl) -> String {
        switch control {
        case .autoPlayNext:
            return store.autoPlayNext ? "play.circle.fill" : "play.circle"
        case .moreInSeries:
            return "rectangle.stack"
        case .skipIntroAuto:
            return session.skipSettings.enabled ? "forward.end.alt.fill" : "forward.end.alt"
        case .skipIntroManual:
            return "forward.end"
        default:
            return control.symbol
        }
    }

    /// The position and the length, following the picture while it runs.
    private var timeLabel: some View {
        let follows = chromeVisible && !session.paused && clock.scrubbing == nil
        return TimelineView(.animation(paused: !follows)) { _ in
            Text(SeekBar<EmptyView>.format(clock.scrubbing ?? (follows ? clock.currentPosition : clock.position))
                 + " / " + SeekBar<EmptyView>.format(clock.duration))
                .font(.footnote.monospacedDigit().weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.5), radius: 3)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var bottomRow: some View {
        if session.isLive {
            HStack {
                Text(L10n.text("LIVE")).font(.caption.weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.red, in: Capsule())
                Spacer(minLength: 0)
            }
        } else if session.hasTimeline {
            // Dragging holds the controls up itself (`hold`); a tap gesture here would compete with the scrubber's drag.
            // The episode and screen buttons live in `bottomBar` now, so the bar keeps only the time
            // and the track: the bottom of the picture holds one row of controls, not two.
            SeekBar<EmptyView>(clock: clock, showsClock: false, moving: chromeVisible && !session.paused, hold: hold, sought: sought) { EmptyView() }
        } else {
            EmptyView()
        }
    }

    /// The position moved by a button or the seek bar: the Lock Screen follows.
    private func sought() {
        poke()
        nowPlaying.update(title: channel.name, session: session)
    }

    /// Locks or unlocks the controls, and the orientation with them.
    ///
    /// The button used to stop the taps and slides and nothing else, while `PlayerOrientation.lock()`
    /// and `unlock()` sat there with no caller: a lock button that lets the gyroscope turn the film
    /// while you are holding the phone is not much of a lock. Pinning the orientation it is in when
    /// the lock goes on is what the label promises, and the rotate button stays out of a locked
    /// picture too — "lock" pins the orientation, so a by-hand turn must not slip past it.
    private func toggleLock() {
        controlsLocked.toggle()
        if controlsLocked { PlayerOrientation.lock() } else { PlayerOrientation.unlock() }
        poke()
    }

    /// Turns the picture to the next orientation by hand; the controls follow the rotation.
    private func rotate() {
        let next: UIInterfaceOrientation
        switch PlayerOrientation.currentOrientation {
        case .landscapeLeft: next = .landscapeRight
        case .landscapeRight: next = .portrait
        default: next = .landscapeLeft
        }
        PlayerOrientation.rotate(to: next)
        poke()
    }

    /// [mi3s] 二开：画面载体。iOS 按 One 的做法用 `AVPlayerViewController`；
    /// 其余平台保持上游的 `AVPlayerLayer`。单独抽出来，免得 `ZStack` 里的表达式
    /// 大到编译器推不出类型（实测会 "unable to type-check in reasonable time"）。
    @ViewBuilder private var pictureCarrier: some View {
        #if os(iOS)
        OneStylePlayerSurface(
            player: session.player,
            gravity: pictureGravity,
            // [mi3s] 二开：和上游一致，**开着**「离开 App 自动浮起」。
            //
            // 上游原生就是开的（见 `fusion/base` 的 `PictureInPicture.attach`），
            // 所以「返回主屏出现浮窗」是原生能力。我们曾为躲开「折叠/转向被误判成离开」
            // 把它关成 false，结果连真离开也不浮了 —— 这就是用户报的现象。
            //
            // 现在改为：能力常开，只在这些动作**前后**用
            // `suspendAutomaticFloating()` / `resumeAutomaticFloating()` 临时挡一下，
            // 动作结束立刻恢复。既保住能力，又不让重挂载误触发。
            automaticPiP: true,
            pip: pip
        )
        .pictureBox(scaling, aspect: pictureAspect)
        .playerBleed(!inline)
        #else
        PlayerLayerView(player: session.player, gravity: pictureGravity, pip: pip)
            .pictureBox(scaling, aspect: pictureAspect)
            .playerBleed(!inline)
        #endif
    }

    private var pipPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "pip").font(.system(size: 48, weight: .light))
            Text(L10n.text("Playing in Picture in Picture")).font(.callout)
        }
        .foregroundStyle(.white.opacity(0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .playerBleed(!inline)
    }
}

/// The top of an iPhone watch page before the picture: the cover filling the width, blurred, under a spinner.
/// While nothing is starting, the whole cover shows clear over that blur.
struct WatchCoverBackdrop: View {
    let poster: URL?
    var headers: [String: String] = [:]
    var loading = true
    var clear = false
    /// In a split (landscape / Duo unfolded) layout the cover sits in a wide column, so it should be
    /// wide (16:9) instead of the portrait poster.
    var wide = false
    /// What the wait has to say, by how long it has run (see `WaitSpinner`).
    var status: (@MainActor (TimeInterval) -> PlaybackWait)? = nil
    @State private var aspect: CGFloat?
    var body: some View {
        ZStack {
            Color.black
            PosterImage(url: poster, headers: headers)
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                .blur(radius: 24).scaleEffect(1.2)
                .overlay(Color.black.opacity(0.35))
                .accessibilityHidden(true)
            if clear, poster != nil {
                if wide {
                    // Landscape / unfolded: the cover is a 16:9 picture that fits its wide column.
                    PosterImage(url: poster, headers: headers, aspect: $aspect)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(aspect ?? 16.0 / 9.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                        .padding(.vertical, 14)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                } else {
                    // Upright: the poster fills the whole top band, reaching the status bar and both edges,
                    // so no dead-black band is left beside or above it. PosterImage already scales-to-fill
                    // and clips, so it just needs the whole band as its frame.
                    PosterImage(url: poster, headers: headers, aspect: $aspect)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            if loading { WaitSpinner(status: status) }
        }
        .animation(.easeOut(duration: 0.3), value: clear)
        .clipped()
    }
}

/// A spinner first; once the wait has run `PlaybackWait.detailsAfter`, its line and small print along the bottom,
/// so the spinner stays where it was.
struct WaitSpinner: View {
    var status: (@MainActor (TimeInterval) -> PlaybackWait)?
    @State private var started = Date()
    var body: some View {
        ZStack {
            ProgressView().controlSize(.large).tint(.white)
            if let status {
                TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                    let elapsed = max(0, timeline.date.timeIntervalSince(started))
                    let speaks = elapsed >= PlaybackWait.detailsAfter
                    VStack(spacing: 5) {
                        if speaks {
                            let wait = status(elapsed)
                            Text(wait.message).font(.footnote.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                            WaitDetails(detail: wait.detail, steps: Array(wait.steps.suffix(2)))
                        }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .animation(.smooth(duration: 0.45), value: speaks)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

/// Where the iPhone and iPad player is drawn.
enum MobilePlayerLayout {
    /// A screen of its own (the full-screen player).
    case screen
    /// The top of an iPhone watch page, under the status bar.
    case inline
    /// A watch page's player filling the screen; Back returns to the page.
    case pageFullScreen
}

/// The player at the top of an iPhone watch page (`VideoDetailView`).
struct WatchPlayback {
    /// Filling the screen, or at the top of the page.
    var fullScreen: Bool
    /// Full Screen, or back to the page. True when the picture is wider than tall, so the phone turns.
    var toggleFullScreen: (_ landscape: Bool) -> Void
    /// Back, out of the page.
    var leave: () -> Void
    /// The picture owns a full-height column on the page — held sideways, or the unfolded Duo's two-column
    /// page — rather than a strip at the top. Its chrome then uses the roomy size and stays clear of the
    /// safe-area insets, which a full-height picture leaves it none of.
    var immersive: Bool = false
    /// The picture, or an error, has taken the place of the wait: the page's cover can go.
    var started: (Bool) -> Void = { _ in }
    /// The page's player, so the cover over it can say how its wait goes.
    var opened: (PlaybackSession) -> Void = { _ in }
    /// The picture's width over height, once the stream is known, so the page can size its box to the
    /// picture instead of assuming 16:9.
    var aspect: (CGFloat) -> Void = { _ in }
    /// Whether the player's own controls are showing, so the page can avoid drawing its own bottom
    /// affordances (the unfolded-upright Duo's details grab-handle) over the transport bar.
    var chromeVisible: (Bool) -> Void = { _ in }
    /// Open the episode picker. The page routes this: on the unfolded-upright Duo the full-bleed
    /// picture has no room for an in-picture panel, so it opens the half-height details sheet instead
    /// of the store's panel.
    var openEpisodes: () -> Void = {}
}

/// The full-screen player sets the app's appearance; one at the top of a page sets only its own.
struct PlayerScheme: ViewModifier {
    let ownsScreen: Bool
    func body(content: Content) -> some View {
        if ownsScreen { content.preferredColorScheme(.dark) } else { content.environment(\.colorScheme, .dark) }
    }
}

extension View {
    /// Under the status bar and the home indicator on a screen of its own; inside its frame at the top of a page,
    /// where reaching into the safe area would run the picture under the status bar.
    @ViewBuilder func playerBleed(_ bleeds: Bool, edges: Edge.Set = .all) -> some View {
        if bleeds { ignoresSafeArea(edges: edges) } else { self }
    }

    /// Hands the picture the stream's own shape when the viewer asked the box to follow the source, and
    /// leaves it filling the box for the other three modes. What changes is the *box*, not the picture:
    /// `.resizeAspect` inside a box of the stream's own shape has nothing to pad, so the frame reaches
    /// every edge with no crop and no bars — which is the whole point of "按上游来".
    @ViewBuilder func pictureBox(_ scaling: PictureScaling, aspect: CGFloat?) -> some View {
        if scaling.followsSource, let aspect, aspect.isFinite, aspect > 0 {
            self.aspectRatio(aspect, contentMode: .fit)
        } else {
            self
        }
    }
}

/// The position and the length in a capsule over a scrubber the width of the screen, as in YouTube's player, and
/// scrubbing as in Telegram's: while dragged, only the bar, the time and a frame from that point (above the handle)
/// follow the finger, and the video seeks once, when the finger lifts. Seeking the playing video along with the finger
/// left it stuttering behind. A view of its own, so only it redraws as the position moves.
private struct SeekBar<Accessory: View>: View {
    /// The height of the time's row, which the accessory shares: the episode buttons are 36 points round.
    static var timeRow: CGFloat { 36 }
    let clock: PlayerClock
    /// Off when the chrome shows the time itself, in the row above: the bar is then nothing but
    /// the track, and the readout appears only while scrubbing, when the finger needs it.
    var showsClock = true
    /// Playing with the controls showing: the bar follows the player every frame.
    let moving: Bool
    let hold: (Bool) -> Void
    let sought: () -> Void
    /// At the right of the time: the episode buttons.
    @ViewBuilder let accessory: () -> Accessory
    /// Where a drag began: the position then and the finger's start. The handle moves by as much as the finger does
    /// (Telegram), rather than jumping under it; a touch away from the handle puts it there first.
    @State private var drag: (position: Double, location: CGPoint)?
    /// Slower scrubbing while the finger moves away from the bar: half, a quarter and a tenth of the speed (Telegram).
    @State private var fineness = 1.0
    @State private var width: CGFloat = 0

    var body: some View {
        // Every display frame while it plays, as AVKit's bar does; paused, held or hidden, only when the clock changes.
        let follows = moving && clock.scrubbing == nil
        TimelineView(.animation(paused: !follows)) { _ in
            bar(clock.scrubbing ?? (follows ? clock.currentPosition : clock.position))
        }
        // Outside the bar, which is one accessibility element. Gone while scrubbing, when the time grows with the
        // scrubbing speed's label and the finger is there to scrub.
        .overlay(alignment: .topTrailing) {
            if drag == nil { accessory().frame(height: Self.timeRow).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.15), value: drag == nil)
        .sensoryFeedback(.selection, trigger: fineness)
    }

    private func bar(_ position: Double) -> some View {
        let duration = clock.duration
        let value = min(max(0, position), duration)
        let x = duration > 0 ? width * value / duration : 0
        let held = drag != nil
        return VStack(alignment: .leading, spacing: 6) {
            if showsClock || held {
                HStack(spacing: 8) {
                    Text(Self.format(value) + " / " + Self.format(duration))
                    if let speed = Self.fineLabel(fineness) { Text(speed).foregroundStyle(.white.opacity(0.75)) }
                }
                .font(.footnote.monospacedDigit().weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassSurface(.regular, in: Capsule())
                .frame(height: Self.timeRow)
                .accessibilityHidden(true)
            }
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3)).frame(height: held ? 6 : 4)
                Capsule().fill(.white).frame(width: max(0, x), height: held ? 6 : 4)
                Circle().fill(.white)
                    .frame(width: held ? 24 : 14, height: held ? 24 : 14)
                    .shadow(color: .black.opacity(0.35), radius: 3)
                    .offset(x: x - (held ? 12 : 7))
            }
            .frame(maxWidth: .infinity, minHeight: 32)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { changed($0, value: value, duration: duration) }
                .onEnded { _ in ended() })
            .animation(.spring(duration: 0.3, bounce: 0.3), value: held)
        }
        // The frame at the finger, above the time, centred on the handle and kept on screen.
        .overlay(alignment: .topLeading) {
            if held, let preview = clock.preview {
                let previewWidth: CGFloat = 160
                Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: previewWidth)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.8), lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 6)
                    .alignmentGuide(.top) { $0[.bottom] + 8 }
                    .offset(x: min(max(0, x - previewWidth / 2), max(0, width - previewWidth)))
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.12), value: held && clock.preview != nil)
        .accessibilityElement()
        .accessibilityLabel(L10n.text("Playback Position"))
        .accessibilityValue(Self.format(value))
        .accessibilityIdentifier("player.seek")
        .accessibilityAdjustableAction { direction in
            clock.seek(to: min(max(0, value + (direction == .increment ? 10 : -10)), duration))
            sought()
        }
    }

    private func changed(_ gesture: DragGesture.Value, value: Double, duration: Double) {
        guard duration > 0, width > 0 else { return }
        if drag == nil {
            let handle = width * value / duration
            let start = abs(gesture.startLocation.x - handle) <= 30 ? value : duration * Double(min(max(0, gesture.startLocation.x / width), 1))
            drag = (start, gesture.startLocation)
            hold(true)
            clock.scrub(to: start)
        }
        guard let begin = drag else { return }
        let away = abs(gesture.location.y - begin.location.y)
        let wanted = away > 150 ? 0.1 : away > 100 ? 0.25 : away > 50 ? 0.5 : 1
        if wanted != fineness {
            // Carry on from here at the new speed, so the handle doesn't jump.
            fineness = wanted
            drag = (clock.scrubbing ?? begin.position, gesture.location)
            return
        }
        let moved = Double((gesture.location.x - begin.location.x) / width) * duration * fineness
        clock.scrub(to: min(max(0, begin.position + moved), duration))
    }

    private func ended() {
        guard drag != nil else { return }
        drag = nil
        fineness = 1
        hold(false)
        clock.endScrub()
        sought()
    }

    private static func fineLabel(_ fineness: Double) -> String? {
        switch fineness {
        case 0.5: L10n.text("Half-Speed Scrubbing")
        case 0.25: L10n.text("Quarter-Speed Scrubbing")
        case ..<0.25: L10n.text("Fine Scrubbing")
        default: nil
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.isFinite ? max(0, seconds) : 0)
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

/// The top row's three parts: Back, the title and the buttons. All in one row while the title keeps `minimumTitle`;
/// otherwise Back and the buttons share the first row and the title has the next one to itself. On a screen too
/// narrow even for Back beside the buttons, the buttons take the first row alone and Back goes beside the title.
private struct PlayerTopBar: SwiftUI.Layout {
    var spacing: CGFloat = 12
    var rowSpacing: CGFloat = 10
    var minimumTitle: CGFloat = 160

    private enum Arrangement { case oneRow, titleBelow, buttonsAlone }

    private func arrangement(_ width: CGFloat, back: CGSize, buttons: CGSize) -> Arrangement {
        if back.width + spacing + minimumTitle + spacing + buttons.width <= width { return .oneRow }
        return back.width + spacing + buttons.width <= width ? .titleBelow : .buttonsAlone
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let back = subviews[0].sizeThatFits(.unspecified), buttons = subviews[2].sizeThatFits(.unspecified)
        let width = proposal.width ?? back.width + subviews[1].sizeThatFits(.unspecified).width + buttons.width + 2 * spacing
        func title(_ room: CGFloat) -> CGSize { subviews[1].sizeThatFits(ProposedViewSize(width: room, height: nil)) }
        switch arrangement(width, back: back, buttons: buttons) {
        case .oneRow:
            let title = title(width - back.width - buttons.width - 2 * spacing)
            return CGSize(width: width, height: max(back.height, buttons.height, title.height))
        case .titleBelow:
            return CGSize(width: width, height: max(back.height, buttons.height) + rowSpacing + title(width).height)
        case .buttonsAlone:
            return CGSize(width: width, height: buttons.height + rowSpacing + max(back.height, title(width - back.width - spacing).height))
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let back = subviews[0].sizeThatFits(.unspecified), buttons = subviews[2].sizeThatFits(.unspecified)
        /// Places a subview with its vertical centre at `middle`; the title gets `room` and truncates to it.
        func place(_ index: Int, x: CGFloat, middle: CGFloat, room: CGFloat? = nil) {
            let size = room.map { subviews[index].sizeThatFits(ProposedViewSize(width: $0, height: nil)) } ?? subviews[index].sizeThatFits(.unspecified)
            subviews[index].place(at: CGPoint(x: x, y: middle - size.height / 2), proposal: ProposedViewSize(width: size.width, height: size.height))
        }
        switch arrangement(bounds.width, back: back, buttons: buttons) {
        case .oneRow:
            place(0, x: bounds.minX, middle: bounds.midY)
            place(1, x: bounds.minX + back.width + spacing, middle: bounds.midY, room: bounds.width - back.width - buttons.width - 2 * spacing)
            place(2, x: bounds.maxX - buttons.width, middle: bounds.midY)
        case .titleBelow:
            let row = max(back.height, buttons.height)
            place(0, x: bounds.minX, middle: bounds.minY + row / 2)
            place(2, x: bounds.maxX - buttons.width, middle: bounds.minY + row / 2)
            let title = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            place(1, x: bounds.minX, middle: bounds.minY + row + rowSpacing + title.height / 2, room: bounds.width)
        case .buttonsAlone:
            place(2, x: bounds.maxX - buttons.width, middle: bounds.minY + buttons.height / 2)
            let room = bounds.width - back.width - spacing
            let row = max(back.height, subviews[1].sizeThatFits(ProposedViewSize(width: room, height: nil)).height)
            let middle = bounds.minY + buttons.height + rowSpacing + row / 2
            place(0, x: bounds.minX, middle: middle)
            place(1, x: bounds.minX + back.width + spacing, middle: middle, room: room)
        }
    }
}

/// A round glass button of the given size, for play and skip in the middle of the picture.
private struct PlayerCircleStyle: ButtonStyle {
    var size: CGFloat
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .glassSurface(.regular.interactive(), in: Circle())
            .contentShape(Circle())
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.38)
            // Gives under the finger, so a tap shows before the player answers.
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

/// The system's AirPlay button, which presents the route picker itself.
struct AirPlayButton: UIViewRepresentable {
    /// 清空 tint：只留可点区域，字形由调用方自己盖一颗 SF Symbol。
    ///
    /// One 皮肤必须这么做 —— `AVRoutePickerView` 自带一圈内边距，字形尺寸也不跟
    /// 外层 frame 走，塞进和邻居一样大的框里永远小一圈（看着就是「就它一个特别小」）。
    /// 清掉 tint 后路由选择器照常弹，视觉交给同尺寸的 `Image(systemName: "airplayvideo")`，
    /// 且那颗图标 `allowsHitTesting(false)`，点击仍然落在系统按钮上。
    var transparent = false

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = transparent ? .clear : .white
        return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = transparent ? .clear : .white
    }
}

/// The picture's own gestures, in UIKit: taps, a touch and hold followed while the finger moves, slides and a pinch.
/// SwiftUI's long press ends where a drag would begin, and a tap beside it can fire as the held finger lifts.
private struct PictureGestures: UIViewRepresentable {
    enum Hold { case began, moved(CGSize), ended }
    /// Sideways seeks; up or down sets the brightness on the left half and the volume on the right.
    enum Slide { case seek, brightness, volume }
    enum Swipe { case began(Slide), moved(CGSize, in: CGSize), ended }
    /// Where the tap landed across the picture, and the picture's width.
    let tap: (CGFloat, CGFloat) -> Void
    let hold: (Hold) -> Void
    let swipe: (Swipe) -> Void
    /// Whether slides up or down set the brightness and the volume.
    var levels = true
    /// Pinched out (true) or in, as in YouTube: fill the screen or fit the picture.
    let pinch: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        press.minimumPressDuration = 0.35
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        // A touch that lifts before the hold begins is a tap, at once; each tap of a double tap comes on its own.
        tap.require(toFail: press)
        // A finger that moves before the hold begins slides instead.
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched(_:)))
        for recognizer in [press, tap, pan, pinch] { view.addGestureRecognizer(recognizer) }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PictureGestures?
        private var start = CGPoint.zero
        private var slide = Slide.seek

        @objc func tapped(_ tap: UITapGestureRecognizer) {
            guard let view = tap.view else { return }
            parent?.tap(tap.location(in: view).x, view.bounds.width)
        }

        @objc func pressed(_ press: UILongPressGestureRecognizer) {
            let location = press.location(in: press.view)
            switch press.state {
            case .began: start = location; parent?.hold(.began)
            case .changed: parent?.hold(.moved(CGSize(width: location.x - start.x, height: location.y - start.y)))
            case .ended, .cancelled, .failed: parent?.hold(.ended)
            default: break
            }
        }

        @objc func panned(_ pan: UIPanGestureRecognizer) {
            guard let view = pan.view else { return }
            switch pan.state {
            case .began: parent?.swipe(.began(slide))
            case .changed:
                let moved = pan.translation(in: view)
                parent?.swipe(.moved(CGSize(width: moved.x, height: moved.y), in: view.bounds.size))
            case .ended, .cancelled, .failed: parent?.swipe(.ended)
            default: break
            }
        }

        @objc func pinched(_ pinch: UIPinchGestureRecognizer) {
            guard pinch.state == .ended, abs(pinch.scale - 1) > 0.1 else { return }
            parent?.pinch(pinch.scale > 1)
        }

        /// Sideways anywhere; up or down only away from the edges that Notification Center, Control Center and the
        /// Home indicator use.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return true }
            let velocity = pan.velocity(in: view)
            if abs(velocity.x) > abs(velocity.y) { slide = .seek; return true }
            let location = pan.location(in: view)
            guard parent?.levels == true, PictureLevel.slides(fromY: location.y, height: view.bounds.height) else { return false }
            slide = location.x < view.bounds.width / 2 ? .brightness : .volume
            return true
        }
    }
}

/// The picture in an AVPlayerLayer, which Picture in Picture takes over while it runs. The layer keeps
/// its player while the instance's own PiP is up — the floating window renders this very layer — and is
/// hidden inline by the player's placeholder. A layer that is not the running PiP's source drops its
/// player, so one `AVPlayer` never drives two layers at once.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    /// How the picture meets the layer's box, chosen by the viewer and not by the shape of the device.
    let gravity: AVLayerVideoGravity
    let pip: PictureInPicture
    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        if pip.shouldRender(view.playerLayer) { view.playerLayer.player = player }
        pip.attach(view.playerLayer)
        return view
    }
    func updateUIView(_ view: LayerView, context: Context) {
        let target: AVPlayer? = pip.shouldRender(view.playerLayer) ? player : nil
        if view.playerLayer.player !== target { view.playerLayer.player = target }
        // The floating window follows the source layer's `videoGravity`: `.resizeAspect` sizes it to the
        // video's own shape, while a fill sizes it to the layer's box — a portrait box in landscape,
        // which crops the film and lets the window drift off the screen. While PiP is up the inline
        // picture hides behind the placeholder, so the source layer must fit, never fill.
        view.playerLayer.videoGravity = pip.active ? .resizeAspect : gravity
    }
}

/// Picture in Picture for the player layer: the button, and carrying on in a floating window when the app is left.
@MainActor @Observable final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate {
    /// 平台是否支持 PiP。
    ///
    /// ⚠️ 这个值是**判断我们能不能做 PiP 的唯一硬依据**，必须留痕：
    /// - 模拟器（CoreSimulator）实测返回 **false**（AVKit 原话
    ///   `+[AVPictureInPicturePlatformAdapter isPictureInPictureSupported] → NO`）
    /// - **但 Fig VM 上哔哩哔哩能弹出 PiP 悬浮窗** ⇒ VM 平台是支持的。
    /// 所以在 VM/真机上如果这里仍是 false，那问题在我们的调用方式，不在平台。
    let supported: Bool = {
        let v = AVPictureInPictureController.isPictureInPictureSupported()
        #if DEBUG
        print("[PiP] isPictureInPictureSupported = \(v)")
        #endif
        return v
    }()
    private(set) var possible = false
    private(set) var active = false
    /// [mi3s] 二开：按钮是否可点。iOS 上画面归 `AVPlayerViewController`，
    /// PiP 能不能起由 AVKit 报；其余平台仍看自建 controller 的 `possible`。
    /// 与上游一致：只看自建 controller 报的 `possible / active`。
    var canToggle: Bool { possible || active }
    /// 这套画面「有没有能力」起应用外小窗 —— 退场裁决器（`PlaybackExit`）的 `pipPossible`。
    ///
    /// 与 `current != nil` 的区别很关键：`current` 只在 PiP **已经起来过**之后才非 nil
    /// （唯一赋值点在 `willStartPictureInPicture`），拿它当能力判据等于
    /// 「以前浮过才允许再浮」。首播时它恒为 nil，于是退场裁决会以为
    /// 「做不到」而走 ③b 的 `.keep`：离开 App 既不浮窗也不登出，音频在后台空转。
    ///
    /// 正确的问法是「平台支持 + 当前画面层已登记内容源」：
    ///   · `supported` = 平台级能力（模拟器恒 false，真机/VM 为 true）；
    ///   · `current != nil` = 已经浮着，当然也算可能的。
    /// 画面层没登记（哔哩哔哩皮肤在修 `BiliSkinPicture.pip` 之前就是这样）时仍返回 false，
    /// 那样 `.keep` 才是诚实的 —— 但那属于「这个皮肤还没接上」，由使用方自己保证。
    static var isSupportedForPlayback: Bool {
        // `supported` 是实例属性（每实例算一次平台判断），静态这里直接问平台；
        // `AVPictureInPictureController.isPictureInPictureSupported()` 是纯查询、无副作用。
        AVPictureInPictureController.isPictureInPictureSupported() || current != nil
    }

    /// Whether Picture in Picture is running, kept apart from the instance so it survives the iPhone Duo
    /// fold/unfold that tears the player view down and rebuilds it with a fresh `active = false`.
    private(set) static var isActive = false
    /// The controller whose floating window is showing right now. Shared so a rebuilt player view
    /// (iPhone Duo fold/unfold) can adopt it: its `AVPictureInPictureController` is gone with the old
    /// view, but the floating window still runs, so the fresh instance needs the running controller to
    /// read "active" and to stop PiP or return inline.
    private(set) static var current: AVPictureInPictureController?
    /// The layer the running controller was created on. While Picture in Picture is up, only this layer
    /// may render the player — the floating window takes its picture. Any other layer must not attach the
    /// player: an `AVPlayer` drives one layer's video at a time, and a second layer would steal the
    /// picture from the floating window, leaving it audio-only.
    private static weak var sourceLayer: AVPlayerLayer?
    /// Called on the main actor when Picture in Picture starts or stops, so the session can turn off
    /// its queued-advance while PiP is active (AVKit's queue is unreliable inside the floating window).
    var onActiveChange: (@MainActor (Bool) -> Void)?
    /// Whether this instance may adopt the running controller when its view is rebuilt while PiP is up.
    /// Only the full-screen player may: it is the view a Duo fold tears down and rebuilds, so its rebuilt
    /// instance must take over the running controller. The mini player lives in the root view and is never
    /// rebuilt, so it must never adopt — adopting the full-screen player's controller would splice the two
    /// and mix their state.
    private let adoptsRunningController: Bool
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    /// The layer the controller was last bound to, so a stopped PiP can bind a fresh controller to the
    /// layer on screen now (the running controller's source layer can't be changed).
    @ObservationIgnored private weak var layer: AVPlayerLayer?
    /// 「离开 App 自动浮起」当前该开还是该关。
    ///
    /// controller 可能晚于用户操作才建出来（首帧才建），所以意图必须单独存一份：
    /// `suspendAutomaticFloating()` 在 controller 之前跑、就要在建 controller 时生效。
    @ObservationIgnored private var wantsAutomaticFloating = true

    init(adoptsRunningController: Bool = true) {
        self.adoptsRunningController = adoptsRunningController
        super.init()
        // 登记到弱表：`suspendAutomaticFloating()` 要能逐个点名关掉
        // 「离开 App 自动浮起」，否则折叠/转屏时 AVKit 会把重挂载当成离开。
        Self.registry.add(self)
    }

    /// Whether `layer` should render the player right now. While Picture in Picture is up, only the
    /// running controller's source layer renders; the inline picture is covered by the player's
    /// placeholder instead.
    func shouldRender(_ layer: AVPlayerLayer) -> Bool {
        if !Self.isActive { return true }
        return Self.sourceLayer === layer
    }

    func attach(_ layer: AVPlayerLayer) {
        guard supported else { return }
        self.layer = layer
        // Picture in Picture is already running. Only the full-screen player adopts the running
        // controller (a Duo fold rebuilt its view); a non-adopting instance — the mini player — keeps
        // clear of it entirely, so it can never steal the controller or mix its state with the floating
        // window's.
        if Self.isActive, let running = Self.current {
            if adoptsRunningController, controller !== running {
                controller = running
                running.delegate = self
                active = true
                observe(running)
            }
            return
        }
        // ⛔ 换了 layer 时**必须把 controller 的 contentSource 指过去**。
        //
        // 原来这里是 `guard controller == nil else { return }` —— 已有 controller 就什么都不做。
        // 但折叠、转向、进/出全屏、切页面都会换 layer，旧 layer 的 view 被销毁后，
        // controller 仍指着那一块已经不存在的画面：`isPictureInPicturePossible` 变成 false，
        // 自动浮起也就永远不会触发。用户看到的就是「返回主屏没有浮窗」。
        //
        // 上游（GitHub `jo32/tvbox-silicon` main，`PictureInPicture.attach`）正是这样写的：
        // layer 换了就改 `contentSource`，**不重建 controller**。
        // 重建会丢掉 PiP 状态与 delegate，改指向则一次到位。
        if let controller {
            if controller.contentSource?.playerLayer !== layer, !controller.isPictureInPictureActive {
                controller.contentSource = .init(playerLayer: layer)
            }
            return
        }
        makeController(for: layer)
    }

    /// 与上游一致：有 controller 就自己起停，不问 AVKit 在不在场。
    ///
    /// 曾经这里有两道门（`avkitHost != nil` 就 return），叠加 `canToggle` 的同类门之后，
    /// 画中画按钮要么不亮、要么亮着点了没反应 —— 而 AVKit 那条自动起浮也早被关掉了。
    /// 两条路都堵住，就是「返回主屏没有浮窗」。
    func toggle() {
        guard let controller = controller ?? Self.current else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            fitContent()
            controller.startPictureInPicture()
        }
    }

    /// [mi3s] 二开：「应用外悬浮小窗」。离开 App 时把画面交给系统 PiP 窗口。
    ///
    /// 为什么不打开 AVKit 那个 `canStartPictureInPictureAutomaticallyFromInline`：
    /// 它的语义是「inline 图层离开屏幕」，而本 App 的图层在折叠、转向、进出全屏、
    /// 切页面时都会被重挂一次，AVKit 每次都当成「用户离开 App」，于是页面和悬浮窗
    /// 同时放同一集（见 `makeController` 里的注释）。这里改成显式、有时机的一次调用：
    /// 只在我们自己判定「用户在播放中离开了 App」时浮起，回来时收回。
    /// [mi3s] 二开：显式把画面交给系统 PiP 窗口。
    ///
    /// 自动浮起现在**是开的**，和上游一致：
    ///   · `makeController` 里 `canStartPictureInPictureAutomaticallyFromInline = true`；
    ///   · `OneStylePlayerSurface(automaticPiP: true)`。
    /// 所以正常路径下系统会在离开 App 时自己浮起，这两个方法是给
    /// 「退场裁决器显式要求起浮」用的补充入口（回归脚本、自动化）。
    /// 让当前挂载的播放器起悬浮窗。
    ///
    /// 现在只有一条路：自建 `AVPictureInPictureController`（`contentSource: playerLayer`）。
    /// 它本来就支持裸 `AVPlayerLayer`，也支持 AVKit 之外的任何 layer —— 只要 `attach` 时
    /// 把 `contentSource` 指到当前那一块画面（见 `attach`），这里就能起浮。
    static func startCurrent() {
        guard let controller = current, !controller.isPictureInPictureActive,
              controller.isPictureInPicturePossible else { return }
        controller.startPictureInPicture()
    }

    // MARK: - 重挂载期间临时关掉「自动浮起」

    /// 所有**活着的** PiP 协调器。`canStartPictureInPictureAutomaticallyFromInline` 是
    /// 每个 controller 各自的属性，要临时关必须逐个点名 —— 而正在播的那一个可能是
    /// 页面里 `@State` 的实例（One / 哔哩哔哩皮肤各一个），也可能是全屏播放器的实例，
    /// 静态方法拿不到它们，所以在这里登记。
    ///
    /// 弱引用：页面销毁后自己消失，不需要显式反注册。
    private static let registry = NSHashTable<PictureInPicture>.weakObjects()

    /// 重挂载期间被临时关掉的实例快照。恢复时只恢复这一批，
    /// 不去动这期间新注册的（新实例还没经历过重挂载，它的开关本来就该是 on）。
    private static var suspended: [PictureInPicture] = []
    private static var resumeTask: Task<Void, Never>?

    /// 「重挂载窗口」是否开着。
    ///
    /// 自建 controller（One / 哔哩哔哩皮肤）走 `setAutomaticFloating` 关得掉，
    /// 但**原生皮肤的 `AVPlayerViewController` 不在这个 registry 里** ——
    /// 它的 `canStartPictureInPictureAutomaticallyFromInline` 由
    /// `OneStylePlayerSurface.updateUIViewController` 每次刷新时按构造参数写回，
    /// 一个静态函数碰不到那个实例。所以另立一个全局闸：
    /// `OneStylePlayerSurface` 读它来决定这次要写 true 还是 false。
    private(set) static var isAutomaticFloatingSuspended = false

    /// 折叠 / 展开 / 转屏 / 进出自绘页前后调用。
    ///
    /// ⛔ 这两个函数此前**只存在于注释里**（`makeController` 与 `OneStylePlayerSurface`
    /// 都写着「由 `suspendAutomaticFloating()` 短暂关闭」），但全仓没有任何定义 ——
    /// 于是两条自动浮起通路（`canStartPictureInPictureAutomaticallyFromInline = true`
    /// 与 `OneStylePlayerSurface(automaticPiP: true)`）**恒开**，
    /// 而 Duo 折叠、展开、转屏、进出全屏都会把画面层重挂一次，
    /// AVKit 把 `inline layer 离开屏幕` 当成「用户离开 App」，于是浮窗自己飞出来。
    ///
    /// 现在真的关：所有活着的实例一起关，`resumeAfter` 之后自动恢复。
    /// 用延时恢复而不是「等布局稳了再恢复」，是因为重挂载没有可观测的完成信号 ——
    /// 一段固定的宽限期比「等一个永远不来的回调」可靠。
    static func suspendAutomaticFloating(resumeAfter delay: TimeInterval = 1.5) {
        resumeTask?.cancel()
        var touched: [PictureInPicture] = []
        for pip in registry.allObjects {
            touched.append(pip)
            pip.setAutomaticFloating(false)
        }
        suspended = touched
        isAutomaticFloatingSuspended = true
        resumeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            resumeAutomaticFloating()
        }
        Diagnostics.shared.record(.info, "player",
            "auto PiP suspended for \(String(format: "%.1f", delay))s (\(touched.count) controllers)")
    }

    /// 恢复 `suspendAutomaticFloating()` 关掉的那一批。
    static func resumeAutomaticFloating() {
        resumeTask?.cancel()
        resumeTask = nil
        for pip in suspended { pip.setAutomaticFloating(true) }
        suspended = []
        isAutomaticFloatingSuspended = false
    }

    /// 单个实例的开关。`controller` 还没建出来时只记意图 ——
    /// `makeController` 建 controller 时会读 `wantsAutomaticFloating`，
    /// 否则「先 suspend 再建 controller」这一顺序会把 suspend 吃掉（开机首帧正好是这个顺序）。
    private func setAutomaticFloating(_ on: Bool) {
        wantsAutomaticFloating = on
        controller?.canStartPictureInPictureAutomaticallyFromInline = on
    }

    /// 收回正在跑的悬浮窗。回到 App 且画面已回到页面上时必须调用。
    static func stopCurrent() {
        guard let controller = current, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }

    func startFloating() {
        guard supported else { return }
        guard let controller = controller ?? Self.current else { return }
        guard !controller.isPictureInPictureActive else { return }
        guard controller.isPictureInPicturePossible else { return }
        fitContent()
        controller.startPictureInPicture()
    }

    /// 回到 App：悬浮窗收回，画面回到内嵌层。
    func stopFloating() {
        guard let controller = controller ?? Self.current, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }

    #if os(iOS)
    /// 当前承载画面的 `AVPlayerViewController`。AVKit 自己管 PiP，这里是唯一的入口。
    private(set) static weak var avkitHost: AVPlayerViewController?
    /// `AVPlayerViewController` 出现/消失时登记，PiP 按钮与状态都读它。
    func register(host: AVPlayerViewController?) {
        Self.avkitHost = host
    }

    /// `AVPlayerViewControllerDelegate` 的 PiP 回调转进来：页面据此显示/撤掉占位。
    func report(active now: Bool) {
        guard active != now else { return }
        active = now
        Self.isActive = now
        onActiveChange?(now)
    }
    #endif

    /// Fits the floating window to the video's own shape before it opens. The window follows the source
    /// layer's `videoGravity`; the inline landscape bleed leaves it `.resizeAspectFill`, which sizes the
    /// window to the layer's portrait box and crops the film. Asserting `.resizeAspect` here — for the
    /// button and the automatic leave-the-app start alike — tells AVKit to size the window from the
    /// video's `presentationSize` instead.
    private func fitContent() {
        layer?.videoGravity = .resizeAspect
    }

    private func makeController(for layer: AVPlayerLayer) {
        // ⛔ 建 PiP controller 之前，音频会话必须是「播放」类别且支持 PiP。
        //
        // 系统日志实测（模拟器，iOS 27）：
        //   `AVAudioSession indicates PIP is unavailable for this audio session`
        // 也就是 controller 建出来了，但这个会话没被标成可承载 PiP 的那一类，
        // 于是 `isPictureInPicturePossible` 恒 false、自动浮起永不触发。
        //
        // `PlaybackView.configure` 里确实配了 `.playback/.moviePlayback`，但那是
        // **通用播放器**的初始化路径；One/哔哩哔哩皮肤的画面是本文件自己的
        // `AVPlayerLayer`，它的 controller 可能先于那次配置建立（首帧就建）。
        // 这里再确认一次是幂等的，也不会打断正在播的声音。
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback || session.mode != .moviePlayback {
                try session.setCategory(.playback, mode: .moviePlayback)
            }
            try session.setActive(true)
        } catch {
            Diagnostics.shared.record(.warning, "player", "audio session for PiP: \(Diagnostics.describe(error))")
        }
        #endif
        let controller = AVPictureInPictureController(contentSource: .init(playerLayer: layer))
        controller.delegate = self
        // ⛔ 这里要和上游一致：**默认开着**。（旧的「Off on purpose」注释已作废：
        //    当时关掉它是为了躲「折叠/转向被当成离开 App」，但那连真离开也一起关掉了。）
        //
        // 上游原生（`fusion/base`）就是 `= true`，所以「离开 App 浮窗」天生可用。
        // 我们二开时为了修「折叠/转向/切页面时 AVKit 把重挂载当作离开 App」，
        // 把它改成了 false —— 代价是**顺带把真离开也关掉了**，于是
        // 「全屏播放返回主屏幕没有浮窗」。
        //
        // 正确的修法不是关掉能力，而是**只在会误判的窗口内临时关**：
        // 折叠、转向、进/出全屏这些「重挂载」动作前后由 `suspendAutomaticFloating()`
        // 短暂关闭，动作结束后立刻恢复。这样能力保留，误判也被挡住。
        //
        // ⛔ 值来自 `wantsAutomaticFloating`，不是硬编码 true：
        // 重挂载窗口内 `suspendAutomaticFloating()` 会把它压到 false，
        // 此时若 controller 恰好在这一帧才建出来，硬编码 true 会让那次 suspend 白做 ——
        // 而「首帧建 controller + 同帧折叠」正是开机进页时最常见的顺序。
        controller.canStartPictureInPictureAutomaticallyFromInline = wantsAutomaticFloating
        observe(controller)
        self.controller = controller
    }

    private func observe(_ controller: AVPictureInPictureController) {
        observation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor [weak self] in self?.possible = possible }
        }
    }

    /// After a PiP the rebuild adopted is stopped, bind a fresh controller to the layer now on screen:
    /// the running controller still points at the pre-rebuild layer, whose view is gone, so starting
    /// again on it would float a picture nobody can see.
    private func rebind() {
        controller = nil
        observation = nil
        guard supported, let layer else { return }
        makeController(for: layer)
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.fitContent()
            Self.isActive = true
            Self.current = self.controller
            Self.sourceLayer = self.layer
            self.active = true
            self.onActiveChange?(true)
            // ★ 探针：PiP 是**谁**、在**什么状态**下起来的。
            //
            // 用户报两个问题：「播放中出 PiP 但没有小窗 UI」、「合拢/展开也出小窗」。
            // 只记 "PiP started" 无法定位 —— 必须带上当时的页面状态与调用栈。
            let pageState = "\(PlaybackAudioSession.activeCount)"
            let auto = self.wantsAutomaticFloating ? "auto=on" : "auto=off"
            let stack = Thread.callStackSymbols.prefix(14)
                .map { $0.split(separator: " ").dropFirst(2).first.map(String.init) ?? "" }
                .joined(separator: "<")
            oneSkinLog("PiP START \(auto) liveSessions=\(pageState) stack=\(stack)")
            Diagnostics.shared.record(.info, "player", "PiP started")
        }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            Self.isActive = false
            Self.current = nil
            Self.sourceLayer = nil
            self.active = false
            self.onActiveChange?(false)
            self.rebind()
            Diagnostics.shared.record(.info, "player", "PiP stopped")
        }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        let detail = Diagnostics.describe(error)
        Task { @MainActor in Diagnostics.shared.record(.warning, "player", "Picture in Picture failed: \(detail)") }
    }
}

/// The playing item's position and duration, four times a second while it plays.
@MainActor @Observable final class PlayerClock {
    private(set) var position: Double = 0
    /// Zero until the item has a finite duration.
    private(set) var duration: Double = 0
    private(set) var item: AVPlayerItem?
    /// Where the seek bar is held, until the precise seek it ends with lands.
    private(set) var scrubbing: Double?
    /// Watches for absence of progress, not for errors: a stream that dies without failing sits at
    /// the same position for ever, and only this notices.
    @ObservationIgnored private let watchdog = StallWatchdog()
    /// The four marks of one attempt, so "it takes ages" becomes resolution, buffering and start.
    private(set) var marks = PlaybackMarks()
    /// Set when the watchdog has given up on this line, for the view to act on.
    private(set) var stalled = false
    @ObservationIgnored private weak var player: AVPlayer?
    @ObservationIgnored private var token: Any?

    func attach(_ player: AVPlayer) {
        detach()
        self.player = player
        // The observer also fires on seeks and rate changes, so a new item shows up here while paused too.
        token = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        tick(player.currentTime())
    }

    func detach() {
        if let token { player?.removeTimeObserver(token) }
        token = nil
    }

    /// The player's position now, read without waiting for the next tick.
    var currentPosition: Double {
        let seconds = player?.currentTime().seconds ?? 0
        return seconds.isFinite ? seconds : position
    }

    /// The frame the seek bar shows above its handle while dragged; nil until one is made, or where none can be.
    private(set) var preview: CGImage?
    @ObservationIgnored private var generator: AVAssetImageGenerator?
    @ObservationIgnored private var generatorItem: ObjectIdentifier?
    /// An item AVFoundation made no frame from (an HLS stream, say): no more tries for it.
    @ObservationIgnored private var previewless: ObjectIdentifier?
    @ObservationIgnored private var generating = false
    @ObservationIgnored private var nextPreview: Double?

    /// While dragging, only the bar, the time and the preview follow the finger; the playing video is left alone
    /// until the finger lifts (Telegram).
    func scrub(to seconds: Double) {
        scrubbing = seconds
        nextPreview = seconds
        makePreview()
    }

    /// Let go: one exact seek to where the finger stopped.
    func endScrub() {
        nextPreview = nil
        preview = nil
        if let target = scrubbing { seek(to: target) }
    }

    /// An exact seek; the bar stays at the target until it lands, rather than jumping back to the old position.
    func seek(to seconds: Double) {
        guard let player else { scrubbing = nil; return }
        scrubbing = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.scrubbing == seconds else { return }
                self.position = seconds
                self.scrubbing = nil
            }
        }
    }

    /// One frame at a time, then the latest place asked for (Telegram's MediaPlayerFramePreview does the same), from
    /// a generator of its own so the playing video isn't disturbed. Nearby keyframes are good enough, and quick.
    private func makePreview() {
        guard !generating, let seconds = nextPreview, let item = player?.currentItem else { return }
        let identity = ObjectIdentifier(item)
        guard previewless != identity else { nextPreview = nil; return }
        if generatorItem != identity {
            let generator = AVAssetImageGenerator(asset: item.asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 320)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
            self.generator = generator
            generatorItem = identity
        }
        guard let generator else { return }
        nextPreview = nil
        generating = true
        generator.generateCGImageAsynchronously(for: CMTime(seconds: seconds, preferredTimescale: 600)) { [weak self] image, _, _ in
            nonisolated(unsafe) let frame = image
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.generating = false
                if let frame { if self.scrubbing != nil { self.preview = frame } }
                else if self.preview == nil { self.previewless = identity }
                self.makePreview()
            }
        }
    }

    private func tick(_ time: CMTime) {
        guard let player else { return }
        if item !== player.currentItem { item = player.currentItem }
        let seconds = time.seconds
        position = seconds.isFinite ? max(0, seconds) : 0
        // The first non-zero position means a frame reached the screen.
        if marks.firstFrame == nil, position > 0 { marks.firstFrame = Date() }
        if scrubbing == nil, player.timeControlStatus == .playing {
            switch watchdog.report(position: position) {
            case .stalled:
                stalled = true
            case .exhausted:
                stalled = true
            default:
                if stalled { stalled = false }
            }
        }
        let length = player.currentItem?.duration.seconds ?? 0
        let finite = length.isFinite ? max(0, length) : 0
        // Observation reports every assignment, even of the same value; the duration rarely changes.
        if finite != duration { duration = finite }
    }
}

/// The item's audio tracks and subtitles, for the options menu.
@MainActor @Observable final class MediaTracks {
    struct Group {
        let group: AVMediaSelectionGroup
        let options: [AVMediaSelectionOption]
    }
    private(set) var audio: Group?
    private(set) var legible: Group?
    /// Bumped by a selection, so the menus show the new choice.
    private var revision = 0
    @ObservationIgnored private weak var item: AVPlayerItem?

    func load(_ item: AVPlayerItem?) async {
        self.item = item; audio = nil; legible = nil
        guard let item else { return }
        let asset = item.asset
        let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
        let subtitles = try? await asset.loadMediaSelectionGroup(for: .legible)
        guard !Task.isCancelled, self.item === item else { return }
        audio = audible.map { Group(group: $0, options: $0.options) }
        // Forced subtitles only translate foreign speech and come on by themselves; they aren't a choice.
        legible = subtitles.map { group in
            Group(group: group, options: group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) })
        }
    }

    func selected(in group: Group) -> AVMediaSelectionOption? {
        _ = revision
        return item?.currentMediaSelection.selectedMediaOption(in: group.group)
    }

    func select(_ option: AVMediaSelectionOption?, in group: Group) {
        item?.select(option, in: group.group)
        revision += 1
    }
}

/// The video on the Lock Screen, in Control Center and on headphones, with play, pause, skip and scrub: AVKit's
/// own player published these by itself. Music holds Now Playing only while no video plays (MusicRemoteControl).
@MainActor final class VideoNowPlaying {
    private var targets: [(MPRemoteCommand, Any)] = []

    func start(_ session: PlaybackSession) {
        guard targets.isEmpty else { return }
        let commands = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlaybackSession, MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { [weak self, weak session] event in
                MainActor.assumeIsolated {
                    guard let session else { return .noActionableNowPlayingItem }
                    action(session, event)
                    self?.update(title: nil, session: session)
                    return .success
                }
            }
            targets.append((command, target))
        }
        on(commands.playCommand) { session, _ in if session.paused { session.togglePlayback() } }
        on(commands.pauseCommand) { session, _ in session.player.pause() }
        on(commands.togglePlayPauseCommand) { session, _ in session.togglePlayback() }
        commands.skipForwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.preferredIntervals = [10]
        on(commands.skipForwardCommand) { session, _ in session.skip(10) }
        on(commands.skipBackwardCommand) { session, _ in session.skip(-10) }
        on(commands.changePlaybackPositionCommand) { session, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
            session.player.seek(to: CMTime(seconds: event.positionTime, preferredTimescale: 600))
        }
    }

    private var title = ""
    private var artworkSource: PlaybackArtwork?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

    /// The video's poster beside its title, loaded once per poster; none until it has loaded.
    func show(_ source: PlaybackArtwork, session: PlaybackSession) {
        guard source != artworkSource else { return }
        artworkSource = source; artwork = nil
        artworkTask?.cancel()
        guard let url = source.poster else { return }
        artworkTask = Task { [weak self, weak session] in
            guard let bitmap = await PosterPalette.image(url, headers: source.headers), !Task.isCancelled,
                  let self, let session, self.artworkSource == source else { return }
            self.artwork = Self.artwork(UIImage(cgImage: bitmap))
            self.update(title: nil, session: session)
        }
    }

    /// MediaPlayer asks for the image on its own queue: a closure made on the main actor would
    /// trap there, checking it runs on the main thread.
    private nonisolated static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// `title` nil keeps the one shown.
    func update(title: String?, session: PlaybackSession) {
        guard !targets.isEmpty else { return }
        if let title { self.title = title }
        let player = session.player, seekable = session.hasTimeline && !session.isLive
        let commands = MPRemoteCommandCenter.shared()
        for command in [commands.skipForwardCommand, commands.skipBackwardCommand, commands.changePlaybackPositionCommand] {
            command.isEnabled = seekable
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: self.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: session.isLive,
            MPNowPlayingInfoPropertyPlaybackRate: session.paused ? 0.0 : Double(session.boost ?? player.defaultRate),
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(player.defaultRate),
        ]
        let elapsed = player.currentTime().seconds
        if elapsed.isFinite { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
        if seekable, let duration = player.currentItem?.duration.seconds, duration.isFinite {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = session.paused ? .paused : .playing
    }

    func stop() {
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        artworkTask?.cancel(); artworkTask = nil; artworkSource = nil; artwork = nil
        // Music may already have taken Now Playing back as the player closed.
        let center = MPNowPlayingInfoCenter.default()
        if center.nowPlayingInfo?[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.video.rawValue {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }
    }
}

/// A stream address wrapped so it can drive a `sheet(item:)`. `URL` is `Hashable` but not
/// `Identifiable`, and conforming it globally would be a surprising thing to do to a Foundation type.
private struct HandoffStream: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
#endif
