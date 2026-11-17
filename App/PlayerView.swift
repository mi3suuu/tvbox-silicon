import SwiftUI
import AVKit
import TVCore

struct PlaybackView: View {
    let channel: Channel
    /// ⛔ 选集页（One 皮肤）专用：只要 `onAppear` 产生并启动 session，
    /// **不渲染任何画面层**。画面由 `OneSkinFixedPicture` 的 AVPlayerLayer 自绘。
    ///
    /// 挂完整播放层会在离屏 8×8 视图里再创建一个 AVPlayerViewController
    /// （通用播放器样式改动后的载体），和选集页的 AVPlayerLayer 抢同一个
    /// AVPlayer；竖屏片源还会被 `pictureBox` 按片源比例压成极窄一条，
    /// AVKit 随即停掉视频输出 —— 表现就是「有些资源点进去看不了」。
    var stageOnly: Bool = false
    /// 选集页（One 皮肤）用：把本视图**实际持有的**会话交回调用方。
    /// 换集时 `PlaybackView` 的 `@State session` 不会跟着 init 参数更新
    ///（SwiftUI 在视图身份不变时保留 @State），而是由 `.onChange(of: channel)`
    /// 在同一个 AVPlayer 上换掉 currentItem。画面层必须绑到这个交回的会话，
    /// 否则每集重新问 `Store` 取会拿到一个从未加载过的新 player —— 有声音没画面。
    /// 纯回调，不参与任何画面渲染，也不改播放器样式。
    var onStageSession: ((PlaybackSession) -> Void)? = nil
    #if os(iOS)
    /// Set when the player is the top of an iPhone watch page rather than a screen of its own.
    var watch: WatchPlayback? = nil
    #endif
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    @State private var session: PlaybackSession
    /// Whether the session was made here (and must be stopped here), rather than owned by a caller that hands it
    /// in so playback survives an iPhone Duo fold/unfold, where this view is torn down and rebuilt.
    @State private var ownsSession: Bool
    @State private var showsChrome = true
    @State private var hideTask: Task<Void, Never>?
    #if os(iOS)
    /// A watch page starts playing by itself, so its controls wait for a tap (`-qaPlayerControls` keeps them up).
    @State private var quietStart = !UserDefaults.standard.bool(forKey: "qaPlayerControls")
    #endif
    @AppStorage(DanmakuPreference.key) private var showsDanmaku = true
    @AppStorage(DanmakuArea.key) private var danmakuArea = DanmakuArea.standard
    @State private var showsDanmakuList = false
    /// The episode picker's open state lives on the store (`Store.showsEpisodes`), not here, so a
    /// Duo fold/unfold that tears this view down and rebuilds it keeps the picker open.
    // 上游 1.8.23 在同一视图上新增的三个 sheet 开关（R3：与上面那条二开说明并存）。
    @State private var showsDanmakuSettings = false
    @State private var showsEpisodes = false
    @State private var showsChannels = false
    @AppStorage(VideoEnhancement.upscaleKey) private var upscalesVideo = false
    @AppStorage(VideoEnhancement.smoothKey) private var smoothsVideo = false
    #if os(tvOS)
    @AppStorage(PlaybackInfo.key) private var showsPlaybackInfo = false
    // [mi3s] 二开融合（上游 1.8.11）：tvOS 播放倍速与「铺满屏幕」两个播放器内选项。
    // 上游把两者做成 NativePlayerView 的 transport bar 菜单项，状态留在这里。
    @State private var playbackSpeed: Float = 1
    @State private var fillsScreen = false
    @State private var transportBar = TransportBarVisibility()
    #endif
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    #if os(iOS)
    init(channel: Channel, session: PlaybackSession? = nil, watch: WatchPlayback? = nil, stageOnly: Bool = false,
         onStageSession: ((PlaybackSession) -> Void)? = nil) {
        self.channel = channel
        self.watch = watch
        self.stageOnly = stageOnly
        self.onStageSession = onStageSession
        if let session {
            _session = State(initialValue: session)
            _ownsSession = State(initialValue: false)
        } else {
            _session = State(initialValue: PlaybackSession())
            _ownsSession = State(initialValue: true)
        }
    }
    #else
    init(channel: Channel, session: PlaybackSession? = nil, stageOnly: Bool = false,
         onStageSession: ((PlaybackSession) -> Void)? = nil) {
        self.channel = channel
        self.stageOnly = stageOnly
        self.onStageSession = onStageSession
        if let session {
            _session = State(initialValue: session)
            _ownsSession = State(initialValue: false)
        } else {
            _session = State(initialValue: PlaybackSession())
            _ownsSession = State(initialValue: true)
        }
    }
    #endif

    private var chromeVisible: Bool {
        #if os(iOS)
        if playerLayout == .inline, quietStart { return session.error != nil }
        #endif
        return showsChrome || session.error != nil || session.loading
    }

    var body: some View {
        ZStack {
            #if os(iOS)
            Color.black.playerBleed(playerLayout != .inline)
            #else
            Color.black.ignoresSafeArea()
            #endif
            #if os(tvOS)
            // Remove the native focus environment while recovery controls are shown.
            if session.error == nil {
                NativePlayerView(player: session.player, comments: session.danmaku, showsDanmaku: $showsDanmaku, opacity: session.danmakuOpacity, revision: session.danmakuRevision,
                                 qualities: session.qualities, quality: session.quality, choose: { session.choose(quality: $0) },
                                 audio: session.audioChoices, audioChoice: session.audioChoice, chooseAudio: { session.chooseAudio($0) },
                                 live: session.isLive, previous: episodeAction(store.step(back: true, from: channel, session: session)),
                                 next: episodeAction(store.step(back: false, from: channel, session: session)), waiting: waitContent,
                                 enhancer: session.enhancer, upscale: $upscalesVideo, smooth: $smoothsVideo, info: $showsPlaybackInfo,
                                 speed: playbackSpeed, setSpeed: { playbackSpeed = $0; session.setSpeed($0) }, fills: $fillsScreen, danmakuArea: $danmakuArea,
                                 external: session.externalSubtitles, skip: session.skipOffer, skipSource: { session.skipSourceSegment() },
                                 skipping: session.canSkip ? session.skipSettings : nil, setSkipping: { session.applySkipSettings($0) },
                                 markSkip: { session.markSkip(intro: $0) },
                                 chapters: session.chapters,
                                 exitWhileWaiting: session.showsPicture ? nil : { dismiss() }, episodes: episodeChoices, channels: channelChoices,
                                 lines: session.lines.indices.map { L10n.text("Line %@", "\($0 + 1)") }, line: session.line,
                                 chooseLine: { session.choose(line: $0) }, transportBar: transportBar,
                                 titleRow: AnyView(TVPlayerTitleRow(channel: channel, session: session, transportBar: transportBar).environment(store))).ignoresSafeArea()
                    .onAppear { playbackSpeed = session.player.defaultRate }
            }
            // Until the picture starts, AVKit's player keeps the Back press to itself, so a stream that never
            // loads (a dead live channel) left no way out but quitting the app. This takes focus and closes instead.
            if session.error == nil && !session.showsPicture {
                Color.clear.loadingFocus(takeFocus: true) { dismiss() }
                    .accessibilityIdentifier("player.waiting")
            }
            // In the title-safe corner, over the picture and clear of the transport bar.
            if showsPlaybackInfo && session.error == nil && session.showsPicture {
                PlaybackInfoPanel(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
            }
            #elseif os(iOS)
            // 选集页只借 onAppear 启动 session，画面不在这里画。
            if !stageOnly {
            MobilePlayerView(channel: channel, session: session, showsDanmaku: $showsDanmaku, upscalesVideo: $upscalesVideo, smoothsVideo: $smoothsVideo,
                             waiting: waitContent, chromeVisible: chromeVisible, toggleChrome: toggleChrome, poke: poke, hold: holdChrome,
                             close: exit, layout: playerLayout, immersive: watch?.immersive ?? false,
                             toggleFullScreen: watch.map { _ in toggleFullScreen },
                             openEpisodes: { watch?.openEpisodes() ?? { store.showsEpisodes = true }() },
                             miniplayer: miniplayer,
                             aspect: { watch?.aspect($0) })
            }
            #else
            NativePlayerView(player: session.player, comments: session.danmaku, showsDanmaku: $showsDanmaku, opacity: session.danmakuOpacity, revision: session.danmakuRevision).ignoresSafeArea()
            chrome.opacity(chromeVisible ? 1 : 0).allowsHitTesting(chromeVisible)
            #endif
            status
            #if !os(tvOS)
            SourceSkipButton(session: session)
            SkipNoticeView(session: session)
            #endif
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "qaPlaybackProbe") {
                VStack {
                    Text(session.catalogDanmaku.automaticState)
                        .accessibilityIdentifier("player.qa.danmaku")
                        .accessibilityValue("\(session.danmaku.count)")
                    Text("Playback position").accessibilityIdentifier("player.qa.position")
                        .accessibilityValue("\(session.position)")
                }
                .font(.caption2).foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .allowsHitTesting(false)
            }
            // `-qaEnhanceHUD 1`: what the enhancer is doing, the frame rate it draws, and the screen's own rate.
            if UserDefaults.standard.bool(forKey: "qaEnhanceHUD") {
                Text(enhanceHUD)
                    .font(.system(size: 22, weight: .medium, design: .monospaced)).foregroundStyle(.white)
                    .padding(12).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                    .padding(60)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
            #endif
        }
        #if os(iOS)
        // Registers the external-display accessory while the player is on screen (iOS 27): the system only
        // offers the display to apps that ask for it, and takes it back when the player closes.
        .background(ExternalDisplaySceneRegistrar().allowsHitTesting(false))
        // On a watch page the rest of the page keeps its own appearance.
        .modifier(PlayerScheme(ownsScreen: watch == nil))
        // The full-screen player owns the whole display, so it hides the status bar. A watch page's inline
        // player keeps it (the page hides it itself). This is what kept the time visible over the letterbox
        // bars on the iPhone Duo's inner display — a 16:9 picture on the ~1.42:1 inner screen leaves bars
        // above and below, and the un-hidden clock sat on the top bar.
        .statusBarHidden(watch == nil)
        #else
        .preferredColorScheme(.dark)
        #endif
        // Translated subtitles are translated here, where Translation can ask to download a language.
        .subtitleTranslation()
        #if os(macOS)
        .frame(minWidth: 880, minHeight: 540)
        #endif
        #if !os(tvOS)
        .onContinuousHover { _ in poke() }
        #if os(iOS)
        // The controls stay up while paused and start their countdown again on play.
        .onChange(of: session.paused) { _, paused in if paused { hideTask?.cancel() } else if showsChrome { scheduleHide() } }
        // The watch page draws its own bottom affordances (the unfolded-upright Duo's details grab-handle),
        // so it must know when the player's transport bar is up to avoid drawing over it.
        .onChange(of: chromeVisible) { _, visible in watch?.chromeVisible(visible) }
        #else
        .simultaneousGesture(TapGesture().onEnded { poke() })
        #endif
        #endif
        .onAppear {
            // A session handed in by an iPhone Duo's watch page already plays this channel after a fold/unfold:
            // don't start it again, which would drop back to the beginning.
            if !session.isPlaying(channel) { startCatalogPlayback(session, channel: channel, store: store) }
            showOnStart()
            // 把真正持有并播放的会话交给选集页画面层（见 onStageSession 注释）。
            onStageSession?(session)
            #if os(iOS)
            ExternalDisplay.shared.attach(session.player, store: store)
            #endif
        }
        #if DEBUG && os(iOS)
        // `-qaWatchFullScreen <seconds>`: a watch page's player goes full screen after that long, for screenshots.
        .task(id: watch != nil) {
            let delay = UserDefaults.standard.double(forKey: "qaWatchFullScreen")
            guard watch?.fullScreen == false, delay > 0 else { return }
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled { toggleFullScreen() }
        }
        #endif
        .onChange(of: channel) { _, channel in
            if !session.isPlaying(channel) { startCatalogPlayback(session, channel: channel, store: store) }
            showOnStart(opening: false)
        }
        #if os(iOS)
        .onChange(of: session.showsPicture || session.error != nil, initial: true) { _, started in watch?.started(started) }
        .onAppear { watch?.opened(session) }
        #endif
        .onChange(of: showsDanmaku) { _, value in session.catalogDanmaku.enabled = value }
        .onChange(of: session.catalogDanmaku.enabled) { _, value in showsDanmaku = value }
        #if os(iOS)
        // The episode sheet and the end-of-series screen, presented according to
        // the shape on screen: a sheet when the player fills the display, a panel
        // inside the picture at the top of a watch page. `PlayerSurface` holds
        // that rule so all three iPhone Duo shapes agree.
        .overlay {
            PlayerAuxiliaryHost(
                surface: PlayerSurface(layout: playerLayout),
                showsPanel: Binding(get: { store.showsEpisodes }, set: { store.showsEpisodes = $0 }),
                panel: { episodePanel },
                showsEndScreen: store.seriesEnd != nil,
                endScreen: { endScreenContent }
            )
            .allowsHitTesting(true)
        }
        #endif
        #if os(macOS)
        // On the Mac the sheet is the only episode surface, so it is presented here rather than by
        // the surface rule the iPhone Duo needs.
        .sheet(isPresented: Binding(get: { store.showsEpisodes }, set: { store.showsEpisodes = $0 })) {
            episodePanel
                .frame(minWidth: 560, minHeight: 600)
        }
        #endif
        .onDisappear {
            hideTask?.cancel(); store.cancelEpisodeSelection()
            // A fold/unfold hands the session in (ownsSession == false) and tears this view down; keep the
            // picker open then. Only a real close (ownsSession == true) dismisses it.
            if ownsSession { session.stop(); store.showsEpisodes = false }
            #if os(iOS)
            ExternalDisplay.shared.detach(session.player)
            PlayerOrientation.release()
            #endif
        }
        #if os(iOS)
        // Opening iPhone Duo moves the app to the inner display, which ignores orientations. Suspend a
        // landscape lock (remembering it) and restore the viewer's grip when the outer display returns,
        // so a landscape playback stays landscape on the way back instead of snapping upright.
        .onChange(of: horizontalSizeClass == .regular && verticalSizeClass == .regular) { _, large in
            if large { PlayerOrientation.suspend() } else { PlayerOrientation.restore() }
        }
        #endif
    }

    #if DEBUG
    private var enhanceHUD: String {
        var lines = ["Sharper \(UserDefaults.standard.bool(forKey: VideoEnhancement.upscaleKey) ? "on" : "off") · Smooth \(UserDefaults.standard.bool(forKey: VideoEnhancement.smoothKey) ? "on" : "off")"
                     + " · drawing: \(session.enhancer.status.upscaling ? "upscaled " : "")\(session.enhancer.status.smoothing ? "smoothed" : session.enhancer.status.active ? "" : "AVKit picture")",
                     session.enhancer.summary]
        #if !os(macOS)
        if let screen = UIApplication.shared.appWindowScene?.screen {
            lines.append("screen \(screen.maximumFramesPerSecond) Hz \(Int(screen.nativeBounds.width))×\(Int(screen.nativeBounds.height))")
        }
        #endif
        return lines.joined(separator: "\n")
    }
    #endif

    #if os(tvOS)
    private func episodeAction(_ step: PlayerStep?) -> EpisodeAction? {
        step.map { EpisodeAction(name: $0.name, busy: $0.busy, channel: $0.channel, play: $0.go) }
    }

    /// The video's lines and episodes for the player's Episodes menu and info-panel tab: nil for one episode.
    private var episodeChoices: EpisodeChoices? {
        guard let catalog = store.catalog(for: channel), catalog.video.episodes.count > 1 else { return nil }
        let episodes = catalog.video.episodes
        var seen = Set<String>()
        let flags = episodes.map(\.flag).filter { seen.insert($0).inserted }
        let store = store, channel = channel
        return EpisodeChoices(
            key: "\(catalog.video.id):\(episodes.count)",
            lines: flags.map { flag in (flag, episodes.filter { $0.flag == flag }) },
            labels: catalog.labels, current: channel.historyContext?.episode(in: episodes)?.id,
            busy: store.resolvingEpisode != nil,
            select: { store.selectEpisode($0, from: channel) },
            panel: { AnyView(TVPlayerEpisodesPanel(channel: channel).environment(store)) })
    }

    /// The list the live channel was picked from, for the info panel's Channel List tab (#1010): nil when there is none.
    private var channelChoices: ChannelChoices? {
        guard let lineup = store.lineup(for: channel) else { return nil }
        let store = store, channel = channel
        return ChannelChoices(key: "\(lineup.title):\(lineup.channels.count):\(channel.id)") {
            AnyView(TVPlayerChannelsPanel(channel: channel).environment(store))
        }
    }
    #endif

    #if !os(tvOS)
    #if os(macOS)
    private var chrome: some View {
        // One row when it fits: a long title truncates, and only when the buttons leave no room for any do they get
        // a row of their own. (One copy of each view: ViewThatFits with a candidate per title width built every glass
        // button many times over and stalled the main thread past the watchdog.) The iPhone and iPad player draws its
        // own (MobilePlayerView).
        ChromeRow { chromeTitle; chromeButtons; chromeClose }
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .top)
        .subtitleImport(files: $importsSubtitleFile, address: $asksSubtitleAddress, search: $searchesSubtitles, subtitles: session.externalSubtitles)
        .playerEpisodesSheet(isPresented: $showsEpisodes, channel: channel)
        .playerChannelsSheet(isPresented: $showsChannels, channel: channel, session: session)
        .sheet(isPresented: $showsDanmakuList) {
            DanmakuListView(player: session.player, comments: session.danmaku) { showsDanmakuList = false }
                .danmakuListPresentation()
        }
        .sheet(isPresented: $showsDanmakuSettings) {
            CatalogDanmakuSettingsView(model: session.catalogDanmaku, channelName: channel.name).playerSheet()
        }
    }

