import SwiftUI
import TVCore

@main struct TVBoxApp: App {
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @State private var store = Store.shared
    #else
    @State private var store = Store()
    #endif
    @State private var updates = Updates()
    @State private var announcements = Announcements()
    // [mi3s] 二开：隐私遮罩开关。SwiftUI 的 ViewModifier 无法承载 App 级存储属性，
    // 也无法在 extension 里加 stored property，只能落在 App 结构体上。
    @AppStorage(PrivacyShade.key) private var coversAppSwitcher = true
    #if os(iOS)
    /// An Apple TV's Douyin code, scanned with the Camera.
    @State private var douyinHandoff: DouyinHandoff.Link?
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    #if os(iOS) || os(macOS)
    /// A link that asks to add a subscription, waiting for the viewer to agree (#167). Apple TV opens no links.
    @State private var subscriptionLink: SubscriptionImportLink?
    #endif
    init() {
        #if DEBUG
        // ★ InjectionIII 热重载（仅 Debug）。
        // 加载后改 .swift 保存即可注入运行中的 App，无需重装。
        // 前提：Other Linker Flags 含 -Xlinker -interposable（见 project.yml）。
        #if os(iOS)
        Bundle(path: "/Applications/InjectionIII.app/Contents/Resources/iOSInjection.bundle")?.load()
        #endif
        #endif
        #if os(macOS)
        // Use thin overlay scrollers app-wide. With "Show scroll bars: Always" or a mouse attached,
        // AppKit otherwise draws wide legacy scrollers that crowd poster grids and the episode rail.
        // The app's own defaults domain takes precedence over the global setting.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
        #endif
        #if os(iOS)
        _ = MusicRemoteControl.shared
        DownloadsLifecycle.install()
        // 观看页皮肤：首次启动把旧版布尔迁移成三态值，之后读到的就是稳定值。
        PlaySkin.adoptCurrentIfNeeded()
        // 播放器控件布局：把旧版「每形态一份」并成一份（幂等，见函数注释）。
        // 三种形态共用一份排布，放不下的按钮由播放器运行时收进「更多」。
        PlayerControlsLayout.migrateToUnifiedIfNeeded()
        #endif
        SubtitleTranslationSetup.install()
        // [mi3s] 出口代理：回环中继必须在播放前起来。此前 `LocalProxyServer.base()` 零调用点，
        // `baseSync` 恒为 nil，配了代理也只会静默直连——这里在启动时就把它拉起。
        LocalProxyServer.shared.ensureStarted()
        // 给 Loon 拉订阅用的规则服务：绑所有网卡，局域网地址与回环都能连。
        RulesHost.shared.start()
        // 内存压力监听：20 个小窗 + 画质增强那条路的降级依据（见 `PlaybackLoad`）。
        // 不装它就是「等系统先杀进程，我们连让路的机会都没有」。
        PlaybackLoad.shared.startMemoryPressureMonitor()
        Task.detached { LoonConfigProbe.logOnce() }
    }
    var body: some Scene {
        WindowGroup {
            // Store, Updates and Announcements go in last, below: sheets attached here show outside RootView.
            RootView().environment(store).environment(updates).environment(announcements)
                // [mi3s] 二开：App Switcher 缩略图遮罩。必须挂在根视图上并常驻视图树，
                // 系统在进入后台的瞬间才截图，晚挂的 view 已经来不及进快照。
                .privacyShade(enabled: coversAppSwitcher)
                #if !os(tvOS)
                // tvOS draws plain buttons and section links in the tint, so it keeps the neutral default.
                .tint(Brand.accent)
                #endif
                .task { Diagnostics.shared.record(.info, "app", "Application scene opened") }
                .task { await ErrorReports.shared.start() }
                .task {
                    // ★ 结账上一次启动：如果「创建 JVM → VM 应答」这段窗口没走完，进程就没了。
                    // 必须在**任何一次插件请求之前**跑，否则这一轮又会拿一次点击去撞同一个 abort。
                    // 读上次的小窗快照，供管理器「恢复上次窗口」使用。
                    // ⛔ 只读不恢复：见 `VideoTaskCenter.loadResumable` 的说明。
                    store.videoTasks.loadResumable()
                    if JarRuntimeHealth.audit() {
                        Diagnostics.shared.record(.error, "jar.runtime",
                            "embedded JVM aborted while starting; disabled for build \(JarRuntimeHealth.currentBuild) failures=\(JarRuntimeHealth.failures)")
                    }
                    // ★ 无条件清理 QA 换皮残留 —— 必须放在 QA 门控**之前**。
                    // 写它的要 QA 启动、清它的也要 QA 启动时，就永远解不开；
                    // 真机实证过「选 One 无效、杀进程重进还是哔哩哔哩」。
                    QALaunch.consumeStickyQASkin()
                    #if DEBUG
                    if QALaunch.section != nil || QALaunch.page != nil { await QALaunch.start(store); return }
                    #endif
                    await store.seedAggregatedSubscriptions()
                    await store.restoreSubscription()
                    // After the saved subscriptions load, so the ones another device added load beside them.
                    store.cloudSync?.start()
                }
                .task {
                    #if DEBUG
                    if QALaunch.section != nil, UserDefaults.standard.string(forKey: "qaReleaseFeed") == nil { return }
                    #endif
                    // Builds before 1.1 recorded no version, so earlier use shows as a saved subscription.
                    await updates.launched(returning: UserDefaults.standard.string(forKey: "subscriptionAddress") != nil)
                }
                .task {
                    #if DEBUG
                    if QALaunch.section != nil, UserDefaults.standard.string(forKey: "qaMessageFeed") == nil { return }
                    #endif
                    await announcements.check()
                }
                #if os(tvOS) || os(macOS)
                .task { BilibiliCastController.shared.start(store) }
                .onChange(of: store.extrasUnlocked) { _, unlocked in if unlocked { BilibiliCastController.shared.start(store) } }
                #endif
                #if os(tvOS) || os(macOS)
                .task { PlayOnController.shared.start(store) }
                #endif
                #if os(iOS)
                // Both links carry the app's one scheme, and only the action's host tells them apart.
                .onOpenURL { url in
                    if let link = DouyinHandoff.Link(url) { douyinHandoff = link }
                    else if let link = SubscriptionImportLink(url) { subscriptionLink = link }
                }
                .sheet(item: $douyinHandoff) { DouyinHandoffView(link: $0) }
                .sheet(item: $subscriptionLink) { SubscriptionImportView(link: $0) }
                #elseif os(macOS)
                .onOpenURL { url in if let link = SubscriptionImportLink(url) { subscriptionLink = link } }
                .sheet(item: $subscriptionLink) { SubscriptionImportView(link: $0) }
                // Without this, every link opened a second main window, and the sheet showed in both.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                #endif
                // A launch that ends while active, without passing through here, crashed or was ended.
                .onChange(of: scenePhase, initial: true) { _, phase in ErrorReports.shared.onScreen(phase == .active) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        Task { _ = await Diagnostics.shared.snapshot(); ErrorReports.shared.save() }
                        store.cloudSync?.flushPending()
                        // [mi3s] 二开：后台听视频关掉时，进后台就把画面停掉。
                        // 开着时什么都不做 —— 会话本来就是 .playback 类别、Info.plist 里有 audio
                        // 后台模式，系统会让它继续出声，画面由系统自己停。
                        // 不在这里 setActive(false)：那会把正在播的音轨一起掐掉，
                        // 再回到前台还要重新起一次，接不上。
                        #if os(iOS)
                        // `BiliPlayerExtras` 定义在 BiliSkin.swift（iOS-only）。
                        // tvOS/macOS 没有「后台听视频」这个二开开关，跳过即可。
                        if !BiliPlayerExtras.shared.backgroundAudio {
                            // 不裸取 activeSession（它是 private）：按正在播的 channel 问 Store 要，
                            // channel 一致时它返回的就是那个会话，不会新建。
                            if let channel = store.playing {
                                store.playbackSession(for: channel).player.pause()
                            }
                        }
                        #endif
                        // [mi3s] 二开：隐私保险库退到后台即重新上锁。一次解锁只对给出它的那一刻有效，
                        // 把手机递给别人时被隐藏的源/订阅不会被看到。没有密码时 lock() 是空操作。
                        store.relockVaultOnBackground()
                    }
                    if phase == .active {
                        Task { await ErrorReports.shared.sendIfDue() }
                        // Another viewer may have taken over the Apple TV: ask iCloud for what changed (#584).
                        store.cloudSync?.refresh()
                    }
                    #if os(tvOS) || os(macOS)
                    // Phones only see the TV while the app is open.
                    if phase == .background { BilibiliCastController.shared.stop() }
                    if phase == .active { BilibiliCastController.shared.start(store) }
                    #endif
                    #if os(tvOS)
                    // As for Bilibili casts: other devices only see the TV while the app is open.
                    if phase == .background { PlayOnController.shared.stop() }
                    if phase == .active { PlayOnController.shared.start(store) }
                    #endif
                    #if !os(macOS)
                    if phase == .background { DownloadsLifecycle.enteredBackground() }
                    if phase == .active { DownloadsLifecycle.becameActive() }
                    #endif
                    // Apple TV and Mac sessions run for days; look again when the app comes back.
                    if phase == .active { Task { await updates.check(); await announcements.check() } }
                }
                #if os(tvOS)
                .preferredColorScheme(.dark)
                #endif
                #if os(macOS)
                .frame(minWidth: 920, minHeight: 640)
                #endif
                // Outside every modifier above, so the import and Douyin sheets get them too: on RootView alone, a
                // yingxia://import link stopped the app ("No Observable object of type Store found", TestFlight 49-51).
                .environment(store).environment(updates).environment(announcements)
        }
        #if os(macOS)
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                if Updates.channel != .none {
                    Button(L10n.text("Check for Updates…")) { Task { await updates.check(manual: true) } }
                        .disabled(updates.checking)
                }
            }
        }
        #endif
        #if os(macOS)
        // The music mini player, floating over other apps at the bottom right; also in the Window menu.
        Window(L10n.text("Mini Player"), id: MusicMacMiniPlayer.windowID) {
            MusicMacMiniPlayer().environment(store).tint(Brand.accent)
        }
        .windowStyle(.plain)
        .windowLevel(.floating)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultWindowPlacement { content, context in
            let size = content.sizeThatFits(.unspecified)
            let screen = context.defaultDisplay.visibleRect
            return WindowPlacement(CGPoint(x: screen.maxX - size.width - 20, y: screen.maxY - size.height - 20), size: size)
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        #endif
    }
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The player's rotate button narrows this to landscape (see PlayerOrientation).
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { PlayerOrientation.mask }
    }
}
#endif

