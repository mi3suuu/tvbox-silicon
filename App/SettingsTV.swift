import SwiftUI
import TVCore

#if os(tvOS)
// The TV has its own settings layout (`SettingsPage` plus `SettingsGroup`), so the row views above
// live in the iPhone/Mac-only block. Two pages are shared with them — the privacy vault and the
// subtitle style — and both ask for this row. Give the TV the same two pieces, drawn as a plain
// label, which is what a group row looks like there anyway.
struct FormLabel: View {
    let symbol: String
    var tint: Color = .gray
    let title: String
    var subtitle: String? = nil
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}

extension View {
    /// Tinting a switch green is an iPhone idiom; on the TV the system draws it.
    @ViewBuilder func settingsSwitch() -> some View { self }

    /// The Mac needs a plain button style inside a form; every other platform leaves the row alone.
    @ViewBuilder func formRowButton() -> some View { self }
}
#endif

#if os(tvOS)
// MARK: Settings on Apple TV
// Laid out like the system's own Settings: the app on the left, a list on the right. Every row is
// one press of the remote: its current value sits at the trailing edge, a switch flips in place,
// and anything that needs typing or choosing opens a page of its own.

struct TVSettingsView: View {
    @Environment(Store.self) private var store
    @Environment(Updates.self) private var updates
    @State private var cloudSummary = ""
    @State private var bilibiliSummary = ""
    @State private var douyinSummary = ""
    @AppStorage(DanmakuPreference.key) private var showsDanmaku = true
    @AppStorage(DanmakuArea.key) private var danmakuArea = DanmakuArea.standard
    @AppStorage(VideoEnhancement.upscaleKey) private var upscalesVideo = false
    @AppStorage(VideoEnhancement.smoothKey) private var smoothsVideo = false
    @AppStorage(BilibiliCastController.key) private var receivesCasts = true
    @AppStorage(PlayOnController.key) private var receivesPlayOn = true
    @AppStorage(PlaybackInfo.key) private var showsPlaybackInfo = false
    @AppStorage(ErrorReports.key) private var sendsErrorReports = true
    @AppStorage(TMDBMatch.key) private var looksUpTMDB = true
    @AppStorage(CloudSync.enabledKey) private var syncsWithICloud = true

