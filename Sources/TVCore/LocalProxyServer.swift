import Foundation
import Network
import Security

/// A loopback TCP proxy. URLSession (and AVPlayer) point at `http://127.0.0.1:<port>/…`, this server
/// reads the request, opens the target — direct, or through one of the viewer's proxies — and relays
/// bytes both ways.
///
/// Request path encodes the route, in one of two forms:
///   - `/d/<scheme>/<host>/<port>/<path>` — direct
///   - `/p/<proxyID>/<scheme>/<host>/<port>/<path>` — through that proxy
///
/// ## Why the upstream TLS is terminated here
///
/// The local side is plain HTTP, because AVPlayer will not trust a self-signed certificate for
/// `https://127.0.0.1`. So an `https://` target is reached by opening a TLS session *from this
/// server* — with the target's own name as SNI — and then the two sides are both plaintext HTTP and
/// can be relayed byte-for-byte without reframing. Certificate errors are ignored on purpose (media
/// CDNs with stale or mismatched chains are common, and Loon-style MITM proxies answer with their own
/// root), and each one is logged.
///
/// ## Proxying an `https` target
///
/// `Network`'s own proxy support does the CONNECT and then the TLS handshake over the tunnel, so the
/// server never has to speak TLS-over-CONNECT by hand: the proxy configuration goes on the privacy
/// context and `NWConnection` does the rest. Ask for TLS on the connection and the CONNECT for a
/// plain one.
///
/// ## One request per local connection
///
/// The upstream request is rewritten to `Connection: close` and the local connection is closed when
/// the upstream one ends, so a second request pipelined onto the same local connection can never be
/// answered with a request-target the origin does not understand. AVPlayer reconnects per request.
public final class LocalProxyServer: @unchecked Sendable {
    public static let shared = LocalProxyServer()

    private let queue = DispatchQueue(label: "tvbox.proxy.server")
    /// `port` is read from the main actor (`baseSync`) and written from the listener's queue, and
    /// `starting` is touched by whoever asks for the base address, so both live behind this lock.
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16?
    private var starting: Task<UInt16, Error>?

    /// The base address, starting the server if it is not up yet.
    ///
    /// One start at a time. Two callers could both read `starting == nil`, both create a listener,
    /// and the second one's port belonged to a listener nothing held a reference to any more — a
    /// port that answered and could never be shut down.
    public func base() async throws -> URL {
        if let running = Self.url(for: lock.withLock { port }) { return running }
        let task = lock.withLock { () -> Task<UInt16, Error> in
            if let starting { return starting }
            let task = Task { try await self.start() }
            starting = task
            return task
        }
        do {
            // `starting` is left in place once it succeeds: every later call returns the running
            // port above, and keeping the finished task costs nothing.
            return try Self.url(for: await task.value)
        } catch {
            // Nothing bound, so the next caller has to be allowed to try again.
            lock.withLock { starting = nil }
            throw error
        }
    }

    /// Starts the server in the background if it is not running, and returns the running port.
    ///
    /// Without this the whole feature was dead: `baseSync` reads `port`, `port` is only written by
    /// `start()`, and `start()` was only reachable from `base()`, which nothing called — so a viewer
    /// who added a proxy played straight out and never saw why. The player cannot await (it builds
    /// an item while drawing a frame), so it asks for `baseSync` and falls back to direct until the
    /// port is up; this makes sure it comes up.
    @discardableResult
    public func ensureStarted() -> Task<Void, Never> {
        Task { [self] in
            do {
                _ = try await base()
                Diagnostics.shared.record(.info, "proxy", "relay listening port=\(lock.withLock { port ?? 0 })")
            } catch {
                Diagnostics.shared.failure("proxy", "relay failed to start", error)
            }
        }
    }

    private static func url(for port: UInt16?) -> URL? {
        port.map { Self.url(for: $0) }
    }

