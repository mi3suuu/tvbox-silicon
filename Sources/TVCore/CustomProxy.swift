import Foundation
import Network
import Observation

/// An outbound proxy the viewer defined: HTTP, HTTPS (an HTTP CONNECT proxy), or SOCKS5,
/// at a host and port with an optional username and password.
public struct CustomProxyEndpoint: Codable, Hashable, Identifiable, Sendable {
    public enum Scheme: String, Codable, CaseIterable, Identifiable, Sendable {
        case http, https, socks5
        public var id: String { rawValue }
        public var title: String { rawValue.uppercased() }
    }

    public let id: String
    public var name: String
    public var scheme: Scheme
    public var host: String
    public var port: Int
    public var username: String
    public var password: String

    public init(id: String = UUID().uuidString, name: String, scheme: Scheme, host: String, port: Int,
                username: String = "", password: String = "") {
        self.id = id; self.name = name; self.scheme = scheme; self.host = host; self.port = port
        self.username = username; self.password = password
    }

    var address: String? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, (1...65535).contains(port) else { return nil }
        return host
    }

    // MARK: 编解码 —— 凭证明文不进盘

    /// `username` / `password` are stored obfuscated so a copied preferences file does not show
    /// proxy credentials at a glance. This is **not** encryption — a single XOR + Base64 layer —
    /// and exists only because the settings blob is otherwise plain JSON. The real fix would be
    /// Keychain, which is deliberately out of scope here.
    private static let obfuscationKey = Array("yingxia.customproxy".utf8)
    private static let obfuscationMarker = "v1:"

    private enum CodingKeys: String, CodingKey {
        case id, name, scheme, host, port, username, password
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        scheme = try container.decode(Scheme.self, forKey: .scheme)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = Self.deobfuscate(try container.decodeIfPresent(String.self, forKey: .username) ?? "")
        password = Self.deobfuscate(try container.decodeIfPresent(String.self, forKey: .password) ?? "")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(scheme, forKey: .scheme)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(Self.obfuscate(username), forKey: .username)
        try container.encode(Self.obfuscate(password), forKey: .password)
    }

    private static func obfuscate(_ text: String) -> String {
        let key = obfuscationKey
        let bytes = Array(text.utf8)
        let mixed = bytes.enumerated().map { $0.element ^ key[$0.offset % key.count] }
        return obfuscationMarker + Data(mixed).base64EncodedString()
    }

    private static func deobfuscate(_ text: String) -> String {
        // Values saved by earlier builds carry no marker and are plain text.
        guard text.hasPrefix(obfuscationMarker) else { return text }
        let payload = String(text.dropFirst(obfuscationMarker.count))
        guard let data = Data(base64Encoded: payload) else { return text }
        let key = obfuscationKey
        let bytes = data.enumerated().map { $0.element ^ key[$0.offset % key.count] }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Which way one source's requests leave: direct, or through one of the configured proxies.
public enum CustomProxyRoute: Codable, Hashable, Sendable {
    case direct
    case proxy(String)   // CustomProxyEndpoint.id
    public var proxyID: String? { if case .proxy(let id) = self { return id } else { return nil } }
    public var isProxy: Bool { proxyID != nil }
}

/// The viewer's outbound proxies and the per-source routes. The player asks here whether a source
/// goes direct or through one of them; a proxy that cannot be reached falls back to direct, and
/// `LocalProxyServer` logs which of the two happened.
public final class CustomProxyStore: @unchecked Sendable {
    public static let shared = CustomProxyStore()

    private static let endpointsKey = "proxyEndpoints.v1"
    private static let routesKey = "proxyRoutes.v1"
    private static let defaultKey = "proxyDefault.v1"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var _endpoints: [CustomProxyEndpoint] = []
    private var _routes: [String: CustomProxyRoute] = [:]

    /// `defaults` is kept, not just read once: writing through `.standard` while reading from the
    /// injected suite meant a store built for a test or a QA session read its own empty list back on
    /// the next launch, and a route the viewer set was silently written somewhere else.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.endpointsKey),
           let saved = try? JSONDecoder().decode([CustomProxyEndpoint].self, from: data) { _endpoints = saved }
        if let data = defaults.data(forKey: Self.routesKey),
           let saved = try? JSONDecoder().decode([String: CustomProxyRoute].self, from: data) { _routes = saved }
        // 老版本允许同一台代理存多条（点两次「添加 Loon」就是两条 `127.0.0.1:7221`）。
        // 两条重复记录会让「只配了一台 → 它就是默认出口」这条规则失效，结果是**全站直连**。
        // 这里在加载后整理一次，并把路由/默认出口一起改指到保留的那条。
        let before = _endpoints.count
        collapseAllDuplicatesLocked()
        if _endpoints.count != before { persistLocked() }
    }

    // MARK: Reads

    public var endpoints: [CustomProxyEndpoint] { lock.withLock { _endpoints } }
    public func proxy(for id: String) -> CustomProxyEndpoint? { lock.withLock { _endpoints.first { $0.id == id } } }
    public func route(origin: URL, sourceKey: String) -> CustomProxyRoute {
        lock.withLock { _routes[Self.key(origin: origin, sourceKey: sourceKey)] ?? .direct }
    }

    // MARK: Mutations

    /// 同一台代理的判据：**同协议 + 同主机 + 同端口**。
    ///
    /// 名字不参与：观众把「Loon」再导入一次时名字是一样的，改了名也不该变成两台。
    /// 账号密码也不参与 —— 同一台机器换密码不是「另一台代理」，而是一条要更新的记录。
    private func identityKey(_ endpoint: CustomProxyEndpoint) -> String {
        // ⛔ host 要 trim：`"127.0.0.1 "` 与 `"127.0.0.1"` 会被当成两台，
        //    于是又回到「配了多台且没指定 → 全站直连」的老坑（本轮 P0 的形态之一）。
        "\(endpoint.scheme.rawValue)|\(endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(endpoint.port)"
    }

    /// 加一台代理（或更新已有的那一台）。
    ///
    /// ## 为什么必须去重
    ///
    /// 观众点两次「添加 Loon」会得到两条一模一样的 `127.0.0.1:7221`。而「默认出口」的规则是
    /// 「只配了一台代理 → 那台就是出口」（见 `fallbackEndpoint`），
    /// 两条重复记录让它变成「配了多台又没指定」→ **返回 nil → 全站直连**。
    /// 现象就是：Loon 明明设置好了，App 却一条请求都没发给它，
    /// Loon 那边只看到临时端口 —— 与用户报的「没有按我们规定好的端口去连接」完全一致。
    ///
    /// 去重时**保留原有 id**：源路由、行路由都按 id 记，换 id 等于把它们一起作废。
    public func upsert(_ endpoint: CustomProxyEndpoint) {
        lock.withLock {
            let identity = identityKey(endpoint)
            if let index = _endpoints.firstIndex(where: { $0.id == endpoint.id }) {
                _endpoints[index] = endpoint
                // 改名/改端口之后可能和另一条撞上，撞了就并掉后出现的那条。
                collapseDuplicatesLocked(keeping: index, identity: identity)
            } else if let index = _endpoints.firstIndex(where: { identityKey($0) == identity }) {
                let existing = _endpoints[index]
                _endpoints[index] = CustomProxyEndpoint(id: existing.id, name: endpoint.name,
                                                        scheme: endpoint.scheme, host: endpoint.host,
                                                        port: endpoint.port,
                                                        username: endpoint.username,
                                                        password: endpoint.password)
            } else {
                _endpoints.append(endpoint)
            }
            persistLocked()
        }
    }

    /// 把与 `keeping` 同一身份的多余记录删掉，并把指向它们的路由改指到保留的那条。
    private func collapseDuplicatesLocked(keeping index: Int, identity: String) {
        let keepID = _endpoints[index].id
        let duplicates = _endpoints.filter { $0.id != keepID && identityKey($0) == identity }
        guard !duplicates.isEmpty else { return }
        let duplicateIDs = Set(duplicates.map(\.id))
        _endpoints.removeAll { duplicateIDs.contains($0.id) }
        for (key, route) in _routes where route.proxyID.map(duplicateIDs.contains) == true {
            _routes[key] = .proxy(keepID)
        }
        if let fallback = defaultProxyID, duplicateIDs.contains(fallback) {
            defaults.set(keepID, forKey: Self.defaultKey)
        }
    }

    /// 启动时整理一遍历史记录：老版本允许同一台代理存多条。
    private func collapseAllDuplicatesLocked() {
        var index = 0
        while index < _endpoints.count {
            collapseDuplicatesLocked(keeping: index, identity: identityKey(_endpoints[index]))
            index += 1
        }
    }

    public func removeEndpoint(id: String) {
        lock.withLock {
            _endpoints.removeAll { $0.id == id }
            // Collect the keys first: mutating `_routes` while enumerating it is undefined, and a
            // removed proxy's route should fall back to the default `.direct` (an absent key), not
            // be persisted as an explicit `.direct` entry that `setRoute(.direct)` would otherwise
            // drop.
            let stale = _routes.compactMap { $0.value.proxyID == id ? $0.key : nil }
            for key in stale { _routes.removeValue(forKey: key) }
            persistLocked()
        }
    }

    public func setRoute(_ route: CustomProxyRoute, origin: URL, sourceKey: String) {
        lock.withLock {
            let key = Self.key(origin: origin, sourceKey: sourceKey)
            switch route {
            case .direct: _routes.removeValue(forKey: key)
            case .proxy: _routes[key] = route
            }
            persistLocked()
        }
    }

    /// The endpoint a source's requests should leave through, or nil when it goes direct.
    ///
    /// `LocalProxyServer` asks this while building a connection; it used to open a hand-written
    /// CONNECT/SOCKS5 tunnel, which could not carry TLS to an `https` target and never ran outside
    /// the playback item. `Network` does the handshake over the tunnel instead.
    public func endpoint(origin: URL, sourceKey: String) -> CustomProxyEndpoint? {
        guard let id = route(origin: origin, sourceKey: sourceKey).proxyID else { return nil }
        return proxy(for: id)
    }

    // MARK: 默认出口
    //
    // 149 那台公共中继拆掉之后，一批源（`_route: 需代理`，见 route.json）在本机上直连不通、
    // 经境外出口可读。它们此前能看，全靠那台服务器替它们出去 —— 现在要看观众的出口。
    //
    // 但按源一个个配代理是不现实的：源列表里有几百个，观众的耐心只有一次。所以这里给一个
    // 「默认出口」的概念：显式指定优先；只配了一台代理时，那台就是出口（他配它就是为了出去）。

    /// 观众指定的默认出口。nil = 没指定。
    public var defaultProxyID: String? {
        get { lock.withLock { defaults.string(forKey: Self.defaultKey) } }
        set {
            lock.withLock {
                if let newValue, !newValue.isEmpty { defaults.set(newValue, forKey: Self.defaultKey) }
                else { defaults.removeObject(forKey: Self.defaultKey) }
            }
        }
    }

    /// 代理腿是否绑 `41500-41599`，让 Loon 的 `SRC-PORT` 规则把它推进自己的策略组。
    ///
    /// 默认**关**。真机上这一段几乎总是被写成 `SRC-PORT,41500-41599,节点选择`：
    /// 于是所有「设成代理」的源都被推去境外节点，国内 api 与视频 CDN 直接不可用
    /// （`NWError -9816` / `-1200`），而同一个源在「直连 + Loon」下是好的。
    /// 不绑端口时 Loon 会按它自己的域名 / `GEOIP,CN,DIRECT` 规则走 —— 那才是用户配这套东西的本意。
    /// 只有在真的想让「代理」= 「强制走节点」时才打开它。
    public static let forceNodeLaneKey = "proxyForceNodeLane.v1"

    public var forceNodeLane: Bool {
        get { lock.withLock { defaults.bool(forKey: Self.forceNodeLaneKey) } }
        set { lock.withLock { defaults.set(newValue, forKey: Self.forceNodeLaneKey) } }
    }

    /// 直连不通时该从哪台代理出去。
    ///
    /// 两条规则，都刻意保守：
    ///   · 显式指定了默认出口 → 用它；
    ///   · 只配了一台代理 → 用它（让他为 90 个源逐个点代理，等于这个功能不存在）；
    ///   · 配了两台以上又没指定 → **返回 nil**。替他挑一台等于替他决定请求从哪条腿出去，
    ///     而这正是当初拆掉 149 的理由。
    public var fallbackEndpoint: CustomProxyEndpoint? {
        if let id = defaultProxyID, let chosen = proxy(for: id) { return chosen }
        let all = endpoints
        return all.count == 1 ? all[0] : nil
    }

    /// Every route as stored, for the full-backup and iCloud snapshots.
    public var routes: [String: CustomProxyRoute] { lock.withLock { _routes } }

    /// Replaces the whole route table, for those restores.
    public func replaceRoutes(_ routes: [String: CustomProxyRoute]) {
        lock.withLock {
            _routes = routes
            persistLocked()
        }
    }

    nonisolated public static func key(origin: URL, sourceKey: String) -> String {
        origin.absoluteString + "|" + sourceKey
    }

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(_endpoints) { defaults.set(data, forKey: Self.endpointsKey) }
        if let data = try? JSONEncoder().encode(_routes) { defaults.set(data, forKey: Self.routesKey) }
    }
}

extension NSLock {
    @inline(__always) func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}

/// Main-actor facade the settings UI observes. `revision` changes when endpoints or routes change.
@MainActor @Observable public final class CustomProxyRouter {
    public static let shared = CustomProxyRouter()
    public let store = CustomProxyStore.shared
    public private(set) var revision = 0
    public init() {}
    public func touch() { revision += 1 }
}