    var body: some View {
        TVSettingsLayout {
            TVSettingsHero()
        } list: {
            if !updates.available.isEmpty { updateSection }
            // First in the list, beside the app: a problem or an idea is one press away.
            TVSettingsSection {
                TVSettingsLink(title: L10n.text("Send Feedback")) { FeedbackView() }
                TVSettingsLink(title: L10n.text("Telegram Group")) { TelegramGroupView() }
            }
            subscriptionSection
            TVSettingsSection(title: L10n.text("Accounts")) {
                if store.extrasUnlocked {
                    TVSettingsLink(title: L10n.text("Bilibili"), value: bilibiliSummary) { BilibiliAccountView() }
                    TVSettingsLink(title: L10n.text("Douyin"), value: douyinSummary) { DouyinAccountView() }
                }
                TVSettingsLink(title: L10n.text("Cloud Drive Accounts"), value: cloudSummary) { CloudDriveView() }
            }
            TVSettingsSection(footer: L10n.text("Keeps favorites, Continue Watching, subscriptions, and the sources you pinned, hid or ordered the same on your devices signed in to the same iCloud account. Accounts, passwords and downloads stay on each device.")) {
                TVSettingsToggle(title: L10n.text("iCloud Sync"), isOn: $syncsWithICloud)
                    .onChange(of: syncsWithICloud) { _, on in store.cloudSync?.setEnabled(on) }
            }
            TVSettingsSection {
                TVSettingsLink(title: L10n.text("Watch Now")) { WatchNowSettingsView() }
            }
            TVSettingsSection(title: L10n.text("Playback"), footer: playbackFooter) {
                if store.extrasUnlocked {
                    TVSettingsToggle(title: L10n.text("Show Danmaku"), isOn: $showsDanmaku)
                    TVSettingsAction(title: L10n.text("Danmaku Area"), value: danmakuArea.title) { danmakuArea = danmakuArea.next }
                    TVSettingsToggle(title: L10n.text("Cast from the Bilibili App"), isOn: $receivesCasts)
                        .onChange(of: receivesCasts) { _, on in
                            if on { BilibiliCastController.shared.start(store) } else { BilibiliCastController.shared.stop() }
                        }
                }
                TVSettingsToggle(title: L10n.text("Play from Other Devices"), isOn: $receivesPlayOn)
                    .onChange(of: receivesPlayOn) { _, on in
                        if on { PlayOnController.shared.start(store) } else { PlayOnController.shared.stop() }
                    }
                TVSettingsLink(title: L10n.text("Play a URL")) { TVPlayURLPage() }
            }
            TVSettingsSection(footer: L10n.text("Shows the video's format, resolution, frame rate and bitrate in a corner of the player.")) {
                // 上游 #547 的字幕外观页在 tvOS 上同样丢了入口（上游 SettingsView.swift:1594 有一行
                // `TVSettingsLink(title: "Subtitle Style")`）。补在这里，紧挨"Show Video Info"——
                // 两者都是播放画面上看得见的东西，放在同一节里最顺手。
                TVSettingsLink(title: L10n.text("Subtitle Style")) { SubtitleStyleView() }
                TVSettingsToggle(title: L10n.text("Show Video Info"), isOn: $showsPlaybackInfo)
            }
            if VideoEnhancement.canUpscale || VideoEnhancement.canSmooth {
                TVSettingsSection(title: L10n.text("Picture"), footer: VideoEnhancement.note) {
                    if VideoEnhancement.canUpscale { TVSettingsToggle(title: L10n.text("Sharper Picture"), isOn: $upscalesVideo) }
                    if VideoEnhancement.canSmooth { TVSettingsToggle(title: L10n.text("Smooth Motion (60 fps)"), isOn: $smoothsVideo) }
                }
            }
            TVSettingsSection(title: L10n.text("Advanced"),
                              footer: L10n.text("Sends errors to the developer a few times a day so they can be fixed: the error text with web addresses cut to the server name, the app and system versions, and a random ID. Never your accounts, passwords or viewing history.")) {
                TVSettingsLink(title: L10n.text("Local Cache")) { CacheSettingsView() }
                if store.extrasUnlocked { TVSettingsLink(title: L10n.text("JAR Runtime and Compatibility")) { RuntimeView() } }
                // [mi3s] 二开：自己的出口代理（HTTP/HTTPS/SOCKS5），与手机/Mac 同一个页面。
                TVSettingsLink(title: L10n.text("Proxy")) { ProxySettingsView() }
                TVSettingsLink(title: L10n.text("Diagnostic Logs")) { DiagnosticsView() }
                // The same page the phone and the Mac reach from Advanced: what is hidden, and the
                // passcode that guards it. Without a row here the TV could apply a vault it had no
                // way to edit.
                TVSettingsLink(title: L10n.text("Privacy Vault")) { PrivacyVaultView() }
                TVSettingsLink(title: L10n.text("Resource Order")) { ResourceRankingView() }
                TVSettingsToggle(title: L10n.text("Send Error Reports"), isOn: $sendsErrorReports)
                    .onChange(of: sendsErrorReports) { _, on in if !on { ErrorReports.shared.discard() } }
                TVSettingsToggle(title: L10n.text("Look Up Titles on TMDB"), isOn: $looksUpTMDB)
            }
            if updates.available.isEmpty, Updates.channel != .none { updateSection }
            if store.extrasUnlocked { ContributorsSection() }
            TVSettingsSection(title: L10n.text("About"),
                              footer: store.extrasUnlocked ? L10n.text("Supports TVBox JSON subscriptions, M3U / TXT live playlists, and standard type 1 / type 4 JSON APIs. Media formats depend on the device. Local JavaScript and Python plugins are experimental on Mac, and JAR plugins are experimental on every platform; compatibility varies by source.") : nil) {
                TVSettingsLink(title: L10n.text("Open Source Licenses")) { LicensesView() }
            }
        }
        .tabTitle(L10n.text("Settings"))
        // Refreshed whenever Settings reappears, so a sign-in on the account page shows here.
        .onAppear { bilibiliSummary = BilibiliAccount.load().summary; douyinSummary = DouyinAccount.load().summary; cloudSummary = CloudProvider.summary() }
        .task(id: store.extrasUnlocked) { if store.extrasUnlocked { await ContributorList.shared.check() } }
    }