    private var chromeTitle: some View {
        Text(channel.name).font(.headline).lineLimit(1)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .glassSurface(.regular, in: Capsule())
    }

    private var chromeButtons: some View {
        HStack(spacing: 2) {
            if let previous = store.step(back: true, from: channel, session: session) {
                Button { previous.go() } label: {
                    Image(systemName: "backward.end.fill").font(.headline).frame(width: 22, height: 22)
                }
                .chromeButton()
                .disabled(previous.busy)
                .accessibilityLabel(previous.title(back: true)).help(previous.name)
            }
            if let next = store.step(back: false, from: channel, session: session) {
                Button { next.go() } label: {
                    Image(systemName: "forward.end.fill").font(.headline).frame(width: 22, height: 22)
                }
                .chromeButton()
                .disabled(next.busy)
                .accessibilityLabel(next.title(back: false)).help(next.name)
            }
            PlayerEpisodesButton(channel: channel, isPresented: $showsEpisodes) {
                Image(systemName: PlayerEpisodesSheet.symbol).font(.headline).frame(width: 22, height: 22)
            }
            .chromeButton()
            PlayerChannelsButton(channel: channel, session: session, isPresented: $showsChannels) {
                Image(systemName: PlayerChannelsSheet.symbol).font(.headline).frame(width: 22, height: 22)
            }
            .chromeButton()
            CatalogPlaybackActions(channel: channel, session: session, openEpisodes: {
                #if os(iOS)
                watch?.openEpisodes() ?? { store.showsEpisodes = true }()
                #else
                store.showsEpisodes = true
                #endif
            })
            if session.qualities.count > 1 {
                Menu {
                    QualityPicker(session: session)
                } label: {
                    Image(systemName: "sparkles.tv").font(.headline).frame(width: 22, height: 22)
                }
                .chromeButton()
                .accessibilityLabel(L10n.text("Quality"))
            }
            // A file whose sound tracks AVKit's own menu can't offer (#428).
            if session.audioChoices.count > 1 {
                Menu {
                    Picker(L10n.text("Audio"), selection: Binding(get: { session.audioChoice }, set: { if let id = $0 { session.chooseAudio(id) } })) {
                        ForEach(session.audioChoices) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "speaker.wave.2").font(.headline).frame(width: 22, height: 22)
                }
                .chromeButton()
                .accessibilityLabel(L10n.text("Audio"))
            }
            // Subtitle files beside the video, or added now (#576); the item's own are in AVKit's menu.
            Menu {
                MacSubtitleFiles(subtitles: session.externalSubtitles, addFile: { importsSubtitleFile = true }, addAddress: { asksSubtitleAddress = true },
                                 searchOnline: { searchesSubtitles = true })
            } label: {
                Image(systemName: session.externalSubtitles.selected == nil ? "captions.bubble" : "captions.bubble.fill").font(.headline).frame(width: 22, height: 22)
            }
            .chromeButton()
            .accessibilityLabel(L10n.text("Subtitle Files"))
            // Settings stay reachable before comments load, including when automatic matching found none.
            Menu {
                Toggle(isOn: $showsDanmaku) { Label(L10n.text("Show Danmaku"), systemImage: "text.bubble") }
                Picker(selection: $danmakuArea) {
                    ForEach(DanmakuArea.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { Label(L10n.text("Danmaku Area"), systemImage: "rectangle.tophalf.inset.filled") }
                .pickerStyle(.menu)
                DanmakuStylePickers(model: session.catalogDanmaku)
                Button(L10n.text("Danmaku Settings…")) { showsDanmakuSettings = true }
                Button { showsDanmakuList = true } label: { Label(L10n.text("Danmaku List"), systemImage: "list.bullet.rectangle") }
                    .disabled(session.danmaku.isEmpty)
            } label: {
                Image(systemName: DanmakuPreference.symbol).font(.headline).frame(width: 22, height: 22)
            }
            .chromeButton()
            .accessibilityLabel(L10n.text("Danmaku"))
        }
        .chromeGroup(inset: 3)
    }

    private var chromeClose: some View {
        Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).frame(width: 22, height: 22) }
            .chromeButton()
            .accessibilityLabel(L10n.text("Close"))
            .accessibilityIdentifier("player.close")
            .keyboardShortcut(.cancelAction)
    }
    #endif

    private func poke() {
        #if os(iOS)
        quietStart = false
        #endif
        showsChrome = true
        scheduleHide()
    }

    /// Opening the player shows the controls for a moment, except at the top of a watch page, which plays by itself.
    /// Another episode taking over the open player (auto-play at the end of one, Next) leaves them as they were: still
    /// up for a viewer who just used them, and not over the picture each time an episode ends by itself (#875).
    private func showOnStart(opening: Bool = true) {
        #if os(iOS)
        if playerLayout == .inline, !UserDefaults.standard.bool(forKey: "qaPlayerControls") {
            hideTask?.cancel(); quietStart = true; showsChrome = false
            return
        }
        #endif
        if opening { poke() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        #if DEBUG
        // Keep screenshot/interaction QA stable while XCTest waits for AVKit to idle.
        if UserDefaults.standard.bool(forKey: "qaPlayerControls") { return }
        #endif
        #if os(iOS)
        // The controls stay while paused, and while VoiceOver runs, which can't reach controls that have faded out;
        // otherwise they leave about three seconds into playback.
        guard !session.paused, !UIAccessibility.isVoiceOverRunning else { return }
        let delay = 3.0
        #else
        let delay = 3.5
        #endif
        hideTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled { withAnimation(.smooth(duration: 0.3)) { showsChrome = false } }
        }
    }

    /// The episode sheet for this channel, seeded with the saved context so it
    /// reopens on the same line and the same episode at its saved position.
    ///
    /// Available on both platforms. The Mac used to have no way to open it at all: the transport
    /// menu asked its host to present the sheet and no host passed the closure, so "Episodes" was a
    /// button that did nothing, and the two-level episode menu it replaced was gone.
    private var episodePanel: some View {
        #if os(iOS)
        CatalogEpisodePanel(channel: channel, compact: playerLayout == .inline)
        #else
        CatalogEpisodePanel(channel: channel, compact: false)
        #endif
    }

    #if os(iOS)
    /// What to watch after the last episode: same source, same show first.
    @ViewBuilder private var endScreenContent: some View {
        if let end = store.seriesEnd {
            SeriesEndScreen(
                finishedTitle: end.title,
                suggestions: end.suggestions,
                autoPlayNext: store.autoPlayNext,
                replay: {
                    store.dismissSeriesEnd()
                    // Restart through the shared setup, not `session.start`, so the play-on/advance
                    // closures are reattached and replaying the series keeps auto-playing to the end.
                    startCatalogPlayback(session, channel: end.channel, store: store)
                },
                choose: { store.playSeriesSuggestion($0) },
                dismiss: { store.dismissSeriesEnd() }
            )
        }
    }

    private var playerLayout: MobilePlayerLayout {
        guard let watch else { return .screen }
        return watch.fullScreen ? .pageFullScreen : .inline
    }

    /// Back: closes the player, or on a watch page leaves the page — back to the main interface, where
    /// the video keeps playing in the mini player. Full Screen is shrunk with its own toggle button.
    private func exit() {
        guard let watch else { return dismiss() }
        watch.leave()
    }

    /// Float in-app: back to the main interface while the video keeps playing in the mini player.
    /// Unlike `exit`, this leaves the watch page even from Full Screen (its own toggle button still
    /// shrinks back to the page), and closes the full-screen cover when there is no watch page.
    private func miniplayer() {
        // [mi3s] 二开：缩成小窗**唯一**的正当入口（原版播放器 / 全屏播放器那一侧）。
        //
        // 上一版这里写的是 `store.miniPlayerActive = true` —— 那套只有一个全局布尔 +
        // 一个 `store.playing`，只能挂一个小窗。现在坞是真源（要求 5）：
        // `miniPlayerActive` 已是坞的只读投影，赋值 true 是空操作，必须显式登记。
        // `dockForeground()` 会把这**一集**放进坞并摘掉前台槽，坞里别的卡片不受影响。
        store.dockForeground()
        // 有观看页时由页面自己 pop；没有（全屏播放器）就关掉这一层覆盖。
        guard let watch else { return dismiss() }
        watch.leave()
    }

    /// Full Screen turns the phone for a picture wider than tall; a portrait video fills the screen upright.
    private func toggleFullScreen() {
        let size = session.player.currentItem?.presentationSize ?? .zero
        watch?.toggleFullScreen(size.height == 0 || size.width >= size.height)
        poke()
    }

    /// A tap on the picture shows the controls, or hides them at once.
    private func toggleChrome() {
        #if DEBUG
        // UI tests tap the picture to reach the controls, which `-qaPlayerControls` keeps up.
        if UserDefaults.standard.bool(forKey: "qaPlayerControls") { return poke() }
        #endif
        guard showsChrome, !quietStart else { return poke() }
        hideTask?.cancel()
        withAnimation(.smooth(duration: 0.25)) { showsChrome = false }
    }

    /// The seek bar is held: the controls stay until it is let go, then count down again.
    private func holdChrome(_ holding: Bool) {
        if holding { showsChrome = true; hideTask?.cancel() } else { scheduleHide() }
    }
    #endif
    #else
    private func poke() {}
    private func showOnStart(opening: Bool = true) {}
    #endif

    @ViewBuilder private var status: some View {
        if let error = session.error {
            #if os(tvOS)
            TVPlaybackFailureView(channelName: channel.name, details: error, symbol: session.errorSymbol, backdrop: waitContent,
                                  retry: { startCatalogPlayback(session, channel: channel, store: store) }, goBack: { dismiss() })
            #elseif os(iOS)
            if playerLayout == .inline {
                // At the top of a watch page: the same words, small, and Try Again; the page has Back.
                VStack(spacing: 8) {
                    Label(L10n.text("Can't play this right now"), systemImage: session.errorSymbol).font(.headline)
                    Text(error).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                        .multilineTextAlignment(.center)
                    Button { startCatalogPlayback(session, channel: channel, store: store) } label: {
                        Label(L10n.text("Try Again"), systemImage: "arrow.clockwise")
                    }
                    .controlButton(prominent: true).tint(Brand.accent).controlSize(.small).padding(.top, 2)
                }
                .foregroundStyle(.white).padding(.horizontal, 24).padding(.top, 36)
                .environment(\.colorScheme, .dark)
            } else {
                // A pause, not an alarm: the artwork stays behind (see waitContent), the words are kind, and the next step is clear.
                VStack(spacing: 0) {
                    Image(systemName: session.errorSymbol)
                        .font(.system(size: 58, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                        .breathingSymbol()
                        .shadow(color: .white.opacity(0.22), radius: 26)
                        .frame(height: 70)
                        .accessibilityHidden(true)
                    Text(L10n.text("Can't play this right now")).font(.title2.weight(.semibold)).padding(.top, 24)
                    Text(error).font(.callout).foregroundStyle(.white.opacity(0.7)).lineSpacing(2)
                        .multilineTextAlignment(.center).frame(maxWidth: 330).padding(.top, 10)
                    GlassGroup(spacing: 12) {
                        // A dead link's first remedy is another line, so that is the primary action
                        // when the video has lines to switch; Try Again stays the fallback.
                        HStack(spacing: 12) {
                            if channel.historyContext != nil {
                                Button { store.showsEpisodes = true } label: {
                                    Label(L10n.text("Switch Line"), systemImage: "list.bullet.rectangle")
                                }
                                .controlButton(prominent: true).tint(Brand.accent)
                            }
                            Button { startCatalogPlayback(session, channel: channel, store: store) } label: {
                                Label(L10n.text("Try Again"), systemImage: "arrow.clockwise")
                            }
                            .controlButton(prominent: channel.historyContext == nil).tint(Brand.accent)
                            Button { exit() } label: { Label(L10n.text("Close"), systemImage: "xmark") }.controlButton()
                        }
                    }
                    .controlSize(.large).padding(.top, 30)
                }
                .foregroundStyle(.white)
                .padding(32)
                .environment(\.colorScheme, .dark)
            }
            #else
            ErrorState(title: L10n.text("Can't play this right now"), message: error, details: "", symbol: session.errorSymbol,
                       retry: { startCatalogPlayback(session, channel: channel, store: store) }, goBack: { dismiss() }, backTitle: L10n.text("Close"))
                .padding(30).frame(maxWidth: 480)
                .glassSurface(.regular, in: RoundedRectangle(cornerRadius: 30, style: .continuous)).padding(30)
            #endif
        } else if session.loading || session.buffering {
            #if os(macOS)
            // Top of the frame, clear of the transport bar. Seeks stall briefly; only longer waits show.
            LoadingCard(appearAfter: session.loading ? 0 : 1.5, maxWidth: LoadingCard.compact) { session.loadingProgress }
                .padding(.horizontal, 24).padding(.top, 48)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
            #endif
        }
    }

    private var waitContent: PlaybackWaitContent? {
        #if os(tvOS)
        .make(session, channel: channel, store: store, linesHint: false)
        #else
        .make(session, channel: channel, store: store, linesHint: true)
        #endif
    }
}


extension PlaybackWaitContent {
    /// The wait drawn under a player's controls: the artwork while the episode first loads (and behind
    /// an error), the words alone when playback stalls. `linesHint` where the player has the ⋯ menu.
    static func make(_ session: PlaybackSession, channel: Channel, store: Store, linesHint: Bool) -> PlaybackWaitContent? {
        let starting = session.loading || session.error != nil || !session.showsPicture
        guard starting || session.buffering else { return nil }
        let catalog = store.catalog(for: channel)
        let artwork = PlaybackArtwork(poster: catalog?.video.poster ?? channel.historyContext?.poster,
                                      headers: catalog?.video.posterHeaders ?? channel.historyContext?.posterHeaders ?? [:])
        let resume = channel.resumePosition, hint = linesHint && catalog != nil
        // Until the first frame, the wait runs from the episode's start, so a wait view made again (the Mac's player view is
        // remade as the video gets ready) carries on where it was rather than starting over.
        let since = starting && !session.showsPicture ? session.openedAt : nil
        return PlaybackWaitContent(artwork: artwork, starting: starting, showsWords: session.error == nil, appearAfter: starting ? 0.6 : 1.5,
                                   since: since) { [session] elapsed in
            session.wait(elapsed: elapsed, resume: resume, linesHint: hint)
        }
    }
}

#if !os(tvOS)
/// The player's title bar: the title, the buttons and Close share one row, the title truncating to leave the others
/// their width; when that would leave the title less than `minimumTitle`, the buttons and Close take a row of their
/// own, right-aligned.
private struct ChromeRow: SwiftUI.Layout {
    var spacing: CGFloat = 12
    var rowSpacing: CGFloat = 10
    /// Between the buttons and Close, as between the buttons themselves.
    var buttonSpacing: CGFloat = 10
    var minimumTitle: CGFloat = 110

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let buttons = subviews[1].sizeThatFits(.unspecified), close = subviews[2].sizeThatFits(.unspecified)
        let tail = tailSize(buttons, close)
        let width = proposal.width ?? subviews[0].sizeThatFits(.unspecified).width + spacing + tail.width
        if let room = titleRoom(width, tail: tail) {
            let title = subviews[0].sizeThatFits(ProposedViewSize(width: room, height: nil))
            return CGSize(width: width, height: max(title.height, tail.height))
        }
        let title = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: title.height + rowSpacing + tail.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let buttons = subviews[1].sizeThatFits(.unspecified), close = subviews[2].sizeThatFits(.unspecified)
        let tail = tailSize(buttons, close)
        if let room = titleRoom(bounds.width, tail: tail) {
            let title = subviews[0].sizeThatFits(ProposedViewSize(width: room, height: nil))
            let row = max(title.height, tail.height)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + (row - title.height) / 2), proposal: ProposedViewSize(width: room, height: title.height))
            placeTail(buttons, close, right: bounds.maxX, middle: bounds.minY + row / 2, subviews)
            return
        }
        let title = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: title.height))
        placeTail(buttons, close, right: bounds.maxX, middle: bounds.minY + title.height + rowSpacing + tail.height / 2, subviews)
    }

    /// The buttons and Close side by side.
    private func tailSize(_ buttons: CGSize, _ close: CGSize) -> CGSize {
        CGSize(width: buttons.width + (buttons.width > 0 ? buttonSpacing : 0) + close.width, height: max(buttons.height, close.height))
    }

    private func placeTail(_ buttons: CGSize, _ close: CGSize, right: CGFloat, middle: CGFloat, _ subviews: LayoutSubviews) {
        subviews[2].place(at: CGPoint(x: right - close.width, y: middle - close.height / 2), proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: right - close.width - buttonSpacing - buttons.width, y: middle - buttons.height / 2), proposal: .unspecified)
    }

    private func titleRoom(_ width: CGFloat, tail: CGSize) -> CGFloat? {
        let room = width - tail.width - spacing
        return room >= minimumTitle ? room : nil
    }
}
#endif

