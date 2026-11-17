import Foundation

/// 把「必须显式走节点」的域名打成一份 Loon 插件。
///
/// 为什么不继续用 Remote Rule（远程规则）：那条路要求**每次刷新都能重新取到**规则文件，
/// 而 iOS 把 App 一挂起，本机监听就没了 —— Loon 什么时候来拉全凭运气，
/// 于是「120 秒自动刷新」在真机上等于随机失败。
///
/// 插件不一样：Loon 只在**导入那一刻**取一次，之后内容存在它自己的库里。
/// App 被系统杀掉、监听消失，已导入的规则照样生效。
/// 所以插件是「一次性交付 + 永久有效」，正好绕开「我们没有常驻服务器」这个硬约束。
///
/// 策略只写 `PROXY`，不写具体组名：
///   · 插件规则只允许 `DIRECT` / `REJECT` / `PROXY` 三种（官方 Plugin 文档）；
///   · `PROXY` 的语义是「用观众当前选中的策略组」——
///     不必知道组名，观众改组名也不会失效。
public enum LoonPlugin {
    /// 给 Loon 取插件用的路径后缀。
    public static let path = "/loon/plugin.lpx"

    /// 生成插件正文。
    ///
    /// - Parameter hosts: 已学到「代理腿超时」的 host；重复项会被去掉，空项忽略。
    public static func text(hosts: [String], title: String = "映匣 · 强制走节点",
                            date: Date = Date()) -> String {
        var unique: [String] = []
        for raw in hosts {
            let host = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, host.contains("."), !unique.contains(host) else { continue }
            unique.append(host)
        }
        // 没有记录时不给一条空规则 —— Loon 会把空插件判成「无法找到任何有效规则」。
        let body = unique.isEmpty
            ? "# 暂无可修正的站点"
            : unique.map { "DOMAIN-SUFFIX,\($0),PROXY" }.joined(separator: "\n")
        return """
        #!name = \(title)
        #!desc = 由映匣生成。这些站点的域名被 Loon 的域名/IP 规则判成了直连，端口段规则排在它们后面因此无效；这里改用 PROXY（= 你当前选中的策略组）显式覆盖。
        #!author = 映匣
        #!system = iOS,iPadOS
        #!date = \(stamp(date))
        #!tag = 映匣,直连修正
        #!type = normal

        [Rule]
        \(body)
        """
    }

    /// 插件里实际会生效的规则条数（UI 上用来决定要不要给「安装」入口）。
    public static func ruleCount(hosts: [String]) -> Int {
        var unique: Set<String> = []
        for raw in hosts {
            let host = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, host.contains(".") else { continue }
            unique.insert(host)
        }
        return unique.count
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
