import SwiftUI
import TVCore

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case home = "Watch Now", discover = "Discover", live = "Live TV", music = "Music", manga = "Manga", search = "Global Search", sites = "Sources", files = "Cloud Files", favorites = "Favorites", history = "Playback History", downloads = "Downloads", settings = "Settings", more = "More"
    /// Messages from the website (App/Announcements.swift); only the phone lists it, in More.
    case messages = "Messages"
    /// Apple TV's sidebar item for the song playing, first while one is loaded; it opens the player.
    case nowPlaying = "Now Playing"
    var id: String { rawValue }
    var title: String { L10n.text(rawValue) }
    /// Where Software Update lives: Settings, or More when Settings is folded into it.
    var showsUpdateBadge: Bool { self == .settings || self == .more }
    var icon: String {
        switch self {
        case .home: "play.rectangle.fill"
        case .discover: "safari.fill"
        case .search: "magnifyingglass"
        case .live: "dot.radiowaves.left.and.right"
        case .music: "music.note"
        case .manga: "book.fill"
        case .sites: "square.grid.2x2.fill"
        case .files: "folder.fill"
        case .favorites: "heart.fill"
        case .downloads: "arrow.down.circle.fill"
        case .history: "clock.arrow.circlepath"
        case .settings: "slider.horizontal.3"
        case .messages: "megaphone.fill"
        case .more: "ellipsis"
        case .nowPlaying: "waveform"
        }
    }
}