#if !os(tvOS)
/// What a `yingxia://import?url=` link opens: the subscription it names, and the viewer's agreement. A page
/// can point at a subscription, but nothing is downloaded before Add (#167).
struct SubscriptionImportView: View {
    let link: SubscriptionImportLink
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var failure: String?
    /// What the import added, shown before the sheet closes: a directory's subscriptions arrive switched off.
    @State private var added: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 40)).foregroundStyle(Brand.accent)
                    .frame(maxWidth: .infinity)
                Text(L10n.text("Add This Subscription?"))
                    .font(.title3.weight(.bold)).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 10) {
                    field(L10n.text("Subscription URL"), link.address.absoluteString)
                    if let name = link.name { field(L10n.text("Name"), name) }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentPanel(cornerRadius: 16)
                Text(L10n.text("A page can only ask: Yingxia adds this subscription after you agree, never on its own."))
                    .font(.footnote).foregroundStyle(.secondary)
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(Brand.amber)
                }
                if let added {
                    Label(added, systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.green)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background { Backdrop() }
            .navigationTitle(L10n.text("Subscription"))
            .toolbar {
                if added == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.text("Cancel")) { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if added != nil { Button(L10n.text("Done")) { dismiss() }.fontWeight(.semibold) }
                    // Settings may be importing already, and the store takes one import at a time.
                    else if adding || store.importing { ProgressView() }
                    else { Button(L10n.text("Add"), action: add).fontWeight(.semibold) }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
        }
    }

    private func add() {
        adding = true; failure = nil
        Task {
            await store.importSubscription(address: link.address.absoluteString, name: link.name)
            adding = false
            // Settings shows these too; here they say what did or did not arrive.
            if let error = store.importError { failure = error } else { added = store.notice ?? L10n.text("Done") }
        }
    }
}
#endif

