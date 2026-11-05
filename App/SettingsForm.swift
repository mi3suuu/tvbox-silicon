import SwiftUI
import TVCore
import UniformTypeIdentifiers

#if !os(tvOS)
// MARK: Settings on iPhone, iPad and Mac
// A native grouped form, as in the Settings app and System Settings: the app as the first card,
// icon-led rows that show their current value, switches in place, and subpages for the rest.

enum FormMetrics {
    #if os(macOS)
    static let icon: CGFloat = 22, symbol: CGFloat = 11, hero: CGFloat = 52
    #else
    static let icon: CGFloat = 30, symbol: CGFloat = 14, hero: CGFloat = 64
    #endif
}

/// The tile that leads a row: a coloured symbol on grey on iPhone and iPad, white on colour on the Mac.
struct SettingsIcon: View {
    let symbol: String
    var tint: Color = .gray
    var body: some View {
        #if os(iOS)
        // Black (Douyin) would vanish in dark mode, so it follows the text colour.
        Image(systemName: symbol)
            .font(.system(size: FormMetrics.symbol, weight: .semibold)).foregroundStyle(tint == .black ? Color.primary : tint)
            .frame(width: FormMetrics.icon, height: FormMetrics.icon)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: FormMetrics.icon * 0.26, style: .continuous))
            .accessibilityHidden(true)
        #else
        Image(systemName: symbol)
            .font(.system(size: FormMetrics.symbol, weight: .semibold)).foregroundStyle(.white)
            .frame(width: FormMetrics.icon, height: FormMetrics.icon)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: FormMetrics.icon * 0.26, style: .continuous))
            .accessibilityHidden(true)
        #endif
    }
}

/// Icon tile, title and an optional second line.
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
        } icon: { SettingsIcon(symbol: symbol, tint: tint) }
    }
}

/// A row that opens a page, with its current value before the chevron.
struct FormLink<Destination: View>: View {
    let symbol: String
    var tint: Color = .gray
    let title: String
    var value: String? = nil
    var warning = false
    @ViewBuilder var destination: () -> Destination
    var body: some View {
        RouteLink(destination: destination) {
            #if os(iOS)
            // One line, as in the Settings app: the title keeps its width and a long value is cut
            // short; LabeledContent dropped the value under the title instead.
            HStack(spacing: 8) {
                FormLabel(symbol: symbol, tint: tint, title: title).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 0)
                if let value, !value.isEmpty { valueText(value) }
            }
            #else
            LabeledContent {
                if let value, !value.isEmpty { valueText(value) }
            } label: { FormLabel(symbol: symbol, tint: tint, title: title) }
            #endif
        }
    }
    private func valueText(_ value: String) -> some View {
        Text(value).lineLimit(1).foregroundStyle(warning ? AnyShapeStyle(Brand.amber) : AnyShapeStyle(.secondary))
    }
}