#if os(tvOS)
private struct TVPlaybackFailureView: View {
    let channelName: String
    let details: String
    var symbol = "play.slash.fill"
    /// The episode's colours behind the message, as on iPhone; the plain background when there is no artwork.
    var backdrop: PlaybackWaitContent? = nil
    let retry: () -> Void
    let goBack: () -> Void
    @State private var showsDetails = false
    @FocusState private var retryFocused: Bool

    var body: some View {
        ZStack {
            if let backdrop { backdrop.view } else { TVStyle.background.ignoresSafeArea() }
            VStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 96, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .breathingSymbol()
                    .shadow(color: .white.opacity(0.2), radius: 40)
                    .frame(height: 120)
                    .accessibilityHidden(true)
                    .padding(.bottom, 40)
                Text(L10n.text("Can't play this right now"))
                    .font(.system(size: 56, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 18)
                Text(channelName)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color(white: 0.85)).lineLimit(2)
                    .padding(.bottom, 16)
                Text(L10n.text("Try again, or go back and choose another video."))
                    .font(.system(size: 27)).foregroundStyle(Color(white: 0.65))
                    .fixedSize(horizontal: false, vertical: true)
                // Liquid Glass, as every other control on Apple TV: clear at rest, white on focus.
                GlassGroup(spacing: 20) {
                    HStack(spacing: 20) {
                        Button(action: retry) { Label(L10n.text("Try Again"), systemImage: "arrow.clockwise") }.focused($retryFocused)
                        Button(action: goBack) { Label(L10n.text("Go back"), systemImage: "chevron.backward") }
                        Button { showsDetails.toggle() } label: { Label(L10n.text(showsDetails ? "Hide details" : "Show details"), systemImage: "info.circle") }
                    }
                    .controlButton()
                }
                .padding(.top, 48)
                if showsDetails {
                    ScrollView {
                        Text(details)
                            .font(.system(size: 23))
                            .foregroundStyle(Color(white: 0.65))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxHeight: 150)
                    .padding(.top, 32)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 1120)
            .padding(64)
        }
        .onAppear { retryFocused = true }
        .onExitCommand(perform: goBack)
    }
}
#endif

#if os(macOS)
private struct NativePlayerView: View {
    let player: AVPlayer
    let comments: [Danmaku]
    @Binding var showsDanmaku: Bool
    var opacity = 0.9
    var revision = ""
    var body: some View {
        ZStack {
            PlayerSurface(player: player)
            if showsDanmaku && !comments.isEmpty { DanmakuOverlay(player: player, comments: comments, opacity: opacity, revision: revision).ignoresSafeArea() }
        }
    }
}
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}
#elseif os(iOS)
/// The iPhone player's rotate button. While it holds landscape the app allows landscape only, so the phone
/// held upright (or Portrait Orientation Lock) doesn't turn it back; the button or closing the player does.
@MainActor enum PlayerOrientation {
    static private(set) var mask: UIInterfaceOrientationMask = .allButUpsideDown
    static var available: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    /// An iPhone watch page is on screen: it stays upright, and only its Full Screen turns the phone.
    static private var holdsPortrait = false
    /// The viewer locked the controls: the app stays in exactly one orientation and the gyroscope can't move it.
    static private(set) var isLocked = false
    /// 锁定那一刻的横竖。由 `lock()` 写入，版面层在收到 `lockStateDidChange` 时读它，
    /// 而不是自己去读 `window.bounds`（那是连续量，会读到转向动画的中间帧）。
    static private(set) var lockedLandscape = false

    /// The scene's current orientation, or nil when there is none to read.
    static var currentOrientation: UIInterfaceOrientation? {
        UIApplication.shared.appWindowScene?.interfaceOrientation
    }

    /// A single orientation as a mask, for pinning the app to it.
    private static func singleMask(_ orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: .allButUpsideDown
        }
    }

    /// 进出全屏。**全屏的方向只由它决定**，不再掺杂页面习惯（`holdsPortrait`）。
    ///
    /// 这是「全屏机制没有独立做好」的正面修法：
    ///   · 进全屏 → 打开 `fullScreenOwnsOrientation`，此后一切 `holdPortrait` 写入被丢弃；
    ///     mask 直接取请求的方向，`holdsPortrait` 不参与计算。
    ///   · 退全屏 → 关掉闸门，并把方向交还给页面习惯（`holdsPortrait` 此刻反映
    ///     的仍是进全屏之前的页面规则，因为全屏期间没人能改写它）。
    static func set(landscape: Bool, fullScreen: Bool? = nil) {
        guard let scene = UIApplication.shared.appWindowScene else { return }
        // 调用方显式告知这是全屏切换时，先同步闸门状态。
        if let fullScreen { fullScreenOwnsOrientation = fullScreen }

        // A locked player stays put whatever the rotate button or a full-screen toggle asks.
        if !isLocked {
            // ★ 全屏态：**不看 `holdsPortrait`**，而且**横竖两侧都要钉住**。
            //
            // 原来竖的那一侧写的是 `.allButUpsideDown`（= 放开不管）：
            //   · `mask` 放开后，陀螺仪可以在全屏里把画面翻走；
            //   · `geometry` 放开后，`requestGeometryUpdate(.allButUpsideDown)` 只是
            //     「除倒置外都行」，**落点是系统按物理握持自己挑的** ——
            //     用户横着拿手机点「旋转到竖屏」时，系统照样挑 landscape。
            // 表现就是「全屏只能横着，转不回竖」；反之从竖屏进全屏后也守不住。
            // 用户明确要求「全屏也要能横屏也能竖屏」，所以两侧对称地钉当前方向。
            // 横的一侧本来就已经钉成 `.landscape`，这里只是把竖的一侧补齐。
            if fullScreenOwnsOrientation {
                mask = landscape ? .landscape : .portrait
            } else {
                mask = landscape ? .landscape : holdsPortrait ? .portrait : .allButUpsideDown
            }
        }
        // A lock must also stop the geometry request that actually turns the screen: `requestGeometryUpdate`
        // asks the scene to rotate to a specific orientation and does not consult `mask`, so passing the
        // requested `landscape` here turned the phone even while locked (the gyroscope "lock" that let the
        // film flip when the viewer changed their grip). While locked, keep the orientation it was pinned in.
        //
        // 全屏态下 `landscape == false` 也必须显式请求 `.portrait`：
        // 传 `.allButUpsideDown` 等于「你随便挑」，系统会按物理朝向留在横屏，
        // 用户点的「转到竖屏」就像没生效。
        let geometry: UIInterfaceOrientationMask = isLocked
            ? mask
            : (landscape ? .landscape : .portrait)
        // 进 / 退全屏是用户显式点的，必须立刻转过去 → turn: true。
        apply(mask, scene: scene, geometry: geometry, turn: true)
    }

    /// Pins the app to the viewer's current orientation; the gyroscope can no longer turn the picture.
    static func lock() {
        guard let scene = UIApplication.shared.appWindowScene else { return }
        // The full-screen player never asked for device-orientation notifications (only the watch page
        // does), so `UIDevice.current.orientation` would otherwise read `.unknown` or a stale value and
        // `lockPin` would pin the wrong way. Start them before the pin reads the physical grip.
        //
        // ⛔ 必须与 `unlock()` 里的 `endGenerating…` 配对。
        //
        // 这两句原本只有 begin、全仓没有一处 end：锁一次之后整个进程**永久**在采样
        // 加速度计/陀螺仪，直到 App 被杀。用户的要求正好相反 ——
        // 「锁屏防误触模式下屏蔽握持态陀螺仪感应」。
        // 采样不停就意味着「设备朝向一直被读」，而锁定存在的意义恰恰是不再理会握持。
        // 现在：只在 `lock()` 读一次物理握持（pin 的那一下确实需要），`unlock()` 立刻停表。
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        isLocked = true
        // The grip the phone is physically held in is what "this orientation" means to a viewer, and it
        // is not fooled by the `requestGeometryUpdate` turn still settling. On an unfolded Duo, for
        // example, `turn(to: landscape)` has only *asked* the interface to rotate, so `interfaceOrientation`
        // still reports portrait for a beat — locking off that pins portrait and the film flips upright the
        // moment the grip changes, exactly the bug a lock exists to stop. Only when the device is flat or
        // still settling (no sideways grip to honour) does the lock fall back to the interface direction.
        mask = singleMask(lockPin)
        // 点「锁定」是用户意图，要把画面钉到当前朝向 → turn: true。
        apply(mask, scene: scene, geometry: mask, turn: true)
        // pin 已经完成，握持采样到此为止 —— 之后无论设备怎么转都不再读它。
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        // 广播给版面层：锁定后要冻结横竖判定（见 `VideoDetailView.sideways`）。
        // 内屏不遵守方向掩码，所以「不再理会握持」是内屏上唯一能兑现的防误触手段，
        // 而它需要版面层知道「现在锁了」。
        //
        // ⛔ 随广播**带上锁定这一刻的横竖**（`lockedLandscape`）。
        //
        // 原来的做法是让版面层在 `onChange` 里现读 `landscapeScreen`，但那读的是
        // `window.bounds` —— 一个**连续量**。点「锁定」会先 `apply(turn: true)` 请求转向，
        // 下一帧读到的是转向动画的中间帧（669×951 → 951×669 途中约 810×810，
        // 宽高比 1.0 ≤ portraitEnter 1.15）→ 判成横持 → **冻结值写反且永久保留**。
        // 在 lock() 内部取快照就没有这个窗口：此刻 `mask` 已定，横竖就是这次锁定的意图。
        lockedLandscape = mask == .landscape
        NotificationCenter.default.post(name: PlayerOrientation.lockStateDidChange, object: nil)
    }

    /// 锁定状态变化广播。版面层据此冻结/恢复横竖判定。
    static let lockStateDidChange = Notification.Name("PlayerOrientation.lockStateDidChange")

    /// The single orientation a lock should pin: the physical grip first, the interface direction as a
    /// fallback when the device is flat or mid-turn. `.unknown` / `.faceUp` / `.faceDown` are not real
    /// directions to hold, so they are dropped.
    private static var lockPin: UIInterfaceOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        case .portrait: return .portrait
        default:
            return currentOrientation.flatMap(Self.lockable) ?? .portrait
        }
    }

    /// The orientation a lock should pin. `.unknown` / `.faceUp` / `.faceDown` are not real directions
    /// to hold, so they are dropped in favour of the device's physical tilt.
    private static func lockable(_ orientation: UIInterfaceOrientation) -> UIInterfaceOrientation? {
        switch orientation {
        case .portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight: return orientation
        default: return nil
        }
    }

    /// Lets the gyroscope turn the picture again.
    static func unlock() {
        guard isLocked else { return }
        isLocked = false
        mask = holdsPortrait ? .portrait : .allButUpsideDown
        guard let scene = UIApplication.shared.appWindowScene else { return }
        // 解锁只是「放开限制」，不该改变当前朝向 → turn: false。
        apply(mask, scene: scene, geometry: mask, turn: false)
        // 解锁 → 版面层解除冻结，立刻回到跟随真实空间。
        NotificationCenter.default.post(name: PlayerOrientation.lockStateDidChange, object: nil)
    }

    /// Turns the picture to a chosen orientation by hand; the controls follow. A locked player stays
    /// put — "lock" means the orientation is pinned, so the rotate button must not slip past it.
    static func rotate(to orientation: UIInterfaceOrientation) {
        guard !isLocked, let scene = UIApplication.shared.appWindowScene else { return }
        let single = singleMask(orientation)
        mask = single
        // 点旋转键是用户意图 → turn: true。
        apply(single, scene: scene, geometry: single, turn: true)
    }

    /// Turns the picture to an orientation once, without pinning it there: the supported-orientation
    /// mask is untouched, so the gyroscope keeps following the device afterwards. This is the "unfold
    /// into landscape by default" behaviour — the Duo's inner display opens sideways, but the viewer can
    /// still turn it upright, unlike `rotate(to:)` which holds it. Locked players ignore it entirely.
    static func turn(to orientation: UIInterfaceOrientation) {
        guard !isLocked, let scene = UIApplication.shared.appWindowScene else { return }
        let single = singleMask(orientation)
        // 这个方法名字就是「转一次」，是显式意图 → turn: true。
        apply(mask, scene: scene, geometry: single, turn: true)
    }

    /// 声明方向的唯一出口。`turn` 决定这次要不要**主动请求**系统转过去。
    ///
    /// ## 为什么必须把「声明」和「请求」分开（旋转来回弹的根因）
    ///
    /// One 1.7.0 的做法（`One_1.7.0` 静态实证）：
    ///   · `One.AppDelegate` 只实现 **一个** 方向回调
    ///     `application:supportedInterfaceOrientationsForWindow:`，返回固定 mask；
    ///   · 全二进制**没有任何一处**调用 `requestGeometryUpdateWithPreferences:`
    ///     （`nm` 零命中，只有一个 selref 字符串，且没有类实现它）。
    ///   ⇒ One 只**声明允许哪些方向**，从不命令系统往哪转。转不转由设备和系统决定。
    ///
    /// 我们此前每发生一次形态变化（折叠 / 展开 / 进全屏 / 退全屏）都调一次
    /// `requestGeometryUpdate(.iOS(interfaceOrientations:))` —— 那是**命令**系统转。
    /// 在 Duo 上这会形成自激环：
    ///   1. 折叠 → 页面按 `duoExpanded` 写 `holdPortrait(true)` → 我们命令「转竖屏」；
    ///   2. 系统转完，几何回调触发 → 又读到方向变了 → 再写一次；
    ///   3. 展开 → 写 `holdPortrait(false)` → 命令「转横屏」；
    ///   4. 系统转完又触发几何回调 …
    /// 用户看到的就是**转过去又转回来**。One 不做这件事，所以它不会弹。
    ///
    /// 现在：默认只 `setNeedsUpdateOfSupportedInterfaceOrientations()` 让系统按新 mask
    /// 重算（设备物理朝向决定落点），只有**用户显式点旋转键 / 进全屏**才 `turn: true`
    /// 真去命令系统转 —— 那是用户意图，必须立刻生效。
    private static func apply(_ mask: UIInterfaceOrientationMask,
                              scene: UIWindowScene,
                              geometry: UIInterfaceOrientationMask,
                              turn: Bool) {
        var controller = scene.keyWindow?.rootViewController
        while let next = controller?.presentedViewController { controller = next }
        controller?.setNeedsUpdateOfSupportedInterfaceOrientations()
        // 只声明、不命令：系统按设备物理朝向落在 mask 允许的那个方向上。
        // 这一步是 Duo 上唯一正确的日常路径 —— 折叠/展开不改变设备朝向，
        // 所以重算 mask 之后落点不变，不会出现「转过去又转回来」。
        guard turn else { return }
        // UIKit calls the error handler on a background queue. @Sendable keeps it off the main actor;
        // without it Swift 6 checks the closure's main-actor isolation at entry and traps (issue #247).
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: geometry)) { @Sendable error in
            Diagnostics.shared.record(.warning, "player", "Rotation refused: \(error.localizedDescription)")
        }
    }

    /// Back to portrait when the player closes, if the button turned it.
    ///
    /// The portrait hold is cleared too. It is set by the watch page, and the page only clears it
    /// when it disappears while folded shut — closing the player on an unfolded Duo, or leaving the
    /// page from Full Screen, left the whole app pinned upright for the rest of the session.
    static func release() {
        // ⛔ 必须先记下「本来锁着没有」再清。
        //
        // `PlaybackView.onDisappear` **无条件**调本函数，而折叠/展开会拆掉 PlaybackView ——
        // 于是「锁定 → 合盖」这条路上锁会被静默清掉。上一版这里不发广播，
        // 版面层的 `lockedForShape` 仍为 true、冻结值仍在 ⇒
        // **控件显示未锁定、方向真的未锁、但版面永久冻结**，用户只能退页重建。
        // （并行审查的子代理第 2 项抓到的死锁：此后点锁钮走的是 lock()，
        //  即便走到 unlock() 也有 `guard isLocked else { return }` 早退，广播永远不发。）
        let wasLocked = isLocked
        isLocked = false
        holdsPortrait = false
        if mask == .landscape { set(landscape: false) }
        // 锁状态真的变了才广播 —— 无条件发会让每次离开播放页都触发一次版面重算。
        if wasLocked {
            NotificationCenter.default.post(name: PlayerOrientation.lockStateDidChange, object: nil)
        }
    }

    /// iPhone Duo 折叠/展开时的方向承接。
    ///
    /// ⛔ 这两个函数现在**什么都不做**，这是有意的。
    ///
    /// 旧语义建立在「外屏默认横屏、内屏忽略方向」这个假设上：
    ///   · `suspend()`：展开到内屏时把横屏锁降回竖屏；
    ///   · `restore()`：折回外屏时按 `holdsPortrait` 重新把外屏设成横屏。
    /// 但用户明确要求「外屏要能横屏也能竖屏」，而 `suspend()` 恰恰会在**展开**那一刻
    /// 把用户刚设好的横屏锁抹掉（`if mask == .landscape { set(landscape: false) }`），
    /// `restore()` 又会按页面习惯强推一个方向 —— 两者都在替用户决定方向。
    ///
    /// 折叠/展开不改变物理握持，方向就该跟着握持走，不需要页面插一手。
    /// 保留空实现（而不是删掉调用点）是为了让调用方语义清楚：
    /// 「这里曾经有个方向策略，现在它被取消了」。
    static func suspend() {}

    /// 见 `suspend()`：折回外屏不再强推任何方向。
    static func restore() {}

    /// Full Screen 进行中：**任何人都不得改写方向锁**。
    ///
    /// 这一步修的是「竖屏点全屏 → 试一下横屏 → 又弹回竖屏」。
    /// 链条：全屏按钮 → `set(landscape: true)` → `apply(.landscape)` 开始转 →
    /// 转屏过程中 `duoExpanded` / sizeClass 变化 → `VideoDetailView` 的
    /// `.onChange(of: duoExpanded)` 里又调 `holdPortrait(!expanded)` →
    /// 它内部 `apply(geometry: .portrait)` 把界面**转回去**。
    ///
    /// 全屏是用户显式点的，它的方向必须只由全屏按钮自己决定；
    /// 页面「习惯竖屏」这条规则只在**非全屏**时才有意义。
    /// 退出全屏后 `setFullScreen` 会重新走一次 `set(landscape:)`，
    /// 那时再按页面习惯恢复，不会留下错误的锁。
    static private(set) var fullScreenOwnsOrientation = false
    /// 进入/退出全屏时同步闸门。退出时**不做任何方向请求** ——
    /// 页面自己的 `holdPortrait` / `set(landscape:)` 会在下一帧按需恢复，
    /// 这里多插一手只会又变成两套状态打架。
    static func setFullScreenHeld(_ held: Bool) {
        fullScreenOwnsOrientation = held
    }

    /// While a watch page shows, the app stays upright (the page turns to landscape for Full Screen only).
    static func holdPortrait(_ hold: Bool) {
        // ★ 全屏期间忽略一切「页面习惯方向」的写入（见 `fullScreenOwnsOrientation`）。
        guard !fullScreenOwnsOrientation else { return }
        guard holdsPortrait != hold else { return }
        holdsPortrait = hold
        guard !isLocked else { return }
        mask = hold ? .portrait : .allButUpsideDown
        guard let scene = UIApplication.shared.appWindowScene else { return }
        // ⛔ `turn: false` —— 这里是「转过去又转回来」的头号元凶。
        //
        // `holdPortrait` 由页面在**形态变化**时调用（`onChange(of: duoExpanded)` 等）。
        // 以前它走 `apply(..., geometry:)` → `requestGeometryUpdate`，等于每次折叠/展开
        // 都命令系统转一次；系统转完几何回调又触发下一次写入，形成自激环。
        // 折叠/展开并不改变设备物理朝向，所以正确做法只是**改 mask 允许集**，
        // 让系统按物理朝向自然落位（One 就是这么做的：只声明，从不 request）。
        // 用户手上的旋转键与全屏按钮仍然走 `turn: true`，那是显式意图。
        apply(mask, scene: scene, geometry: hold ? .portrait : .allButUpsideDown, turn: false)
    }
}
#else
/// Full screen inside a SwiftUI view that ignores the safe area, the controller is told it has none,
/// and AVKit then lays its bottom controls into the TV's overscan margin, where focus effects are cut
/// off. This restores the title-safe area for the controls; the video and its overlays still fill the screen.
private final class TitleSafePlayerController: AVPlayerViewController {
    private static let titleSafe = UIEdgeInsets(top: 60, left: 80, bottom: 60, right: 80)
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let given = view.safeAreaInsets, extra = additionalSafeAreaInsets
        let wanted = UIEdgeInsets(top: max(0, Self.titleSafe.top - (given.top - extra.top)), left: max(0, Self.titleSafe.left - (given.left - extra.left)),
                                  bottom: max(0, Self.titleSafe.bottom - (given.bottom - extra.bottom)), right: max(0, Self.titleSafe.right - (given.right - extra.right)))
        if wanted != extra { additionalSafeAreaInsets = wanted }
    }
}

