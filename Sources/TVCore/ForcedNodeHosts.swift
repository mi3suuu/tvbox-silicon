import Foundation

/// 「Loon 判了直连、但我们非走节点不可」的域名表。
///
/// 为什么需要它：Loon 的规则顺序是 **域名规则 → IP 规则 → 其余（含 SRC-PORT）**，
/// 这一点在本仓库 `LoonPreset` 里对真机实测过。所以对「已被观众自己的规则判成直连」的站，
/// 我们把连接交给 Loon 也没用 —— Loon 照旧直连，直连被墙就是超时。
///
/// 观众不能逐个站点去查规则，所以这里记录**实测过「代理腿也不通」的 host**，
/// 设置页「Copy Loon Rule」会把它们拼成 `DOMAIN-SUFFIX` 行一起复制出去，
/// 观众粘到 `[Rule]` 顶部（`GEOIP,CN` 之前）就永久生效，新站出现时再复制一次即可。
///
/// 判定口径：代理腿**超时**（不是拒绝）才算。拒绝说明 Loon 没接这个连接，
/// 那是出口选择的问题，不是规则判定；只有「接了但不回」才说明 Loon 把这条连接直连了。
public final class ForcedNodeHosts: @unchecked Sendable {
    public static let shared = ForcedNodeHosts()

    private static let hostsKey = "forcedNodeHosts.v1"
    private static let targetKey = "forcedNodeTargetGroup.v1"
    private static let countsKey = "forcedNodeCounts.v1"
    /// 上限：观众真按这个列表维护规则时，几十条已经很多了。
    ///
    /// 2026-11-17：40 → 80。20 个小窗播 20 个不同源时，每个源至少贡献「入口域名」，
    /// 加上片单推导出的 CDN 域名就是 2–3 条/源 —— 40 条会在挂满 20 个窗时被写满，
    /// 而写满是**FIFO 丢弃**：刚学到的域名把上一轮刚学会的挤掉，
    /// 症状正是「有些窗一直取不到片单，而同样的源单独播又正常」。
    private static let limit = 80

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 记一条「这条腿不通」的 host。返回**是否刚刚新增**（调用方据此决定要不要排恢复探测）。
    ///
    /// 分档是这个方法的全部要点：
    ///   · 接口（`.catalog`）一次就记 —— 它就是这个源的身份证，错了整个源都进不去；
    ///   · 视频（`.media`）与图片（`.image`）要**两次**才记 —— 这两个是 CDN，一条流里几十个
    ///     请求，偶尔一个慢不该让整片域名永久绕出国；连着两次都不通才算真的判错了。
    ///
    /// ⛔ 不能因为「只关心入口」就只收 `.catalog`：入口进去之后，片单指向的是**别的域名**
    ///    （m3u8 在 A、分片在 B、海报在 C）。Loon 是按域名判的，我们少收一个域名，
    ///    观众看到的就是「能打开、点进去放不出来」。
    @discardableResult
    public func note(host: String, purpose: EgressPurpose = .catalog) -> Bool {
        let key = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.contains(".") else { return false }
        // 名单会变成永久的全局规则，所以「我们自己发出去的探测地址」绝不能进：
        // 它们的超时只说明代理腿没通，和「这个站被判直连」是两件事。
        guard !Self.utilityHosts.contains(key) else { return false }
        lock.lock()
        defer { lock.unlock() }
        var hosts = storedHosts()
        if hosts.contains(key) { return false }

        let required = purpose == .catalog ? 1 : 2
        var counts = defaults.dictionary(forKey: Self.countsKey) as? [String: Int] ?? [:]
        let count = (counts[key] ?? 0) + 1
        counts[key] = count
        defaults.set(counts, forKey: Self.countsKey)
        guard count >= required else { return false }

        hosts.append(key)
        if hosts.count > Self.limit {
            let overflow = hosts.count - Self.limit
            for host in hosts.prefix(overflow) { counts.removeValue(forKey: host) }
            hosts.removeFirst(overflow)
            defaults.set(counts, forKey: Self.countsKey)
        }
        defaults.set(hosts, forKey: Self.hostsKey)
        return true
    }

    /// 从**片单/播放地址**里推导出来的同源域名，立即收录。
    ///
    /// 为什么需要这条独立入口：分片是播放器自己拉的（走系统栈 → Loon），
    /// 失败根本经过不了我们的出口决策，也就学不到。而片单里写着它们的域名。
    /// 所以只要「入口已被判定必须走节点」，片单里出现的主机就是同一件事的一部分：
    /// 不一起收，观众看到的就是「片单取到了、点进去放不出来」。
    @discardableResult
    public func noteRelated(host: String) -> Bool {
        let key = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.contains("."), !Self.utilityHosts.contains(key) else { return false }
        guard !key.hasPrefix("127."), key != "localhost" else { return false }
        lock.lock()
        defer { lock.unlock() }
        var hosts = storedHosts()
        guard !hosts.contains(key) else { return false }
        hosts.append(key)
        if hosts.count > Self.limit { hosts.removeFirst(hosts.count - Self.limit) }
        defaults.set(hosts, forKey: Self.hostsKey)
        return true
    }

