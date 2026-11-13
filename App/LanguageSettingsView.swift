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
    /// 响应式真源：`isSelected` 原来直接读 `UserDefaults`，而 `UserDefaults`
    /// **不参与 SwiftUI 状态管理** —— 点完只有 `store.languageRevision` 自增，
    /// 若本视图没被那条 revision 驱动，勾选态就不动、也没有任何回馈。
    /// 用户报的「语言设置没有勾选态和刷新」就是这个。
    /// `@AppStorage` 让写入立刻触发本视图重绘，勾选态一定跟手。
    @AppStorage(L10n.languageKey) private var storedLanguage: String = ""

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
        // 读 `@AppStorage` 而不是 `UserDefaults.standard`：前者变化会重绘。
        let stored: String? = storedLanguage.isEmpty ? nil : storedLanguage
        if let code { return stored == code }
        return stored == nil || !L10n.supportedLanguages.contains(stored ?? "")
    }
}
#endif
