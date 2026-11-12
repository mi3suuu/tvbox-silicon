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
    /// 用户**真删**掉的子源。与 `hiddenSources` 一起写：那个负责「不出现在列表里」，
    /// 这个负责「不出现在已隐藏里」—— 只有前者的话，删掉的源会以「已隐藏」的形式
    /// 又冒出来一次，用户会以为删除没生效。
    let deletedSources: DeletedSources
    /// 谁参与搜索（源 / 分组 / 订阅三层）。与 `hiddenSources` 正交：那个让源**看不见**，
    /// 这个让它**看得见但不搜**（见 `SearchScope` 头部）。
    let searchScope: SearchScope
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
    private static let resourceRankingBaseKey = "resourceRanking"
    /// 资源排序是用户手选的**偏好**，按环境分键：默认环境用原 key（升级不丢），其余 `<base>.<uuid>`。
    private var resourceRankingKey: String { environments.scopedKey(Self.resourceRankingBaseKey) }
    /// 当前内存里这份 `resourceRanking` 是从哪个环境的 key 读出来的。
    ///
    /// `saveVault()` 会写 `resourceRankingKey`，而那个 key 跟着 `environments.activeID` 走。
    /// 三条切换路径都是「先 activate 再 saveVault」：那一刻 activeID 已经是新环境，于是
    /// **上一个环境的排序被写进了新环境的 key**（新环境本该是一张白纸），删除时还会覆盖
    /// 回落到默认环境的那份。存住归属环境，`saveVault` 只写回它自己的 key 就堵住了。
    @ObservationIgnored private var resourceRankingEnvironmentID: UUID?
    /// `init` 里用的静态版本（那时 `self` 还没就绪）。与上面的实例版口径必须一致。
    private static func resourceRankingKey(_ environments: Environments) -> String {
        environments.scopedKey(resourceRankingBaseKey)
    }
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
        // 写回**这份值所属的环境**，不是「此刻屏幕上的环境」——两者在切换的瞬间并不相同。
        if let blob = try? JSONEncoder().encode(resourceRanking) {
            let owner = resourceRankingEnvironmentID ?? environments.activeID
            playbackDefaults.set(blob, forKey: EnvironmentScopedKey.key(Self.resourceRankingBaseKey,
                                                                       environment: owner,
                                                                       default: environments.defaultID))
        }
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

    /// [mi3s] 二开：把所有「按环境分键」的偏好 store 指向 `environments` 当前环境，并重读各自那一份。
    ///
    /// 环境隔离的第一版只覆盖了带 `environmentID` 字段的数据。置顶 / 隐藏 / 源排序 / 源改派 /
    /// 自定义分组都是**偏好**，没有记录可打戳，key 里只有 `origin + sourceKey` 或纯 id —— 于是
    /// 切环境后，上一个环境的置顶行、隐藏源、排序、分组照样作用在新环境上，这就是「点播源里还
    /// 残留着之前环境的东西」的来路。
    ///
    /// 切换与删除都只走这一个入口：只改一部分 store 就是「有的串台有的不串」的下一个 bug。
    func applyEnvironmentToPreferenceStores(_ environments: Environments) {
        Self.applyEnvironment(environments, pinned: pinnedSources, hidden: hiddenSources,
                              deleted: deletedSources,
                              order: sourceOrder, reassignment: sourceReassignment,
                              groups: sourceGroupBook, overrides: sourceOverrides,
                              lines: lineSettings, routing: sourceRouting, search: searchScope)
        // 资源排序是 Store 上的一个值而不是 store 对象，静态方法拿不到实例，只能在这里重读。
        // key 已经跟着 environments 走（`resourceRankingKey`）。
        if let blob = playbackDefaults.data(forKey: resourceRankingKey),
           let decoded = try? JSONDecoder().decode(ResourceRanking.self, from: blob) {
            resourceRanking = decoded
        } else {
            resourceRanking = .standard
        }
        // 重读之后，内存里这份值就属于新环境了；`saveVault` 依此写回正确的 key。
        resourceRankingEnvironmentID = environments.activeID
    }

    /// The work behind `applyEnvironmentToPreferenceStores`, callable from `init` (where `self` is not
    /// usable yet) as well as from the UI's switch, create and delete.
    static func applyEnvironment(_ environments: Environments,
                                 pinned: PinnedSources, hidden: HiddenSources,
                                 deleted: DeletedSources,
                                 order: SourceOrder, reassignment: SourceReassignment,
                                 groups: SourceGroupBook, overrides: SourceOverrides,
                                 lines: LineSettings, routing: SourceRouting,
                                 search: SearchScope) {
        let defaultID = environments.defaultID
        let activeID = environments.activeID
        // 先写归属，再让每个 store 按新 key 重读：顺序反过来就会读到上一个环境的那份。
        pinned.defaultEnvironmentID = defaultID; pinned.environmentID = activeID
        hidden.defaultEnvironmentID = defaultID; hidden.environmentID = activeID
        deleted.defaultEnvironmentID = defaultID; deleted.environmentID = activeID
        order.defaultEnvironmentID = defaultID; order.environmentID = activeID
        reassignment.defaultEnvironmentID = defaultID; reassignment.environmentID = activeID
        groups.defaultEnvironmentID = defaultID; groups.environmentID = activeID
        // 源改名 / 改 API、线路开关、源路由同样是偏好：不分环境的话，A 环境改的名字与线路
        // 在 B 环境照样生效（同一份订阅两处 `origin + sourceKey` 完全一致）。
        overrides.defaultEnvironmentID = defaultID; overrides.environmentID = activeID
        lines.defaultEnvironmentID = defaultID; lines.environmentID = activeID
        routing.defaultEnvironmentID = defaultID; routing.environmentID = activeID
        // 「谁参与搜索」也是偏好：不分环境的话，A 环境关掉的源在 B 里也被静默跳过，
        // 表现是「切了个环境，搜索结果少了一半」。
        search.defaultEnvironmentID = defaultID; search.environmentID = activeID
        pinned.reloadForEnvironment()
        hidden.reloadForEnvironment()
        deleted.reloadForEnvironment()
        order.reloadForEnvironment()
        reassignment.reloadForEnvironment()
        groups.reloadForEnvironment()
        overrides.reloadForEnvironment()
        lines.reloadForEnvironment()
        routing.reloadForEnvironment()
        search.reloadForEnvironment()
    }

    /// 删掉一个环境时，把它名下的偏好 key 一并清掉。数据侧的删除由调用方各自负责
    /// （历史 / 收藏 / 订阅 / 下载），这里只管偏好。
    func deletePreferences(of environment: UUID) {
        let defaults = playbackDefaults
        let defaultID = environments.defaultID
        PinnedSources.delete(environment: environment, defaults: defaults, default: defaultID)
        HiddenSources.delete(environment: environment, defaults: defaults, default: defaultID)
        DeletedSources.delete(environment: environment, defaults: defaults, default: defaultID)
        SourceOrder.delete(environment: environment, defaults: defaults, default: defaultID)
        SourceReassignment.delete(environment: environment, defaults: defaults, default: defaultID)
        SourceGroupBook.delete(environment: environment, defaults: defaults, default: defaultID)
        SourceOverrides.delete(environment: environment, defaults: defaults, default: defaultID)
        LineSettings.delete(environment: environment, defaults: defaults, default: defaultID)
        SourceRouting.delete(environment: environment, defaults: defaults, default: defaultID)
        SearchScope.delete(environment: environment, defaults: defaults, default: defaultID)
        // 排序也按环境分键，删环境要连它那份一起清，否则孤儿 key 永久残留。
        if environment != defaultID {
            defaults.removeObject(forKey: EnvironmentScopedKey.key(Self.resourceRankingBaseKey,
                                                                  environment: environment, default: defaultID))
        }
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
    /// While true, `reassignSource` records the move but does not rebuild the merged list. Only
    /// `performBatch` sets it: a batch of moves must rebuild once at the end, not once per source.
    /// Nothing stored depends on it — the rebuild is a cache refresh, so a suppressed batch ends in
    /// exactly the state the same moves made one at a time would reach.
    @ObservationIgnored var suppressRebuild = false
    /// 上一轮扫描测到的源，收尾整理据此只动测过的那批。`@ObservationIgnored`：它只是收尾用的
    /// 临时清单，不是页面要观察的状态。
    @ObservationIgnored var probeSwept: [Site]?
    /// 收尾整理做了什么的一句话，展示给用户（「已归入可连 41 / 不通 12」）。
    var lastTidyNote: String?
    /// 一轮扫描结束后自动做什么（重排 / 归组 / 改路由）。默认只重排 —— 见 `PostSweepTidy`。
    /// 存在主类里是因为 `@Observable` 的存储属性不能放 extension。
    var postSweepTidy: PostSweepTidy {
        get {
            guard let raw = playbackDefaults.object(forKey: "postSweepTidy") as? Int else {
                return .standard
            }
            return PostSweepTidy(rawValue: raw)
        }
        set { playbackDefaults.set(newValue.rawValue, forKey: "postSweepTidy") }
    }
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
    ///
    /// ⛔ 现在是**坞的投影**，不再是一个独立布尔。
    ///
    /// 原来它是「小窗现在画不画」的唯一真源，配一个 `store.playing` 的单值 ——
    /// 那套结构只能表达「一集在坞里」。用户这次要求坞里能同时挂多个、且新开的不
    /// 影响已有的，于是真源换成 `videoTasks.tasks`：**坞非空 = 小窗在画**。
    ///
    /// 保留这个名字有三个理由：① `PlaybackExit` 的 `miniIntent` / `miniPlayerOn`
    /// 仍按它读；② 一律改成读坞会让两份状态在同一帧里不同步（写入是同步的，读到的是
    /// 上一次计算的值）；③ 它现在不可能与坞不一致 —— 它就是坞的读法。
    ///
    /// 写入语义：`= false` 表示「收掉整个坞」（登出、用户关掉所有小窗）。
    /// ⚠️ 所以**不要**在「回到某个观看页」时写它 —— 那会把别的正在看的小窗一起杀掉。
    /// 回到某一页只该摘掉那一页自己的任务（`VideoTaskCenter.take` 已经负责）。
    var miniPlayerActive: Bool {
        get { videoTasks.hasTasks }
        set { if !newValue { videoTasks.removeAll() } }
    }
    /// [mi3s] 二开：**多任务播放的坞**（见 `VideoTasks.swift`）。
    ///
    /// 与 `playing` / `miniPlayerActive` 的分工必须分清，否则会互相踩：
    ///   · `playing` 与 `playbackSession(for:)` 是**前台**那一集（观看页 / 全屏播放器），只能有一个；
    ///   · 本对象是**坞里**的那些，可以同时有好几个，各自一个 `PlaybackSession`。
    ///
    /// 一集要么在前台、要么在坞里，永不两边同时存在。放在主类是因为 Swift 的 extension
    /// 不能加存储属性（项目铁律第一条）。
    let videoTasks = VideoTaskCenter()
    /// 坞里最近一次「回到选集页」请求要压的那一页。
    ///
    /// 与 `pendingRoute` 同一套机制：坞是挂在 `RootView` 上的全局浮层，不在任何分区的
    /// `NavigationStack` 里，拿不到那个分区的 `openRoute`，只能置一个请求由栈接住。
    var pendingTaskRoute: Route?

    /// Mac 侧栏在漫画阅读器占满窗口时收起。
    ///
    /// `MangaReaderView` 在 `onAppear` / `onDisappear` 里成对写它（`150`/`151` 行）。上游
    /// `c8578eb` 给 Store 加过这个成员，我们这份 Store 里没有 —— macOS 因此报
    /// 「value of type 'Store' has no member 'hidesSidebar'」，漫画阅读器的「阅读时折叠侧栏」
    /// 整段失效。它只是一个布尔，放在主类里是因为 Swift extension 不能加存储属性。
    var hidesSidebar = false

    var playing: Channel? {
        // An episode of a listening source (audiobooks, radio, songs) plays in the music player instead (#289).
        didSet {
            if let channel = playing, let queue = listeningQueue(for: channel) { playing = nil; listen(queue, from: channel); return }
            // ⛔ 新起播放时的「载体声明」—— 但**不能无条件写**。
            //
            // 背景：`RootView` 的弹层判据是 `(playsInWatchPage || !presentingPlayer)`，
            // 而 `presentingPlayer` 在页面主动写它之前一直是 false。于是「从设置页的 QA
            // 深链起播」这类路径：弹层被判 nil（页面不出来），同时退场裁决器看到
            // 「没有任何可见载体」，宽限窗一过就把播放停掉。
            //
            // ⚠️ 但也不能一律置 true：观看页（`VideoDetailView`）里 `store.playing = …`
            // 是在**它自己**的上下文里赋值的，而 `watchPageScopes` 由 `onAppear` 维护 ——
            // 页面刚推入、`onAppear` 还没跑的那一帧，`playsInWatchPage` 会是 false。
            // 那种时刻置 true 就会把全屏播放器盖到观看页上面，正是要避免的事。
            //
            // 所以只在**明确不属于任何观看页作用域**时才声明：
            // 观看页自己会在 `onAppear` 里把 scope 加进去，之后 `playsInWatchPage` 为真，
            // 这条分支自然不再触发。而「scope 还没登记」的那一帧，用 `watchPageScopes`
            // 的非空与否判断并不可靠 —— 所以这里宁可**不写**，把声明留给调用方：
            // `QALaunch`、`Store.play(_:)`、跨源换源这些「不在页面里起播」的路径会显式声明。
            if playing != nil, presentingPlayer == false,
               !playsInWatchPage(playing), !isWatchPageMounted {
                presentingPlayer = true
            }
            // The session playing survives an iPhone Duo fold/unfold. It is dropped when playback stops, or when
            // a different channel starts playing.
            //
            // ⛔ 这里**只清前台**，不碰坞（`videoTasks`）。
            // 原来这一行写的是 `miniPlayerActive = false`，那在单任务时代等于「小窗收掉」；
            // 现在 `miniPlayerActive` 是坞的投影，写它 = 把坞里**所有**正在看的迷你播放器
            // 一起停掉。而 `playing = nil` 的常见来源是「关掉前台的这一集」、
            // 「换一集起播」—— 两者都不该波及别的任务。清坞只发生在两处：
            // 用户按卡片上的 ✕，或整个坞被显式清空（`miniPlayerActive = false`）。
            if playing == nil { activeSession = nil; activeSessionChannel = nil; presentingPlayer = false }
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
    /// 把一个**已经在播**（或刚在坞里播着）的会话交给前台，不新建。
    ///
    /// 与 `playbackSession(for:)` 的区别就是「新建」那一句：
    ///   · `playbackSession(for:)` 遇到新频道会**新建一个空会话** —— 从坞里回到选集页
    ///     若走它，画面会重新取流、从零加载，用户看到的是「点一下回到播放，进度条跳回开头」；
    ///   · 本方法只写那一对槽，`playing` 之后由调用方赋值，两边就是同一个 `AVPlayer`。
    ///
    /// 这也是坞（`VideoTaskCenter`）与前台之间唯一允许的交接口。
    func adoptSession(_ session: PlaybackSession, for channel: Channel) {
        activeSession = session
        activeSessionChannel = channel
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
    /// 观看页此刻是否**挂着**（不管它登记的是哪一个视频）。
    ///
    /// 与 `watchPageScopes` 的分工：那是「哪些视频的观看页在屏幕上」，用于判断
    /// 「这一集该在页面里播还是全屏播」；这个是「有没有任何观看页在场」，
    /// 用于回答一个更早、更粗的问题：**这次起播是不是页面内起播**。
    ///
    /// 存在的理由：`watchPageScopes` 由 `onAppear` 异步维护，页面刚推入的那一帧还是空的；
    /// 只看它会把「页面内起播」误判成「全局起播」，进而弹出全屏层盖住观看页。
    /// 这个标志由页面 `onAppear` / `onDisappear` 同步维护，不受 scope 内容影响。
    @ObservationIgnored var isWatchPageMounted = false
    var playbackCatalog: PlaybackCatalog?
    /// [mi3s] 二开：跨源换源的状态（见 `Store+CrossSource.swift`）。
    ///
    /// 两个都必须在这里而不是 extension：Swift 不能给 extension 加存储属性。
    /// 这也是本项目唯一的二开侵入点形态 —— 主类只加字段，逻辑全在 extension。
    /// 搜索结果跨「换源面板 → 详情页 → 播放页」存活，页面一重建就丢等于每次重搜。
    var crossSourceStorage = CrossSourceState()
    /// 换源时的在飞任务；换一次就取消上一次，避免连点两下起两条流。
    @ObservationIgnored var crossSourceSwitchTask: Task<Void, Never>?
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
    /// Which group each source is listed in, by `Site.id`, for search's group priority. Built from the
    /// same cached grouping the page draws, so it cannot disagree with what the viewer sees.
    @ObservationIgnored private var groupOfSiteCache: [String: String]?
    /// What the cached rows were built from: the merged subscription, which subscriptions are on, and the viewer's pins, hides, and order.
    ///
    /// `environments.activeID` is in here on purpose. Switching environments changes what the rows
    /// should be, but two environments can agree on every other field — a fresh one has no pins, no
    /// hides, no order, and (once the same subscription is copied to it) the same merged sites — so
    /// without the environment id the stamp would match and the Sources page would keep drawing the
    /// **previous** environment's cached rows. That is the "点播源里还残留着之前环境的东西" symptom
    /// arriving by a path the per-store key partition cannot fix.
    private func currentSiteListStamp() -> String {
        let imported = subscription?.importedAt.timeIntervalSince1970 ?? 0
        let entries = environmentSubscriptions.map { "\($0.address)=\($0.enabled)" }.joined(separator: "\n")
        // ⛔ 每一个会改变「一个源怎么显示、怎么排序、怎么取数」的 store 的 revision 都必须在这里。
        // 漏一个，改完那项设置就会静默不生效：缓存戳没变，`groupsCache` / `orderedCache` 继续发旧的
        // `Site`，要等到别的戳碰巧变化才刷新。`sourceRouting`（直连/代理要重写 api）与
        // `sourceOverrides`（改名/改 api）曾经就漏在这里，于是「改路由没反应」和「改名只在播放器里
        // 生效」——两处都是这一类。
        // ⛔ `deletedSources.revision` 也必须在里面。删源时我们同时写了 `hiddenSources`
        // （它的 revision 会变，戳因此也会变），所以**当前看着不坏**——但这是靠同一条路径的
        // 副作用兜住的。一旦将来某处只动 `deletedSources`（例如恢复/撤销、或忘了同步写 hidden），
        // 缓存戳不动，`groupsCache` / `orderedCache` 会继续发旧 `Site`，删除静默失效。
        // 用户刚踩过 `sourceRouting` / `sourceOverrides` 这两个同款坑，不要再留第三个。
        return "\(environments.activeID.uuidString)|\(subscription?.origin.absoluteString ?? "")|\(imported)|\(subscription?.sites.count ?? 0)|\(entries)|\(pinnedSources.revision)|\(hiddenSources.revision)|\(deletedSources.revision)|\(vault.revision)|\(sourceOrder.revision)|\(sourceReassignment.revision)|\(sourceGroupBook.revision)|\(sourceRouting.revision)|\(sourceOverrides.revision)|\(searchScope.revision)"
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
        deletedSources = DeletedSources(defaults: playbackDefaults)
        searchScope = SearchScope(defaults: playbackDefaults)
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
        // [mi3s] 二开：下载也按环境隔离。下载记录自带 `environmentID`（nil 归默认环境），
        // 音乐下载同理。`DownloadLibrary.shared` / `MusicDownloadLibrary.shared` 是全局单例
        // （下载队列跑在 App 上、不持有 Store），所以这里必须写进同一个实例，否则页面与
        // 「这一集下过没有」的判断会各读一套。
        DownloadLibrary.shared.defaultEnvironmentID = loadedEnvironments.all.first?.id
        DownloadLibrary.shared.activeEnvironmentID = loadedEnvironments.activeID
        MusicDownloadLibrary.shared.defaultEnvironmentID = loadedEnvironments.all.first?.id
        MusicDownloadLibrary.shared.activeEnvironmentID = loadedEnvironments.activeID
        // [mi3s] 二开：偏好式数据（置顶 / 隐藏 / 源排序 / 源改派 / 自定义分组）没有记录可打戳，
        // 按 storage key 分环境。这里先把当前环境灌进去，各处 init 读的就是当前环境的那一份。
        // init 里 `self` 还没整体就绪，只能走静态形式、把几个 store 显式传进去。
        Self.applyEnvironment(loadedEnvironments, pinned: pinnedSources, hidden: hiddenSources,
                              deleted: deletedSources,
                              order: sourceOrder, reassignment: sourceReassignment,
                              groups: sourceGroupBook, overrides: sourceOverrides,
                              lines: lineSettings, routing: sourceRouting, search: searchScope)
        if let blob = playbackDefaults.data(forKey: Self.artworkLanguageKey),
           let decoded = try? JSONDecoder().decode(ArtworkLanguage.self, from: blob) { artworkLanguage = decoded }
        if let blob = playbackDefaults.data(forKey: Self.skipSourcesKey),
           let decoded = try? JSONDecoder().decode(SkipSegmentSources.self, from: blob) { skipSources = decoded }
        if let blob = playbackDefaults.data(forKey: Self.resourceRankingKey(loadedEnvironments)),
           let decoded = try? JSONDecoder().decode(ResourceRanking.self, from: blob) {
            resourceRanking = decoded
            resourceRankingEnvironmentID = loadedEnvironments.activeID
        }
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
        // Search's group priority needs the same grouping the page draws; ask this store rather than
        // rebuilding it there, so a group the viewer renamed or reordered is honoured at once.
        searchModel.groupOf = { [weak self] site in self?.groupID(listing: site) ?? "" }
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
                // ⛔ 落地地址必须在 `documents[entry.address] = nil` **之前**取，否则永远读到 nil。
                // 这是本函数的经典踩点：先清文档、再去问文档要 origin。
                let landedOrigin = documents[entry.address]?.origin
                documents[entry.address] = nil; subscriptionErrors[entry.address] = nil
                if persistsChanges { try? FileManager.default.removeItem(at: Self.file(for: entry)); ImportedFiles.remove(entry.address) }
                // 删订阅要连它名下的「真删子源」记账一起清掉。
                // 不清的话，将来重新加回同一地址时那些源仍然记着「已删除」，
                // 于是又隐形又不报错 —— 看起来像「重新导入少了一批源」。
                // ⛔ 两个地址都要试：`entry.address` 是用户输入的那个，而键里存的是
                // `site.origin(or:)`（= `provenance.origin`，重定向/镜像/协议升级后的落地地址）。
                // 两者不等时只传其一会漏账，后果是「删订阅再重加，源永远不回来」。
                var origins: [URL] = []
                if let typed = URL(string: entry.address) { origins.append(typed) }
                if let landedOrigin { origins.append(landedOrigin) }
                deletedSources.forget(origins: origins)
                // 隐藏标记也要一起清。只清真删的话，源回来时是隐藏态、落在「已隐藏」里，
                // 用户看到的是「重新导入少了一批源」—— `deleteSite` 注释承诺的「源自然全部回来」不成立。
                hiddenSources.forget(origins: origins)
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
    /// What merging one file would change, counted by source identity, so the import dialog can say
    /// it before the viewer picks a mode instead of surprising them afterwards.
    struct ImportSummary: Sendable {
        var newSubscriptions = 0
        var newSources = 0
        var duplicateSources = 0
        var newLivePlaylists = 0
        /// How many subscriptions the file itself lists.
        var listedSubscriptions = 0
        /// Nothing in the file is missing from this device.
        var addsNothing: Bool { newSubscriptions == 0 }
    }

    func previewImport(_ config: SubscriptionConfig) -> ImportSummary {
        guard config.isValid else { return ImportSummary() }
        var summary = ImportSummary()
        summary.listedSubscriptions = config.subscriptions.count
        var offered = Set<String>(), offeredLives = Set<URL>()
        for entry in environmentSubscriptions where entry.enabled {
            guard let document = documents[entry.address] else { continue }
            offered.formUnion(document.fingerprints)
            offeredLives.formUnion(document.lives.map(\.url))
        }
        let known = Set(environmentSubscriptions.map(\.address))
        for synced in config.subscriptions.sorted(by: { ($0.rank, $0.entry.address) < ($1.rank, $1.entry.address) })
        where !known.contains(synced.entry.address) {
            guard let document = synced.document else { summary.newSubscriptions += 1; continue }
            let fresh = document.fingerprints.subtracting(offered)
            let freshLives = document.lives.filter { !offeredLives.contains($0.url) }
            summary.duplicateSources += document.sites.count - fresh.count
            guard !fresh.isEmpty || !freshLives.isEmpty else { continue }
            summary.newSubscriptions += 1
            summary.newSources += fresh.count
            summary.newLivePlaylists += freshLives.count
            offered.formUnion(fresh)
            offeredLives.formUnion(freshLives.map(\.url))
        }
        return summary
    }

    /// Merges a configuration file in. `overwrite` decides what happens to an address that is
    /// already present: by default (merge) it is left untouched, so re-importing never duplicates or
    /// overwrites; with `overwrite` the file's name, enabled state and routing win, so a backup
    /// restores the exact state it was exported in. In both modes the list is reordered to the
    /// file's rank, and a fresh entry that carries a content snapshot is restored without a fetch.
    ///
    /// Merge mode also skips a new subscription whose sources are all on screen already, compared by
    /// `Site.fingerprint` rather than by address: bundles from different rounds list the same providers
    /// under different addresses, and adding them all made one site answer three searches.
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
                // ⛔ 与 `removeSubscriptions` 同款：导入配置会**删掉不在文件里的订阅**，
                // 那条路径也必须清它的「真删子源」记账。漏了就是：用户导入一份不含某订阅的
                // 配置 → 该订阅被移除、记账还留着 → 之后再把那个订阅加回来，
                // 那批源永远不出现，而 `undeleteSite` 已删，**没有任何入口能救**。
                // 落地地址要在清 documents 之前取。
                let landedOrigin = documents[entry.address]?.origin
                documents[entry.address] = nil; subscriptionErrors[entry.address] = nil
                if persistsChanges { try? FileManager.default.removeItem(at: Self.file(for: entry)); ImportedFiles.remove(entry.address) }
                var origins: [URL] = []
                if let typed = URL(string: entry.address) { origins.append(typed) }
                if let landedOrigin { origins.append(landedOrigin) }
                deletedSources.forget(origins: origins)
                // 隐藏标记也要一起清。只清真删的话，源回来时是隐藏态、落在「已隐藏」里，
                // 用户看到的是「重新导入少了一批源」—— `deleteSite` 注释承诺的「源自然全部回来」不成立。
                hiddenSources.forget(origins: origins)
            }
        }

        var added: [SubscriptionEntry] = []
        var restored: [(SubscriptionEntry, Subscription)] = []
        /// What the environment already offers, by source identity rather than by address. Merge mode
        /// keeps every subscription already on screen, so a bundle that repeats them would otherwise
        /// add a subscription per address while the merged list holds each provider once — a file that
        /// adds nothing but duplicates used to grow the list on every import. A subscription whose
        /// sources are all here already is not added at all.
        var offered = Set<String>(), offeredLives = Set<URL>()
        if !overwrite {
            for entry in environmentSubscriptions where entry.enabled {
                guard let document = documents[entry.address] else { continue }
                offered.formUnion(document.fingerprints)
                offeredLives.formUnion(document.lives.map(\.url))
            }
        }
        var skipped = 0

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
                if !overwrite, let document = synced.document {
                    let fresh = document.fingerprints.subtracting(offered)
                    let freshLives = document.lives.filter { !offeredLives.contains($0.url) }
                    guard !fresh.isEmpty || !freshLives.isEmpty else { skipped += 1; continue }
                    offered.formUnion(fresh)
                    offeredLives.formUnion(freshLives.map(\.url))
                }
                let stamped = stamping(synced.entry)
                subscriptions.append(stamped)
                added.append(stamped)
                if let document = synced.document { restored.append((stamped, document)) }
            }
        }

        guard !added.isEmpty || overwrite || removedCount > 0 else {
            notice = skipped > 0
                ? L10n.text("Nothing new: the %lld subscriptions in this file list only sources you already have.", skipped)
                : L10n.text("Every subscription in this file is already imported; nothing was added.")
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
        if skipped > 0, !overwrite {
            notice = (notice.map { $0 + " " } ?? "") + L10n.text("Skipped %lld: everything they list is already here.", skipped)
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
        // [mi3s] 二开：接管配置里夹带的测速读数。
        //
        // 外部生成的订阅（`*-ranked.json`）会把测速结果写进每个源的 `raw`：
        // `_route` / `_speedKBps` / `_mbps` / `_quality`。此前我们**完全不读**这些字段，
        // 于是 341 个源里那 38 个已经测过的等于白测，用户还得自己再跑一遍全量。
        //
        // 放在 `keep()` 而不是各个下载/解析分支里：这是所有订阅内容的唯一写入口
        // （本地导入、远端刷新、云同步三路都过它），一处接线就全覆盖。
        importBundledReadings(value)
    }

    /// 把一份订阅里自带的测速读数交给探测库。
    ///
    /// 判定（两个速度字段是否矛盾、`_route` 怎么说）全在 `SourceProbeImport`，
    /// 这里只负责遍历与汇总 —— 判定逻辑留在 TVCore 才有测试钉着。
    ///
    /// 不覆盖更新的自测读数由 `importReadings` 自己保证，所以反复刷新不会把
    /// 用户刚测的实时数据冲回导出那一刻的旧值。
    private func importBundledReadings(_ value: Subscription) {
        var found: [String: SourceProbeResult] = [:]
        for site in value.sites {
            guard let reading = SourceProbeImport.reading(from: site.raw) else { continue }
            found[site.sourceKey] = reading
        }
        guard !found.isEmpty else { return }
        let written = SourceProbeStore.shared.importReadings(found)
        guard written > 0 else { return }
        Diagnostics.shared.record(.info, "probe",
            "imported \(written) readings from \(value.origin.host() ?? value.origin.absoluteString)")
    }
    /// 放宽到 `internal`：`Store+SearchScope.swift`（另一个文件里的 extension）要用它改订阅名。
    /// 与 `remember(_:client:for:)` 同一个理由 —— 复制一份写盘逻辑必然与这里走散。
    func saveSubscriptionList() {
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
        let deleted = deletedSources
        sync.register("favorites", current: { favorites.syncValues }, apply: { favorites.adopt($0) })
        sync.register("history", delay: .seconds(30), current: { Dictionary(history.entries.map { ($0.environmentKey, $0) }, uniquingKeysWith: { first, _ in first }) },
                      apply: { history.adopt($0.map(\.value)) })
        sync.register("subscriptions", current: { [weak self] in self?.syncedSubscriptions ?? [:] }, apply: { [weak self] in self?.adoptSubscriptions($0) })
        sync.register("pinnedSources", current: { CloudSync.ranks(pinned.savedKeys) }, apply: { pinned.adopt(CloudSync.ordered($0)) })
        sync.register("hiddenSources", current: { Dictionary(hidden.savedKeys.map { ($0, true) }, uniquingKeysWith: { first, _ in first }) },
                      apply: { hidden.adopt($0.sorted { ($0.stamp, $0.id) < ($1.stamp, $1.id) }.map(\.id)) })
        // 真删的子源也要跟着走。不注册的话，另一台设备只收到 `hiddenSources`，
        // 删掉的源在那边以「已隐藏」出现并带 Unhide —— 删除语义被降级成隐藏。
        sync.register("deletedSources", current: { Dictionary(deleted.savedKeys.map { ($0, true) }, uniquingKeysWith: { first, _ in first }) },
                      apply: { deleted.adopt($0.sorted { ($0.stamp, $0.id) < ($1.stamp, $1.id) }.map(\.id)) })
        sync.register("sourceOrder", current: { CloudSync.ranks(order.savedKeys) }, apply: { order.adopt(CloudSync.ordered($0)) })
        // Only "on" is an item: a new device's default (off) is no change, so it can't switch the order off everywhere.
        sync.register("sourceOrderOn", current: { order.enabled ? ["on": true] : [:] }, apply: { if order.enabled == $0.isEmpty { order.enabled = !$0.isEmpty } })
        // The group ranking follows the viewer too: it is a ranking they set up over an hour, and a
        // new device that fell back to the automatic order would quietly disagree with the old one.
        sync.register("sourceGroupOrder", current: { CloudSync.ranks(order.savedGroupOrder) }, apply: { order.saveGroupOrder(CloudSync.ordered($0)) })
        // 自定义分组也要跟人走。它是唯一一个此前既不跨设备、也不跨环境的偏好 store：
        // 在这台机器上把 300 个源分好组，换一台打开是一片散沙 —— 而分组正是最费时的那项整理。
        // `adopt` 按名合并（不产生两个同名组），所以两台各建过组也不会互相覆盖。
        let groupBook = sourceGroupBook
        sync.register("sourceGroups",
                      current: { Dictionary(groupBook.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) },
                      // `complete: true`：这份列表是远端的全部。不带它，「删掉一个分组」
                      // 在同步里永远不生效 —— 只增不删的合并会留着本地那条，下一轮又推回云端。
                      apply: { groupBook.adopt($0.map(\.value), complete: true) })
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
        // 没有这一行，上面那条 `register("deletedSources")` 永远不会被推上去：
        // `DeletedSources.onChange` 声明了却没人挂，删源在别的设备上完全不可见。
        deleted.onChange = { sync.changed("deletedSources") }
        order.onChange = { sync.changed("sourceOrder"); sync.changed("sourceOrderOn"); sync.changed("sourceGroupOrder") }
        sourceGroupBook.onChange = { sync.changed("sourceGroups") }
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
            // 与另外两条删订阅路径同款：清掉该订阅名下的「真删子源」记账，
            // 否则本机永久留孤儿（那批源以后即使同一个订阅回来也永不显示）。
            let landedOrigin = documents[entry.address]?.origin
            documents[entry.address] = nil; subscriptionErrors[entry.address] = nil
            try? FileManager.default.removeItem(at: Self.file(for: entry))
            var origins: [URL] = []
            if let typed = URL(string: entry.address) { origins.append(typed) }
            if let landedOrigin { origins.append(landedOrigin) }
            deletedSources.forget(origins: origins)
            // 隐藏标记也要一起清。只清真删的话，源回来时是隐藏态、落在「已隐藏」里，
            // 用户看到的是「重新导入少了一批源」—— `deleteSite` 注释承诺的「源自然全部回来」不成立。
            hiddenSources.forget(origins: origins)
        }
        subscriptions = next
        saveSubscriptionList()
        if subscriptions.contains(where: { $0.enabled && documents[$0.address] == nil }) { Task { await restoreSubscription() } }
        else { rebuildSubscription() }
    }
    /// Shows every enabled subscription that has a copy, merged in list order.
    /// Not private: the grouping and routing batches in Store+SourceGrouping write through it.
    func rebuildSubscription(resetting: Bool = true) {
        if resetting { searchModel.reset(); recommendationModel.reset() }
        subscription = Subscription.merge(environmentSubscriptions.filter(\.enabled).compactMap { documents[$0.address] })?.withCloudSources(extrasUnlocked ? cloudDocument : nil)
        if let subscription { applySourceRouting(subscription) }
        refreshCloudSources()
        if let subscription {
            Self.registerPlugins(subscription)
            // ⛔ 这两句会**移除隐藏标记**。它们不看 `deletedSources` ——
            // 而 `deletedSources` 只在隐藏计数里被读，列表过滤只认 `hiddenSources`。
            // 于是「真删」的内置源 / 曾失败过的源会在这一句里被重新显示出来：
            // 删了、刷新一下、又回来了 —— 用户看到的就是「删除失效」。
            //
            // 修法：先把真删的源从入参里剔掉，再交给这两个一次性迁移。
            // 它们本来就是「把历史遗留的隐藏恢复一遍」的补丁，没有理由去碰用户刚刚删掉的源。
            let restorable = subscription.sites.filter {
                !deletedSources.contains($0, origin: subscription.origin)
            }
            hiddenSources.restoreBuiltIns(restorable, origin: subscription.origin)
            hiddenSources.restoreAutoHidden(restorable, origin: subscription.origin, health: .shared)
            #if os(iOS) || os(tvOS)
            // Converts the visible JAR sources' likely classes while the app sits idle (issue #274).
            let visible = subscription.sites.filter { !hiddenSources.contains($0, origin: subscription.origin) }
            let origin = subscription.origin, spider = subscription.spiderURL
            Task { await PluginConversionAhead.shared.schedule(sites: visible, origin: origin, spider: spider) }
            #endif
        }
        adoptLegacyMoves()
        pruneGroupOrder()
        // 真删记账只增不减会跟着同步/备份无限膨胀。按现存订阅地址回收一次 ——
        // 放在这里而不是删订阅处，是因为「哪些订阅还活着」只有重建后才是最终答案。
        var live = Set(environmentSubscriptions.map(\.address))
        if let landed = subscription?.origin.absoluteString { live.insert(landed) }
        deletedSources.prune(live: live)
    }

    /// Forgets ranking entries that no longer name anything: a deleted custom group, a removed
    /// subscription. Without it a stale id keeps a place in the ranking for ever, and a real group
    /// sits permanently below a group that does not exist.
    ///
    /// The five kinds of id a source group can carry are all that can be named, so this keeps exactly
    /// those plus the ids of the viewer's own groups.
    private func pruneGroupOrder() {
        guard sourceOrder.hasGroupOrder else { return }
        var known: Set<String> = ["pinned", "builtIn", "other", "hidden"]
        // Only switched-on subscriptions have a section (`SourceGroups.make` skips disabled ones),
        // so a switched-off address must not hold a ranking slot the page cannot show or adjust.
        known.formUnion(environmentSubscriptions.filter(\.enabled).map(\.address))
        known.formUnion(sourceGroupBook.groups.map(\.target))
        sourceOrder.pruneGroupOrder(keeping: known)
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
        // A batch suppresses this and rebuilds once; see `Store.performBatch`.
        if !suppressRebuild { rebuildSubscription() }
    }

    /// Takes one source out of every group and subscription — 「未分组」.
    ///
    /// 与 `reassignSource(site, to: nil)` 的区别：nil 是「放回原订阅」，而这是「放到不属于任何
    /// 订阅的未分组里」。两者都是显式去路，用户需要能区分，否则「我把它移出去」做不到 ——
    /// 唯一的「移出」动作会把它送回原处。
    func moveSourceToUngrouped(_ site: Site) {
        reassignSource(site, to: CustomSourceGroup.ungroupedTarget)
    }

    /// 这个源当前是不是「未分组」。
    func isUngrouped(_ site: Site) -> Bool {
        guard let config = subscription else { return false }
        return sourceReassignment.destination(address: entryAddress(of: site) ?? site.origin(or: config.origin).absoluteString,
                                              sourceKey: site.sourceKey,
                                              origin: site.provenance?.origin)
            .map(CustomSourceGroup.isUngrouped) ?? false
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
        /// 阶段 1 在这一批之前筛掉了多少源。只有批次里的**第一个**带它（其余为 0），
        /// 让消费方能把进度分母从「全部源」校正为「真正要细测的源」——
        /// 否则 350 个源筛掉 200 个时，进度条会停在 150/350 然后凭空消失。
        var screenedOut = 0
    }

    /// Starts measuring every listed source — built-in ones included.
    ///
    /// The sweep runs off the main actor, a few sources at a time, and each source is given a
    /// deadline. It used to run on the main actor, one source after another, waiting for a plugin to
    /// compile and a dead host to time out at every step: the app looked frozen because it was. The
    /// reader can stop it, and the progress is visible while it runs.
    /// 全量探测。
    ///
    /// - Parameter fast: true 时用 `.bulk` 调度（阶段 2 并发 16 而不是 4）。
    ///
    /// ⛔ `standard` 的 4 路并发是按「插件编译抢 CPU」定的，对**纯 HTTP 线路测速**过于保守：
    /// 340 个源 4 路要排 85 轮、每轮约 3 秒 → 4 分钟以上，这就是「探测缓慢」的来源。
    /// `.bulk` 开到 16 路，同样 340 源约 21 轮、1 分钟内跑完。
    func startProbingAllSources(fast: Bool = true) {
        guard let config = subscription else { return }
        runProbe(probeTargets(config, skippingFresh: probeMaxAge),
                 schedule: fast ? .bulk : .standard)
    }

    /// How old a reading may be before a sweep counts it as stale. Ten minutes by default: pressing
    /// the button twice costs nothing, and a source that broke an hour ago is still re-checked. 0 on
    /// the speed page means never skip.
    var probeMaxAge: TimeInterval {
        get {
            // 默认值与 `SourceProbeResult.isStale` 的容差同源：两处回答的是同一个问题
            //（「多旧的读数还算数」），各写一个常数就会对同一条读数给出相反结论。
            playbackDefaults.object(forKey: "sourceProbeMaxAge") == nil
                ? sourceProbeStaleness : playbackDefaults.double(forKey: "sourceProbeMaxAge")
        }
        set {
            playbackDefaults.set(newValue, forKey: "sourceProbeMaxAge")
            probeSkipped = nil
        }
    }

    /// 上一轮被**阶段 1 筛掉**（连不上 / 服务器报错）而没进入细测的源数。
    /// 和 `probeSkipped`（读数还新）是两回事，页面要说清是哪一种。
    private(set) var probeScreenedOut: Int?
    /// What the last sweep left out because its reading was still good. A button that measured 12 of
    /// 353 sources must say so, or it reads as broken.
    private(set) var probeSkipped: Int?

    private func needsProbing(_ sourceKey: String, maxAge: TimeInterval) -> Bool {
        guard maxAge > 0 else { return true }
        guard let reading = SourceProbeStore.shared.latest(sourceKey: sourceKey) else { return true }
        return reading.measuredAt.timeIntervalSinceNow < -maxAge
    }

    /// Measures just these sources — the ones in one group, or the ones the reader ticked. A full
    /// sweep of 350 sources takes minutes; re-checking the twenty that survived is the common case.
    func startProbing(_ sites: [Site]) {
        startProbing(sites, skippingFresh: 0)
    }

    /// The same, incremental: a source measured within maxAge seconds is left alone, and what was
    /// skipped is reported so the page can say so. 0 forces a fresh reading for every source.
    func startProbing(_ sites: [Site], skippingFresh maxAge: TimeInterval, fast: Bool = true) {
        guard let config = subscription else { return }
        var seen = Set<String>()
        let chosen = sites.filter { seen.insert($0.id).inserted }
        let targets = chosen.map { ProbeTarget(site: $0, origin: $0.origin(or: config.origin), jarURL: config.spiderURL) }
        // The bulk schedule, by default, for the same reason "measure everything" uses it: a reader
        // who tapped "measure this subscription" is watching a progress bar, and the standard
        // schedule is four times more polite about concurrency than that moment calls for.
        let schedule: ProbeSchedule = fast ? .bulk : .standard
        guard maxAge > 0 else {
            probeSkipped = nil
            runProbe(targets, schedule: schedule)
            return
        }
        let fresh = targets.filter { needsProbing($0.site.sourceKey, maxAge: maxAge) }
        probeSkipped = targets.count - fresh.count
        runProbe(fresh, schedule: schedule)
    }

    private func runProbe(_ targets: [ProbeTarget], schedule: ProbeSchedule = .standard) {
        guard probeTask == nil, !targets.isEmpty else { return }
        probeRun = ProbeRun(done: 0, total: targets.count)
        // 收尾整理要知道「这一轮测了哪些源」——只整理测过的，没测的不该被顺手移动。
        probeSwept = targets.map(\.site)
        let token = UUID()
        probeToken = token
        probeTask = Task { [weak self] in
            var done = 0
            // 分母先按「全部源」建，第一条批次到了再按阶段 1 的结果校正 ——
            // 否则被筛掉的那些永远等不到自己的 done，进度条走不满就消失。
            var total = targets.count
            for await batch in Self.probeBatches(targets, schedule: schedule) {
                if !batch.videoID.isEmpty {
                    SourceProbeStore.shared.record(batch.rows.map { ($0.result, $0.flag) },
                                                   sourceKey: batch.sourceKey, videoID: batch.videoID)
                }
                if batch.screenedOut > 0 {
                    total = max(0, total - batch.screenedOut)
                    self?.probeScreenedOut = batch.screenedOut
                }
                done += 1
                guard self?.probeToken == token else { return }
                self?.probeRun = ProbeRun(done: done, total: max(done, total))
                if Task.isCancelled { break }
            }
            guard self?.probeToken == token else { return }
            self?.probeRun = nil
            self?.probeTask = nil
            // ★ 测完就按结果重排优先顺序（用户的第二项要求）。
            //
            // 此前 `sortScore` 只在显示层用来上色，**从没写过顺序** ——
            // 于是「测完速」对搜索顺序与列表顺序毫无影响，用户还得自己拖。
            // 改成：一轮扫描结束后按得分降序写回 `SourceOrder`，下一次搜索就按新顺序问源。
            if let swept = self?.probeSwept {
                self?.lastTidyNote = self?.tidyAfterSweep(swept, tidy: self?.postSweepTidy ?? .standard)
            }
        }
    }

    /// 按最新测速得分重排源的优先顺序。
    ///
    /// 只动**测过**的源；没测过的原地垫后（没测过≠坏）。
    /// `pinned` 里钉住的永远排最前 —— 用户钉过的意图高于任何测量。
    @MainActor
    func reorderSourcesByProbeResult() {
        guard let config = subscription else { return }
        // 只重排当前可见的源：隐藏/保险库里的源不参与，也不该被排出顺序。
        let sites = sourceGroups(includeHidden: false)
            .filter { $0.kind != .hidden }
            .flatMap(\.sites)
        guard !sites.isEmpty else { return }
        // 钉住的源按 `PinnedSources.contains(_:origin:)` 判定，再折算成键集合
        // （`reorderByProbe` 要的是键，因为它写的就是键数组）。
        let pinned = Set(sites.filter { pinnedSources.contains($0, origin: config.origin) }
            .map { EpisodeSkipSettings.scope(origin: $0.origin(or: config.origin),
                                             source: $0.sourceKey, video: "") })
        // `reorderByProbe` 内部已经 bump `revision` 并触发 `onChange`，这里不要再动它
        // （`revision` 是 `private(set)`，外部写不进也只该有一个写入点）。
        _ = sourceOrder.reorderByProbe(
            sites,
            origin: config.origin,
            // ⛔ 收的是 `Site`，不是键：`SourceOrder` 内部的键是 scope-JSON，
            // 拿它查以裸 `sourceKey` 为键的探针库必然全 nil，重排就成了空操作。
            score: { site in SourceProbeStore.shared.latest(sourceKey: site.sourceKey)?.sortScore },
            pinnedKeys: pinned
        )
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
    private func probeTargets(_ config: Subscription, skippingFresh maxAge: TimeInterval = 0) -> [ProbeTarget] {
        var seen = Set<String>()
        var targets: [ProbeTarget] = []
        var skipped = 0
        for group in sourceGroups(includeHidden: false) where group.kind != .hidden {
            for site in group.sites where seen.insert(site.id).inserted {
                // The incremental part: a reading newer than the window is trusted, so pressing the
                // button again after a sweep costs almost nothing instead of re-measuring 350 sources.
                if maxAge > 0, !needsProbing(site.sourceKey, maxAge: maxAge) {
                    skipped += 1
                    continue
                }
                // `site.origin(or:)`, not `config.origin`: a merged subscription's `origin` is only
                // the first feed's (`Subscription.merge` keeps `first.origin`), so probing every
                // source against it resolves the second feed's relative api against the wrong host —
                // and a source whose API then 404s is recorded as unreachable when it is fine.
                // `startProbing` has always used the per-source origin; this is the same rule.
                targets.append(ProbeTarget(site: site, origin: site.origin(or: config.origin), jarURL: config.spiderURL))
            }
        }
        probeSkipped = maxAge > 0 ? skipped : nil
        return targets
    }

    /// The sweep, as a stream of per-source batches. The producer runs detached, so neither a slow
    /// host nor a plugin's first compile can hold the main actor.
    private nonisolated static func probeBatches(_ targets: [ProbeTarget],
                                                schedule: ProbeSchedule = .standard) -> AsyncStream<ProbeBatch> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                // ── 阶段 1：廉价筛 ───────────────────────────────────────────────
                //
                // 对能直接打 HTTP 的源各发一次 2 KB 请求，先判掉「连不上 / 服务器报错 /
                // 慢到不值得细测」的那一批。旧实现对所有源都直接走重路径（抓主页 + 4 条线路
                // 各 256 KB），一个死源也要花 25 秒超时 + 1 MB 流量才能得出
                // 「它不可用」这个本来一个请求就能知道的结论。
                //
                // 插件源筛不了，`SourceScreen` 会返回 `.unknown` 并**放行** ——
                // 把它们判死会得到「插件没启动所以超时」的假负结论，比不筛更糟。
                let (survivors, dropped) = await screen(targets, schedule: schedule)
                // 筛掉的源不产出批次，第一条批次把它带出去，供消费方校正进度分母。
                var pendingScreenedOut = dropped

                await withTaskGroup(of: ProbeBatch?.self) { group in
                    // 阶段 2 的并发受插件编译限制：比阶段 1 低得多。
                    // 阶段 1 纯 HTTP，所以那里可以开到 `schedule.screenWidth`。
                    let width = schedule.measureWidth
                    var next = 0
                    func launch() -> Bool {
                        guard next < survivors.count, !Task.isCancelled else { return false }
                        let target = survivors[next]
                        next += 1
                        group.addTask { await probe(target) }
                        return true
                    }
                    for _ in 0..<width { if !launch() { break } }
                    for await batch in group {
                        if let batch {
                            var batch = batch
                            batch.screenedOut = pendingScreenedOut
                            pendingScreenedOut = 0
                            continuation.yield(batch)
                        }
                        if !launch() { continue }
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 阶段 1：并发筛。返回值得细测的源。
    ///
    /// 并发用 `schedule.screenWidth`（默认 16）：这一阶段不发插件调用、不编译脚本，
    /// 只发 HTTP，瓶颈在网络与主机轮换。旧的 2 路并发是按「插件编译会抢 CPU」定的，
    /// 对纯 HTTP 的筛来说过于保守 —— 341 个源按 2 路筛要跑几十秒，按 16 路只要几秒。
    private nonisolated static func screen(_ targets: [ProbeTarget],
                                          schedule: ProbeSchedule) async -> (kept: [ProbeTarget], dropped: Int) {
        guard !targets.isEmpty else { return ([], 0) }
        var kept: [(Int, ProbeTarget)] = []
        await withTaskGroup(of: (Int, ProbeTarget)?.self) { group in
            var next = 0
            func launch() -> Bool {
                guard next < targets.count, !Task.isCancelled else { return false }
                let index = next
                let target = targets[index]
                next += 1
                group.addTask {
                    // 筛不了的（插件源、内置源）直接放行。
                    guard SourceScreen.screenable(target.site, jarURL: target.jarURL) else {
                        return (index, target)
                    }
                    // ⛔ 必须把源自己的请求头带上。`source.raw["header"]` 是源声明的
                    // Referer / UA —— 要它的 CDN 对裸请求回 403，而 403 在这里判 `.drop`，
                    // 于是「有头的源」被系统性筛掉、整轮不细测。细测路径（`CatalogClient`
                    // 走 `preparePlayback`）本来就带这组头，所以那道缝只在筛阶段存在。
                    let declared = target.site.raw["header"]?.object?.compactMapValues(\.string) ?? [:]
                    let verdict = await SourceScreen.screen(target.site, origin: target.origin,
                                                            headers: declared, schedule: schedule)
                    if verdict.verdict.shouldMeasure {
                        Diagnostics.shared.record(.info, "probe",
                            "screen keep \(target.site.sourceKey) \(verdict.detail) \(verdict.milliseconds ?? -1)ms")
                        return (index, target)
                    }
                    Diagnostics.shared.record(.info, "probe",
                        "screen drop \(target.site.sourceKey) \(verdict.verdict.rawValue) \(verdict.detail)")
                    return nil
                }
                return true
            }
            for _ in 0..<schedule.screenWidth { if !launch() { break } }
            for await row in group {
                if let row { kept.append(row) }
                if !launch() { continue }
            }
        }
        // 恢复原始顺序：并发完成的顺序是随机的，而扫描进度与「第几个源」要可对齐。
        let survivors = kept.sorted { $0.0 < $1.0 }.map(\.1)
        // 被筛掉的源要能被报告出来。此前它们既不产出 batch、也不进 `probeSkipped`，
        // 于是进度条永远走不满就消失，而页面不会说「为什么少测了 200 个」。
        return (survivors, targets.count - survivors.count)
    }

    /// One source: its home page for a representative video, then that video's lines.
    ///
    /// Each line is **resolved** through `preparePlayback` → `resolvePlayback` before it is measured —
    /// the two steps the episode picker and the cross-source panel already take. That is not a
    /// nicety: for a type 3/4 source an `Episode.address` is a *play parameter* ("第1集$abc123"),
    /// not a URL. Probing it directly measured an address that does not exist, so every such source
    /// came out unreachable, and 「按测速结果分组」filed working sources into 「不通」.
    /// `URL(string: "abc123")` returns a *relative* URL rather than nil, which is why the old
    /// `URL(string: $0.address) != nil` filter let every one of them through.
    ///
    /// Resolving also yields `channel.headers`. A CDN that wants a Referer answers 403 to a bare
    /// request, so a source that plays fine from the picker was measured dead here.
    private nonisolated static func probe(_ target: ProbeTarget) async -> ProbeBatch {
        let client = CatalogClient(site: target.site, origin: target.origin, jarURL: target.jarURL)
        let empty = ProbeBatch(sourceKey: target.site.sourceKey, videoID: "", rows: [])
        guard let page = await withDeadline(seconds: 25, { try await client.home() }),
              let video = page.videos.first else { return empty }
        // One episode per line is enough to judge the line: probing every episode would multiply the
        // work by the episode count without changing the verdict.
        var firstPerFlag: [(flag: String, episode: Episode)] = []
        var seenFlags = Set<String>()
        for episode in video.episodes where !episode.flag.isEmpty {
            if seenFlags.insert(episode.flag).inserted { firstPerFlag.append((episode.flag, episode)) }
        }
        var rows: [ProbeRow] = []
        await withTaskGroup(of: ProbeRow?.self) { group in
            var next = 0
            func launch() -> Bool {
                guard next < firstPerFlag.count, !Task.isCancelled else { return false }
                let (flag, episode) = firstPerFlag[next]
                next += 1
                group.addTask {
                    // Resolve first: the address may be a play parameter, and the answer carries the
                    // headers the CDN actually wants. A line that will not resolve is left unmeasured
                    // rather than filed as dead — the same rule the picker follows.
                    guard let target = await ProbePlanTarget.resolve(episode, client: client) else { return nil }
                    let url = target.url
                    // ⛔ 不要在这里跳过非 HTTP 地址。云盘 / 红果 / DASH 给出的是
                    // `tvbox-cloud://` 之类，它们同样能测 —— `SourceProbeRunner.probe` 内部会把它们
                    // 解析成 App 内的字节流，用同一套两段计时量真实吞吐。在这里拦掉，
                    // 等于让这三类源永远没有读数。
                    // ★ 每个 host 的在飞上限（`LineRotation.maxConcurrent`，默认 4）。
                    //
                    // 这一层才是「别把某个站打急」的真正闸门：源级 `measureWidth`
                    // 只管「同时测多少个源」，而本函数内部还会对同一源的每条线路并发，
                    // 两层相乘才是实际打到某个 host 的并发数
                    // （改前是 16 × 4 = 64，而论证里写的是 16）。
                    //
                    // `beginBase` 同时也是退避闸门：被判 saturated 或正在冷却的 host
                    // 会返回 false，这里**跳过这条线路**（不是判它死）——
                    // 与 `EpisodePicker.probeIfNeeded` 的用法一致。
                    // 原先它只有 EpisodePicker 一处在用、扫描路径完全绕过。
                    // 全局名额（One `pendingTests` 的等价物，RCA H5）：把各入口的并发收进
                    // 同一个池子，别让批量扫描把用户此刻正在播的那条链路占满。
                    //
                    // ⛔ 必须先领全局、再领 host：反过来时若 host 领到而全局没领到就直接
                    //    返回，该 host 的在飞计数永不归还，会被永久判成 saturated。
                    //
                    // ★ 这里**故意用 claim 而不是 wait**：批量扫描（340 源 × 4 线）的
                    //   每个请求都在和同批的其它请求争名额，让它们排队会把整轮扫描
                    //   拖成串行，进度条几分钟不动。跳过并计入"本轮未测"才是诚实的。
                    //   （交互路径——用户点了一条线——才该排队，见 `waitForProbeSlot`。）
                    guard await SourceProbeStore.shared.claimProbeSlot() else { return nil }
                    // ⛔ 每条提前返回的路径都必须显式归还。
                    //    不用 `defer { Task { ... } }`：那个 Task 是异步的，归还晚一拍，
                    //    密集扫描时名额会被自己饿住（连续几轮全被 claim 失败挡掉）。
                    let base = url.host
                    if let base, !(await SourceProbeStore.shared.beginBase(base)) {
                        await SourceProbeStore.shared.releaseProbeSlot()
                        return nil
                    }
                    let result = await SourceProbeRunner.probe(url: url, headers: target.headers)
                    await SourceProbeStore.shared.releaseProbeSlot()
                    if let base {
                        switch result.reachability {
                        case .reachable, .slow: await SourceProbeStore.shared.succeedBase(base)
                        case .unreachable: await SourceProbeStore.shared.failBase(base)
                        case .unknown: await SourceProbeStore.shared.cancelBase(base)
                        }
                    }
                    return ProbeRow(flag: target.flag, result: result)
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
        groupOfSiteCache = nil
    }

    /// The `SourceGroup.id` a source is listed under, for search's group priority. Empty when no
    /// grouping is available (no subscription yet), which `SourceOrder` reads as "unranked".
    func groupID(listing site: Site) -> String {
        let stamp = currentSiteListStamp()
        // The cache is consulted before asking about the particular source: a source in no group at
        // all (privacy-hidden, or not browsable) is absent from the map, and testing for it first sent
        // every such lookup back through a full rebuild — once per comparison in `arrange`.
        if stamp == siteListStamp, let cached = groupOfSiteCache { return cached[site.id] ?? "" }
        var map: [String: String] = [:]
        // Read with `includeHidden: true`, which does **not** build the "Hidden Sources" section:
        // `SourceGroups.make` only adds it when hidden sources are being filtered out, and with them
        // included a hidden source stays in its own group. So a hidden source is reported under its
        // own group here — which is what matters, since search never asks a hidden source anyway.
        // "group:id" is what `SourceGroup.id` yields for the viewer's own groups.
        for group in sourceGroups(includeHidden: true) {
            for member in group.sites where map[member.id] == nil { map[member.id] = group.id }
        }
        groupOfSiteCache = map
        return map[site.id] ?? ""
    }

    /// The sources page's sections: pinned, built-in, then one per subscription.
    func sourceGroups(includeHidden: Bool) -> [SourceGroup] {
        let stamp = currentSiteListStamp()
        if stamp == siteListStamp, let cached = groupsCache[includeHidden] { return cached }
        guard let config = subscription else { return [] }
        let pins = pinnedSources.arrange(config.sites, origin: config.origin).filter { pinnedSources.contains($0, origin: config.origin) }
        var groups = SourceGroups.make(entries: environmentSubscriptions, documents: documents, builtIns: config.sites.filter(\.isBuiltIn), builtInOrigin: config.origin, mergedSites: config.sites, pinOrder: pins, userHidden: { hiddenSources.contains($0, origin: config.origin) }, includeHidden: includeHidden, jarURL: config.spiderURL, privacyHidden: { !vault.permits(site: $0, fallback: config.origin) },
            // 真删的源：列表过滤仍由 `hiddenSources` 完成（它们同时写进了那份），
            // 这里只负责把它们**挡在「已隐藏」分区之外** —— 那边有 Unhide，
            // 让删掉的源出现在那儿正是要消灭的「删除失败」错觉。
            deletedHidden: { deletedSources.contains($0, origin: config.origin) },
            reassign: { site, address in
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
    /// 把这一部剧挂成当前的播放目录（catalog）。
    ///
    /// 权限从 `private` 放宽到 `internal`：`Store+CrossSource` 换源时也要挂，
    /// 而复制一份出来必然与这里走散（它还要写 MediaCache、还要异步补集名标签）。
    /// 放宽可见性比复制逻辑安全。
    func remember(_ video: Video, client: CatalogClient, for channel: Channel) {
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

    func nextFile(after channel: Channel) -> Channel? { file(1, from: channel, in: filesFolder) }
    func previousFile(before channel: Channel) -> Channel? { file(-1, from: channel, in: filesFolder) }

    /// 云文件目录的「下一集/上一集」，**由调用方指定目录**。
    ///
    /// 供坞里的任务用：`filesFolder` 是 Store 上的单值，坞里同时播放两个不同目录的文件时
    /// 它只会指向最后开始的那一个。任务各自带着自己的目录来问，才不会串。
    func nextFile(after channel: Channel, in folder: CloudFilesFolder?) -> Channel? {
        file(1, from: channel, in: folder)
    }
    func previousFile(before channel: Channel, in folder: CloudFilesFolder?) -> Channel? {
        file(-1, from: channel, in: folder)
    }

    /// The file `offset` places from the playing one in its folder, for the player's Previous and Next.
    ///
    /// `folder` 由调用方给（前台给 `filesFolder`，坞里的任务给自己的那一份）。
    /// 三重比对（`drive.key` / `folder.id` / 文件名都在同一个 context 里）保证
    /// **拿错目录只会返回 nil，绝不会播到别的目录里的片子**。
    private func file(_ offset: Int, from channel: Channel, in folder: CloudFilesFolder?) -> Channel? {
        guard let context = channel.historyContext, context.sourceKey == CloudFiles.sourceKey, let folder,
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
