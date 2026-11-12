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
    }

    // MARK: Reads

    public var endpoints: [CustomProxyEndpoint] { lock.withLock { _endpoints } }
    public func proxy(for id: String) -> CustomProxyEndpoint? { lock.withLock { _endpoints.first { $0.id == id } } }
    public func route(origin: URL, sourceKey: String) -> CustomProxyRoute {
        lock.withLock { _routes[Self.key(origin: origin, sourceKey: sourceKey)] ?? .direct }
    }

    // MARK: Mutations

    public func upsert(_ endpoint: CustomProxyEndpoint) {
        lock.withLock {
            if let index = _endpoints.firstIndex(where: { $0.id == endpoint.id }) { _endpoints[index] = endpoint }
            else { _endpoints.append(endpoint) }
            persistLocked()
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