struct RootView: View {
    @Environment(Store.self) private var store
    /// iPhone（含 Duo 展开态）常驻 `.tabBarOnly`，iPad 常驻 `.sidebarAdaptable`。
    ///
    /// ⛔ 这里**绝不能随「播放页是否打开」切换**。2026-11-09 设备日志实测：
    /// `VideoDetailView.onAppear` 把 `store.watchPageOpen=true` → `onChange` 把
    /// TabView 从 `.sidebarAdaptable` 分支切到 `.tabBarOnly` 分支 —— 两个分支
    /// 是**不同的视图身份**，SwiftUI 会销毁并重建整个 TabView，连带它内部
    /// 的 NavigationStack；刚 push 进来的选集页被立刻 pop，用户的观感就是
    /// 「点开闪一下进双屏又退回来」。页面 `onDisappear` 又把标记置回 false，
    /// 于是再切一次，形成振荡（日志里 `platformTabs onAppear` 会重复打印）。
    ///
    /// 原来切样式的目的是避开 regular width 下 `.sidebarAdaptable` 自动展开的
    /// 侧栏压住右栏；iPhone 常驻 `.tabBarOnly` 后侧栏根本不存在，问题同样解决，
    /// 而且不再有重建。侧栏的隐藏交给详情页自己的
    /// `.setBarVisibility(.hidden, for: .tabBar)`。
    private var phoneTabsWithoutSidebar: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }
    @Environment(Updates.self) private var updates
    @Environment(Announcements.self) private var announcements
    @Environment(\.horizontalSizeClass) private var sizeClass
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #else
    /// tvOS has no vertical size class; `tabSafeArea` ignores it there anyway.
    private var verticalSizeClass: UserInterfaceSizeClass? { nil }
    #endif
    // Untyped so it can hold both More-tab sections and Route pages.
    @State private var morePath = NavigationPath()
    @State private var moreSection: AppSection = .settings
    /// [mi3s] 二开：折展时「因为分区从标签栏掉进 More」而被动跳过去的那一个分区；用户自己点 More
    /// 进去时保持 nil。折叠把 7 格收成 4 格，Sites / Music / Manga 会掉进 More，`store.section` 被改写
    /// 成 `.more`；展开时格子回到 7 个，`inMore` 里已经没有它，于是要把它放回去。没有这个标记就没法
    /// 区分「用户主动停在 More」和「被折展搬过来」，前者不能被拽回去。见 Docs/duo/Duo适配报告.md §二·P2。
    @State private var movedToMoreBySlotChange: AppSection?
    #if os(iOS)
    @AppStorage(PhoneTabs.storageKey) private var storedTabs = ""
    /// Where the in-app mini player has been dragged, so it can sit anywhere on screen like YouTube's.
    @State private var miniDrag = CGSize.zero
    /// The mini player's size multiplier (1.0 = default), pinch to resize. Clamped so it never grows
    /// past the screen nor shrinks to nothing.
    @State private var miniScale: CGFloat = 1.0
    /// The last drag translation, so each `onChanged` adds only the *delta* (跟手) instead of the
    /// cumulative translation from the gesture start, which made it fly across the screen.
    @State private var lastDrag = CGSize.zero
    #endif
    #if os(macOS)
    /// Pushed pages in the detail column. Cleared on section change: the stack keeps them when its root is replaced.
    @State private var detailPath = NavigationPath()
    @State private var nowPlayingShown = false
    @State private var hidesToolbar = false
    #endif
    private var tabs: [AppSection] {
        #if os(iOS)
        if phoneTabs { return PhoneTabs(stored: storedTabs).arranged(slots: barSlots, hiding: store.hiddenSections).bar + [.more] }
        #endif
        #if os(tvOS)
        if !tvMore.isEmpty { return Array(sections.prefix(Self.topBarSlots - 1)) + [.more] }
        #endif
        return sections
    }
    private var sections: [AppSection] {
        #if os(iOS)
        // The iPad's sidebar, in the order set in Settings > Edit Tab Bar (#427).
        return PhoneTabs.sidebar(stored: storedTabs, hiding: store.hiddenSections)
        #else
        let sections = [AppSection.home, .discover, .live, .music, .manga, .search, .sites, .files, .history, .favorites, .downloads, .settings]
            .filter { !store.hiddenSections.contains($0) }
        #if os(tvOS)
        // Where the remote already goes to change section, so the song is one move away from anywhere.
        // Before tvOS 27 the sidebar has no header for the Now Playing card.
        if store.music.track != nil, !MusicSidebarNowPlaying.inSidebarHeader { return [.nowPlaying] + sections }
        #endif
        return sections
        #endif
    }
    #if os(tvOS)
    /// tvOS 17 has no sidebar, only the tab bar along the top, and selecting its eighth or a later tab does
    /// nothing. Past its seventh place, the bar ends in More with the rest, as on iPhone.
    private static let topBarSlots = 7
    private var tvMore: [AppSection] {
        if #available(tvOS 18, *) { return [] }
        return sections.count > Self.topBarSlots ? Array(sections.dropFirst(Self.topBarSlots - 1)) : []
    }
    #endif
    #if os(iOS)
    /// The mini player's Picture in Picture controller, so the small inline picture carries on in a
    /// floating window when the app is left.
    @State private var miniPip = PictureInPicture(adoptsRunningController: false)
    /// The viewer's picture size, shared with the full player.
    @AppStorage(PictureScaling.key) private var pictureScalingRaw = PictureScaling.source.rawValue
    private var pictureScaling: PictureScaling { PictureScaling(rawValue: pictureScalingRaw) ?? .source }
    #endif
    /// A message from the website waits while a video plays or another alert or sheet is up.
    private var messageWaits: Bool {
        var busy = store.playing != nil || store.error != nil || updates.sheet != nil || updates.message != nil || PluginSignIn.shared.prompt != nil
        #if os(tvOS)
        busy = busy || store.music.presentsPlayer
        #endif
        return busy
    }
    var body: some View {
        @Bindable var store = store
        Group {
            #if os(macOS)
            NavigationSplitView {
                MacSidebar()
                    .navigationSplitViewColumnWidth(min: 190, ideal: 216, max: 260)
            } detail: {
                // The music bar floats over every page while a song is loaded, as in Music.
                // The stack stays put across sections. Rebuilding it resets the sidebar column, so a
                // section change collapsed the sidebar while the new page was still a placeholder.
                NavigationStack(path: $detailPath) { content(store.section).musicBar().routeDestinations() }
                    .environment(\.openRoute, RouteOpener { detailPath.append($0) })
            }
            .onChange(of: store.section) { detailPath = NavigationPath() }
            .overlay {
                if nowPlayingShown { MusicMacNowPlaying().ignoresSafeArea().transition(.move(edge: .bottom)) }
            }
            .background { NowPlayingWindowChrome(active: hidesToolbar, store: store) }
            .background { MusicMiniPlayerTrigger() }
            .onChange(of: store.music.presentsPlayer && store.music.track != nil) { _, show in
                // Hiding the toolbar moves the page under it. The player slides up over the window
                // first and the toolbar goes once it is covered; closing brings the toolbar back
                // before the player slides away.
                if show {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.92)) { nowPlayingShown = true } completion: {
                        if nowPlayingShown { hidesToolbar = true }
                    }
                } else {
                    hidesToolbar = false
                    withAnimation(.spring(response: 0.4, dampingFraction: 1)) { nowPlayingShown = false }
                }
            }
            #else
            // The system tab bar on every size class: iOS 26 floats it over content and
            // collapses extra sections into More, which a hand-built bar imitated poorly.
            platformTabs
            #if os(iOS)
                .overlay(alignment: .bottomTrailing) { videoMiniPlayer }
            #endif
            #endif
        }
        .onChange(of: store.section) { _, section in
            if section != .search { store.searchModel.suspend() }
        }
        // A Baidu or Aliyun line waiting for its plugin's sign-in code to be scanned.
        .sheet(item: Binding(get: { PluginSignIn.shared.prompt }, set: { if $0 == nil { PluginSignIn.shared.dismiss() } })) {
            PluginSignInView(prompt: $0)
        }
        #if os(tvOS)
        .fullScreenCover(isPresented: Binding(get: { store.music.presentsPlayer }, set: { store.music.presentsPlayer = $0 })) { MusicPlayerScreen() }
        #endif
        // A video and a song never play over each other. The song stops rather than pausing, so its strip
        // doesn't stay over the video and every page after it (#289); where it was stays saved, and
        // Music's Continue Playing picks it up.
        .onChange(of: store.playing) { _, channel in if channel != nil { store.music.stop() } }
        .modifier(PlayerPresentation(playing: $store.playing))
        #if os(tvOS) || os(macOS)
        // What another device sent, while it opens.
        .overlay { PlayOnIncoming().animation(.spring(duration: 0.4), value: PlayOnController.shared.incoming?.title) }
        #endif
        .updatePresentation(updates, playing: store.playing != nil)
        .announcementPresentation(announcements, blocked: messageWaits)
        .alert(L10n.text("Unable to Complete"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(L10n.text("OK"), role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        // The app-switcher shade lives on the scene in TVBoxApp, not here: it must sit above sheets,
        // the player and every page, and there can be only one. A second one here used to read a
        // dead `hidesInAppSwitcher` key no settings screen ever wrote, so turning the switch off in
        // Settings left this inner shade on and the snapshot stayed covered (2026-11-04).
    }

    #if !os(macOS)
    #if os(iOS)
    /// The phone's tab bar: the tabs the viewer arranged in Settings, then More with the rest. Which screens use
    /// it, and why: `PhoneTabs.inUse`.
    @AppStorage(PhoneTabs.labelsKey) private var showsTabLabels = true
    private var phoneTabs: Bool { PhoneTabs.inUse(horizontal: sizeClass) }
    /// Sections a phone reaches through More, as arranged in the tab bar editor.
    private var inMore: [AppSection] { PhoneTabs(stored: storedTabs).arranged(slots: barSlots, hiding: store.hiddenSections).more }
    private var barSlots: Int { PhoneTabs.slots(horizontal: sizeClass, vertical: verticalSizeClass) }
    #endif
    private var platformTabs: some View {
        tabView
            .onAppear { OneSkinProbe.log("platformTabs onAppear noSidebar=\(phoneTabsWithoutSidebar)") }
            // ⛔ 不要再在这里加 `onChange(of: store.watchPageOpen)` 去切 TabView 样式。
            // 详见 `phoneTabsWithoutSidebar` 的注释：那会把刚 push 进来的选集页直接 pop 掉。
            #if os(tvOS)
            .musicSidebarHeader()
            // Now Playing is not a page: choosing it opens the full-screen player over the section
            // the viewer was in. The sidebar selects on a click, not on focus, so passing it opens nothing.
            .onChange(of: store.section) { previous, section in
                guard section == .nowPlaying else { return }
                store.section = previous == .nowPlaying ? .music : previous
                store.music.presentsPlayer = true
            }
            // tvOS 17: a section in More opens there, whether a button or the Now Playing tab moved it in.
            .onChange(of: store.section) { _, section in openInMore(section) }
            .onChange(of: tvMore) { _, more in
                if more.isEmpty && store.section == .more { store.section = morePath.isEmpty ? .home : moreSection }
                else { openInMore(store.section) }
            }
            #endif
            #if os(iOS)
            .minimizesTabBarOnScroll()
            // 页面标题上的「查看更多 ›」要知道哪些分区被折进了 More：
            // 有独立标签的直接切过去，没有的 push 到本页栈上（Back 才回得来）。
            .environment(\.sectionsInMore, phoneTabs ? inMore : [])
            .musicAccessory(enabled: store.music.showsStrip(videoPlaying: store.playing != nil) && phoneTabs)
            // Opened from the mini player; swiping down closes it, as in Music.
            .sheet(isPresented: Binding(get: { store.music.presentsPlayer }, set: { store.music.presentsPlayer = $0 })) { MusicNowPlayingScreen() }
            .onChange(of: store.section) { _, section in
                if phoneTabs && inMore.contains(section) {
                    // [mi3s] 二开：用户（或一次深链）主动选了一个在 More 里的分区 —— 不是折展搬的。
                    movedToMoreBySlotChange = nil
                    moreSection = section; morePath = NavigationPath([section])
                    store.section = .more
                }
            }
            // Closing iPhone Duo narrows the side bar back to four: a section that just left it opens inside More.
            // Opening it again widens the bar back to seven, and the section returns to the bar — so the page the
            // viewer was on has to come back with it. Without this, closing on Sites and opening again left them
            // on More: `phoneTabs` never changed (a Duo is a phone folded or flat), so the restore below never ran.
            .onChange(of: barSlots) { _, _ in
                if phoneTabs && inMore.contains(store.section) {
                    // Fell out of the bar into More. Remember it was this that moved them, not a tap.
                    movedToMoreBySlotChange = store.section
                    moreSection = store.section; morePath = NavigationPath([store.section]); store.section = .more
                } else if store.section == .more, let moved = movedToMoreBySlotChange, !inMore.contains(moved) {
                    // Back in the bar: put the page back, and leave More as empty as we found it.
                    moreSection = moved
                    morePath = NavigationPath()
                    movedToMoreBySlotChange = nil
                    store.section = moved
                }
            }
            .onChange(of: phoneTabs) { _, phone in
                // [mi3s] 二开：切到/离开手机标签栏都是别的原因，折展搬移的账就此结清。
                movedToMoreBySlotChange = nil
                if !phone && store.section == .more { store.section = morePath.isEmpty ? .settings : moreSection }
                else if phone && inMore.contains(store.section) {
                    moreSection = store.section; morePath = NavigationPath([store.section]); store.section = .more
                }
            }
            #endif
    }

    #if os(iOS)
    /// The floating mini player after the watch page closes while the video keeps playing, so the
    /// viewer can still get back to it. Tap to reopen full screen; ✕ stops playback. Leaving the app
    /// here carries on in Picture in Picture (the inline layer's controller starts it automatically).
    @ViewBuilder private var videoMiniPlayer: some View {
        // [mi3s] 二开：只认「用户在视频控件里按了缩成小窗」。原来只判断「不在观看页」，
        // 于是折叠 / 展开 / 换向 / 切页面都会把小窗拱出来。
        if let channel = store.playing, store.floatsInMiniPlayer(channel), !store.presentingPlayer {
            GeometryReader { geo in
                // YouTube-style in-app player: sized to the screen, pinch-to-resize and draggable to
                // any corner. Landscape gets a wider picture; portrait a bit over half the width.
                let landscape = geo.size.width > geo.size.height
                let baseWidth = landscape ? min(geo.size.width * 0.34, 320) : min(geo.size.width * 0.62, 240)
                // Pinch scales the whole thing; clamp so it can't outgrow the screen or vanish.
                let width = min(max(baseWidth * miniScale, 120), geo.size.width - 24)
                let session = store.playbackSession(for: channel)
                // The card takes the stream's own shape instead of a fixed 16:9: a 4:3 or 2.35:1 film
                // in a 16:9 card is either cropped or padded, and the card is too small to afford either.
                let sourceSize = session.player.currentItem?.presentationSize ?? .zero
                let ratio = sourceSize.width > 0 && sourceSize.height > 0 ? sourceSize.width / sourceSize.height : 16.0 / 9
                let height = width / (ratio.isFinite && ratio > 0.2 && ratio < 6 ? ratio : 16.0 / 9)
                VStack(alignment: .leading, spacing: 0) {
                    PlayerLayerView(player: session.player, gravity: pictureScaling.gravity, pip: miniPip)
                        .frame(width: width, height: height).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        // Both controls live in the picture's corners, and the bar below carries the
                        // name alone: a row of buttons under a 16:9 thumbnail turns the picture into
                        // the smaller half of the card, which is what made the video hard to see.
                        .overlay(alignment: .topLeading) {
                            Button { session.togglePlayback() } label: {
                                Image(systemName: session.paused ? "play.fill" : "pause.fill")
                                    .contentTransition(.symbolEffect(.replace))
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(.black.opacity(0.5), in: Circle())
                                    // A hairline, or the button vanishes over a dark frame.
                                    .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(session.paused ? "Play" : "Pause"))
                            .padding(6)
                        }
                        .overlay(alignment: .topTrailing) {
                            Button {
                                store.stopPlaying()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(.black.opacity(0.5), in: Circle())
                                    .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Stop"))
                            .padding(6)
                        }
                        .onChange(of: channel, initial: true) { _, playingChannel in
                            let session = store.playbackSession(for: playingChannel)
                            // Sync the current PiP state at once, not just the callback: the mini player can be
                            // rebuilt (returning from full screen, a Duo fold) while PiP is already active, and a
                            // rebuild only re-runs onAppear — it never re-fires onActiveChange. Left unset, the queue
                            // would advance inside the floating window, where AVKit's queued advance is unreliable.
                            session.queueingDisabled = miniPip.active || PictureInPicture.isActive
                            miniPip.onActiveChange = { session.queueingDisabled = $0 }
                            // The floating mini player has no `PlaybackView`, so nothing else starts the session
                            // when `store.playing` moves on (auto-advance, series suggestion) or when playback begins
                            // straight from a Home/Search card. Start it here, once per channel.
                            if !session.isPlaying(playingChannel) { startCatalogPlayback(session, channel: playingChannel, store: store) }
                        }
                    Text(channel.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(width: width, alignment: .leading)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)) }
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onTapGesture {
                    // [mi3s] 二开：点小窗回到 **One 选集页**，而不是旧全屏播放器。
                    // 原来无条件 `presentingPlayer = true`，于是从皮肤页缩成小窗再点回来，
                    // 皮肤就丢了（换成了上游播放器）。现在按目录把那一页重新压进当前分区栈；
                    // 目录里查不到（云文件 / 直播之类没有详情页）时才退回旧播放器。
                    if let catalog = store.catalog(for: channel) {
                        store.pendingRoute = Route {
                            AnyView(VideoDetailView(video: catalog.video, client: catalog.client))
                        }
                    } else {
                        store.presentingPlayer = true
                    }
                }
                .offset(miniDrag)
                // Drag moves it by the *delta* each frame (跟手), not the cumulative translation, which
                // made a slow finger send it flying. Pinch resizes around 1.0.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let delta = CGSize(width: value.translation.width - lastDrag.width,
                                               height: value.translation.height - lastDrag.height)
                            lastDrag = value.translation
                            miniDrag.width += delta.width
                            miniDrag.height += delta.height
                        }
                        .onEnded { _ in
                            lastDrag = .zero
                            // Snap back inside the safe area so it never parks off-screen.
                            let halfW = width / 2, halfH = (height + 38) / 2
                            let minX = -geo.size.width / 2 + halfW + 8
                            let maxX = geo.size.width / 2 - halfW - 8
                            let minY = -geo.size.height / 2 + halfH + 8
                            let maxY = geo.size.height / 2 - halfH - 8
                            let x = min(max(miniDrag.width, minX), maxX)
                            let y = min(max(miniDrag.height, minY), maxY)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { miniDrag = CGSize(width: x, height: y) }
                        }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            miniScale = min(max(value, 0.5), 2.5)
                        }
                        .onEnded { value in
                            miniScale = min(max(value, 0.5), 2.5)
                        }
                )
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomTrailing)
                .padding(12)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
    #endif

    @ViewBuilder private var tabView: some View {
        @Bindable var store = store
        if #available(iOS 18, tvOS 18, *) {
            // iPhone（含 Duo 展开）固定 `.tabBarOnly`，iPad 固定 `.sidebarAdaptable`。
            //
            // ⛔ 分支条件必须是**设备形态常量**，不能是「播放页是否打开」。
            // 之前按 `sidebarCollapsed` 切：页面 onAppear 置 true 的瞬间 TabView
            // 被销毁重建，内部 NavigationStack 一起没，刚 push 的选集页被 pop，
            // onDisappear 又置回 false 再重建一次 —— 就是「闪一下又退回来」。
            //
            // 两种样式类型不同，不能写三元；分支本身留着，但条件永不变，
            // SwiftUI 就不会重新生成视图身份，导航栈得以保住。
            let _ = OneSkinProbe.log("tabView branch noSidebar=\(phoneTabsWithoutSidebar)")
            if phoneTabsWithoutSidebar {
                TabView(selection: $store.section) {
                    ForEach(tabs) { item in
                        Tab(value: item) { tabPage(item) } label: { tabLabel(item) }
                            #if os(iOS)
                            .badge(tabBadge(item))
                            #endif
                    }
                }
                .tabViewStyle(.tabBarOnly)
            } else {
                TabView(selection: $store.section) {
                    ForEach(tabs) { item in
                        Tab(value: item) { tabPage(item) } label: { tabLabel(item) }
                            #if os(iOS)
                            .badge(tabBadge(item))
                            #endif
                    }
                }
                .tabViewStyle(.sidebarAdaptable)
            }
        } else {
            // tvOS 17 and iOS 17 have no Tab or sidebar: the classic tab bar, along the top on Apple TV and at the
            // bottom on iPad too.
            TabView(selection: $store.section) {
                ForEach(tabs) { item in
                    tabPage(item).tabItem { tabLabel(item) }.tag(item)
                        #if os(iOS)
                        .badge(tabBadge(item))
                        #endif
                }
            }
        }
    }

    @ViewBuilder private func tabPage(_ item: AppSection) -> some View {
        if item == .more {
            NavigationStack(path: $morePath) {
                content(.more).routeDestinations()
                    // Any section can be moved into More, so any can be pushed here.
                    .navigationDestination(for: AppSection.self) { content($0).tvDefaultControls().tabSafeArea(sizeClass, vertical: verticalSizeClass) }
                    .tabSafeArea(sizeClass, vertical: verticalSizeClass)
            }
            .environment(\.openRoute, RouteOpener { morePath.append($0) })
        } else {
            RouteStack(item) { content(item).tvDefaultControls().tabSafeArea(sizeClass, vertical: verticalSizeClass) }
        }
    }

    #if os(tvOS)
    private func openInMore(_ section: AppSection) {
        guard tvMore.contains(section) else { return }
        moreSection = section; morePath = NavigationPath([section]); store.section = .more
    }
    #endif

    @ViewBuilder private func tabLabel(_ item: AppSection) -> some View {
        #if os(tvOS)
        if item == .nowPlaying { MusicTabLabel() } else { Label(item.title, systemImage: item.icon) }
        #else
        // Only the title changes, so the tab bar updates in place; VoiceOver still reads the name.
        Label { Text(phoneTabs && !showsTabLabels ? "" : item.title) } icon: { Image(systemName: item.icon) }
            .accessibilityLabel(item.title)
        #endif
    }

    #if os(iOS)
    // tvOS tab bars have no badges; there the launch sheet and Settings carry the news.
    private func tabBadge(_ item: AppSection) -> Text? {
        showsUpdateBadge(item) && !updates.available.isEmpty ? Text(L10n.text("New")) : nil
    }

    /// Software Update lives in Settings, so More carries the badge only while Settings is inside it.
    private func showsUpdateBadge(_ item: AppSection) -> Bool {
        item == .more ? phoneTabs && inMore.contains(.settings) : item.showsUpdateBadge
    }
    #endif
    #endif


    @ViewBuilder private func content(_ section: AppSection) -> some View {
        #if DEBUG
        if QALaunch.overrides(section) {
            QALaunch.page(for: section, store: store).sectionMarker(section)
        } else {
            sectionRoot(section).sectionMarker(section)
        }
        #else
        sectionRoot(section).sectionMarker(section)
        #endif
    }

    @ViewBuilder private func sectionRoot(_ section: AppSection) -> some View {
        switch section {
        case .home: HomeView()
        case .discover: DiscoverView()
        case .search: GlobalSearchView()
        case .live: LiveView()
        case .music: MusicView()
        case .manga: MangaView()
        case .sites: SitesView()
        case .files: CloudFilesView()
        case .favorites: FavoritesView()
        case .downloads: DownloadsView()
        case .history: PlaybackHistoryView()
        case .settings: SettingsView()
        case .messages: MessagesView()
        case .nowPlaying: EmptyView()
        case .more:
            // Only the phone's tab bar and tvOS 17's have a More tab.
            #if os(iOS)
            MoreView()
            #elseif os(tvOS)
            TVMoreView(sections: tvMore)
            #else
            EmptyView()
            #endif
        }
    }
}

