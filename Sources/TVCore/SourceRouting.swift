import Foundation
import Observation

/// How one source (or a whole subscription) reaches its upstream.
///
/// A source that can be reached directly on this network may go down at any time; its domain may be
/// SNI-blocked, or its host may start refusing plain connections. `SourceRouting` remembers the viewer's
/// choice and, in `.auto`, follows `SourceHealth` so a source that stops answering directly is retried
/// through the relay and switched back once the direct line recovers.
public enum SourceRoute: String, Codable, CaseIterable, Sendable {
    /// Follow connectivity: direct first, relay when the direct line is failing.
    case auto
    /// Always hit the source's own address (its `api` as imported).
    case direct
    /// Always route through the relay, whatever the direct line is doing.
    case proxy

    public var title: String {
        switch self {
        case .auto: return L10n.text("Auto")
        case .direct: return L10n.text("Direct")
        case .proxy: return L10n.text("Proxy")
        }
    }
}

/// Subscription-qualified routing choices. The key scheme matches `PinnedSources` and `HiddenSources`,
/// so a choice survives re-imports and merges; a source not listed falls back to its subscription's route.
@MainActor @Observable public final class SourceRouting: KeyedPersistedStore<String> {
    private static let baseKey = "sourceRouting.v1"
    /// 该环境下的 key。源改名 / 改 API、线路开关、源路由都是**偏好**，没有记录可打戳，
    /// 只能按 storage key 分环境（口径同 `PinnedSources`）：默认环境保留原 key，升级不丢旧偏好。
    /// 不分环境时，A 环境里把某源改名成「我的源」、或把某条线路设为代理/隐藏，切到 B 环境
    /// 照样生效 —— 同一份订阅在两个环境下 `origin + sourceKey` 完全一致，必中。
    public var environmentID: UUID?
    public var defaultEnvironmentID: UUID?
    private var scopedKey: String {
        EnvironmentScopedKey.key(Self.baseKey, environment: environmentID, default: defaultEnvironmentID)
    }

    /// Reads the choices stored as raw-value strings (the pre-existing on-disk format).
    public init(defaults: UserDefaults = .standard) {
        let raw = defaults.dictionary(forKey: Self.baseKey) as? [String: String] ?? [:]
        let values = raw.compactMapValues { SourceRoute(rawValue: $0)?.rawValue }
        super.init(defaults: defaults, storageKey: Self.baseKey, values: values)
    }

    /// 切环境后按新 key 重读（存的是 raw string，格式与磁盘一致）。
    public func reloadForEnvironment() {
        let raw = defaults.dictionary(forKey: scopedKey) as? [String: String] ?? [:]
        let next = raw.compactMapValues { SourceRoute(rawValue: $0)?.rawValue }
        guard next != values else { return }
        values = next
        bump(notify: false)
    }

    /// 删环境时清掉它名下的路由偏好。
    public static func delete(environment: UUID, defaults: UserDefaults = .standard, default defaultID: UUID?) {
        guard let defaultID, environment != defaultID else { return }
        defaults.removeObject(forKey: EnvironmentScopedKey.key(baseKey, environment: environment, default: defaultID))
    }

    private func key(_ site: Site, origin: URL) -> String {
        EpisodeSkipSettings.scope(origin: site.origin(or: origin), source: site.sourceKey, video: "")
    }

    /// The explicit route for this source, or nil when it follows its subscription (or `.auto`).
    public func route(_ site: Site, origin: URL) -> SourceRoute? {
        values[key(site, origin: origin)].flatMap(SourceRoute.init(rawValue:))
    }

    /// The route actually used: an explicit choice first, then the subscription's own route.
    public func effectiveRoute(_ site: Site, origin: URL, subscription: SourceRoute?) -> SourceRoute {
        values[key(site, origin: origin)].flatMap(SourceRoute.init(rawValue:)) ?? subscription ?? .auto
    }

    public func set(_ route: SourceRoute, for site: Site, origin: URL) {
        let k = key(site, origin: origin)
        values[k] = route.rawValue
        persist()
    }

    /// Clears an explicit choice so the source follows its subscription again.
    public func clear(_ site: Site, origin: URL) {
        let k = key(site, origin: origin)
        guard values.removeValue(forKey: k) != nil else { return }
        persist()
    }

    /// The list merged with other devices', dropping raw values this build does not recognise.
    public override func adopt(_ raw: [String: String]) {
        let next = raw.compactMapValues { SourceRoute(rawValue: $0)?.rawValue }
        guard next != values else { return }
        values = next
        persist(notify: notifyOnAdopt)
    }

    /// Stores the raw-value strings directly, keeping the pre-existing on-disk format.
    public override func write() {
        defaults.set(values, forKey: scopedKey)
    }
}

