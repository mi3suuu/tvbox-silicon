import Foundation

/// 本机的局域网地址，以及「拨代理该用哪个地址」的判定。
///
/// ## 为什么不能拨 127.0.0.1
///
/// Loon 的 `SRC-PORT` 规则**只对局域网来的连接生效**。实测（2026-11-17，同一台 iPhone，
/// Loon 的 wifi-access 端口 7221，目标 `ip-api.com`）：
///
/// ```
/// 本机直连                    → 112.47.166.102   （家里宽带）
/// LAN 地址 + 源端口 41521     → 50.7.250.106     （Loon 选中的节点）
/// LAN 地址 + 源端口 41621     → 112.47.166.102   （直连）
/// ```
///
/// 而 App 里的代理端点写的是 `127.0.0.1:7221`：连接是通的（Loon 监听在所有接口上），
/// 所以日志里每条都显示 `proxy=Loon src=:415xx`，看起来完全正常 —— 但请求从回环进来，
/// Loon 不做端口分类，直接按它自己的规则透传出去。用户看到的就是
/// 「该走代理的源在 Loon 眼里是原样透传，没用我们规定的端口」。
///
/// 结论：**只要端点写的是回环地址，就换成这台设备的局域网 IPv4 去拨。**
/// 端口那段（41500-41599 / 41600-41699）不受影响 —— `requiredLocalEndpoint` 仍然按 lane 绑。
///
/// 反过来也要能退：Loon 的「允许 Wi-Fi 访问」关掉时，局域网地址上根本没人监听，
/// 拨过去会立刻被拒。那种情况下退回回环（至少还能用 Loon 的普通规则），见 `ProxyDialHost`。
public enum LocalNetwork {

    /// 这台设备当前的局域网 IPv4；找不到（例如只有蜂窝）返回 nil。
    ///
    /// 只认 AF_INET、非回环、非 169.254（自分配）。优先 `en*`（Wi-Fi/以太网）与私有网段，
    /// 避开 VPN 常见的 `198.18.x`（Loon/Clash 的 TUN 地址）与 `10.211/10.37`（虚拟机网卡）——
    /// 拨到 TUN 自己的地址等于把请求塞回隧道口，不是我们想要的路径。
    public static var currentIPv4: String? {
        cached.value
    }

    /// 回环地址的几种写法。
    public static func isLoopback(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "127.0.0.1" || trimmed == "localhost" || trimmed == "::1" || trimmed == "[::1]"
    }

    /// 拨这台代理时该连哪个地址。
    ///
    /// 非回环地址原样返回（用户在别的机器上跑代理就是这种情况）；
    /// 回环且拿得到局域网地址 → 换成局域网地址；拿不到 → 保持回环。
    public static func dialHost(forProxyHost host: String) -> String {
        plan(stored: host, currentIPv4: currentIPv4).primary
    }

    /// 端点里存的是**上一次网络环境**下的地址，换网络就失效 —— 真机上踩过：
    /// 端点记着 `192.168.124.55`（家里 Wi-Fi），设备切到热点 `172.20.10.x` 之后，
    /// 中继拨这个地址必然失败，代理腿和直连腿一起挂，界面只剩「暂时无法加载此来源」。
    ///
    /// 所以拨号前按**当前**网络重算一次。纯函数，便于测试。
    public static func plan(stored: String, currentIPv4: String?) -> (primary: String, fallback: String?) {
        if isLoopback(stored) {
            // ⛔ 回环优先，局域网地址只做退路。
            //
            // 反过来试过一次，真机日志直接点名：
            //   `Loon unreachable at 192.168.124.55:7221; dialling 127.0.0.1 instead
            //    (turn on Allow Wi-Fi Access in Loon to use the port rules)`
            // Loon 的代理端口默认只接受本机回环，局域网要另开「允许 Wi-Fi 访问」。
            // 把局域网放前面等于每次冷启动都先撞一次失败再退回 —— 白等一个超时。
            guard let currentIPv4, currentIPv4 != stored else { return (stored, nil) }
            return (stored, currentIPv4)
        }
        // 存的是私有网段但不是本机现在的地址 → 多半是「本机代理」换了网段（Loon 就在这台手机上）。
        guard isPrivate(stored) else { return (stored, nil) }
        guard let currentIPv4, currentIPv4 != stored else { return (stored, nil) }
        return ("127.0.0.1", currentIPv4)
    }