#if os(tvOS)
/// tvOS 17's More tab: the sections that did not fit in its tab bar.
private struct TVMoreView: View {
    let sections: [AppSection]
    var body: some View {
        List(sections) { section in
            NavigationLink(value: section) { Label(section.title, systemImage: section.icon) }
        }
        // The rows at Settings' width on the app's navy canvas, instead of the system's grey across the screen.
        .frame(maxWidth: Layout.settingsWidth)
        .frame(maxWidth: .infinity)
        .background { Backdrop() }
        .navigationTitle(AppSection.more.title)
    }
}
#endif

#if !os(macOS)
/// What the player cover shows; the same presentation whichever channel it holds.
private struct PlayerSlot: Identifiable {
    let channel: Channel
    var id: String { "player" }
}
#endif

private struct PlayerPresentation: ViewModifier {
    @Environment(Store.self) private var store
    @Binding var playing: Channel?
    #if os(macOS)
    @State private var playerWindow = PlayerWindowController()
    #endif
    func body(content: Content) -> some View {
        #if os(macOS)
        content.onChange(of: playing, initial: true) { _, channel in
            if let channel {
                playerWindow.present(channel, store: store) { playing = nil }
            } else {
                playerWindow.close()
            }
        }
        #else
        // One presentation while anything plays: the next episode replaces the channel inside the player.
        // Keyed by the channel, every change dismissed the player and presented a new one, so even a
        // queued episode would stop and load.
        // An iPhone watch page plays its own video at the top of the page (`VideoDetailView`).
        content.fullScreenCover(item: Binding(
            get: { (store.playsInWatchPage(playing) || !store.presentingPlayer) ? nil : playing.map(PlayerSlot.init) },
            set: { if $0 == nil { store.presentingPlayer = false } }
        )) {
            // Handed in: the iPad app on a Mac presents a full-screen cover without the presenter's environment
            // objects, and every video stopped the app there ("No Observable object of type Store found").
            PlaybackView(channel: $0.channel, session: store.playbackSession(for: $0.channel)).environment(store)
        }
        #endif
    }
}