    private var playbackFooter: String {
        let phones = L10n.text("With Mi3s open here, your other devices on the same network can send it what they play: tap Play On in their player.")
        guard store.extrasUnlocked else { return phones }
        return L10n.text("With your phone on the same network, tap the TV button in a Bilibili video and choose %@.", L10n.text("Mi3s")) + "\n" + phones
    }

    private var subscriptionSection: some View {
        TVSettingsSection(title: L10n.text("Subscriptions"), footer: store.notice) {
            ForEach(store.environmentSubscriptions) { entry in
                let failed = store.subscriptionErrors[entry.address] != nil
                TVSettingsLink(title: entry.title, value: store.subscriptionValue(entry), warning: failed) { TVSubscriptionPage(entry: entry) }
            }
            TVSettingsLink(title: L10n.text("Add Subscription")) { TVAddSubscriptionPage() }
            if store.environmentSubscriptions.count > 1 { TVSettingsLink(title: L10n.text("Remove Subscriptions")) { TVRemoveSubscriptionsPage() } }
            if !store.environmentSubscriptions.isEmpty {
                TVSettingsAction(title: L10n.text("Refresh All"),
                                 value: store.importing ? L10n.text("Importing…") : store.subscription.map { $0.importedAt.formatted(date: .abbreviated, time: .shortened) },
                                 busy: store.importing) { Task { await store.refreshSubscriptions() } }
                    .disabled(store.importing)
            }
        }
    }

    private var updateSection: some View {
        TVSettingsSection(title: L10n.text("Software Update")) {
            if let title = updates.availableTitle {
                Button(action: updates.show) {
                    TVSettingsRowLabel(title: title, chevron: true) { NewBadge() }
                }.glassRow()
            } else {
                TVSettingsAction(title: L10n.text("Check Now"),
                                 value: updates.checking ? L10n.text("Checking…") : updates.lastChecked.map { L10n.text("Last checked %@", $0.formatted(date: .abbreviated, time: .shortened)) },
                                 busy: updates.checking) { Task { await updates.check(manual: true) } }
                    .disabled(updates.checking)
            }
            if !updates.currentNotes.isEmpty {
                Button(action: updates.showCurrentNotes) {
                    TVSettingsRowLabel(title: L10n.text("What's New in Version %@", updates.displayVersion), chevron: true)
                }.glassRow()
            }
        }
    }
}

/// The page frame: a hero column on the left, vertically centred, and the scrolling list on the right.
struct TVSettingsLayout<Hero: View, List: View>: View {
    @ViewBuilder var hero: Hero
    @ViewBuilder var list: List
    var body: some View {
        HStack(alignment: .center, spacing: 72) {
            hero.frame(width: 560).frame(maxHeight: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 48) { list }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassRowInsets()
                    .padding(.vertical, 40)
            }
            .scrollClipDisabled()
            .tvFocusSection()
        }
        .padding(.horizontal, Layout.gutter)
        .screenBackdrop()
    }
}

