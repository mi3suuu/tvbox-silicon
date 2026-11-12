import Foundation

/// 偏好类的 UserDefaults key 按环境分键的唯一口径。
///
/// 环境隔离（见 `Environments`）的第一版只给「记录式」数据加了字段：订阅、播放记录、
/// 收藏、下载各自带 `environmentID`。**偏好式**数据（置顶、隐藏、源排序、源改派、
/// 自定义分组）没有记录可打戳，key 里只有 `origin + sourceKey` 或纯 id，
/// 于是切环境后上一个环境的置顶/隐藏/排序照样作用于新环境 —— 这正是
/// 「切了环境，点播源里还残留着之前环境的东西」的来路。
///
/// 这里沿用搜索历史已经验证过的口径（`Store.searchHistoryKey`）：
/// 默认环境用原 key，**升级不丢任何旧偏好**；其余环境用 `<base>.<uuid>`，各自独立。
/// 读与写必须都过这一个函数，否则就是「切环境后偏好回来了」的下一例。
public enum EnvironmentScopedKey {
    /// 某个环境下的完整 key。
    ///
    /// - `environment` 为空表示还不知道当前环境（初始化早期），按默认环境处理。
    /// - `defaultID` 为空表示 `Environments` 尚未加载，同样按默认环境处理 ——
    ///   只有默认环境会拿到没有后缀的原 key，所以这个兜底不会让两个环境撞在同一个 key 上。
    public static func key(_ base: String, environment: UUID?, default defaultID: UUID?) -> String {
        guard let environment, let defaultID, environment != defaultID else { return base }
        return base + "." + environment.uuidString
    }

    /// 被删除的环境留下的那些 key，用来在删环境时一起清掉。
    /// 只算出候选名，真正的清理由持有数据的那一方做（它才知道要读哪个 suite）。
    public static func keys(_ bases: [String], environment: UUID) -> [String] {
        bases.map { $0 + "." + environment.uuidString }
    }
}