struct EpisodeAction {
    let name: String
    let busy: Bool
    /// A live channel of the list it was picked from (#1010).
    var channel = false
    let play: @MainActor () -> Void
}

/// A catalog video's episodes by line, for the transport bar's Episodes menu and the info panel's Episodes tab.
struct EpisodeChoices {
    /// Changes when the video or its episodes do: the info panel's tab is made again then.
    let key: String
    let lines: [(flag: String, episodes: [Episode])]
    let labels: [Episode.ID: String]
    let current: Episode.ID?
    let busy: Bool
    let select: @MainActor (Episode) -> Void
    let panel: @MainActor () -> AnyView
}

/// The list a live channel was picked from, as the info panel's Channel List tab (#1010). `key` changes when the
/// tab is made again.
struct ChannelChoices {
    let key: String
    let panel: @MainActor () -> AnyView
}

/// AVPlayerViewController itself, for its transport-bar menu: the Danmaku switch lives there, next to
/// subtitles and audio, where a remote can reach it. Comments draw in the content overlay, under the controls.
private struct NativePlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    let comments: [Danmaku]
    @Binding var showsDanmaku: Bool
    var opacity = 0.9
    var revision = ""
    var qualities: [StreamQuality] = []
    var quality: Int? = nil
    var choose: @MainActor (Int?) -> Void = { _ in }
    /// The sound tracks AVKit's own Audio menu can't offer (`PlaybackSession.audioChoices`), and the one playing.
    var audio: [UngroupedAudio.Choice] = []
    var audioChoice: CMPersistentTrackID? = nil
    var chooseAudio: @MainActor (CMPersistentTrackID) -> Void = { _ in }
    var live = false
    /// The neighbouring episodes of a catalog video, as transport-bar buttons beside the menus.
    var previous: EpisodeAction? = nil
    var next: EpisodeAction? = nil
    var waiting: PlaybackWaitContent? = nil
    var enhancer: VideoEnhancer? = nil
    var upscale: Binding<Bool> = .constant(false)
    var smooth: Binding<Bool> = .constant(false)
    var info: Binding<Bool> = .constant(false)
    // [mi3s] 二开融合（上游 1.8.11）：播放倍速、铺满屏幕、弹幕区域。
    /// The speed picked in the Playback Speed menu, which `setSpeed` makes the player's default rate.
    var speed: Float = 1
    var setSpeed: @MainActor (Float) -> Void = { _ in }
    /// Fill Screen: the picture is cropped to the whole screen rather than fitted inside it, as on iPhone.
    var fills: Binding<Bool> = .constant(false)
    var danmakuArea: Binding<DanmakuArea> = .constant(.standard)
    /// The danmaku look from Settings › Danmaku, which the transport bar's Danmaku menu sets too (#789).
    @AppStorage(DanmakuStyle.fontSizeKey) private var danmakuFontSize = DanmakuStyle.standardFontSize
    @AppStorage(DanmakuStyle.opacityKey) private var danmakuOpacity = DanmakuStyle.standardOpacity
    @AppStorage(DanmakuStyle.speedKey) private var danmakuSpeed = DanmakuStyle.standardSpeed
    /// Subtitle files beside the video (#576); the item's own are in AVKit's Subtitles menu.
    var external: ExternalSubtitles? = nil
    /// The source's opening or ending credits playing now, offered as AVKit's Skip button (#256).
    var skip: PlaybackSkip? = nil
    var skipSource: @MainActor () -> Void = {}
    /// The video's own intro and outro times, where it keeps any (#808): set from the menu at the place playing.
    var skipping: EpisodeSkipSettings? = nil
    var setSkipping: @MainActor (EpisodeSkipSettings) -> Void = { _ in }
    var markSkip: @MainActor (_ intro: Bool) -> Void = { _ in }
    /// The part's chapters (Bilibili's 分段章节): a Chapters tab in the info panel, beside Danmaku.
    var chapters: [PlaybackChapter] = []
    private static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]
    private static func speedLabel(_ speed: Float) -> String {
        Double(speed).formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
    /// Closes the player on Back until the picture starts. The overlay that takes focus for that loses it
    /// once the transport bar shows (an episode button takes it), and AVKit then keeps the press to itself.
    var exitWhileWaiting: (() -> Void)? = nil
    var episodes: EpisodeChoices? = nil
    var channels: ChannelChoices? = nil
    /// A live channel's lines, for the Lines menu (#679), and the one playing.
    var lines: [String] = []
    var line = 0
    var chooseLine: @MainActor (Int) -> Void = { _ in }
    /// Told when AVKit shows or hides the transport bar, for `titleRow`.
    var transportBar: TransportBarVisibility? = nil
    /// The title's logo and the video's tags, over the transport bar while it shows (#758).
    var titleRow: AnyView? = nil
    final class Coordinator: NSObject, UIGestureRecognizerDelegate, @preconcurrency AVPlayerViewControllerDelegate {
        var host: UIHostingController<AnyView>?; var listed = ""; var criteria: DisplayCriteriaKeeper?
        var exit: (() -> Void)?
        var subtitles: SubtitleCues?
        var transportBar: TransportBarVisibility?
        func playerViewController(_ controller: AVPlayerViewController, willTransitionToVisibilityOfTransportBar visible: Bool,
                                  with coordinator: AVPlayerViewControllerAnimationCoordinator) {
            transportBar?.visible = visible
        }
        // Picture in Picture shows only the player's own picture, so AVPlayer draws the subtitles there.
        func playerViewControllerWillStartPictureInPicture(_ controller: AVPlayerViewController) { subtitles?.native = true }
        func playerViewControllerDidStopPictureInPicture(_ controller: AVPlayerViewController) { subtitles?.native = false }
        let back = UITapGestureRecognizer()
        override init() {
            super.init()
            back.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
            back.delegate = self
            back.addTarget(self, action: #selector(pressedBack))
        }
        @objc private func pressedBack() { exit?() }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = TitleSafePlayerController()
        // [mi3s] One 皮肤把播放器塞进一个小窗口（不是全屏），
        // 但 AVPlayerViewController 会自己接管布局、忽略父级 frame，
        // 导致视频铺满整屏、小窗口约束失效。必须让宿主裁剪。
        controller.view.clipsToBounds = true
        controller.view.backgroundColor = .black
        // Decided before the controller is presented: AVKit refuses the change during playback.
        if VideoEnhancement.canSmooth, let enhancer { context.coordinator.criteria = DisplayCriteriaKeeper(controller: controller, player: player, enhancer: enhancer) }
        controller.player = player
        controller.delegate = context.coordinator
        context.coordinator.subtitles = subtitles
        context.coordinator.transportBar = transportBar
        let host = UIHostingController(rootView: overlay)
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        // Comments use the whole picture, not the TV's title-safe area.
        host.safeAreaRegions = []
        // The content overlay exists only once the controller's view has loaded.
        controller.loadViewIfNeeded()
        if let container = controller.contentOverlayView {
            controller.addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(host.view)
            NSLayoutConstraint.activate([host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                                         host.view.topAnchor.constraint(equalTo: container.topAnchor), host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
            host.didMove(toParent: controller)
        }
        context.coordinator.host = host
        controller.view.addGestureRecognizer(context.coordinator.back)
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        // Live has no timeline worth scrubbing: keep it at the live edge.
        if controller.requiresLinearPlayback != live { controller.requiresLinearPlayback = live }
        // [mi3s] 二开融合（上游 1.8.11）：Fill Screen 切换画面填充方式（裁切 vs 等比）。
        let gravity: AVLayerVideoGravity = fills.wrappedValue ? .resizeAspectFill : .resizeAspect
        if controller.videoGravity != gravity { controller.videoGravity = gravity }
        context.coordinator.host?.rootView = overlay
        context.coordinator.exit = exitWhileWaiting
        context.coordinator.back.isEnabled = exitWhileWaiting != nil
        // The episodes, the chapters and the comment list are tabs in the info panel (swipe down), beside the video's own info.
        let listed = "\(revision):\(comments.count):\(chapters.map(\.start)):\(episodes?.key ?? ""):\(channels?.key ?? "")"
        if context.coordinator.listed != listed {
            context.coordinator.listed = listed
            var tabs: [UIViewController] = []
            if let channels {
                let panel = UIHostingController(rootView: channels.panel())
                panel.title = L10n.text("Channel List")
                panel.sizingOptions = .preferredContentSize
                panel.safeAreaRegions = []
                tabs.append(panel)
            }
            if let episodes {
                let panel = UIHostingController(rootView: episodes.panel())
                panel.title = L10n.text("Episodes")
                // As tall as its content (one row of tiles, with or without the lines beside the title): a set height left
                // a band of empty panel under them.
                panel.sizingOptions = .preferredContentSize
                // No safe-area inset of its own: on an Apple TV the TV's inset pushed the strip down, leaving a gap
                // under the tabs and cutting off the episode titles at its foot.
                panel.safeAreaRegions = []
                tabs.append(panel)
            }
            // Chapters that are AVKit's own markers (PlaybackSession.mark) already have AVKit's Chapters tab; a second
            // one of ours listed them twice.
            if !chapters.isEmpty, player.currentItem?.navigationMarkerGroups.isEmpty ?? true {
                let list = UIHostingController(rootView: PlayerChaptersView(player: player, chapters: chapters))
                list.title = L10n.text("Chapters")
                list.preferredContentSize = CGSize(width: 0, height: 330)
                tabs.append(list)
            }
            if !comments.isEmpty {
                let list = UIHostingController(rootView: DanmakuListView(player: player, comments: comments))
                list.title = L10n.text("Danmaku")
                list.preferredContentSize = CGSize(width: 0, height: 480)
                controller.customInfoViewControllers = [list]
            }
        }
        let binding = $showsDanmaku
        var items: [UIMenuElement] = []
        if !comments.isEmpty {
            // [mi3s] 二开融合（上游 1.8.11）：弹幕开关升为二级菜单，并入「弹幕区域」。
            let area = danmakuArea
            let areas = DanmakuArea.allCases.map { option in
                UIAction(title: option.title, state: area.wrappedValue == option ? .on : .off) { _ in area.wrappedValue = option }
            }
            // Size, opacity and speed too: on a TV this menu is all a remote reaches while watching (#789).
            let fontSize = $danmakuFontSize, opacity = $danmakuOpacity, speed = $danmakuSpeed
            let sizes = DanmakuStyle.fontSizes(including: danmakuFontSize).map { option in
                UIAction(title: DanmakuStyle.sizeTitle(option), state: abs(option - danmakuFontSize) < 0.001 ? .on : .off) { _ in fontSize.wrappedValue = option }
            }
            let opacities = DanmakuStyle.opacities(including: danmakuOpacity).map { option in
                UIAction(title: DanmakuStyle.percent(option), state: abs(option - danmakuOpacity) < 0.001 ? .on : .off) { _ in opacity.wrappedValue = option }
            }
            let current = DanmakuStyle.clampedSpeed(danmakuSpeed)
            let speeds = DanmakuStyle.speeds(including: danmakuSpeed).map { option in
                UIAction(title: DanmakuStyle.speedTitle(option), state: abs(option - current) < 0.001 ? .on : .off) { _ in speed.wrappedValue = option }
            }
            items.append(UIMenu(title: L10n.text("Danmaku"), image: UIImage(systemName: DanmakuPreference.symbol), children: [
                UIAction(title: L10n.text("Show Danmaku"), state: showsDanmaku ? .on : .off) { _ in binding.wrappedValue.toggle() },
                UIMenu(title: L10n.text("Danmaku Area"), image: UIImage(systemName: "rectangle.tophalf.inset.filled"), children: areas),
                UIMenu(title: L10n.text("Text Size"), image: UIImage(systemName: "textformat.size"), children: sizes),
                UIMenu(title: L10n.text("Opacity"), image: UIImage(systemName: "circle.lefthalf.filled"), children: opacities),
                UIMenu(title: L10n.text("Scroll Speed"), image: UIImage(systemName: "speedometer"), children: speeds),
            ]))
        }
        if qualities.count > 1 {
            let choose = choose
            let current = qualities.first { $0.id == quality }?.label ?? L10n.text("Auto")
            let options = [UIAction(title: L10n.text("Auto"), state: quality == nil ? .on : .off) { _ in choose(nil) }]
                + qualities.map { option in UIAction(title: option.label, state: quality == option.id ? .on : .off) { _ in choose(option.id) } }
            items.append(UIMenu(title: L10n.text("Quality") + " · " + current, image: UIImage(systemName: "sparkles.tv"), children: options))
        }
        if audio.count > 1 {
            let chooseAudio = chooseAudio
            let options = audio.map { option in UIAction(title: option.name, state: option.id == audioChoice ? .on : .off) { _ in chooseAudio(option.id) } }
            items.append(UIMenu(title: L10n.text("Audio"), image: UIImage(systemName: "speaker.wave.2"), children: options))
        }
        // [mi3s] 二开融合（上游 1.8.11）：直播没有倍速的意义，只在点播上给。
        // Always there (but for live): adding a file by its address starts here (#576).
        if let external, !live { items.append(Self.subtitleFilesMenu(external, presenter: controller)) }
        let skipSource = skipSource
        let skips = skip.map { [UIAction(title: $0.kind == .intro ? L10n.text("Skip Intro") : L10n.text("Skip Outro"), image: UIImage(systemName: "forward.fill")) { _ in skipSource() }] } ?? []
        if controller.contextualActions.map(\.title) != skips.map(\.title) { controller.contextualActions = skips }
        if let skipping, !live {
            // No keyboard for a time here: the intro ends, or the outro starts, where the picture is. Each shows what
            // it holds, or where it may be set.
            let setSkipping = setSkipping, markSkip = markSkip
            var options: [UIMenuElement] = [
                UIAction(title: L10n.text("Automatically skip intro and outro"), state: skipping.enabled ? .on : .off) { _ in
                    var value = skipping; value.enabled.toggle(); setSkipping(value)
                },
                UIAction(title: L10n.text("Intro Ends Here"),
                         subtitle: skipping.introEnd > 0 ? EpisodeSkipSettings.formatTime(skipping.introEnd) : L10n.text("In the first five minutes")) { _ in markSkip(true) },
                UIAction(title: L10n.text("Outro Starts Here"),
                         subtitle: skipping.outroLength > 0 ? L10n.text("%@ before the end", EpisodeSkipSettings.formatTime(skipping.outroLength))
                            : L10n.text("In the last ten minutes")) { _ in markSkip(false) },
            ]
            if skipping.introEnd > 0 || skipping.outroLength > 0 {
                options.append(UIAction(title: L10n.text("Clear Intro and Outro"), image: UIImage(systemName: "xmark")) { _ in
                    setSkipping(EpisodeSkipSettings(enabled: skipping.enabled))
                })
            }
            // Not forward.end: beside Next Episode's forward.end.fill it read as a second Next button.
            items.append(UIMenu(title: L10n.text("Skip intro / outro"), image: UIImage(systemName: "arrow.right.to.line"), children: options))
        }
        if !live {
            let setSpeed = setSpeed, speed = speed
            let options = Self.speeds.map { rate in UIAction(title: Self.speedLabel(rate), state: rate == speed ? .on : .off) { _ in setSpeed(rate) } }
            items.append(UIMenu(title: L10n.text("Playback Speed") + " · " + Self.speedLabel(speed), image: UIImage(systemName: "gauge.with.dots.needle.67percent"), children: options))
        }
        if lines.count > 1 {
            let choose = chooseLine, line = line
            items.append(UIMenu(title: L10n.text("Lines"), image: UIImage(systemName: "point.3.connected.trianglepath.dotted"),
                                children: lines.enumerated().map { index, title in
                                    UIAction(title: title, state: index == line ? .on : .off) { _ in choose(index) }
                                }))
        }
        if let previous {
            items.insert(UIAction(title: previous.channel ? L10n.text("Previous Channel") : L10n.text("Previous Episode"), subtitle: previous.name, image: UIImage(systemName: "backward.end.fill"),
                                  attributes: previous.busy ? [.disabled] : []) { _ in previous.play() }, at: 0)
        }
        if let next {
            items.insert(UIAction(title: next.channel ? L10n.text("Next Channel") : L10n.text("Next Episode"), subtitle: next.name, image: UIImage(systemName: "forward.end.fill"),
                                  attributes: next.busy ? [.disabled] : []) { _ in next.play() }, at: previous == nil ? 0 : 1)
        }
        // [mi3s] 二开融合（上游 1.8.11）：Picture 菜单升级——加入 Fill Screen，且无增强能力时也保留该菜单。
        do {
            let upscale = upscale, smooth = smooth, fills = fills
            var options: [UIMenuElement] = [
                UIAction(title: L10n.text("Fill Screen"), image: UIImage(systemName: "arrow.up.left.and.arrow.down.right"),
                         state: fills.wrappedValue ? .on : .off) { _ in fills.wrappedValue.toggle() },
            ]
            if VideoEnhancement.canUpscale {
                options.append(UIAction(title: L10n.text("Sharper Picture"), state: upscale.wrappedValue ? .on : .off) { _ in upscale.wrappedValue.toggle() })
            }
            if VideoEnhancement.canSmooth {
                options.append(UIAction(title: L10n.text("Smooth Motion (60 fps)"), state: smooth.wrappedValue ? .on : .off) { _ in smooth.wrappedValue.toggle() })
            }
            let enhances = VideoEnhancement.canUpscale || VideoEnhancement.canSmooth
            items.append(UIMenu(title: L10n.text("Picture"), image: UIImage(systemName: enhances ? "wand.and.sparkles" : "aspectratio"), children: options))
        }
        let info = info
        items.append(UIAction(title: L10n.text("Show Video Info"), image: UIImage(systemName: "info.circle"),
                              state: info.wrappedValue ? .on : .off) { _ in info.wrappedValue.toggle() })
        controller.transportBarCustomMenuItems = items
    }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) { coordinator.criteria?.reset() }
    private var overlay: AnyView {
        AnyView(ZStack {
            if let enhancer { EnhancedVideoSurface(enhancer: enhancer) }
            if showsDanmaku && !comments.isEmpty { DanmakuOverlay(player: player, comments: comments, opacity: opacity, revision: revision).ignoresSafeArea() }
            if let subtitles { SubtitleOverlay(cues: subtitles, fills: fills.wrappedValue) }
            if let titleRow { titleRow }
            if let waiting { waiting.view.transition(PlaybackWaitContent.transition) }
        }
        // In with a fade; out at once, so the first frame replaces the wait with no pause or crossfade.
        .animation(waiting == nil ? nil : .easeInOut(duration: 0.7), value: waiting == nil))
    }
}
#endif

#if os(macOS)
/// A real document-style window: playback remains independent of library navigation.
@MainActor final class PlayerWindowController: NSObject, NSWindowDelegate {
    private var window: PlaybackWindow?
    private let session = PlaybackSession()
    private var onClose: (() -> Void)?

    func present(_ channel: Channel, store: Store, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let target: PlaybackWindow
        if let window { target = window }
        else {
            target = PlaybackWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
            target.isReleasedWhenClosed = false
            target.delegate = self
            target.contentMinSize = NSSize(width: 480, height: 320)
            target.collectionBehavior = [.fullScreenPrimary]
            target.backgroundColor = .black
            target.titlebarAppearsTransparent = true
            target.titleVisibility = .hidden
            target.isMovableByWindowBackground = true
            target.center()
            target.setFrameAutosaveName("PlaybackWindow")
            target.session = session
            window = target
        }
        target.title = channel.name
        // The next episode updates the view in place: a new one would rebuild the player view, a flash between episodes.
        let root = DesktopPlaybackRoot(channel: channel, session: session, window: target, store: store)
        if let host = target.contentView as? NSHostingView<DesktopPlaybackRoot> { host.rootView = root }
        else { target.contentView = NSHostingView(rootView: root) }
        startCatalogPlayback(session, channel: channel, store: store)
        target.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        (sender as? PlaybackWindow)?.resized(to: frameSize) ?? frameSize
    }

    func windowWillStartLiveResize(_ notification: Notification) { window?.startsDrag() }

    func windowWillClose(_ notification: Notification) {
        session.stop()
        window?.contentView = nil
        window = nil
        let callback = onClose
        onClose = nil
        callback?()
    }
}

@MainActor final class PlaybackWindow: NSWindow {
    weak var session: PlaybackSession?

    private var scroll = ScrollAxisLock()
    /// The second click of a double-click went to full screen: its mouse-up is not passed on either.
    private var takesMouseUp = false

    /// The wheel over the picture sets the volume, as in other players; AVKit's own handling scrubbed the video.
    /// A sideways swipe is still AVKit's, to scrub with (#874). Over the episode list and other panels it still
    /// scrolls them.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyUp, event.keyCode == 124, arrow.isDown { arrowReleased(skips: true) }
        // A double-click on the picture goes full screen and back, as in QuickTime Player and IINA (#838). Only the second
        // click is taken, down and up, so a single click still shows or hides AVKit's controls at once, as before.
        if event.type == .leftMouseUp, takesMouseUp { takesMouseUp = false; return }
        if event.type == .leftMouseDown {
            pressedAt = convertPoint(toScreen: event.locationInWindow)
            takesMouseUp = event.clickCount == 2 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty
                && contentView?.hitTest(event.locationInWindow).map(Self.isBarePicture) == true
            if takesMouseUp { toggleFullScreen(nil); return }
        }
        if event.type == .scrollWheel, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let session, let hit = contentView?.hitTest(event.locationInWindow), Self.isPicture(hit),
           scroll.axis(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, starts: !event.phase.isDisjoint(with: [.began, .mayBegin]),
                       tracked: !event.phase.isEmpty || !event.momentumPhase.isEmpty) == .vertical {
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.003 : 0.02)
            if delta != 0 {
                session.player.isMuted = false
                session.player.volume = min(1, max(0, session.player.volume + Float(event.isDirectionInvertedFromDevice ? -delta : delta)))
            }
            return
        }
        super.sendEvent(event)
    }

    /// The right arrow: a tap skips ahead, held it plays at the hold speed until it is let go (`KeyHold`, #871).
    private var arrow = KeyHold()
    private var arrowWait: Task<Void, Never>?

    private func arrowPressed(repeated: Bool) {
        // A new press while one is still open: its key-up was lost, so the hold it may have started ends first.
        if !repeated, arrow.isDown { arrowReleased(skips: false) }
        guard arrow.press(repeated: repeated) else { return }
        arrowWait = Task { [weak self] in
            try? await Task.sleep(for: .seconds(KeyHold.delay))
            guard !Task.isCancelled, let self, self.arrow.wait() else { return }
            let chosen = UserDefaults.standard.object(forKey: SpeedBoost.key) as? Double
            self.session?.setBoost(Float(SpeedBoost(rate: chosen ?? SpeedBoost.standard).rate))
        }
    }

    private func arrowReleased(skips: Bool) {
        arrowWait?.cancel(); arrowWait = nil
        switch arrow.release() {
        case .tap: if skips { session?.skip(10) }
        case .held: session?.setBoost(nil)
        case .stray: break
        }
    }

    /// The key-up goes to whichever window is key by then, so a hold ends here.
    override func resignKey() {
        arrowReleased(skips: false)
        super.resignKey()
    }

    private static func isPicture(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current { if v is AVPlayerView { return true }; current = v.superview }
        return false
    }

    /// The picture and not AVKit's controls over it: their buttons and sliders are controls, on glass platters.
    private static func isBarePicture(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v is AVPlayerView { return true }
            if v is NSControl || v is NSVisualEffectView { return false }
            if #available(macOS 26, *), v is NSGlassEffectView { return false }
            current = v.superview
        }
        return false
    }

    /// The picture's size, once known.
    private var videoSize: NSSize?
    /// Fill Window (#978): the picture fills whatever shape the window has, so the window resizes freely, to any
    /// shape, as in VLC. Turning it off gives the window the picture's shape again and locks it.
    var fillsFrame = false {
        didSet {
            guard fillsFrame != oldValue else { return }
            if !fillsFrame, let videoSize { fit(toVideo: videoSize) }
        }
    }

    /// Where a drag of the window's edge or corner started, and which edges it moves.
    private var drag: (frame: NSRect, mouse: NSPoint, edges: (left: Bool, right: Bool, bottom: Bool, top: Bool))?

    /// Where the last click went down: AppKit starts a drag only after its first step, by when the pointer has moved.
    private var pressedAt: NSPoint?

    func startsDrag() {
        let mouse = pressedAt ?? NSEvent.mouseLocation, margin: CGFloat = 12
        drag = (frame, mouse, (mouse.x <= frame.minX + margin, mouse.x >= frame.maxX - margin,
                               mouse.y <= frame.minY + margin, mouse.y >= frame.maxY - margin))
    }

    /// The size a drag of the window's edge or corner gives it (`windowWillResize`): the picture's shape (#689), so there
    /// are no black bars to drag away, unless Shift is held, which resizes it freely, to any shape, as in IINA. Shift is
    /// checked on every step, so it can be pressed or let go midway. The window keeps the shape itself, not with
    /// `contentAspectRatio`: AppKit reads that once, when a drag starts.
    func resized(to proposed: NSSize) -> NSSize {
        guard inLiveResize, !styleMask.contains(.fullScreen) else { return proposed }
        let flags = (NSApp.currentEvent?.modifierFlags ?? []).union(NSEvent.modifierFlags)
        if flags.contains(.shift) {
            // AppKit's own Shift-drag keeps the window's shape, so the size comes from the pointer instead.
            guard let drag else { return proposed }
            let mouse = NSEvent.mouseLocation, minimum = frameRect(forContentRect: NSRect(origin: .zero, size: contentMinSize)).size
            var size = drag.frame.size
            if drag.edges.right { size.width += mouse.x - drag.mouse.x } else if drag.edges.left { size.width -= mouse.x - drag.mouse.x }
            if drag.edges.top { size.height += mouse.y - drag.mouse.y } else if drag.edges.bottom { size.height -= mouse.y - drag.mouse.y }
            return NSSize(width: max(minimum.width, size.width.rounded()), height: max(minimum.height, size.height.rounded()))
        }
        guard !fillsFrame, let videoSize, videoSize.width > 0, videoSize.height > 0 else { return proposed }
        let ratio = videoSize.width / videoSize.height
        let old = contentRect(forFrameRect: frame).size
        var size = contentRect(forFrameRect: NSRect(origin: .zero, size: proposed)).size
        guard old.width > 0, old.height > 0, size.width > 0, size.height > 0 else { return proposed }
        // The side the drag moves more leads and the other follows: an edge moves one side, a corner both.
        if abs(size.width - old.width) / old.width >= abs(size.height - old.height) / old.height { size.height = size.width / ratio }
        else { size.width = size.height * ratio }
        let minimum = contentMinSize
        if size.width < minimum.width || size.height < minimum.height {
            let up = max(minimum.width / size.width, minimum.height / size.height)
            size.width *= up; size.height *= up
        }
        return frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: size.width.rounded(), height: size.height.rounded()))).size
    }

    /// Sizes the window to the picture, which `resized(to:)` then keeps while it is resized (#689), so there are no black bars to
    /// drag away. A video of the shape the window already has leaves the size the viewer chose alone; full screen and
    /// a zoomed window are left as they are, and so is a window the picture fills (#978).
    func fit(toVideo video: NSSize) {
        guard video.width > 0, video.height > 0, video.width.isFinite, video.height.isFinite else { return }
        videoSize = video
        guard !fillsFrame else { return }
        guard !styleMask.contains(.fullScreen), !isZoomed, let contentView else { return }
        let current = contentView.bounds.size
        guard current.width > 0, current.height > 0 else { return }
        let ratio = video.width / video.height
        if abs(current.width / current.height - ratio) / ratio < 0.01 { return }
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? frame
        // Keep the width the viewer has, as far as the screen allows, and give it the picture's height.
        let chrome = frame.height - current.height
        var width = min(current.width, visible.width * 0.9)
        var height = width / ratio
        let room = visible.height * 0.9 - chrome
        if height > room { height = room; width = height * ratio }
        let minimum = contentMinSize
        if width < minimum.width || height < minimum.height {
            let up = max(minimum.width / width, minimum.height / height)
            width *= up; height *= up
        }
        var target = frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: width.rounded(), height: height.rounded())))
        target.origin = NSPoint(x: frame.midX - target.width / 2, y: frame.midY - target.height / 2)
        target.origin.x = min(max(visible.minX, target.origin.x), max(visible.minX, visible.maxX - target.width))
        target.origin.y = min(max(visible.minY, target.origin.y), max(visible.minY, visible.maxY - target.height))
        setFrame(target, display: true, animate: true)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Preserve system commands and text/slider editing inside native controls.
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !(firstResponder is NSTextView), !(firstResponder is NSSlider) else { return super.performKeyEquivalent(with: event) }
        switch event.keyCode {
        case 49: session?.togglePlayback()
        case 123: session?.skip(event.modifierFlags.contains(.shift) ? -60 : -10)
        case 124:
            if event.modifierFlags.contains(.shift) { session?.skip(60) } else { arrowPressed(repeated: event.isARepeat) }
        case 126: if let player = session?.player { player.volume = min(1, player.volume + 0.05) }
        case 125: if let player = session?.player { player.volume = max(0, player.volume - 0.05) }
        case 53:
            if styleMask.contains(.fullScreen) { toggleFullScreen(nil) }
            else { return super.performKeyEquivalent(with: event) }
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f": toggleFullScreen(nil)
            case "m": session?.player.isMuted.toggle()
            default: return super.performKeyEquivalent(with: event)
            }
        }
        return true
    }
}

