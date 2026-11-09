import SwiftUI
import TVCore

@MainActor @Observable final class Store {
    static let defaultURL = "https://raw.githubusercontent.com/qist/tvbox/master/fty.json"
    /// Every subscription a fresh install should carry. The three addresses aggregate the two
    /// bundles' sources so an overwritten install keeps nothing orphaned: the public fty.json,
    /// the 124.223.214.31 server, and the local Rex aggregate served by the Mac on the LAN.
    /// Feeds this build adds on a fresh install.
    ///
    /// A `.local` name is not one of them: `macdemacbook-pro.local` only resolves on the LAN it was
    /// named on, so every fresh install on a phone elsewhere spent its first launch on a DNS failure
    /// and an error banner. The development Mac's feed is kept for debug builds, where the Mac is
    /// usually the machine serving it.
    static let aggregatedSubscriptionAddresses: [String] = {
        var addresses = [
            "https://raw.githubusercontent.com/qist/tvbox/master/fty.json",
            "http://124.223.214.31:55316/9981",
        ]
        #if DEBUG
        addresses.append("http://macdemacbook-pro.local:8081/api/rex/movie-degraded.json")
        #endif
        return addresses
    }()
    private static let dismissedAggregatesKey = "dismissedAggregateSubscriptions"
    /// Aggregate addresses the viewer deleted on purpose. Launch-time seeding skips them; adding one
    /// back by hand clears it again.
    private(set) var dismissedAggregateAddresses: Set<String> = []
    let searchModel = SearchModel()
    /// Song search and the music player; both outlive the Music page, so a song keeps playing elsewhere in the app.
    /// The Mac and Apple TV list every kind at once, in rows; a phone or iPad starts on songs.
    /// Music extensions the listener imported search alongside the catalogs; with none, they answer nothing at once.
    #if os(macOS) || os(tvOS)
    let musicSearch = MusicSearchModel(catalogs: MusicSearchModel.defaultCatalogs() + [MusicExtensionCatalog()], kind: .top)
    #else
    let musicSearch = MusicSearchModel(catalogs: MusicSearchModel.defaultCatalogs() + [MusicExtensionCatalog()])
    #endif
    let music = MusicPlaybackSession()
    /// The Music page's charts, playlists and new albums; fetched when that page first shows.
    /// The music extensions' library groups come after the catalogs' shelves.
    let musicBrowse = MusicBrowseModel(sources: MusicBrowseModel.defaultSources() + [MusicExtensionCatalog()])
    let recommendationModel = RecommendationModel()
    let playbackHistory: PlaybackHistory
    let playbackDefaults: UserDefaults
    let pinnedSources: PinnedSources
    let hiddenSources: HiddenSources
    let sourceOrder: SourceOrder
    /// Per-source direct/proxy choices and the automatic connectivity fallback.
    let sourceRouting: SourceRouting
    /// The viewer's own HTTP/HTTPS/SOCKS5 proxy endpoints, chosen per source instead of the built-in relay.
    let customProxy: CustomProxyRouter
    /// Per-source rename and API override (the viewer edits one source without editing the subscription).
    let sourceOverrides: SourceOverrides
    /// Per-line (flag) route and hide choices, finer than the source-level routing.
    let lineSettings: LineSettings
    /// Where a source was dragged across subscriptions (displayed group override).
    let sourceReassignment: SourceReassignment
    /// The viewer's own groups — the ones a sweep can fill with "these answer" and "these do not".
    let sourceGroupBook: SourceGroupBook
    /// Keeps the viewer's library the same on their other devices; nil for tests and QA's isolated data.
    let cloudSync: CloudSync?
    /// The history entry being resumed; another entry, or leaving the page, replaces or cancels it.
    private(set) var resumingHistoryID: String?
    private var resumeTask: Task<Void, Never>?
    /// The debounced keychain-backup write, cancelled and restarted on every change.
    @ObservationIgnored private var keychainBackupTask: Task<Void, Never>?
    /// Every enabled subscription merged in list order, plus the built-in sources.
    var subscription: Subscription?
    /// The address being typed in to add a subscription.
    var subscriptionAddress: String
    /// What to call the subscription being added; empty shows where it lives instead.
    var subscriptionName = ""
    /// Every subscription the viewer added, in the order they merge.
    var subscriptions: [SubscriptionEntry] = []
    /// Why a subscription last failed to refresh, by address; its last good copy stays in use.
    var subscriptionErrors: [String: String] = [:]
    /// The last good copy of each subscription, by address.
    private(set) var documents: [String: Subscription] = [:]
    let favorites: Favorites
    /// Passcode-locked hiding of subscriptions and sources. Reads go through its `visible…` and
    /// `permits…` methods so a hidden source disappears from every listing at once, rather than
    /// being filtered again in each view.
    var vault = PrivacyVault()
    /// Which language artwork comes in. Persisted beside the vault, in the playback defaults.
    var artworkLanguage = ArtworkLanguage()
    /// The AI translation service, when the viewer configured one. Empty means "use the device's
    /// Translation instead", which is what the app does by default.
    var aiTranslation = SubtitleTranslator.Configuration(baseURL: "", model: "", apiKey: "", targetLanguage: "")
    /// Separate viewing lives. See `Environments`.
    var environments = Environments()
    /// Where intro/credits markers come from, in priority order.
    var skipSources = SkipSegmentSources()
    /// How to order several files of the same title.
    var resourceRanking = ResourceRanking.standard
    /// The embedded Web Cast server that projects the catalog to a browser on the same Wi-Fi.
    let webCast = WebCastController()
    private static let vaultKey = "privacyVault"
    private static let artworkLanguageKey = "artworkLanguage"
    private static let aiTranslationKey = "aiSubtitleTranslation"
    private static let environmentsKey = "environments"
    private static let skipSourcesKey = "skipSegmentSources"
    private static let resourceRankingKey = "resourceRanking"
    /// Whether the keychain auto-backup leg is on. Persisted like the other optional toggles. Off by
    /// default: it costs a keychain write on every change and, unlike the manual file, restores
    /// everything (including subscriptions) without the viewer choosing what comes back.
    private static let keychainBackupKey = "keychainBackup.enabled"

    /// Persists the vault. Called by every mutation so a passcode change or a hide survives a crash.
    func saveVault() {
        if let blob = try? JSONEncoder().encode(vault) { playbackDefaults.set(blob, forKey: Self.vaultKey) }
        if let blob = try? JSONEncoder().encode(artworkLanguage) { playbackDefaults.set(blob, forKey: Self.artworkLanguageKey) }
        if let blob = try? JSONEncoder().encode(aiTranslation) { playbackDefaults.set(blob, forKey: Self.aiTranslationKey) }
        if let blob = try? JSONEncoder().encode(environments) { playbackDefaults.set(blob, forKey: Self.environmentsKey) }
        if let blob = try? JSONEncoder().encode(skipSources) { playbackDefaults.set(blob, forKey: Self.skipSourcesKey) }
        if let blob = try? JSONEncoder().encode(resourceRanking) { playbackDefaults.set(blob, forKey: Self.resourceRankingKey) }
        // Every environment change (add/remove/activate) funnels through here, so this is the one
        // place to keep the player's shared history pointed at the environment on screen.
        playbackHistory.activeEnvironmentID = environments.activeID
        favorites.activeEnvironmentID = environments.activeID
        // The vault and the preferences persisted here are part of the lightweight iCloud backup.
        cloudSync?.changed("cloudBackup")
        persistKeychainBackup()
    }

