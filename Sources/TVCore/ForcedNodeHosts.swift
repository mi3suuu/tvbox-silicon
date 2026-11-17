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
    /// 上限：观众真按这个列表维护规则时，几十条已经很多了。
    private static let limit = 40

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 代理腿超时的 host。
    public func note(host: String) {
        let key = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.contains(".") else { return }
        lock.lock()
        defer { lock.unlock() }
        var hosts = storedHosts()
        guard !hosts.contains(key) else { return }
        hosts.append(key)
        if hosts.count > Self.limit { hosts.removeFirst(hosts.count - Self.limit) }
        defaults.set(hosts, forKey: Self.hostsKey)
    }

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
    }

    private func storedHosts() -> [String] {
        defaults.stringArray(forKey: Self.hostsKey) ?? []
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

    /// 让 Loon 重新拉一遍全部订阅资源 —— 我们学到新域名后调它即可。
    public static var updateAll: URL? { URL(string: "loon://update?sub=all") }

    /// 本机托管的规则文件地址。回环常被 Loon 拒绝，所以优先用当前局域网地址。
    public static func hostedRulesURL(port: Int) -> URL? {
        let host = LocalNetwork.currentIPv4 ?? "127.0.0.1"
        return URL(string: "http://\(host):\(port)/loon/rules.list")
    }
}