/// A row that opens a web page outside the app, with an arrow where other rows have a chevron.
struct SettingsWebRow: View {
    let symbol: String
    var tint: Color = .gray
    let title: String
    var subtitle: String? = nil
    let url: URL
    @Environment(\.openURL) private var openURL
    var body: some View {
        Button { openURL(url) } label: {
            HStack(spacing: 8) {
                FormLabel(symbol: symbol, tint: tint, title: title, subtitle: subtitle).foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        #if os(macOS)
        .buttonStyle(.plain)
        #else
        // A button in a list draws its title in the tint; this one reads like the rows around it.
        .tint(.primary)
        #endif
    }
}

extension View {
    /// A button that fills its row: tinted text on iPhone, a plain clickable row on the Mac, where a
    /// form would otherwise draw a push button around the whole label.
    @ViewBuilder func formRowButton() -> some View {
        #if os(macOS)
        buttonStyle(.plain).contentShape(Rectangle())
        #else
        self
        #endif
    }
    /// Settings as the system draws them, like System Settings and the Settings app: the system's
    /// grouped background and row fills, and the system accent on switches and buttons instead of
    /// the app's neutral one. The scroll view spans the page and margins centre the rows; a narrowed
    /// frame left the toolbar's scroll edge as a band over the middle column only.
    func settingsForm(_ title: String) -> some View {
        GeometryReader { proxy in
            let extra = (proxy.size.width - Layout.settingsWidth) / 2
            let form = formStyle(.grouped).tint(systemAccent)
                #if os(iOS)
                // The app's navy canvas, as on every other page, instead of the system's black.
                .scrollContentBackground(.hidden)
                .background { Backdrop() }
                #endif
            // Only when there is room to spare: a zero margin would replace the system's own insets.
            if extra > 0 { form.contentMargins(.horizontal, extra, for: .scrollContent) } else { form }
        }
        .screenTitle(title, width: Layout.settingsWidth)
    }
    /// Rows in the app's fill on iPhone and iPad; the Mac keeps System Settings' own.
    @ViewBuilder func settingsRows() -> some View {
        #if os(iOS)
        listRowBackground(SettingsStyle.rowFill)
        #else
        self
        #endif
    }
    /// Switches in the system's own colour: green on iPhone and iPad, the accent on the Mac. Every switch on
    /// iPhone and iPad takes it: the neutral accent is near-white in Dark Mode, so a switch tinted with it turned white.
    @ViewBuilder func settingsSwitch() -> some View {
        #if os(iOS)
        tint(.green)
        #else
        self
        #endif
    }
}

/// The notes under settings switches, shared by Settings and the pages under it.
enum SettingsNote {
    static var playbackInfo: String { L10n.text("Shows the video's format, resolution, frame rate and bitrate in a corner of the player.") }
    static var danmaku: String { L10n.text("Bilibili's bullet comments, drawn over the video. You can also switch them in the player.") }
    static var tmdb: String {
        L10n.text("Shows cast, artwork and episode details from TMDB on video pages. Sends the video's title, its details from the source and the source's name to Mi3s's lookup service, never your accounts or subscription addresses.")
    }
    static var errorReports: String {
        L10n.text("Sends errors to the developer a few times a day so they can be fixed: the error text with web addresses cut to the server name, the app and system versions, and a random ID. Never your accounts, passwords or viewing history.")
    }
    static var iCloud: String {
        L10n.text("Keeps favorites, Continue Watching, subscriptions, and the sources you pinned, hid or ordered the same on your devices signed in to the same iCloud account. Accounts, passwords and downloads stay on each device.")
    }
    static var privacyVault: String {
        L10n.text("Hides the subscriptions and sources you choose behind a passcode. Hidden sources stay out of the list, search, and Continue Watching until the vault is unlocked.")
    }
    static var appSwitcher: String {
        L10n.text("While the app is in the background, the app switcher shows a lock instead of what was on screen.")
    }
    static var support: String {
        L10n.text("Supports TVBox JSON subscriptions, M3U / TXT live playlists, and standard type 1 / type 4 JSON APIs. Media formats depend on the device. Local JavaScript and Python plugins are experimental on Mac, and JAR plugins are experimental on every platform; compatibility varies by source.")
    }
}

struct FormSettingsView: View {
    @Environment(Store.self) private var store
    @Environment(Updates.self) private var updates
    @State private var cloudSummary = ""
    @State private var bilibiliSummary = ""
    @State private var douyinSummary = ""
    @AppStorage(DanmakuPreference.key) private var showsDanmaku = true
    @AppStorage(DanmakuArea.key) private var danmakuArea = DanmakuArea.standard
    @AppStorage(VideoEnhancement.upscaleKey) private var upscalesVideo = false
    @AppStorage(VideoEnhancement.smoothKey) private var smoothsVideo = false
    @AppStorage(ErrorReports.key) private var sendsErrorReports = true
    @AppStorage(TMDBMatch.key) private var looksUpTMDB = true
    @AppStorage(CloudSync.enabledKey) private var syncsWithICloud = true
    @AppStorage("refreshSubscriptionsOnLaunch") private var refreshesOnLaunch = false

    /// The ranking in one line — what the Sources page's sort will do — for the row that opens it.
    private var rankingSummary: String {
        let keys = store.resourceRanking.keys
        guard !keys.isEmpty else { return L10n.text("Default") }
        return keys.map { Self.rankingName($0.attribute) + ($0.descending ? " \u{2193}" : " \u{2191}") }.joined(separator: " ")
    }
    private static func rankingName(_ attribute: ResourceRanking.Key.Attribute) -> String {
        switch attribute {
        case .resolution: return L10n.text("Resolution")
        case .bitrate: return L10n.text("Bitrate")
        case .fileSize: return L10n.text("File Size")
        case .colourRange: return L10n.text("Colour Range")
        }
    }
    #if os(macOS)
    @State private var choosesFile = false
    #endif
    #if os(iOS)
    @State private var addingSubscription = false
    @State private var showsFeedback = false
    @State private var choosesConfig = false
    @State private var exportsConfig = false
    @State private var pendingConfig: SubscriptionConfig?
    @State private var choosesFullBackup = false
    @State private var exportsFullBackup = false
    /// Built only when the exporter opens, so the body never runs the disk reads and JSON encoding on every render.
    @State private var exportConfigDocument: ConfigDocument?
    @State private var exportFullBackupDocument: FullBackupDocument?
    @State private var picksBackupCategories = false
    @State private var pendingFullBackup: FullBackup?
    @State private var backupCategories: BackupCategory = .all
    @State private var cloudBackupMode: CloudBackupSheet.Mode?
    @Environment(\.openURL) private var openURL
    @AppStorage(PhoneTabs.labelsKey) private var showsTabLabels = true
    #endif
    #if os(macOS)
    @AppStorage(BilibiliCastController.key) private var receivesCasts = true
    @AppStorage(PlayOnController.key) private var receivesPlayOn = true
    @AppStorage(PlaybackInfo.key) private var showsPlaybackInfo = false
    #endif
    private var version: String? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : L10n.text("Version %@", $0) }
    }

