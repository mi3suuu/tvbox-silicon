import SwiftUI
import TVCore

struct VideoDetailView: View {
    #if DEBUG && os(iOS)
    /// 自动旋转回归钩子的单实例闸；转屏会重复触发 `onAppear`。
    @MainActor private static var qaRotateCycleRunning = false
    #endif
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    let video: Video
    let client: CatalogClient
    /// Opened from Continue Watching: on an iPhone the page resumes it at once.
    var resume: PlaybackHistoryEntry? = nil
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    // ⛔ 全屏状态必须**跨页面身份重建存活**（mi3s 2026-11-09）：
    // 设备日志（oneskin.log）铁证：detail onAppear 反复触发 133 次（页面身份重建循环），
    // @State fullScreen 每次重建归零 —— 用户点全屏后 fs=true 铺满一帧，页面一重建
    // 就被弹回非全屏，表现为「竖屏点全屏没反应 / 全屏闪一下就退出」。
    // 改 @AppStorage 持久化：状态与页面身份解耦，重建后自动恢复。
    // 退出点（exitFullScreen / onDisappear / 折叠复位）照常写 false。
    @AppStorage("watchFullScreen") private var fullScreen = false
    /// 详情页的选集抽屉开关。
    ///
    /// ⛔ **不能用 `store.showsEpisodes`**：那个键是上游全屏播放器
    /// （`PlayerView.swift` 的 `.sheet`）在用。详情页与全屏同时挂同一个键，
    /// 置 true 会**同时触发两个 sheet** —— iOS 同层弹不了两个，
    /// 结果是页面被挤回推荐首页、后续所有触摸失效。这正是用户报的现象。
    /// 详情页用自己的 @State，两条路径互不干扰。
    @State private var showsAllEpisodes = false
    /// 选集抽屉当前停在哪一档高度。集合固定 `[.medium, .large]`，只换这个值。
    @State private var episodeDetent: PresentationDetent = .medium
    /// 选集抽屉：搜索词与当前页（每页 10 集）。
    @State private var episodeQuery = ""
    @State private var episodePage = 0
    /// 选集抽屉的筛选维度。
    enum EpisodeFilter: String, CaseIterable, Identifiable {
        case all, unwatched, downloaded
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "全部"
            case .unwatched: "未看"
            case .downloaded: "已下载"
            }
        }
    }
    @State private var episodeFilter: EpisodeFilter = .all
    /// 每页集数，可在抽屉里切换。
    static let pageSizeChoices = [10, 20, 50]
    @State private var episodePageSize = 10
    @State private var episodeScroll: Episode.ID?
    /// The page's player shows its picture (or an error); until then the page's cover stays over it.
    @State private var playerStarted = false
    /// Back on the cover while it starts: shown for a moment by a tap, as the player's controls are.
    @State private var coverBack = false
    /// The page's player, whose wait the cover tells about.
    @State private var playerSession: PlaybackSession?
    /// The source's config center, open in the app (`ConfigCenterView`).
    @State private var showsConfigCenter = false
    #endif
    @State private var requestTask: Task<Void, Never>?
    @State private var detail: Video?
    /// Short labels (第1集) for lines whose episode names are file names, by episode id (#318). Display only.
    @State private var episodeLabels: [Episode.ID: String] = [:]
    @State private var error: String?
    @State private var busy = false
    @State private var pendingPlan: PlaybackPlan?
    @State private var pendingEpisode: Episode?
    @State private var choosingQuality = false
    @State private var synopsisExpanded = false
    @State private var selectedFlag: String?
    /// 倒序: the episode lists show the last episode first. A per-page preference, so flipping one
    /// video's list around never flips every other video's.
    @State private var reversesEpisodes = false
    /// Play takes over focus from the loading placeholder; otherwise nothing is focused once details load.
    @FocusState private var playFocused: Bool
    /// ⛔ **2026-11-09 根治「横竖屏切换后界面一直推移 / 得重启才恢复」**
    ///
    /// 这两个值以前是 `.onGeometryChange` 写回的 @State，却又驱动
    /// `upstreamWatchBody` 的列宽、画面高度、`duoExpanded` / `isWide` 判据 ——
    /// 「测量 → 写 State → 改布局 → 再测量」自激闭环，每转一次屏缩一圈，
    /// 右侧浅色列不断往左推进来。历史修法清一色是阈值 / 双帧确认 / 冻结缓存，
    /// 都只是减速；冻结还会把几何卡在旧值，正是「得重启 App 才生效」。
    ///
    /// 现在它们是**纯派生值**：只读静态屏幕边界 + 离散界面方向，
    /// 不测量自身、不写状态、不缓存。同形态下每次求值完全相同，没有环可自激；
    /// 方向一变立即得到新值，一次到位，也不会卡死。
    #if os(iOS)
    private var layoutSize: CGSize {
        let b = UIApplication.shared.appWindowScene?.screen.bounds.size ?? UIScreen.main.bounds.size
        // screen.bounds 是物理固定方向，旋转时不产生动画中间态；
        // 按界面方向交换宽高即得当前逻辑尺寸。
        return landscapeScreen
            ? CGSize(width: max(b.width, b.height), height: min(b.width, b.height))
            : CGSize(width: min(b.width, b.height), height: max(b.width, b.height))
    }
    private var containerWidth: CGFloat { layoutSize.width }
    private var containerHeight: CGFloat { layoutSize.height }
    #else
    // macOS / tvOS 没有设备旋转，测量回写不构成闭环，保留原行为。
    @State private var containerWidth: CGFloat = 0
    @State private var containerHeight: CGFloat = 0
    #endif
    /// The picture's own width-over-height, reported by the player once the stream is known.
    /// 16:9 until then, which is what most sources serve and therefore the least surprising guess.
    @State private var playerAspectRatio: CGFloat = 16.0 / 9.0
    /// 每条线路的测速样本（线路名 → 已解析的播放地址）。
    /// 只放**真正解析出来**的地址：type 3/4 的源要先经 preparePlayback 才能拿到流，
    /// 直接拿 `episode.address` 去测等于测一个解析不了的字符串，数字毫无意义。
    @State private var lineSamples: [String: OneSkinLineSample] = [:]
    /// The cover's width over height once it loads; landscape covers are common (Bilibili, short dramas).
    @State private var artAspect: CGFloat?
    /// TMDB's backdrop once its picture has loaded. The source's cover stays until then, and when it never does
    /// (image.tmdb.org is blocked on some networks, #237).
    @State private var loadedBackdrop: URL?
    /// The episode whose playback is being prepared; its row and the Play button show progress.
    @State private var loadingEpisode: Episode.ID?
    /// A failed or blocked playback attempt, shown as an inline banner beside the artwork.
    @State private var playbackIssue: PlaybackIssue?
    @State private var signingIn: CloudDrive?
    /// A sign-in the source's CatPawOpen bundle runs itself (UC's TV token).
    @State private var bundleSignIn: BundleSignIn?
    @State private var choosingDownloads = false
    /// How many episodes were just queued, shown briefly under the header.
    @State private var queuedNotice: Int?
    /// A line has no episode to continue the one playing: shown briefly under the header.
    @State private var lineNotice: String?
    /// TMDB's details for the video (TMDBViews.swift). The page shows the source's own until they are in, then fades them in.
    @State var tmdb = TMDBLookup()
    /// The source's own recommendations, shown under the video when TMDB has none for it. Loaded lazily, once TMDB
    /// has answered, so the related list fills the space below the episodes instead of leaving it blank.
    @State private var siteRelated: [Recommendation] = []
    private var flags: [String] {
        var seen = Set<String>()
        return (detail?.episodes ?? []).map(\.flag).filter { seen.insert($0).inserted }
    }
    private var activeFlag: String { flags.contains(selectedFlag ?? "\u{0}") ? selectedFlag! : (flags.first ?? "") }
    /// The active line's episodes. `activeFlag` goes through every episode, so it is read once, not once per episode:
    /// in the filter it made each page update quadratic (4 lines of 1,000 episodes took seconds, and iOS killed the app).
    private var activeEpisodes: [Episode] {
        let flag = activeFlag
        return (detail?.episodes ?? []).filter { $0.flag == flag }
    }
    /// 仅供诊断日志的离散形态签名，不参与任何布局计算。
    private var layoutSignature: String {
        #if os(iOS)
        let o = UIApplication.shared.appWindowScene?.interfaceOrientation.rawValue ?? -1
        return "h\(String(describing: sizeClass))|v\(String(describing: verticalSizeClass))|o\(o)|fs\(fullScreen)|skin\(oneSkinActive)"
        #else
        return "h\(String(describing: sizeClass))"
        #endif
    }

    private var wideMinWidth: CGFloat {
        #if os(tvOS)
        1200
        #else
        760
        #endif
    }
    private func startRequest(_ operation: @escaping @MainActor () async -> Void) {
        let previous = requestTask
        previous?.cancel()
        requestTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    var body: some View {
        Group {
            #if os(iOS)
            // [mi3s] 二开：选集播放页的**系统栏位**与**页面生命周期**只在这里挂一次。
            //
            // 以前 `watchBody` 的两条渲染分支（One 皮肤 `oneSkinBody` / 上游原版
            // `upstreamWatchBody`）各自抄了一遍 `statusBarHidden` /
            // `persistentSystemOverlays` / `setBarVisibility(:for: .navigationBar|.tabBar)`
            // / `navigationBarBackButtonHidden` / `hidesAppTabBar`，生命周期
            // （方向锁 / 转屏 / 换集 / 离页）也只写在 upstream 那一支 ——
            // 于是皮肤一开，方向锁和转屏就集体失踪。两份代码的判据必然分叉，
            // 用户看到的就是「横屏没有菜单栏、竖屏又有」。
            //
            // 现在两份都收成唯一一处：栏位认 `WatchSystemChrome`（单一判据 `fullScreen`），
            // 生命周期认 `watchPageLifecycle`（两条分支共用同一套）。
            if watchLayout {
                watchPageLifecycleBody(watchBody
                    .watchSystemChrome(fullScreen: fullScreen))
                    // The upright watch page is immersive and its navigation bar is hidden, so the
                    // edge swipe is its way back. One screen edge only: the player owns the rest.
                    .background { EdgeSwipeBack(enabled: !fullScreen && !duoExpanded) }
            } else {
                pageBody
            }
            #else
            pageBody
            #endif
        }
        // 选集抽屉。**挂在这里**，与 `.downloadPicker` 同级 ——
        //
        // 关键教训：挂在 `watchBody` 内部时，无论用 @State 还是 store 都弹不出来
        // （`episodes tapped` 有日志、状态也置了，但 sheet 的内容闭包从未执行）。
        // `watchBody` 是 `@ViewBuilder` 里的 if/else 分支，OneSkin 那一支还叠了
        // `.hidesAppTabBar` / `.setBarVisibility` 这类改动 UIKit 层级的修饰符，
        // 在分支内部挂 sheet 找不到稳定的呈现锚点。
        // 而 `.downloadPicker` 挂在本层（Group 之后）一直能弹 —— 照它挂就对。
        // iOS 专属：`showsAllEpisodes` / `allEpisodes` 都在 `#if os(iOS)` 里，
        // 不包起来 macOS / tvOS 会编译失败（此前只有 iOS 构建过，问题被掩盖）。
        #if os(iOS)
        .sheet(isPresented: $showsAllEpisodes) {
            #if DEBUG
            let _ = oneSkinLog("episodes sheet BUILDING eps=\(activeEpisodes.count) pages=\(episodePageCount)")
            #endif
            allEpisodes
        }
        .onChange(of: showsAllEpisodes) { _, open in
            // 每次打开重新落档：宽屏（Duo 展开 / iPad）直接给满高，窄屏先给半屏。
            guard open else { return }
            episodeDetent = (duoExpanded || sizeClass == .regular) ? .large : .medium
        }
        #endif
        .safeAreaInset(edge: .bottom) { if !isWatchPage { loadingCard } }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            #if os(iOS)
            // ★ iOS：**只读，绝不写状态**。布局尺寸由 `layoutSize` 纯派生，
            // 这里量到的 `size` 不参与任何布局决策 —— 反馈环从根上不存在。
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "qaLogGeometry") {
                let sb = UIApplication.shared.appWindowScene?.screen.bounds.size ?? .zero
                NSLog("GEO probe=%.0fx%.0f derived=%.0fx%.0f sig=%@ hSize=%@ vSize=%@ duo=%@ land=%@ port=%@ scrW=%.0f scrH=%.0f shape=%@",
                      size.width, size.height, containerWidth, containerHeight, layoutSignature,
                      String(describing: sizeClass), String(describing: verticalSizeClass),
                      String(describing: duoExpanded), String(describing: landscapeScreen),
                      String(describing: portraitExpanded), sb.width, sb.height,
                      String(describing: oneSkinShape))
            }
            #endif
            _ = size
            #else
            containerWidth = size.width
            containerHeight = size.height
            #endif
        }
        #if os(macOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { DetailAurora(poster: video.poster, headers: video.posterHeaders) }
        #else
        // [mi3s] One 皮肤自带黑底（OneSkinBackdropLayer）。这里如果再挂 screenBackdrop，
        // 会把 Backdrop 那层浅色（244,246,251）铺在最底下，OneSkin 的半透明黑压不住它，
        // 结果整页发白 —— 控件和文字全部看不清，像素判读也全是噪声。
        // One 实测底色是 #000 / #0E0E0E，所以皮肤开着时不挂主题底。
        .modifier(ScreenBackdropIfNeeded(enabled: !oneSkinActive))
        #endif
        .screenTitle(video.name).task {
            store.searchModel.suspend()
            // A Continue Watching card, or a favorite, can still be on screen when the vault relocks
            // (timeout, a screenshot, the app going to the background). The page must not then reveal a
            // hidden source's title, cover, or episode list, nor resume it. The resume path's own choke
            // point (`resumeHistory`) refuses playback, but this page would still draw the details.
            let blocked = if let resume {
                !store.vault.permitsPlayback(sourceKey: resume.context.sourceKey, origin: resume.context.origin)
            } else {
                !store.vault.permits(site: client.site, fallback: client.origin)
            }
            if blocked {
                store.error = L10n.text("This title is hidden. Unlock the Privacy Vault to watch it.")
                dismiss()
                return
            }
            #if os(iOS)
            // From Continue Watching the watch page resumes at once, resolving its own details.
            let continues = watchLayout && watchChannel == nil && store.resumingHistoryID == nil
            if continues, let resume { store.resume(resume) }
            #endif
            if detail == nil { await loadDetail() }
            #if os(iOS)
            // A video of one episode then plays by itself, from where the viewer stopped if watched before. One of
            // several waits on its cover for the viewer to choose the line and episode (#260).
            if continues, resume == nil, watchChannel == nil, store.resumingHistoryID == nil, activeEpisodes.count <= 1 {
                playWatchCover()
            }
            // Opened on a video of several episodes with nothing watched before: the viewer's next step is
            // picking one, so the episode list comes up rather than a cover with a Play button that only leads
            // to the same list. A video watched before skips this — its continuation is the point of opening it.
            // On the Duo's unfolded landscape the episode grid already lives in the right column beside the
            // picture, so the auto-pop sheet would only cover it — skip the pop there.
            // [mi3s] OneSkin 皮肤开着时**不再自动弹选集 sheet**：
            // 皮肤详情栏里本来就有选集区，再弹全屏 sheet 只会盖住右栏、遮掉画面控件。
            if opensIntoEpisodes, store.resumingHistoryID == nil, watchChannel == nil,
               !(duoExpanded && sideways), !portraitExpanded,
               !oneSkinActive, !choosingDownloads {
                // ⛔ 必须是 `showsAllEpisodes`（本页抽屉的键）。
                // 写 `store.showsEpisodes` 打开的是上游全屏播放器的面板 —— 本页没有宿主，
                // 结果「什么都不弹」，还留下一个 true 的脏状态。
                showsAllEpisodes = true
            }
            #endif
            #if DEBUG
            // `-qaDownloadPicker 1` / `-qaEpisodesSheet 1`：截图用的抽屉直开入口。
            // 两者同层，不能同时为 true（iOS 同层只剩一个 presenter），打开一个先关另一个。
            if UserDefaults.standard.bool(forKey: "qaDownloadPicker") {
                showsAllEpisodes = false
                choosingDownloads = true
            }
            if UserDefaults.standard.bool(forKey: "qaEpisodesSheet") {
                choosingDownloads = false
                showsAllEpisodes = true
            }
            // `-qaWatchPlay 1` 直接起播第一集：控件层只在 session 起来后才画，
            // 多集片源默认停在封面，没有这条就截不到「真实播放中」的控件版式。
            if UserDefaults.standard.bool(forKey: "qaWatchPlay"),
               watchChannel == nil, let first = activeEpisodes.first ?? detail?.episodes.first {
                await play(first)
            }
            #endif
        }
        .onAppear {
            store.watchPageOpen = true
            // 进页面就为每条线路解析一个可测速地址（不阻塞首帧）。
            Task { await buildLineSamples() }
            #if DEBUG
            let switchDelay = UserDefaults.standard.double(forKey: "qaSwitchEpisode")
            oneSkinLog("detail onAppear watchPageOpen=\(store.watchPageOpen) qaSwitchEpisode=\(switchDelay)")
            // `-qaSwitchEpisode <秒>`：无人值守回归「换集后播放器是否渲染新内容」。
            // 先起播第一集，等 N 秒再播第二集，对比两次截图 / oneskin.log 即可，
            // 不必在模拟器上模拟点击（simctl 没有 tap）。
            if switchDelay > 0 {
                Task { @MainActor in
                    // 等订阅导入 + 详情落地；最多 8 秒。
                    for _ in 0..<16 where activeEpisodes.count < 2 {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    guard activeEpisodes.count > 1 else {
                        oneSkinLog("qaSwitchEpisode: 需要至少两集，实际 \(activeEpisodes.count)")
                        return
                    }
                    let first = activeEpisodes[0], second = activeEpisodes[1]
                    oneSkinLog("qaSwitchEpisode: first -> \(first.name)")
                    await play(first)
                    try? await Task.sleep(for: .seconds(switchDelay))
                    guard !Task.isCancelled else { return }
                    oneSkinLog("qaSwitchEpisode: second -> \(second.name)")
                    await play(second)
                }
            }
            #endif
        }
        .onDisappear {
            store.watchPageOpen = false
            requestTask?.cancel()
            #if os(iOS)
            // The page itself is gone (not just folded/unfolded): leave Full Screen. The video keeps playing,
            // so the floating mini player (RootView) takes over and the viewer can still get back to it.
            // On a fold this view stays alive, so playback carries on into the other layout.
            // 页面消失只清理**自己的**全屏状态。方向不再由这里强制回竖屏：
            // 全屏与方向已解耦（`setFullScreen` / `exitFullScreen` 都不碰
            // `PlayerOrientation`），横屏页离开时再 `set(landscape: false)`
            // 会主动把整机转回竖屏，把这一页的方向偏好污染到下一个页面 ——
            // 正是用户说的「每个页的全屏机制没有独立做好，无法共用」。
            // 方向只由旋转键与播放器关闭时的 `release()` 管。
            if fullScreen { fullScreen = false }
            #endif
        }
        .task(id: detail?.id) {
            // The source's related titles load beside TMDB's lookup, not after it: a title TMDB doesn't know
            // (or a Worker that is slow) would otherwise leave the space under the video empty until the
            // lookup timed out. The related list shows the source's own titles while TMDB is still thinking,
            // and TMDB's recommendations replace them once they arrive.
            async let tmdbLookup: Void = startTMDB()
            async let related: Void = loadRelatedFallback()
            _ = await (tmdbLookup, related)
        }
        .onChange(of: choosingQuality) { _, open in if !open && !busy { loadingEpisode = nil } }
        #if os(iOS)
        .sheet(isPresented: $showsConfigCenter) { ConfigCenterView { await configCenterAddress() } }
        #endif
        // Sign in where playback failed, then resume the episode that needed the account.
        #if !os(tvOS)
        .sheet(item: $bundleSignIn) { pending in
            CatPawSignInView(client: client, provider: pending.provider) {
                if let episode = playbackIssue?.episode { startRequest { await play(episode) } }
            }
        }
        #endif
        #if os(macOS)
        .sheet(item: $signingIn) { drive in
            if drive == .xunlei {
                XunleiSignInView { if let episode = playbackIssue?.episode { startRequest { await play(episode) } } }
            } else if drive == .baidu {
                // Baidu signs in with a code to scan on a Mac, as in Settings.
                CloudQRLoginView(drive: .baidu) { retryAfterSignIn() }
            } else {
                CloudLoginView(provider: drive.provider) { cookie, ticket in
                    try await drive.provider.saveLogin(cookie, ticket: ticket)
                    if let episode = playbackIssue?.episode { startRequest { await play(episode) } }
                }
            }
        }
        #elseif os(iOS)
        // The drive's own sign-in page; the code is for signing in with another phone.
        .sheet(item: $signingIn) { drive in
            if drive == .xunlei { XunleiSignInView(signedIn: retryAfterSignIn) }
            else {
                WebSignInView(service: drive.webSignIn, signedIn: retryAfterSignIn) {
                    CloudQRLoginView(drive: drive.qrDrive) { retryAfterSignIn() }
                }
            }
        }
        #else
        .fullScreenCover(item: $signingIn) { drive in
            if drive == .xunlei { XunleiSignInView(signedIn: retryAfterSignIn) }
            else { CloudQRLoginView(drive: drive.qrDrive) { retryAfterSignIn() } }
        }
        #endif
        .downloadPicker(isPresented: $choosingDownloads) {
            DownloadPicker(video: video, site: client.site, flag: activeFlag,
                           episodes: activeEpisodes, origin: client.origin,
                           // One 皮肤 / 全屏时页面是黑的，抽屉也跟着黑，避免浅色材质糊在画面上。
                           dark: drawerIsDark,
                           startsLarge: drawerStartsLarge) { count in
                guard count > 0 else { return }
                withAnimation(.smooth(duration: 0.2)) { queuedNotice = count }
                Task { try? await Task.sleep(for: .seconds(6)); withAnimation(.smooth(duration: 0.2)) { queuedNotice = nil } }
            }
        }
        .confirmationDialog(L10n.text("Choose quality"), isPresented: $choosingQuality, titleVisibility: .visible) {
            if let plan = pendingPlan, let episode = pendingEpisode {
                ForEach(plan.choices) { choice in
                    Button(choice.name) { startRequest { await resolve(plan, choice: choice, episode: episode) } }
                }
            }
        }
    }

    /// One page on Mac, iPad and Apple TV: the banner, the synopsis, the episodes, then TMDB's cast and facts. An episode
    /// rail beside the banner (once used for long lists, and always on Apple TV) squeezed the banner into a card.
    private var pageBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if detail != nil {
                    episodePanel
                    tmdbExtras
                } else if let error {
                    errorCard(error).padding(.top, 12)
                } else {
                    // The Play placeholder in the header holds focus while details load.
                    DetailSkeleton()
                }
            }
            .pageContainer()
        }
    }

    private var isWatchPage: Bool {
        #if os(iOS)
        watchLayout
        #else
        false
        #endif
    }

    /// 抽屉是否用深色底：One 皮肤或全屏时页面是黑的，浅色材质会糊在画面上。
    private var drawerIsDark: Bool {
        #if os(iOS)
        oneSkinActive || fullScreen
        #else
        false
        #endif
    }

    /// 抽屉是否从满高开始：宽屏（Duo 展开 / iPad）下 medium 会变成居中小卡，
    /// 两个抽屉都会显得又小又空。
    private var drawerStartsLarge: Bool {
        #if os(iOS)
        duoExpanded || sizeClass == .regular
        #else
        false
        #endif
    }

    @ViewBuilder private var loadingCard: some View {
        if busy {
            // Keyed by the step, so the timer restarts when details turn into resolving a link.
            LoadingCard { .source(client.site, origin: client.origin, title: busyTitle) }
                .id(busyTitle)
                .frame(maxWidth: .infinity).padding(.horizontal, Layout.gutter).padding(.bottom, 24)
        }
    }
    @ViewBuilder private var playbackBanner: some View {
        if let count = queuedNotice {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Brand.accent)
                Text(count == 1 ? L10n.text("1 episode added to Downloads.") : L10n.text("%lld episodes added to Downloads.", count)).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Button(L10n.text("Show Downloads")) { store.section = .downloads }.settingsButton()
            }
            .padding(Spacing.panel)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        if let notice = lineNotice {
            HStack(spacing: 12) {
                Image(systemName: "info.circle.fill").foregroundStyle(Brand.accent)
                Text(notice).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
            }
            .padding(Spacing.panel)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        if let issue = playbackIssue {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: issue.drive != nil || issue.signIn != nil ? "person.crop.circle.badge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Brand.amber)
                    .frame(width: 36, height: 36)
                    .background(Brand.amber.opacity(0.15), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("Couldn't play %@", EpisodeRow.title(issue.episode.name)))
                            .font(.headline).lineLimit(2)
                        Text(issue.message).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).selectable()
                    }
                    HStack(spacing: 8) {
                        if let drive = issue.drive {
                            Button(drive.signInTitle) { signingIn = drive }.settingsButton(prominent: true)
                        }
                        #if !os(tvOS)
                        if let provider = issue.signIn {
                            Button(L10n.text("Get UC TV Token")) { bundleSignIn = BundleSignIn(provider: provider) }
                                .settingsButton(prominent: true)
                                .accessibilityIdentifier("playbackIssue.bundleSignIn")
                        }
                        #endif
                        Button(L10n.text(issue.blockedBeforeRequest ? "Try Anyway" : "Retry")) {
                            startRequest { await play(issue.episode, skipAccountCheck: true) }
                        }
                        .settingsButton(prominent: issue.drive == nil && issue.signIn == nil)
                        #if os(tvOS)
                        // A focusable action instead of the small corner close button.
                        Button(L10n.text("Dismiss")) { withAnimation(.smooth(duration: 0.2)) { playbackIssue = nil } }.settingsButton()
                        #endif
                    }
                }
                Spacer(minLength: 0)
                #if !os(tvOS)
                Button { withAnimation(.smooth(duration: 0.2)) { playbackIssue = nil } } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.07), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).accessibilityLabel(L10n.text("Dismiss")).help(L10n.text("Dismiss"))
                #endif
            }
            .padding(Spacing.panel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.primary.opacity(0.08)) }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
    private func errorCard(_ error: String) -> some View {
                    ErrorStateCard(
                        title: detail == nil ? L10n.text("Unable to load video details") : L10n.text("Unable to start playback"),
                        message: detail == nil
                            ? L10n.text("Try again, or go back and choose another video.")
                            : L10n.text("Try another episode or playback source."),
                        details: error,
                        retry: detail == nil ? { startRequest { await loadDetail() } } : nil,
                        goBack: { dismiss() },
                        busy: busy,
                        backTitle: L10n.text("Go back")
                    )
    }
    private var busyTitle: String {
        if detail == nil { return L10n.text("Loading video details…") }
        let episode = detail?.episodes.first { $0.id == loadingEpisode }
        return episode.map { L10n.text("Getting the video link for %@…", EpisodeRow.title($0.name)) } ?? L10n.text("Getting the video link…")
    }
    private func loadDetail() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let value = try await client.detail(video.id, cached: client.site.type == 3 || client.site.type == 4)
            try Task.checkCancellation()
            // Worked out once, off the main thread: a line can hold thousands of episodes.
            let episodes = value.episodes
            #if DEBUG
            oneSkinLog("detail loaded: eps=\(episodes.count) flags=\(Set(episodes.map(\.flag)).sorted())")
            #endif
            episodeLabels = await Task.detached(priority: .userInitiated) { EpisodeLabels.labels(episodes) }.value
            detail = value
            // Start on the line watched last (#362), else on one that can play: not one from a drive the viewer has no
            // way to sign in to.
            if selectedFlag == nil { selectedFlag = watchedFlag ?? CloudDrive.preferredFlag(flags) }
            #if os(tvOS)
            Task { try? await Task.sleep(for: .milliseconds(100)); playFocused = true }
            #endif
        } catch {
            guard !Task.isCancelled else { return }
            Diagnostics.shared.failure("catalog", "detail \(client.reportContext)", error)
            self.error = error.localizedDescription
            #if os(tvOS)
            // The loading placeholder that held focus is gone: Retry in the hero takes it.
            Task { try? await Task.sleep(for: .milliseconds(100)); playFocused = true }
            #endif
        }
    }
    /// What this device knows shows at once; otherwise the lookup starts once the source's details are in (their
    /// synopsis and episodes help tell works of the same name apart).
    private func startTMDB() async {
        guard TMDBLookup.applies(to: client.site) else { return }
        let key = TMDBMatchStore.key(source: client.site.key, video: video.id)
        guard let detail else { _ = await tmdb.prepare(key: key); return }
        let request = TMDBMatch.Request(video: detail.keepingPoster(video.poster), listVideo: video,
                                        source: TMDBMatch.SourceRef(key: client.site.key, name: client.site.name))
        // AI-generated videos and short dramas aren't on TMDB: the page keeps the source's own data.
        guard !TMDBMatch.labeledNotOnTMDB(request) else { tmdb.skip(); return }
        await tmdb.run(key: key, request: request)
    }
    /// The source's own related titles, shown when TMDB has no recommendations for the video. Loaded once per page;
    /// `relatedSection` only uses them while TMDB's recommendations are empty, so a matched title never shows both.
    private func loadRelatedFallback() async {
        guard siteRelated.isEmpty else { return }
        if let recs = try? await client.recommendations() {
            guard !Task.isCancelled else { return }
            siteRelated = recs
        }
        #if DEBUG && os(iOS)
        NSLog("RELATED-FALLBACK count=%d", siteRelated.count)
        #endif
    }
    /// A video without episodes. A config center entry (a CatPawOpen bundle's, #311, or a Wex plugin's, #360) opens its page in the app.
    @ViewBuilder private func noEpisodes(_ detail: Video) -> some View {
        #if os(iOS)
        if ConfigCenter.page(of: detail, site: client.site) != nil {
            Button { showsConfigCenter = true } label: { Label(L10n.text("Open Config Center"), systemImage: "gearshape") }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("detail.configCenter")
        } else {
            Text(L10n.text("No playable sources were found for this video.")).foregroundStyle(.secondary)
        }
        #else
        Text(L10n.text("No playable sources were found for this video.")).foregroundStyle(.secondary)
        #endif
    }
    #if os(iOS)
    /// The config center's address now. Asking the bundle again gives its current port, which changes when iOS took
    /// back its socket while the app was suspended; the page's details can be older than that, or cached.
    private func configCenterAddress() async -> URL? {
        let fresh = try? await client.detail(video.id)
        return (fresh ?? detail).flatMap { ConfigCenter.page(of: $0, site: client.site) }
    }
    #endif
    /// TMDB's story when it has one, else the source's synopsis.
    private func synopsisText(_ detail: Video) -> String {
        if let story = tmdb.details?.story, !story.isEmpty { return story }
        return detail.synopsis
    }
    /// The lookup's progress or its question, then TMDB's cast, facts and notice, under the page's own content.
    @ViewBuilder private var tmdbStatus: some View {
        TMDBLookupStatus(lookup: tmdb)
    }
    @ViewBuilder private var tmdbExtras: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let details = tmdb.details {
                if !details.cast.isEmpty { TMDBCastRow(cast: details.cast) }
                TMDBInfoGrid(details: details)
                TMDBFooter(lookup: tmdb, title: currentVideo().name)
            }
            relatedSection
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
    /// "猜你喜欢" over the related list. The list itself falls back from TMDB's recommendations to the source's
    /// own related titles, then to this video's episodes, so the space below the video never sits empty.
    @ViewBuilder private var relatedSection: some View {
        let recs = tmdb.details?.recommendations ?? []
        if !recs.isEmpty {
            Text(L10n.text("You May Like")).font(.headline)
            TMDBRelatedList(titles: recs) { store.searchVideos($0) }
        } else if !siteRelated.isEmpty {
            Text(L10n.text("You May Like")).font(.headline)
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(siteRelated) { item in
                    switch item.destination {
                    case .detail(let video):
                        RouteLink { CatalogDestination(video: video, client: client) } label: {
                            RelatedCard(title: item.name, subtitle: item.remarks, poster: item.poster?.url, headers: item.poster?.headers ?? [:])
                        }
                    case .search(let query):
                        Button { store.searchVideos(query) } label: {
                            RelatedCard(title: item.name, subtitle: item.remarks, poster: item.poster?.url, headers: item.poster?.headers ?? [:])
                        }
                        .tmdbCardButton()
                    }
                }
            }
        } else if detail != nil, !activeEpisodes.isEmpty {
            Text(L10n.text("You May Like")).font(.headline)
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(shownOrder(activeEpisodes)) { episode in
                    Button { startRequest { await play(episode) } } label: {
                        RelatedCard(title: episodeTitle(episode), subtitle: SourceLabel(client.site.name).text,
                                    poster: video.poster, headers: video.posterHeaders)
                    }
                    .tmdbCardButton()
                }
            }
        }
    }
    private var bannerHeight: CGFloat {
        #if os(tvOS)
        // Leaves the synopsis in view under it.
        min(max(containerWidth * 0.38, 480), 680)
        #else
        min(max(containerWidth * 0.42, 280), 540)
        #endif
    }
    /// TMDB's backdrop banner once its picture is in, the source's cover and title until then.
    @ViewBuilder private var tmdbHero: some View {
        if let details = tmdb.details, let backdrop = details.backdrop, backdrop == loadedBackdrop {
            let banner = TMDBBanner(details: details, backdrop: backdrop, unmatched: tmdb.answer?.unmatched ?? "") { playControl }
            banner.frame(height: bannerHeight).transition(.opacity)
        } else {
            hero.transition(.opacity)
        }
    }
    private var headerLayout: AnyLayout {
        #if os(iOS)
        if sizeClass == .compact { return AnyLayout(HStackLayout(alignment: .top, spacing: 16)) }
        #endif
        return AnyLayout(HStackLayout(alignment: .top, spacing: 24))
    }
    private var compactDetail: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }
    @ViewBuilder private func synopsis(_ detail: Video) -> some View {
        let text = synopsisText(detail)
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(text).foregroundStyle(.secondary)
                    .lineLimit(synopsisExpanded ? nil : synopsisLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                if text.count > 100 {
                    let toggle = Button(L10n.text(synopsisExpanded ? "Show Less" : "Show Full Synopsis")) { synopsisExpanded.toggle() }
                    #if os(tvOS)
                    toggle.controlButton()
                    #else
                    toggle.buttonStyle(.plain).font(.subheadline.weight(.semibold)).frame(minHeight: 44, alignment: .leading)
                    #endif
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Full width, so Down from the banner's buttons reaches Show Full Synopsis wherever they sit.
            .tvFocusSection()
        }
    }
    private var synopsisLineLimit: Int {
        #if os(tvOS)
        4
        #else
        3
        #endif
    }
    private var posterWidth: CGFloat {
        #if os(macOS)
        150
        #elseif os(iOS)
        compactDetail ? 104 : 150
        #else
        Layout.detailPoster
        #endif
    }
    private var isWide: Bool { containerWidth >= wideMinWidth }
    /// The details, with the list's poster when the details came without one.
    func currentVideo() -> Video { (detail ?? video).keepingPoster(video.poster, headers: video.posterHeaders) }

    private func videoFavorite() -> FavoriteItem {
        .video(FavoriteVideo(origin: client.origin, site: client.site, video: currentVideo()))
    }

    private func episodeFavorite(_ episode: Episode) -> FavoriteItem {
        .episode(FavoriteEpisode(video: FavoriteVideo(origin: client.origin, site: client.site, video: currentVideo()), episodeFlag: episode.flag, episodeName: episode.name, episodeID: episode.id))
    }

    @ViewBuilder private var playControl: some View {
        if let detail {
            if let first = activeEpisodes.first ?? detail.episodes.first {
                // Beside the poster on a phone there is no room for both labels: Download drops to its icon.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { playButton(first); downloadButton(iconOnly: false); videoFavoriteButton }
                    HStack(spacing: 10) { playButton(first); downloadButton(iconOnly: true); videoFavoriteButton }
                }
            } else {
                #if os(tvOS)
                // No episodes, so no Play: without a button here nothing on the page could take focus, and Back
                // did nothing at all.
                goBackButton(prominent: true).focused($playFocused)
                #endif
            }
        } else if error == nil {
            // On Apple TV the hero fills the screen and the skeleton below it is off-screen: the
            // Play button's placeholder holds focus, so Back leaves the page instead of the app.
            SkeletonBlock(cornerRadius: 10).frame(width: 150, height: 40).loadingFocus(takeFocus: true) { dismiss() }
        } else {
            #if os(tvOS)
            // The details failed. The error card's buttons are below the full-screen hero, out of the remote's reach,
            // so the hero offers them too; they hold focus, and Back leaves the page again.
            HStack(spacing: 10) {
                Button { startRequest { await loadDetail() } } label: { Label(L10n.text("Retry"), systemImage: "arrow.clockwise") }
                    .controlButton(prominent: true).tint(Brand.accent).controlSize(.large)
                    .disabled(busy)
                    .focused($playFocused)
                    .accessibilityIdentifier("detail.retry")
                goBackButton(prominent: false)
            }
            #endif
        }
    }
    #if os(tvOS)
    private func goBackButton(prominent: Bool) -> some View {
        Button { dismiss() } label: { Label(L10n.text("Go back"), systemImage: "chevron.backward") }
            .controlButton(prominent: prominent).controlSize(.large)
            .accessibilityIdentifier("detail.goBack")
    }
    #endif
    private func playButton(_ episode: Episode) -> some View {
        Button { startRequest { await play(episode) } } label: {
            HStack(spacing: 8) {
                if loadingEpisode == episode.id { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill") }
                Text(L10n.text("Play"))
            }
            .font(.headline).lineLimit(1).fixedSize().padding(.horizontal, 8)
        }
        .controlButton(prominent: true).tint(Brand.accent).controlSize(.large)
        .focused($playFocused)
    }
    private func downloadButton(iconOnly: Bool) -> some View {
        Button { choosingDownloads = true } label: {
            Label(L10n.text("Download"), systemImage: "arrow.down.circle")
                .labelStyle(DownloadLabelStyle(iconOnly: iconOnly))
                .font(.headline).lineLimit(1).fixedSize()
        }
        .controlButton().controlSize(.large).accessibilityLabel(L10n.text("Download"))
    }
    /// Icon-only, beside Play and Download. An empty heart keeps the control color; a saved one is rose.
    /// Set as text in their font, so the button is as tall as theirs: a bare image made a smaller one on Apple TV.
    private var videoFavoriteButton: some View {
        let saved = store.favorites.contains(videoFavorite())
        let title = saved ? L10n.text("Remove %@ from favorites", currentVideo().name) : L10n.text("Add %@ to favorites", currentVideo().name)
        return Button { store.favorites.toggle(videoFavorite()) } label: {
            Group {
                if saved {
                    Text(Image(systemName: "heart.fill")).foregroundStyle(Brand.rose)
                } else {
                    Text(Image(systemName: "heart"))
                }
            }
            .font(.headline).lineLimit(1).fixedSize()
        }
        .controlButton().controlSize(.large)
        .accessibilityLabel(title).help(title)
        .accessibilityIdentifier("detail.favorite")
    }
    /// Share the video's TMDB page, whose link is stable (a source's playback address is temporary).
    @ViewBuilder private var shareButton: some View {
        #if !os(tvOS)
        if let link = tmdb.details?.link {
            ShareLink(item: link) {
                Text(Image(systemName: "square.and.arrow.up"))
                    .font(.headline).lineLimit(1).fixedSize()
            }
            .controlButton().controlSize(.large)
            .accessibilityLabel(L10n.text("Share"))
            .accessibilityIdentifier("detail.share")
        }
        #endif
    }
    /// The source's cover in TMDB's banner shape, so the page keeps its layout when TMDB's backdrop fades in, and for
    /// titles TMDB doesn't have.
    private var hero: some View {
        PosterBanner(poster: video.poster, headers: video.posterHeaders, title: video.name, subtitle: video.remarks,
                     aspect: $artAspect) { playControl }
            .frame(height: bannerHeight)
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            // TMDB's banner at any width, so a matched title's page looks the same everywhere.
            if isWide || hasBackdrop {
                tmdbHero
                playbackBanner
                tmdbStatus
                if let detail, !synopsisText(detail).isEmpty {
                    synopsis(detail).font(.body).padding(.horizontal, 18).padding(.vertical, 14)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: posterWidth)
                        .overlay { PosterImage(url: video.poster, headers: video.posterHeaders) }
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    // As tall as the 2:3 poster, so the buttons line up with its bottom edge.
                    MinHeightLayout(minHeight: posterWidth * 1.5) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(video.name).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                            if !video.remarks.isEmpty { Text(video.remarks).font(.subheadline).foregroundStyle(.secondary) }
                            if let facts = tmdb.details?.facts, !facts.isEmpty {
                                Text(facts).font(.subheadline).foregroundStyle(.secondary).transition(.opacity)
                            }
                            Spacer(minLength: 0)
                            playControl
                        }
                    }
                    Spacer(minLength: 0)
                }
                playbackBanner
                tmdbStatus
                if let detail { synopsis(detail) }
            }
        }
        .animation(.smooth(duration: 0.45), value: tmdb.details)
        .animation(.smooth(duration: 0.45), value: loadedBackdrop)
        .animation(.smooth(duration: 0.3), value: tmdb.phase)
        .task(id: tmdb.details?.backdrop) {
            // Into TMDBArtwork's cache, so the banner shows it at once.
            guard let backdrop = tmdb.details?.backdrop,
                  await TMDBArtwork.load(backdrop, maxPixels: TMDBBannerMetrics.backdropPixels) != nil,
                  !Task.isCancelled else { return }
            loadedBackdrop = backdrop
        }
    }
    private var hasBackdrop: Bool {
        tmdb.details?.backdrop != nil && tmdb.details?.backdrop == loadedBackdrop
    }
    @ViewBuilder private var episodePanel: some View {
        if let detail {
            if detail.episodes.isEmpty {
                noEpisodes(detail)
            } else {
                let items = activeEpisodes
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        #if os(tvOS)
                        if items.count > 1 {
                            episodeOrderButton(count: items.count)
                        } else {
                            Text(L10n.text("Episodes")).font(.headline)
                        }
                        #else
                        Text(L10n.text("Episodes")).font(.headline)
                        Text("\(items.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        if items.count > 1 { episodeOrderButton }
                        #endif
                        Spacer(minLength: 8)
                        if flags.count == 1, !activeFlag.isEmpty {
                            Text(SourceLabel(activeFlag).text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    flagPicker
                    episodeList(items)
                }
            }
        }
    }
    @ViewBuilder private var flagPicker: some View {
        if flags.count > 1 {
            #if os(tvOS)
            ChipRow {
                HStack(spacing: 8) {
                    ForEach(flags, id: \.self) { flag in
                        Chip(title: flag.isEmpty ? L10n.text("Play") : flag, selected: flag == activeFlag) { selectedFlag = flag }
                    }
                }
            }.tvFocusSection()
            #else
            SourceStrip(items: flags.map { .init(id: $0, name: $0.isEmpty ? L10n.text("Play") : $0) }, selection: activeFlag) { selectedFlag = $0 }
            #endif
        }
    }
    #if os(tvOS)
    /// On Apple TV the heading itself turns the list around (倒序): one glass button whose arrow shows the order,
    /// up for the first episode first, down for the last.
    private func episodeOrderButton(count: Int) -> some View {
        Button { reversesEpisodes.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: reversesEpisodes ? "arrow.down" : "arrow.up").contentTransition(.symbolEffect(.replace))
                Text(L10n.text("Episodes"))
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .glassPill()
        .accessibilityLabel(L10n.text("Reverse Order"))
        .accessibilityAddTraits(reversesEpisodes ? .isSelected : [])
        .accessibilityIdentifier("episodes.reverse")
    }
    #else
    /// The small button beside the episode count that turns the lists around (倒序).
    private var episodeOrderButton: some View {
        Button { reversesEpisodes.toggle() } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(reversesEpisodes ? Brand.accent : Color.secondary)
                .frame(minWidth: 32, minHeight: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassOrFill(.regular.interactive(), Color.primary.opacity(0.06), in: Circle())
        .help(L10n.text("Reverse Order"))
        .accessibilityLabel(L10n.text("Reverse Order"))
        .accessibilityAddTraits(reversesEpisodes ? .isSelected : [])
        .accessibilityIdentifier("episodes.reverse")
    }
    #endif

    /// What the pickers show for an episode: its short label when its line has them, else its name without the size tag.
    private func episodeTitle(_ episode: Episode) -> String { episodeLabels[episode.id] ?? EpisodeRow.title(episode.name) }

    /// The episodes in the order the lists show them. Only the lists: Play and the next episode still follow the source.
    private func shownOrder(_ items: [Episode]) -> [Episode] { reversesEpisodes ? items.reversed() : items }

    // MARK: 选集抽屉的分页 / 筛选 / 搜索

    /// 搜索 + 筛选之后的集（按当前排序）。空搜索 = 全集。
    ///
    /// 三级管道，顺序固定：**先筛选 → 再搜索**。
    /// 反过来的话，「未看 + 搜 12」会在全部里搜出第 12 集，再被未看筛掉，
    /// 用户会以为「第 12 集不见了」——实际是搜到了又被筛走。
    private var filteredEpisodes: [Episode] {
        var items = shownOrder(activeEpisodes)

        switch episodeFilter {
        case .all:
            break
        case .unwatched:
            items = items.filter { !isWatched($0) }
        case .downloaded:
            items = items.filter { download($0)?.status == .completed }
        }

        let q = episodeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        // 纯数字按「第 N 集」判：用户搜 12 想的是第 12 集，
        // 不是标题里含「12」的那一批（「2012」不该命中）。
        if let n = Int(q) {
            let exact = items.filter { ep in
                if let num = TMDBMatch.episodeNumber(ep.name) { return num == n }
                return episodeTitle(ep).contains("\(n)")
            }
            // 有精确集号命中就只给精确结果；没有才退回子串匹配。
            if !exact.isEmpty { return exact }
        }
        return items.filter { ep in
            episodeTitle(ep).localizedCaseInsensitiveContains(q) || ep.name.localizedCaseInsensitiveContains(q)
        }
    }

    /// 这部剧里「看过」的集：episodeID → 是否看完。
    ///
    /// 不能拿 `watchHistory`（单条续播点）来判断 —— 它只代表「上次看到哪一集」，
    /// 用它筛「未看」会把除当前集以外的所有集都当成未看。
    /// 真正的逐集记录在 `store.visibleHistory.entries` 里，每条含
    /// `context.videoID`（哪部剧）与 `context.episodeID`（哪一集）。
    /// 按本剧的 scope 收一遍，就是这个抽屉需要的完整「已看」集合。
    private var watchedEpisodeIDs: Set<String> {
        let scope = watchScopes
        return Set(store.visibleHistory.compactMap { entry in
            guard scope.contains(entry.context.id) else { return nil }
            // 有进度或已看完才算「看过」；刚点开几秒不算，否则「未看」会漏掉。
            return entry.progress > 0.02 || entry.completed ? entry.context.episodeID : nil
        })
    }

    /// 这一集是否看过。正在播的那集始终算已看。
    private func isWatched(_ episode: Episode) -> Bool {
        if episode.id == currentEpisodeID, watchChannel != nil { return true }
        return watchedEpisodeIDs.contains(episode.id)
    }

    /// 搜索提交时跳到第一处命中所在的页。
    ///
    /// 基于**过滤后**的列表算下标：`filteredEpisodes` 已经把筛选和搜索都应用过了，
    /// 所以这里第一项就是命中项，页码恒为 0 —— 但保留函数是为了
    /// 「搜 12 直接翻到含第 12 集那一页」的语义：当搜索是纯数字且列表里
    /// 没有精确集号（退回子串匹配）时，仍然定位到第一个含该数字的位置。
    private func jumpToFirstMatch() {
        let q = episodeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { episodePage = 0; return }
        let list = filteredEpisodes
        guard !list.isEmpty else { episodePage = 0; return }
        if let n = Int(q),
           let idx = list.firstIndex(where: { TMDBMatch.episodeNumber($0.name) == n }) {
            episodePage = idx / max(episodePageSize, 1)
        } else {
            episodePage = 0
        }
    }

    private var episodePageCount: Int {
        max(1, Int(ceil(Double(filteredEpisodes.count) / Double(max(episodePageSize, 1)))))
    }

    /// 当前页。页码越界时自动夹回（切换筛选/搜索后总数变小的情况）。
    private var pagedEpisodes: [Episode] {
        let all = filteredEpisodes
        let size = max(episodePageSize, 1)
        let page = min(episodePage, max(0, episodePageCount - 1))
        let start = min(page * size, max(0, all.count))
        let end = min(start + size, all.count)
        guard start < end else { return [] }
        return Array(all[start..<end])
    }

    private func episodeList(_ items: [Episode]) -> some View {
        // A chip fits about six characters before it truncates (《一…); longer names get rows.
        let longNames = (items.map { (episodeLabels[$0.id] ?? $0.name).count }.max() ?? 0) > 6
        // Under a full-width banner, long names fill columns rather than one stretched list.
        let rowColumns = isWide ? [GridItem(.adaptive(minimum: 320), spacing: 8)] : [GridItem(.flexible())]
        // TMDB's stills, when its season lines up with most of the episodes and has pictures for them; without
        // pictures the small chips read better than empty tiles. While TMDB is still looking, tiles with the episode
        // numbers, so its stills fade into the same tiles instead of chips turning into tiles.
        let stills = tmdb.episodes(items)
        let showsStills = items.count > 1
            && (stills.values.filter { $0.still != nil }.count * 2 >= items.count || (tmdbPending && items.count <= 60))
        let columns = showsStills ? [GridItem(.adaptive(minimum: TMDBMetrics.episodeTile), spacing: TMDBMetrics.spacing, alignment: .top)]
            : longNames ? rowColumns : [GridItem(.adaptive(minimum: episodeMin), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: showsStills ? TMDBMetrics.spacing : longNames ? 4 : 8) {
            ForEach(shownOrder(items)) { episode in
                let saved = download(episode)
                Group {
                    if showsStills {
                        Button { startRequest { await play(episode) } } label: {
                            TMDBEpisodeTile(name: episodeTitle(episode), info: stills[episode.id], loading: loadingEpisode == episode.id, width: nil)
                        }
                        .tmdbCardButton()
                        .overlay(alignment: .topTrailing) { if saved?.status == .completed { DownloadedBadge().padding(4) } }
                        .accessibilityLabel(episode.name)
                    } else if longNames {
                        EpisodeRow(name: episode.name, label: episodeLabels[episode.id], loading: loadingEpisode == episode.id, download: saved) {
                            startRequest { await play(episode) }
                        }
                    } else {
                        Chip(title: episodeLabels[episode.id] ?? episode.name, selected: loadingEpisode == episode.id, fill: true) { startRequest { await play(episode) } }
                            .overlay(alignment: .topTrailing) { if saved?.status == .completed { DownloadedBadge() } }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if store.favorites.contains(episodeFavorite(episode)) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: DownloadMetrics.thumb > 60 ? 18 : 12, weight: .semibold))
                            .foregroundStyle(Brand.rose)
                            .padding(4)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .contextMenu {
                    // The file name a label stands for: its resolution and codec can matter on a netdisk line.
                    if episodeLabels[episode.id] != nil { Text(episode.name) }
                    FavoriteMenuButton(item: episodeFavorite(episode), name: episode.name)
                    if saved == nil || saved?.status == .failed {
                        Button(L10n.text("Download"), systemImage: "arrow.down.circle") {
                            DownloadLibrary.shared.download(DownloadSource(site: client.site, videoID: video.id, episode: episode, origin: client.origin),
                                                            title: video.name, poster: video.poster, posterHeaders: video.posterHeaders)
                        }
                    } else if let saved {
                        Button(L10n.text(saved.status == .completed ? "Delete Download" : "Cancel Download"), systemImage: "trash", role: .destructive) {
                            DownloadLibrary.shared.remove([saved.id])
                        }
                    }
                }
            }
        }
        #if os(tvOS)
        // Room for the focused glass row, which grows toward the trailing edge.
        .padding(.trailing, 16).padding(.vertical, 6)
        #endif
        .tvFocusSection()
        .animation(.smooth(duration: 0.4), value: showsStills)
    }
    /// Mac and iPad, under the banner: TMDB hasn't answered yet. Short-drama-length lists stay chips (see episodeList).
    private var tmdbPending: Bool {
        #if os(tvOS)
        false
        #else
        isWide && (tmdb.phase == .looking || (tmdb.phase == .idle && TMDBLookup.applies(to: client.site)))
        #endif
    }
    private var episodeMin: CGFloat {
        #if os(tvOS)
        170
        #else
        // Room for 第 10 集 / 第01集 without an ellipsis.
        100
        #endif
    }
    private func download(_ episode: Episode) -> DownloadItem? {
        DownloadLibrary.shared.item(for: DownloadSource(site: client.site, videoID: video.id, episode: episode, origin: client.origin))
    }
    private func play(_ episode: Episode, skipAccountCheck: Bool = false) async {
        #if DEBUG
        oneSkinLog("play episode=\(episode.name) flag=\(episode.flag) busy=\(busy)")
        #endif
        guard !busy else { return }
        // A downloaded episode plays from the device: no link to fetch, and it works offline.
        if let saved = download(episode), saved.status == .completed {
            store.playing = DownloadLibrary.shared.channel(for: saved)
            return
        }
        // Cloud-drive plugins wait for an in-app login that cannot appear on this platform,
        // which surfaces only as a 60-second timeout. Ask for the account up front instead.
        if !skipAccountCheck, let drive = CloudDrive.missingLogin(forFlag: episode.flag) {
            withAnimation(.smooth(duration: 0.25)) {
                playbackIssue = PlaybackIssue(episode: episode, message: drive.loginHint, drive: drive, blockedBeforeRequest: true)
            }
            return
        }
        busy = true; loadingEpisode = episode.id
        withAnimation(.smooth(duration: 0.2)) { playbackIssue = nil }
        defer { busy = false; if !choosingQuality { loadingEpisode = nil } }
        do {
            let plan = try await client.preparePlayback(episode)
            try Task.checkCancellation()
            if plan.choices.count > 1 {
                pendingPlan = plan; pendingEpisode = episode; choosingQuality = true
            } else {
                let playback = store.subscription.map { client.applying($0) } ?? client
                let resolved = try await playback.resolvePlayback(plan, choice: plan.choices[0])
                try Task.checkCancellation()
                store.playing = store.catalogChannel(resolved, video: currentVideo(), episode: episode, client: playback)
                #if DEBUG
                oneSkinLog("play OK url=\(String(describing: resolved.url).prefix(90))")
                #endif
            }
        } catch {
            #if DEBUG
            oneSkinLog("play FAIL \(error)")
            #endif
            fail(episode, error)
        }
    }
    private func resolve(_ plan: PlaybackPlan, choice: PlaybackChoice, episode: Episode) async {
        busy = true; loadingEpisode = episode.id
        defer { busy = false; pendingPlan = nil; pendingEpisode = nil; loadingEpisode = nil }
        do {
            let playback = store.subscription.map { client.applying($0) } ?? client
            let resolved = try await playback.resolvePlayback(plan, choice: choice)
            try Task.checkCancellation()
            store.playing = store.catalogChannel(resolved, video: currentVideo(), episode: episode, client: playback)
        } catch { fail(episode, error) }
    }
    private func retryAfterSignIn() {
        if let episode = playbackIssue?.episode { startRequest { await play(episode) } }
    }
    private func fail(_ episode: Episode, _ error: Error) {
        #if DEBUG
        oneSkinLog("fail \(episode.name): \(error)")
        #endif
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        // [融合修正] 原来这里调 `CloudDriveLoginRequired(bundleMessage:)`，
        // 但那个初始化器在全仓库都不存在（备份分支也没有）——这行一直是编译不过的死代码，
        // 只是本文件此前没进 target 才没暴露。改为按错误文本判断，语义不变：
        // 网盘要求登录时，错误描述里会带驱动名。
        let login = error as? CloudDriveLoginRequired ?? CloudDriveLoginRequired.matching(message: error.localizedDescription)
        // A drive that needs signing in is expected, not a failure to report.
        if login == nil {
            Diagnostics.shared.failure("catalog", "play \(client.reportContext) flag=\(episode.flag)", error)
        }
        withAnimation(.smooth(duration: 0.25)) {
            // Plugins report a missing or expired drive login in their own words ("夸克授权失败，请扫码登录");
            // say what happened and offer the sign-in instead of echoing them.
            if let login, let drive = CloudDrive(rawValue: login.rawValue) {
                playbackIssue = PlaybackIssue(episode: episode, message: drive.expiredHint, drive: drive, blockedBeforeRequest: false)
            } else if let provider = CatPawSignIn.provider(for: error.localizedDescription) {
                // Signed in, but the bundle wants a token its own code gives; signing in again would change nothing.
                playbackIssue = PlaybackIssue(episode: episode, message: L10n.text("You're signed in to UC, but this source plays UC accounts without premium through UC's TV app, which needs a token of its own. Get it once with the UC Browser app, or choose another line."),
                                              drive: nil, blockedBeforeRequest: false, signIn: provider)
            } else if let drive = CloudDrive(flag: episode.flag), CloudDrive.isLoginFailure(error.localizedDescription) {
                playbackIssue = PlaybackIssue(episode: episode, message: drive.expiredHint, drive: drive, blockedBeforeRequest: false)
            } else {
                playbackIssue = PlaybackIssue(episode: episode, message: error.localizedDescription,
                                              drive: CloudDrive.missingLogin(forFlag: episode.flag), blockedBeforeRequest: false)
            }
        }
    }

    /// This video's playback scopes (`PlaybackHistoryContext.id`); the details may carry another ID than the list's.
    private var watchScopes: Set<String> {
        let origin = client.site.origin(or: client.origin)
        return Set([video.id, detail?.id].compactMap { $0 }.map { EpisodeSkipSettings.scope(origin: origin, source: client.site.sourceKey, video: $0) })
    }
    /// Whether opening this page should land on the episode list instead of a cover.
    ///
    /// A video of several episodes with nothing watched before has no single episode to
    /// start: the first one may be the wrong line, and the previous behaviour left the
    /// viewer on a Play button that opened the very list they now get directly.
    private var opensIntoEpisodes: Bool {
        #if os(iOS)
        guard watchLayout, activeEpisodes.count > 1 else { return false }
        return watchHistory == nil
        #else
        return false
        #endif
    }
    /// Where the viewer stopped last time, for Continue.
    private var watchHistory: PlaybackHistoryEntry? {
        store.visibleHistory.first { watchScopes.contains($0.context.id) }
    }
    /// The line of the episode playing, else of the one watched last, while the details still have it: the page opens
    /// on that line so the episode shows in its list, not on the first line (#362).
    private var watchedFlag: String? {
        guard let episodes = detail?.episodes else { return nil }
        #if os(iOS)
        let context = watchChannel?.historyContext ?? watchHistory?.context
        #else
        let context = watchHistory?.context
        #endif
        return context?.episode(in: episodes)?.flag
    }

    #if os(iOS)
    // MARK: iPhone watch page

    private var watchLayout: Bool { WatchPage.applies(sizeClass, verticalSizeClass) }

    /// Landscape on a phone held sideways: the page splits left/right rather than stacking — the picture
    /// on the left, the episode list on the right. A phone held sideways is compact in both directions
    /// (`compact × compact`). The Duo's *folded outer* display in portrait reports `regular × compact`,
    /// which `verticalSizeClass == .compact` alone mistook for sideways and wrongly split; requiring the
    /// horizontal class too keeps the outer portrait a single stacked column (video on top, details below).
    private var landscapePage: Bool { sizeClass == .compact && verticalSizeClass == .compact }
    /// iPhone Duo's inner display: still a phone (`idiom == .phone`) but regular in both directions.
    /// It is not "held sideways" — it is a real folded-out tablet-sized screen — so it uses the same
    /// two-column layout as a landscape phone (picture on the left, synopsis + episodes on the right).
    /// A real iPad (`idiom == .pad`) never reaches here: `WatchPage.applies` keeps it on the plain
    /// detail page.
    private var duoExpanded: Bool {
        #if DEBUG
        // `-qaDuoExpanded 1` renders this branch anywhere, so the folded-out layout can be photographed
        // without an iPhone Duo simulator — that model needs an iOS 27.1 runtime, and on a machine that
        // only has 26.5 / 27.0 the device type refuses to be created at all.
        if UserDefaults.standard.bool(forKey: "qaDuoExpanded") { return true }
        #endif
        // The Duo unfolded is a tablet-sized screen, much wider than the folded outer cover. Held upright
        // its classes report `.regular × .regular`; held sideways they report `.regular × .compact`, the
        // *same classes as the folded outer cover*. So the classes alone can't tell unfolded from folded —
        // the width can: wide = unfolded, narrow = folded.
        // A landscape phone (compact × compact) is wide too, but it is NOT the Duo unfolded — it keeps its
        // immersive single-surface layout. Only a regular-width phone (the Duo's inner display) can be unfolded.
        return UIDevice.current.userInterfaceIdiom == .phone
            && sizeClass == .regular
            && (containerWidth > 600 || verticalSizeClass == .regular)
    }
    /// Whether the screen itself is genuinely wider than tall. The Duo's inner display held sideways
    /// reports `regular × .regular` in practice (the size class does NOT flip to `.compact` as the
    /// comment above assumed), so a `verticalSizeClass` test misreads the unfolded landscape as upright.
    /// `screen.bounds.width > height` is no better: the inner display reports its *native* portrait
    /// bounds (2007×2853) even while its `interfaceOrientation` is `.landscapeLeft/Right` (rot90), so a
    /// bounds comparison always read "upright" and the unfolded landscape borrowed the portrait
    /// full-bleed layout. The interface orientation is discrete and cannot sit at the width:height
    /// critical point during the unfold/rotate animation, so it is the stable signal that keeps the
    /// two unfolded shapes — landscape column vs portrait full-bleed — independent.
    private var landscapeScreen: Bool {
        switch UIApplication.shared.appWindowScene?.interfaceOrientation {
        case .landscapeLeft, .landscapeRight: return true
        default: return false
        }
    }
    /// [mi3s] 二开：Duo 摊开后默认**留在竖屏**（单列：画面在上、详情与选集在下）。
    /// 想看双列就把设备转横 —— 不再一展开就强制横屏。
    ///
    /// 原来这里有三层「强制 sideways」：`unfoldingToLandscape`（落向横屏的轮询窗口）、
    /// `unfoldedLandscapeHolds`（轮询失败后继续硬撑双列），外加 `landLandscape()`
    /// 主动请求旋转。结果是「展开 = 双屏」，用户要的竖屏形态永远看不到。整套已删除：
    /// `landscapeScreen` 只在设备**真的**横过来时才为真。
    private var sideways: Bool { duoExpanded && landscapeScreen }

    private var portraitExpanded: Bool { duoExpanded && !sideways }
    /// The page is laid out left/right — picture on one side, details and episodes beside it — rather
    /// than stacked. True for a phone held sideways and for the unfolded Duo held sideways; Full
    /// Screen owns the whole display instead, so it never splits.
    private var splitsWatchPage: Bool { (landscapePage || (duoExpanded && sideways)) && !fullScreen }
    /// What plays at the top of the page: one of this video's episodes.
    private var watchChannel: Channel? {
        store.playing.flatMap { watchScopes.contains($0.historyContext?.id ?? "") ? $0 : nil }
    }
    /// The episode playing, else the one watched last: marked in the list, which scrolls to it.
    private var currentEpisodeID: Episode.ID? {
        guard let episodes = detail?.episodes else { return nil }
        return (watchChannel?.historyContext ?? watchHistory?.context)?.episode(in: episodes)?.id
    }

    /// As in Bilibili's app: the player at the top, under the status bar, and the title, actions, synopsis and
    /// episodes scrolling below it. Full Screen grows the same player over the page, so playback carries on.
    ///
    /// One structure for every shape of the phone. The picture sits at the top of the page with the details
    /// and episode list under it; held sideways — and on the unfolded Duo's wide inner display — the same two
    /// pieces are laid out left/right instead. `AnyLayout` swaps the *axis*, never the views, so the player
    /// keeps its identity through every fold, turn and Full Screen. It used to be written once per branch
    /// (stacked, split, and a third full-bleed one for the upright unfolded Duo), which tore the view down
    /// and rebuilt it on each move: the `AVPlayerLayer` left the window (AVKit answered with a second,
    /// unwanted Picture in Picture window), playback re-ran its setup, and the page's orientation hold was
    /// released mid-turn — the picture, and then the whole page, drifted.
    @ViewBuilder private var watchBody: some View {
        // [mi3s] 二开：One 皮肤。开关在设置里（`OneSkinPreferencePanel`），
        // 存 `UserDefaults` 的 `oneSkinEnabled`。关着就走下面原版 `upstreamWatchBody`，
        // 一个字节的版式都没换。
        if oneSkinActive {
            // [mi3s] One 皮肤整屏独立：不吃上一层的列宽/内边距，
            // 自己从全屏尺寸开始排版（横屏双列必须拿到完整宽高）。
            oneSkinBody
                // ★ 选集页**只让画面上边越界，底部要留给菜单栏**。
                //
                // 原来是无条件 `.ignoresSafeArea()`（四个方向全忽略）——
                // OneSkin 会一路铺到屏幕最底，把底部标签栏整个盖住。
                // 用户报「选集播放页应该保留原本的菜单栏」，根因就是它：
                // `TabBarHider` 的日志证明标签栏的 isHidden 一直是 false
                // （`want=false now=false`），它没被藏，是被盖了。
                //
                // 全屏时必须继续全忽略，否则四周的 letterbox 会留出白边。
                .ignoresSafeArea(edges: fullScreen ? .all : [.top, .horizontal])
                // ★ 光「不忽略底部」还不够：iOS 26 的液态玻璃标签栏是**浮层**，
                // 它不撑大 `safeAreaInsets`，系统只给 34pt Home 指示条 ——
                // 选集卡片会从玻璃下面穿过去、被压掉半行（截图逐像素量过）。
                // 让哪一边看方向：竖持让底边（底部胶囊），横持让右边（贴右缘的竖排胶囊）。
                // 全屏两边都归零（全屏本来就没有菜单栏）。
                // 竖持：底部浮动胶囊（约 50pt，浮在 34pt Home 指示条之上）。
                // 与右边同理用 `padding` 而不是 `safeAreaPadding` —— 两条边一个写法，
                // 免得下次又要在「安全区 vs 内缩」上猜一遍。让位条由下面的 pageBase 垫底。
                .padding(.bottom, oneSkinTabReserve.bottom)
                .padding(.trailing, oneSkinTabReserve.trailing)
                // 让位出来的那一条不能露系统页面底色（浅灰一条，比压住内容更难看）。
                // 用 One 自己的整页底色垫在下面：海报渐变在页边本来就近黑，接缝看不出来。
                .background(OneSkinPalette.pageBase.ignoresSafeArea())
                // OneSkin 用 `OneSkinFixedPicture` 自绘画面，但 session 由
                // PlaybackView 的 `onAppear` 启动、`opened:` 回调交回来。
                // 所以这里仍挂一份离屏的 PlaybackView —— 但**只要 session，
                // 不要它的画面层**（stageOnly）；否则会多一个
                // AVPlayerViewController 与选集页的 AVPlayerLayer 抢 player，
                // 竖屏片源最容易变成黑屏「看不了」。见 PlaybackView.stageOnly。
                .background(alignment: .topLeading) {
                    // 用 offset 推到屏幕外而不是 opacity：opacity 极低时 SwiftUI
                    // 可能跳过子树渲染，`onAppear` / `opened:` 就不触发。
                    oneSkinSessionStage
                        .frame(width: 8, height: 8)
                        .offset(x: -4000, y: -4000)
                        .allowsHitTesting(false)
                }
                // [mi3s] 系统栏位（状态栏 / 导航栏 / 标签栏 / Home 指示条）
                // 已经**不在这一支里写**了 —— 见 `body` 里 `watchBody` 外层挂的
                // `WatchSystemChrome`。判据只有 `fullScreen` 一个，两条渲染分支共用，
                // 不会再出现「改了一边漏了另一边」。
        } else {
            upstreamWatchBody
        }
    }

    /// One 观看页三态。判据**全部来自离散信号**，不看容器宽高比：
    ///   split      = Duo 摊开 + 横持（sideways），或手机横持（landscapePage）
    ///   fullBleed  = Duo 摊开 + 竖持（portraitExpanded）＝「展开宽屏」
    ///   column     = 其余（折叠态 / 立式手机）
    ///
    /// 2026-11-09：这里原来用 `containerWidth > containerHeight` 判 split。
    /// 容器尺寸在折叠 / 旋转动画里是**连续量**，会在临界点反复翻转；
    /// 而 `containerWidth/Height` 又是 `.onGeometryChange` 写回的 @State，
    ///   于是形成「改布局 → 再量到新尺寸 → 再改形态」的自激环，表现为两种展开态
    /// 分不开、控件坐标每帧漂移。`sideways` 只看 `interfaceOrientation`
    /// （离散）、`duoExpanded` / `landscapePage` 只看 size class（离散），
    /// 形态一旦定下就不会因亚点尺寸变化而抖动。
    private var oneSkinShape: OneSkinShape {
        #if DEBUG
        // VM / 模拟器没有折叠与旋转接口，这两个开关用来无人值守地
        // 分别拍下「展开宽屏」和「展开横屏」，确认两态确实不同。
        if UserDefaults.standard.bool(forKey: "qaOneSkinWide") { return .fullBleed }
        if UserDefaults.standard.bool(forKey: "qaOneSkinSideways") { return .split }
        #endif
        if duoExpanded {
            // 展开宽屏 vs 展开横屏：只差 `sideways`（设备 interfaceOrientation）。
            return sideways ? .split : .fullBleed
        }
        return landscapePage ? .split : .column
    }

    @AppStorage(OneSkin.enabledKey) private var oneSkinEnabled = true  // [临时验证] 默认开，QA 参数传不进 Fig-clone
    @AppStorage(OneSkin.speedKey) private var oneSkinSpeed: Double = 1

    /// [mi3s] QA 强制开关：启动参数 `-qaOneSkin`（或 `qaOneSkin=1`）时强制启用皮肤，
    /// 免去验证时和 cfprefsd 抢 UserDefaults 的麻烦。普通用户走 `oneSkinEnabled`（设置页）。
    private var oneSkinActive: Bool {
        // 同 key 在 OneSkinPreferencePanel 里也是 @AppStorage；两处默认值必须一致，
        // 否则谁先构造谁决定实际值（曾因那边默认 false 导致皮肤永远不生效）。
        oneSkinEnabled || UserDefaults.standard.bool(forKey: "qaOneSkin")
    }

    /// 选集页要给菜单栏让出的空间。
    ///
    /// iOS 26 的标签栏是浮层、不进 `safeAreaInsets`，所以必须自己让位；
    /// 而且**形状随方向变**：竖持是底部横胶囊，横持是贴右缘的竖胶囊。
    /// 只让底边是之前「横屏内容被菜单栏盖住」的原因（Duo 内屏截图逐像素量过）。
    private var oneSkinTabReserve: (bottom: CGFloat, trailing: CGFloat) {
        // ⛔ 底部菜单已折起（WatchSystemChrome.oneSkin → tabBar 恒收，2026-11-09）：
        // 液态玻璃胶囊不再渲染，两向让位全部归零。保留判据注释以防回退时误读：
        // 竖持让底边、横持让右边（Duo 内屏 regular×regular 的 size class 判据不可用，
        // 必须看 landscapeScreen）。
        guard !fullScreen else { return (0, 0) }
        if landscapeScreen { return (0, 0) }
        return (0, 0)
    }

    // MARK: One 皮肤用到的三处取值
    // 观看页把「在播的是哪一集」「是不是本站播放」「跳 10 秒」这三件事原本写在各处内联表达式里，
    // 皮肤层需要具名入口，就在这里收一次，不复制上游逻辑。

    /// 在播的那一集；没在播就是列表里的第一集。
    private var currentEpisode: Episode? {
        if let id = currentEpisodeID { return activeEpisodes.first { $0.id == id } }
        return activeEpisodes.first
    }

    /// 这一页自己正在播（而不是别处有小窗或在推流）。
    private var playingOnThisPage: Bool {
        guard let channel = watchChannel else { return false }
        return store.playing == channel
    }

    /// 前后跳 10 秒，走播放器自己的 `skip(_:)`。
    private func skip(by seconds: Double) {
        playerSession?.skip(seconds)
    }

    /// 为**每条线路**解析出可测速的真实播放地址。
    ///
    /// 为什么要逐线解析、而不是直接拿 `episode.address`：
    /// type 3/4（CatPaw / 苹果CMS 播放器接口）的 `address` 只是个 play 参数，
    /// 必须过 `preparePlayback` + `resolvePlayback` 才变成可请求的流地址。
    /// 拿原始字符串去 HEAD，测的是一个不存在的 URL，数字纯属摆设。
    ///
    /// 每条线路取「当前正在看的这一集」；该线没有这一集时退回它的首集。
    /// 并发解析、失败即跳过 —— 测不出的线路在菜单里不显示数字，不编造。
    private func buildLineSamples() async {
        guard let episodes = detail?.episodes, !flags.isEmpty else {
            await MainActor.run { lineSamples = [:] }
            return
        }
        let playing = episodes.first { $0.id == currentEpisodeID }
        let lines = flags
        // `subscription` 是主线程隔离的，先在主线程取好快照，再并发解析。
        let base = client
        let playback = store.subscription.map { client.applying($0) } ?? client

        let resolved = await withTaskGroup(of: (String, OneSkinLineSample?).self) { group in
            for flag in lines {
                let onLine = episodes.filter { $0.flag == flag }
                guard let ep = onLine.first(where: { $0.id == playing?.id }) ?? onLine.first else {
                    continue
                }
                group.addTask {
                    do {
                        let plan = try await base.preparePlayback(ep)
                        guard let choice = plan.choices.first else { return (flag, nil) }
                        let channel = try await playback.resolvePlayback(plan, choice: choice)
                        return (flag, OneSkinLineSample(url: channel.url, headers: channel.headers))
                    } catch {
                        return (flag, nil)
                    }
                }
            }
            var out: [String: OneSkinLineSample] = [:]
            for await (flag, sample) in group {
                if let sample { out[flag] = sample }
            }
            return out
        }

        await MainActor.run { lineSamples = resolved }
    }

    /// ⛔ 换集修复（2026-11-09）：选集页画面必须绑到「真正在播」的那一个 AVPlayer。
    ///
    /// `Store.playbackSession(for:)` 遇到新 channel 会**新建一个空会话**；但
    /// `PlaybackView` 的 `@State session` 在视图身份不变时不会跟着 init 参数换，
    /// 而是由 `.onChange(of: channel)` 在**原 player** 上替换 currentItem
    ///（上游就是这么设计换集的）。换集后两边就此分叉：`oneSkinBody` 若仍用
    /// `store.playbackSession(for: watchChannel)`，会把 `OneSkinFixedPicture`
    /// 绑到一个没有 item 的新 player 上，只剩海报虚化；声音却还在旧 player
    /// 上播 —— 用户看到的「换集后播放器不渲染新内容」。
    ///
    /// `playerSession` 由离屏 stage 的 `onStageSession` / `opened:` 交回，指向
    /// PlaybackView 实际持有的会话，换集时保持不变，正好长期一致。
    /// `??` 右侧延迟求值：只有首次 `onAppear` 之前才回退到 store（此时两者本就
    /// 是同一个对象）；换集后 `playerSession` 已有值，不会再新建空会话。
    private var oneSkinStageSession: PlaybackSession? {
        playerSession ?? watchChannel.map { store.playbackSession(for: $0) }
    }

    /// One 版式：黑底一列，画面→控制条→标题→主按钮→标签→选集。
    /// 画面仍是同一套播放引擎，只是把画面当成一个 View 传进去，皮肤层不认识 `PlaybackSession`。
    @ViewBuilder private var oneSkinBody: some View {
        OneSkinStage(
            video: video,
            detail: detail,
            current: currentEpisode,
            playing: playingOnThisPage,
            busy: busy,
            aspectRatio: max(playerAspectRatio, 0.4),
            shape: oneSkinShape,
            // 片源身份：字幕文件、请求头、片头片尾 scope、上下集都靠它（成员顺序在 shape 之后）。
            channel: watchChannel,
            // ⛔ 换集修复：画面与画质菜单都用「真正在播」的会话，
            // 不能每集重新 `store.playbackSession(for:)` 取一个空会话。
            // 详见 `oneSkinStageSession` 注释。
            avPlayer: oneSkinStageSession?.player,
            session: oneSkinStageSession,
            // One 的进度条两端是「已播 / −剩余」，没有真值就画不出进度。
            // session 是 @Observable，这两个值变化会带着皮肤一起重绘。
            position: playerSession?.position ?? 0,
            duration: playerSession?.duration ?? 0,
            // 这里曾传 `picture: { watchStage }`，但 OneSkinStage 从未调用它
            //（画面由 OneSkinPlayerLayer + avPlayer 自绘）。真正的 PlaybackView 是
            // 下面 oneSkinBody 上挂的 `.background(watchStage)`，它负责触发 session.prepare。
            onBack: {
                // [mi3s] 二开：返回分两层，和上游 `leavePlayer()` 同义。
                // 全屏里点返回 = 退出全屏，回到**选集页**继续播（画面、进度、选集都在）；
                // 只有本来就不在全屏时，才是真的离开这一页。
                // 原来这里无条件 `dismiss()`，用户在全屏里点返回直接被踢回首页，
                // 正在播的那一集只剩小窗 —— 就是「返回直接全退」。
                leavePlayer()
            },
            // 一键退全屏：只改状态，不碰页面栈。控件层全屏时的返回走这条路。
            onExitFullScreen: { exitFullScreen() },
            onPlay: { episode in
                Task { await play(episode) }
            },
            onTogglePlay: {
                // 上游没有单独的暂停/继续入口：停止走 store，继续就再播当前集。
                // ⛔ 停止必须走 `store.stopPlaying()`：裸赋 `playing = nil` 会跳过
                // session.stop()（历史保存 / 流清理 / 弹幕清空 / upcoming 取消），
                // Store.playing.didSet 只把对象置 nil —— 与 Store.swift:343 注释
                // 「playing = nil alone skips that teardown and leaks」一致。
                if playingOnThisPage {
                    store.stopPlaying()
                } else if let episode = currentEpisode ?? activeEpisodes.first {
                    Task { await play(episode) }
                }
            },
            onSeekBack: {
                skip(by: -10)
            },
            onSeekForward: {
                skip(by: 10)
            },
            onSeekTo: { fraction in
                // 进度条松手：把 0…1 换算成秒再定位。
                // 时长未知（live / 刚起播）时忽略，不猜。
                guard let session = playerSession, session.duration > 0 else { return }
                session.seek(to: session.duration * fraction)
            },
            onFullScreen: {
                #if DEBUG
                #endif
                setFullScreen(landscape: playerAspectRatio > 1)
            },
            onEpisodes: {
                // 本页的抽屉只认 `showsAllEpisodes`。
                //
                // 曾经这里写的是 `store.showsEpisodes`（上游全屏播放器的键），
                // 于是「点选集没反应」：本页的 sheet 读的是 @State，而 store 那个键
                // 在本页没有宿主，只留下一个 true 的脏状态。
                // 闭包捕获 @State 包装器本身、共享同一存储，写它是有效的 ——
                // 之前判定「写入被副本丢弃」是误诊，真正写错的是键。
                showsAllEpisodes = true
            },
            onToggleSkin: {
                withAnimation(.smooth(duration: 0.25)) { oneSkinEnabled = false }
            },
            onDownload: {
                choosingDownloads = true
            },
            onFavorite: {
                store.favorites.toggle(videoFavorite())
            },
            onShare: {
                // One 分享的是稳定链接（TMDB 页），没有就静默（ShareLink 同样会隐藏）。
                if let link = tmdb.details?.link {
                    #if !os(tvOS)
                    let activity = UIActivityViewController(activityItems: [link], applicationActivities: nil)
                    if let scene = UIApplication.shared.appWindowScene,
                       let root = scene.keyWindow?.rootViewController {
                        var presenter = root
                        while let presented = presenter.presentedViewController { presenter = presented }
                        if let pop = activity.popoverPresentationController {
                            pop.sourceView = presenter.view
                            pop.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
                        }
                        presenter.present(activity, animated: true)
                    }
                    #endif
                }
            },
            isFavorite: store.favorites.contains(videoFavorite()),
            lines: flags,
            activeLine: activeFlag,
            lineSamples: lineSamples,
            onSelectLine: { flag in
                // 复用上游 watchLines 的换线逻辑：换 flag 后播「续上当前集」的那一集。
                let previous = activeFlag
                selectedFlag = flag
                guard watchChannel != nil, let episodes = detail?.episodes else { return }
                let playing = episodes.first { $0.id == currentEpisodeID }
                guard let same = episode(on: flag, matching: playing, in: episodes) else {
                    selectedFlag = previous
                    withAnimation(.smooth(duration: 0.2)) { lineNotice = L10n.text("This line doesn't have this episode.") }
                    Task { try? await Task.sleep(for: .seconds(4)); withAnimation(.smooth(duration: 0.2)) { lineNotice = nil } }
                    return
                }
                if same.id != currentEpisodeID { startRequest { await play(same) } }
            },
            onRotate: {
                // 横竖屏切换：按**当前方向**反向转。PlayerOrientation 会同时调整允许的方向掩码。
                // ⛔ 不能用 screen.bounds 的宽高比：VM 上它恒报竖屏原值（466×678），
                // 不随 interfaceOrientation 交换 —— 实际已横屏时仍算出 landscape=true，
                // 旋转键永远请求横屏、转不回竖屏。interfaceOrientation 是离散信号，
                // 与本文件 landscapeScreen 同一来源。
                let nowLandscape = UIApplication.shared.appWindowScene.map { scene in
                    switch scene.interfaceOrientation {
                    case .landscapeLeft, .landscapeRight: return true
                    default: return false
                    }
                } ?? false
                PlayerOrientation.set(landscape: !nowLandscape)
            },
            onMiniPlayer: {
                // 唯一入口：视频控件里的「缩成小窗」。
                // 先置**手动开关**，再离开观看页 —— 小窗只认这个开关，不认「是否在观看页」。
                store.miniPlayerActive = true
                dismiss()
            },
            onFold: {
                // 合拢/展开由 OneSkinStage 自己的 `folded` 驱动，这里只留钩子。
            },
            // 「复制视频链接」「用外部播放器打开」都吃当前直链。
            streamURL: watchChannel?.url,
            streamHeaders: watchChannel?.headers ?? [:],
            // 全屏态：OneSkin 之前完全没接这个状态，皮肤下点全屏没有任何变化。
            isFullScreen: fullScreen
        )
        // 倍速是皮肤自己的开关，但要真的落到播放器上；开关变了才下发，避免每次重绘都设一遍。
        .onChange(of: oneSkinSpeed) { _, value in
            playerSession?.setSpeed(Float(value))
        }
        .onAppear {
            if oneSkinSpeed != 1 { playerSession?.setSpeed(Float(oneSkinSpeed)) }
        }
        // [mi3s] 方向锁 / 转屏 / 折展收全屏 / 换集清会话，全部**不在这里写**：
        // 已统一到 `watchPageLifecycle()`，由 `body` 在 `watchBody` 外层挂一次。
        // 之前这里和 upstream 分支各写一套：皮肤开着时 upstream 那套根本不执行，
        // 方向锁与「折回外屏撤全屏」就跟着失效。
    }

    @ViewBuilder private var upstreamWatchBody: some View {
        // The picture's own shape, never a fixed 16:9 box: a 4:3 or a 2.35:1 film fills it exactly, so
        // the bars the old box drew inside the player are gone. The page reports what the stream is;
        // 16:9 is only the guess until it does.
        let ratio = max(playerAspectRatio, 0.4)
        let side = containerWidth > 0 ? containerWidth : 390
        // Landscape splits the page left/right instead of stacking, as One does: the picture keeps the
        // width it needs and the episode list uses the space beside it rather than below. A Duo unfolded
        // does the same across its wide inner display. Upright — the folded outer cover and the unfolded
        // inner display alike — stacks one column, picture on top, details and episodes below.
        let splits = splitsWatchPage
        // The folded-out Duo gives the right column a clamped share: wide enough for the episode tiles
        // and the synopsis, narrow enough to leave the picture room. Clamping to a range (instead of a
        // raw fraction) also stops the measured width feeding back into the column width and shrinking
        // the page turn after turn.
        let detailWidth = splits ? (duoExpanded ? min(max(containerWidth * 0.36, 300), 460) : max(0, containerWidth * 0.42)) : 0
        let playerWidth = splits ? max(1, side - detailWidth) : side
        // The picture keeps the stream's shape and takes at most half the upright screen, so the episode
        // list is on screen under it — on the unfolded Duo too, which used to hide that list behind a
        // half-height sheet while the picture owned the whole display. Full Screen is the way to give the
        // picture everything.
        let tall = containerHeight > 1 ? containerHeight : side * 1.6
        let pictureHeight = min(playerWidth / ratio, tall * 0.5)
        let stageHeight: CGFloat? = fullScreen ? nil : (splits ? max(1, tall) : max(1, pictureHeight))
        let axis = splits ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        ZStack(alignment: .top) {
            // Black belongs behind the picture, not behind the page: in the split layout a full-height
            // black band behind the details column left black text on black in light mode. Full Screen is
            // one black surface, so it keeps the plain black behind everything.
            if fullScreen || splits { Color.black.ignoresSafeArea() }
            axis {
                watchStage
                    .frame(width: splits ? playerWidth : nil, height: stageHeight)
                    .frame(maxWidth: fullScreen ? .infinity : nil, maxHeight: fullScreen ? .infinity : nil)
                if !fullScreen {
                    ScrollView {
                        watchDetails
                            .padding(.horizontal, splits ? Layout.gutter : 16)
                            .padding(.top, splits ? 16 : 14)
                            // The column runs to the physical bottom edge (the page hides the status bar
                            // and the tab bar's inset does not reach this pushed page), so the last card
                            // needs its own reserve or the home indicator cuts its caption.
                            .padding(.bottom, splits ? 48 : 24)
                    }
                    .scrollIndicators(.never)
                    .frame(width: splits ? detailWidth : nil)
                    .overlay(alignment: .leading) {
                        // A hairline between the picture and the details column, so the two-column page
                        // reads as two surfaces rather than text glued to the picture's edge.
                        if splits { Rectangle().fill(Color.primary.opacity(0.25)).frame(width: 1.5) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // [mi3s] 系统栏位与页面生命周期**不在这里写**：
        // 已提到 `body` 里 `watchBody` 的外层（`WatchSystemChrome` + `watchPageLifecycle`），
        // 与 One 皮肤那条分支共用同一份实现、同一个判据。
    }

    /// 选集播放页的生命周期 —— **两条渲染分支共用一份**。
    ///
    /// 为什么必须共用：这些钩子此前只挂在 `upstreamWatchBody` 上。One 皮肤开关一打开，
    /// `watchBody` 走的是 `oneSkinBody` 那一支，于是方向锁、转屏监听、
    /// 换集清会话、离页收回 scope 集体失踪 —— 表现是「皮肤开着，转屏行为和装了两个 App 一样」。
    ///
    /// 规则本身只留一处，改一次两边都生效：
    ///   · 折叠态钉竖屏、展开后交还给设备（不主动请求横屏）；
    ///   · **转屏不再自动进全屏**：横屏就是双列选集页，全屏只由全屏键进入；
    ///   · 换集清掉上一集的会话；离页收回页面 scope、解除方向锁。
    private func watchPageLifecycleBody<Content: View>(_ content: Content) -> some View {
        content
            .onAppear {
                store.watchPageScopes.formUnion(watchScopes)
                // 回到观看页，小窗授权作废 —— 否则从观看页退回后小窗会再次自动弹出。
                // （开关只由控件里的「缩成小窗」写入，这里负责在画面回到页内时收回。）
                store.miniPlayerActive = false
                // ★ One 皮肤开着的选集页**不钉竖屏**：
                // 用户的要求是「横屏竖屏一样，都保留菜单栏」，而横屏必须真的能转过去
                // 才谈得上双列选集页。上游那套「观看页恒竖屏、只有全屏才转」在
                // 皮肤下会让转屏变成空操作（`holdPortrait` 把 mask 锁成 `.portrait`）。
                // 皮肤关着仍按上游：折叠钉竖、展开松手。
                if oneSkinActive {
                    PlayerOrientation.holdPortrait(false)
                } else {
                    PlayerOrientation.holdPortrait(!duoExpanded)
                }
                #if DEBUG
                // QA：`-qaWatchFullScreen 1` 直接进全屏，用来给「全屏控件层」截图
                // （真机上要靠点全屏键，模拟器不好触发）。
                if UserDefaults.standard.bool(forKey: "qaWatchFullScreen"), !fullScreen {
                    setFullScreen(landscape: true)
                }
                // QA：`-qaRotateCycle <秒>` 在**同一个进程内**反复真旋转。
                // 用来回归「横竖屏来回切，界面/控件是否累积推移、是否要重启才恢复」：
                // 每轮横→竖→横，对比首尾截图的竖直分界线 x 坐标即可。
                // 历史上这个 bug 反复出现却没被抓住，就是因为每次都靠人手转一次、
                // 看一眼，没有可重复的来回切换证据。
                let rotateEvery = UserDefaults.standard.double(forKey: "qaRotateCycle")
                // `onAppear` 在转屏时可能被重复调用；没有这道闸会启动多个并行
                // 定时器互相抢方向（实测日志出现三连 landscape，动画中间态失控）。
                if rotateEvery > 0, !Self.qaRotateCycleRunning {
                    Self.qaRotateCycleRunning = true
                    Task { @MainActor in
                        defer { Self.qaRotateCycleRunning = false }
                        var sideways = false
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(rotateEvery))
                            guard !Task.isCancelled else { break }
                            sideways.toggle()
                            PlayerOrientation.rotate(to: sideways ? .landscapeRight : .portrait)
                            oneSkinLog("qaRotateCycle -> \(sideways ? "landscape" : "portrait")")
                        }
                    }
                }
                #endif
            }
            .onChange(of: watchScopes) { old, new in
                store.watchPageScopes.subtract(old.subtracting(new)); store.watchPageScopes.formUnion(new)
            }
            .onChange(of: duoExpanded) { _, expanded in
                // 折叠 ⇄ 展开只改「方向锁」：折叠态钉竖屏（外屏），展开后交还给设备。
                // 这里不调 `landLandscape()`：展开的默认落点是**竖屏单列**，
                // 双列只在设备真的横过来时出现（`sideways` 只看 `landscapeScreen`）。
                PlayerOrientation.holdPortrait(oneSkinActive ? false : !expanded)
                // A Full Screen started on the inner display must not carry onto the outer one:
                // folding while full-screen left the player filling a portrait screen it could not
                // turn, with the watch page's own layout gone.
                if !expanded && fullScreen { fullScreen = false }
            }
            // Fold/unfold flips the tab bar, the scrim's bleed and the controls' safe-area padding at
            // once; animate the lot together so the swap reads as one move, not a pop.
            .animation(.smooth(duration: 0.3), value: duoExpanded)
            .onDisappear {
                // An iPhone Duo fold/unfold swaps `watchBody` for `pageBody` (and back) without the
                // page leaving, so the page-level `onDisappear` handles stopping playback and leaving
                // Full Screen. Here only the watch page's own contributions are undone; they are
                // re-established by `onAppear` when the watch page returns.
                store.watchPageScopes.subtract(watchScopes)
                // Unconditional: an unfold sets the hold to false already, but closing the page while
                // folded shut used to skip this and leave the app held upright.
                PlayerOrientation.holdPortrait(false)
            }
            .onChange(of: watchChannel == nil) { _, ended in
                playerStarted = false
                if ended { playerSession = nil }
                if ended && fullScreen { setFullScreen(landscape: false) }
                // [mi3s] 二开：**转屏 / 起播都不再自动进全屏**。
                // 上游这里有 `phoneTurned()`：手机已经横着时，一起播就跳全屏。
                // 用户的诉求正好相反 —— 横屏是双列选集页（左画面 + 右详情 + 菜单栏），
                // 全屏只由全屏键显式触发。整个调用已删除，`phoneTurned` 也随之移除。
            }
            // 换线路换筛选后页码必须回到 1：新线路可能只有 20 集，
            // 停在第 50 页会被夹到末页，看起来像「跳到了最后一页」。
            .onChange(of: activeFlag) { _, _ in episodePage = 0 }
            .onChange(of: episodeFilter) { _, _ in episodePage = 0 }
    }

    /// The picture's own surface: black, so the bands a fit leaves inside it read as part of the frame
    /// rather than as the page showing through, with the player on top. Not clipped: in Full Screen the
    /// player ignores the safe area and reaches the physical edges, and a clip at the page's own bounds
    /// would cut that overflow back off. On the page the player stays inside its box, so there is nothing
    /// to clip there either.
    private var watchStage: some View {
        ZStack {
            Color.black
            watchPlayer(stageOnly: false)
        }
    }

    /// ⛔ 选集页（One 皮肤）用的离屏 stage：只产生/启动 `PlaybackSession`，
    /// 不渲染任何画面。画面统一由 `OneSkinFixedPicture` 的 `AVPlayerLayer` 画，
    /// 这样同一个 `AVPlayer` 只有一个渲染宿主，通用播放器样式改动
    /// （`AVPlayerViewController` / 按片源比例的 pictureBox）影响不到选集页。
    private var oneSkinSessionStage: some View {
        watchPlayer(stageOnly: true)
    }

    @ViewBuilder private func watchPlayer(stageOnly: Bool) -> some View {
        // One cover from opening the page to the first picture: the player's own wait stays under it, so nothing
        // swaps or flickers on the way.
        let covered = watchChannel == nil || (!playerStarted && !fullScreen)
        ZStack {
            if let channel = watchChannel {
                // ⛔ 换集修复：stageOnly 的 PlaybackView 身份不变，它的 @State session
                // 会在**原 player** 上换 item。这里同样复用同一个会话，别每集问
                // Store 要一个从未启动过的新会话 —— `playbackSession(for:)` 在
                // channel 变化时会顺手新建并顶掉 activeSession，是有副作用的。
                let stageSession = stageOnly
                    ? (playerSession ?? store.playbackSession(for: channel))
                    : store.playbackSession(for: channel)
                PlaybackView(channel: channel, session: stageSession,
                             watch: WatchPlayback(fullScreen: fullScreen, toggleFullScreen: setFullScreen,
                                                  leave: leavePlayer,
                                                  immersive: splitsWatchPage || duoExpanded,
                                                  started: { playerStarted = $0 }, opened: { playerSession = $0 },
                                                  aspect: { ratio in
                                                      // Only grow, never shrink below 16:9 into a squat box: a
                                                      // source that reports nothing keeps the usual shape.
                                                      guard ratio.isFinite, ratio > 0.2, ratio < 6 else { return }
                                                      if abs(ratio - playerAspectRatio) > 0.01 { playerAspectRatio = ratio }
                                                  },
                                                  // 同上：本页的抽屉只认 `showsAllEpisodes`。
                                                  openEpisodes: { showsAllEpisodes = true }),
                             stageOnly: stageOnly,
                             // 把 PlaybackView 实际持有的会话交回本页：选集页
                             // 画面层据此长期绑定同一个 AVPlayer（换集只换 item）。
                             onStageSession: { session in playerSession = session })
            }
            if covered { watchCover.transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.35), value: covered)
    }

    /// Back from the picture. In Full Screen that means back to the page — the details and the episode
    /// list the viewer was looking at — not out of the page: the button sits in the top-left corner of a
    /// page the viewer only enlarged, so closing the page under it dropped them on Home with the video
    /// floating in the mini player. Leaving the page itself is the cover's Back, or the edge swipe.
    private func leavePlayer() {
        if fullScreen { exitFullScreen() } else { dismiss() }
    }

    /// 明确地退出全屏（单向），绝不关页。
    ///
    /// 不能用 `setFullScreen(landscape:)` 代劳：那是个**对折开关**（`entering = !fullScreen`），
    /// 返回时只要读到一次过期的 `false`（皮肤层与页面层是两份状态，见 OneSkinStage
    /// 的 `fullScreenNow`），它就会把 `fullScreen` 设成 `true`；反过来读到过期的 `false`
    /// 又会走进 `dismiss()`——用户看到的就是「全屏里点返回，直接回到主页」。
    /// 返回是一条单向操作，实现也必须是单向的。
    private func exitFullScreen() {
        guard fullScreen else { return }
        withAnimation(.smooth(duration: 0.3)) { fullScreen = false }
        // 与 setFullScreen 同一条规则：全屏/退全屏都不碰方向。原来这里
        // `PlayerOrientation.set(landscape: false)` 会把方向 mask 锁回竖屏 ——
        // 横屏全屏退回后用户再点旋转键，被这个锁住的 mask 拦住，表现为
        // 「横屏过来的 UI/控件漂移，重启才恢复」的一环。
        // 退全屏只是恢复页面布局；方向仍然只归旋转键管。
    }


    /// The cover's words while it waits: the source finding the episode's link, then the page's player getting it ready.
    private func coverStatus(_ elapsed: TimeInterval) -> PlaybackWait {
        if let session = playerSession, let channel = watchChannel, loadingEpisode == nil {
            return session.wait(elapsed: elapsed, resume: channel.resumePosition, linesHint: false)
        }
        let progress = LoadingProgress.source(client.site, origin: client.origin, title: busyTitle)
        return PlaybackWait(message: progress.title, detail: progress.detail)
    }

    private func setFullScreen(landscape: Bool) {
        let entering = !fullScreen
        withAnimation(.smooth(duration: 0.3)) { fullScreen = entering }
        // ⛔ 全屏**不再主动转屏**（mi3s 二开，2026-11-09）：
        // 全屏 = 画面铺满**当前**屏幕方向。原来按片源比例决定转屏（横版片源进全屏
        // 请求转横）—— 竖屏下点全屏会出现「尝试切横屏又弹回竖屏」：
        // `requestGeometryUpdate` 的转屏请求与全屏过渡互锁（上游注释自认过这个坑：
        // interlocks the refused geometry update with the full-screen transition），
        // 请求被系统弹回，全屏状态却已置位，两套状态打架就是用户看到的「没反应」。
        // 方向只归 Chrome 的旋转键管（onRotate）。`landscape` 参数保留但不再触发转屏。
        _ = landscape
        // ★ 告诉方向系统「现在处于全屏」/「已经退出全屏」。
        //
        // 这是「全屏机制独立」的开关：
        //   · 进全屏 → `isFullScreenHeld = true`，此后 `holdPortrait(...)` 的任何写入
        //     都被丢弃，页面尺寸变化（duoExpanded / sizeClass）再也无法把方向拉回去；
        //   · 退全屏 → 关掉闸门，方向交还给页面习惯。
        PlayerOrientation.setFullScreenHeld(entering)
    }

    /// [已删除] `phoneTurned()`：转屏自动进全屏。
    ///
    /// 用户诉求是「选集播放页横屏竖屏一样，都保留菜单栏，只有全屏播放才隐藏」。
    /// 而这条上游逻辑把「手机横过来」直接翻译成「进全屏」，于是横屏永远看不到
    /// 双列选集页和菜单栏 —— 菜单栏按规则被收掉了，用户看到的就是「横屏没有菜单栏」。
    /// 现在转屏只是转屏：横屏 = 双列选集页（左画面 + 右详情 + 底部菜单栏），
    /// 全屏只由顶栏/底栏那颗全屏键显式进入。`turnedFullScreen` 这个配套状态一并删除，
    /// 别再让「转进去的全屏」和「按钮进的全屏」有两套退出条件。
    ///
    /// 若将来要恢复，唯一正确的做法是**在 `watchPageLifecycle` 里**加回，
    /// 不要在两条渲染分支里各写一份（那正是这次清掉的屎山）。

    /// The cover's Play: where the viewer stopped, else the line's first episode.
    private func playWatchCover() {
        if let watchHistory { store.resume(watchHistory); return }
        guard let first = activeEpisodes.first ?? detail?.episodes.first else { return }
        startRequest { await play(first) }
    }

    /// Before the picture: the cover across the top, blurred, while an episode starts. Otherwise (a video of several
    /// episodes waiting for one to be chosen, or an episode that failed, which the banner below explains) the cover
    /// shows clear, as Discover's page does, with Play.
    private var watchCover: some View {
        let starting = (detail == nil && error == nil) || busy || loadingEpisode != nil || store.resumingHistoryID != nil || watchChannel != nil
        let playable = watchHistory != nil || (activeEpisodes.first ?? detail?.episodes.first) != nil
        // The list's poster when there was one, so the picture doesn't change once the details arrive.
        let poster = video.poster != nil ? video : detail ?? video
        return WatchCoverBackdrop(poster: poster.poster, headers: poster.posterHeaders, loading: starting, clear: !starting, wide: (landscapePage || duoExpanded) && !fullScreen) { coverStatus($0) }
            .contentShape(Rectangle())
            .onTapGesture { if starting { withAnimation(.smooth(duration: 0.25)) { coverBack.toggle() } } }
            .task(id: coverBack) {
                guard coverBack else { return }
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { withAnimation(.smooth(duration: 0.3)) { coverBack = false } }
            }
            .overlay {
                if !starting, playable {
                    Button { playWatchCover() } label: {
                        Image(systemName: "play.fill").font(.system(size: 22, weight: .semibold))
                            .frame(width: 58, height: 58)
                            .glassSurface(.regular.interactive(), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("Play"))
                    .accessibilityIdentifier("watch.play")
                }
            }
            .overlay(alignment: .topLeading) {
                // While it starts by itself nothing sits on the cover until it's tapped. Every shape of
                // the page shows it: the navigation bar is hidden on all of them (a white title strip
                // over a poster printed the name twice), so this is the only way back from the cover.
                if !starting || coverBack {
                    Button { leavePlayer() } label: { Image(systemName: "chevron.backward").font(.headline).frame(width: 22, height: 22) }
                        .chromeButton()
                        .accessibilityLabel(L10n.text("Back"))
                        .accessibilityIdentifier("watch.back")
                        .padding(8)
                        .transition(.opacity)
                }
            }
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
    }

    private var watchDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(currentVideo().name).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                if let facts = tmdb.details?.facts, !facts.isEmpty {
                    Text(facts).font(.subheadline.weight(.medium)).lineLimit(2).transition(.opacity)
                }
                let meta = [currentVideo().remarks, currentVideo().year ?? "", SourceLabel(client.site.name).text].filter { !$0.isEmpty }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let genres = tmdb.details?.genres, !genres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(genres, id: \.self) { genre in
                            Text(genre).font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                    }
                }
            }
            if detail?.episodes.isEmpty == false {
                HStack(spacing: 10) { downloadButton(iconOnly: false); videoFavoriteButton; shareButton }
            }
            playbackBanner
            tmdbStatus
            if let detail { synopsis(detail) }
            if detail != nil {
                seasonPicker
                watchEpisodes
                tmdbExtras.padding(.top, 6)
            } else if let error {
                errorCard(error)
            } else {
                DetailSkeleton()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Its buttons are Liquid Glass, like the player's above them (#293).
        .environment(\.glassControls, true)
        .animation(.smooth(duration: 0.45), value: tmdb.details)
        .animation(.smooth(duration: 0.3), value: tmdb.phase)
    }

    /// A row of the series' seasons, so a matched multi-season show can jump between them. Only shown when
    /// TMDB has more than one season and the viewer is on the matching one's details.
    @ViewBuilder private var seasonPicker: some View {
        if let details = tmdb.details, details.mediaType == .tv {
            let seasons = details.seasons.filter { $0.number > 0 }
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(seasons, id: \.number) { season in
                            let selected = details.season?.number == season.number
                            Button {
                                Task { await tmdb.selectSeason(season.number) }
                            } label: {
                                Text(season.name.isEmpty ? L10n.text("Season %lld", season.number) : season.name)
                                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(selected ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Capsule())
                                    .foregroundStyle(selected ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("detail.season.\(season.number)")
                        }
                    }
                }
            }
        }
    }

    /// As in Bilibili's 选集: one row of episodes that scrolls sideways to the one playing, and All for the full list.
    /// A video with one episode has no row (its only episode is the video); several lines still show to choose from.
    ///
    /// On the Duo's unfolded landscape (the two-column page) the right column is tall and wide enough to hold the
    /// whole list at once, so the sideways row gives way to a resident vertical grid — the episode list lives beside
    /// the picture instead of hiding behind an "All" sheet, the same way the synopsis and lines do.
    @ViewBuilder private var watchEpisodes: some View {
        if let detail {
            if detail.episodes.isEmpty {
                noEpisodes(detail)
            } else {
                let items = activeEpisodes
                let compact = compactTileWidth(items) != nil
                // B站式数字卡片网格：展开双栏/竖屏 sheet 走常驻网格，每行约 6 个；窄屏外屏保留
                // 横向滚动 + 全部（布局形态不变，只把卡片换成数字方块）。
                if duoExpanded && items.count > 1 {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(L10n.text("Episodes")).font(.headline)
                            Text("\(items.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            episodeOrderButton
                        }
                        watchLines
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8, alignment: .top)], spacing: 8) {
                            ForEach(shownOrder(items)) { watchEpisodeCard($0, fill: true) }
                        }
                    }
                } else {
                VStack(alignment: .leading, spacing: 12) {
                    if items.count > 1 {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(L10n.text("Episodes")).font(.headline)
                            Text("\(items.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            episodeOrderButton
                            if items.count > (compact ? 5 : 2) {
                                Button { showsAllEpisodes = true } label: {
                                    HStack(spacing: 3) { Text(L10n.text("All")); Image(systemName: "chevron.right").font(.caption.weight(.semibold)) }
                                        .font(.subheadline).foregroundStyle(.secondary)
                                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                                        .padding(.horizontal, 10).frame(minHeight: 32)
                                        .glassOrFill(.regular.interactive(), Color.clear, in: Capsule())
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("watch.allEpisodes")
                            }
                        }
                    } else if flags.count > 1 {
                        Text(L10n.text("Lines")).font(.headline)
                    }
                    watchLines
                    if items.count > 1 {
                        // scrollPosition rather than ScrollViewReader: scrollTo also scrolls the page's vertical
                        // scroll view, which pushed the title under the player.
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 8) { ForEach(shownOrder(items)) { watchEpisodeCard($0) } }
                                .scrollTargetLayout()
                                .padding(.horizontal, 16)
                        }
                        .scrollIndicators(.never)
                        .scrollPosition(id: $episodeScroll, anchor: .center)
                        // Edge to edge, unclipped: the tiles' glass shadow ran past the row and was cut off in a band (#293).
                        .scrollClipDisabled()
                        .padding(.horizontal, -16)
                        .onAppear { episodeScroll = currentEpisodeID }
                        .onChange(of: currentEpisodeID) { _, id in if let id { withAnimation { episodeScroll = id } } }
                    }
                }
                }
            }
        }
    }

    /// The lines, when there are several. Choosing one while an episode plays switches to it on that line.
    @ViewBuilder private var watchLines: some View {
        if flags.count > 1 {
            SourceStrip(items: flags.map { .init(id: $0, name: $0.isEmpty ? L10n.text("Play") : $0) }, selection: activeFlag) { flag in
                let previous = activeFlag
                selectedFlag = flag
                guard watchChannel != nil, let episodes = detail?.episodes else { return }
                let playing = episodes.first { $0.id == currentEpisodeID }
                guard let same = episode(on: flag, matching: playing, in: episodes) else {
                    // This line has no episode to continue the one playing: stay on it, and say so.
                    selectedFlag = previous
                    withAnimation(.smooth(duration: 0.2)) { lineNotice = L10n.text("This line doesn't have this episode.") }
                    Task { try? await Task.sleep(for: .seconds(4)); withAnimation(.smooth(duration: 0.2)) { lineNotice = nil } }
                    return
                }
                if same.id != currentEpisodeID { startRequest { await play(same) } }
            }
            // Edge to edge and unclipped, like the episodes, so the strip doesn't cut the chips' glass shadow (#293).
            .contentMargins(.horizontal, 16, for: .scrollContent).scrollClipDisabled()
            .padding(.horizontal, -16)
        }
    }

    /// The episode on `flag` that continues `playing`: the same name, else the same episode number (第20集 / EP20 /
    /// S01E20), else nil when this line has no such episode. With nothing playing, the line's first episode.
    private func episode(on flag: String, matching playing: Episode?, in episodes: [Episode]) -> Episode? {
        guard let playing else { return episodes.first { $0.flag == flag } }
        let line = episodes.filter { $0.flag == flag }
        if let same = line.first(where: { $0.name == playing.name }) { return same }
        if let number = TMDBMatch.episodeNumber(playing.name),
           let same = line.first(where: { TMDBMatch.episodeNumber($0.name) == number }) { return same }
        return nil
    }

    /// TMDB's stills for the line's episodes, when its season lines up with most of them and has pictures for them;
    /// otherwise none, and the episodes keep their small cards.
    private func watchStills(_ items: [Episode]) -> [Episode.ID: TMDBMatch.EpisodeInfo] {
        let stills = tmdb.episodes(items)
        return items.count > 1 && stills.values.filter { $0.still != nil }.count * 2 >= items.count ? stills : [:]
    }

    /// The width of the small tiles when every name is short (第1集, 01, 4K国语), or nil for two-line cards. The tiles
    /// are as wide as the widest name, at least 64 points: a fixed 64 cut off names of four or five characters such as
    /// 4K国语 or 第100集 (#290). Measures one name, in the same pass that checks their lengths.
    private func compactTileWidth(_ items: [Episode]) -> CGFloat? {
        var widest = "", widestUnits = 0
        for item in items {
            let title = episodeTitle(item)
            guard title.count <= 5 else { return nil }
            // Chinese and other wide characters take about twice the room of digits and Latin letters.
            let units = title.unicodeScalars.reduce(0) { $0 + ($1.isASCII ? 1 : 2) }
            if units > widestUnits { widest = title; widestUnits = units }
        }
        let font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
        let text = (widest as NSString).size(withAttributes: [.font: font]).width
        // 8 points of padding on each side, and a little room for the bold of the episode playing.
        return max(64, (text + 20).rounded(.up))
    }

    /// An episode as a B站-style number tile: a compact dark square with the episode number centred, the
    /// playing one inverted (light fill + dark number) as the one clear anchor. No still, no caption — the
    /// number is the whole tile, so the grid stays small and uniform across the three shapes. The resume
    /// state (watched halfway) is a "续 N%" corner badge instead of a bottom progress bar.
    private func watchEpisodeCard(_ episode: Episode, fill: Bool = false, chosen: (() -> Void)? = nil) -> some View {
        let current = episode.id == currentEpisodeID
        // B站式纯数字卡片：播放中集反白（浅底深字）是「正在播放」的唯一清晰锚点；续播集用
        // 左上角「续 N%」小角标代替底部进度条；未看是深灰底。无封面、无标题行，方块小而均匀。
        let playing = current && watchChannel != nil
        let resumeProgress: Double? = {
            guard current, watchChannel == nil, let history = watchHistory,
                  !history.completed, history.progress > 0 else { return nil }
            return history.progress
        }()
        let saved = download(episode)
        let number = TMDBMatch.episodeNumber(episode.name)
        let label = number.map(String.init) ?? episodeTitle(episode)
        let shape = RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
        return Button {
            chosen?()
            // The episode already playing keeps playing.
            guard !(current && watchChannel != nil) else { return }
            startRequest { await play(episode) }
        } label: {
            ZStack {
                shape.fill(playing ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Color.primary.opacity(0.12)))
                if loadingEpisode == episode.id {
                    ProgressView().controlSize(.small).tint(playing ? Brand.onAccent : Color.primary)
                } else {
                    Text(label)
                        .font(.system(size: number == nil ? 13 : 20, weight: .semibold).monospacedDigit())
                        .foregroundStyle(playing ? Brand.onAccent : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .padding(.horizontal, 4)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(width: fill ? nil : 64, height: fill ? nil : 64)
            .overlay(alignment: .topLeading) {
                if let resumeProgress {
                    Text(L10n.text("Resume %lld%%", Int((resumeProgress * 100).rounded())))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Brand.onAccent)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Brand.accent, in: Capsule())
                        .padding(3)
                }
            }
            .overlay(alignment: .topTrailing) { if saved?.status == .completed { DownloadedBadge() } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .id(episode.id)
        .accessibilityAddTraits(current ? .isSelected : [])
        .contextMenu {
            if episodeLabels[episode.id] != nil { Text(episode.name) }
            if saved == nil || saved?.status == .failed {
                Button(L10n.text("Download"), systemImage: "arrow.down.circle") {
                    DownloadLibrary.shared.download(DownloadSource(site: client.site, videoID: video.id, episode: episode, origin: client.origin),
                                                    title: video.name, poster: video.poster, posterHeaders: video.posterHeaders)
                }
            } else if let saved {
                Button(L10n.text(saved.status == .completed ? "Delete Download" : "Cancel Download"), systemImage: "trash", role: .destructive) {
                    DownloadLibrary.shared.remove([saved.id])
                }
            }
        }
    }

    /// 选集抽屉底部的分页条：上一页 / 「第 x / N 页」可点跳转 / 下一页。
    ///
    /// 为什么不用 `Picker` 或 Slider：集数可能上千，Picker 的滚轮太慢，
    /// Slider 又难以精确落到某一页。这里给「上一页 / 下一页」做粗调，
    /// 中间的页码点开一个输入框做精确跳转。
    private struct EpisodePager: View {
        @Binding var page: Int
        let pageCount: Int
        let total: Int
        @Binding var pageSize: Int
        @State private var editing = false
        @State private var draft = ""

        var body: some View {
            HStack(spacing: 12) {
                Button { page = max(0, page - 1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(page <= 0)
                .opacity(page <= 0 ? 0.35 : 1)

                Spacer(minLength: 0)

                VStack(spacing: 1) {
                    Button {
                        draft = "\(page + 1)"
                        editing = true
                    } label: {
                        Text("\(page + 1) / \(pageCount)")
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    Text("\(total) 集")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer(minLength: 0)

                Button { page = min(pageCount - 1, page + 1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(page >= pageCount - 1)
                .opacity(page >= pageCount - 1 ? 0.35 : 1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.bar)
            .alert(L10n.text("跳到第几页"), isPresented: $editing) {
                TextField("1", text: $draft)
                    .keyboardType(.numberPad)
                Button(L10n.text("Cancel"), role: .cancel) {}
                Button(L10n.text("Go")) {
                    if let n = Int(draft), n >= 1 { page = min(pageCount - 1, n - 1) }
                }
            } message: {
                Text(L10n.text("共 %d 页，每页 %d 集", pageCount, pageSize))
            }
        }
    }

    private var allEpisodes: some View {
        NavigationStack {
            VStack(spacing: 0) {
                watchLines
                episodeDrawerControls
                Divider().opacity(0.4)
                ScrollView {
                    if pagedEpisodes.isEmpty {
                        Text(episodeQuery.isEmpty && episodeFilter == .all
                             ? L10n.text("没有剧集")
                             : L10n.text("没有匹配的剧集"))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.top, 60)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8, alignment: .top)], spacing: 8) {
                            ForEach(pagedEpisodes) { watchEpisodeCard($0, fill: true) {
                                showsAllEpisodes = false
                            } }
                        }
                        .padding(16)
                    }
                }
                .scrollDismissesKeyboard(.immediately)
                EpisodePager(page: $episodePage, pageCount: episodePageCount,
                             total: filteredEpisodes.count, pageSize: $episodePageSize)
            }
            .navigationTitle(L10n.text("Episodes"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { episodeOrderButton }
                ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { showsAllEpisodes = false } }
            }
        }
        .environment(\.glassControls, true)
        // ★ 抽屉自己铺深色底并锁深色外观。
        //
        // 之前什么都不铺，sheet 沿用系统浅色底（实测整页 247/247/247），
        // 而 OneSkin 整页是深色（#080808）—— 抽屉一弹就是一大片刺眼白，
        // 用户看到的就是「竖屏底下这块渐隐白层」。
        // 铺 `OneSkinPalette.stage`（#080808，与页底同色）并锁 dark，
        // 里面的 TextField / Menu / Divider / NavigationBar 才会跟着走深色。
        // sheet 的**材质本身**也要换掉。
        //
        // 只加 `.background(...)` 是不够的：iOS 26 的 sheet 自带一层
        // `.regularMaterial` 玻璃底（实测取样 RGB ≈ 114,113,113 的**中性灰**），
        // 它压在内容下面、盖住我们铺的深色，于是整片抽屉是灰的，
        // 且底部到 home indicator 安全区之间露出 9pt 深色 —— 就是用户看到的
        // 「底部白色渐隐块」。`.presentationBackground` 直接替掉那层材质。
        .presentationBackground(OneSkinPalette.stage)
        .preferredColorScheme(.dark)
        // 高度档位与下载抽屉**同一套**：`[.medium, .large]` + 用户拖拽。
        //
        // ⛔ 不要再用 `[.height(320)]`，也不要让档位集合随 `duoExpanded` 变：
        // 1) 320pt 里固定头（导航栏 44 + 线路 + 搜索 44 + 筛选 32 + 分页器 48）就吃掉 200+，
        //    列表只剩一行，用户以为「选集列表空了 / 只加载了一集」；
        // 2) 档位集合在 sheet 展示期间被替换（合拢 → 展开）时，当前档位会从集合里消失，
        //    UIKit 只能跳到剩下的唯一档位或直接收掉 —— 折叠一下抽屉自己变高/消失。
        // 展开态想默认给满高，用 `selection` 换档，不动集合。
        .presentationDetents([.medium, .large], selection: $episodeDetent)
        .presentationDragIndicator(.visible)
        .onChange(of: episodePageCount) { _, count in
            // 换线路 / 改筛选 / 改每页条数后总页数变小：页码夹回，否则分页器会显示「6 / 2」。
            if episodePage > count - 1 { episodePage = max(0, count - 1) }
        }
    }

    /// 抽屉顶部的搜索 + 筛选 + 每页条数。
    ///
    /// 三者在同一块里，因为它们是同一件事的三个维度：
    /// 「我要找哪几集」— 搜索限定内容、筛选限定范围、页大小决定一屏看多少。
    private var episodeDrawerControls: some View {
        VStack(spacing: 8) {
            // 搜索
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                TextField(L10n.text("搜索集数或标题"), text: $episodeQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .autocorrectionDisabled()
                    .onChange(of: episodeQuery) { _, _ in episodePage = 0 }
                    .onSubmit { jumpToFirstMatch() }
                if !episodeQuery.isEmpty {
                    Button { episodeQuery = ""; episodePage = 0 } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.07)))

            // 筛选 + 每页条数
            HStack(spacing: 8) {
                ForEach(EpisodeFilter.allCases) { f in
                    Button {
                        episodeFilter = f
                        episodePage = 0
                    } label: {
                        Text(f.label)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(
                                episodeFilter == f ? Color.primary.opacity(0.16) : Color.primary.opacity(0.05)))
                            .foregroundStyle(episodeFilter == f ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                // 每页条数：10 / 20 / 50
                Menu {
                    ForEach(Self.pageSizeChoices, id: \.self) { n in
                        Button {
                            episodePageSize = n
                            episodePage = 0
                        } label: {
                            if episodePageSize == n { Label("\(n) / 页", systemImage: "checkmark") }
                            else { Text("\(n) / 页") }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("\(episodePageSize) / 页")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    #endif
}

#if os(iOS)
/// iPhone: a video's page is a watch page, its player at the top (`VideoDetailView`). iPhone Duo's inner
/// display (regular both ways) keeps the watch page too — it is still a phone (`idiom == .phone`), and it
/// folds back to the compact outer screen, so the playback page must survive the fold. Only a real iPad
/// (`idiom == .pad`) takes the tablet's plain detail page.
enum WatchPage {
    @MainActor static func applies(_ horizontal: UserInterfaceSizeClass?, _ vertical: UserInterfaceSizeClass?) -> Bool {
        // 原判据只认 `.phone`：虚拟机 / Duo 模拟器上 idiom 可能不是 .phone，
        // 会让观看页永远走 pageBody（图文详情页），One 皮肤根本没机会渲染。
        // 补一条：屏幕短边 < 600pt 也按手机观看页处理（真机 phone 亦满足）。
        if UIDevice.current.userInterfaceIdiom == .phone { return true }
        let b = UIScreen.main.bounds.size
        return min(b.width, b.height) < 600
    }
}

/// A swipe from the left edge goes back, as on any pushed page: hiding the navigation bar turns that gesture off.
/// It also comes before the picture's slide-to-seek and the episode row's scrolling, which would otherwise take a
/// swipe that starts at the edge.
struct EdgeSwipeBack: UIViewControllerRepresentable {
    /// Off in Full Screen, where the swipe would leave the page, and on a folded-out Duo, where the page keeps
    /// its own navigation bar (and the system sidebar owns the left edge).
    var enabled: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.enabled = enabled }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var enabled = true {
            didSet { if enabled != oldValue { apply(animated: false) } }
        }
        private weak var recognizer: UIGestureRecognizer?
        private weak var previous: UIGestureRecognizerDelegate?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply(animated: animated)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply(animated: false)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // The swipe already under way goes on; other pages get the system's own rules back.
            disarm()
        }

        /// Only the immersive (enabled) page hides the navigation bar and arms the edge swipe. On a folded-out
        /// Duo the page keeps its nav bar and tab bar for an explicit way back, so this must not hide the bar —
        /// doing so left the expanded page with neither a back button nor a working swipe.
        private func apply(animated: Bool) {
            guard isViewLoaded, view.window != nil else { return }
            if enabled {
                // Pushed from a search field still active (after Search was pressed), the bar the page hides
                // stayed, and its Back showed over the page's own.
                if navigationController?.isNavigationBarHidden == false {
                    navigationController?.setNavigationBarHidden(true, animated: animated)
                }
                arm()
            } else {
                disarm()
            }
        }

        /// Again after a swipe that was let go halfway, which brings the page back.
        private func arm() {
            guard let pop = navigationController?.interactivePopGestureRecognizer, pop.delegate !== self else { return }
            recognizer = pop; previous = pop.delegate
            pop.delegate = self; pop.isEnabled = true
        }

        private func disarm() {
            if let recognizer, recognizer.delegate === self { recognizer.delegate = previous }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            enabled && (navigationController?.viewControllers.count ?? 0) > 1
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            enabled && other is UIPanGestureRecognizer
        }
    }
}
#endif

extension PlaybackHistoryEntry {
    /// The watched title as a list card, to open its page with.
    var listVideo: Video {
        Video(id: context.videoID, name: context.videoName, poster: context.poster, posterHeaders: context.posterHeaders ?? [:], year: context.year)
    }
}

private struct PlaybackIssue {
    let episode: Episode
    let message: String
    let drive: CloudDrive?
    /// True when playback was not attempted because a required account is missing.
    let blockedBeforeRequest: Bool
    /// A sign-in the source's CatPawOpen bundle runs itself (`CatPawSignIn.provider(for:)`).
    var signIn: String? = nil
}

private struct BundleSignIn: Identifiable {
    let provider: String
    var id: String { provider }
}

/// Cloud drives whose plugins need a saved login before they can return a stream.
private enum CloudDrive: String, Identifiable {
    /// Xunlei's sign-in is only for CatPawOpen bundles, which say when it is missing; other sources play their Xunlei
    /// lines without it, so those lines are never held back for it. Baidu comes only from a plugin's error
    /// (`CloudDriveLoginRequired`), never from a line's name: other plugins sign in to it with their own code.
    case quark, uc, xunlei, baidu
    var id: String { rawValue }
    /// FTY names its lines after drive nicknames: 夸父 is Quark, 优汐 is UC.
    init?(flag: String) {
        let text = flag.lowercased()
        if text.contains("夸克") || text.contains("夸父") || text.contains("quark") { self = .quark }
        else if text.hasPrefix("uc") || text.contains("uc网盘") || text.contains("优汐") { self = .uc }
        else if text.contains("迅雷") || text.contains("xunlei") { self = .xunlei }
        else { return nil }
    }
    /// Lines from drives that sign in through the plugin's own QR code (FTY's 嘟嘟 is Baidu, 阿狸 is
    /// Aliyun). They ask for a scan the first time, so they never start a title on their own.
    static func withoutSignIn(_ flag: String) -> Bool {
        let text = flag.lowercased()
        return ["嘟嘟", "百度", "度盘", "baidu", "阿狸", "阿里", "aliyun"].contains { text.contains($0) }
    }
    /// The first line that can play now: not from a drive without a sign-in, nor one whose sign-in is missing.
    static func preferredFlag(_ flags: [String]) -> String? {
        let accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
        return flags.first { flag in
            if withoutSignIn(flag) { return false }
            guard let drive = CloudDrive(flag: flag), drive != .xunlei else { return true }
            let cookie = drive == .quark ? accounts.quarkCookie : accounts.ucCookie
            return !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    var name: String {
        switch self {
        case .quark: L10n.text("Quark")
        case .uc: "UC"
        case .xunlei: L10n.text("Xunlei")
        case .baidu: L10n.text("Baidu Netdisk")
        }
    }
    var signInTitle: String {
        switch self {
        case .quark: L10n.text("Sign In to Quark")
        case .uc: L10n.text("Sign In to UC")
        case .xunlei, .baidu: L10n.text("Sign In to %@", name)
        }
    }
    #if os(macOS)
    var provider: CloudProvider { self == .quark ? .quark : .uc }
    #else
    var qrDrive: CloudDriveQRLogin.Drive { self == .quark ? .quark : self == .baidu ? .baidu : .uc }
    var webSignIn: WebSignIn { self == .quark ? .quark : self == .baidu ? .baidu : .uc }
    #endif
    var loginHint: String { L10n.text("This source plays from %@ and needs you to sign in first.", name) }
    var expiredHint: String { L10n.text("Your %@ sign-in is missing or has expired. Sign in again to play this episode.", name) }
    static func missingLogin(forFlag flag: String) -> CloudDrive? {
        guard let drive = CloudDrive(flag: flag), drive != .xunlei else { return nil }
        let accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
        let cookie = drive == .quark ? accounts.quarkCookie : accounts.ucCookie
        return cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? drive : nil
    }
    static func isLoginFailure(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["授权", "登录", "扫码", "cookie", "login", "unauthorized"].contains { text.contains($0) }
    }
}

/// Episode names often lead with a size tag ("[1.18GB] S01E41.mkv"); show it as trailing detail.
// [mi3s] 二开：`EpisodeRow` 由 `private` 提为 `internal`，让上游 `PlayerEpisodesSheet` 也能复用同一行
// 渲染（否则两处各画一套，字号/间距迟早走偏）。见 03-侵入点登记表 I-06。
struct EpisodeRow: View {
    let name: String
    /// The episode's short label (第1集), shown in place of the name; the size tag stays as detail.
    var label: String? = nil
    let loading: Bool
    var download: DownloadItem? = nil
    let action: () -> Void
    @State private var hovering = false
    static func split(_ name: String) -> (title: String, detail: String?) {
        if let match = name.firstMatch(of: /^\s*\[([^\]]+)\]\s*(.+)$/) { return (String(match.2), String(match.1)) }
        return (name, nil)
    }
    static func title(_ name: String) -> String { split(name).title }
    /// Row type and height per platform: a Mac list size is unreadable from a sofa.
    private static var metrics: (text: CGFloat, icon: CGFloat, height: CGFloat, inset: CGFloat) {
        #if os(tvOS)
        (28, 18, 42, 0) // GlassRowStyle adds its own padding and focus glass
        #elseif os(iOS)
        (15, 11, 44, 14)
        #else
        (13, 10, 36, 12)
        #endif
    }
    private var parts: (title: String, detail: String?) {
        let parts = Self.split(name)
        return (label ?? parts.title, parts.detail)
    }
    var body: some View {
        let parts = parts
        let button = Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if loading { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "play.fill").font(.system(size: Self.metrics.icon)).foregroundStyle(hovering ? .primary : .tertiary) }
                }
                .frame(width: Self.metrics.icon + 6)
                Text(parts.title).font(.system(size: Self.metrics.text, weight: loading ? .semibold : .medium))
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if let detail = parts.detail {
                    Text(detail).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
                if let download { DownloadState(item: download) }
            }
            .padding(.horizontal, Self.metrics.inset).frame(minHeight: Self.metrics.height)
            .frame(maxWidth: .infinity, alignment: .leading)
            #if !os(tvOS)
            .background(Color.primary.opacity(loading ? 0.12 : (hovering ? 0.08 : 0.04)),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            #endif
            .contentShape(Rectangle())
        }
        .accessibilityLabel(name)
        #if os(tvOS)
        button.glassRow()
        #else
        button.buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.smooth(duration: 0.15), value: hovering)
        #endif
    }
}

private struct DownloadLabelStyle: LabelStyle {
    let iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        if iconOnly { configuration.icon } else { HStack(spacing: 6) { configuration.icon; configuration.title } }
    }
}

/// Gives its one subview at least `minHeight`, even in a scroll view, where `frame(minHeight:)`
/// leaves the content at its ideal height and spacers inside it never grow.
private struct MinHeightLayout: SwiftUI.Layout {
    var minHeight: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: max(size.height, minHeight))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