#if os(macOS)
/// Content-first sidebar: grouped rows, neutral selection, and ⌘1–⌘8 to switch sections.
private struct MacSidebar: View {
    @Environment(Store.self) private var store
    @Environment(Updates.self) private var updates
    private var groups: [(title: String, items: [AppSection])] {
        let groups: [(title: String, items: [AppSection])] = [(L10n.text("Browse"), [.home, .discover, .search, .live, .music, .sites, .files]),
                                                             (L10n.text("Library"), [.history, .favorites, .downloads, .settings])]
        return groups.map { (title: $0.title, items: $0.items.filter { !store.hiddenSections.contains($0) }) }
    }

    var body: some View {
        let ordered = groups.flatMap(\.items)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10).padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.items) { item in
                            SidebarRow(section: item, selected: store.section == item,
                                       badge: item.showsUpdateBadge && !updates.available.isEmpty,
                                       shortcut: (ordered.firstIndex(of: item).map { $0 + 1 }).flatMap { $0 < 10 ? Character(String($0)) : nil }) {
                                store.section = item
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 12)
        }
        .scrollIndicators(.never)
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarStatus() }
    }
}

private struct SidebarRow: View {
    let section: AppSection
    let selected: Bool
    var badge = false
    /// ⌘1–⌘9; sections past the ninth have none.
    let shortcut: Character?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(width: 20)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if badge { NewBadge() }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.11 : (hovering ? 0.05 : 0)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.15), value: hovering)
        .keyboardShortcut(shortcut.map { KeyboardShortcut(KeyEquivalent($0), modifiers: .command) })
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
#endif