/// 启动时读一次 Loon 的运行配置，把「端口段规则指向哪个策略组」写进日志。
///
/// 为什么需要它：观众看到的现象是「标了代理也不能播」，而真正决定走不走节点的
/// 是 Loon 自己 —— 我们的代理腿只是把连接交给 Loon，Loon 再按自己的规则判。
/// 规则若把 `SRC-PORT 41500-41599` 指向一个「直连」的策略组（或 FINAL 就是直连），
/// 那么代理腿和直连腿都出不去，App 侧怎么改都没用。
/// 这条日志把「Loon 到底怎么判我们的端口」变成可核对的证据，而不是靠猜。
enum LoonConfigProbe {
    static func logOnce() {
        guard let endpoint = CustomProxyStore.shared.endpoints.first else { return }
        // 候选顺序：按当前网络重算的地址 → 它的退路 → 端点里存的原始地址。
        // 只试第一个会在「Loon 在别的机器上」时误报读不到；三条都失败才值得报警。
        let plan = LocalNetwork.plan(stored: endpoint.host, currentIPv4: LocalNetwork.currentIPv4)
        let apiPort = endpoint.port == 7221 ? 7222 : endpoint.port
        var urls: [URL] = []
        for host in [plan.primary, plan.fallback, endpoint.host].compactMap({ $0 }) {
            var components = URLComponents()
            components.scheme = "http"
            components.host = host
            components.port = apiPort
            components.path = "/loonapi/v1/config/file.conf"
            if let url = components.url, !urls.contains(url) { urls.append(url) }
        }
        guard !urls.isEmpty else { return }
        Task {
            var lastError: Error?
            for url in urls {
                do {
                    let preset = try await LoonPreset.load(from: url)
                    // 记住规则指向的组名：设置页「Copy Loon Rule」要按这个组名生成强制节点规则。
                    ForcedNodeHosts.shared.targetGroup = preset.portRuleTarget
                    Diagnostics.shared.record(.info, "egress",
                        "loon config host=\(url.host ?? "-") wifi=\(preset.sharesOnLAN)"
                        + " http=\(preset.httpPort) socks=\(preset.socksPort)"
                        + " portRule=\(String(describing: preset.portRule))"
                        + " target=\(preset.portRuleTarget ?? "-")"
                        + " directLine=\(preset.hasDirectLine)"
                        + " nodeTypes=\(preset.nodeProtocols.joined(separator: ","))"
                        + " ciphers=\(preset.nodeCiphers.joined(separator: ","))"
                        + " legacyWide=\(preset.hasLegacyWideRange)")
                    probeRuntimeAPI(host: url.host ?? "127.0.0.1", port: apiPort)
                    return
                } catch {
                    lastError = error
                }
            }
            if let lastError {
                let tried = urls.compactMap(\.host).joined(separator: "/")
                Diagnostics.shared.record(.warning, "egress",
                    "could not read Loon's config at \(tried):\(apiPort) — \(lastError.localizedDescription)")
            }
        }
    }
    /// 探查 Loon 的**运行态**读接口。
    ///
    /// 「当前选中哪个节点」不在 `file.conf` 里（那是配置，只有节点定义与组成员），
    /// 而观众要的是「App 自动用我正在用的那个节点」。所以先问清楚 Loon 到底暴露了哪些
    /// 只读接口、返回什么形状 —— 有就接上，没有就用配置里唯一那台/默认出口。
    /// 只发 GET、只看状态码与前几十个字节，不写任何东西（写动词会断连，实测过）。
    static func probeRuntimeAPI(host: String, port: Int) {
        let paths = ["/loonapi/v1/proxies", "/loonapi/v1/policy", "/loonapi/v1/groups",
                     "/loonapi/v1/proxy-groups", "/loonapi/v1/status", "/loonapi/v1/config",
                     "/loonapi/v1/traffic", "/loonapi/v1/requests"]
        Task {
            for path in paths {
                var components = URLComponents()
                components.scheme = "http"
                components.host = host
                components.port = port
                components.path = path
                guard let url = components.url else { continue }
                var request = URLRequest(url: url, timeoutInterval: 3)
                request.httpMethod = "GET"
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      let http = response as? HTTPURLResponse else {
                    Diagnostics.shared.record(.debug, "egress", "loon api \(path) unreachable")
                    continue
                }
                let head = String(decoding: data.prefix(120), as: UTF8.self)
                    .replacingOccurrences(of: "\n", with: " ")
                Diagnostics.shared.record(.info, "egress",
                    "loon api \(path) status=\(http.statusCode) bytes=\(data.count) head=\(head)")
            }
        }
    }

}