/// The app as the left column of Settings: its icon, name, version and credit.
private struct TVSettingsHero: View {
    private var version: String? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : L10n.text("Version %@", $0) }
    }
    var body: some View {
        VStack(spacing: 34) {
            AppMark(size: 300)
            VStack(spacing: 10) {
                Text(L10n.text("Mi3s")).font(.system(size: 48, weight: .bold))
                if let version { Text(version).font(.system(size: 26)).foregroundStyle(.secondary) }
                Text(Brand.copyright).font(.system(size: 22)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A titled run of rows with an optional note under it.
struct TVSettingsSection<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title).font(.system(size: 25, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.leading, 28).padding(.bottom, 6).accessibilityAddTraits(.isHeader)
            }
            content
            if let footer, !footer.isEmpty {
                Text(footer).font(.system(size: 22)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28).padding(.top, 8)
            }
        }
    }
}

/// The title on the leading edge; the current value, an accessory and a chevron on the trailing one.
struct TVSettingsRowLabel<Accessory: View>: View {
    let title: String
    /// A line under the title, saying what the row is about.
    var detail: String? = nil
    var value: String? = nil
    var warning = false
    var busy = false
    var chevron = false
    @ViewBuilder var accessory: Accessory
    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 29, weight: .medium)).lineLimit(1)
                if let detail { Text(detail).font(.system(size: 22)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .layoutPriority(1)
            Spacer(minLength: 32)
            if busy { ProgressView() }
            if let value, !value.isEmpty {
                Text(value).font(.system(size: 27)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(warning ? AnyShapeStyle(Brand.amber) : AnyShapeStyle(.secondary))
            }
            accessory
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: 22, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension TVSettingsRowLabel where Accessory == EmptyView {
    init(title: String, detail: String? = nil, value: String? = nil, warning: Bool = false, busy: Bool = false, chevron: Bool = false) {
        self.init(title: title, detail: detail, value: value, warning: warning, busy: busy, chevron: chevron) { EmptyView() }
    }
}

/// A row that opens a page.
struct TVSettingsLink<Destination: View>: View {
    let title: String
    var value: String? = nil
    var warning = false
    @ViewBuilder var destination: () -> Destination
    var body: some View {
        RouteLink(destination: destination) { TVSettingsRowLabel(title: title, value: value, warning: warning, chevron: true) }
            .glassRow()
    }
}

/// A switch as a row: selecting it flips the value shown at the trailing edge.
struct TVSettingsToggle: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: { TVSettingsRowLabel(title: title, detail: detail, value: L10n.text(isOn ? "On" : "Off")) }
            .glassRow()
            .accessibilityValue(L10n.text(isOn ? "On" : "Off"))
    }
}

/// A row that does something in place.
struct TVSettingsAction: View {
    let title: String
    var value: String? = nil
    var busy = false
    var destructive = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            TVSettingsRowLabel(title: title, value: value, busy: busy).foregroundStyle(destructive ? Brand.rose : Color.primary)
        }
        .glassRow()
    }
}

/// Text entry as a row: the title and the current text, like any other row. A focused tvOS text
/// field always draws the system's white platter, which sat inside the glass row as a box in a box,
/// so selecting the row opens the system's text entry instead, as Wi-Fi passwords do.
struct TVSettingsField: View {
    let title: String
    @Binding var text: String
    /// Words rather than an address: the usual keyboard, with capitals and corrections.
    var prose = false
    /// 密码类字段（cookie/token/密码）。iOS 侧用 `SecureField`，tvOS 没有该控件，
    /// 但电视上这些值同样不该明文摆在屏幕上 —— 用圆点遮住当前值，编辑仍走弹窗输入。
    var secret = false
    @State private var editing = false
    @State private var draft = ""
    @State private var cancelled = false

    /// 行尾显示的值：secret 且非空时遮蔽，与 iOS `SecureField` 的观感一致。
    private var displayValue: String {
        if text.isEmpty { return L10n.text("Not set") }
        return secret ? String(repeating: "•", count: min(text.count, 12)) : text
    }

