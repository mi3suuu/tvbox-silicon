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
                .overlay(alignment: .bottomTrailing) {
                    // 前台已经在演的时候不画坞里的卡片 —— 否则两层视频叠在一起。
                    // 用 `opacity` 而不是 `if`：坞里的任务不能因为「这一帧被前台盖住」
                    // 而被销毁重建（那会把正在播的 AVPlayer 一起丢掉，切回来要重新缓冲）。
                    videoMiniPlayer
                        .opacity(store.videoTasks.showsCards(coveredByForeground: dockCoveredByForeground) ? 1 : 0)
                        .allowsHitTesting(store.videoTasks.showsCards(coveredByForeground: dockCoveredByForeground))
                }
                // ⛔ 坞的**管理入口**：只要有任务就常驻，与「卡片画不画」无关。
                //
                // 用户报「进入播放页迷你小窗就消失了，误触也没了」——
                // 卡片让位是对的（两层视频叠一起会穿帮），但没有入口能把它叫回来，
                // 屏幕上就没有任何东西证明「这里还有几集在播」。
                //
                // 位置贴右下角但**在坞卡片之上**（后加 = 更上层），
                // 这样卡片被隐藏时它是唯一可见的东西，卡片显示时它叠在角落也不挡内容。
                .overlay(alignment: .bottomTrailing) {
                    if store.videoTasks.showsHandle(coveredByForeground: dockCoveredByForeground) {
                        DockHandleButton(coveredByForeground: dockCoveredByForeground)
                            .padding(12)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                // 管理器：悬浮列表，不 push 页面（坞的意义就是不打断当前操作）。
                .overlay(alignment: .topTrailing) {
                    if store.videoTasks.showsManager {
                        DockManagerPanel()
                            .padding(.top, 8).padding(.trailing, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            #endif
            #endif
        }
        .onChange(of: store.section) { _, section in
            if section != .search { store.searchModel.suspend() }
        }
        // 增删改代理之后必须重算路由。
        //
        // ⛔ 源的「经代理」不是请求时决定的，而是合并订阅时把 `api` 改写成
        //    `http://127.0.0.1:<port>/p/<proxyID>/…`。不重算就还是原来的直连地址 ——
        //    观众配好 Loon、回到源页点播放，连接却从本机直接出去，
        //    Loon 那边只看到临时端口。用户报的「设置好了 Loon 但没按我们规定好的端口连接」
        //    有一半是这条：`customProxy.touch()` 以前没有任何观察者。
        .onChange(of: store.customProxy.revision) { _, _ in
            // 改了代理就重新给中继一次机会：否则冷启动那两次失败之后，这一轮里加的新代理
            // 要等下次启动才生效（观众看到的是「配了但没反应」）。
            store.resetRelayStartBudget()
            store.rebuildSubscription()
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
        // ⛔ 这里**不要**再挂 `.globalSwipeBack()`。
        //
        // 它原来挂在本文件的这个 `Group` 上（TabView 外层），而那层拿不到
        // `UINavigationController`，`GlobalSwipeBack.arm()` 第一句 guard 就返回 ——
        // 整条需求等于没实现。现在挂到每个分区的 `RouteStack` 里（见该处注释）。
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
    /// ⛔ 槽位必须**形态无关**，否则切形态会崩。
    ///
    /// 实测崩溃（真机 Duo，2026-11-12 01:35–01:36，3 次）：
    ///   -[__NSArrayM insertObject:atIndex:]            ← 越界插入
    ///   -[UITabBarController _tabs_rebuildTabBarItemsAnimated:]
    ///   std::__terminate → abort（SIGABRT）
    ///
    /// 成因：`PhoneTabs.slots` 按 sizeClass 返回 4 或 5，而 `tabs` 数组由它派生；
    /// Duo 放/合时 sizeClass 在 `compact×compact` ↔ `regular×regular` 之间切换，
    /// `tabs` 长度随之变化，`UITabBarController` 在重建 items 的 block 里
    /// 按旧长度插入新项 → NSRangeException。
    ///
    /// 系统 TabBar 不支持运行中改变项数。槽位固定成 `barSlots`（4+更多），
    /// 宽屏少显示的那一项改由 `.sidebarAdaptable` 自然收纳，不再改数组长度。
    private var barSlots: Int { PhoneTabs.barSlots }
    #endif
    private var platformTabs: some View {
        tabView
            .onAppear {
                #if os(iOS)
                // `OneSkinProbe` 属 OneSkin 文件簇（整体只在 iOS 编译）；tvOS 不要这段调试日志。
                OneSkinProbe.log("platformTabs onAppear noSidebar=\(phoneTabsWithoutSidebar)")
                #endif
            }
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
    /// 迷你播放器**坞**：观看页/全屏里缩下来的那一集，以及长按海报直接起播的那些，
    /// 全都挂在这里。点一张回它那一集的选集页；✕ 只停那一个。
    ///
    /// 与上一版的差别（用户 2026-11-11 的要求 5）：
    ///   · 上一版是「一张卡片 + 一个 `store.playing`」，全应用只能有一个小窗；
    ///   · 现在是 `store.videoTasks.tasks` 一列，可以同时挂多个、随时切换回任意一个。
    ///
    /// 拖动与缩放的钳制仍按容器尺寸变化重算一次：合盖 466×678 ⇄ 展开 669×951 时
    /// `geo.size` 会变，不重钳的话在外屏拖到右下角的小窗，展开后会跑到屏外。
    /// 坞里有任务、但**当前不该画**的时候。
    ///
    /// ⛔ 这是用户报的「竖屏视频里出现两个嵌套视频」的根因：
    ///
    /// 坞挂在整个 `platformTabs` 上（`.overlay`），判据只看「坞里有没有任务」。
    /// 于是用户进到观看页、**前台视频正在播**时，坞里那张卡也还在画、也还在播 ——
    /// 两张视频叠在同一块区域上，各播各的。
    ///
    /// 正确语义：坞表达的是「我正在看、但没占着屏幕」。一旦前台观看页真的在演
    /// （`playsInWatchPage` 或全屏播放器打开），坞就必须让位 —— 那时候画面已经在页面上。
    ///
    /// 注意判据要用 **`playing` 与当前 scope**，不能用 `hasTasks`：
    /// 坞里可以同时挂好几集，其中一集在前台时，其余几集**应当继续挂在坞里**
    /// （用户切回来还在），只是不画 —— 所以这里是「隐藏坞的绘制」，
    /// 不是「清空坞」。`applyMuting()` 那条链路照旧管声音。
    private var dockCoveredByForeground: Bool {
        // ⛔ 观看页在场也必须让位 —— 哪怕 `playing == nil`。
        //
        // 原来只有下面 `playsInWatchPage(store.playing)` 一条判据，而它对
        // `playing == nil` **恒为 false**（`Store+Playback.swift:9`:
        // `guard let scope = channel?.historyContext?.id else { return false }`）。
        //
        // 于是用户停在观看页里、但这一集没有挂到 `store.playing` 的那一刻
        // （关掉前台这一集、换一集起播的间隙、坞里挂着别的集），
        // 判据全部为 false ⇒ 坞照画 ⇒ 用户看到的正是
        // 「坞在不该出现时出现」。这正是原报告里「`playing=nil` 的场景判不出」。
        //
        // `store.isWatchPageMounted` 就是为这一帧准备的（`Store.swift:584-591`）：
        // 它由观看页 `onAppear`/`onDisappear` **同步**维护，不受 scope 内容影响，
        // 所以页面刚推入、`onAppear` 还没跑那一帧也可靠。
        // `Store.swift:518` 早已用它做同一类判定（决定要不要弹全屏播放器）——
        // 同一份判据在两处分叉，坞这边漏了。现在两边一致。
        let r = store.playsInWatchPage(store.playing)
        let covered = DockCoverage.isCoveredByForeground(
            presentingPlayer: store.presentingPlayer,
            isWatchPageMounted: store.isWatchPageMounted,
            playsInWatchPage: r
        )
        #if DEBUG
        // 探针：坞该不该让位的判据在真机上到底怎么取值。
        // 用户报「展开横屏时坞仍画着」——要么这几个判据都是 false，
        // 要么判出来了但 `.opacity` 没接上。日志能一眼分开。
        if store.videoTasks.hasTasks {
            oneSkinLog("DOCKCOVER presenting=\(store.presentingPlayer) mounted=\(store.isWatchPageMounted) inWatch=\(r) covered=\(covered) playing=\(store.playing?.name ?? "nil") scopes=\(store.watchPageScopes.count)")
        }
        #endif
        return covered
    }

    @ViewBuilder private var videoMiniPlayer: some View {
        VideoTaskDock(gravity: pictureScaling.gravity, pip: miniPip,
                      coveredByForeground: dockCoveredByForeground,
                      offset: $miniDrag, scale: $miniScale)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
                guard newSize.width > 1, newSize.height > 1 else { return }
                // 卡片宽度按坞自己的公式重算，边界用它的一半，才不会把卡片推出屏幕。
                let baseWidth = newSize.width > newSize.height
                    ? min(newSize.width * 0.34, 320) : min(newSize.width * 0.62, 240)
                let halfW = min(max(baseWidth * miniScale, 120), newSize.width - 24) / 2
                let halfH = halfW * 0.75 + 30
                let maxX = newSize.width / 2 - halfW - 8
                let maxY = newSize.height / 2 - halfH - 8
                let x = min(max(miniDrag.width, -maxX), maxX)
                let y = min(max(miniDrag.height, -maxY), maxY)
                if abs(x - miniDrag.width) > 0.5 || abs(y - miniDrag.height) > 0.5 {
                    miniDrag = CGSize(width: x, height: y)
                }
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
            #if os(iOS)
            let _ = OneSkinProbe.log("tabView branch noSidebar=\(phoneTabsWithoutSidebar)")
            #endif
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
    #if os(iOS)
    /// 上一次的窗口尺寸。宽高互换 = 转屏或 Duo 折叠展开，用来把「版式变化」与「离开 App」分开。
    @State private var lastSize: CGSize = .zero
    /// 最近一次版式变化（宽高互换）发生的时刻。
    ///
    /// ⛔ 不能用裸 Bool：那个值只会被下一次裁决消费，而裁决只在 `scenePhase` 或
    /// `miniPlayerActive` 变化时跑。于是「转个屏 → 十分钟后上滑回主界面」时它还是 true，
    /// 会把本该起的悬浮窗挡掉 —— 正好与要求相反。用时间戳加一个短窗口，
    /// 只压住「旋转紧接着的那次退场」。
    @State private var layoutChangedAt: Date = .distantPast
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
        // 播放退场的统一裁决（见 `PlaybackExit`）。
        //
        // 三条要求合成一个判据：
        //   ① 没有任何可见载体（不在页面上、没有应用内小窗、没有 PiP）→ 真正登出，不许音频空转；
        //   ② 上滑回主界面 → 起应用外悬浮窗，让画面跟过去；
        //   ③ 转屏 / 折叠 / 展开 → 什么都不做，绝不能因为它们浮出小窗。
        //
        // ①②③ 互斥，此前每处退场各自猜一遍，于是漏出了「音频在跑、界面上什么都没有」这种第四态。
        // 现在只有这一个地方决定，别处不再各自判断。
        #if os(iOS)
        .modifier(PlaybackExitArbiter(layoutChangedAt: layoutChangedAt))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            // 版式变化的判据：**尺寸真的变了**，而不是「宽高关系翻了」。
            //
            // ⛔ 原来判的是宽高关系翻转（`w>h` 是否变化）。它对转屏成立，
            // 但对 **合盖外屏 466×678（竖）⇄ 展开竖持 669×951（竖）** 完全不成立 ——
            // 两次都是 w<h，`rotated` 恒 false，`layoutChangedAt` 不更新，
            // 于是 `PlaybackExit.decide` 里 `layoutJustChanged == false`。
            // 而那一刻 `hasInlinePicture` 依赖的 `onAppear/onDisappear` 还没跑，
            // 载体为空；只要顺手退到后台（合盖正好收起手机），
            // 就会被判成「离开 App」→ 起一个应用外小窗。
            // 这恰好是用户最常做的那一对动作，也是「展开一下就飞出小窗」的直接成因。
            //
            // 现在改用**逐轴**差分（`OneSkinStageSize.isLayoutChange`）。
            //
            // ⛔ 上一版用的是面积差，那个判据对 Duo 最有代表性的一对动作**恒为 false**：
            // 内屏竖持 669×951 与横持 951×669 面积完全相同（都是 636,219 pt²），
            // `|after-before| / max` 恒等于 0。于是「竖持 ⇄ 横持」被判成「什么都没变」，
            // `layoutChangedAt` 不更新 → 只要那一刻恰好在后台，就会被判成「离开 App」
            // 而浮出应用外小窗。逐轴判就不漏：951↔669 在宽、高各自差 29.6%。
            let areaChanged: Bool = OneSkinStageSize.isLayoutChange(from: lastSize, to: size)
            if areaChanged {
                layoutChangedAt = Date()
                // ⛔ 同一帧把「离开 App 自动浮起」压住（BUG：转屏/折叠会飞出小窗）。
                //
                // 转屏与折叠/展开都会把画面层重挂一次，AVKit 把
                // 「inline layer 离开屏幕」当成「用户离开 App」，于是浮窗自己飞出来。
                // `suspendAutomaticFloating()` 关掉所有活着的 PiP 协调器
                // （含 One / 哔哩哔哩皮肤那两个 @State 实例，以及原生皮肤的 AVKit 宿主），
                // 1.5s 后自动恢复 —— 能力保留，误判被挡住。
                // 放在这里而不是各调用点，是因为**所有**版式变化都必然先经过这里，
                // 一处接线即可覆盖转屏、折叠、展开三种来源。
                PictureInPicture.suspendAutomaticFloating()
            }
            lastSize = size
        }
        #endif
        #endif
    }
}

#if os(iOS)
/// 按 `PlaybackExit` 的裁决驱动真实副作用。
///
/// 单独抽成修饰器是因为它需要读 `scenePhase` 与 PiP 状态，而 `PlayerPresentation` 已经
/// 是一个 `ViewModifier`；再嵌一层比把七八个状态塞进去更清楚。
private struct PlaybackExitArbiter: ViewModifier {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    /// 最近一次版式变化的时刻（见 `PlayerPresentation.layoutChangedAt`）。
    let layoutChangedAt: Date
    /// 载体变为空的时刻。宽限窗用来放过 push/pop 与进/退全屏的过渡帧。
    @State private var carrierEmptySince: Date?

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                // 只有真正进 background 才算「离开 App」。
                //
                // `.inactive` 不算：下拉通知中心、来电横幅、控制中心都会经过它，
                // 那些时候用户没走，浮起悬浮窗反而是打扰。
                if phase == .background {
                    arbitrate(leavingApp: true)
                } else if phase == .active {
                    arbitrate(leavingApp: false)
                }
            }
            .onChange(of: store.miniPlayerActive) { _, _ in
                // 缩成小窗 / 小窗收起，都会改变「有没有可见载体」。
                arbitrate(leavingApp: false)
            }
            // ⛔ 这是上一版的结构性错误：裁决只挂在 `scenePhase` 与 `miniPlayerActive` 上，
            // 而**退出页面（pop / 返回上一层）两个都不改** —— 于是「音频空转」那个场景
            // 的登出判定根本不会跑。用户报的正是它。
            //
            // 真正的触发源是「有没有可见载体」本身：它变了就该重新裁决一次。
            // 用 keypath 化成一个 Bool 来观察，避免每次 `watchPageScopes` 抖动都重算。
            .onChange(of: carrierKey) { _, _ in
                arbitrate(leavingApp: scenePhase == .background)
            }
            // 坞增删（点 ✕、长按海报新起一个、点卡片回到选集页）同样要重新裁决一次：
            // `carrierKey` 里已经带了「坞里有没有」，但它只是**有没有**，
            // 从 2 张变 1 张不会改变 key —— 那种时候载体仍在，不需要重裁决。
            // 真正需要的是「坞被清空的那一刻」：那会改变 key，上面那条已经覆盖。
            // 这里不多写一条，避免同一帧裁决两次。
    }

    /// 「有没有可见载体」的紧凑快照。
    ///
    /// 把三个来源（全屏在播 / 观看页在播 / 小窗在播）压成一个字符串：
    /// `onChange` 只在这个组合真的变了时才触发，页面内部其它状态变化不会惊动裁决。
    private var carrierKey: String {
        let inline = store.playing != nil && (store.presentingPlayer || store.playsInWatchPage(store.playing))
        // ⛔ 小窗载体要问**坞**，不是问 `playing`。
        //
        // 坞里的一集已经不在 `playing` 上了（`dockForeground` 会把前台槽摘掉，否则
        // 两边指着同一个会话，前台一停播就把小窗里的流也停了）。用 `floatsInMiniPlayer(playing)`
        // 判就会得到恒 false → 裁决认为「没有任何可见载体」→ 0.4 秒后走 `.logOut`
        // → `miniPlayerActive = false` → **整个坞被清空**。这是坞多个任务时最致命的漏。
        let mini = store.videoTasks.hasTasks
        let pip = PictureInPicture.isActive
        return "\(inline ? 1 : 0)\(mini ? 1 : 0)\(pip ? 1 : 0)"
    }

    /// 版式变化被视为「刚刚」的窗口长度。
    ///
    /// 1.5 秒够覆盖旋转动画与随后的布局重排；超时就不再把退场当成版式变化，
    /// 否则转完屏之后的所有正常退场都会被误挡。
    private static let layoutWindow: TimeInterval = 1.5

    /// 「载体为空」要持续这么久才算真的登出（见 `PlaybackExit.decide` 第 ④ 步）。
    private static let absenceWindow: TimeInterval = 0.4

    private func arbitrate(leavingApp: Bool) {
        let layoutChanged = Date().timeIntervalSince(layoutChangedAt) < Self.layoutWindow

        // 维护「空态持续了多久」。
        //
        // 载体为空 → 开始计时；载体恢复 → 清计时。宽限窗内仍为空不算登出，
        // 因为 push/pop 动画、进/退全屏、Duo 折叠重挂都会让载体短暂为空。
        let inlineNow = store.playing != nil && (store.presentingPlayer || store.playsInWatchPage(store.playing))
        // 同上：坞非空就是「有可见载体」，与 `playing` 无关。
        let miniNow = store.videoTasks.hasTasks
        let visible = inlineNow || miniNow || PictureInPicture.isActive
        if visible {
            carrierEmptySince = nil
        } else if carrierEmptySince == nil {
            carrierEmptySince = Date()
        }
        // 0.4 s：够覆盖一次 push/pop 或全屏切换的过渡，又短到用户察觉不出「该停没停」。
        let settled = carrierEmptySince.map { Date().timeIntervalSince($0) >= Self.absenceWindow } ?? false

        // ⛔ 进 / 退全屏也会改布局尺寸，而它**不是**版式变化意义上的「转屏」，
        // 但它确实会在 `scenePhase` 不变的情况下让 `carrierKey` 抖一下。
        // 那种时刻不能登出：用户只是切了全屏。
        //
        // 同理，Duo 折叠 / 展开、以及页面 push/pop 过渡的那一两帧，
        // 载体都会短暂为空 —— 一律用同一个宽限窗挡掉。
        // 只有在窗口之外、确实没有任何载体时才登出。

        let context = PlaybackExit.Context(
            isBackground: scenePhase == .background,
            layoutJustChanged: layoutChanged,
            // 「页面上有画面」= 观看页在前台且它自己在画。
            // 全屏播放器由 `presentingPlayer` 表示，观看页由 `playsInWatchPage` 表示，
            // 两者都不成立时页面里确实没有画面。
            hasInlinePicture: store.playing != nil && (store.presentingPlayer || store.playsInWatchPage(store.playing)),
            miniPlayerOn: store.videoTasks.hasTasks,
            pipActive: PictureInPicture.isActive,
            // 下载回放不该起 PiP：它不依赖网络，浮到系统层没有意义，
            // 反而会在用户离开时留下一个「看起来还在播」的窗口。
            // 画面那侧有没有 PiP 能力。
            //
            // 只有一条路：自建 `AVPictureInPictureController(contentSource: .init(playerLayer:))`。
            // 这是上游的做法，也是最可靠的 —— 它不依赖 AVKit 宿主是否存在，
            // 只要 `attach` 时把 `contentSource` 指到当前那块 layer 就行。
            // ⛔ 不能只判 `current != nil`。
            //
            // `current` 只在 PiP **已经起来过**之后才非 nil（唯一赋值点在
            // `willStartPictureInPicture`），所以首播时它恒为 nil。原来的语义等于
            // 「以前浮过才允许再浮」—— 哔哩哔哩皮肤因此永远走 ③b 分支返回 `.keep`：
            // 离开 App 不浮窗、也不登出，音频在后台空转（`PlaybackExit` 头部
            // 声明要消灭的「第四态」）。
            //
            // 改成问「这套画面**能不能**浮」：平台支持 + 画面层已登记内容源。
            // `supported` 是平台级判断；`current != nil` 覆盖「已经浮着」的情况。
            // 哔哩哔哩皮肤现在也 attach 了（见 `BiliSkinPicture.pip`），这条随之成立。
            pipPossible: PictureInPicture.isSupportedForPlayback,
            // 坞里有任务时也允许浮：那时 `playing` 已被摘掉（画面全在坞里），
            // 用 `playing` 判会恒 false，于是「坞里看着却在后台空转」。
            pipAllowed: store.playing.map { $0.url.scheme != DownloadLibrary.scheme } ?? store.videoTasks.hasTasks,
            miniIntent: store.miniPlayerActive,
            absenceSettled: settled
        )

        switch PlaybackExit.decide(context, leavingApp: leavingApp) {
        case .keep:
            break
        case .startPictureInPicture:
            // 交给已挂载的那一份去起：`startFloating` 只在有 AVKit 宿主时有效。
            PictureInPicture.startCurrent()
        case .stopPictureInPicture:
            PictureInPicture.stopCurrent()
        case .logOut:
            // 真正登出。三样都清：播放、会话、小窗授权 —— 少清一样就会留下
            // 「状态说在播、实际没有画面」的残影。
            //
            // ⚠️ `miniPlayerActive = false` 现在是「清空**整个**坞」（它是坞的投影）。
            // 这里安全，因为 `.logOut` 的前提就是 `PlaybackExit` 判出**没有任何可见载体**
            // （`presentation == .hidden` 且空态已稳定）—— 坞里那时必然是空的。
            // 若将来有人把 `.logOut` 的判据放宽到「坞非空也登出」，这一行就会
            // 连带掐掉正在看的小窗，届时要改成只清前台。
            store.stopPlaying()
            store.miniPlayerActive = false
        }
    }
}
#endif

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

/// `RouteLink` + **自动导航一次**。只在 DEBUG 的 QA 深链里用。
///
/// 为什么需要它：`-qaPage open-detail:` 过去只渲染一个 `RouteLink` 按钮，必须有人点才会导航，
/// 于是无人值守时截图永远停在「Open video」那一页 —— 而**不导航就不会登记 `watchPageScopes`**
/// （登记在 `VideoDetailView.watchPageLifecycleBody` 的 `.onAppear` 里，只有真正 push 才会跑）。
///
/// ⛔ 这不是造替身。它落到的页面、走的路径和用户点同一个 `RouteLink` **完全一致**：
/// 同一个 `Route` 值 → 同一个 `RoutePath.opener` → 同一条 `path` →
/// `navigationDestination(for: Route.self)` → `PushedRouteTabSafeArea { route.build() }`。
/// 唯一差别是触发器（自动 vs 手指），而「导航发生了」这件事本身就是被验证的对象。
///
/// `autoOpen` 由 `QALaunch` 按平台给默认：iOS 默认开（真机/模拟器截图无需点击），
/// tvOS 默认关 —— `TVNavigationUITests` 要靠点这个按钮来测 Back，抢跑会把按钮顶掉。
struct QAAutoRouteLink<Label: View>: View {
    private let route: Route
    private let label: Label
    private let autoOpen: Bool
    @Environment(\.openRoute) private var openRoute
    @State private var opened = false
    init<Destination: View>(autoOpen: Bool, @ViewBuilder destination: @escaping @MainActor () -> Destination,
                            @ViewBuilder label: () -> Label) {
        route = Route { AnyView(destination()) }
        self.autoOpen = autoOpen
        self.label = label()
    }
    var body: some View {
        NavigationLink(value: route) { label }
            .task {
                guard autoOpen, !opened else { return }
                opened = true
                guard let openRoute else {
                    oneSkinLog("[QA] autoOpen skipped: no openRoute in environment")
                    return
                }
                openRoute(route)
                oneSkinLog("[QA] autoOpen pushed route (watch page should now register its scopes)")
            }
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
            // 导航栈深度是「页面还在不在」的唯一权威事实，写进 store 供收坞判定使用。
            //
            // ⛔ 只让**当前分区**的栈写：其他分区的栈也有页面时会把深度盖成 1，
            // 让「已经 pop 干净」被误判成「页面还在」，于是真离场也不收坞。
            .onChange(of: stack.path.count, initial: true) { _, depth in
                guard store.section == section else { return }
                store.navDepth = depth
                #if DEBUG
                OneSkinProbe.log("NAVDEPTH section=\(section) depth=\(depth)")
                #endif
            }
            .onChange(of: store.section) { _, now in
                guard now == section else { return }
                store.navDepth = stack.path.count
            }
            .onChange(of: store.pendingRoute) { _, route in
                guard let route, store.section == section else { return }
                stack.opener(route)
                store.pendingRoute = nil
            }
            // 坞里点某张卡片回「那一集的选集页」：与 `pendingRoute` 同一套机制，
            // 只是置请求的是 `VideoTaskCenter` 那一侧（它不在任何栈里，拿不到 `openRoute`）。
            //
            // ⛔ 必须比 `pendingRoute` 更强势：那里 `opener` 会因「栈里已有页」而拒收，
            // 而这里用户是**明确要回到某一集**，栈里可能正开着另一个详情页。所以先清栈再压。
            .onChange(of: store.pendingTaskRoute) { _, route in
                guard let route, store.section == section else { return }
                if !stack.path.isEmpty { stack.path = NavigationPath() }
                stack.opener(route)
                store.pendingTaskRoute = nil
            }
            // ⛔ `.globalSwipeBack()` **不能**挂在这里（NavigationStack 外层）。
            //
            // 它挂在 `NavigationStack { }` 的修饰符链上，`background { }` 里的
            // representable 会成为 NavigationStack 的**兄弟**，而不是栈内的宿主 VC，
            // `arm()` 第一句 `guard let nav = navigationController` 仍然拿到 nil。
            // 实测：左滑完全没反应 —— 用户报的正是这个。
            //
            // 正解在 `routeDestinations()`：挂到栈内的根视图上。
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
                // ★ 全局左滑返回挂**在每个被 push 出来的页面上**。
                //
                // 这里是栈内（`PushedRouteTabSafeArea` 的宿主在 `UINavigationController`
                // 的 viewControllers 里），`navigationController` 非 nil，`arm()` 才装得上手势。
                //
                // ⛔ 不要改挂到 `NavigationStack` 外层：那里 representable 是栈的兄弟，
                // 拿不到 nav，整条需求等于没实现（实测左滑无反应）。
                .globalSwipeBack()
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
                let skinOn = (UserDefaults.standard.object(forKey: OneSkinKeys.enabledKey) as? Bool) ?? true
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