    /// The loopback base URL for a bound port. The string is statically well-formed for any
    /// `UInt16`, so this never returns nil and needs no fallback.
    private static func url(for port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)/")!
    }

    /// The base address if the server is already running, else nil. Synchronous, for callers (the
    /// player) that can't await — they ask the server to start earlier and fall back to direct.
    public var baseSync: URL? {
        Self.url(for: lock.withLock { port })
    }

    /// The local address that relays `url` directly.
    public static func directURL(base: URL, url: URL) -> URL {
        encode(base: base, url: url, prefix: "d")
    }

    /// The local address that relays `url` through `proxyID`.
    public static func proxyURL(base: URL, url: URL, proxyID: String) -> URL {
        encode(base: base, url: url, prefix: "p/\(proxyID)")
    }

    /// `/d/<scheme>/<host>/<port>/<path>` and `/p/<id>/<scheme>/<host>/<port>/<path>`, sharing one
    /// encoder so the two forms cannot drift apart.
    private static func encode(base: URL, url: URL, prefix: String) -> URL {
        let scheme = url.scheme ?? "http"
        let host = url.host ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        let path = url.path.isEmpty ? "/" : url.path
        let query = url.query.map { "?\($0)" } ?? ""
        return URL(string: "\(base.absoluteString)\(prefix)/\(scheme)/\(host)/\(port)\(path)\(query)") ?? url
    }

    private func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        lock.withLock { listener = server }
        let queue = self.queue
        server.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.readRequest(connection, buffer: Data(), queue: queue)
        }
        // `NWListener` keeps calling the state handler for its whole life, so a `.failed` that
        // arrives after `.ready` would resume the same continuation a second time, which traps.
        let answer = StartAnswer()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            answer.arm(continuation)
            server.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let p = server.port?.rawValue else { return }
                    self.lock.withLock { self.port = p }
                    answer.finish(.success(p))
                case .failed(let error): answer.finish(.failure(error))
                case .cancelled: answer.finish(.failure(CancellationError()))
                default: break
                }
            }
            server.start(queue: queue)
        }
    }

    /// Answers the start continuation exactly once, whichever state gets there first.
    private final class StartAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<UInt16, Error>?

        func arm(_ continuation: CheckedContinuation<UInt16, Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func finish(_ result: Result<UInt16, Error>) {
            lock.lock()
            guard let continuation else {
                lock.unlock()
                return
            }
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        }
    }

    private static func readRequest(_ connection: NWConnection, buffer: Data, queue: DispatchQueue) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            var bytes = buffer
            if let data { bytes.append(data) }
            if let headerEnd = bytes.range(of: Data("\r\n\r\n".utf8)) {
                Self.route(connection, head: String(decoding: bytes[..<headerEnd.lowerBound], as: UTF8.self),
                           leftover: Data(bytes[headerEnd.upperBound...]), queue: queue)
            } else if error != nil || complete || bytes.count > 1 << 20 {
                connection.cancel()
            } else {
                readRequest(connection, buffer: bytes, queue: queue)
            }
        }
    }

    struct Target: Equatable {
        let proxyID: String?
        let scheme: String
        let host: String
        let port: UInt16
        let path: String
    }

    private static func route(_ connection: NWConnection, head: String, leftover: Data, queue: DispatchQueue) {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { connection.cancel(); return }
        let fields = requestLine.split(separator: " ")
        guard fields.count >= 2 else { connection.cancel(); return }
        guard let parsed = parse(String(fields[1])) else { connection.cancel(); return }

        // Rewrite to origin-form for the upstream and force it to close when done: this server
        // answers one request per local connection, and a keep-alive upstream would leave the local
        // socket open with nothing reading it.
        let rewritten = String(fields[0]) + " " + parsed.path + " " + String(fields.dropFirst(2).joined(separator: " "))
        var headers = lines.dropFirst().filter { line in
            let name = line.split(separator: ":", maxSplits: 1).first.map { $0.lowercased() } ?? ""
            // The local Host is 127.0.0.1; the origin needs its own.
            return name != "connection" && name != "keep-alive" && name != "host"
        }
        var hostHeader = parsed.host
        if Int(parsed.port) != (parsed.scheme.lowercased() == "https" ? 443 : 80) { hostHeader += ":\(parsed.port)" }
        headers.insert("Host: " + hostHeader, at: 0)
        headers.append("Connection: close")
        let rewrittenHead = ([rewritten] + headers).joined(separator: "\r\n")

        guard let port = NWEndpoint.Port(rawValue: parsed.port) else { connection.cancel(); return }
        let secure = parsed.scheme.lowercased() == "https"

        let endpoint: CustomProxyEndpoint?
        if let proxyID = parsed.proxyID {
            endpoint = CustomProxyStore.shared.proxy(for: proxyID)
            if endpoint == nil {
                // A route naming a proxy that has since been removed: go direct rather than fail, so
                // deleting an endpoint cannot break playback that used to work.
                Diagnostics.shared.record(.warning, "proxy", "route names a missing proxy; going direct target=\(parsed.host)")
            }
        } else {
            endpoint = nil
        }

        let built = connectionParameters(secure: secure, serverName: parsed.host, proxy: endpoint)
        let upstream = NWConnection(host: NWEndpoint.Host(parsed.host), port: port, using: built.parameters)
        // The port comes back to the pool as soon as this connection is done with it — on failure
        // and on cancellation as well as on a clean close, or a long session would drain the range.
        let sourcePort = built.sourcePort
        upstream.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let via = endpoint.map { "proxy=\($0.name)" } ?? "direct"
                let viaPort = sourcePort.map { " src=:\($0)" } ?? ""
                Diagnostics.shared.record(.debug, "proxy", "upstream ready \(via)\(viaPort) \(parsed.scheme)://\(parsed.host):\(parsed.port)")
                Self.sendAndRelay(connection, upstream: upstream, head: rewrittenHead, leftover: leftover)
            case .failed(let error):
                Diagnostics.shared.failure("proxy", "upstream failed \(parsed.scheme)://\(parsed.host):\(parsed.port) via=\(endpoint?.name ?? "direct")", error)
                if let sourcePort { SRCPortPool.shared.release(sourcePort) }
                connection.cancel(); upstream.cancel()
            case .cancelled:
                if let sourcePort { SRCPortPool.shared.release(sourcePort) }
                connection.cancel()
            default: break
            }
        }
        upstream.start(queue: queue)
    }

    /// TCP, plus TLS when the target needs it, plus the viewer's proxy when one is assigned.
    ///
    /// `Network` performs the `CONNECT` and then the TLS handshake over that tunnel by itself once
    /// the proxy is on the parameters, which is why no TLS-over-CONNECT code lives here.
    ///
    /// ## The source port
    ///
    /// A proxied connection is opened **from a port in `SRCPortPool`'s range** whenever the pool has
    /// one free, so Loon can route on `SRC-PORT` instead of on the hostname (see `SRCPortPool` for
    /// why that is the only way to make it use the selected line regardless of its own rules).
    /// `requiredLocalEndpoint` and `proxyConfigurations` do coexist — verified by holding a port and
    /// watching both paths fail with `EADDRINUSE` — so the bind and the proxy are set on the same
    /// parameters.
    ///
    /// `sourcePort` is released by the caller when the connection ends, never here: this function
    /// only builds the parameters.
    private static func connectionParameters(secure: Bool, serverName: String,
                                             proxy: CustomProxyEndpoint?) -> (parameters: NWParameters, sourcePort: UInt16?) {
        let tcp = NWProtocolTCP.Options()
        // Media segments arrive in bursts; the default window throttles a 4K stream on a close link.
        tcp.noDelay = true
        let params: NWParameters
        if secure {
            let tls = NWProtocolTLS.Options()
            if let sec = tls.securityProtocolOptions as sec_protocol_options_t? {
                serverName.withCString { sec_protocol_options_set_tls_server_name(sec, $0) }
                // Deliberately lenient: a media CDN with a stale chain, or a MITM proxy (Loon and
                // its kin) answering with its own root, is exactly the case this relay exists for.
                sec_protocol_options_set_verify_block(sec, { _, _, complete in
                    Diagnostics.shared.record(.debug, "proxy", "upstream certificate not verified (relay is lenient by design)")
                    complete(true)
                }, DispatchQueue.global(qos: .userInitiated))
            }
            params = NWParameters(tls: tls, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        // Both lanes dial from a fixed range, because the decision is two-sided: Loon is told to
        // send the proxy range through the selected line *and* to leave the direct range alone.
        //
        // This is the only place the lane reaches Loon. When the relay proxies, `Network` opens its
        // own connection to the proxy, so `requiredLocalEndpoint` decides the port Loon sees for the
        // CONNECT — which is what `SRC-PORT` matches. Measured: dialling a bare IP from the DIRECT
        // range bypassed the node that the same request took from the Proxy range or from an
        // ephemeral port. Domain rules still win over `SRC-PORT`; see `SRCPortPool`.
        let lane: SRCPortPool.Lane = proxy == nil ? .direct : .proxy
        var sourcePort: UInt16?
        if let port = SRCPortPool.shared.acquire(lane) {
            sourcePort = port
            params.requiredLocalEndpoint = .hostPort(host: "0.0.0.0", port: NWEndpoint.Port(rawValue: port)!)
        } else {
            // Lane exhausted: this request goes out on an ephemeral port, so Loon falls back to its
            // own rules for it. Worth a line, because the symptom is "the proxy did not apply to
            // this one request" with nothing else to go on.
            Diagnostics.shared.record(.warning, "proxy", "source port lane exhausted lane=\(lane); request will follow Loon's own rules")
        }
        // 「配了代理却悄悄直连」是这个功能最坏的失败方式：观众以为在走 Loon，
        // 实际上一条请求都没出去过。地址/端口不合法时必须留一行日志。
        if let proxy, proxy.address == nil || !(1...65535).contains(proxy.port) {
            Diagnostics.shared.record(.warning, "proxy",
                "endpoint unusable (host=\"\(proxy.host)\" port=\(proxy.port)); this request goes direct")
        }
        if let proxy, let host = proxy.address.flatMap({ NWEndpoint.Host($0) }), let port = NWEndpoint.Port(rawValue: UInt16(clamping: proxy.port)) {
            let context = NWParameters.PrivacyContext(description: "tvbox.proxy.\(proxy.id)")
            let endpoint = NWEndpoint.hostPort(host: host, port: port)
            let configuration: ProxyConfiguration
            switch proxy.scheme {
            case .socks5:
                configuration = ProxyConfiguration(socksv5Proxy: endpoint)
            case .https:
                // The proxy itself is reached over TLS — a different thing from the target's TLS,
                // which is why it gets its own options here.
                let tls = NWProtocolTLS.Options()
                if let sec = tls.securityProtocolOptions as sec_protocol_options_t? {
                    host.debugDescription.withCString { sec_protocol_options_set_tls_server_name(sec, $0) }
                    sec_protocol_options_set_verify_block(sec, { _, _, complete in complete(true) },
                                                          DispatchQueue.global(qos: .userInitiated))
                }
                configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: tls)
            case .http:
                configuration = ProxyConfiguration(httpCONNECTProxy: endpoint)
            }
            if !proxy.username.isEmpty {
                configuration.applyCredential(username: proxy.username, password: proxy.password)
            }
            context.proxyConfigurations = [configuration]
            params.setPrivacyContext(context)
        }
        return (params, sourcePort)
    }

    private static func sendAndRelay(_ connection: NWConnection, upstream: NWConnection, head: String, leftover: Data) {
        // Both sides are plaintext HTTP at this point — TLS, when the target had it, ended at this
        // server — so the request bytes go out as written and the response comes back as the origin
        // wrote it. No reframing, no chunked-encoding handling, nothing to get wrong per format.
        let toUpstream = Data(head.utf8) + Data("\r\n\r\n".utf8) + leftover
        upstream.send(content: toUpstream, completion: .contentProcessed { error in
            if let error {
                Diagnostics.shared.failure("proxy", "upstream send failed", error)
                connection.cancel(); upstream.cancel(); return
            }
            Self.pump(from: connection, to: upstream)
            Self.pump(from: upstream, to: connection)
        })
    }

    private static func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { _ in })
            }
            if error != nil || complete {
                destination.send(content: nil, completion: .contentProcessed { _ in destination.cancel() })
            } else {
                pump(from: source, to: destination)
            }
        }
    }

    /// Parses `/d/<scheme>/<host>/<port>/<path>` or `/p/<proxyID>/<scheme>/<host>/<port>/<path>`.
    static func parse(_ target: String) -> Target? {
        // Split the query off first: a query can contain "/", and letting those slashes become path
        // segments put the wrong pieces in the port slot for any address with a query string.
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let query = pieces.count > 1 ? "?" + pieces[1] : ""
        let parts = pieces[0].split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 4 else { return nil }
        var index = 0
        let proxyID: String?
        if parts[0] == "p" {
            guard parts.count >= 5 else { return nil }
            proxyID = String(parts[1]); index = 2
        } else if parts[0] == "d" {
            proxyID = nil; index = 1
        } else { return nil }
        let scheme = String(parts[index])
        let host = String(parts[index + 1])
        guard let port = UInt16(parts[index + 2]) else { return nil }
        let path = "/" + parts[(index + 3)...].joined(separator: "/") + query
        return Target(proxyID: proxyID, scheme: scheme, host: host, port: port, path: path)
    }
}