/// Auto-hiding chrome driven by real pointer movement and key presses (not hover
/// phases, which AVPlayerView's own overlay and layout passes keep re-firing).
@MainActor @Observable private final class ChromeIdle {
    var visible = true
    private var task: Task<Void, Never>?
    private var monitor: Any?
    private weak var window: NSWindow?

    func attach(_ window: NSWindow) {
        detach()
        self.window = window
        window.acceptsMouseMovedEvents = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return }
                // Ignore synthetic mouse events that carry no movement.
                if event.type == .mouseMoved, abs(event.deltaX) + abs(event.deltaY) < 1 { return }
                self.poke()
            }
            return event
        }
        poke()
    }

    func detach() {
        task?.cancel(); task = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func poke() {
        if !visible { withAnimation(.smooth(duration: 0.25)) { visible = true } }
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.smooth(duration: 0.4)) { self.visible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

/// The faster speed while the right arrow is held, at the top as on iPhone. A view of its own, so a hold redraws
/// only this.
private struct DesktopBoostLabel: View {
    let session: PlaybackSession

    var body: some View {
        if let rate = session.boost {
            HStack(spacing: 6) {
                Text(Self.label(rate))
                // Held lower than asked: the connection can't keep up with the faster speed.
                if let wanted = session.boostWanted { Text(Self.label(wanted)).strikethrough().opacity(0.55) }
                Image(systemName: "forward.fill")
            }
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glassSurface(.regular, in: Capsule())
            .padding(.top, 56)
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            .accessibilityIdentifier("player.boost")
        }
    }

    private static func label(_ speed: Float) -> String {
        Double(speed).formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

private struct DesktopPlaybackRoot: View {
    let channel: Channel
    let session: PlaybackSession
    let window: PlaybackWindow
    let store: Store
    var body: some View { DesktopPlaybackView(channel: channel, session: session, window: window).environment(store) }
}

private struct DesktopPlaybackView: View {
    @Environment(Store.self) private var store
    let channel: Channel
    @Bindable var session: PlaybackSession
    let window: PlaybackWindow
    @State private var fillsFrame = false
    @State private var floats = false
    @State private var idle = ChromeIdle()
    @AppStorage(DanmakuPreference.key) private var showsDanmaku = true
    @State private var showsDanmakuList = false
    /// The episode sheet, which the transport bar's "Episodes" asks for.
    @State private var showsDanmakuSettings = false
    @State private var showsEpisodes = false
    @State private var showsChannels = false
    @AppStorage(PlaybackInfo.key) private var showsPlaybackInfo = false
    /// Devices with Yingxia open, for the Play On button; and the one the video was sent to.
    @State private var tvBrowser = PlayOnBrowser()
    @State private var playingOn: String?

    private var showsChrome: Bool { idle.visible || session.error != nil }
    private var waitContent: PlaybackWaitContent? { .make(session, channel: channel, store: store, linesHint: true) }

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                Color.black
                let bare = session.isLive || !session.hasTimeline
                // A new player view whenever the controls come or go (see DesktopNativePlayer).
                DesktopNativePlayer(player: session.player, fillsFrame: fillsFrame, live: bare, waiting: waitContent, enhancer: session.enhancer,
                                    subtitles: session.subtitles)
                    .id(bare)
                if showsDanmaku && !session.danmaku.isEmpty { DanmakuOverlay(player: session.player, comments: session.danmaku, opacity: session.danmakuOpacity, revision: session.danmakuRevision).ignoresSafeArea() }
                // Under the title bar's buttons, so it stays put while they come and go.
                SubtitleOverlay(cues: session.subtitles, fills: fillsFrame).ignoresSafeArea()
                SourceSkipButton(session: session)
                DesktopBoostLabel(session: session)
                // Under the title bar's buttons and AVKit's row of controls below them (macOS 26), so it stays put while
                // they come and go.
                if showsPlaybackInfo && session.error == nil && session.showsPicture && playingOn == nil {
                    PlaybackInfoPanel(session: session)
                        .padding(.leading, 16).padding(.top, 96)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(.opacity)
                }
                if let error = session.error {
                    ErrorState(title: L10n.text("Can't play this right now"), message: error, details: "", symbol: session.errorSymbol,
                               retry: { startCatalogPlayback(session, channel: channel, store: store) })
                        .padding(28).frame(maxWidth: 460)
                        .glassSurface(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous)).padding()
                        .environment(\.colorScheme, .dark)
                }
                if let playingOn {
                    Color.black
                    PlayOnPlaceholder(receiver: playingOn) {
                        self.playingOn = nil
                        if session.paused { session.togglePlayback() }
                    }
                }
            }
            topBar
                .opacity(showsChrome ? 1 : 0)
                .allowsHitTesting(showsChrome)
        }
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        .onChange(of: showsDanmaku) { _, value in session.catalogDanmaku.enabled = value }
        .onChange(of: session.catalogDanmaku.enabled) { _, value in showsDanmaku = value }
        .onChange(of: floats) { _, value in window.level = value ? .floating : .normal }
        .onChange(of: fillsFrame, initial: true) { _, value in window.fillsFrame = value }
        // Each picture that appears (the next episode too) shapes the window; the size arrives a moment after it.
        .task(id: session.showsPicture) {
            guard session.showsPicture else { return }
            for _ in 0..<30 {
                if let size = session.player.currentItem?.presentationSize, size.width > 0, size.height > 0 {
                    window.fit(toVideo: size)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
            }
        }
        .onChange(of: showsChrome) { _, value in setTrafficLights(visible: value) }
        .onAppear { floats = window.level == .floating; idle.attach(window); tvBrowser.start() }
        // Played here again (Space, say): the other device no longer has it to itself.
        .onChange(of: session.paused) { _, paused in if !paused { playingOn = nil } }
        .playerEpisodesSheet(isPresented: $showsEpisodes, channel: channel)
        .playerChannelsSheet(isPresented: $showsChannels, channel: channel, session: session)
        .sheet(isPresented: $showsDanmakuList) {
            DanmakuListView(player: session.player, comments: session.danmaku) { showsDanmakuList = false }
                .danmakuListPresentation()
        }
        .sheet(isPresented: $showsEpisodes) {
            CatalogEpisodePanel(channel: channel, compact: false)
                .frame(minWidth: 560, minHeight: 600)
        }
        // 上游 1.8.23：弹幕设置从「⋯」菜单升成独立 sheet。
        .sheet(isPresented: $showsDanmakuSettings) {
            CatalogDanmakuSettingsView(model: session.catalogDanmaku, channelName: channel.name).playerSheet()
        }
        .onDisappear { idle.detach(); tvBrowser.stop() }
        .subtitleImport(files: $importsSubtitleFile, address: $asksSubtitleAddress, search: $searchesSubtitles, subtitles: session.externalSubtitles)
        // A subtitle file dropped on the video shows on it (#576).
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(ExternalSubtitles.handles)
            files.forEach { session.externalSubtitles.add(file: $0) }
            return !files.isEmpty
        }
    }

    /// Title on the left (beside the traffic lights), actions on the right, over a soft scrim.
    private var topBar: some View {
        HStack(spacing: 10) {
            Text(channel.name).font(.headline).lineLimit(1)
                .shadow(color: .black.opacity(0.6), radius: 4)
                .padding(.leading, 86)
            Spacer(minLength: 12)
            // One glass capsule holds the buttons, like a toolbar group: a glass circle each read as loose bubbles.
            HStack(spacing: 2) {
                if session.isLive || !session.hasTimeline {
                    // AVKit's controls are hidden without a timeline (see DesktopNativePlayer), so play and mute live here.
                    barButton(session.paused ? "play.fill" : "pause.fill", L10n.text("Play / Pause (Space)")) { session.togglePlayback() }
                    barButton(session.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", L10n.text("Mute (M)")) { session.player.isMuted.toggle() }
                } else {
                    barButton("gobackward.10", L10n.text("Back 10 seconds (←)")) { session.skip(-10) }
                    barButton("goforward.10", L10n.text("Forward 10 seconds (→)")) { session.skip(10) }
                }
                if let previous = store.step(back: true, from: channel, session: session) {
                    barButton("backward.end.fill", previous.title(back: true), help: previous.name) { previous.go() }
                        .disabled(previous.busy)
                }
                if let next = store.step(back: false, from: channel, session: session) {
                    barButton("forward.end.fill", next.title(back: false), help: next.name) { next.go() }
                        .disabled(next.busy)
                }
                PlayerEpisodesButton(channel: channel, isPresented: $showsEpisodes) {
                    Image(systemName: PlayerEpisodesSheet.symbol).font(.system(size: 14, weight: .medium))
                        .frame(width: 34, height: 34)
                        .playerBarButton()
                }
                .buttonStyle(.plain)
                PlayerChannelsButton(channel: channel, session: session, isPresented: $showsChannels) {
                    Image(systemName: PlayerChannelsSheet.symbol).font(.system(size: 14, weight: .medium))
                        .frame(width: 34, height: 34)
                        .playerBarButton()
                }
                .buttonStyle(.plain)
                if !tvBrowser.receivers.isEmpty {
                    PlayOnButton(channel: channel, session: session, browser: tvBrowser) { receiver in
                        session.player.pause()
                        playingOn = receiver
                    }
                }
                // [mi3s] 二开：本页的选集面板归本视图管（`showsEpisodes`），所以把打开动作交给它，
                // 而不是让菜单自己弹 sheet（上游此处是裸 `CatalogPlaybackActions(...)`）。
                CatalogPlaybackActions(channel: channel, session: session, openEpisodes: { showsEpisodes = true })
                optionsMenu
                barButton("arrow.up.left.and.arrow.down.right", L10n.text("Enter / Exit Full Screen")) { window.toggleFullScreen(nil) }
            }
            .chromeGroup(inset: 2)
        }
        // 6 pt from the side, like AVKit's PiP and volume pills under it, so the right edges line up.
        .padding(.top, 10).padding(.trailing, 6).padding(.bottom, 36)
        .background(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        }
    }

    private func barButton(_ symbol: String, _ label: String, help: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14, weight: .medium)) }
            .buttonStyle(.plain)
            .frame(width: 34, height: 34)
            .playerBarButton()
            .help(help ?? label)
            .accessibilityLabel(label)
    }

    private var optionsMenu: some View {
        DesktopOptionsMenu(channel: channel, session: session, window: window, hasDanmaku: !session.danmaku.isEmpty, fillsFrame: $fillsFrame, floats: $floats,
                           showsDanmakuList: $showsDanmakuList, showsDanmakuSettings: $showsDanmakuSettings,
                           importsSubtitleFile: $importsSubtitleFile, asksSubtitleAddress: $asksSubtitleAddress, searchesSubtitles: $searchesSubtitles)
            .equatable()
    }

    private func setTrafficLights(visible: Bool) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.animator().alphaValue = visible ? 1 : 0
        }
    }
}