    var body: some View {
        @Bindable var store = store
        ScrollViewReader { proxy in
        Form { Group {
            heroSection

            // Right under the app, so a problem or an idea is never more than one click away.
            #if os(iOS)
            // Two tiles side by side, so the way to the developer reads as a place, not two more rows.
            Section {
                HStack(spacing: 12) {
                    Button { showsFeedback = true } label: {
                        SettingsTile(symbol: "bubble.left.and.text.bubble.right.fill", tint: Brand.indigo, title: L10n.text("Send Feedback"),
                                     subtitle: L10n.text("Report a problem or share an idea"))
                    }
                    Button { openURL(Support.telegram) } label: {
                        SettingsTile(symbol: "paperplane.fill", tint: Brand.cyan, title: L10n.text("Telegram Group"),
                                     subtitle: L10n.text("Chat with the developer and other users"), external: true)
                    }
                }
                // Its own style per button, so each tile takes its own taps rather than the row's.
                .buttonStyle(PressableStyle())
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            #else
            Section {
                SettingsLinkRow(symbol: "bubble.left.and.text.bubble.right.fill", tint: Brand.indigo, title: L10n.text("Send Feedback"),
                                subtitle: L10n.text("Report a problem or share an idea")) { FeedbackView() }
                SettingsWebRow(symbol: "paperplane.fill", tint: Brand.cyan, title: L10n.text("Telegram Group"),
                               subtitle: L10n.text("Chat with the developer and other users"), url: Support.telegram)
            }
            #endif

            Section {
                ForEach(store.environmentSubscriptions) { entry in
                    let failure = store.subscriptionErrors[entry.address]
                    FormLink(symbol: failure == nil ? "list.bullet.rectangle.fill" : "exclamationmark.triangle.fill",
                             tint: failure != nil ? .orange : entry.enabled ? .blue : .gray,
                             title: entry.title, value: store.subscriptionValue(entry), warning: failure != nil) {
                        SubscriptionDetailView(entry: entry)
                    }
                }
                if store.environmentSubscriptions.count > 1 {
                    FormLink(symbol: "trash.fill", tint: .red, title: L10n.text("Remove Subscriptions")) { RemoveSubscriptionsView() }
                    Button { store.setAllSubscriptions(enabled: true) } label: {
                        FormLabel(symbol: "checkmark.circle.fill", tint: .green, title: L10n.text("Enable All Subscriptions")).foregroundStyle(.primary)
                    }
                    Button { store.setAllSubscriptions(enabled: false) } label: {
                        FormLabel(symbol: "circle.dashed", tint: .gray, title: L10n.text("Disable All Subscriptions")).foregroundStyle(.primary)
                    }
                }
                // Every move the viewer made by dragging one source onto another subscription, and
                // the way to undo it. Shown only while there is something to undo.
                if store.sourceReassignment.moveCount > 0 {
                    FormLink(symbol: "arrow.triangle.branch", tint: .purple, title: L10n.text("Moved Sources"),
                             value: String(store.sourceReassignment.moveCount)) { SourceMovesView() }
                        .accessibilityIdentifier("settings.movedSources")
                }
                #if os(iOS)
                // One row instead of an always-open field and three text buttons; the address goes in a sheet.
                Button { addingSubscription = true } label: {
                    FormLabel(symbol: "plus", tint: .green, title: L10n.text("Add Subscription")).foregroundStyle(.primary)
                }
                if !store.environmentSubscriptions.isEmpty {
                    Button { exportsConfig = true } label: {
                        FormLabel(symbol: "square.and.arrow.up", tint: .cyan, title: L10n.text("Export Configuration")).foregroundStyle(.primary)
                    }
                }
                Button { choosesConfig = true } label: {
                    FormLabel(symbol: "square.and.arrow.down", tint: .indigo, title: L10n.text("Import Configuration")).foregroundStyle(.primary)
                }
                // A complete backup: every slice, sign-in state included, not just subscriptions.
                Button { picksBackupCategories = true } label: {
                    FormLabel(symbol: "externaldrive.badge.icloud", tint: .teal, title: L10n.text("Full Backup")).foregroundStyle(.primary)
                }
                Button { choosesFullBackup = true } label: {
                    FormLabel(symbol: "icloud.and.arrow.down", tint: .teal, title: L10n.text("Restore Full Backup")).foregroundStyle(.primary)
                }
                // The cloud-drive leg: write the backup into a signed-in drive and pull it back on
                // another device, no file hand-off needed.
                Button { picksBackupCategories = true; cloudBackupMode = .backup } label: {
                    FormLabel(symbol: "externaldrive.badge.plus", tint: .teal, title: L10n.text("Back Up to Cloud Drive"),
                              subtitle: L10n.text("Into a signed-in Quark, UC, 115, AList or WebDAV")).foregroundStyle(.primary)
                }
                Button { picksBackupCategories = true; cloudBackupMode = .restore } label: {
                    FormLabel(symbol: "externaldrive.badge.checkmark", tint: .teal, title: L10n.text("Restore from Cloud Drive")).foregroundStyle(.primary)
                }
                // The automatic keychain leg: keeps a snapshot that survives uninstall, so a reinstall
                // restores everything without a manual file. Off by default.
                Toggle(isOn: Binding(get: { store.keychainBackupEnabled }, set: { store.keychainBackupEnabled = $0 })) {
                    FormLabel(symbol: "key.fill", tint: .teal, title: L10n.text("Auto-backup to keychain"),
                              subtitle: L10n.text("Survives uninstall and restores automatically"))
                }
                #else
                TextField(L10n.text("Subscription URL (TVBox JSON, M3U or TXT)"), text: $store.subscriptionAddress, prompt: Text(L10n.text("Subscription URL (TVBox JSON, M3U or TXT)")))
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .onSubmit { add() }
                TextField(L10n.text("Name (optional)"), text: $store.subscriptionName, prompt: Text(L10n.text("Name (optional)")))
                    .labelsHidden()
                    .onSubmit { add() }
                subscriptionActions
                #endif
            } header: {
                #if os(iOS)
                HStack {
                    Text(L10n.text("Subscriptions"))
                    Spacer()
                    if store.importing {
                        ProgressView().controlSize(.small)
                    } else if !store.environmentSubscriptions.isEmpty {
                        // Quiet but legible in the header's own grey: primary keeps it tappable in dark mode
                        // where `.secondary` fades into the black background.
                        Button { Task { await store.refreshSubscriptions() } } label: {
                            Label(L10n.text("Refresh All"), systemImage: "arrow.clockwise")
                        }
                        .font(.footnote.weight(.semibold)).textCase(nil).tint(.primary)
                    }
                }
                #else
                Text(L10n.text("Subscriptions"))
                #endif
            } footer: {
                // `store.error` is deliberately not repeated here: it already raises the app-wide
                // "Unable to Complete" alert, so showing it in the footer too meant the same failure
                // arrived twice with two different tones. Import failures have their own field-level
                // message, which is the one that belongs under the form.
                if let message = store.importError ?? store.notice { Text(message) }
            }

            if !store.environmentSubscriptions.isEmpty {
                Section {
                    Toggle(isOn: $refreshesOnLaunch) {
                        FormLabel(symbol: "arrow.clockwise.circle.fill", tint: .teal, title: L10n.text("Refresh on Launch"),
                                  subtitle: L10n.text("Re-fetch every enabled subscription each time the app opens, so changed source addresses update themselves."))
                    }
                    .settingsSwitch()
                    Button {
                        store.clearSubscriptionCache()
                    } label: {
                        FormLabel(symbol: "trash.circle", tint: .orange, title: L10n.text("Clear Subscription Cache"),
                                  subtitle: L10n.text("Frees %@ of parsed copies; enabled subscriptions are fetched again.", ByteCountFormatter.string(fromByteCount: store.subscriptionCacheSize(), countStyle: .file)))
                    }
                }
            }

            Section(L10n.text("Accounts")) {
                if store.extrasUnlocked {
                    FormLink(symbol: "play.tv.fill", tint: .pink, title: L10n.text("Bilibili"), value: bilibiliSummary) { BilibiliAccountView() }
                    FormLink(symbol: "music.note", tint: .black, title: L10n.text("Douyin"), value: douyinSummary) { DouyinAccountView() }
                }
                FormLink(symbol: "externaldrive.fill.badge.person.crop", tint: .brown, title: L10n.text("Cloud Drive Accounts"), value: cloudSummary) { CloudDriveView() }
            }

            Section {
                Toggle(isOn: $syncsWithICloud) {
                    FormLabel(symbol: "icloud.fill", tint: .blue, title: L10n.text("iCloud Sync"))
                }
                .settingsSwitch()
                .onChange(of: syncsWithICloud) { _, on in store.cloudSync?.setEnabled(on) }
            } footer: {
                Text(SettingsNote.iCloud)
            }

            // What plays, and how it is chosen. One list for both platforms: on the phone these sit
            // beside the app's other pages, and on a Mac this is the only door to them.
            Section {
                FormLink(symbol: "arrow.up.arrow.down.square.fill", tint: .teal, title: L10n.text("Resource Order"),
                         value: rankingSummary) { ResourceRankingView() }
                FormLink(symbol: "forward.end.alt.fill", tint: .cyan, title: L10n.text("Segment Sources")) { SkipSourceSettingsView() }
                FormLink(symbol: "waveform.badge.plus", tint: .purple, title: L10n.text("Speech Subtitles")) { SpeechSubtitleView() }
                FormLink(symbol: "character.bubble.fill", tint: .mint, title: L10n.text("AI Translation"),
                         value: store.aiTranslation.isComplete ? L10n.text("On") : nil) { AITranslationView() }
                FormLink(symbol: "textformat.alt", tint: .indigo, title: L10n.text("Artwork Language")) { ArtworkLanguageView() }
                FormLink(symbol: "rectangle.stack.fill", tint: .orange, title: L10n.text("Environments")) { EnvironmentsView() }
            } header: {
                Text(L10n.text("What Plays"))
            }

            #if os(iOS)
            // The app's own pages in one group, as in the Settings app. Playback's switches and notes live a level
            // deeper, so this page stays a short list of places.
            Section {
                FormLink(symbol: AppSection.home.icon, tint: Brand.cyan, title: L10n.text("Watch Now")) { WatchNowSettingsView() }
                FormLink(symbol: "slider.horizontal.below.rectangle", tint: .orange, title: L10n.text("Playback")) { PlaybackSettingsView() }
                FormLink(symbol: "play.fill", tint: Brand.indigo, title: L10n.text("Play a URL")) { PlayURLView() }
                EditTabBarRow()
                Toggle(isOn: $showsTabLabels) {
                    FormLabel(symbol: "dock.rectangle", tint: .gray, title: L10n.text("Tab Bar Labels"))
                }
                .settingsSwitch()
            }
            #else
            Section {
                FormLink(symbol: AppSection.home.icon, tint: Brand.cyan, title: L10n.text("Watch Now")) { WatchNowSettingsView() }
            }
            #endif

            #if os(macOS)
            Section {
                if store.extrasUnlocked {
                    Toggle(isOn: $showsDanmaku) {
                        FormLabel(symbol: "text.bubble.fill", tint: .teal, title: L10n.text("Show Danmaku"), subtitle: danmakuNote)
                    }
                    .settingsSwitch()
                    Picker(selection: $danmakuArea) {
                        ForEach(DanmakuArea.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: {
                        FormLabel(symbol: "rectangle.tophalf.inset.filled", tint: .teal, title: L10n.text("Danmaku Area"))
                    }
                    Toggle(isOn: $receivesCasts) {
                        FormLabel(symbol: "tv.and.mediabox.fill", tint: BilibiliMark.blue, title: L10n.text("Cast from the Bilibili App"),
                                  subtitle: L10n.text("With your phone on the same network, tap the TV button in a Bilibili video and choose %@.", L10n.text("Mi3s")))
                    }
                    .onChange(of: receivesCasts) { _, on in
                        if on { BilibiliCastController.shared.start(store) } else { BilibiliCastController.shared.stop() }
                    }
                }
                Toggle(isOn: $receivesPlayOn) {
                    FormLabel(symbol: "play.tv.fill", tint: Brand.indigo, title: L10n.text("Play from Other Devices"),
                              subtitle: L10n.text("With Mi3s open here, your other devices on the same network can send it what they play: tap Play On in their player."))
                }
                .settingsSwitch()
                .onChange(of: receivesPlayOn) { _, on in
                    if on { PlayOnController.shared.start(store) } else { PlayOnController.shared.stop() }
                }
                Toggle(isOn: $showsPlaybackInfo) {
                    FormLabel(symbol: "info.circle.fill", tint: .blue, title: L10n.text("Show Video Info"), subtitle: SettingsNote.playbackInfo)
                }
                .settingsSwitch()
                FormLink(symbol: "play.fill", tint: Brand.indigo, title: L10n.text("Play a URL")) { PlayURLView() }
            } header: {
                Text(L10n.text("Playback"))
            }
            if VideoEnhancement.canUpscale || VideoEnhancement.canSmooth {
                Section {
                    if VideoEnhancement.canUpscale {
                        Toggle(isOn: $upscalesVideo) {
                            FormLabel(symbol: "wand.and.sparkles", tint: .purple, title: L10n.text("Sharper Picture"), subtitle: upscaleNote)
                        }
                        .settingsSwitch()
                    }
                    if VideoEnhancement.canSmooth {
                        Toggle(isOn: $smoothsVideo) {
                            FormLabel(symbol: "film.stack", tint: .indigo, title: L10n.text("Smooth Motion (60 fps)"), subtitle: smoothNote)
                        }
                        .settingsSwitch()
                    }
                } header: {
                    Text(L10n.text("Picture"))
                }
            }
            #endif

            Section {
                #if WEBCAST
                FormLink(symbol: "globe", tint: .blue, title: L10n.text("Web Cast")) { WebCastSettingsView() }
                #endif
                FormLink(symbol: "internaldrive", tint: .blue, title: L10n.text("Local Cache")) { CacheSettingsView() }
                if store.extrasUnlocked {
                    FormLink(symbol: "cpu.fill", tint: .orange, title: L10n.text("JAR Runtime and Compatibility")) { RuntimeView() }
                }
                FormLink(symbol: "doc.text.magnifyingglass", tint: .gray, title: L10n.text("Diagnostic Logs")) { DiagnosticsView() }
                // Its own row rather than a corner of another page: this is the only setting here
                // that hides content instead of changing how content looks, and a person looking
                // for "where do I hide a source" should not have to read the Advanced list twice.
                FormLink(symbol: "lock.shield.fill", tint: .indigo, title: L10n.text("Privacy Vault"),
                         value: store.vault.hasPasscode ? L10n.text("On") : L10n.text("Off")) { PrivacyVaultView() }
                #if os(iOS)
                // The two switches that send something off the device, with their notes, on a page of their own.
                FormLink(symbol: "hand.raised.fill", tint: .blue, title: L10n.text("Privacy")) { PrivacySettingsView() }
                #else
                Toggle(isOn: $sendsErrorReports) {
                    FormLabel(symbol: "ladybug.fill", tint: .red, title: L10n.text("Send Error Reports"), subtitle: errorReportsNote)
                }
                .settingsSwitch()
                .onChange(of: sendsErrorReports) { _, on in if !on { ErrorReports.shared.discard() } }
                Toggle(isOn: $looksUpTMDB) {
                    FormLabel(symbol: "film.stack.fill", tint: .teal, title: L10n.text("Look Up Titles on TMDB"), subtitle: tmdbNote)
                }
                .settingsSwitch()
                #endif
            } header: {
                Text(L10n.text("Advanced"))
            } footer: {
                #if os(iOS)
                if store.extrasUnlocked { Text(supportNote) }
                #endif
            }

            if store.extrasUnlocked { ContributorsSection() }

            #if os(iOS)
            // As in the Settings app: one-line rows with their state on the right, and the notes under
            // each group instead of a second line and a small link inside the row.
            Section {
                if Updates.channel != .none {
                Button {
                    if updates.available.isEmpty { Task { await updates.check(manual: true) } } else { updates.show() }
                } label: {
                    HStack(spacing: 8) {
                        FormLabel(symbol: "arrow.triangle.2.circlepath", tint: .gray, title: L10n.text("Software Update"))
                            .foregroundStyle(.primary).lineLimit(1).layoutPriority(1)
                        Spacer(minLength: 0)
                        if updates.checking { ProgressView() }
                        else if !updates.available.isEmpty { NewBadge() }
                        else { Text(updates.lastChecked == nil ? L10n.text("Check Now") : L10n.text("Up to Date")).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                // Rows that act in place still read like the rows around them, not like links.
                .tint(.primary)
                .disabled(updates.checking)
                }
                if !updates.currentNotes.isEmpty {
                    Button(action: updates.showCurrentNotes) {
                        HStack(spacing: 8) {
                            FormLabel(symbol: "sparkles", tint: .purple, title: L10n.text("What's New in Version %@", updates.displayVersion))
                                .foregroundStyle(.primary).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                }
                FormLink(symbol: "doc.plaintext.fill", tint: .gray, title: L10n.text("Open Source Licenses")) { LicensesView() }
                    .id("settings.end")
            } header: {
                Text(L10n.text("About"))
            } footer: {
                VStack(alignment: .leading, spacing: 0) {
                    if Updates.channel != .none {
                        if let title = updates.availableTitle { Text(title) }
                        else if let checked = updates.lastChecked { Text(L10n.text("Last checked %@", checked.formatted(date: .abbreviated, time: .shortened))) }
                    }
                    // The page ends on the copyright, centred, as the hero no longer carries it.
                    Text(Brand.copyright).font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 28)
                }
            }
            #else
            Section {
                if updates.available.isEmpty, Updates.channel != .none {
                    LabeledContent {
                        Button { Task { await updates.check(manual: true) } } label: {
                            if updates.checking { ProgressView().controlSize(.small) } else { Text(L10n.text("Check Now")) }
                        }
                        .disabled(updates.checking)
                    } label: {
                        FormLabel(symbol: "checkmark.circle.fill", tint: .green, title: L10n.text("Mi3s is up to date"),
                                  subtitle: updates.lastChecked.map { L10n.text("Last checked %@", $0.formatted(date: .abbreviated, time: .shortened)) })
                    }
                }
                #if os(macOS)
                if let installer = updates.installer {
                    Toggle(isOn: Binding(get: { installer.automaticallyInstalls }, set: { installer.automaticallyInstalls = $0 })) {
                        FormLabel(symbol: "arrow.down.circle.fill", tint: .blue, title: L10n.text("Install Updates Automatically"),
                                  subtitle: L10n.text("Mi3s downloads updates in the background and installs them the next time it quits."))
                    }
                    .settingsSwitch()
                }
                #endif
                if !updates.currentNotes.isEmpty {
                    Button(action: updates.showCurrentNotes) {
                        FormLabel(symbol: "sparkles", tint: .purple, title: L10n.text("What's New in Version %@", updates.displayVersion))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.formRowButton()
                }
                FormLink(symbol: "doc.plaintext.fill", tint: .gray, title: L10n.text("Open Source Licenses")) { LicensesView() }
                    .id("settings.end")
            } header: {
                Text(L10n.text("About"))
            } footer: {
                if store.extrasUnlocked { Text(supportNote) }
            }
            #endif
        }.settingsRows() }
        #if DEBUG
        // `-qaScrollBottom 1` opens Settings at its end for screenshots.
        .task {
            guard UserDefaults.standard.bool(forKey: "qaScrollBottom") else { return }
            try? await Task.sleep(for: .seconds(1))
            proxy.scrollTo("settings.end", anchor: .bottom)
        }
        #endif
        }
        .settingsForm(L10n.text("Settings"))
        #if os(iOS)
        .sheet(isPresented: $addingSubscription) { AddSubscriptionSheet() }
        .navigationDestination(isPresented: $showsFeedback) { FeedbackView() }
        .fileImporter(isPresented: $choosesConfig, allowedContentTypes: [.json]) { result in
            if case .success(let file) = result { importConfig(from: file) }
        }
        .fileExporter(isPresented: $exportsConfig, document: exportConfigDocument,
                      contentType: .json, defaultFilename: "mi3s-config") { result in
            if case .success = result { store.notice = L10n.text("Configuration exported.") }
            else if case .failure(let error) = result { store.importError = L10n.text("Export failed: %@", error.localizedDescription) }
        }
        .onChange(of: exportsConfig) { _, exporting in
            exportConfigDocument = exporting ? ConfigDocument(store.exportConfig()) : nil
        }
        .confirmationDialog(L10n.text("Import Configuration"), isPresented: Binding(
            get: { pendingConfig != nil }, set: { if !$0 { pendingConfig = nil } })) {
            Button(L10n.text("Merge (keep current, add missing)")) { applyPendingConfig(overwrite: false) }
            Button(L10n.text("Restore (overwrite with backup)")) { applyPendingConfig(overwrite: true) }
            Button(L10n.text("Cancel"), role: .cancel) { pendingConfig = nil }
        } message: {
            Text(L10n.text("Merge adds only subscriptions you don't have yet. Restore overwrites names, switches and order to match the backup."))
        }
        // Full backup: pick slices, then export to a file or a cloud drive.
        .sheet(isPresented: $picksBackupCategories) {
            BackupCategoryPicker(selection: $backupCategories) {
                picksBackupCategories = false
                if cloudBackupMode != nil { return }  // the cloud-drive sheet opens instead
                exportsFullBackup = true
            }
        }
        .sheet(item: $cloudBackupMode) { mode in
            CloudBackupSheet(mode: mode, categories: backupCategories)
        }
        .fileImporter(isPresented: $choosesFullBackup, allowedContentTypes: [.json]) { result in
            if case .success(let file) = result { importFullBackup(from: file) }
        }
        .fileExporter(isPresented: $exportsFullBackup, document: exportFullBackupDocument,
                      contentType: .json, defaultFilename: "mi3s-full-backup") { result in
            if case .success = result { store.notice = L10n.text("Full backup exported.") }
            else if case .failure(let error) = result { store.importError = L10n.text("Export failed: %@", error.localizedDescription) }
        }
        .onChange(of: exportsFullBackup) { _, exporting in
            exportFullBackupDocument = exporting ? FullBackupDocument(store.exportFullBackup(categories: backupCategories)) : nil
        }
        .confirmationDialog(L10n.text("Restore Full Backup"), isPresented: Binding(
            get: { pendingFullBackup != nil }, set: { if !$0 { pendingFullBackup = nil } })) {
            Button(L10n.text("Restore everything")) { applyPendingFullBackup() }
            Button(L10n.text("Cancel"), role: .cancel) { pendingFullBackup = nil }
        } message: {
            Text(L10n.text("This overwrites the matching data on this device with the backup. Sign-in state, history, favourites, settings and proxies are all included."))
        }
        #if DEBUG
        // `-qaAddSubscription 1` opens the sheet for screenshots.
        .onAppear { if UserDefaults.standard.bool(forKey: "qaAddSubscription") { addingSubscription = true } }
        #endif
        #endif
        // Refreshed whenever Settings reappears, so a sign-in on the account page shows here.
        .onAppear { bilibiliSummary = BilibiliAccount.load().summary; douyinSummary = DouyinAccount.load().summary; cloudSummary = CloudProvider.summary() }
        .task(id: store.extrasUnlocked) { if store.extrasUnlocked { await ContributorList.shared.check() } }
    }

    @ViewBuilder private var heroSection: some View {
        #if os(iOS)
        // The app on the page's own canvas, not in a card: its icon lit by a glow of itself, the name large, and the
        // version with the update state in one glass chip. A waiting release is the one prominent button.
        Section {
            VStack(spacing: 0) {
                // The row clips what it draws, so the glow stays small enough to fade out inside it.
                AppMark(size: 96)
                    .background { AppMark(size: 96).blur(radius: 22).opacity(0.7).accessibilityHidden(true) }
                    .padding(.top, 36).padding(.bottom, 18)
                Text(L10n.text("Mi3s")).font(.system(size: 32, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    if let version { Text(version) }
                    if updates.availableTitle == nil, Updates.channel != .none, updates.lastChecked != nil {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text(L10n.text("Up to Date"))
                    }
                }
                .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glassSurface(.regular, in: Capsule())
                .padding(.top, 10)
                if let title = updates.availableTitle {
                    Button(action: updates.show) {
                        Label(title, systemImage: "gift.fill")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.onAccent)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Brand.accent, in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .padding(.top, 14)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 10)
            .listRowBackground(Color.clear)
        }
        #else
        // The app leads, like the account card in Settings; a waiting release sits right under it.
        Section {
            HStack(spacing: 14) {
                AppMark(size: FormMetrics.hero)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Mi3s")).font(.title3.weight(.semibold))
                    if let version { Text(version).font(.subheadline).foregroundStyle(.secondary) }
                    Text(Brand.copyright).font(.caption).foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            if let title = updates.availableTitle {
                Button(action: updates.show) {
                    LabeledContent {
                        NewBadge()
                    } label: {
                        FormLabel(symbol: "gift.fill", tint: Brand.cyan, title: title,
                                  subtitle: L10n.text("New features are waiting for you."))
                    }
                }.formRowButton()
            }
        }
        #endif
    }

    private var canAdd: Bool { !store.importing && !store.subscriptionAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var danmakuNote: String { SettingsNote.danmaku }
    private var upscaleNote: String { VideoEnhancement.upscaleNote }
    private var smoothNote: String { VideoEnhancement.smoothNote }
    private var tmdbNote: String { SettingsNote.tmdb }
    private var supportNote: String { SettingsNote.support }
    private var errorReportsNote: String { SettingsNote.errorReports }
    private func add() { if canAdd { Task { await store.importSubscription() } } }

    #if os(iOS)
    /// Reads a chosen configuration file, then asks whether to merge or restore-overwrite before applying it.
    private func importConfig(from file: URL) {
        Task {
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            // A backup file can be large; read it off the main thread instead of blocking the picker's
            // dismiss on a synchronous `Data(contentsOf:)`.
            let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: file) }.value
            guard let data, let config = SubscriptionConfig.decode(data) else {
                store.importError = L10n.text("This isn't a Mi3s configuration file.")
                return
            }
            if config.version != SubscriptionConfig.version {
                store.importError = L10n.text("This configuration file is from a newer version and can't be imported.")
                return
            }
            pendingConfig = config
        }
    }

    private func applyPendingConfig(overwrite: Bool) {
        guard let config = pendingConfig else { return }
        pendingConfig = nil
        store.importConfig(config, overwrite: overwrite)
    }

    /// Reads a full-backup file, then asks for confirmation before overwriting.
    private func importFullBackup(from file: URL) {
        Task {
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: file) }.value
            guard let data, let backup = try? JSONDecoder().decode(FullBackup.self, from: data) else {
                store.importError = L10n.text("This isn't a Mi3s backup file.")
                return
            }
            if backup.schemaVersion != FullBackup.version {
                store.importError = L10n.text("This backup is from a newer version and can't be restored.")
                return
            }
            pendingFullBackup = backup
        }
    }

    private func applyPendingFullBackup() {
        guard let backup = pendingFullBackup else { return }
        pendingFullBackup = nil
        let result = store.importFullBackup(backup, categories: .all)
        let restored = result.restored.count
        let missing = result.skippedMissing.count
        if missing > 0 {
            store.notice = L10n.text("Restored %@ categories; %@ were empty in the backup.", String(restored), String(missing))
        } else {
            store.notice = L10n.text("Full backup restored. Restart the app to apply everything.")
        }
    }
    #endif

    #if os(macOS)
    @ViewBuilder private var subscriptionActions: some View {
        // System Settings style: the actions as buttons at the trailing edge, the default one prominent.
        HStack {
            if !store.subscriptions.isEmpty {
                Button(L10n.text("Refresh All")) { Task { await store.refreshSubscriptions() } }.disabled(store.importing)
            }
            Spacer()
            if store.importing { ProgressView().controlSize(.small); ElapsedTime() }
            if store.importing, store.importTotal > 1 {
                Text(L10n.text("%lld of %lld", store.importDone, store.importTotal)).font(.caption2).foregroundStyle(.secondary)
            }
            Button(L10n.text("Use a Demo URL")) { store.subscriptionAddress = Store.defaultURL }
            Button(L10n.text("Add from File…")) { choosesFile = true }.disabled(store.importing)
                .help(L10n.text("A TVBox JSON subscription, or one Python (.py) or JavaScript (.js) spider."))
            Button(store.importing ? L10n.text("Importing…") : L10n.text("Add Subscription")) { add() }
                .buttonStyle(.borderedProminent).disabled(!canAdd)
        }
        .fileImporter(isPresented: $choosesFile, allowedContentTypes: SubscriptionFile.types) { result in
            if case .success(let file) = result { Task { await store.importSubscriptionFile(file) } }
        }
    }
    #endif
}

#if os(iOS)
/// The hero card's fill: the row colour lit from above by the icon's cyan and indigo.
private struct SettingsHeroGlow: View {
    var body: some View {
        ZStack {
            SettingsStyle.rowFill
            RadialGradient(colors: [Brand.cyan.opacity(0.32), .clear], center: .top, startRadius: 0, endRadius: 230)
            RadialGradient(colors: [Brand.indigo.opacity(0.22), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 260)
        }
    }
}

/// A tile at the top of Settings: a symbol on a grey disc and the way out in the corner, then the title and one line
/// about it. Drawn in the rows' fill and corner, so it reads as part of the same form.
private struct SettingsTile: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    var external = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                Spacer(minLength: 0)
                Image(systemName: external ? "arrow.up.right" : "chevron.forward")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsStyle.rowFill, in: shape)
        .contentShape(shape)
    }
}

/// Answers the press itself, not the release: a slight sink on a critically damped spring, so a quick tap still shows.
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 1), value: configuration.isPressed)
    }
}

/// Adding a subscription: the address, a shortcut to the default one, and Add in the toolbar.
/// Closes itself once the import succeeds; a failure stays here under the field.
private struct AddSubscriptionSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var choosesFile = false
    private var canAdd: Bool { !store.importing && !store.subscriptionAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form { Group {
                Section {
                    TextField(L10n.text("Subscription URL (TVBox JSON, M3U or TXT)"), text: $store.subscriptionAddress, prompt: Text(L10n.text("Subscription URL (TVBox JSON, M3U or TXT)")))
                        .labelsHidden()
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                        .submitLabel(.done)
                        .focused($focused)
                        .onSubmit(add)
                    TextField(L10n.text("Name (optional)"), text: $store.subscriptionName, prompt: Text(L10n.text("Name (optional)")))
                        .labelsHidden()
                        .submitLabel(.done)
                        .onSubmit(add)
                } footer: {
                    if let error = store.importError { Text(error).foregroundStyle(Brand.amber) }
                    else { Text(L10n.text("Paste the address of a TVBox JSON subscription, an M3U or TXT live playlist, or an AList server.")) }
                }
                // Offered, never filled in or imported on its own.
                Section {
                    Button { store.subscriptionAddress = Store.defaultURL } label: {
                        FormLabel(symbol: "sparkles", tint: Brand.indigo, title: L10n.text("Use a Demo URL"))
                            .foregroundStyle(.primary)
                    }
                }
                Section {
                    Button { choosesFile = true } label: {
                        FormLabel(symbol: "doc.badge.plus", tint: .orange, title: L10n.text("Add from File…"))
                            .foregroundStyle(.primary)
                    }
                    .disabled(store.importing)
                } footer: { Text(L10n.text("A TVBox JSON subscription, or one Python (.py) or JavaScript (.js) spider.")) }
            }.settingsRows() }
            .settingsForm(L10n.text("Add Subscription"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.importing { ProgressView() }
                    else { Button(L10n.text("Add"), action: add).fontWeight(.semibold).disabled(!canAdd) }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { store.importError = nil; focused = true }
        .fileImporter(isPresented: $choosesFile, allowedContentTypes: SubscriptionFile.types) { result in
            guard case .success(let file) = result else { return }
            Task {
                await store.importSubscriptionFile(file)
                if store.importError == nil { dismiss() }
            }
        }
    }

    private func add() {
        guard canAdd else { return }
        Task {
            await store.importSubscription()
            if store.importError == nil { dismiss() }
        }
    }
}
#endif

/// What Add from File offers: a subscription, or one spider script.
enum SubscriptionFile {
    static let types: [UTType] = [.json, .pythonScript, .javaScript]
}

#if os(iOS)
/// The JSON configuration file handed to `fileExporter` for "Export Configuration".
private struct ConfigDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(_ config: SubscriptionConfig) {
        self.data = (try? JSONEncoder().encode(config)) ?? Data()
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// The full-backup file handed to `fileExporter`.
private struct FullBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(_ backup: FullBackup) {
        self.data = (try? JSONEncoder().encode(backup)) ?? Data()
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif

/// A sheet that lets the viewer tick which slices a full backup carries, then confirm.
private struct BackupCategoryPicker: View {
    @Binding var selection: BackupCategory
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(BackupCategory.titles, id: \.0.rawValue) { category, title in
                        Toggle(isOn: Binding(
                            get: { selection.contains(category) },
                            set: { on in
                                if on { selection.insert(category) } else { selection.remove(category) }
                            }
                        )) {
                            Text(title)
                        }
                    }
                } footer: {
                    Text(L10n.text("Sign-in & accounts carries cookies and tokens; restoring them may still require re-signing in if a service expired them."))
                }
            }
            .navigationTitle(L10n.text("Backup contents"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Export")) { dismiss(); onConfirm() }
                }
            }
        }
    }
}

/// One subscription: switch it on or off, move it (earlier subscriptions win duplicate sources), or remove it.
private struct SubscriptionDetailView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let entry: SubscriptionEntry
    @State private var confirmsRemoval = false
    @State private var copying = false
    @State private var copyingTo: UUID?
    var body: some View {
        let current = store.environmentSubscriptions.first { $0.address == entry.address } ?? entry
        let index = store.environmentSubscriptions.firstIndex { $0.address == entry.address } ?? 0
        let failure = store.subscriptionErrors[entry.address]
        let copy = store.documents[entry.address]
        Form { Group {
            Section {
                Toggle(isOn: Binding(get: { current.enabled }, set: { on in Task { await store.setSubscription(current, enabled: on) } })) {
                    FormLabel(symbol: "list.bullet.rectangle.fill", tint: current.enabled ? .blue : .gray, title: L10n.text("Use This Subscription"))
                }
                .settingsSwitch()
                .disabled(store.importing)
                // A subscription's default route: its sources without a choice of their own follow it.
                LabeledContent(L10n.text("Connection")) {
                    Picker(L10n.text("Connection"), selection: Binding(
                        get: { current.routing },
                        set: { route in store.setRoute(route, for: current) }
                    )) {
                        ForEach(SourceRoute.allCases, id: \.self) { route in
                            Text(route.title).tag(route)
                        }
                    }
                    .labelsHidden()
                }
                LabeledContent(L10n.text("Name")) {
                    // Empty shows the name it would otherwise have.
                    TextField(L10n.text("Name"), text: Binding(get: { current.name }, set: { store.renameSubscription(current, to: $0) }),
                              prompt: Text(SubscriptionEntry(address: current.address).title))
                        .labelsHidden().multilineTextAlignment(.trailing)
                }
                LabeledContent(L10n.text("Subscription URL")) {
                    Text(current.address).lineLimit(2).truncationMode(.middle).textSelection(.enabled).foregroundStyle(.secondary)
                }
            } footer: {
                if let failure { Text(L10n.text("Couldn't refresh: %@", failure)) }
                else if let copy { Text(L10n.text("Sources: %lld · Live playlists: %lld", copy.sites.count, copy.lives.count)) }
            }
            if store.environmentSubscriptions.count > 1 {
                Section(L10n.text("Order")) {
                    if index > 0 { Button(L10n.text("Move Up")) { store.moveSubscription(current, by: -1) } }
                    if index < store.environmentSubscriptions.count - 1 { Button(L10n.text("Move Down")) { store.moveSubscription(current, by: 1) } }
                }
            }
            // Copy this subscription into another sandbox: the same feed, fully independent there.
            if store.environments.all.count > 1 {
                Section {
                    ForEach(store.environments.all.filter { $0.id != store.environments.activeID }) { environment in
                        Button {
                            store.copySubscription(current, to: environment.id)
                        } label: {
                            FormLabel(symbol: "doc.on.doc.fill", tint: .teal,
                                      title: L10n.text("Copy to %@", environment.name))
                        }
                        .disabled(store.subscriptions(in: environment.id).contains { $0.address == current.address })
                    }
                } footer: {
                    Text(L10n.text("Copies the subscription into another environment. Each environment keeps its own subscriptions, history and watchlist; nothing is shared."))
                }
            }
            Section {
                Button(L10n.text("Remove"), role: .destructive) { confirmsRemoval = true }
            }
        }.settingsRows() }
        .settingsForm(current.title)
        .confirmationDialog(L10n.text("Remove"), isPresented: $confirmsRemoval) {
            Button(L10n.text("Remove"), role: .destructive) { store.removeSubscription(current); dismiss() }
        }
    }
}