    var body: some View {
        Button { draft = text; cancelled = false; editing = true } label: {
            TVSettingsRowLabel(title: title, value: displayValue)
        }
        .glassRow()
        .alert(title, isPresented: $editing) {
            TextField(title, text: $draft)
                .autocorrectionDisabled(!prose)
                .textInputAutocapitalization(prose ? .sentences : .never).keyboardType(prose ? .default : .URL)
            Button(L10n.text("Done")) {}
            Button(L10n.text("Cancel"), role: .cancel) { cancelled = true }
        }
        // Closing the alert any way but Cancel keeps the text. tvOS 18 also shows the text field as a second
        // button under it, which closes the alert without running any action, so a typed address was lost (#291).
        .onChange(of: editing) { _, open in
            if !open, !cancelled { text = draft.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }
}

/// A page under Settings: a large symbol and title on the left, its rows on the right.
struct TVSettingsSubpage<Content: View>: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        TVSettingsLayout {
            VStack(spacing: 30) {
                Image(systemName: symbol).font(.system(size: 120, weight: .regular)).foregroundStyle(.secondary)
                    .frame(height: 180)
                VStack(spacing: 10) {
                    Text(title).font(.system(size: 44, weight: .bold)).multilineTextAlignment(.center).lineLimit(2)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 24)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        } list: { content }
        .screenTitle("")
    }
}

/// One subscription: switch it on or off, move it (earlier subscriptions win duplicate sources), or remove it.
private struct TVSubscriptionPage: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let entry: SubscriptionEntry
    @State private var confirmsRemoval = false
    var body: some View {
        let current = store.environmentSubscriptions.first { $0.address == entry.address } ?? entry
        let index = store.environmentSubscriptions.firstIndex { $0.address == entry.address } ?? 0
        let failure = store.subscriptionErrors[entry.address]
        let copy = store.documents[entry.address]
        TVSettingsSubpage(symbol: "list.bullet.rectangle", title: current.title, subtitle: current.address) {
            TVSettingsSection(title: L10n.text("Subscription"),
                              footer: failure.map { L10n.text("Couldn't refresh: %@", $0) }
                                ?? copy.map { L10n.text("Sources: %lld · Live playlists: %lld", $0.sites.count, $0.lives.count) }) {
                TVSettingsToggle(title: L10n.text("Use This Subscription"),
                                 isOn: Binding(get: { current.enabled }, set: { on in Task { await store.setSubscription(current, enabled: on) } }))
                    .disabled(store.importing)
                TVSettingsField(title: L10n.text("Name"), text: Binding(get: { current.name }, set: { store.renameSubscription(current, to: $0) }))
            }
            if store.environmentSubscriptions.count > 1 {
                TVSettingsSection(title: L10n.text("Order")) {
                    if index > 0 { TVSettingsAction(title: L10n.text("Move Up")) { store.moveSubscription(current, by: -1) } }
                    if index < store.environmentSubscriptions.count - 1 { TVSettingsAction(title: L10n.text("Move Down")) { store.moveSubscription(current, by: 1) } }
                }
            }
            if store.environments.all.count > 1 {
                TVSettingsSection(title: L10n.text("Copy to Environment"),
                                  footer: L10n.text("Copies the subscription into another environment. Each environment keeps its own subscriptions, history and watchlist; nothing is shared.")) {
                    ForEach(store.environments.all.filter { $0.id != store.environments.activeID }) { environment in
                        TVSettingsAction(title: environment.name) {
                            store.copySubscription(current, to: environment.id)
                        }
                        .disabled(store.subscriptions(in: environment.id).contains { $0.address == current.address })
                    }
                }
            }
            TVSettingsSection(title: L10n.text("Remove")) {
                TVSettingsAction(title: L10n.text("Remove"), destructive: true) { confirmsRemoval = true }
            }
        }
        .confirmationDialog(L10n.text("Remove"), isPresented: $confirmsRemoval) {
            Button(L10n.text("Remove"), role: .destructive) { store.removeSubscription(current); dismiss() }
        }
    }
}

