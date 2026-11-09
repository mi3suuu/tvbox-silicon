import SwiftUI
import TVCore

#if os(iOS)
/// 界面语言选择页。
///
/// 和播放器控件设置同一套交互：一行一个选项，右侧打勾。
/// 选完立刻 `L10n.setLanguage` + 让 `store.languageRevision` 自增，
/// 根视图读到计数器就整棵重算 —— 不需要重启。
struct LanguageSettingsView: View {
    @Environment(Store.self) private var store

    /// `nil` 代表「跟随系统」，排在最前。
    private var choices: [String?] {
        [nil] + L10n.supportedLanguages.map { Optional($0) }
    }

    var body: some View {
        SettingsPage(title: L10n.text("App Language"), symbol: "globe") {
            SettingsGroup(footer: L10n.text("The app language is independent of your device language and applies immediately.")) {
                ForEach(choices, id: \.self) { code in
                    Button {
                        L10n.setLanguage(code)
                        store.languageRevision &+= 1
                    } label: {
                        HStack(spacing: 10) {
                            Text(code.map { L10n.displayName($0) } ?? L10n.text("Follow System"))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            if isSelected(code) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.language.\(code ?? "system")")
                }
            }
        }
    }

    private func isSelected(_ code: String?) -> Bool {
        let stored = UserDefaults.standard.string(forKey: L10n.languageKey)
        if let code { return stored == code }
        return stored == nil || !L10n.supportedLanguages.contains(stored ?? "")
    }
}
#endif