    /// 私有网段（RFC1918）。公网代理不动。
    static func isPrivate(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return false }
        guard let a = UInt8(parts[0]), let b = UInt8(parts[1]) else { return false }
        if a == 10 { return true }
        if a == 192, b == 168 { return true }
        if a == 172, (16...31).contains(b) { return true }
        return false
    }

    // MARK: - 地址枚举

    private static let cached = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var cachedValue: String?
        private var readAt = Date.distantPast
        /// 网卡变化（切 Wi-Fi、开热点）后最多 5 秒就能反映出来，代价是枚举一次网卡。
        private let ttl: TimeInterval = 5

        var value: String? {
            lock.lock()
            defer { lock.unlock() }
            if Date().timeIntervalSince(readAt) < ttl { return cachedValue }
            let fresh = LocalNetwork.enumerate()
            cachedValue = fresh
            readAt = Date()
            return fresh
        }
    }

    private static func enumerate() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var best: (score: Int, address: String)?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let name = String(cString: entry.pointee.ifa_name).lowercased()
            guard let score = rank(name: name, address: text) else { continue }
            if best == nil || score > best!.score { best = (score, text) }
        }
        return best?.address
    }

    /// 给一张网卡打分；`nil` 表示这张网卡的地址不该被选中。
    ///
    /// 单独拆出来是为了能单测：真机上没法喂一张网卡列表进来。
    static func rank(name: String, address: String) -> Int? {
        guard !address.isEmpty, !address.hasPrefix("169.254."), !address.hasPrefix("127.") else { return nil }
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        // TUN 的假地址：Loon / Clash / Surge 都爱用 198.18.0.0/15，拨它等于把请求送回隧道。
        if octets[0] == 198 && (octets[1] == 18 || octets[1] == 19) { return nil }
        var score = 0
        if name.hasPrefix("en") { score += 40 }
        if octets[0] == 192 && octets[1] == 168 { score += 30 }
        else if octets[0] == 10 { score += 20 }
        else if octets[0] == 172, (16...31).contains(octets[1]) { score += 20 }
        else { score += 5 }
        return score
    }
}

/// 「这条代理现在该拨哪个地址」，带一次失败回落。
///
/// 默认按 `LocalNetwork.dialHost` 换成局域网地址；一旦某个 `host:port` 在局域网地址上
/// 连不通（最常见的原因是 Loon 的「允许 Wi-Fi 访问」关了），就把它记下来改拨回环 ——
/// 那种情况下回环至少还能用 Loon 自己的规则，比每条请求都失败要好。
public enum ProxyDialHost {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var loopbackOnly: Set<String> = []

    static func key(_ endpoint: CustomProxyEndpoint) -> String {
        "\(endpoint.scheme.rawValue)|\(endpoint.host)|\(endpoint.port)"
    }

    /// 现在该拨的地址（主选）。
    public static func primary(for endpoint: CustomProxyEndpoint) -> String {
        let planned = LocalNetwork.plan(stored: endpoint.host, currentIPv4: LocalNetwork.currentIPv4)
        guard planned.primary != endpoint.host else { return endpoint.host }
        let key = key(endpoint)
        let forced = lock.withLock { loopbackOnly.contains(key) }
        // 端点地址在本机网段上已不存在（换了网络）时，不能因为「上次记录过回环优先」就继续拨旧地址。
        if forced, LocalNetwork.isPrivate(endpoint.host),
           LocalNetwork.currentIPv4 != endpoint.host { return planned.primary }
        return forced ? endpoint.host : planned.primary
    }

    /// 主选失败后该退到哪；没有可退的返回 nil。
    public static func fallback(for endpoint: CustomProxyEndpoint) -> String? {
        let primary = primary(for: endpoint)
        guard primary != endpoint.host else { return nil }
        return endpoint.host
    }

    /// 主选连不通：记住，后续请求直接拨回环，不用每条都先失败一次。
    public static func notePrimaryFailed(_ endpoint: CustomProxyEndpoint) {
        let substituted = LocalNetwork.dialHost(forProxyHost: endpoint.host)
        guard substituted != endpoint.host else { return }
        lock.withLock { _ = loopbackOnly.insert(key(endpoint)) }
        Diagnostics.shared.record(.warning, "proxy",
            "proxy \(endpoint.name) unreachable at \(substituted):\(endpoint.port); dialling \(endpoint.host) instead (turn on Allow Wi-Fi Access in Loon to use the port rules)")
    }

    /// 改了端点（换地址/端口）就重新试一次主选。
    public static func forget(_ endpoint: CustomProxyEndpoint) {
        lock.withLock { loopbackOnly.remove(key(endpoint)) }
    }
}
