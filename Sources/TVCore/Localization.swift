import Foundation

/// Shared by the SwiftUI app and core errors. Source keys are readable English.
/// Production follows Apple's per-app language selection; explicit languages are
/// useful for previews and tests and do not mutate global preferences.
public enum L10n {
    public static let supportedLanguages = ["en", "zh-Hans", "zh-Hant", "ja"]

    /// 用户在设置页选的界面语言。`nil` = 跟随系统。
    ///
    /// 存 `UserDefaults` 而不是只放内存：App 冷启动时 `Bundle.module` 的
    /// `preferredLocalizations` 已经定死（跟随系统），只有我们自己读这个键
    /// 才能覆盖它。所以 `text()` 每次取值时都先看这里。
    public static let languageKey = "appLanguage"

    /// 当前生效的语言：用户选过就用它，否则用系统给的那个。
    public static var currentLanguage: String {
        if let chosen = UserDefaults.standard.string(forKey: languageKey),
           supportedLanguages.contains(chosen) {
            return chosen
        }
        return resolvedLanguage(nil)
    }

    /// 设置页改语言后调用：写偏好并让 SwiftUI 重算。
    /// `objectWillChange` 由调用方（Store）负责，这里只管持久化。
    public static func setLanguage(_ code: String?) {
        if let code, supportedLanguages.contains(code) {
            UserDefaults.standard.set(code, forKey: languageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: languageKey)
        }
    }

    /// 设置页那一行右侧显示的当前值。
    /// 跟随系统时显示「跟随系统 · <系统语言>」，让用户知道实际生效的是哪个。
    public static var currentSelectionName: String {
        if let chosen = UserDefaults.standard.string(forKey: languageKey),
           supportedLanguages.contains(chosen) {
            return displayName(chosen)
        }
        return "\(text("Follow System")) · \(displayName(resolvedLanguage(nil)))"
    }

    /// 语言在界面上的显示名，用**该语言自己的写法**，不做翻译。
    public static func displayName(_ code: String) -> String {
        switch code {
        case "en": return "English"
        case "zh-Hans": return "简体中文"
        case "zh-Hant": return "繁體中文"
        case "ja": return "日本語"
        default: return code
        }
    }

    /// One of `supportedLanguages`: the match for `language`, or the language the app's UI is shown in.
    public static func resolvedLanguage(_ language: String? = nil) -> String {
        guard let language else { return Bundle.module.preferredLocalizations.first ?? "en" }
        let match = Bundle.preferredLocalizations(from: supportedLanguages, forPreferences: [language]).first ?? "en"
        return supportedLanguages.contains(match) ? match : "en"
    }

    /// Every supported language's rendering of one key.
    ///
    /// For the few places where a human-readable string is also an *identity* — a custom group the
    /// app creates for the reader, which is found again by name. Matching on the current language
    /// alone means a reader who switches the interface language between two runs gets a second group
    /// beside the first, each holding half of what they meant as one. This returns all of them so a
    /// caller can recognise the group whatever language it was made in.
    public static func everyRendering(of key: String) -> [String] {
        supportedLanguages.map { text(key, language: $0) }
    }

    public static func text(_ key: String, _ arguments: CVarArg..., language: String? = nil) -> String {
        // 没显式传语言时走**用户选的语言**（`currentLanguage`），
        // 而不是 `Bundle.module` 的 `preferredLocalizations` ——
        // 那个只认系统语言，用户在设置里换语言它不会跟着变。
        let selected = resolvedLanguage(language ?? currentLanguage)
        let bundle = Bundle.module.path(forResource: selected, ofType: "lproj").flatMap(Bundle.init(path:)) ?? Bundle.module
        let format = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: language ?? bundle.preferredLocalizations.first ?? "en"), arguments: arguments)
    }
}