/// Removing many subscriptions at once: tick them, or take all or the switched-off ones, then remove.
private struct TVRemoveSubscriptionsPage: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var confirmsRemoval = false
    var body: some View {
        let chosen = store.environmentSubscriptions.filter { selection.contains($0.address) }
        let all = chosen.count == store.environmentSubscriptions.count
        let off = store.environmentSubscriptions.filter { !$0.enabled }.map(\.address)
        TVSettingsSubpage(symbol: "trash", title: L10n.text("Remove Subscriptions")) {
            TVSettingsSection {
                TVSettingsAction(title: L10n.text(all ? "Deselect All" : "Select All")) { selection = all ? [] : Set(store.environmentSubscriptions.map(\.address)) }
                if !off.isEmpty { TVSettingsAction(title: L10n.text("Select Turned-Off Subscriptions")) { selection = Set(off) } }
            }
            TVSettingsSection(title: L10n.text("Subscriptions")) {
                ForEach(store.environmentSubscriptions) { entry in
                    let selected = selection.contains(entry.address)
                    Button {
                        if selected { selection.remove(entry.address) } else { selection.insert(entry.address) }
                    } label: {
                        TVSettingsRowLabel(title: entry.title, value: store.subscriptionValue(entry)) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 30))
                        }
                    }
                    .glassRow()
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            TVSettingsSection {
                TVSettingsAction(title: L10n.text("Remove %lld Subscriptions", chosen.count), destructive: true) { confirmsRemoval = true }
                    .disabled(chosen.isEmpty || store.importing)
            }
        }
        .confirmationDialog(L10n.text("Remove %lld Subscriptions", chosen.count), isPresented: $confirmsRemoval) {
            Button(L10n.text("Remove"), role: .destructive) { store.removeSubscriptions(Set(chosen.map(\.address))); dismiss() }
        }
    }
}

/// Adding a subscription: the address, then add it or fill in the default one.
private struct TVAddSubscriptionPage: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var store = store
        let empty = store.subscriptionAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        TVSettingsSubpage(symbol: "plus.rectangle.on.rectangle", title: L10n.text("Add Subscription")) {
            TVSettingsSection(title: L10n.text("Subscription"), footer: store.importError ?? store.notice) {
                TVSettingsField(title: L10n.text("Subscription URL (TVBox JSON, M3U or TXT)"), text: $store.subscriptionAddress)
                TVSettingsField(title: L10n.text("Name (optional)"), text: $store.subscriptionName)
                TVSettingsAction(title: store.importing ? L10n.text("Importing…") : L10n.text("Add Subscription"), busy: store.importing) {
                    Task {
                        let before = store.subscriptions.count
                        await store.importSubscription()
                        if store.importError == nil, store.subscriptions.count > before { dismiss() }
                    }
                }
                .disabled(store.importing || empty)
                TVSettingsAction(title: L10n.text("Use a Demo URL")) { store.subscriptionAddress = Store.defaultURL }
            }
        }
    }
}

/// Playing a media address directly.
private struct TVPlayURLPage: View {
    @Environment(Store.self) private var store
    @State private var address = ""
    var body: some View {
        TVSettingsSubpage(symbol: "play.rectangle", title: L10n.text("Play a URL")) {
            TVSettingsSection(title: L10n.text("Playback")) {
                TVSettingsField(title: L10n.text("HTTP / HTTPS media URL"), text: $address)
                TVSettingsAction(title: L10n.text("Open Player")) {
                    do { store.playing = Channel(name: L10n.text("URL Playback"), url: try WebAddress.resolve(address)) }
                    catch { store.error = error.localizedDescription }
                }
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
#endif

#if os(tvOS)
extension View {
    /// Apple TV has no grouped settings form and no page chrome of its own inside a settings
    /// subpage: the TV draws the title and the rows already, so this only has to exist.
    ///
    /// The pages it is applied to are shared with the phone and the Mac, where the grouped form and
    /// the screen title are what make them look like Settings.
    func settingsForm(_ title: String) -> some View { self }
}
#endif
