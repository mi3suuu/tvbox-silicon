import Foundation

/// 记住用户在某部剧的某条线路上选过的清晰度。
///
/// ## 为什么要有
///
/// 采集站与插件常常一部剧返回好几档（`url` 是数组、或 FongMi 的 `values`）。映匣原来的做法是
/// **每点一次播放就弹一次「选择清晰度」**（`VideoDetailView` 的 `plan.choices.count > 1`）：
///
///   · 用户每集都要再选一次，选项名还常常是源自己给的空名或 `1 / 2 / 3`；
///   · 弹窗挡在起播前，网络再快也要先等人点一下 —— 这就是「点了播放，半天没反应」的一部分；
///   · 而且它每次都回到第一项，等于把「上次选的 4K」忘掉。
///
/// 现在按「源 + 剧 + 线路」记一条：下次同一条线直接用它起播；那档不在了才重新问。
///
/// ## 键为什么带线路
///
/// 同一部剧的每条线路是**不同服务商**的片源，清晰度档位互不对应（A 线的「高清」与 B 线的
/// 「高清」不是同一档）。只按剧记会把 A 线的选择套到 B 线上，取不到就当没记 —— 白记。
public enum QualityPreference {
    private static let prefix = "qualityChoice.v1|"

    /// 一条选择的存储键。剧 id 可能含 `|`，所以只做拼接、不解析回来。
    public static func key(site: String, video: String, flag: String) -> String {
        prefix + site + "|" + video + "|" + flag
    }

    public static func remembered(_ key: String, defaults: UserDefaults = .standard) -> String? {
        guard let name = defaults.string(forKey: key), !name.isEmpty else { return nil }
        return name
    }

    public static func remember(_ name: String, for key: String, defaults: UserDefaults = .standard) {
        guard !name.isEmpty else { return }
        defaults.set(name, forKey: key)
    }

    public static func forget(_ key: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    /// 从一组候选里挑回记住的那一档。
    ///
    /// 按**名字**比而不是按序号：源换季、改档位顺序都会让序号漂移，而对不上名字时
    /// 调用方会重新弹一次选择 —— 这比「静默播了另一档」好。
    public static func match<T>(_ choices: [T], named name: String, nameOf: (T) -> String) -> T? {
        choices.first { nameOf($0) == name }
    }
}