/// The Mac player's options menu, as a view of its own that is equal to itself while nothing it shows changes. In a
/// live room every chat message evaluates the player's body again; built again with it, an open menu shut the submenu
/// under the pointer, so Quality, Text Size and the others flickered and couldn't be picked (#846).
private struct DesktopOptionsMenu: View, Equatable {
    @Environment(Store.self) private var store
    let channel: Channel
    let session: PlaybackSession
    let window: PlaybackWindow
    /// Whether there are comments at all, not the comments: those change with every message.
    let hasDanmaku: Bool
    @Binding var fillsFrame: Bool
    @Binding var floats: Bool
    @Binding var showsDanmakuList: Bool
    @Binding var showsDanmakuSettings: Bool
    @Binding var importsSubtitleFile: Bool
    @Binding var asksSubtitleAddress: Bool
    @Binding var searchesSubtitles: Bool
    @AppStorage(DanmakuPreference.key) private var showsDanmaku = true
    @AppStorage(DanmakuArea.key) private var danmakuArea = DanmakuArea.standard
    @AppStorage(VideoEnhancement.upscaleKey) private var upscalesVideo = false
    @AppStorage(VideoEnhancement.smoothKey) private var smoothsVideo = false
    @AppStorage(PlaybackInfo.key) private var showsPlaybackInfo = false