struct SidebarStatus: View {
    /// "Version 1.0 (1)"; nil when the bundle carries no version (e.g. MARKETING_VERSION unset).
    private var version: String? {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty else { return nil }
        let build = info?["CFBundleVersion"] as? String ?? ""
        let text = L10n.text("Version %@", short)
        return build.isEmpty || build == short ? text : "\(text) (\(build))"
    }
    var body: some View {
        if let version {
            Text(version)
                .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).frame(height: 40)
                .overlay(alignment: .top) { Divider().padding(.horizontal, 12) }
                .selectable()
        }
    }
}

/// A pushed page carried as a navigation-path value. View-destination `NavigationLink`s are not
/// recorded in a stack's path, so they survive clearing it; inside NavigationSplitView that left a
/// detail page covering the newly selected sidebar section.
struct Route: Hashable, @unchecked Sendable {
    private let id = UUID()
    let build: @MainActor () -> AnyView
    static func == (lhs: Route, rhs: Route) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Drop-in for `NavigationLink(destination:label:)` that pushes through the stack's path.
struct RouteLink<Label: View>: View {
    private let route: Route
    private let label: Label
    #if os(macOS)
    @Environment(\.stripDrag) private var drag
    @Environment(\.openRoute) private var openRoute
    #endif
    init<Destination: View>(@ViewBuilder destination: @escaping @MainActor () -> Destination, @ViewBuilder label: () -> Label) {
        route = Route { AnyView(destination()) }
        self.label = label()
    }
    var body: some View {
        #if os(macOS)
        // In a strip the link under the pointer gets the mouse-up that ends a drag, which must not open it.
        if let drag, let openRoute {
            Button { if !drag.active { openRoute(route) } } label: { label }
        } else {
            NavigationLink(value: route) { label }
        }
        #else
        NavigationLink(value: route) { label }
        #endif
    }
}

extension EnvironmentValues {
    /// Pushes a page onto the enclosing stack's path. A page opened with `navigationDestination(item:)` is not on the
    /// path, so a `RouteLink` on it pushed underneath it: the new page only showed after Back.
    @Entry var openRoute: RouteOpener? = nil
}

/// A tab's stack, with its own path so pages can be pushed from code (`openRoute`).
private struct RouteStack<Root: View>: View {
    @Environment(Store.self) private var store
    /// 这个栈属于哪个分区。全局请求（`store.pendingRoute`，如小窗点回来）只交给
    /// **当前分区**的栈，否则每个分区的栈都会压一页。
    let section: AppSection
    @State private var stack = RoutePath()
    private let root: Root
    init(_ section: AppSection, @ViewBuilder root: () -> Root) {
        self.section = section
        self.root = root()
    }
    var body: some View {
        @Bindable var stack = stack
        NavigationStack(path: $stack.path) { root.routeDestinations() }
            .environment(\.openRoute, stack.opener)
            .onChange(of: store.pendingRoute) { _, route in
                guard let route, store.section == section else { return }
                stack.opener(route)
                store.pendingRoute = nil
            }
    }
}

/// A stack's path, and the one `openRoute` that pushes onto it for the stack's whole life.
@MainActor @Observable private final class RoutePath {
    var path = NavigationPath()
    /// 已经在栈上的页数。用来**防止同一页被压两次**。
    ///
    /// 现象：详情页的控制栏在画面上出现两遍（两行「倍速 1x / 循环 / 适应 / 自动·线路1」），
    /// 而且两套里的数据源不一致 —— 日志 `detail loaded: eps=1` 之后，
    /// `detailColumn ... eps=0` 交替出现，右栏的「合集」行因此时有时无、
    /// 选集按钮点不到。原因就是 `NavigationLink` 被触发两次（连点 / 手势重复识别），
    /// 同一条路径上压了两个 `VideoDetailView`：上层那份的 `detail` 还是 nil，
    /// 渲染出空壳；下层那份才有数据。两份叠在一起，视觉上就是控件画了两遍。
    ///
    /// `Route` 每次构造都带新的 UUID，`==` 判不出来，所以只能在压栈这一层按
    /// 「是否已有压栈页」拦住第二次。
    @ObservationIgnored private(set) lazy var opener = RouteOpener { [weak self] route in
        guard let self else { return }
        // 已经有页在栈上就不再压：翻页一律走 path 自身的替换语义，
        // 而不是把新页盖在旧页上面（那会留下一个数据未加载的空壳）。
        //
        // ⛔ 用 `path.count` 判，**不要自己维护计数器**。
        // 曾经写过 `var depth = 0` + `depth += 1`，配一个 `popped()` 打算在出栈时减回去 ——
        // 但 `popped()` 没有任何调用点（忘了接），`depth` 一旦变 1 就永不归零，
        // 后果比原 bug 更重：**从详情页退回列表后，再也打不开任何详情页**。
        // `NavigationPath` 自己就知道栈里有几页，直接读它，天然自洽、不会漏减。
        guard path.count == 0 else { return }
        path.append(route)
    }
}

/// Pushes a page onto a stack's path (`openRoute`). An object rather than a closure: SwiftUI can't compare closures,
/// so one in the environment was a new value on every update and every pushed page updated with it. On tvOS 27 an
/// alert or sheet over a pushed page then kept the stack updating forever and froze the app (#272).
@MainActor final class RouteOpener {
    private let push: @MainActor (Route) -> Void
    init(_ push: @escaping @MainActor (Route) -> Void) { self.push = push }
    func callAsFunction(_ route: Route) { push(route) }
}

extension View {
    /// Registers `Route` pages; apply once at the root of every NavigationStack.
    func routeDestinations() -> some View {
        #if os(macOS) || os(tvOS)
        modifier(MacRouteDestinations())
        #else
        navigationDestination(for: Route.self) { route in
            PushedRouteTabSafeArea { route.build() }
        }
        #endif
    }

