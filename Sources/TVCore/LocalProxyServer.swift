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

        // 拨代理的地址可能不是端点上写的那个（见 `LocalNetwork`）：回环地址要换成局域网地址，
        // 否则 Loon 收下连接却按它自己的规则透传 —— 用户看到的就是「没用我们规定的端口」。
        //
        // 同一个目标已经连续在代理腿上失败过几次：这一条就直接走直连，不再先赔一次失败。
        // 剧集列表一次并发几十个请求，每条都「先挂一次再重试」会让整页慢到像没反应。
        let directNow = endpoint != nil && ProxyCircuit.isOpen(host: parsed.host)
        let state = TunnelState(connection: connection, head: rewrittenHead, leftover: leftover,
                                scheme: parsed.scheme, host: parsed.host, port: parsed.port,
                                path: parsed.path, endpoint: endpoint, queue: queue)
        Self.open(state, dialHost: directNow ? nil : endpoint.map { ProxyDialHost.primary(for: $0) },
                  forceDirect: directNow)
    }

    /// 代理腿按目标熔断：同一个 host 连续失败几次之后，短时间内直接走直连。
    ///
    /// 不是「禁用代理」，而是「别对同一个已经证明不通的目标反复尝试」。任何一次走代理成功
    /// 都会把计数清零，所以它只会影响真正不通的那些目标。
    enum ProxyCircuit {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var failures: [String: (count: Int, until: Date)] = [:]
        private static let threshold = 3
        private static let cooldown: TimeInterval = 60

        static func isOpen(host: String) -> Bool {
            lock.withLock {
                guard let record = failures[host] else { return false }
                if record.count < threshold { return false }
                if Date() >= record.until { failures[host] = nil; return false }
                return true
            }
        }

        static func noteFailure(host: String) {
            lock.withLock {
                let count = (failures[host]?.count ?? 0) + 1
                let until = Date().addingTimeInterval(cooldown)
                failures[host] = (count, until)
                if count == threshold {
                    Diagnostics.shared.record(.warning, "proxy",
                        "proxy failed \(count)× for \(host); going direct for \(Int(cooldown))s")
                }
            }
        }

        static func noteSuccess(host: String) {
            lock.withLock { if failures[host] != nil { failures[host] = nil } }
        }
    }

    /// 一次隧道尝试的状态。抽成类是因为「局域网地址失败后退回回环」要在
    /// `@Sendable` 的状态回调里再发起一次连接 —— 局部函数捕获可变变量在 Swift 6 下过不了。
    private final class TunnelState: @unchecked Sendable {
        let connection: NWConnection
        let head: String
        let leftover: Data
        let scheme: String
        let host: String
        let port: UInt16
        /// 原始 path + query，系统栈兜底要用它重新拼 URL。
        let path: String
        let endpoint: CustomProxyEndpoint?
        let queue: DispatchQueue
        private let lock = NSLock()
        private var retried = false
        private var rebinds = 0
        private var directFallback = false
        private var systemFallback = false
        private var retrying = false

        init(connection: NWConnection, head: String, leftover: Data, scheme: String,
             host: String, port: UInt16, path: String, endpoint: CustomProxyEndpoint?, queue: DispatchQueue) {
            self.connection = connection
            self.head = head
            self.leftover = leftover
            self.scheme = scheme
            self.host = host
            self.port = port
            self.path = path
            self.endpoint = endpoint
            self.queue = queue
        }

        /// 只会成功一次：回退只做一次，别在两条腿之间来回弹。
        func claimRetry() -> Bool {
            lock.withLock {
                guard !retried else { return false }
                retried = true
                return true
            }
        }

        /// 源端口绑定失败（`EADDRINUSE`）后的下一手。
        ///
        /// 这条路径曾经把整个代理模式打死：一次回退重拨会把刚 `cancel()` 的端口还回池子，
        /// 池子按 LIFO 又把同一个端口发给下一条连接，绑定失败 → 再还 → 再发同一个，
        /// 于是一条坏端口能吃掉之后所有请求（真机实测 3 分钟 558 次 `NWError 48`）。
        /// 所以绑定失败不再算「这条链路坏了」，只算「这个端口脏了」：换一个端口重来，
        /// 两次都撞上就改用临时端口 —— 请求能出去比端口落在规定段里重要。
        enum Rebind { case anotherPort, ephemeral, giveUp }

        func claimRebind() -> Rebind {
            lock.withLock {
                rebinds += 1
                switch rebinds {
                case 1, 2: return .anotherPort
                case 3: return .ephemeral
                default: return .giveUp
                }
            }
        }

        /// 代理那条腿整体走不通（不是端口问题）→ 换成「不经代理」再拨一次。
        ///
        /// 真机上这就是「有的源能看、有的源不能」的解法：这些源的 HTTPS 会话被
        /// Loon 交给节点后立刻被对端关掉（`NWError -9816`，服务器未通知即关闭），
        /// 而同样的域名走直连腿是通的。代理只该是「换条路试试」，不是「只能走这条路」。
        func claimDirectFallback() -> Bool {
            lock.withLock {
                guard !directFallback else { return false }
                directFallback = true
                retrying = true
                // 换了一条腿，端口重试预算也要跟着重来 —— 否则代理腿上用掉的两次
                // 会让直连腿第一次撞上 TIME_WAIT 就直接判死。
                rebinds = 0
                return true
            }
        }

        /// 正在换腿：这条 upstream 的 `.cancelled` 不能把本地连接一起关掉，
        /// 否则重试时已经没有客户端可回了。
        var isRetrying: Bool { lock.withLock { retrying } }

        func finishedRetrying() { lock.withLock { retrying = false } }

        /// 最后一条腿：整个请求交给系统网络栈（`URLSession`）。
        ///
        /// 真机上有一类目标，中继自己建 TLS 时必然被对端关会话（`NWError -9816`），
        /// 而同一个地址走系统栈（也就是用户手动「直连 + Loon 全局」时那条路）是通的。
        /// 差别在 TLS 客户端实现，不在网络路径 —— 所以最后一步干脆换成系统栈再发一次：
        /// 能出内容比「坚持用我们自己的连接」重要。
        func claimSystemFallback() -> Bool {
            lock.withLock {
                guard !systemFallback else { return false }
                systemFallback = true
                retrying = true
                return true
            }
        }
    }

    private static func open(_ state: TunnelState, dialHost: String?, bindSourcePort: Bool = true,
                             forceDirect: Bool = false) {
        let endpoint = forceDirect ? nil : state.endpoint
        let built = connectionParameters(secure: state.scheme.lowercased() == "https",
                                         serverName: state.host, proxy: endpoint,
                                         dialHost: dialHost, bindSourcePort: bindSourcePort)
        guard let port = NWEndpoint.Port(rawValue: state.port) else {
            state.connection.cancel()
            return
        }
        let upstream = NWConnection(host: NWEndpoint.Host(state.host), port: port, using: built.parameters)
        // The port comes back to the pool as soon as this connection is done with it — on failure
        // and on cancellation as well as on a clean close, or a long session would drain the range.
        let sourcePort = built.sourcePort
        upstream.stateUpdateHandler = { connectionState in
            // 日志必须标清是哪条腿：`state.endpoint` 在 forceDirect 后仍然非 nil，
            // 用它打标签会让「直连腿失败」看起来像「代理腿失败」。
            let leg = endpoint?.name ?? (forceDirect ? "direct(after proxy failed)" : "direct")
            switch connectionState {
            case .ready:
                state.finishedRetrying()
                if endpoint != nil { ProxyCircuit.noteSuccess(host: state.host) }
                let via = endpoint.map { "proxy=\($0.name)" } ?? (forceDirect ? "direct(after proxy failed)" : "direct")
                let viaPort = sourcePort.map { " src=:\($0)" } ?? ""
                let dial = dialHost.map { " dial=\($0)" } ?? ""
                Diagnostics.shared.record(.debug, "proxy",
                    "upstream ready \(via)\(viaPort)\(dial) \(state.scheme)://\(state.host):\(state.port)")
                sendAndRelay(state.connection, upstream: upstream, head: state.head, leftover: state.leftover)
            case .failed(let error), .waiting(let error):
                // 端口绑定失败先于一切：不是目标不通，是这个源端口还在 TIME_WAIT / 被占用。
                // 换端口重来，别把请求判死（真机上一次端口粘滞曾让 558 条请求全灭）。
                if isAddressInUse(error) {
                    let plan = state.claimRebind()
                    if let sourcePort { SRCPortPool.shared.release(sourcePort) }
                    upstream.cancel()
                    switch plan {
                    case .anotherPort:
                        Diagnostics.shared.record(.debug, "proxy",
                            "source port \(sourcePort.map(String.init) ?? "-") busy; retrying on another port \(state.scheme)://\(state.host):\(state.port)")
                        open(state, dialHost: dialHost, forceDirect: forceDirect)
                    case .ephemeral:
                        Diagnostics.shared.record(.warning, "proxy",
                            "source port range unusable; falling back to an ephemeral port \(state.scheme)://\(state.host):\(state.port)")
                        open(state, dialHost: dialHost, bindSourcePort: false, forceDirect: forceDirect)
                    case .giveUp:
                        Diagnostics.shared.failure("proxy",
                            "upstream failed \(state.scheme)://\(state.host):\(state.port) via=\(leg) (source port)", error)
                        state.connection.cancel()
                    }
                    return
                }
                // 局域网地址上没人监听（Loon 的 Wi-Fi 访问关着）会落到这里 —— 包括
                // `.waiting`：被拒之后 Network 会一直重试，那等于把这条请求挂死。
                // 退一次回环，至少让 Loon 用它的普通规则把这条带出去。
                if let proxy = state.endpoint,
                   let fallback = ProxyDialHost.fallback(for: proxy), fallback != dialHost,
                   state.claimRetry() {
                    ProxyDialHost.notePrimaryFailed(proxy)
                    if let sourcePort { SRCPortPool.shared.release(sourcePort) }
                    upstream.cancel()
                    open(state, dialHost: fallback)
                    return
                }
                // 代理那条腿对这条请求就是不工作（真机典型形态：`NWError -9816`，
                // Loon 交出去之后目标侧直接关会话）。换成不经代理再拨一次 ——
                // 播放器和源站用的都是幂等 GET，重发一次没有副作用。
                if state.endpoint != nil, !forceDirect, state.claimDirectFallback() {
                    ProxyCircuit.noteFailure(host: state.host)
                    Diagnostics.shared.record(.warning, "proxy",
                        "proxy route failed for \(state.host):\(state.port); retrying direct")
                    if let sourcePort { SRCPortPool.shared.release(sourcePort) }
                    upstream.cancel()
                    open(state, dialHost: nil, bindSourcePort: bindSourcePort, forceDirect: true)
                    return
                }
                // 两条腿都不通：最后一次交给系统栈（URLSession）。这一步会丢掉源端口控制，
                // 但它复制的是用户验证过 100% 能播的那条路径。
                if state.claimSystemFallback() {
                    Diagnostics.shared.record(.warning, "proxy",
                        "relay legs failed for \(state.host):\(state.port); retrying through the system stack")
                    if let sourcePort { SRCPortPool.shared.release(sourcePort) }
                    upstream.cancel()
                    relayThroughSystemStack(state)
                    return
                }
                Diagnostics.shared.failure("proxy",
                    "upstream failed \(state.scheme)://\(state.host):\(state.port) via=\(leg)",
                    error)
                if let sourcePort { SRCPortPool.shared.release(sourcePort) }
                state.connection.cancel(); upstream.cancel()
            case .cancelled:
                if let sourcePort { SRCPortPool.shared.release(sourcePort) }
                // 换腿重试时这条 upstream 是被我们自己取消的 —— 本地连接还要接着用。
                if !state.isRetrying { state.connection.cancel() }
            default: break
            }
        }
        upstream.start(queue: state.queue)
    }

    /// `NWError 48` / `EADDRINUSE`：源端口绑定冲突，与目标站无关。
    private static func isAddressInUse(_ error: Error) -> Bool {
        guard let nw = error as? NWError else { return false }
        if case .posix(let code) = nw { return code == .EADDRINUSE }
        return false
    }

    /// 用系统栈（`URLSession`）把同一条请求再发一次，把结果写回本地连接。
    ///
    /// 为什么需要这条腿：中继自己用 `NWConnection` 建 TLS，对某些站点必然被对端关会话
    /// （真机 `NWError -9816`，`send` 都没来得及发生）。而同一个地址用系统栈是通的 ——
    /// 用户手动「直连 + Loon 全局」能播的就是这条路。差别在 TLS 客户端实现，
    /// 所以最后一步不再坚持自己的连接，交给系统。
    ///
    /// 代价是这一步没有源端口控制（`URLSession` 不能 bind 源端口），所以它只做最后兜底，
    /// 前面两条腿都失败时才走。只重放幂等方法（GET / HEAD）。
    private static func relayThroughSystemStack(_ state: TunnelState) {
        let method = state.head.components(separatedBy: "\r\n").first?
            .split(separator: " ").first.map(String.init)?.uppercased() ?? "GET"
        guard method == "GET" || method == "HEAD",
              let url = URL(string: "\(state.scheme)://\(state.host):\(state.port)\(state.path)") else {
            state.connection.cancel()
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 25
        for line in state.head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let lower = name.lowercased()
            if name.isEmpty || lower == "host" || lower == "connection" { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 25
        config.httpMaximumConnectionsPerHost = 6
        let session = URLSession(configuration: config)
        session.dataTask(with: request) { data, response, error in
            state.queue.async {
                if let error {
                    Diagnostics.shared.failure("proxy",
                        "system stack failed \(state.scheme)://\(state.host):\(state.port)", error)
                    state.connection.cancel()
                    session.finishTasksAndInvalidate()
                    return
                }
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 502
                var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n"
                if let http {
                    for (key, value) in http.allHeaderFields {
                        let name = "\(key)"
                        let lower = name.lowercased()
                        if lower == "transfer-encoding" || lower == "content-length" || lower == "connection" { continue }
                        head += "\(name): \(value)\r\n"
                    }
                }
                let body = method == "HEAD" ? Data() : (data ?? Data())
                head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                let payload = Data(head.utf8) + body
                state.connection.send(content: payload, isComplete: true,
                                      completion: .contentProcessed { _ in
                    state.connection.cancel()
                    session.finishTasksAndInvalidate()
                })
                Diagnostics.shared.record(.debug, "proxy",
                    "served via system stack \(state.scheme)://\(state.host):\(state.port) status=\(status) bytes=\(body.count)")
            }
        }.resume()
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
                                             proxy: CustomProxyEndpoint?,
                                             dialHost: String? = nil,
                                             bindSourcePort: Bool = true) -> (parameters: NWParameters, sourcePort: UInt16?) {
        let tcp = NWProtocolTCP.Options()
        // Media segments arrive in bursts; the default window throttles a 4K stream on a close link.
        tcp.noDelay = true
        // 建连必须自己定死上限。系统默认是几十秒的重传预算，而这里的上游可能是「拿不到局域网
        // 地址的 Loon」这种根本不会应答的目标 —— 不设上限，播放器看到的就是「一直等待」，
        // 而且回环回退要等这个超时过完才发生。6 秒够跨洋握手，也够让我们快速换腿。
        tcp.connectionTimeout = 6
        let params: NWParameters
        if secure {
            let tls = NWProtocolTLS.Options()
            if let sec = tls.securityProtocolOptions as sec_protocol_options_t? {
                serverName.withCString { sec_protocol_options_set_tls_server_name(sec, $0) }
                // 必须显式声明只用 HTTP/1.1：中继只会说 HTTP/1.1，而有些源站在没有 ALPN 时
                // 会直接关掉会话（真机 `NWError -9816`，`send` 都没发生）。声明了它，
                // 服务端才知道能按 h1 回话。
                "http/1.1".withCString { sec_protocol_options_add_tls_application_protocol(sec, $0) }
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
        // 没有这一行，一个刚关掉的连接会把端口按 `TIME_WAIT` 扣住几十秒，
        // 而池子只有 100 个口 —— 真机上表现为连点几部剧就整段 `NWError 48`。
        params.allowLocalEndpointReuse = true
        let lane: SRCPortPool.Lane = proxy == nil ? .direct : .proxy
        var sourcePort: UInt16?
        if bindSourcePort, let port = SRCPortPool.shared.acquire(lane) {
            sourcePort = port
            params.requiredLocalEndpoint = .hostPort(host: "0.0.0.0", port: NWEndpoint.Port(rawValue: port)!)
        } else if bindSourcePort {
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
        let proxyHost = dialHost ?? proxy?.host
        if let proxy, let host = proxyHost.flatMap({ NWEndpoint.Host($0) }), let port = NWEndpoint.Port(rawValue: UInt16(clamping: proxy.port)) {
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