/// Removing many subscriptions at once: tick them, or take all or the switched-off ones, then remove.
private struct RemoveSubscriptionsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var confirmsRemoval = false
    var body: some View {
        let chosen = store.environmentSubscriptions.filter { selection.contains($0.address) }
        let all = chosen.count == store.environmentSubscriptions.count
        let off = store.environmentSubscriptions.filter { !$0.enabled }.map(\.address)
        Form { Group {
            Section {
                Button(L10n.text(all ? "Deselect All" : "Select All")) { selection = all ? [] : Set(store.environmentSubscriptions.map(\.address)) }
                if !off.isEmpty { Button(L10n.text("Select Turned-Off Subscriptions")) { selection = Set(off) } }
            }
            Section {
                ForEach(store.environmentSubscriptions) { entry in
                    let selected = selection.contains(entry.address)
                    Button {
                        if selected { selection.remove(entry.address) } else { selection.insert(entry.address) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            Text(entry.title).lineLimit(1).foregroundStyle(.primary)
                            Spacer(minLength: 6)
                            Text(store.subscriptionValue(entry)).lineLimit(1).foregroundStyle(.secondary)
                        }
                    }
                    .formRowButton()
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            Section {
                Button(L10n.text("Remove %lld Subscriptions", chosen.count), role: .destructive) { confirmsRemoval = true }
                    .disabled(chosen.isEmpty || store.importing)
            }
        }.settingsRows() }
        .settingsForm(L10n.text("Remove Subscriptions"))
        .confirmationDialog(L10n.text("Remove %lld Subscriptions", chosen.count), isPresented: $confirmsRemoval) {
            Button(L10n.text("Remove"), role: .destructive) { store.removeSubscriptions(Set(chosen.map(\.address))); dismiss() }
        }
    }
}

/// Playing a media address directly.
private struct PlayURLView: View {
    @Environment(Store.self) private var store
    @State private var address = ""
    private var empty: Bool { address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        Form { Group {
            Section {
                TextField(L10n.text("HTTP / HTTPS media URL"), text: $address, prompt: Text(L10n.text("HTTP / HTTPS media URL")))
                    .labelsHidden()
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                    #endif
                    .onSubmit(open)
                #if os(macOS)
                HStack { Spacer(); Button(L10n.text("Open Player"), action: open).buttonStyle(.borderedProminent).disabled(empty) }
                #else
                Button(L10n.text("Open Player"), action: open).disabled(empty)
                #endif
            }
        }.settingsRows() }
        .settingsForm(L10n.text("Play a URL"))
    }
    private func open() {
        guard !empty else { return }
        do { store.playing = Channel(name: L10n.text("URL Playback"), url: try WebAddress.resolve(address)) }
        catch { store.error = error.localizedDescription }
    }
}
#endif