    /// 我们自己用来探测出口的公共地址，不属于任何源，不该被写成规则。
    private static let utilityHosts: Set<String> = [
        "api.ipify.org", "ipify.org", "www.ipify.org",
        "api64.ipify.org", "ipinfo.io", "api.ipinfo.io",
        "ifconfig.me", "icanhazip.com", "myip.ipip.net", "ip.sb", "api.ip.sb"
    ]

    public var hosts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedHosts()
    }

    /// Loon 里我们那条 `SRC-PORT` 规则指向的策略组名；读不到配置时留空，由调用方给一个占位。
    public var targetGroup: String? {
        get { defaults.string(forKey: Self.targetKey) }
        set {
            if let newValue, !newValue.isEmpty { defaults.set(newValue, forKey: Self.targetKey) }
            else { defaults.removeObject(forKey: Self.targetKey) }
        }
    }

    /// 纯规则行，给 Loon 的**订阅**用：不带策略名、不带注释。
    ///
    /// 订阅项的出口由 RULE-SET / 导入时选择的策略决定，文件里再写一遍第三列没有好处，
    /// 反而可能被判成无效行（真机上就踩过「无法找到任何有效规则」）。
    public func subscriptionRules() -> [String] {
        hosts.map { "DOMAIN-SUFFIX,\($0)" }
    }

    /// `[Remote Rule]` 的一整行，带 `update-interval`。
    ///
    /// ⛔ 这才是「无感」的唯一正路：`loon://update?sub=all` 会把 Loon 切到前台，
    ///    而 Remote Rule 的 `update-interval`（秒）是 Loon **自己在后台**按间隔重拉的。
    ///    把它设成 120，观众就不再需要任何手动动作，也不必被切 App。
    public func remoteRuleLine(url: URL, policy: String? = nil, interval: Int = 120) -> String {
        let target = policy ?? targetGroup ?? LoonPreset.defaultGroupName
        return "\(url.absoluteString), policy=\(target), tag=映匣强制节点, update-interval=\(interval), enabled=true"
    }

    /// 可直接粘进 `[Rule]` 的行。没有记录时返回 nil，调用方就别附带这一段。
    public func ruleFragment(fallbackTarget: String = "Proxy") -> String? {
        let hosts = hosts
        guard !hosts.isEmpty else { return nil }
        let target = targetGroup ?? fallbackTarget
        let lines = hosts.map { "DOMAIN-SUFFIX,\($0),\(target)" }
        return (["# 以下域名被 Loon 的域名/IP 规则判成直连，走端口段规则无效，需显式覆盖（放在 GEOIP,CN 之前）："]
                + lines).joined(separator: "\n")
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Self.hostsKey)
        defaults.removeObject(forKey: Self.countsKey)
    }

    private func storedHosts() -> [String] {
        let raw = defaults.stringArray(forKey: Self.hostsKey) ?? []
        // 老版本收进来过的探测地址（`api.ipify.org`）在这里顺手剔掉：
        // 名单会被写成永久规则，错一条就要观众自己去 Loon 里删。
        let cleaned = raw.filter { !Self.utilityHosts.contains($0.lowercased()) }
        if cleaned.count != raw.count { defaults.set(cleaned, forKey: Self.hostsKey) }
        return cleaned
    }
}

/// Loon 的 URL Scheme（官方 `nsloon.app/docs/Scheme`）。
///
/// 有了它，「加规则」不必让观众逐个粘贴：我们托管规则文件，
/// 再把 `loon://import?rules=<urlencoded>` 交给系统打开，Loon 自己去订阅。
public enum LoonScheme {
    /// 导入规则订阅。`url` 需可被 Loon 访问；同机时用局域网地址最稳（回环常被拒）。
    public static func importRules(_ url: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "loon"
        components.host = "import"
        components.queryItems = [URLQueryItem(name: "rules", value: url.absoluteString)]
        return components.url
    }

    /// 导入插件（`loon://import?plugin=`）。
    ///
    /// 比 `importRules` 更适合我们：插件只在导入时取一次，之后内容存在 Loon 自己的库里，
    /// 不依赖本机监听是否还活着 —— 也就不会出现「App 挂起后刷新失败」。
    public static func importPlugin(_ url: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "loon"
        components.host = "import"
        components.queryItems = [URLQueryItem(name: "plugin", value: url.absoluteString)]
        return components.url
    }

    /// 让 Loon 重新拉一遍全部订阅资源 —— 我们学到新域名后调它即可。
    public static var updateAll: URL? { URL(string: "loon://update?sub=all") }

    /// 本机托管的规则文件地址。回环常被 Loon 拒绝，所以优先用当前局域网地址。
    public static func hostedRulesURL(port: Int) -> URL? {
        let host = LocalNetwork.currentIPv4 ?? "127.0.0.1"
        return URL(string: "http://\(host):\(port)/loon/rules.list")
    }
}
