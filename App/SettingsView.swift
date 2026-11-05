import SwiftUI
import TVCore
import UniformTypeIdentifiers

// MARK: Settings building blocks
// The pages under Settings are built from these, so they match the Settings page itself: the
// system's grouped form on iPhone, iPad and Mac, and on Apple TV a page like the TV's own Settings
// subpages, with a symbol and title on the left and sections of rows on the right.

/// A titled run of rows with an optional note under it.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        #if os(tvOS)
        TVSettingsSection(title: title, footer: footer) { content }
        #else
        Section {
            content
        } header: {
            if let title { Text(title) }
        } footer: {
            if let footer { Text(footer) }
        }
        #endif
    }
}

/// Icon tile, title, optional subtitle and a trailing accessory. On Apple TV the row goes without
/// the tile, as rows do in the TV's own Settings.
struct SettingsRow<Trailing: View>: View {
    let symbol: String
    var tint: Color = .gray
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        #if os(tvOS)
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 29, weight: .medium)).lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 23)).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer(minLength: 32)
            trailing
        }
        // The insets of a `glassRow()`, so static rows line up with the rows that can be selected.
        .padding(.horizontal, 28).padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        #else
        LabeledContent { trailing } label: { FormLabel(symbol: symbol, tint: tint, title: title, subtitle: subtitle) }
        #endif
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(symbol: String, tint: Color = .gray, title: String, subtitle: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A row that opens a subpage.
struct SettingsLinkRow<Destination: View>: View {
    let symbol: String
    var tint: Color = .gray
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var destination: () -> Destination
    var body: some View {
        #if os(tvOS)
        TVSettingsLink(title: title, value: subtitle, destination: destination)
        #else
        RouteLink(destination: destination) { FormLabel(symbol: symbol, tint: tint, title: title, subtitle: subtitle) }
        #endif
    }
}

/// A row that does something in place, such as clearing the cache: the whole row is the button.
struct SettingsActionRow: View {
    let title: String
    var destructive = false
    let action: () -> Void
    var body: some View {
        #if os(tvOS)
        TVSettingsAction(title: title, destructive: destructive, action: action)
        #else
        Button(title, role: destructive ? .destructive : nil, action: action).formRowButton()
        #endif
    }
}

extension View {
    /// Buttons inside settings rows: the TV's control style, and the system's bordered buttons in
    /// the system accent elsewhere, as in System Settings and the Settings app.
    @ViewBuilder func settingsButton(prominent: Bool = false) -> some View {
        #if os(tvOS)
        controlButton(prominent: prominent)
        #elseif os(iOS)
        if prominent { buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(systemAccent) }
        else { buttonStyle(.bordered).buttonBorderShape(.capsule).tint(systemAccent) }
        #else
        if prominent { buttonStyle(.borderedProminent).tint(systemAccent) } else { buttonStyle(.bordered) }
        #endif
    }
}

#if !os(tvOS)
/// The system's accent, not the app's: `Color.accentColor` follows the app-wide tint here.
var systemAccent: Color {
    #if os(macOS)
    Color(nsColor: .controlAccentColor)
    #else
    Color(uiColor: .systemBlue)
    #endif
}
#endif

/// A page under Settings. `symbol` and `subtitle` lead the page on Apple TV.
struct SettingsPage<Content: View>: View {
    let title: String
    var symbol = "gearshape"
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        #if os(tvOS)
        TVSettingsSubpage(symbol: symbol, title: title, subtitle: subtitle) { content }
        #else
        Form { Group { content }.settingsRows() }.settingsForm(title)
        #endif
    }
}

/// The panel around the diagnostic log list.
enum SettingsStyle {
    static let radius: CGFloat = 12
    static let groupFill = Color.primary.opacity(0.05)
    /// Row fill on the app's canvas on iPhone and iPad: the navy of the More tab's tiles.
    static let rowFill = Color(light: .white, dark: Color(red: 0.075, green: 0.105, blue: 0.19))
}

// MARK: Settings

struct SettingsView: View {
    var body: some View {
        #if os(tvOS)
        TVSettingsView()
        #else
        FormSettingsView()
        #endif
    }
}

extension Store {
    /// What a subscription row shows before its chevron.
    func subscriptionValue(_ entry: SubscriptionEntry) -> String {
        if subscriptionErrors[entry.address] != nil { return L10n.text("Couldn't refresh") }
        if !entry.enabled { return L10n.text("Off") }
        guard let copy = documents[entry.address] else { return L10n.text("Not loaded yet") }
        return L10n.text("%lld sources", copy.sites.count)
    }
}