    /// The iOS 26 floating tab bar sits over the scroll content instead of reserving a strip, so a
    /// page's last row would sit under it. On iOS 26 the system still reports the home-indicator
    /// inset (34pt) — the floating Liquid Glass capsule does *not* publish its own height, because it
    /// overlays the content rather than widening the safe area. So the last row (and any footer text
    /// under it) needs an explicit extra reserve on top of that 34pt, sized by width class:
    ///  • compact width — the phone's bottom capsule. A literal padding on top of the system inset
    ///    double-counts and leaves a dead strip, so fade the content as it slides under and let the
    ///    system 34pt inset hold the final row clear of the capsule.
    ///  • regular width — the Duo's inner display and iPads. The wider floating dock tops out ~57pt
    ///    off the bottom, so 34pt alone leaves the last row (and the copyright footer under it)
    ///    caught under the dock's upper lip. Reserve extra with safeAreaPadding so the footer clears
    ///    the dock. 24pt was not enough — the copyright line sits ~28pt under "Last checked" and was
    ///    still clipped by the dock (measured with PIL row-scanning, 2026-11-05); 88pt clears it with
    ///    a little air to spare.
    @ViewBuilder func tabSafeArea(_ horizontal: UserInterfaceSizeClass? = nil, vertical: UserInterfaceSizeClass? = nil) -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            if horizontal == .regular {
                safeAreaPadding(.bottom, 88)
            } else if vertical == .regular {
                // The phone's bottom capsule, on a screen held upright (compact × regular): the floating
                // Liquid Glass capsule overlays the scroll content (it does not widen the safe area, so the
                // system's 34pt home-indicator inset is all a plain ScrollView gets). The capsule's top lip
                // sits ~24pt above that inset, so the last row (and any footer under it) is caught under the
                // glass and its text is clipped mid-line. Reserve the gap with safeAreaPadding so the
                // ScrollView's last row scrolls clear of the capsule; the reserve is transparent, so the
                // content still slides under the glass and reads through it rather than stopping at a hard
                // edge.
                //
                // [mi3s] 二开：OneSkin 皮肤开着时**不要**这条白色渐隐。渐隐用的是
                // `Color(.systemBackground)`（浅色模式 RGB 240），竖屏播放页底部 80pt
                // 的系统白渐变压在 One 的深色海报底上 —— 用户报的「竖屏底部白色
                // 渐隐图层」。皮肤自带整页海报取色底（OneSkinBackdropLayer），
                // 它需要的正是「底部渐近黑」，这条浅色渐变与它直接冲突。
                // 皮肤状态是全局 UserDefaults 开关，这里直读即可（不引入环境依赖）。
                // ⛔ 默认值语义：AppStorage(wrappedValue: true) 在键**从未写过**时也是
                // true，而 UserDefaults.bool(forKey:) 读未写入键返回 false —— 两个
                // 默认值不一致会让「全新安装 + 从没进过设置页」的用户读出 false，
                // 白渐隐照样挂回来。必须用 object(forKey:) 判「写过没」。
                let skinOn = (UserDefaults.standard.object(forKey: "oneSkinEnabled") as? Bool) ?? true
                if skinOn {
                    safeAreaPadding(.bottom, 40)
                } else {
                    safeAreaPadding(.bottom, 40)
                    .overlay(alignment: .bottom) {
                        LinearGradient(stops: [.init(color: .clear, location: 0),
                                               .init(color: Color(.systemBackground), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 80)
                            .allowsHitTesting(false)
                            .ignoresSafeArea(edges: .bottom)
                    }
                }
            } else {
                // compact × compact (the iPhone Duo's folded *outer* display held sideways) is left alone:
                // the system's narrow bottom capsule is an awkward fit there and the fade reads as a white
                // smear across a landscape that was never meant to carry a phone's bottom bar.
                //
                // [mi3s] 二开：这一支必须有，且必须 `self`。`tabSafeArea` 是 `@ViewBuilder`，先前这里是
                // 一句注释、没有 else —— compact × compact 下两个分支都不命中，函数返回的是 `EmptyView`，
                // 而它被 `.tabSafeArea(...)` 挂在每个 tab 页的根上，于是整页（含 Home）被替换成空视图：
                // 只剩系统侧边标签栏胶囊，内容区一片纯白 `255,255,255`。这不是布局算错，是页面压根没被
                // 构建。见 Docs/duo/Duo适配报告.md §一。
                self
            }
        } else {
            safeAreaPadding(.bottom)
        }
        #else
        self
        #endif
    }
}

/// Pushed pages keep the iOS 26 floating tab bar (the capsule overlays a `NavigationStack`'s pushed
/// content just as it overlays a tab's root), so their last row is caught under the glass too. This
/// wrapper reads the current size class and applies the same bottom reserve as `tabSafeArea`, once, for
/// every `Route` page — instead of sprinkling the fix across every pushed view.
private struct PushedRouteTabSafeArea<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontal
    @Environment(\.verticalSizeClass) private var vertical
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.tabSafeArea(horizontal, vertical: vertical)
    }
}