    /// Writes the full backup into the keychain when the leg is on, so a reinstall restores it
    /// without a manual file. Debounced: called from many mutation points, but only the first write
    /// in a burst goes through, and the trailing edge is flushed on background.
    func persistKeychainBackup() {
        guard persistsChanges, keychainBackupEnabled else { return }
        keychainBackupTask?.cancel()
        keychainBackupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.keychainBackupTask = nil
            let backup = self.exportFullBackup(categories: .all)
            _ = KeychainBackup.save(backup)
        }
    }

    /// Relocks the vault the moment the screen is captured — a screenshot or an active screen
    /// recording / mirroring — so a hidden subscription or source is never caught mid-view. The
    /// lock only matters when a passcode is set; otherwise the vault hides nothing.
    #if os(iOS)
    func installCaptureGuards() {
        // No `guard vault.hasPasscode` here: it is installed once at init, before a passcode exists, so
        // a passcode set later in the same session must still get the guard. `relock` re-checks the
        // passcode at the moment of the capture, which is the only time it matters.
        let relock = { [weak self] in
            guard let self, self.vault.hasPasscode else { return }
            Task { @MainActor in
                guard self.vault.isUnlocked() else { return }
                self.vault.lock()
                self.saveVault()
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.userDidTakeScreenshotNotification,
                                               object: nil, queue: .main) { _ in relock() }
        NotificationCenter.default.addObserver(forName: UIScreen.capturedDidChangeNotification,
                                               object: nil, queue: .main) { note in
            guard let screen = note.object as? UIScreen, screen.isCaptured else { return }
            relock()
        }
    }
    #endif

    /// Rows the viewer may see. Every listing that shows history goes through this.
    /// History for the environment on screen, then hidden rows removed.
    ///
    /// Order matters: the environment filter runs first because a hidden row from another
    /// environment must not be unhidden by this one.
    var visibleHistory: [PlaybackHistoryEntry] {
        vault.visibleHistory(playbackHistory.entries(in: environments.activeID))
    }

    /// Which environment new records belong to. Kept on the history object so its own `record`
    /// can stamp without knowing about `Environments`.
    var activeEnvironmentID: UUID? { environments.activeID }
    /// The subscriptions belonging to the environment on screen. A record with no environment id
    /// predates environments and lives in the default one, so an upgrade keeps it visible.
    var environmentSubscriptions: [SubscriptionEntry] {
        subscriptions.filter { environments.shows($0.environmentID) }
    }
    /// The subscriptions belonging to a given environment (for the copy-to-other-sandbox action).
    func subscriptions(in environment: UUID) -> [SubscriptionEntry] {
        subscriptions.filter { ($0.environmentID ?? environments.all[0].id) == environment }
    }
    /// A new subscription record, stamped with the environment on screen.
    private func stamping(_ entry: SubscriptionEntry) -> SubscriptionEntry {
        var copy = entry
        copy.environmentID = environments.stamp
        return copy
    }
    /// The index of a subscription matching both address and environment, so the same address kept
    /// under two sandboxes never collides.
    private func index(of entry: SubscriptionEntry) -> Int? {
        subscriptions.firstIndex { $0.address == entry.address && ($0.environmentID ?? environments.all[0].id) == (entry.environmentID ?? environments.all[0].id) }
    }
    /// Deletes every subscription that belongs to one environment, used when that environment is
    /// removed. The shared on-disk copy survives only if another environment still uses the address.
    func removeSubscriptions(in environment: UUID) {
        let removed = subscriptions.filter { ($0.environmentID ?? environments.all[0].id) == environment }
        guard !removed.isEmpty else { return }
        subscriptions.removeAll { ($0.environmentID ?? environments.all[0].id) == environment }
        for entry in removed {
            let stillUsed = subscriptions.contains { $0.address == entry.address }
            if !stillUsed {
                documents[entry.address] = nil; subscriptionErrors[entry.address] = nil
                if persistsChanges { try? FileManager.default.removeItem(at: Self.file(for: entry)); ImportedFiles.remove(entry.address) }
            }
        }
        saveSubscriptionList()
    }
    /// Re-merges the enabled subscriptions of the now-active environment after a switch or delete.
    func rebuildForActiveEnvironment() {
        rebuildSubscription(resetting: true)
    }
    /// Copies one subscription into another environment (sandbox). The address, name, switch and
    /// routing are carried over; the copy is stamped with the target environment and switched on.
    func copySubscription(_ entry: SubscriptionEntry, to environment: UUID) {
        guard environments.environment(environment) != nil else { return }
        let alreadyThere = subscriptions.contains { $0.address == entry.address && ($0.environmentID ?? environments.all[0].id) == environment }
        guard !alreadyThere else { return }
        var copy = entry
        copy.environmentID = environment
        copy.enabled = true
        subscriptions.append(copy)
        saveSubscriptionList()
        // The parsed content is shared across environments, so nothing needs re-fetching; the
        // merge just needs to account for the new entry once it is the active environment.
    }
    /// Favourites the viewer may see.
    var visibleFavorites: [FavoriteItem] { vault.visibleFavorites(favorites.items) }
    /// Subscriptions the viewer may see: a hidden subscription's name and address must not surface in
    /// a diagnostic dump (feedback) or anywhere else that lists what is set up. A subscription whose
    /// copy has no origin yet (never fetched) is kept — it has no sources to hide, and dropping it
    /// would hide a fresh, unhidden feed the viewer just added.
    var visibleSubscriptions: [SubscriptionEntry] {
        let open = vault.unlocked()
        let scoped = environmentSubscriptions
        if open { return scoped }
        return scoped.filter { entry in
            guard let origin = documents[entry.address]?.origin else { return true }
            return !vault.isHidden(subscription: origin)
        }
    }
    /// Whether an episode may be opened, for a deep link or a resumed session.
    func mayPlay(sourceKey: String, origin: URL) -> Bool { vault.permitsPlayback(sourceKey: sourceKey, origin: origin) }
    /// Whether the vault lets this source be listed, searched or opened right now. `origin` is the merged
    /// subscription's, used only where the source carries no origin of its own.
    func maySee(_ site: Site, origin: URL) -> Bool { vault.permits(site: site, fallback: origin) }
    var importing = false
    /// How many subscriptions of the current import/refresh have answered, of `importTotal`. `0` while
    /// nothing is importing; the UI shows "N of M" from these so a refresh reads as progress, not a wait.
    var importDone = 0
    var importTotal = 0
    /// Whether an import owns the gate, and who is waiting for it.
    ///
    /// A second import used to be dropped on the floor: `guard !importing else { return }` meant a
    /// `yingxia://subscribe` link that arrived while launch-time seeding was still running — the
    /// normal case on a fresh install — silently imported nothing. Imports now queue behind the one
    /// running, which is what the caller already assumed when it awaited them in a loop.
    @ObservationIgnored private var importBusy = false
    @ObservationIgnored private var importWaiters: [CheckedContinuation<Void, Never>] = []

    /// Waits for the running import, then takes the gate.
    private func beginImport() async {
        if !importBusy {
            importBusy = true
            return
        }
        await withCheckedContinuation { importWaiters.append($0) }
    }

    /// Hands the gate to the next waiter, or releases it.
    private func endImport() {
        if importWaiters.isEmpty {
            importBusy = false
        } else {
            importWaiters.removeFirst().resume()
        }
    }
    var error: String?
    /// Why the last subscription import failed. It shows under the address field, not in the app-wide alert: on
    /// iPhone and iPad that alert closed the Add Subscription sheet over it and took the viewer out of the form (#357).
    var importError: String?
    var notice: String?
    /// Whether the full-screen player is presented (vs. the floating mini player). Toggled by the
    /// mini player (tap to go full screen) and the full-screen cover (close to return to the mini player).
    var presentingPlayer = false
    /// [mi3s] 二开：**从任意位置**把一页压进当前分区的导航栈。
    ///
    /// 应用内小窗是挂在 `RootView` 上的全局浮层，不在任何分区的 `NavigationStack` 里，
    /// 拿不到那个分区的 `openRoute`。所以小窗点「回到播放」时只能置一个请求，
    /// 由分区自己的栈（`RouteStack`）接住并压栈 —— 这样点回去落到的是 **One 选集页**，
    /// 而不是旧的全屏播放器（皮肤在那一刻会「丢」）。
    var pendingRoute: Route?
    /// [mi3s] 二开：OneSkin 选集/播放页是否在前台。
    ///
    /// 播放页（`VideoDetailView`）是 push 进 NavigationStack 的，仍留在 TabView 里，
    /// 于是 `.sidebarAdaptable` 在 regular width（Duo 横屏 678×466 就是）会**自动展开
    /// 右侧边栏**，直接压住详情栏的按钮 —— 实测选集卡、「全部」、下载卡都被挡住。
    /// 置位后 `RootView` 把 TabView 换成不带侧栏的样式，播放页独占全宽；
    /// 页面消失时复位。
    var watchPageOpen = false
    /// 界面语言的「版本号」。改语言时 +1，任何读到 `L10n.text` 的视图都会重建。
    ///
    /// `L10n.text()` 读的是 `UserDefaults`，本身不是 SwiftUI 状态 ——
    /// 光写偏好，界面要等下一次冷启动才会变。这里提供一个 `@Observable` 的计数器，
    /// 设置页改语言时 +1，根视图读到它就会整棵重算，语言立刻生效。
    var languageRevision = 0
    /// [mi3s] 二开：应用内小窗的**显式**开关。
    ///
    /// 以前这里是 `floatRequested` + `floatsInMiniPlayer(channel)`：后者要读
    /// `!playsInWatchPage(channel)`，而 `watchPageScopes` 在折叠/展开/换向时会被
    /// 观看页的 `onDisappear` 清掉一帧再补回来 —— 小窗就是被这一帧拱出来的。
    /// 「是否在观看页」是**推导**，推导在转场中间必然有一刻为空。
    ///
    /// 现在只认两个动作：
    ///   - 视频控件里的「缩成小窗」→ `true`（`PlayerView.miniplayer()` / One 皮肤同名按钮）
    ///   - 点小窗回全屏、停止播放、重新进观看页 → `false`
    /// 折叠/旋转/切页面都不写这个值，所以它们不可能触发小窗。
    var miniPlayerActive = false
    var playing: Channel? {
        // An episode of a listening source (audiobooks, radio, songs) plays in the music player instead (#289).
        didSet {
            if let channel = playing, let queue = listeningQueue(for: channel) { playing = nil; listen(queue, from: channel); return }
            // The session playing survives an iPhone Duo fold/unfold. It is dropped when playback stops, or when
            // a different channel starts playing.
            if playing == nil { activeSession = nil; activeSessionChannel = nil; presentingPlayer = false; miniPlayerActive = false }
            // A queued advance already moved the session on to the new channel: keep that same session (and its
            // streams) instead of handing out a fresh, never-started one on the next fold/unfold or stop.
            else if let session = activeSession {
                if let playing, session.isPlaying(playing) {
                    activeSessionChannel = playing
                }
                // Otherwise judged on the channel alone. `isPlaying` only turns true once the async `prepare` has
                // finished, so anything that re-assigned `playing` mid-load — a Duo fold, a body
                // re-evaluation — threw the in-flight session away and started the episode again.
                else if activeSessionChannel != playing { activeSession = nil; activeSessionChannel = nil }
            }
        }
    }
    /// The playback session handed across an iPhone Duo fold/unfold, so the watch page and the full-screen player
    /// reuse the same player instead of each building a new one (which dropped the position and episode).
    @ObservationIgnored private var activeSession: PlaybackSession?
    /// The channel the session was handed out for. `isPlaying` only reports true once the async `prepare`
    /// has finished, so a fold/unfold during that load would otherwise build a fresh session and restart
    /// the episode. Matching on the channel keeps the in-flight session.
    @ObservationIgnored private var activeSessionChannel: Channel?
    func playbackSession(for channel: Channel) -> PlaybackSession {
        if let session = activeSession, activeSessionChannel == channel { return session }
        let session = PlaybackSession()
        activeSession = session
        activeSessionChannel = channel
        return session
    }
    /// Stop playback cleanly: run the session's own teardown (history save, stream/remux stop, danmaku
    /// clear) before dropping the channel. `playing = nil` alone skips that teardown and leaks the
    /// background resources the session owns.
    func stopPlaying() {
        activeSession?.stop()
        playing = nil
    }
    /// Set while a listening source's episode goes to the video player on purpose.
    @ObservationIgnored private var playsAsVideo = false
    /// The videos whose iPhone watch page is on screen (`PlaybackHistoryContext.id`): their episodes play at the top
    /// of the page instead of in the full-screen player.
    var watchPageScopes: Set<String> = []
    var playbackCatalog: PlaybackCatalog?
    /// Set when the last episode of a line ends: what the end screen should offer.
    /// Nil while nothing has finished, which is also what dismisses the screen.
    var seriesEnd: SeriesEnd?
    /// What the end-of-series screen draws. `suggestions` is ranked with the same
    /// source and the same show first (a follow-up season, 红果 style); the
    /// screen auto-plays the top "next season" row after a countdown.
    struct SeriesEnd: Identifiable {
        let id = UUID()
        let channel: Channel
        let title: String
        let suggestions: [SeriesSuggestion]
    }
    /// The Cloud Files folder the playing file came from; its next file plays after it.
    var filesFolder: CloudFilesFolder?
    /// Ranked suggestions keyed by normalized title, so the pause menu can reopen
    /// without re-querying the source.
    private var seriesSuggestionCache: [String: [SeriesSuggestion]] = [:]
    var resolvingEpisode: Episode?
    var episodeError: String?
    /// Whether the episode picker is open on the player. Held here, not in the player's own state,
    /// so an iPhone Duo fold/unfold — which tears the player down and rebuilds it as the watch page
    /// swaps its layout — keeps the picker open instead of snapping it shut mid-selection. The video
    /// itself keeps playing throughout (the session survives the same swap), so the picker should too.
    var showsEpisodes = false {
        didSet { if !showsEpisodes { clearEpisodePickerLine() } }
    }
    /// The video the picker's temporary line choice belongs to. `episodePickerLine` alone is a bare
    /// flag string and flags are reused across every video of a source ("高清"/"流畅"/…), so the line
    /// must be scoped to the video it was picked on. Without this, an open picker carried across a
    /// Duo fold — or across an auto-advance / series-suggestion switch — would restore video A's line
    /// onto video B whenever the two happen to share a flag name.
    var episodePickerVideoID: String?
    /// The line the picker is currently showing (chosen but not yet played). Held here, not in the
    /// picker's own state, so a Duo fold/unfold — which rebuilds the picker — keeps the viewer's
    /// just-picked line instead of snapping back to the saved one. Scoped by `episodePickerVideoID`
    /// and cleared when the picker closes.
    var episodePickerLine: String?

    /// Resets the picker's temporary line choice. Called from every path that closes the picker, so a
    /// stale choice never leaks into the next video's picker (the `showsEpisodes` `didSet` only fires
    /// when the flag is written through, which a sheet dismiss or a torn-down view does not do).
    func clearEpisodePickerLine() {
        episodePickerVideoID = nil
        episodePickerLine = nil
    }
    var autoPlayNext: Bool {
        didSet { if persistsChanges { defaults.set(autoPlayNext, forKey: "autoPlayNextEpisode") } }
    }
    /// Whether the keychain auto-backup leg is on. Toggled in Settings; when on, every change to the
    /// backed-up slices (accounts, vault, proxies, preferences, history, favourites, subscriptions)
    /// rewrites the keychain snapshot so a reinstall restores them without a manual file.
    var keychainBackupEnabled: Bool {
        get { defaults.object(forKey: Self.keychainBackupKey) as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: Self.keychainBackupKey)
            if newValue { persistKeychainBackup() }
            else if persistsChanges { KeychainBackup.clear() }
        }
    }
    private var episodeRequest = UUID()
    private var episodeTask: Task<Void, Never>?
    /// Loads the end-of-series suggestions; cancelled when the screen is dismissed.
    private var seriesEndTask: Task<Void, Never>?
    var section: AppSection = .home
    /// Every build shows the built-in services (Music, Bilibili, Douyin), the default subscription and
    /// the plugin pages only once a subscription that works has been added: one that is on and whose
    /// copy has sources or live playlists.
    var extrasUnlocked: Bool {
        subscriptions.contains { $0.enabled && documents[$0.address].map { !$0.sites.isEmpty || !$0.lives.isEmpty } == true }
    }
    /// Yingxia's own sources (`CloudSources`), added beside the viewer's subscriptions once one works.
    private(set) var cloudDocument: Subscription?
    @ObservationIgnored private var cloudFetchedAt: Date?
    @ObservationIgnored private var cloudFetch: Task<Void, Never>?
    /// Sections kept out of the tab bar and sidebar until then.
    /// [mi3s] 二开融合：上游 1.8.11 新增 Manga 分区；无 Venera 漫画源订阅时隐藏。
    var hiddenSections: [AppSection] {
        var hidden: [AppSection] = extrasUnlocked ? [] : [.music]
        if MangaStore.shared.repositories.isEmpty { hidden.append(.manga) }
        return hidden
    }
    /// The app's preference store. Internal (not private) so the full-backup extension can snapshot
    /// and restore the whitelisted keys.
    let defaults: UserDefaults
    private let http = HTTPClient()
    /// Rebuilt source rows are expensive (every source is classified and copied) and Watch Now reads
    /// them many times while drawing one frame. The stamp is the inputs, so a later frame reuses the row.
    /// Not observed: views fill these while drawing, and a write would draw every reader again.
    @ObservationIgnored private var siteListStamp = ""
    @ObservationIgnored private var cloudDrivesObserver: NSObjectProtocol?
    @ObservationIgnored private var automaticCache: [Site]?
    @ObservationIgnored private var orderedCache: [Site]?
    @ObservationIgnored private var recommendationCache: [Site]?
    @ObservationIgnored private var groupsCache: [Bool: [SourceGroup]] = [:]
    /// What the cached rows were built from: the merged subscription, which subscriptions are on, and the viewer's pins, hides, and order.
    private func currentSiteListStamp() -> String {
        let imported = subscription?.importedAt.timeIntervalSince1970 ?? 0
        let entries = environmentSubscriptions.map { "\($0.address)=\($0.enabled)" }.joined(separator: "\n")
        return "\(subscription?.origin.absoluteString ?? "")|\(imported)|\(subscription?.sites.count ?? 0)|\(entries)|\(pinnedSources.revision)|\(hiddenSources.revision)|\(vault.revision)|\(sourceOrder.revision)|\(sourceReassignment.revision)|\(sourceGroupBook.revision)"
    }
    private var persistsChanges: Bool {
        #if DEBUG
        return !defaults.bool(forKey: "qaIsolatedData")
        #else
        return true
        #endif
    }
    init(defaults: UserDefaults = .standard) {
        #if os(macOS)
        if defaults === UserDefaults.standard { Self.adoptPreviousBundleDefaults(defaults) }
        #endif
        self.defaults = defaults
        dismissedAggregateAddresses = Set(defaults.stringArray(forKey: Self.dismissedAggregatesKey) ?? [])
        #if DEBUG
        playbackDefaults = defaults.bool(forKey: "qaIsolatedData")
            ? UserDefaults(suiteName: "com.tvbox.yingxia.qa.player") ?? defaults : defaults
        playbackHistory = defaults.bool(forKey: "qaIsolatedData")
            ? PlaybackHistory(file: URL.cachesDirectory.appending(path: "qa-player-history.json"), defaults: playbackDefaults) : .shared
        #else
        playbackDefaults = defaults
        playbackHistory = .shared
        #endif
        pinnedSources = PinnedSources(defaults: playbackDefaults)
        hiddenSources = HiddenSources(defaults: playbackDefaults)
        #if os(macOS) || os(iOS)
        WebSniff.install(WKWebSniffer())
        #endif
        sourceOrder = SourceOrder(defaults: playbackDefaults)
        sourceRouting = SourceRouting(defaults: playbackDefaults)
        customProxy = CustomProxyRouter.shared
        // These two are read from global `.shared` singletons in the playback/edit paths
        // (PlaybackSession has no Store), so they must BE those singletons — a separate instance
        // here would silently split the data and break per-line routing and source overrides.
        // Built on this Store's own defaults, then published as the shared instance: the player and
        // the source editor have no Store to ask, so they must read the same suite the app writes.
        sourceOverrides = SourceOverrides(defaults: playbackDefaults)
        lineSettings = LineSettings(defaults: playbackDefaults)
        SourceOverrides.shared = sourceOverrides
        LineSettings.shared = lineSettings
        sourceReassignment = SourceReassignment(defaults: playbackDefaults)
        sourceGroupBook = SourceGroupBook(defaults: playbackDefaults)
        cloudSync = defaults === UserDefaults.standard && !defaults.bool(forKey: "qaIsolatedData") ? CloudSync() : nil
        favorites = Favorites(defaults: defaults)
        var loadedAI = SubtitleTranslator.Configuration(baseURL: "", model: "", apiKey: "", targetLanguage: "")
        if let blob = playbackDefaults.data(forKey: Self.aiTranslationKey),
           let decoded = try? JSONDecoder().decode(SubtitleTranslator.Configuration.self, from: blob) { loadedAI = decoded }
        aiTranslation = loadedAI
        // Install the AI translator here rather than at launch: the configuration lives in these
        // defaults, so this is the first moment it is known. `install()` has already set the
        // device's translator; a configured service replaces it, an unconfigured one leaves it.
        var loadedEnvironments = Environments()
        let hadSavedEnvironments = playbackDefaults.data(forKey: Self.environmentsKey)
            .flatMap { try? JSONDecoder().decode(Environments.self, from: $0) }
        if let hadSavedEnvironments { loadedEnvironments = hadSavedEnvironments }
        environments = loadedEnvironments
        // [mi3s] 二开：第一次运行时把默认环境立刻写到磁盘。
        //
        // 不写的话，`Environments()` 的默认参数 `[Environment(name:)]` 每次都会生成新的 UUID，
        // 而订阅、历史、收藏都是用当时的 `environmentID` 盖戳的：下次启动 UUID 变了，
        // `shows()` 一比不等，全部条目被过滤掉 —— 表现就是「导入的订阅重启就没了」，
        // 而且每导一次都追加一条带新 UUID 的记录，越积越多但一条也看不见。
        if hadSavedEnvironments == nil, let blob = try? JSONEncoder().encode(loadedEnvironments) {
            playbackDefaults.set(blob, forKey: Self.environmentsKey)
        }
        SubtitleTranslationSetup.installAI(configuration: loadedAI)
        // The default environment owns everything written before environments existed, so history
        // needs its id to filter those legacy rows correctly.
        playbackHistory.defaultEnvironmentID = loadedEnvironments.all.first?.id
        // New records go to the environment on screen. Without this the video player — which holds
        // `PlaybackHistory.shared` and has no store — stamped every row `nil`, so all environments
        // shared one history and switching did nothing.
        playbackHistory.activeEnvironmentID = loadedEnvironments.activeID
        // Favourites are partitioned the same way, and for the same reason.
        favorites.defaultEnvironmentID = loadedEnvironments.all.first?.id
        favorites.activeEnvironmentID = loadedEnvironments.activeID
        if let blob = playbackDefaults.data(forKey: Self.artworkLanguageKey),
           let decoded = try? JSONDecoder().decode(ArtworkLanguage.self, from: blob) { artworkLanguage = decoded }
        if let blob = playbackDefaults.data(forKey: Self.skipSourcesKey),
           let decoded = try? JSONDecoder().decode(SkipSegmentSources.self, from: blob) { skipSources = decoded }
        if let blob = playbackDefaults.data(forKey: Self.resourceRankingKey),
           let decoded = try? JSONDecoder().decode(ResourceRanking.self, from: blob) { resourceRanking = decoded }
        if let blob = playbackDefaults.data(forKey: Self.vaultKey),
           let saved = try? JSONDecoder().decode(PrivacyVault.self, from: blob) {
            vault = saved
        }
        autoPlayNext = defaults.object(forKey: "autoPlayNextEpisode") == nil || defaults.bool(forKey: "autoPlayNextEpisode")
        let saved = defaults.data(forKey: "subscriptions").flatMap { try? JSONDecoder().decode([SubscriptionEntry].self, from: $0) }
        var entries = saved ?? [], copies: [String: Subscription] = [:]
        for entry in entries {
            if let data = try? Data(contentsOf: Self.file(for: entry)),
               let value = try? JSONDecoder().decode(Subscription.self, from: data) { copies[entry.address] = value }
        }
        // Builds before several subscriptions kept one, in subscription.json, and before that in defaults.
        let legacyAddress = saved == nil ? defaults.string(forKey: "subscriptionAddress") : nil
        let legacy = legacyAddress == nil ? nil : (try? Data(contentsOf: Self.legacyFile)) ?? defaults.data(forKey: "subscription")
        if let legacyAddress {
            entries = [SubscriptionEntry(address: legacyAddress)]
            copies[legacyAddress] = legacy.flatMap { try? JSONDecoder().decode(Subscription.self, from: $0) }
        }
        // [mi3s] 二开：把「指向不存在环境」的订阅收回默认环境。
        //
        // 旧版本从没把 `environments` 写盘，每次启动都是新 UUID，于是每次导入都挂在一个
        // 只存在于当次运行里的 UUID 上 —— 这些记录谁都看不见，还会越积越多（同一地址多条）。
        // 归属不明的记录统一落到默认环境，并按地址去重，保留最新那条。
        var rescuedAny = false
        if !entries.isEmpty {
            let known = Set(loadedEnvironments.all.map(\.id))
            let fallback = loadedEnvironments.all[0].id
            var seen = Set<String>()
            var rescued: [SubscriptionEntry] = []
            for entry in entries.reversed() {
                guard !seen.contains(entry.address) else { continue }
                var fixed = entry
                if fixed.environmentID.map({ !known.contains($0) }) ?? true {
                    fixed.environmentID = fallback
                    rescuedAny = true
                }
                if fixed.address != entry.address { rescuedAny = true }
                seen.insert(fixed.address)
                rescued.append(fixed)
            }
            if rescued.count != entries.count { rescuedAny = true }
            entries = rescued.reversed()
        }
        subscriptions = entries
        documents = copies
        // 迁移/去重改动过就必须落盘，否则下次启动读回的仍是那两个孤儿 UUID。
        // init 里不能读 `self.persistsChanges`（还没初始化完），按同样条件就地判断。
        #if DEBUG
        let mayPersist = !defaults.bool(forKey: "qaIsolatedData")
        #else
        let mayPersist = true
        #endif
        if rescuedAny, mayPersist {
            defaults.set(try? JSONEncoder().encode(entries), forKey: "subscriptions")
        }

        let cloud = (try? Data(contentsOf: Self.cloudFile)).flatMap { try? JSONDecoder().decode(Subscription.self, from: $0) }.flatMap { CloudSources.accepts($0) ? $0 : nil }
        cloudDocument = cloud
        CloudSources.current = cloud
        subscriptionAddress = ""
        if persistsChanges, let legacyAddress {
            if let legacy, copies[legacyAddress] != nil { try? Self.save(legacy, to: Self.file(for: entries[0])) }
            saveSubscriptionList()
            try? FileManager.default.removeItem(at: Self.legacyFile)
            defaults.removeObject(forKey: "subscription")
        }
        rebuildSubscription(resetting: false)
        // Signing in to a drive or adding a server adds its source; signing out or removing one takes it away.
        cloudDrivesObserver = NotificationCenter.default.addObserver(forName: CloudFiles.drivesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshCloudFilesSources()
                // A sign-in changed the account files that the lightweight iCloud backup carries.
                self?.cloudSync?.changed("cloudBackup")
            }
        }
        searchModel.order = sourceOrder
        DownloadLibrary.shared.resolver = { [weak self] item in
            guard let self else { throw CancellationError() }
            return try await self.resolveDownload(item)
        }
        // Songs that were downloading when the app quit carry on.
        MusicDownloadLibrary.shared.wake()
        setUpListening()
        setUpCloudSync()
        #if os(iOS)
        installCaptureGuards()
        #endif
        // Start the web server if the feature is compiled in and switched on.
        #if WEBCAST
        Task { await webCast.start(with: self) }
        #endif
        // A reinstall has no sandbox data but the keychain leg survived. When the viewer turned the
        // leg on, restore it automatically — but only into an empty install, so it can never clobber
        // a freshly-signed-in account on a different device that happens to share the keychain.
        restoreKeychainBackupIfFresh()
    }

    /// Restores the keychain snapshot once, on a fresh install where the leg is on and there is
    /// nothing to overwrite. Runs only when the backed-up slices are empty on this launch, so a
    /// device that already has data never gets it replaced by an older snapshot.
    private func restoreKeychainBackupIfFresh() {
        // Deliberately NOT gated on `keychainBackupEnabled`: that flag lives inside the backed-up
        // preferences, so it is `false` on a fresh install and gating here would dead-lock recovery.
        // The keychain is only non-empty when the switch was last on (turning it off calls
        // `KeychainBackup.clear()`), so "a backup exists" already means the user wants it back.
        guard persistsChanges else { return }
        // "Fresh" = no subscriptions, no history, no favourites, no vault passcode and no accounts.
        let empty = subscriptions.isEmpty && playbackHistory.entries.isEmpty
            && favorites.syncValues.isEmpty && !vault.hasPasscode
            && FullBackupAccountStore.collect().isEmpty
        guard empty, let result = KeychainBackup.load() else { return }
        importFullBackup(result.backup, categories: .all)
    }
    // MARK: Listening sources (#289)

    /// The music player's queue for an episode of a listening source: the episodes of its line, from it on. Nil for
    /// other sources, for one whose streams turned out to be videos, and when the episode's details aren't at hand.
    private func listeningQueue(for channel: Channel) -> MusicQueue? {
        guard !playsAsVideo, let context = channel.historyContext, let catalog = catalog(for: channel),
              AudioSources.isCandidate(catalog.client.site),
              !AudioSourceVerdicts(defaults: playbackDefaults).showsVideo(context),
              let episode = context.episode(in: catalog.video.episodes) else { return nil }
        return AudioSources.queue(video: catalog.video, from: episode, site: catalog.client.site, origin: catalog.client.origin)
    }

    /// Plays the queue from the channel's stream, where this chapter stopped last time.
    private func listen(_ queue: MusicQueue, from channel: Channel) {
        var position = channel.resumePosition
        if position == nil, let context = channel.historyContext,
           let saved = playbackHistory.entries(in: activeEnvironmentID).first(where: { $0.id == context.id }),
           saved.context.episodeID == context.episodeID, saved.context.episodeFlag == context.episodeFlag, saved.resumePosition > 1 {
            position = saved.resumePosition
        }
        Diagnostics.shared.record(.info, "music", "listening source \(channel.historyContext?.sourceKey ?? "-") queue=\(queue.tracks.count)")
        music.play(queue, at: position, stream: channel)
    }

    /// The music player gets a source's streams from here, saves where a book is in the playback history, and hands
    /// an episode with a picture, or one it can't play, to the video player.
    private func setUpListening() {
        music.resolveSource = { [weak self] source in
            guard let self else { throw CancellationError() }
            return try await self.resolveListening(source)
        }
        music.recordSource = { [weak self] source, position, duration in
            self?.playbackHistory.record(source.context, position: position, duration: duration,
                                        environment: self?.environments.activeID)
        }
        music.handOffSource = { [weak self] stream, position, picture, covered in
            guard let self, let context = stream.historyContext else { return }
            if picture { AudioSourceVerdicts(defaults: self.playbackDefaults).recordVideo(context) }
            let channel = Channel(name: stream.name, group: stream.group, url: stream.url, logo: stream.logo, headers: stream.headers,
                                  skipScope: stream.skipScope, historyContext: context, resumePosition: position > 1 ? position : nil,
                                  subtitles: stream.subtitles)
            Task { @MainActor [weak self] in
                // The video player can't open while Now Playing is still closing (as PlayOn waits for the player).
                if covered { try? await Task.sleep(for: .milliseconds(700)) }
                guard let self, self.playing == nil else { return }
                self.playsAsVideo = true
                self.playing = channel
                self.playsAsVideo = false
            }
        }
    }

    /// A chapter's stream from its source, as Continue Watching gets an episode's.
    private func resolveListening(_ source: MusicSourceEpisode) async throws -> Channel {
        let context = source.context
        guard let client = historyClient(PlaybackHistoryEntry(context: context, position: 0, duration: 0, updatedAt: Date())) else {
            throw TVError.unsupported(L10n.text("This history source is no longer in the current subscription. Restore that subscription to continue."))
        }
        let resolved = try await client.playback(source.episode)
        return Channel(name: "\(context.videoName) · \(context.episodeName)", group: resolved.group, url: resolved.url, logo: resolved.logo,
                       headers: resolved.headers, skipScope: context.id, historyContext: context, subtitles: resolved.subtitles)
    }

    /// The current media address of a downloading episode, from its source; the queue asks again when a link expires.
    private func resolveDownload(_ item: DownloadItem) async throws -> Channel {
        let config = subscription
        guard let found = config?.sites.first(where: { $0.key == item.source.siteKey })
                ?? cloudDocument?.sites.first(where: { $0.key == item.source.siteKey }) else {
            throw TVError.unsupported(L10n.text("%@ is no longer in your subscription, so this download can't continue.", item.source.siteName))
        }
        let origin = config?.origin ?? URL(string: "https://example.invalid/")!
        let site = config == nil ? found : resolvedSite(found, origin: origin)
        let base = CatalogClient(site: site, origin: origin, jarURL: config?.spiderURL)
        let client = config.map { base.applying($0) } ?? base
        let plan = try await client.preparePlayback(item.source.episode, forDownload: true)
        let channel = try await client.resolvePlayback(plan, choice: plan.choices[0])
        // A cloud-drive file downloads straight from its CDN, as it plays: through the plugin's
        // proxy every part costs the embedded runtime download threads and interpreted TLS.
        // A file of a drive in Cloud Files downloads from the address its stream reads.
        if channel.url.scheme == CloudStreams.scheme, let media = await CloudStreams.source(for: channel.url) {
            CloudStreams.stop(channel.url)
            return Channel(name: channel.name, group: channel.group, url: media.url, headers: media.headers)
        }
        // A drive's HLS copy downloads with the headers its CDN wants.
        if let headers = CloudStreams.playlistHeaders(for: channel.url) {
            CloudStreams.stop(channel.url)
            return Channel(name: channel.name, group: channel.group, url: channel.url, headers: channel.headers.merging(headers) { $1 })
        }
        let address = try await EmbeddedJarHost.shared.recoverProxy(channel.url)
        if let media = await EmbeddedJarHost.shared.directMedia(address) {
            Diagnostics.shared.record(.info, "download", "cloud direct host=\(media.url.host() ?? "-") length=\(media.length)")
            return Channel(name: channel.name, group: channel.group, url: media.url, headers: media.headers)
        }
        return address == channel.url ? channel : Channel(name: channel.name, group: channel.group, url: address, headers: channel.headers)
    }
    /// Large subscriptions run to megabytes, past the defaults size limit that aborts tvOS apps,
    /// so each parsed subscription lives in a file. tvOS only offers Caches, which the system may purge;
    /// `restoreSubscription()` refetches what is gone from the saved addresses.
    private static var subscriptionDirectory: URL {
        #if os(tvOS)
        return URL.cachesDirectory
        #else
        return URL.applicationSupportDirectory
        #endif
    }
    private static var legacyFile: URL { subscriptionDirectory.appending(path: "subscription.json") }
    private static var cloudFile: URL { subscriptionDirectory.appending(path: "cloud-sources.json") }
    private static func file(for entry: SubscriptionEntry) -> URL {
        subscriptionDirectory.appending(path: "subscriptions").appending(path: entry.cacheName)
    }
    private static func save(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
    /// Lets sources on a shared spider borrow classes from the subscription's other plugin archives.
    private static func registerPlugins(_ subscription: Subscription) {
        let archives = subscription.pluginArchives
        Task { await PluginLocator.shared.use(archives) }
    }
    /// Refetches enabled subscriptions whose cached copy is gone.
    func restoreSubscription() async {
        let missing = environmentSubscriptions.filter { $0.enabled && documents[$0.address] == nil }
        guard !missing.isEmpty else { return }
        await beginImport()
        importing = true
        defer { importing = false; endImport() }
        await fetch(missing)
    }
    /// On launch, makes sure the aggregated subscriptions are all present, importing any that are
    /// missing. Existing entries are left untouched (their saved copy wins), so overwriting either
    /// bundle never orphans the other bundle's sources.
    ///
    /// One exception, and it is the viewer's: an address they deleted is not put back. Without it,
    /// deleting the local Rex feed or the 124.223 server was undone by the next launch, which reads
    /// as the app refusing to take no for an answer.
    func seedAggregatedSubscriptions() async {
        guard !Distribution.isAppStore else { return }
        let pending = Self.aggregatedSubscriptionAddresses.filter { address in
            !dismissedAggregateAddresses.contains(address) && !subscriptions.contains { $0.address == address }
        }
        guard !pending.isEmpty else { return }
        // Add them up front, then fetch side by side: the merged list grows as each one answers,
        // instead of a serial loop where the viewer waits through every full fetch in turn.
        let entries = pending.map { stamping(SubscriptionEntry(address: $0, name: "")) }
        subscriptions += entries
        saveSubscriptionList()
        await beginImport()
        importing = true; importError = nil; notice = nil
        defer { importing = false; endImport() }
        await fetch(entries)
    }
    /// Adds the typed address, or refreshes it when it is already in the list. A directory (多仓)
    /// adds every subscription it lists, switched off, for the viewer to choose from.
    /// [mi3s] 二开融合：`name` 形参来自上游 1.8.11（`yingxia://import` 链接可带名字）。
    /// 我方原有 `subscriptionName` 输入框语义不变：`name` 为 nil 时仍读输入框。
    func importSubscription(address: String? = nil, name: String? = nil) async {
        await beginImport()
        importing = true; importError = nil; notice = nil
        defer { importing = false; endImport() }
        let typed = (address ?? subscriptionAddress).trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let url = try WebAddress.resolve(typed)
            switch try await http.subscriptionImport(url) {
            case .subscription(let value):
                let entryName = name ?? (address == nil ? subscriptionName.trimmingCharacters(in: .whitespacesAndNewlines) : "")
                let entry = stamping(SubscriptionEntry(address: url.absoluteString, name: entryName))
                if let index = subscriptions.firstIndex(where: { $0.address == entry.address && environments.shows($0.environmentID) }) {
                    subscriptions[index].enabled = true
                    if !entryName.isEmpty { subscriptions[index].name = entryName }
                } else { subscriptions.append(entry) }
                // Added back by hand: forget that it was ever deleted, so launch-time seeding
                // treats it like any other subscription again.
                if dismissedAggregateAddresses.remove(entry.address) != nil { saveDismissedAggregates() }
                keep(value, for: entry)
                if persistsChanges { defaults.set(url.absoluteString, forKey: "subscriptionAddress") }
                notice = L10n.text("Imported sources: %lld · Live playlists: %lld", value.sites.count, value.lives.count)
            case .directory(let entries):
                let added = entries.filter { entry in !subscriptions.contains { $0.address == entry.address } }.map(stamping)
                subscriptions += added
                notice = L10n.text("This address lists %lld subscriptions. They were added switched off; turn on the ones you want.", added.count)
            case .comicSources(let count):
                // [mi3s] 二开融合：上游 1.8.11 新增。漫画源列表进 Manga（Venera），不进 Watch Now。
                MangaStore.shared.addRepository(url)
                notice = L10n.text("Added a Venera comic source list (%lld sources). Choose the ones to install in Comic Sources.", count)
            case .alist(let servers):
                // AList servers are browsed in Cloud Files, not merged as sources.
                let saved = try AListServers.add(servers)
                notice = saved.count == 1 ? L10n.text("Added the AList server %@. Browse it in Cloud Files.", saved[0].name)
                    : L10n.text("Added %lld AList servers. Browse them in Cloud Files.", saved.count)
            }
            if address == nil { subscriptionAddress = ""; subscriptionName = "" }
            saveSubscriptionList()
            rebuildSubscription()
        } catch {
            Diagnostics.shared.failure("subscription", "import host=\((try? WebAddress.resolve(typed))?.host() ?? "-")", error)
            importError = L10n.text("Import failed: %@", error.localizedDescription)
        }
    }
    /// Fetches every enabled subscription again; one that fails keeps its last good copy.
    func refreshSubscriptions() async {
        await beginImport()
        importing = true; importError = nil; notice = nil
        defer { importing = false; endImport() }
        await fetch(environmentSubscriptions.filter(\.enabled))
        refreshCloudSources(force: true)
        let failed = environmentSubscriptions.filter { $0.enabled && subscriptionErrors[$0.address] != nil }.count
        if failed > 0 { notice = L10n.text("%lld subscriptions could not be refreshed; their last copies stay in use.", failed) }
    }
    func setSubscription(_ entry: SubscriptionEntry, enabled: Bool) async {
        guard let index = index(of: entry) else { return }
        subscriptions[index].enabled = enabled
        saveSubscriptionList()
        if enabled, documents[entry.address] == nil { await restoreSubscription() } else { rebuildSubscription() }
    }
    /// Names a subscription in Settings and Sources; an empty name shows where it lives again.
    func renameSubscription(_ entry: SubscriptionEntry, to name: String) {
        guard let index = index(of: entry), subscriptions[index].name != name else { return }
        subscriptions[index].name = name
        saveSubscriptionList()
    }
    func removeSubscription(_ entry: SubscriptionEntry) { removeSubscriptions([entry.address]) }
    /// Removes several subscriptions and their saved copies, then merges what is left once.
    /// Only subscriptions of the active environment are removed, so an address kept under another
    /// sandbox survives.
    func removeSubscriptions(_ addresses: Set<String>) {
        let removed = environmentSubscriptions.filter { addresses.contains($0.address) }
        guard !removed.isEmpty else { return }
        subscriptions.removeAll { entry in
            addresses.contains(entry.address) && environments.shows(entry.environmentID)
        }
        // Deleting one of the feeds this build seeds at launch has to stick, or the next launch
        // adds it back and the delete looked like it failed.
        let aggregates = removed.map(\.address).filter(Self.aggregatedSubscriptionAddresses.contains)
        if !aggregates.isEmpty {
            dismissedAggregateAddresses.formUnion(aggregates)
            saveDismissedAggregates()
        }
        for entry in removed {
            let stillUsed = subscriptions.contains { $0.address == entry.address }
            if !stillUsed {
                documents[entry.address] = nil; subscriptionErrors[entry.address] = nil
                if persistsChanges { try? FileManager.default.removeItem(at: Self.file(for: entry)); ImportedFiles.remove(entry.address) }
            }
        }
        saveSubscriptionList()
        rebuildSubscription()
    }
    /// Moves a subscription one place up (-1) or down (1); earlier subscriptions win duplicate sources.
    func moveSubscription(_ entry: SubscriptionEntry, by offset: Int) {
        guard let index = index(of: entry),
              subscriptions.indices.contains(index + offset) else { return }
        subscriptions.swapAt(index, index + offset)
        saveSubscriptionList()
        rebuildSubscription()
    }
    /// Switches every subscription on or off at once — the fast path out of a directory import,
    /// which adds every listed subscription switched off. Only the active environment's subscriptions.
    func setAllSubscriptions(enabled: Bool) {
        guard !environmentSubscriptions.isEmpty else { return }
        subscriptions = subscriptions.map { entry in
            guard environments.shows(entry.environmentID) else { return entry }
            var copy = entry; copy.enabled = enabled; return copy
        }
        saveSubscriptionList()
        if enabled { Task { await restoreSubscription() } } else { rebuildSubscription() }
    }
    /// Total bytes of the parsed subscription copies on disk, for the cache row in Settings.
    func subscriptionCacheSize() -> Int64 {
        let dir = Self.subscriptionDirectory.appending(path: "subscriptions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { total, url in
            total + (Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
    }
    /// Deletes the on-disk copies; enabled subscriptions are re-fetched, so nothing is lost.
    func clearSubscriptionCache() {
        let dir = Self.subscriptionDirectory.appending(path: "subscriptions")
        try? FileManager.default.removeItem(at: dir)
        documents.removeAll()
        Task { await restoreSubscription() }
    }
    /// Merges a configuration file in. `overwrite` decides what happens to an address that is
    /// already present: by default (merge) it is left untouched, so re-importing never duplicates or
    /// overwrites; with `overwrite` the file's name, enabled state and routing win, so a backup
    /// restores the exact state it was exported in. In both modes the list is reordered to the
    /// file's rank, and a fresh entry that carries a content snapshot is restored without a fetch.
    func importConfig(_ config: SubscriptionConfig, overwrite: Bool = false) {
        guard config.isValid else {
            importError = L10n.text("This isn't a Mi3s configuration file.")
            return
        }
        let incoming = config.subscriptions.sorted { ($0.rank, $0.entry.address) < ($1.rank, $1.entry.address) }
        let incomingSet = Set(incoming.map(\.entry.address))

        // Environments are independent, so an import only touches the environment on screen: a
        // subscription address that only another sandbox keeps is left alone, and the file is the
        // authority only over the active environment's subscriptions.
        var current: [String: SubscriptionEntry] = [:]
        for entry in environmentSubscriptions { current[entry.address] = entry }

        var removedCount = 0
        for entry in environmentSubscriptions where !incomingSet.contains(entry.address) {
            current[entry.address] = nil
            removedCount += 1
            subscriptions.removeAll { $0.address == entry.address && environments.shows($0.environmentID) }
            let stillUsed = subscriptions.contains { $0.address == entry.address }
            if !stillUsed {
                documents[entry.address] = nil; subscriptionErrors[entry.address] = nil
                if persistsChanges { try? FileManager.default.removeItem(at: Self.file(for: entry)); ImportedFiles.remove(entry.address) }
            }
        }

        var added: [SubscriptionEntry] = []
        var restored: [(SubscriptionEntry, Subscription)] = []

        for synced in incoming {
            if var entry = current[synced.entry.address] {
                if overwrite {
                    // Restore the exported name / switch / routing over the current copy.
                    entry.name = synced.entry.name
                    entry.enabled = synced.entry.enabled
                    entry.routing = synced.entry.routing
                    if let document = synced.document { restored.append((entry, document)) }
                }
                if let index = index(of: entry) { subscriptions[index] = entry }
            } else {
                // A subscription the file has and this device does not. It used to be collected and
                // never inserted, which is why a fresh install could not restore anything. Stamped to
                // the active environment so an import lands in the sandbox on screen.
                let stamped = stamping(synced.entry)
                subscriptions.append(stamped)
                added.append(stamped)
                if let document = synced.document { restored.append((stamped, document)) }
            }
        }

        guard !added.isEmpty || overwrite || removedCount > 0 else {
            notice = L10n.text("Every subscription in this file is already imported; nothing was added.")
            return
        }

        for (entry, document) in restored { keep(document, for: entry) }
        saveSubscriptionList()
        rebuildSubscription()
        // Entries that carried no snapshot still need their content fetched.
        let needFetch = environmentSubscriptions.filter { $0.enabled && documents[$0.address] == nil }
        if !needFetch.isEmpty { Task { await restoreSubscription() } }

        if overwrite {
            notice = L10n.text("Restored %lld subscriptions from the backup.", incoming.count)
        } else if !added.isEmpty {
            notice = L10n.text("Imported %lld subscriptions.", added.count)
        } else {
            notice = L10n.text("Removed %lld subscriptions that this file does not list.", removedCount)
        }
    }

    func moveSourceGroup(_ address: String, onto target: String, includeHidden: Bool) {
        let shown = sourceGroups(includeHidden: includeHidden).compactMap { group -> String? in
            guard case .subscription(let value) = group.kind else { return nil }
            return value
        }
        let next = SubscriptionOrder.moving(address, onto: target, in: shown)
        guard next != shown else { return }
        subscriptions = SubscriptionOrder.applying(displayed: next, to: subscriptions)
        saveSubscriptionList()
        rebuildSubscription()
    }

    /// Fetches subscriptions side by side, keeps what arrives, and shows the merged result. A
    /// subscription that turns out to be a directory is replaced by the ones it lists, switched off.
    /// Each source is folded in and the merged list rebuilt as soon as it answers — the viewer sees
    /// sources appear one by one instead of waiting for the slowest subscription (a dead host would
    /// otherwise hold up every result for its whole timeout).
    private func fetch(_ entries: [SubscriptionEntry]) async {
        let http = http
        var rebuilt = false
        importTotal = entries.count
        importDone = 0
        await withTaskGroup(of: (SubscriptionEntry, Result<SubscriptionImport, any Error>).self) { group in
            for entry in entries {
                group.addTask {
                    do { return (entry, .success(try await http.subscriptionImport(WebAddress.resolve(entry.address)))) }
                    catch { return (entry, .failure(error)) }
                }
            }
            for await (entry, result) in group {
                await MainActor.run {
                    self.apply(result, for: entry)
                    self.importDone += 1
                    // The first result resets the search/recommendation models; later ones merge in
                    // without resetting, so a search the viewer already started stays put.
                    self.rebuildSubscription(resetting: !rebuilt)
                }
                rebuilt = true
            }
            await MainActor.run { self.saveSubscriptionList() }
        }
    }

    /// Folds one fetched result into the store: a subscription is kept, a directory is expanded, and a
    /// failure is remembered against its address.
    private func apply(_ result: Result<SubscriptionImport, any Error>, for entry: SubscriptionEntry) {
        switch result {
        case .success(.subscription(let value)): keep(value, for: entry)
        case .success(.directory(let listed)):
            guard let index = index(of: entry) else { return }
            let known = Set(subscriptions.map(\.address))
            let stamped = listed.map { var item = $0; item.environmentID = entry.environmentID ?? environments.all[0].id; return item }
            subscriptions.replaceSubrange(index...index, with: stamped.filter { !known.contains($0.address) })
        case .success(.comicSources):
            // [mi3s] 二开融合：上游 1.8.11 新增。
            subscriptionErrors[entry.address] = L10n.text("This address is now a comic source list. Add it again to use it for Manga.")
        case .success(.alist):
            subscriptionErrors[entry.address] = L10n.text("This address is now an AList server. Add it again to browse it in Cloud Files.")
        case .failure(let error):
            Diagnostics.shared.failure("subscription", "refresh host=\(URL(string: entry.address)?.host() ?? "-")", error)
            subscriptionErrors[entry.address] = error.localizedDescription
        }
    }
    private func keep(_ value: Subscription, for entry: SubscriptionEntry) {
        documents[entry.address] = value
        subscriptionErrors[entry.address] = nil
        if persistsChanges, let data = try? JSONEncoder().encode(value) { try? Self.save(data, to: Self.file(for: entry)) }
    }
    private func saveSubscriptionList() {
        guard persistsChanges else { return }
        defaults.set(try? JSONEncoder().encode(subscriptions), forKey: "subscriptions")
        cloudSync?.changed("subscriptions")
    }
    private func saveDismissedAggregates() {
        guard persistsChanges else { return }
        defaults.set(Array(dismissedAggregateAddresses), forKey: Self.dismissedAggregatesKey)
    }
    /// Favorites, Continue Watching, subscriptions and the viewer's pins, hides and order follow them to their other
    /// devices. Continue Watching changes every few seconds while a video plays, so it waits longer between writes.
    private func setUpCloudSync() {
        guard let sync = cloudSync else { return }
        let favorites = favorites, history = playbackHistory, pinned = pinnedSources, hidden = hiddenSources, order = sourceOrder
        let routing = sourceRouting, overrides = sourceOverrides, lines = lineSettings, reassignment = sourceReassignment
        sync.register("favorites", current: { favorites.syncValues }, apply: { favorites.adopt($0) })
        sync.register("history", delay: .seconds(30), current: { Dictionary(history.entries.map { ($0.environmentKey, $0) }, uniquingKeysWith: { first, _ in first }) },
                      apply: { history.adopt($0.map(\.value)) })
        sync.register("subscriptions", current: { [weak self] in self?.syncedSubscriptions ?? [:] }, apply: { [weak self] in self?.adoptSubscriptions($0) })
        sync.register("pinnedSources", current: { CloudSync.ranks(pinned.savedKeys) }, apply: { pinned.adopt(CloudSync.ordered($0)) })
        sync.register("hiddenSources", current: { Dictionary(hidden.savedKeys.map { ($0, true) }, uniquingKeysWith: { first, _ in first }) },
                      apply: { hidden.adopt($0.sorted { ($0.stamp, $0.id) < ($1.stamp, $1.id) }.map(\.id)) })
        sync.register("sourceOrder", current: { CloudSync.ranks(order.savedKeys) }, apply: { order.adopt(CloudSync.ordered($0)) })
        // Only "on" is an item: a new device's default (off) is no change, so it can't switch the order off everywhere.
        sync.register("sourceOrderOn", current: { order.enabled ? ["on": true] : [:] }, apply: { if order.enabled == $0.isEmpty { order.enabled = !$0.isEmpty } })
        // The source-level edits follow the viewer too. They were left out of the first pass, so a
        // rename, an API override, a hidden line or a moved source only lived on the device that made it.
        sync.register("sourceRouting", current: { routing.savedValues }, apply: { routing.adopt(Self.dictionary($0)) })
        sync.register("sourceOverrides", current: { overrides.savedValues }, apply: { overrides.adopt(Self.dictionary($0)) })
        sync.register("lineSettings", current: { lines.savedValues }, apply: { lines.adopt(Self.dictionary($0)) })
        sync.register("sourceReassignment", current: { reassignment.savedValues }, apply: { reassignment.adopt(Self.dictionary($0)) })
        // The lightweight slices a fresh install would otherwise lose — sign-in state, the vault,
        // proxies and preferences — travel as one small payload (subscriptions/history/favourites
        // already have their own channels above).
        sync.register("cloudBackup", current: { [weak self] () -> [String: CloudBackupPayload] in
            guard let self else { return [:] }
            let payload = self.cloudBackupPayload()
            guard !payload.isEmpty else { return [:] }
            return ["backup": payload]
        }, apply: { [weak self] items in
            guard let self, let payload = items.first(where: { $0.id == "backup" })?.value else { return }
            self.applyCloudBackupPayload(payload)
        })
        favorites.onChange = { sync.changed("favorites"); self.persistKeychainBackup() }
        history.onChange = { sync.changed("history"); self.persistKeychainBackup() }
        pinned.onChange = { sync.changed("pinnedSources") }
        hidden.onChange = { sync.changed("hiddenSources") }
        order.onChange = { sync.changed("sourceOrder"); sync.changed("sourceOrderOn") }
        routing.onChange = { sync.changed("sourceRouting") }
        overrides.onChange = { sync.changed("sourceOverrides") }
        lines.onChange = { sync.changed("lineSettings") }
        reassignment.onChange = { sync.changed("sourceReassignment") }
    }
    /// CloudSync hands an `apply` closure a list of `CloudSyncItem`s; the source-level stores each
    /// adopt a plain `[String: Value]`, so this folds the items back into one dictionary.
    private static func dictionary<Value>(_ items: [CloudSyncItem<Value>]) -> [String: Value] {
        Dictionary(items.map { ($0.id, $0.value) }, uniquingKeysWith: { first, _ in first })
    }
    private var syncedSubscriptions: [String: SyncedSubscription] {
        Dictionary(subscriptions.enumerated().map { ($0.element.address, SyncedSubscription(entry: $0.element, rank: $0.offset, document: documents[$0.element.address])) },
                   uniquingKeysWith: { first, _ in first })
    }
    /// Subscriptions another device added, renamed, switched, moved or removed. A new one that is on loads.
    /// Subscription content another device synced, so a second device lists a feed's sources without
    /// fetching it again. A copy already on disk wins.
    private func adoptSyncedDocuments(_ synced: [CloudSyncItem<SyncedSubscription>]) {
        for item in synced {
            guard let document = item.value.document, documents[item.id] == nil else { continue }
            documents[item.id] = document
            if persistsChanges, let data = try? JSONEncoder().encode(document) { try? Self.save(data, to: Self.file(for: SubscriptionEntry(address: item.id))) }
        }
    }
    private func adoptSubscriptions(_ synced: [CloudSyncItem<SyncedSubscription>]) {
        adoptSyncedDocuments(synced)
        let next = synced.sorted { ($0.value.rank, $0.id) < ($1.value.rank, $1.id) }.map(\.value.entry)
        guard next != subscriptions else { return }
        let kept = Set(next.map(\.address))
        for entry in subscriptions where !kept.contains(entry.address) {
            documents[entry.address] = nil; subscriptionErrors[entry.address] = nil
            try? FileManager.default.removeItem(at: Self.file(for: entry))
        }
        subscriptions = next
        saveSubscriptionList()
        if subscriptions.contains(where: { $0.enabled && documents[$0.address] == nil }) { Task { await restoreSubscription() } }
        else { rebuildSubscription() }
    }
    /// Shows every enabled subscription that has a copy, merged in list order.
    private func rebuildSubscription(resetting: Bool = true) {
        if resetting { searchModel.reset(); recommendationModel.reset() }
        subscription = Subscription.merge(environmentSubscriptions.filter(\.enabled).compactMap { documents[$0.address] })?.withCloudSources(extrasUnlocked ? cloudDocument : nil)
        if let subscription { applySourceRouting(subscription) }
        refreshCloudSources()
        if let subscription {
            Self.registerPlugins(subscription)
            hiddenSources.restoreBuiltIns(subscription.sites, origin: subscription.origin)
            hiddenSources.restoreAutoHidden(subscription.sites, origin: subscription.origin, health: .shared)
            #if os(iOS) || os(tvOS)
            // Converts the visible JAR sources' likely classes while the app sits idle (issue #274).
            let visible = subscription.sites.filter { !hiddenSources.contains($0, origin: subscription.origin) }
            let origin = subscription.origin, spider = subscription.spiderURL
            Task { await PluginConversionAhead.shared.schedule(sites: visible, origin: origin, spider: spider) }
            #endif
        }
        adoptLegacyMoves()
    }

    /// Folds moves saved by a build that keyed them by the subscription's origin into the record the
    /// maintenance list reads. Without this an upgraded library keeps *applying* those moves but can
    /// never show or undo them: they are invisible in the list and their source's menu offers no
    /// "move back". Runs after every rebuild, and is a no-op once each one has been rewritten.
    /// Rewrites each source's `api` to direct or proxy according to the viewer's choices; `.auto`
    /// follows connectivity: a source that is failing on its own address is retried through the relay,
    /// and switched back once the direct line recovers.
    private func applySourceRouting(_ config: Subscription) {
        let byAddress = Dictionary(environmentSubscriptions.map { ($0.address, $0) }, uniquingKeysWith: { $1 })
        let sites = config.sites.map { site -> Site in
            let origin = site.origin(or: config.origin)
            let sub: SubscriptionEntry? = {
                if let po = site.provenance?.origin, let entry = byAddress[po.absoluteString] { return entry }
                return byAddress[origin.absoluteString]
            }()
            let explicit = sourceRouting.route(site, origin: origin)
            let effective = explicit ?? (sub?.routing ?? .auto)
            switch effective {
            case .direct:
                return site.routed(.direct)
            case .proxy:
                return site.routed(.proxy)
            case .auto:
                // Follow connectivity only for native sources whose address can be relayed.
                guard site.native, !site.api.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return site }
                let relayed = SourceRelay.isRelayed(site.api)
                let failing = SourceHealth.shared.failedRepeatedly(site, origin: origin)
                if failing && !relayed {
                    return site.routed(.proxy)
                } else if !failing && relayed {
                    return site.routed(.direct)
                }
                return site
            }
        }
        subscription = config.with(sites: sites)
    }

    private func adoptLegacyMoves() {
        guard let config = subscription else { return }
        for legacy in sourceReassignment.pendingLegacy {
            guard let origin = URL(string: legacy.origin),
                  let address = subscriptions.first(where: { documents[$0.address]?.origin == origin })?.address,
                  let site = config.sites.first(where: { $0.sourceKey == legacy.sourceKey && $0.origin(or: config.origin) == origin })
            else { continue }
            sourceReassignment.reassign(site, address: address, origin: origin,
                                        to: legacy.target,
                                        targetName: subscriptions.first { $0.address == legacy.target }?.title ?? "")
        }
    }
    /// Fetches Yingxia's own subscription while a subscription works: at once when there is no copy, else
    /// every ten minutes at most. A failed fetch keeps the last copy.
    private func refreshCloudSources(force: Bool = false) {
        guard extrasUnlocked, cloudFetch == nil else { return }
        #if DEBUG
        // [mi3s] 二开融合：上游 1.8.11 新增 QA 开关，`-qaNoCloudSources 1` 只保留 QA 订阅的源，供数结果的 UI 测试使用。
        if UserDefaults.standard.bool(forKey: "qaNoCloudSources") { return }
        #endif
        if !force, cloudDocument != nil, let fetched = cloudFetchedAt, Date.now.timeIntervalSince(fetched) < 600 { return }
        let http = http, persists = persistsChanges
        cloudFetch = Task { [weak self] in
            let result: Result<Subscription, any Error>
            do { result = .success(try await CloudSources.fetch(http: http)) } catch { result = .failure(error) }
            guard let self else { return }
            self.cloudFetch = nil
            self.cloudFetchedAt = .now
            switch result {
            case .success(let document):
                if persists, let data = try? JSONEncoder().encode(document) { try? Self.save(data, to: Self.cloudFile) }
                CloudSources.current = document
                let changed = (try? JSONEncoder().encode(document.raw)) != (try? JSONEncoder().encode(self.cloudDocument?.raw))
                self.cloudDocument = document
                if changed { self.rebuildSubscription() }
            case .failure(let error):
                Diagnostics.shared.failure("subscription", "built-in sources", error)
            }
        }
    }
    private func refreshCloudFilesSources() {
        guard let subscription, subscription.sites.filter(\.isCloudFiles) != CloudFilesSource.sites() else { return }
        rebuildSubscription()
    }
    func resolvedSite(_ site: Site, origin: URL) -> Site {
        sourceOverrides.apply(to: site, origin: origin)
    }

    /// The Watch Now source row: pinned, then built-in, then the sources page's subscription order.
    func recommendationSites(_ config: Subscription) -> [Site] {
        let stamp = currentSiteListStamp()
        if stamp == siteListStamp, let cached = recommendationCache { return cached }
        let leading = automaticSites(config)
        let pinned = leading.filter { pinnedSources.contains($0, origin: config.origin) }
        let builtIn = leading.filter { $0.isBuiltIn && !pinnedSources.contains($0, origin: config.origin) }
        let groups = sourceGroups(includeHidden: false)
        let result = SourceGroups.homeRow(pinned: pinned, builtIn: builtIn, groups: groups)
        rememberSiteLists(stamp)
        recommendationCache = result
        return result
    }

    /// The sources to show, in the viewer's own order while it is on.
    func orderedSites(_ config: Subscription) -> [Site] {
        let stamp = currentSiteListStamp()
        if stamp == siteListStamp, let cached = orderedCache { return cached }
        let sites = automaticSites(config)
        let arranged = sourceOrder.enabled ? sourceOrder.arrange(sites, origin: config.origin) : sites
        rememberSiteLists(stamp)
        orderedCache = arranged
        return arranged
    }

    // MARK: 源改派（拖到别的订阅 / 维护清单）

    /// Files one source under another subscription (dragged onto that subscription's header, or chosen
    /// from its menu), or back into its own.
    ///
    /// The move is recorded against the subscription's *address* — what the viewer added — so a
    /// refresh that lands on a new mirror keeps it. It also outlives a disabled or removed target:
    /// the record stays until the viewer removes it, and files the source again once the target is back.
    func reassignSource(_ site: Site, to address: String?) {
        // The built-in sources belong to no subscription; a move would file them under a feed that
        // does not know them, and a refresh that drops that feed would leave them in "Other Sources".
        guard !site.isBuiltIn, let config = subscription else { return }
        let origin = site.origin(or: config.origin)
        let own = entryAddress(of: site) ?? origin.absoluteString
        let target = environmentSubscriptions.first { $0.address == address }
        // A move can also name one of the viewer's own groups; the maintenance list shows its name
        // rather than the raw `group:<id>` target it is stored as.
        let targetName = target?.title ?? address.flatMap { sourceGroupBook.group(forTarget: $0)?.name } ?? ""
        sourceReassignment.reassign(site, address: own, origin: origin,
                                    to: address, targetName: targetName)
        rebuildSubscription()
    }

    /// Sets one source's route; `.auto` follows connectivity, the others pin it.
    func setRoute(_ route: SourceRoute, for site: Site) {
        guard let config = subscription else { return }
        sourceRouting.set(route, for: site, origin: site.origin(or: config.origin))
        rebuildSubscription()
    }

    /// Sets a whole subscription's default route; its sources without their own choice follow it.
    func setRoute(_ route: SourceRoute, for entry: SubscriptionEntry) {
        guard let index = index(of: entry) else { return }
        subscriptions[index].routing = route
        saveSubscriptionList()
        rebuildSubscription()
    }

    /// Puts one source back under its own subscription.
    func undoSourceMove(_ entry: Store.SourceMoveEntry) {
        sourceReassignment.remove(entry.move.id)
        rebuildSubscription()
    }

    /// Puts every moved source back at once.
    func undoAllSourceMoves() {
        sourceReassignment.removeAll()
        rebuildSubscription()
    }

    // MARK: 批量测速

    /// A bulk probe in flight: how many sources are done, and how many there are.
    struct ProbeRun: Equatable { var done: Int; var total: Int }

    /// What the Sources page shows while a probe runs, and the way to stop it.
    private(set) var probeRun: ProbeRun?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    /// Identifies the run in flight, so a stopped run finishing late cannot clear the next one's
    /// progress or its handle.
    @ObservationIgnored private var probeToken = UUID()

    /// One source to measure: everything a `CatalogClient` needs, copied so the work can leave the
    /// main actor.
    private struct ProbeTarget: Sendable {
        let site: Site
        let origin: URL
        let jarURL: URL?
    }

    private struct ProbeRow: Sendable {
        let flag: String
        let result: SourceProbeResult
    }

    private struct ProbeBatch: Sendable {
        let sourceKey: String
        let videoID: String
        let rows: [ProbeRow]
    }

    /// Starts measuring every listed source — built-in ones included.
    ///
    /// The sweep runs off the main actor, a few sources at a time, and each source is given a
    /// deadline. It used to run on the main actor, one source after another, waiting for a plugin to
    /// compile and a dead host to time out at every step: the app looked frozen because it was. The
    /// reader can stop it, and the progress is visible while it runs.
    func startProbingAllSources() {
        guard let config = subscription else { return }
        runProbe(probeTargets(config))
    }

    /// Measures just these sources — the ones in one group, or the ones the reader ticked. A full
    /// sweep of 350 sources takes minutes; re-checking the twenty that survived is the common case.
    func startProbing(_ sites: [Site]) {
        guard let config = subscription else { return }
        var seen = Set<String>()
        let targets = sites
            .filter { seen.insert($0.id).inserted }
            .map { ProbeTarget(site: $0, origin: $0.origin(or: config.origin), jarURL: config.spiderURL) }
        runProbe(targets)
    }

    private func runProbe(_ targets: [ProbeTarget]) {
        guard probeTask == nil, !targets.isEmpty else { return }
        probeRun = ProbeRun(done: 0, total: targets.count)
        let token = UUID()
        probeToken = token
        probeTask = Task { [weak self] in
            var done = 0
            for await batch in Self.probeBatches(targets) {
                if !batch.videoID.isEmpty {
                    SourceProbeStore.shared.record(batch.rows.map { ($0.result, $0.flag) },
                                                   sourceKey: batch.sourceKey, videoID: batch.videoID)
                }
                done += 1
                guard self?.probeToken == token else { return }
                self?.probeRun = ProbeRun(done: done, total: targets.count)
                if Task.isCancelled { break }
            }
            guard self?.probeToken == token else { return }
            self?.probeRun = nil
            self?.probeTask = nil
        }
    }

    /// Stops a running sweep. Results already measured stay.
    func cancelProbingAllSources() {
        probeTask?.cancel()
        probeTask = nil
        probeRun = nil
        probeToken = UUID()
    }

    /// Every source the page lists, once each: pinned, built-in, then each subscription's, in the
    /// order they are drawn. Built-in sources are as much a part of "probe everything" as the rest,
    /// and used to be left out because the sweep only walked the automatic list.
    private func probeTargets(_ config: Subscription) -> [ProbeTarget] {
        var seen = Set<String>()
        var targets: [ProbeTarget] = []
        for group in sourceGroups(includeHidden: false) where group.kind != .hidden {
            for site in group.sites where seen.insert(site.id).inserted {
                targets.append(ProbeTarget(site: site, origin: config.origin, jarURL: config.spiderURL))
            }
        }
        return targets
    }

    /// The sweep, as a stream of per-source batches. The producer runs detached, so neither a slow
    /// host nor a plugin's first compile can hold the main actor.
    private nonisolated static func probeBatches(_ targets: [ProbeTarget]) -> AsyncStream<ProbeBatch> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                await withTaskGroup(of: ProbeBatch?.self) { group in
                    // Two sources at a time: enough to keep the network busy without a burst of
                    // plugin compiles competing for the same device.
                    let width = 2
                    var next = 0
                    func launch() -> Bool {
                        guard next < targets.count, !Task.isCancelled else { return false }
                        let target = targets[next]
                        next += 1
                        group.addTask { await probe(target) }
                        return true
                    }
                    for _ in 0..<width { if !launch() { break } }
                    for await batch in group {
                        if let batch { continuation.yield(batch) }
                        if !launch() { continue }
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One source: its home page for a representative video, then that video's lines.
    private nonisolated static func probe(_ target: ProbeTarget) async -> ProbeBatch {
        let client = CatalogClient(site: target.site, origin: target.origin, jarURL: target.jarURL)
        let empty = ProbeBatch(sourceKey: target.site.sourceKey, videoID: "", rows: [])
        guard let page = await withDeadline(seconds: 25, { try await client.home() }),
              let video = page.videos.first else { return empty }
        let lines = video.episodes.filter { !$0.flag.isEmpty && URL(string: $0.address) != nil }
        var rows: [ProbeRow] = []
        await withTaskGroup(of: ProbeRow?.self) { group in
            var next = 0
            func launch() -> Bool {
                guard next < lines.count, !Task.isCancelled else { return false }
                let episode = lines[next]
                next += 1
                group.addTask {
                    guard let url = URL(string: episode.address) else { return nil }
                    return ProbeRow(flag: episode.flag, result: await SourceProbeRunner.probe(url: url))
                }
                return true
            }
            for _ in 0..<4 { if !launch() { break } }
            for await row in group {
                if let row { rows.append(row) }
                if !launch() { continue }
            }
        }
        return ProbeBatch(sourceKey: target.site.sourceKey, videoID: video.id, rows: rows)
    }

    /// Runs `operation`, giving up after `seconds`. The result is nil on a timeout or a throw, so a
    /// host that never answers cannot hold a whole sweep.
    ///
    /// The operation runs in its own task rather than in a task group. A group does not return until
    /// every child has finished, so `group.next()` returning the sleeper's nil still left the caller
    /// waiting on the original task: a plugin call that ignores cancellation held the sweep open past
    /// its own deadline, which is the opposite of what a deadline is for. Whoever finishes first
    /// claims the continuation; the loser is cancelled and forgotten.
    private nonisolated static func withDeadline<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async -> T? {
        let claim = DeadlineClaim()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let work = Task {
                let value = try? await operation()
                if claim.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if claim.claim() {
                    work.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// After a full probe, applies one fix to every line that came back unreachable: route it
    /// through the first custom proxy, force it direct, or hide it from the picker.
    ///
    /// The work comes from the probe store, not from the feeds. Asking each source for its home page
    /// to rediscover which lines are dead meant one request per source, covered only the first video
    /// in each, and took long enough to look frozen. The sweep has already measured every video it
    /// touched, and a route is stored per (origin, source, line) — no episode is needed to fix one.
    ///
    /// The origin is the source's own, not the merged document's: a source that came from a second
    /// subscription is read back with its own origin, so writing under the first one silently fixed
    /// nothing for it. `notice` reports what actually happened, including the honest zero.
    @discardableResult
    func batchFixUnreachableLines(_ fix: LineFix) async -> Int {
        guard let config = subscription else { return 0 }
        let rows = SourceProbeStore.shared.unreadableLines()
        guard !rows.isEmpty else {
            notice = L10n.text("No dead lines have been measured yet. Run Probe All first — this uses those readings rather than asking every source again.")
            return 0
        }
        var proxy: CustomProxyEndpoint?
        if case .proxy = fix {
            guard let first = customProxy.store.endpoints.first else {
                notice = L10n.text("No custom proxy is set up. Add one under Playback → Custom Proxy, or force the lines direct instead.")
                return 0
            }
            proxy = first
        }

        // One lookup for the whole batch: the origin a source belongs to is what the player reads
        // back when it picks a line, so it has to be the same value on both sides.
        var origins: [String: URL] = [:]
        for site in config.sites where origins[site.sourceKey] == nil {
            origins[site.sourceKey] = site.origin(or: config.origin)
        }

        var touched = 0
        for row in rows {
            guard !Task.isCancelled else { break }
            let origin = origins[row.sourceKey] ?? config.origin
            switch fix {
            case .proxy:
                guard let proxy else { continue }
                lineSettings.setRoute(.proxy(proxy.id), origin: origin, sourceKey: row.sourceKey, flag: row.lineFlag)
            case .direct:
                lineSettings.setRoute(.direct, origin: origin, sourceKey: row.sourceKey, flag: row.lineFlag)
            case .hide:
                lineSettings.setHidden(true, origin: origin, sourceKey: row.sourceKey, flag: row.lineFlag)
            }
            touched += 1
        }

        // Counted rather than pluralised: "1 dead lines" is the kind of detail that makes a fix look
        // unfinished, and a bare number after a colon reads correctly for one and for many.
        switch fix {
        case .proxy: notice = L10n.text("Dead lines routed through the proxy: %lld", touched)
        case .direct: notice = L10n.text("Dead lines set to play direct: %lld", touched)
        case .hide: notice = L10n.text("Dead lines hidden from the episode list: %lld", touched)
        }
        return touched
    }

    enum LineFix { case proxy, direct, hide }

    /// The order the app picks: built-in sources, then `SourceStrategy`'s, with pinned sources first. Hidden sources stay out.
    func automaticSites(_ config: Subscription) -> [Site] {
        let stamp = currentSiteListStamp()
        if stamp == siteListStamp, let cached = automaticCache { return cached }
        let sites = SourceLists.browsable(config.sites, jarURL: config.spiderURL) {
            hiddenSources.contains($0, origin: config.origin) || !vault.permits(site: $0, fallback: config.origin)
        }
        let arranged = pinnedSources.arrange(sites.filter(\.isBuiltIn) + sites.filter { !$0.isBuiltIn }, origin: config.origin)
        rememberSiteLists(stamp)
        automaticCache = arranged
        return arranged
    }

    /// Drops cached rows when their inputs changed. Each list fills itself, so a caller that only needs one does not build the others.
    private func rememberSiteLists(_ stamp: String) {
        guard stamp != siteListStamp else { return }
        siteListStamp = stamp
        automaticCache = nil
        orderedCache = nil
        recommendationCache = nil
        groupsCache = [:]
    }

    /// The sources page's sections: pinned, built-in, then one per subscription.
    func sourceGroups(includeHidden: Bool) -> [SourceGroup] {
        let stamp = currentSiteListStamp()
        if stamp == siteListStamp, let cached = groupsCache[includeHidden] { return cached }
        guard let config = subscription else { return [] }
        let pins = pinnedSources.arrange(config.sites, origin: config.origin).filter { pinnedSources.contains($0, origin: config.origin) }
        var groups = SourceGroups.make(entries: environmentSubscriptions, documents: documents, builtIns: config.sites.filter(\.isBuiltIn), builtInOrigin: config.origin, mergedSites: config.sites, pinOrder: pins, userHidden: { hiddenSources.contains($0, origin: config.origin) }, includeHidden: includeHidden, jarURL: config.spiderURL, privacyHidden: { !vault.permits(site: $0, fallback: config.origin) }, reassign: { site, address in
            // Address first: the subscription keeps the address the viewer added, so a refresh that
            // lands on a new mirror keeps every move. The origin is only for older records.
            sourceReassignment.destination(address: address, sourceKey: site.sourceKey, origin: site.provenance?.origin)
        }, customGroups: sourceGroupBook.groups)
        // The viewer's own order, while it is on, orders the sources inside each group too.
        if sourceOrder.enabled { groups = sourceOrder.arrange(groups, origin: config.origin) }
        rememberSiteLists(stamp)
        groupsCache[includeHidden] = groups
        return groups
    }

    func catalogChannel(_ resolved: Channel, video: Video, episode: Episode, client: CatalogClient,
                        resumePosition: Double? = nil) -> Channel {
        let channel = episodeChannel(resolved, video: video, episode: episode, client: client, resumePosition: resumePosition)
        remember(video, client: client.with(parses: subscription?.parseServices ?? client.parses), for: channel)
        return channel
    }

    /// The channel that plays `episode`, without making its video the one playing.
    private func episodeChannel(_ resolved: Channel, video: Video, episode: Episode, client: CatalogClient,
                                resumePosition: Double? = nil) -> Channel {
        let context = PlaybackHistoryContext(origin: client.origin, site: client.site, video: video, episode: episode)
        return Channel(name: "\(video.name) · \(episode.name)", group: resolved.group, url: resolved.url,
                       logo: resolved.logo, headers: resolved.headers, skipScope: context.id,
                       historyContext: context, resumePosition: resumePosition, subtitles: resolved.subtitles)
    }

    /// The video and its episode list, for the player's episode buttons and the next episode.
    private func remember(_ video: Video, client: CatalogClient, for channel: Channel) {
        guard let context = channel.historyContext else { return }
        if let data = try? JSONEncoder().encode(video) {
            // Cache the catalog off the main actor: writing the episode list to disk (and MediaCache's
            // index persist) is synchronous I/O that would stall the player while a video is loading.
            let scope = context.id
            Task.detached(priority: .utility) {
                MediaCache.shared.store(data, for: "detail", kind: .catalog, scope: scope, ttl: 6 * 3600, ticket: MediaCache.shared.ticket())
            }
        }
        // The Episodes menu's short labels (#318): kept from the episode before on the same video, else worked out off the
        // main thread.
        let kept = playbackCatalog.flatMap { $0.video == video ? $0.labels : nil }
        playbackCatalog = PlaybackCatalog(video: video, client: client, scope: context.id, labels: kept ?? [:])
        guard kept == nil else { return }
        let episodes = video.episodes
        Task { [weak self] in
            let labels = await Task.detached(priority: .utility) { EpisodeLabels.labels(episodes) }.value
            // Still this video, though maybe the next episode by now.
            guard let self, !labels.isEmpty, self.playbackCatalog?.video == video else { return }
            self.playbackCatalog?.labels = labels
        }
    }

    /// The next episode's stream, resolved ahead so the player can queue it behind this one; nil when
    /// auto-play is off, there is no next episode, or the source can't resolve it now.
    func upcomingEpisode(after channel: Channel) async -> Channel? {
        // Only while `channel` still plays: once the queue moves on, this was asked about the one before.
        if CloudFiles.isFile(channel.url) { return autoPlayNext && playing == channel ? nextFile(after: channel) : nil }
        // Do not prefetch the next episode of a source the vault now hides: resolving it would query a
        // hidden source even though `advance` would refuse to play the result.
        guard mayContinuePlaying(channel) else { return nil }
        guard autoPlayNext, let catalog = catalog(for: channel), let next = nextEpisode(after: channel) else { return nil }
        do {
            let resolved = try await catalog.client.playback(next)
            guard !Task.isCancelled, playing == channel else { return nil }
            return episodeChannel(resolved, video: catalog.video, episode: next, client: catalog.client)
        } catch {
            if !(error is CancellationError) { Diagnostics.shared.failure("catalog", "upcoming episode \(catalog.client.reportContext) flag=\(next.flag)", error) }
            return nil
        }
    }

    /// The queued episode started playing by itself: it becomes the one playing, as if it had been chosen.
    func advance(to next: Channel, from channel: Channel) {
        if CloudFiles.isFile(next.url), playing == channel { playing = next; return }
        // The unlock may have lapsed while this title was on screen: stop before the next episode of a
        // now-hidden source plays on in the locked state.
        guard mayContinuePlaying(channel) else { stopForHiddenSource(); return }
        guard playing == channel, let catalog = catalog(for: channel) else { return }
        cancelEpisodeSelection()
        remember(catalog.video, client: catalog.client, for: next)
        playing = next
    }

    /// The last episode of a line just ended. Ask the same source for titles that
    /// belong with this one — a follow-up season, 红果 style — and let the end
    /// screen offer them. When the source answers nothing useful, the screen is
    /// still shown (empty) so the viewer is not dropped onto a dead player.
    func finishSeries(_ channel: Channel) {
        guard let context = channel.historyContext, let catalog = catalog(for: channel) else { return }
        // The unlock may have lapsed while the last episode was playing: no follow-up season or
        // "what next" offer for a source the vault now hides.
        guard mayContinuePlaying(channel) else { stopForHiddenSource(); return }
        let title = catalog.video.name
        let client = catalog.client
        seriesEndTask?.cancel()
        seriesEndTask = Task { [weak self] in
            guard let self else { return }
            let candidates = await self.seriesCandidates(for: catalog, client: client)
            guard !Task.isCancelled else { return }
            let ranked = SeriesSuggestionRanker.rank(
                finished: catalog.video,
                candidates: candidates,
                sourceKey: context.sourceKey,
                sourceName: context.sourceName,
                origin: context.origin
            )
            // With auto-play on and a follow-up season found, run straight on into its first
            // episode (跨季连播) instead of stopping on a recommendation screen. This is what a
            // viewer who asked for auto-play expects, and it is the only thing the floating
            // windows (mini player / PiP) can do — they have no end screen to count down on.
            if self.autoPlayNext, let nextSeason = ranked.first(where: { $0.kind == .nextSeason }) {
                self.playSeriesSuggestion(nextSeason)
                return
            }
            self.seriesEnd = SeriesEnd(channel: channel, title: title, suggestions: ranked)
            #if os(iOS)
            ExternalDisplay.shared.seriesEndChanged()
            #endif
        }
    }

    /// Titles from the same source that could follow `catalog.video`.
    /// Searches the base title (season wording stripped), which is how a series
    /// lists its other seasons on these sources. A failure is not an error the
    /// viewer needs to see: the end screen simply arrives with no rows.
    private func seriesCandidates(for catalog: PlaybackCatalog, client: CatalogClient) async -> [Video] {
        let base = SeriesTitleMatcher.split(catalog.video.name).base
        guard base.count >= 2 else { return [] }
        var found: [Video] = []
        if let page = try? await client.list(category: nil, query: base, page: 1) {
            found.append(contentsOf: page.videos)
        }
        return found
    }

    /// Series suggestions for a title that has not finished — the pause menu and the
    /// detail page both want the same rows the end screen shows.
    ///
    /// This is the read-only twin of `finishSeries`: it ranks the same candidates the
    /// same way but publishes nothing, because a paused viewer has not asked to leave
    /// and a detail page is not an ending. Cached per title so reopening the pause
    /// menu costs nothing.
    func seriesSuggestions(for catalog: PlaybackCatalog, context: (sourceKey: String, sourceName: String, origin: URL)) async -> [SeriesSuggestion] {
        let cacheKey = SeriesTitleMatcher.key(catalog.video.name)
        guard !cacheKey.isEmpty else { return [] }
        if let hit = seriesSuggestionCache[cacheKey] { return hit }
        let client = catalog.client
        let candidates = await seriesCandidates(for: catalog, client: client)
        guard !Task.isCancelled else { return [] }
        let ranked = SeriesSuggestionRanker.rank(
            finished: catalog.video,
            candidates: candidates,
            sourceKey: context.sourceKey,
            sourceName: context.sourceName,
            origin: context.origin
        )
        seriesSuggestionCache[cacheKey] = ranked
        return ranked
    }

    /// Play a suggestion straight from the pause menu or the detail page. Unlike
    /// `playSeriesSuggestion` there is no end screen to dismiss, so this only stops
    /// the pending rank task.
    func playSuggestion(_ suggestion: SeriesSuggestion) {
        seriesEndTask?.cancel(); seriesEndTask = nil
        openSeriesVideo(suggestion)
    }

    func dismissSeriesEnd() {
        seriesEndTask?.cancel(); seriesEndTask = nil
        seriesEnd = nil
        #if os(iOS)
        ExternalDisplay.shared.seriesEndChanged()
        #endif
    }

    /// Play a suggestion from the end screen: open that title on its own line.
    func playSeriesSuggestion(_ suggestion: SeriesSuggestion) {
        seriesEnd = nil
        seriesEndTask?.cancel(); seriesEndTask = nil
        openSeriesVideo(suggestion)
    }

    /// Resolves the suggestion's detail and starts its first episode.
    private func openSeriesVideo(_ suggestion: SeriesSuggestion) {
        // A recommendation plays on the same source that just finished or is paused; if that source
        // was re-hidden while its title was on screen, the follow-up must not start in the locked
        // state. This is the single choke point for every recommendation path (end screen auto-play,
        // the pause menu, the detail page).
        guard vault.permitsPlayback(sourceKey: suggestion.sourceKey, origin: suggestion.origin) else {
            error = L10n.text("This title is hidden. Unlock the Privacy Vault to watch it.")
            return
        }
        guard let config = subscription,
              let site = config.sites.first(where: {
                  $0.origin(or: config.origin) == suggestion.origin && $0.sourceKey == suggestion.sourceKey
              }) else { reportMissingFavoriteSource(); return }
        let client = CatalogClient(site: resolvedSite(site, origin: config.origin), origin: config.origin, jarURL: config.spiderURL).applying(config)
        let known = suggestion.video
        seriesEndTask = Task { [weak self] in
            guard let self else { return }
            let video = (try? await client.detail(known.id))?.keepingPoster(known.poster, headers: known.posterHeaders) ?? known
            guard !Task.isCancelled, let first = video.episodes.first else { return }
            do {
                let channel = try await client.playback(first)
                self.remember(video, client: client, for: channel)
                self.playing = channel
            } catch {
                Diagnostics.shared.failure("catalog", "series suggestion \(client.reportContext) id=\(video.id)", error)
                self.error = error.localizedDescription
            }
        }
    }

    func selectEpisode(_ episode: Episode, from channel: Channel, success: (() -> Void)? = nil, failed: ((String) -> Void)? = nil) {
        // Re-check at the moment of advance: an unlock lapsed mid-title must not let the Next button
        // (or the auto-advance that shares this path) carry a hidden source into the locked state.
        guard mayContinuePlaying(channel) else { stopForHiddenSource(); failed?(L10n.text("This title is hidden. Unlock the Privacy Vault to watch it.")); return }
        guard playing == channel, let catalog = catalog(for: channel),
              catalog.video.episodes.contains(episode) else { return }
        cancelEpisodeSelection()
        let request = episodeRequest
        resolvingEpisode = episode; episodeError = nil
        episodeTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.episodeRequest == request { self.resolvingEpisode = nil; self.episodeTask = nil } }
            do {
                let resolved = try await catalog.client.playback(episode)
                guard !Task.isCancelled, self.episodeRequest == request, self.playing == channel else { return }
                self.playing = self.catalogChannel(resolved, video: catalog.video, episode: episode, client: catalog.client)
                success?()
            } catch {
                guard !Task.isCancelled, self.episodeRequest == request, self.playing == channel else { return }
                Diagnostics.shared.failure("catalog", "episode \(catalog.client.reportContext) flag=\(episode.flag)", error)
                self.episodeError = error.localizedDescription
                failed?(error.localizedDescription)
            }
        }
    }

    func cancelEpisodeSelection() {
        episodeRequest = UUID()
        episodeTask?.cancel(); episodeTask = nil; resolvingEpisode = nil
    }

    /// Resumes a watched title. Choosing another title while one is still being prepared switches
    /// to it: the earlier request is cancelled, which also stops its plugin call.
    func resume(_ entry: PlaybackHistoryEntry) {
        guard resumingHistoryID != entry.id else { return }
        resumeTask?.cancel()
        resumingHistoryID = entry.id
        resumeTask = Task { await resumeHistory(entry) }
    }

    func cancelResume() {
        resumeTask?.cancel(); resumeTask = nil
        resumingHistoryID = nil
    }

    func resumeHistory(_ entry: PlaybackHistoryEntry) async {
        resumingHistoryID = entry.id
        defer { if resumingHistoryID == entry.id, !Task.isCancelled { resumingHistoryID = nil } }
        // The listing hides a vault-hidden source, but a row that was already on screen, a deep link,
        // or a stale card must not resume it either. This is the single choke point for every
        // "continue watching" path, so the check lives here rather than at each card.
        guard vault.permitsPlayback(sourceKey: entry.context.sourceKey, origin: entry.context.origin) else {
            error = L10n.text("This title is hidden. Unlock the Privacy Vault to watch it.")
            return
        }
        if entry.context.sourceKey == CloudFiles.sourceKey { return resumeFile(entry) }
        guard let config = subscription, let client = historyClient(entry) else {
            error = L10n.text("This history source is no longer in the current subscription. Restore that subscription to continue.")
            return
        }
        let site = client.site
        let previousPlayback = playing
        do {
            // Plugin/API sources resolve an episode again. Direct-file APIs must refresh
            // their detail first so an expiring media address never becomes a resume shortcut.
            var video = try await client.detail(entry.context.videoID, cached: site.type == 3 || site.type == 4)
            guard var episode = entry.context.episode(in: video.episodes) else {
                throw TVError.unsupported(L10n.text("The saved episode is no longer available from this source. Choose an episode again."))
            }
            let channel: Channel
            do { channel = try await client.playback(episode) }
            catch {
                try Task.checkCancellation()
                video = try await client.detail(entry.context.videoID)
                guard let refreshed = entry.context.episode(in: video.episodes) else { throw error }
                episode = refreshed
                channel = try await client.playback(refreshed)
            }
            guard !Task.isCancelled else { return }
            // Both races are benign, but silent: the viewer chose something else, or the subscription switched
            // while the episode was resolving. Say so instead of doing nothing.
            guard playing == previousPlayback else {
                notice = L10n.text("Playback moved on, so the saved title was not resumed.")
                return
            }
            guard subscription?.origin == config.origin else {
                notice = L10n.text("The subscription changed, so the saved title was not resumed.")
                return
            }
            // A source whose details carry no poster keeps the one saved with the entry.
            playing = catalogChannel(channel, video: video.keepingPoster(entry.context.poster, headers: entry.context.posterHeaders),
                                     episode: episode, client: client, resumePosition: entry.resumePosition)
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { return }
            Diagnostics.shared.failure("catalog", "resume source=\(entry.context.sourceKey)", error)
            self.error = L10n.text("Unable to resume playback: %@", error.localizedDescription)
        }
    }
}

#if os(macOS)
extension Store {
    /// 1.7.7 moved the Mac app from `com.tvbox.yingxia.mac` to `com.jo32.yingxia.mac`, which starts a
    /// new defaults domain: subscriptions, favorites and settings would look lost. Copy the old domain
    /// over once (the app isn't sandboxed, so it can read it). Files under Application Support and
    /// Caches keep their `com.tvbox.yingxia` folder and need nothing.
    static func adoptPreviousBundleDefaults(_ defaults: UserDefaults) {
        let previous = "com.tvbox.yingxia.mac", done = "adoptedDefaults." + previous
        guard Bundle.main.bundleIdentifier != previous, !defaults.bool(forKey: done) else { return }
        for (key, value) in defaults.persistentDomain(forName: previous) ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: done)
    }
}
#endif

/// How this build reaches people. App Store and TestFlight builds are archived with
/// `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) APPSTORE'`; direct downloads and sideloaded
/// builds leave it out. `-qaAppStore 1` makes a debug build act as one.
enum Distribution {
    static var isAppStore: Bool {
        #if APPSTORE
        return true
        #elseif DEBUG
        return UserDefaults.standard.bool(forKey: "qaAppStore")
        #else
        return false
        #endif
    }

    /// An App Store build installed from TestFlight, which leaves a sandbox receipt. A build promoted to the
    /// App Store gets a production receipt, so it stops sending people to TestFlight. `-qaTestFlight 1` in debug builds.
    static let isTestFlight: Bool = {
        #if APPSTORE
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #elseif DEBUG
        return UserDefaults.standard.bool(forKey: "qaTestFlight")
        #else
        return false
        #endif
    }()
}

// MARK: Cloud Files

/// A Cloud Files folder being played through: its files of the kind chosen, in order.
struct CloudFilesFolder {
    let drive: CloudFilesDrive
    let id: String
    let name: String
    let files: [CloudFile]
    /// 上游 #576：文件夹里自带的字幕文件与压缩包，供每个视频旁边的字幕菜单使用。
    var subtitles: [ExternalSubtitle] = []
}

extension Store {
    /// Plays a file from Cloud Files, where it was left if it was being watched; the folder's other
    /// files follow it.
    func playFile(_ file: CloudFile, in folder: CloudFilesFolder) {
        let channel = CloudFiles.channel(file, in: folder.drive, folder: folder.id, folderName: folder.name, subtitles: folder.subtitles)
        let saved = playbackHistory.entries(in: activeEnvironmentID).first { $0.id == channel.historyContext?.id && $0.context.episodeID == file.id && !$0.completed }
        filesFolder = folder
        playing = saved.map { CloudFiles.channel(file, in: folder.drive, folder: folder.id, folderName: folder.name, resumePosition: $0.resumePosition, subtitles: folder.subtitles) } ?? channel
    }

    func nextFile(after channel: Channel) -> Channel? { file(1, from: channel) }
    func previousFile(before channel: Channel) -> Channel? { file(-1, from: channel) }

    /// The file `offset` places from the playing one in its folder, for the player's Previous and Next.
    private func file(_ offset: Int, from channel: Channel) -> Channel? {
        guard let context = channel.historyContext, context.sourceKey == CloudFiles.sourceKey, let folder = filesFolder,
              folder.drive.key == context.episodeFlag, folder.id == context.videoID,
              let index = folder.files.firstIndex(where: { $0.id == context.episodeID }),
              folder.files.indices.contains(index + offset) else { return nil }
        return CloudFiles.channel(folder.files[index + offset], in: folder.drive, folder: folder.id, folderName: folder.name)
    }

    /// Continue Watching on a Cloud Files folder: the file plays at once, and the folder is listed
    /// again meanwhile so the files after it still follow.
    fileprivate func resumeFile(_ entry: PlaybackHistoryEntry) {
        let context = entry.context
        guard let drive = CloudFiles.drive(key: context.episodeFlag) else {
            error = L10n.text("This file's drive is no longer in Cloud Files.")
            return
        }
        filesFolder = nil
        let channel = CloudFiles.channel(context, resumePosition: entry.resumePosition)
        playing = channel
        Task { [weak self] in
            guard let files = try? await CloudFiles.list(drive, folder: context.videoID), let self, self.playing == channel else { return }
            let kind = CloudFile.kind(of: context.episodeName)
            self.filesFolder = CloudFilesFolder(drive: drive, id: context.videoID, name: context.videoName,
                                                files: files.filter { $0.kind == kind && drive.plays($0) })
        }
    }
}

struct PlaybackCatalog {
    let video: Video
    let client: CatalogClient
    let scope: String
    /// Short labels (第1集) for lines whose episode names are file names, by episode id.
    var labels: [Episode.ID: String] = [:]
    /// 上游 #620：从文件名读出的清晰度与体积（4K · 5.2G），显示在选集格下面，按集 id 索引。
    var details: [Episode.ID: String] = [:]
    var playlist: EpisodePlaylist { EpisodePlaylist(video.episodes) }
}

/// A self-contained configuration file the viewer exports to a file (or shares) and imports later,
/// on this device or another. It carries the subscription list with each address's parsed content
/// snapshot, so importing it restores the sources even offline, and — because `importConfig` merges
/// by address — re-importing the same file never duplicates or overwrites what is already there.
struct SubscriptionConfig: Codable, Sendable {
    static let format = "mi3s-config"
    /// 旧版本（映匣时期）导出的格式名，兼容读取。
    static let legacyFormats = ["yingxia-config"]
    static let version = 1
    var format: String
    var version: Int
    var exportedAt: Date
    /// The subscriptions in list order, each with its last good copy.
    var subscriptions: [SyncedSubscription]

    init(subscriptions: [SyncedSubscription], exportedAt: Date = Date()) {
        self.format = Self.format; self.version = Self.version; self.exportedAt = exportedAt
        self.subscriptions = subscriptions
    }

    var isValid: Bool { (format == Self.format || Self.legacyFormats.contains(format)) && version == Self.version }

    static func decode(_ data: Data) -> SubscriptionConfig? {
        try? JSONDecoder().decode(SubscriptionConfig.self, from: data)
    }
}

/// A subscription as iCloud sync keeps it: the entry and its place in the list.
struct SyncedSubscription: Codable, Equatable, Sendable {
    var entry: SubscriptionEntry
    var rank: Int
    /// The subscription's parsed content, so a fresh install restores its sources without re-fetching.
    var document: Subscription?

    /// Equality ignores the document cache: it only decides whether the subscription list changed.
    static func == (lhs: SyncedSubscription, rhs: SyncedSubscription) -> Bool {
        lhs.entry == rhs.entry && lhs.rank == rhs.rank
    }
}


/// Lets one of two racing tasks answer a continuation, never both.
private final class DeadlineClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    /// True for the first caller only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !taken else { return false }
        taken = true
        return true
    }
}