    /// The bindings and settings reach the menu by themselves; only these decide what it is built from.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.session === b.session && a.window === b.window && a.hasDanmaku == b.hasDanmaku && a.channel == b.channel
    }

    var body: some View {
        @Bindable var session = session
        Menu {
            Toggle(L10n.text("Loop Playback"), isOn: $session.looping)
            Toggle(L10n.text("Fill Window"), isOn: $fillsFrame)
            Toggle(L10n.text("Float on Top"), isOn: $floats)
            Toggle(L10n.text("Show Video Info"), isOn: $showsPlaybackInfo)
            if VideoEnhancement.canUpscale { Toggle(L10n.text("Sharper Picture"), isOn: $upscalesVideo) }
            if VideoEnhancement.canSmooth { Toggle(L10n.text("Smooth Motion (60 fps)"), isOn: $smoothsVideo) }
            if session.qualities.count > 1 {
                Menu(L10n.text("Quality")) { QualityPicker(session: session) }
            }
            Menu(L10n.text("Subtitle Files")) {
                MacSubtitleFiles(subtitles: session.externalSubtitles, addFile: { importsSubtitleFile = true }, addAddress: { asksSubtitleAddress = true },
                                 searchOnline: { searchesSubtitles = true })
            }
            Menu(L10n.text("Danmaku")) {
                Toggle(L10n.text("Show Danmaku"), isOn: $showsDanmaku)
                Picker(L10n.text("Danmaku Area"), selection: $danmakuArea) {
                    ForEach(DanmakuArea.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                DanmakuStylePickers(model: session.catalogDanmaku)
                Button(L10n.text("Danmaku Settings…")) { showsDanmakuSettings = true }
                    .accessibilityIdentifier("player.danmakuSettings")
                Button(L10n.text("Danmaku List…")) { showsDanmakuList = true }.disabled(!hasDanmaku)
            }
            Divider()
            Button(L10n.text("Enter / Exit Full Screen")) { window.toggleFullScreen(nil) }
            Button(L10n.text("Retry")) { startCatalogPlayback(session, channel: channel, store: store) }
            Divider()
            Text(L10n.text("Space: Play / Pause"))
            Text(L10n.text("← / →: Seek 10s · Shift: 60s"))
            Text(L10n.text("↑ / ↓: Volume · M: Mute · F: Full Screen"))
        } label: {
            Image(systemName: "slider.horizontal.3").font(.system(size: 14, weight: .medium))
                .frame(width: 34, height: 34).contentShape(Circle())
        }
        // A borderless menu drew its icon at the leading edge of the circle; a plain one keeps it centred.
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize()
        .playerBarButton()
        .help(L10n.text("Playback Options"))
        .accessibilityLabel(L10n.text("Playback Options"))
    }
}

/// The Mac's subtitle-file menu: AVKit's own menu has the item's subtitles, so this one has Off and the files.
private struct MacSubtitleFiles: View {
    let subtitles: ExternalSubtitles
    let addFile: () -> Void
    let addAddress: () -> Void
    let searchOnline: () -> Void
    var body: some View {
        if subtitles.selected != nil { Button(L10n.text("Off")) { subtitles.select(nil) } }
        ExternalSubtitleMenu(subtitles: subtitles, addFile: addFile, addAddress: addAddress, searchOnline: searchOnline)
    }
}

/// AVPlayerView without its controls for live streams. Its controls build a scrubber from the
/// item's duration and seekable range; a live item has an indefinite duration and, at first, no
/// seekable range, and AVKit traps on that range (macOS 27). An IPTV channel is a plain address, so it
/// is only known to be live once its item is ready: the controls wait for a ready item with a finite
/// duration. tvOS avoids it with linear playback.
/// `live` is fixed for a view's life: set to `.none` on a view that has shown its controls,
/// AVKit takes the buttons away but leaves their empty glass platter, which still fades in under the
/// mouse (macOS 27). A view made without controls has no platter.
private struct DesktopNativePlayer: NSViewRepresentable {
    let player: AVPlayer
    let fillsFrame: Bool
    var live = false
    var waiting: PlaybackWaitContent? = nil
    var enhancer: VideoEnhancer? = nil
    var subtitles: SubtitleCues? = nil
    // [mi3s] 二开（补上游能力）：macOS 的 PiP 窗口只显示播放器自己的画面，
    // 所以进出 PiP 时要把字幕切到原生渲染，否则 PiP 里看不到字幕。
    // 我方 DesktopNativePlayer 此前丢了这两个回调（allowsPictureInPicturePlayback 还在），
    // 会导致 PiP 时字幕消失。回调名与上游 22180e4 一致。
    @MainActor final class Coordinator: NSObject, @preconcurrency AVPlayerViewPictureInPictureDelegate {
        var host: PassthroughHostingView<AnyView>?
        var subtitles: SubtitleCues?
        func playerViewWillStartPicture(inPicture playerView: AVPlayerView) { subtitles?.native = true }
        func playerViewDidStopPicture(inPicture playerView: AVPlayerView) { subtitles?.native = false }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> AVPlayerView {
        let view = DesktopAVPlayerView()
        // The wait lives in the content overlay, under the controls, and lets the mouse through to them.
        // It follows the overlay's frame and sets no size of its own: with NSHostingView's default sizing
        // constraints, its SwiftUI content's size pushed back through the overlay and the whole player was laid
        // out at that size (16 × 130 pt once loading ended, the video a 16 × 9 box).
        if let container = view.contentOverlayView {
            let host = PassthroughHostingView(rootView: overlay)
            host.sizingOptions = []
            host.frame = container.bounds
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)
            context.coordinator.host = host
        }
        // The controls along the foot of the picture, the scrubber as wide as they are, as in QuickTime Player. The
        // floating panel sat over the middle of the picture with a short scrubber; on a wide film it covered faces (#932).
        view.controlsStyle = live ? .none : .inline
        view.player = player
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        // [mi3s] 二开（补上游能力）：把 coordinator 挂成 PiP delegate 并带上字幕
        context.coordinator.subtitles = subtitles
        view.pictureInPictureDelegate = context.coordinator
        view.showsSharingServiceButton = false
        // Setting `speeds` puts the player back to normal speed, and this view is new whenever the controls come or go,
        // as they do while each next episode loads: pick the speed it played at again (#1015).
        let speed = player.defaultRate
        view.speeds = [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4].map { AVPlaybackSpeed(rate: Float($0), localizedName: "\($0)×") }
        if let picked = view.speeds.first(where: { $0.rate == speed }) { view.selectSpeed(picked) }
        else {
            player.defaultRate = speed
            if player.rate != 0 { player.rate = speed }
        }
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
        view.videoGravity = fillsFrame ? .resizeAspectFill : .resizeAspect
        context.coordinator.host?.rootView = overlay
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) { view.player = nil }
    private var overlay: AnyView {
        AnyView(ZStack {
            // [mi3s] 二开：`EnhancedVideoSurface` 的显式 gravity 优先（见 App/VideoEnhancement.swift）。
            if let enhancer { EnhancedVideoSurface(enhancer: enhancer, gravity: fillsFrame ? .resizeAspectFill : .resizeAspect) }
            if let waiting { waiting.view.transition(PlaybackWaitContent.transition) }
        // In with a fade; out at once, so the first frame replaces the wait with no pause or crossfade.
        }.animation(waiting == nil ? nil : .easeInOut(duration: 0.7), value: waiting == nil))
    }
}

/// The Mac player's AVPlayerView. Its controls' top row (Picture in Picture and AirPlay on the left, the volume on the
/// right; macOS 26 and later) goes at the top of the view's safe area, which is only the title bar, or nothing in full
/// screen: it sat behind the player's own row of buttons there. This moves the safe area's top below that row.
private final class DesktopAVPlayerView: AVPlayerView {
    /// The foot of `DesktopPlaybackView`'s top bar (10 pt down, 34 pt buttons), and a gap.
    private static let topBar: CGFloat = 46

    override func layout() {
        if #available(macOS 26, *) {
            let extra = max(0, Self.topBar - (safeAreaInsets.top - additionalSafeAreaInsets.top))
            if additionalSafeAreaInsets.top != extra { additionalSafeAreaInsets.top = extra }
        }
        super.layout()
    }
}

/// A hosting view that draws but never takes the mouse, so AVPlayerView's controls above it keep working.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif

#if !os(tvOS)
/// Automatic, or one of the stream's qualities, best first.
struct QualityPicker: View {
    let session: PlaybackSession
    var body: some View {
        Picker(L10n.text("Quality"), selection: Binding(get: { session.quality ?? 0 }, set: { session.choose(quality: $0 == 0 ? nil : $0) })) {
            Text(L10n.text("Auto")).tag(0)
            ForEach(session.qualities) { Text($0.label).tag($0.id) }
        }
        .pickerStyle(.inline)
    }
}
#endif

/// What the player's Previous and Next buttons do: an episode of the video playing, or the file
/// beside the playing one in its Cloud Files folder. Next plays from the queue once it waits there.
struct PlayerStep {
    let name: String
    let busy: Bool
    /// A live channel of the list it was picked from, not an episode or a file (#1010).
    var channel = false
    let go: @MainActor () -> Void

    func title(back: Bool) -> String {
        switch (channel, back) {
        case (true, true): L10n.text("Previous Channel")
        case (true, false): L10n.text("Next Channel")
        case (false, true): L10n.text("Previous Episode")
        case (false, false): L10n.text("Next Episode")
        }
    }
}

extension Store {
    func step(back: Bool, from channel: Channel, session: PlaybackSession) -> PlayerStep? {
        if let episode = back ? previousEpisode(before: channel) : nextEpisode(after: channel) {
            return PlayerStep(name: episode.name, busy: resolvingEpisode != nil) { [weak self] in
                if back || !session.playUpcoming() { self?.selectEpisode(episode, from: channel) }
            }
        }
        if let file = back ? previousFile(before: channel) : nextFile(after: channel) {
            return PlayerStep(name: file.name, busy: false) { [weak self] in
                if back || !session.playUpcoming() { self?.playing = file }
            }
        }
        if let other = lineup(for: channel)?.neighbor(of: channel, back: back) {
            return PlayerStep(name: other.name, busy: false, channel: true) { [weak self] in self?.playing = other }
        }
        return nil
    }
}

/// Shared setup leaves the native AVKit controls and Bilibili resolution intact.
/// Internal (not private) so the floating mini player can start or hand the session
/// on to a newly playing channel the same way `PlaybackView` does — the mini player
/// has no `PlaybackView` of its own, but auto-advance must work there and in PiP too.
@MainActor func startCatalogPlayback(_ session: PlaybackSession, channel: Channel, store: Store) {
    session.history = store.playbackHistory
    session.skipDefaults = store.playbackDefaults
    session.catalogDanmaku.enabled = UserDefaults.standard.object(forKey: DanmakuPreference.key) == nil
        || UserDefaults.standard.bool(forKey: DanmakuPreference.key)
    session.start(channel)
    session.onPlaybackEnded = { [weak store] in
        // The session may already have advanced (a queued episode takes over `store.playing`), so read the
        // channel now playing rather than the one this setup captured: it ends against the right episode.
        guard let store, let channel = store.playing else { return }
        // A next episode in the same line plays on, exactly as before.
        if store.autoPlayNext {
            if let file = store.nextFile(after: channel) { store.playing = file; return }
            if let next = store.nextEpisode(after: channel) { store.selectEpisode(next, from: channel); return }
        }
        // Only the last episode of the line ends with a "what next" offer. With auto-play off the
        // episode above still has a following episode the viewer has not seen, so it just stops here
        // instead of jumping ahead to a series-end recommendation.
        if store.nextFile(after: channel) == nil, store.nextEpisode(after: channel) == nil {
            store.finishSeries(channel)
        }
    }
    // Near the end the next episode is resolved and queued, so it plays on without stopping to load.
    session.playsOn = { [weak store] in store?.autoPlayNext == true }
    session.upcomingEpisode = { [weak store] in
        guard let store, let channel = store.playing else { return nil }
        return await store.upcomingEpisode(after: channel)
    }
    session.onAdvance = { [weak store] next in
        guard let store, let from = store.playing else { return }
        store.advance(to: next, from: from)
    }
    // A short episode's next one is resolved while it plays (#1021), once its own start is out of the way and its
    // length is known.
    Task { [weak store, weak session] in
        for _ in 0..<6 {
            try? await Task.sleep(for: .seconds(5))
            guard let store, let session, store.playing == channel else { return }
            if session.duration > 0 { return store.resolveNextAhead(after: channel, duration: session.duration) }
        }
    }
    session.upcomingEpisode = { [weak store] in await store?.upcomingEpisode(after: channel) }
    session.onAdvance = { [weak store] next in store?.advance(to: next, from: channel) }
    session.onUnplayableFile = { [weak store, weak session] in
        // Like the other callbacks, resolve against the episode now playing, not the one this setup
        // captured: after auto-advance `store.playing` has moved on, and a stale channel would make
        // `transcodedLine(for:)`/`selectEpisode(from:)` look at (and fail on) the previous episode.
        guard let store, let channel = store.playing, let other = store.transcodedLine(for: channel) else { return nil }
        store.selectEpisode(other, from: channel, failed: { session?.lineSwitchFailed($0) })
        return other.flag
    }
    if let context = channel.historyContext, let next = store.nextEpisode(after: channel),
       let catalog = store.catalog(for: channel) {
        session.catalogDanmaku.prefetch(PlaybackHistoryContext(origin: context.origin, site: catalog.client.site,
            video: catalog.video, episode: next))
    }
}