/// Rewrites a source's `api` between its own address and the address the app relays it through.
///
/// ## 中转这件事现在是映匣自己的
///
/// 以前这里写死了一台公共服务器的中转（`149.104.28.149:8100`）：`.proxy` 会把源地址改写成
/// `/cms/<token>/<host>/<path>`，请求和签名都捏在那台机器手里 —— 它一关，所有「中转」源一起
/// 变黑；它也看不到这台手机的任何东西，却必须信任它。
///
/// 现在中转 = **本机回环中继**（`LocalProxyServer`）+ **观众自己配的出口代理**（`CustomProxyStore`）：
///   · 源地址改写成 `http://127.0.0.1:<port>/p/<proxyID>/<scheme>/<host>/<port><path>`；
///   · 字节由 App 自己搬运，出去的那条腿走你选的那台代理（HTTP / HTTPS / SOCKS5）；
///   · 没配代理就是 `/d/…`，等于直连 —— 那样中转没有意义，所以 `.auto` 不会替你翻到中转。
///
/// ⚠️ 一句必须说清的话：**回环中继不能让一个被墙的源变得能访问**。它改变的是「从哪条腿出去」
/// 和「请求长什么样」，不改「这台手机能不能连上那台机器」。149 之所以能救活那些源，是因为它
/// 是一台境外服务器；本机做不到这件事。要救，只有观众自己给一个出口。
public enum SourceRelay {
    /// 旧公共中继的地址，**只用于解包**：历史订阅里带过来的中转地址要能还原成真实地址。
    /// 新的中转地址不再由它产生，也不会再出现在任何随包数据里。
    private static let legacyHost = "149.104.28.149"
    private static let legacyPort = 8100

    /// Whether an address is one of the old public relay's (and therefore needs unwrapping).
    public static func isRelayed(_ api: String) -> Bool {
        api.contains("\(legacyHost):\(legacyPort)/cms/") || api.contains("\(legacyHost):\(legacyPort)/cmsr/")
    }

    /// The source's own (direct) address, stripping the old relay prefix when present.
    public static func directAddress(_ api: String) -> String {
        let needle = "\(legacyHost):\(legacyPort)/"
        guard let range = api.range(of: needle) else { return api }
        let after = api[range.upperBound...]
        // /cms/<token>/<host>/<path> or /cmsr/<token>/<host>/<path>
        let parts = after.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return api }
        // parts[0] is cms|cmsr, parts[1] is the token, the rest is host + optional path
        guard parts.count >= 3 else { return api }
        // cmsr marks a source that was https; the relay itself is always http.
        let scheme = parts[0] == "cmsr" ? "https" : "http"
        return "\(scheme)://" + parts.dropFirst(2).joined(separator: "/")
    }

    /// The loopback address that relays a source's own address, through `proxyID` when one is given.
    ///
    /// Returns the address unchanged when the loopback server is not up or the api is not HTTP
    /// (a JAR class, `assets://`, a local file): those are not URLs the relay can carry.
    public static func relayedAddress(_ api: String, base: URL?, proxyID: String?) -> String {
        let direct = directAddress(api)
        guard let base, let url = URL(string: direct), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return direct }
        let loopback = proxyID.map { LocalProxyServer.proxyURL(base: base, url: url, proxyID: $0) }
            ?? LocalProxyServer.directURL(base: base, url: url)
        return loopback.absoluteString
    }

    /// Applies a route to a source's api string.
    public static func apply(_ route: SourceRoute, to api: String, base: URL? = nil, proxyID: String? = nil) -> String {
        switch route {
        case .direct: return directAddress(api)
        // 中转必须有出口才有意义：没有代理就不包装，免得绕一圈回环还是从同一条腿出去。
        case .proxy: return proxyID == nil ? directAddress(api) : relayedAddress(api, base: base, proxyID: proxyID)
        case .auto: return directAddress(api)
        }
    }
}

extension Site {
    /// A copy whose `api` is rewritten to the given route. Only native (type 1/4) CMS endpoints can be
    /// relayed; a JAR/csp class or built-in source is returned unchanged.
    public func routed(_ route: SourceRoute, relayBase: URL? = nil, proxyID: String? = nil) -> Site {
        guard native, !api.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return self }
        let next = SourceRelay.apply(route, to: api, base: relayBase, proxyID: proxyID)
        guard next != api else { return self }
        var raw = self.raw
        raw["api"] = .string(next)
        var copy = Site(key: key, name: name, type: type, api: next, raw: raw)
        copy.provenance = provenance
        copy.detectedRuntime = detectedRuntime
        return copy
    }
}
