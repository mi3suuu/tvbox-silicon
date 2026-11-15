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
                    // ★ 无条件清理 QA 换皮残留 —— 必须放在 QA 门控**之前**。
                    // 写它的要 QA 启动、清它的也要 QA 启动时，就永远解不开；
                    // 真机实证过「选 One 无效、杀进程重进还是哔哩哔哩」。
                    QALaunch.consumeStickyQASkin()
                    #if DEBUG
                    if QALaunch.section != nil || QALaunch.page != nil { await QALaunch.start(store); return }
                    #endif
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