/// The info panel in a corner of the picture (Settings → Show Video Info, off by default): the video and audio
/// format, the picture's size and frame rate, and the stream's bitrate beside what arrives. It exists only while
/// the switch is on, and reads the playing item once a second, as the session's own sampling does.
struct PlaybackInfoPanel: View {
    let session: PlaybackSession
    @State private var info = PlaybackInfo()
    @State private var formats = PlaybackFormats()

    private struct Row: Identifiable { let id: String; let text: String }

    var body: some View {
        let rows = [Row(id: "film", text: info.video ?? ""), Row(id: "waveform", text: info.audio ?? ""),
                    Row(id: "speedometer", text: info.network() ?? "")].filter { !$0.text.isEmpty }
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            ForEach(rows) { row in
                HStack(spacing: Metrics.spacing * 2.5) {
                    Image(systemName: row.id).foregroundStyle(.white.opacity(0.55)).frame(width: Metrics.icon)
                    Text(row.text).lineLimit(1)
                }
            }
        }
        .font(.system(size: Metrics.font, weight: .medium)).monospacedDigit()
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, Metrics.padding * 1.3).padding(.vertical, Metrics.padding)
        // A plain tint, not a material: it sits over moving video, where a blur would redraw every frame.
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1) }
        .opacity(rows.isEmpty ? 0 : 1)
        .animation(.smooth(duration: 0.25), value: rows.map(\.id))
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player.info")
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refresh() async {
        guard let item = session.player.currentItem else { info = PlaybackInfo(); return }
        let tracks = item.tracks.filter(\.isEnabled)
        let video = tracks.first { $0.assetTrack?.mediaType == .video }
        let audio = tracks.first { $0.assetTrack?.mediaType == .audio }
        let picture = await formats.describe(video?.assetTrack)
        let sound = await formats.describe(audio?.assetTrack)
        guard !Task.isCancelled, session.player.currentItem === item else { return }
        var next = PlaybackInfo()
        let size = item.presentationSize
        next.width = Int(size.width.rounded()); next.height = Int(size.height.rounded())
        if next.width == 0 || next.height == 0 { next.width = picture?.width ?? 0; next.height = picture?.height ?? 0 }
        next.videoCodec = picture?.codec
        next.transferFunction = picture?.transferFunction
        // The track's own rate; the measured one (a stream that declares none) wanders around it.
        let measured = Double(video?.currentVideoFrameRate ?? 0)
        next.frameRate = picture?.frameRate ?? (measured > 0 ? measured : nil)
        next.audioCodec = sound?.codec
        next.sampleRate = sound?.sampleRate
        next.channels = sound?.channels
        // The session's measured rate (the variant's, or the decoded media's), else what the file's tracks declare.
        let declared = (picture?.dataRate ?? 0) + (sound?.dataRate ?? 0)
        next.bitrate = session.transfer.required.map { $0 * 8 } ?? (declared > 0 ? declared : nil)
        next.download = session.transfer.bytesPerSecond
        if next != info { info = next }
    }

    private enum Metrics {
        #if os(tvOS)
        static let font: CGFloat = 21, spacing: CGFloat = 6, padding: CGFloat = 14, corner: CGFloat = 18, icon: CGFloat = 28
        #else
        static let font: CGFloat = 11.5, spacing: CGFloat = 3, padding: CGFloat = 8, corner: CGFloat = 10, icon: CGFloat = 15
        #endif
    }
}

#if !os(macOS)
/// The video's tags over the seek bar, as MiraPlay shows them: "HW  H265  HDR10  4K  24FPS" (#520, #519). Plain
/// white type on the controls' scrim, read once a second while the controls show. On iPhone a tap shows the full info
/// panel (the bitrate, the sound and the download speed) or hides it; on Apple TV they only show (#758).
struct PlaybackBadges: View {
    let session: PlaybackSession
    /// The controls show: only then is the playing item read.
    let active: Bool
    var action: (() -> Void)? = nil
    @State private var sampler = PlaybackInfoSampler()
    @State private var badges: [String] = []

    var body: some View {
        content
            .opacity(badges.isEmpty ? 0 : 1)
            .animation(.smooth(duration: 0.25), value: badges)
            .task(id: active) {
                while active && !Task.isCancelled {
                    if let info = await sampler.sample(session), info.badges != badges { badges = info.badges }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }

    @ViewBuilder private var content: some View {
        if let action {
            Button(action: action) {
                tags.padding(.vertical, 6).padding(.leading, 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Show Video Info"))
            .accessibilityValue(badges.joined(separator: " "))
            .accessibilityIdentifier("player.badges")
        } else {
            tags.allowsHitTesting(false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("player.badges")
        }
    }

    private var tags: some View {
        HStack(spacing: Metrics.spacing) { ForEach(badges, id: \.self) { Text($0) } }
            .font(.system(size: Metrics.font, weight: .semibold)).monospacedDigit()
            .shadow(color: .black.opacity(0.6), radius: 3)
    }

    private enum Metrics {
        #if os(tvOS)
        static let font: CGFloat = 24, spacing: CGFloat = 22
        #else
        static let font: CGFloat = 13, spacing: CGFloat = 12
        #endif
    }
}

/// The title's logo at the bottom left of the picture, as MiraPlay and Apple TV's player show it (#520, #758): TMDB's,
/// when the video's page found the title there. Only what this device already knows; nothing shows otherwise, since the
/// title is in the top row too.
struct PlayerTitleLogo: View {
    let channel: Channel
    /// A phone held upright: a smaller logo.
    var compact = false
    @Environment(Store.self) private var store
    @State private var tmdb = TMDBLookup()
    @State private var aspect: CGFloat?

    var body: some View {
        #if os(tvOS)
        let box = CGSize(width: 440, height: 120)
        #else
        let box = compact ? CGSize(width: 150, height: 40) : CGSize(width: 220, height: 56)
        #endif
        // A view even before there is a logo, so the lookup below runs.
        ZStack(alignment: .bottomLeading) {
            Color.clear.frame(width: 0, height: 0)
            if let logo = tmdb.details?.logo {
                let size = Self.fit(aspect ?? 3, in: box)
                TMDBArtwork(url: logo, maxPixels: 800, fill: false, aspect: $aspect)
                    .frame(width: size.width, height: size.height, alignment: .bottomLeading)
                    .shadow(color: .black.opacity(0.45), radius: 6)
                    .opacity(aspect == nil ? 0 : 1)
                    .animation(.smooth(duration: 0.3), value: aspect == nil)
                    .accessibilityHidden(true)
            }
        }
        .allowsHitTesting(false)
        .task(id: store.catalog(for: channel)?.video.id) {
            guard let catalog = store.catalog(for: channel), TMDBLookup.applies(to: catalog.client.site) else { return }
            _ = await tmdb.prepare(key: TMDBMatchStore.key(source: catalog.client.site.key, video: catalog.video.id))
        }
    }

    /// Wide logos fill the width, tall ones the height.
    static func fit(_ aspect: CGFloat, in box: CGSize) -> CGSize {
        let aspect = max(aspect, 0.5)
        return aspect >= box.width / box.height ? CGSize(width: box.width, height: box.width / aspect)
            : CGSize(width: box.height * aspect, height: box.height)
    }
}
#endif

#if os(tvOS)
/// Whether AVKit's transport bar shows, as its delegate is told: the title row over it shows only then.
@MainActor @Observable final class TransportBarVisibility {
    var visible = false
}

/// Over the transport bar while it shows, as on iPhone (#758, #520): the title's logo on the left, beside the scrubber's
/// buttons, and the video's tags on the right, over those buttons. It draws in the content overlay, under AVKit's
/// controls and menus, and takes no focus.
struct TVPlayerTitleRow: View {
    let channel: Channel
    let session: PlaybackSession
    let transportBar: TransportBarVisibility

    var body: some View {
        let shows = transportBar.visible && session.showsPicture && session.error == nil
        ZStack {
            PlayerTitleLogo(channel: channel)
                .padding(.bottom, Metrics.logoBottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            PlaybackBadges(session: session, active: shows)
                .padding(.bottom, Metrics.tagsBottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 80)
        .opacity(shows ? 1 : 0)
        .animation(.easeInOut(duration: 0.3), value: shows)
        .allowsHitTesting(false)
    }

    /// From the screen's foot (the overlay ignores the safe area): AVKit's button row over the scrubber spans about
    /// 215 to 280 points up, inside the 80-point title-safe sides.
    private enum Metrics {
        static let logoBottom: CGFloat = 230, tagsBottom: CGFloat = 296
    }
}
#endif

/// Reads what `PlaybackInfo` holds from the playing item: the info panel and the tags over the seek bar each keep one
/// and ask it once a second while they show.
@MainActor final class PlaybackInfoSampler {
    private let formats = PlaybackFormats()

    /// Nil while the item changes under the read; an empty info without an item.
    func sample(_ session: PlaybackSession) async -> PlaybackInfo? {
        guard let item = session.player.currentItem else { return PlaybackInfo() }
        let tracks = item.tracks.filter(\.isEnabled)
        let video = tracks.first { $0.assetTrack?.mediaType == .video }
        let audio = tracks.first { $0.assetTrack?.mediaType == .audio }
        let picture = await formats.describe(video?.assetTrack)
        let sound = await formats.describe(audio?.assetTrack)
        guard !Task.isCancelled, session.player.currentItem === item else { return nil }
        var next = PlaybackInfo()
        let size = item.presentationSize
        next.width = Int(size.width.rounded()); next.height = Int(size.height.rounded())
        if next.width == 0 || next.height == 0 { next.width = picture?.width ?? 0; next.height = picture?.height ?? 0 }
        next.videoCodec = picture?.codec
        next.transferFunction = picture?.transferFunction
        next.hardwareDecoding = picture?.codec.map(Self.decodesInHardware)
        next.dolbyVisionProfile = picture?.dolbyVisionProfile
        if let asset = item.asset as? AVURLAsset { next.droppedDolbyVisionProfile = Remux.droppedDolbyVision(asset.url) }
        // The track's own rate; the measured one (a stream that declares none) wanders around it. A streamed MP4 can
        // declare about 1 fps (a 4K drama showed "1FPS"): no video plays that slowly, so then the measured one.
        let measured = Double(video?.currentVideoFrameRate ?? 0)
        let declaredRate = picture?.frameRate.flatMap { $0 >= 5 ? $0 : nil }
        next.frameRate = declaredRate ?? (measured > 0 ? measured : nil)
        // Smooth Motion's in-between frames reach the screen at its grid's rate (#519).
        let enhancement = session.enhancer.status
        if enhancement.smoothing {
            let source = enhancement.sourceRate > 0 ? enhancement.sourceRate : next.frameRate ?? 0
            next.smoothedFrameRate = VideoEnhancer.outputRate(source: source, matching: false)
        }
        next.audioCodec = sound?.codec
        next.sampleRate = sound?.sampleRate
        next.channels = sound?.channels
        // The session's measured rate (the variant's, or the decoded media's), else what the file's tracks declare.
        let declared = (picture?.dataRate ?? 0) + (sound?.dataRate ?? 0)
        next.bitrate = session.transfer.required.map { $0 * 8 } ?? (declared > 0 ? declared : nil)
        next.download = session.transfer.bytesPerSecond
        return next
    }

    private static var hardware: [UInt32: Bool] = [:]

    /// Whether VideoToolbox has a hardware decoder for the format here: HEVC and H.264 on every device, AV1 from the
    /// A17 Pro and M3 on. Dolby Vision asks for its base layer's codec.
    static func decodesInHardware(_ code: UInt32) -> Bool {
        if let known = hardware[code] { return known }
        let base: CMVideoCodecType = switch code {
        case 0x6476_6831, 0x6476_6865, 0x6865_7631: kCMVideoCodecType_HEVC   // dvh1, dvhe, hev1
        case 0x6476_6131, 0x6476_6176, 0x6176_6333: kCMVideoCodecType_H264   // dva1, dvav, avc3
        case 0x6461_7631: 0x6176_3031                                        // dav1: AV1 (av01)
        default: code
        }
        let supported = VTIsHardwareDecodeSupported(base)
        hardware[code] = supported
        return supported
    }
}

/// The formats of the tracks playing, loaded once per track: a stream's tracks change only when its variant does.
@MainActor private final class PlaybackFormats {
    struct Format {
        var codec: UInt32?
        var transferFunction: String?
        var width = 0, height = 0
        var frameRate: Double?
        var sampleRate: Double?
        var channels: Int?
        /// Bits per second the track declares.
        var dataRate: Double?
    }
    private var known: [(track: AVAssetTrack, format: Format)] = []

    func describe(_ track: AVAssetTrack?) async -> Format? {
        guard let track else { return nil }
        if let hit = known.first(where: { $0.track === track }) { return hit.format }
        guard let (descriptions, frameRate, dataRate) = try? await track.load(.formatDescriptions, .nominalFrameRate, .estimatedDataRate) else { return nil }
        var format = Format()
        if let description = descriptions.first {
            format.codec = CMFormatDescriptionGetMediaSubType(description)
            format.transferFunction = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            if CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video {
                let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                format.width = Int(dimensions.width); format.height = Int(dimensions.height)
            }
            if let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                format.sampleRate = stream.mSampleRate > 0 ? stream.mSampleRate : nil
                format.channels = stream.mChannelsPerFrame > 0 ? Int(stream.mChannelsPerFrame) : nil
            }
        }
        format.frameRate = frameRate > 0 ? Double(frameRate) : nil
        format.dataRate = dataRate > 0 ? Double(dataRate) : nil
        // The video and audio tracks playing now, and the ones before a variant switch.
        known = Array(([(track, format)] + known).prefix(4))
        return format
    }
}

/// The episode list, as a sheet.
///
/// One view for both hosts — the iPhone's overlay panel and the Mac's window — so the two cannot
/// drift into different pickers. It reads the catalog and the saved context here rather than taking
/// them as parameters, because both hosts already have the `Channel` and nothing else.
private struct CatalogEpisodePanel: View {
    let channel: Channel
    let compact: Bool
    @Environment(Store.self) private var store

    var body: some View {
        if let catalog = store.catalog(for: channel), let context = channel.historyContext {
            // The resume progress and the episode playing now come from the history, so the grid can
            // draw a progress bar on the "resume here" cell and a distinct mark on the one already
            // playing.
            // 按当前环境取：`context.id` 不含环境，同一部片在两个环境都看过时，
            // 裸 `entries` 会取到较新那条 —— 于是 B 环境的选集器画上了 A 环境的进度。
            let history = PlaybackHistory.shared
                .entries(in: PlaybackHistory.shared.activeEnvironmentID)
                .first { $0.id == context.id }
            EpisodePicker(
                video: catalog.video,
                sourceKey: context.sourceKey,
                sourceName: context.sourceName,
                origin: context.origin,
                resumeContext: context,
                resumePosition: channel.resumePosition,
                resumeProgress: history?.progress,
                currentEpisodeID: context.episodeID,
                compact: compact,
                headers: channel.headers
            ) { episode in
                // Close the picker only once the episode actually resolves, not the moment it is tapped:
                // `selectEpisode` resolves asynchronously, and closing here would drop the panel (and the
                // temporary line choice) even when the resolve fails, leaving the viewer to reopen and
                // re-pick. On success the picker closes; on failure it stays open so the choice survives.
                store.selectEpisode(episode, from: channel, success: {
                    store.showsEpisodes = false
                }, failed: { _ in
                    // Keep the panel open; the store's `episodeError` drives the inline notice.
                })
            }
        }
    }
}