extension View {
    /// Names the section a page belongs to, so an acceptance test can tell "the section opened" from
    /// "some window is on screen".
    ///
    /// Without it every section assertion reduces to `windows.count > 0`, which Home satisfies — the
    /// phone's tab bar draws Home first while a deep link is still landing, so `收藏` and `下载`
    /// photographed Home and the run passed anyway (2026-11-04).
    func sectionMarker(_ section: AppSection) -> some View {
        accessibilityIdentifier("section.\(section.rawValue)")
    }
}

#if os(macOS) || os(tvOS)
/// Pushed pages get `openRoute` too: the environment set on the detail stack reaches its root page, not the pages its
/// destinations build, so a page opened from code (Discover's search, a person from it) pushed nothing.
private struct MacRouteDestinations: ViewModifier {
    @Environment(\.openRoute) private var openRoute
    func body(content: Content) -> some View {
        #if os(macOS)
        content.navigationDestination(for: Route.self) { $0.build().musicBar().environment(\.openRoute, openRoute) }
        #else
        content.navigationDestination(for: Route.self) { $0.build().environment(\.openRoute, openRoute) }
        #endif
    }
}
#endif

// ===== 上游 225 提交新增：从页面标题打开分区的三个符号 =====
struct SectionPage: View {
    let section: AppSection
    var body: some View {
        switch section {
        case .home: HomeView()
        case .discover: DiscoverView()
        case .search: GlobalSearchView()
        case .live: LiveView()
        case .music: MusicView()
        case .manga: MangaView()
        case .sites: SitesView()
        case .files: CloudFilesView()
        case .favorites: FavoritesView()
        case .downloads: DownloadsView()
        case .history: PlaybackHistoryView()
        case .settings: SettingsView()
        case .messages: MessagesView()
        case .nowPlaying, .more: EmptyView()
        }
    }
}

extension EnvironmentValues {
    /// The sections the phone's tab bar leaves to More. Empty where every section has a tab or a sidebar row.
    @Entry var sectionsInMore: [AppSection] = []
}

/// Opens a section from a heading on a page, such as Watch Now's "Continue Watching ›". A section with a tab of its own is
/// selected. One the phone keeps in More is pushed onto the page's own stack, so Back returns to the page: selecting it
/// moved the app to the More tab with the section on top, and Back from there landed on More's list (#700).
@MainActor struct SectionOpener: DynamicProperty {
    @Environment(Store.self) private var store
    @Environment(\.openRoute) private var openRoute
    @Environment(\.sectionsInMore) private var inMore
    func callAsFunction(_ section: AppSection) {
        if inMore.contains(section), let openRoute {
            openRoute(Route { AnyView(SectionPage(section: section).tvDefaultControls()) })
        } else {
            store.section = section
        }
    }
}
