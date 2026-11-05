import SwiftUI
import TVCore

#if !os(tvOS)
/// The two switches that send something off the device, each with what it sends.
struct PrivacySettingsView: View {
    @Environment(Store.self) private var store
    @AppStorage(ErrorReports.key) private var sendsErrorReports = true
    @AppStorage(TMDBMatch.key) private var looksUpTMDB = true
    @AppStorage(PrivacyShade.key) private var coversAppSwitcher = true
    var body: some View {
        SettingsPage(title: L10n.text("Privacy"), symbol: "hand.raised.fill") {
            SettingsGroup(footer: SettingsNote.privacyVault) {
                FormLink(symbol: "lock.shield.fill", tint: .indigo, title: L10n.text("Privacy Vault"),
                         value: store.vault.hasPasscode ? L10n.text("On") : L10n.text("Off")) { PrivacyVaultView() }
            }
            SettingsGroup(footer: SettingsNote.appSwitcher) {
                Toggle(isOn: $coversAppSwitcher) {
                    FormLabel(symbol: "eye.slash.fill", tint: .purple, title: L10n.text("Hide Content in the App Switcher"))
                }
                .settingsSwitch()
            }
            SettingsGroup(footer: SettingsNote.errorReports) {
                Toggle(isOn: $sendsErrorReports) {
                    FormLabel(symbol: "ladybug.fill", tint: .red, title: L10n.text("Send Error Reports"))
                }
                .settingsSwitch()
                .onChange(of: sendsErrorReports) { _, on in if !on { ErrorReports.shared.discard() } }
            }
            SettingsGroup(footer: SettingsNote.tmdb) {
                Toggle(isOn: $looksUpTMDB) {
                    FormLabel(symbol: "film.stack.fill", tint: .teal, title: L10n.text("Look Up Titles on TMDB"))
                }
                .settingsSwitch()
            }
        }
    }
}
#endif
