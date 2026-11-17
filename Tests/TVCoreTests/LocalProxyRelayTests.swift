import Foundation
import Network
import Testing
@testable import TVCore

/// 回环中继的端到端验证：真起一个 NWListener 当晚辈源站，经中继取一次，比对字节。
///
/// 这里锁的是用户实际踩到的那个洞——`LocalProxyServer` 曾经**从未被启动**（`base()` 零调用点），
/// 所以「配了代理」与「直连」在行为上完全一样，且没有任何报错。纯函数测试看不出来，
/// 必须真的起监听、真的走一次请求。
@Suite(.serialized) struct LocalProxyRelayTests {

    /// 一个只认一次请求、回固定体的极小 HTTP 服务。
    private final class TinyServer: @unchecked Sendable {
        let listener: NWListener
        let queue = DispatchQueue(label: "test.tiny.server")
        private(set) var lastRequestLine = ""
        private(set) var lastHost = ""
        private let lock = NSLock()
        private var seen = false

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
        }

        var port: UInt16 { listener.port?.rawValue ?? 0 }

        func start(respond body: String) async throws {
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                    if let data, let head = String(data: data, encoding: .utf8) {
                        let lines = head.components(separatedBy: "\r\n")
                        if let first = lines.first {
                            self.lock.lock()
                            if !self.seen { self.lastRequestLine = first; self.seen = true }
                            self.lock.unlock()
                        }
                        if let host = lines.first(where: { $0.lowercased().hasPrefix("host:") }) {
                            self.lock.lock(); self.lastHost = host; self.lock.unlock()
                        }
                    }
                    let payload = Data(body.utf8)
                    let response = "HTTP/1.1 200 OK\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n" + body
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: continuation.resume()
                    case .failed(let error): continuation.resume(throwing: error)
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
        }

        func stop() { listener.cancel() }
    }

    /// 中继起来的端口就是 player 会用的那个，且经它取回的字节与源站一致。
    @Test func theRelayCarriesARequestAndItsResponse() async throws {
        let origin = try TinyServer()
        try await origin.start(respond: "hello-through-relay")
        defer { origin.stop() }

        let base = try await LocalProxyServer.shared.base()
        // `baseSync` 是播放器读的那个同步出口：异步起好之后它必须已经能看到端口，
        // 否则 makeItem 里那句 `if let base = baseSync` 永远不成立。
        let running = try #require(LocalProxyServer.shared.baseSync)
        #expect(running == base)

        let target = URL(string: "http://127.0.0.1:\(origin.port)/seg/index.m3u8?token=abc")!
        let relayed = LocalProxyServer.directURL(base: base, url: target)
        let (data, response) = try await URLSession.shared.data(from: relayed)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "hello-through-relay")
    }

    /// 上游收到的是 origin-form 请求行，且 **带查询串**——签名地址丢了查询就是 403，
    /// 而 encode 把 query 放在 URL 上、parse 又必须把它还回 path 尾部，这一来一回必须闭合。
    @Test func theUpstreamSeesOriginFormWithItsQuery() async throws {
        let origin = try TinyServer()
        try await origin.start(respond: "ok")
        defer { origin.stop() }

        let base = try await LocalProxyServer.shared.base()
        let target = URL(string: "http://127.0.0.1:\(origin.port)/live/index.m3u8?token=abc&e=1")!
        _ = try await URLSession.shared.data(from: LocalProxyServer.directURL(base: base, url: target))

        // 请求行不含绝对地址（那是 forward proxy 的形态，转发给源站会得到 400）。
        let line = try #require(origin.lastRequestLine.split(separator: "\r\n").first.map(String.init))
        #expect(line.hasPrefix("GET /live/index.m3u8?token=abc&e=1 "))
        #expect(!line.contains("http://"))
        // Host 头必须是源站的，不能被中继自己的 127.0.0.1:port 顶掉。
        #expect(origin.lastHost.lowercased().hasPrefix("host: 127.0.0.1:"))
    }

    /// 一个指向已删除代理的路由回落直连，而不是让播放失败：删端点不该搞坏本来能播的东西。
    @Test func aRouteToAMissingProxyFallsBackToDirect() async throws {
        let origin = try TinyServer()
        try await origin.start(respond: "still-here")
        defer { origin.stop() }

        let base = try await LocalProxyServer.shared.base()
        let target = URL(string: "http://127.0.0.1:\(origin.port)/x")!
        let relayed = LocalProxyServer.proxyURL(base: base, url: target, proxyID: "no-such-proxy")
        let (data, _) = try await URLSession.shared.data(from: relayed)
        #expect(String(decoding: data, as: UTF8.self) == "still-here")
    }

    /// 中继不许把自己的监听端口当目标去拨（自环）。
    ///
    /// 这条路径的目标串由请求方给出，**清单正文也算** —— 远端 `.m3u8` 里写一行
    /// `http://127.0.0.1:<relayPort>/p/<任意 id>/http/127.0.0.1/<port>/y` 就能让中继
    /// 把请求发给自己，并把内层再转给任意本机端口。
    ///
    /// 两个独立信号都要成立，缺一不可：
    ///   · 请求必须失败（守卫直接 cancel）。若守卫漏了，中继会正常回一个响应，这条断言就红；
    ///   · 源站一次请求都不该收到。只有第一条时，「守卫漏了但内层恰好也失败」会造成假绿。
    @Test func theRelayRefusesToDialItsOwnListener() async throws {
        let origin = try TinyServer()
        try await origin.start(respond: "should-not-arrive")
        defer { origin.stop() }

        let base = try await LocalProxyServer.shared.base()
        let own = try #require(base.port)
        let inner = "/p/any-id/http/127.0.0.1/\(origin.port)/y"
        let target = URL(string: "http://127.0.0.1:\(own)\(inner)")!
        let outcome = try? await URLSession.shared.data(from: LocalProxyServer.directURL(base: base, url: target))
        #expect(outcome == nil, "中继接受了「目标是自己」的请求：\(String(describing: outcome?.1))")
        #expect(origin.lastRequestLine.isEmpty, "内层请求被转出去了：\(origin.lastRequestLine.prefix(80))")
    }

    // MARK: - 上游连接复用

    /// 源站（keep-alive）：数「开了几条连接」与「收到几次请求」。
    ///
    /// 复用成立时：两次请求 → 1 条连接。不复用时：2 条。
    private final class KeepAliveServer: @unchecked Sendable {
        private let queue = DispatchQueue(label: "test.keepalive")
        private let lock = NSLock()
        private var _connections = 0
        private var _requests = 0
        private var listener: NWListener?
        private var open: [NWConnection] = []

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
        }

        var port: UInt16 { listener?.port?.rawValue ?? 0 }
        var connections: Int { lock.withLock { _connections } }
        var requests: Int { lock.withLock { _requests } }

        func start() async throws {
            listener?.newConnectionHandler = { [self] connection in
                lock.withLock { _connections += 1; open.append(connection) }
                connection.start(queue: queue)
                serve(connection)
            }
            guard let listener else { return }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: continuation.resume()
                    case .failed(let error): continuation.resume(throwing: error)
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
        }

        /// 一条连接上反复收请求、回响应，**不关连接**。
        private func serve(_ connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
                if let data, !data.isEmpty {
                    lock.withLock { _requests += 1 }
                    let body = "segment"
                    let head = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
                    connection.send(content: Data(head.utf8) + Data(body.utf8),
                                    completion: .contentProcessed { _ in self.serve(connection) })
                    return
                }
                if complete || error != nil { connection.cancel() }
            }
        }

        /// ⛔ 必须把**已接受的连接**也关掉。
        ///
        /// 中继会把空闲连接放进 `RelayUpstreamPool`，键只到 `host:port`。
        /// 测试桩若只 cancel 监听器，那些连接还活着；下一个测试桩很可能拿到同一个临时端口，
        /// 于是中继把「上一条连接的响应」发给新请求 —— 实测表现是别的用例读到 "segment"。
        var stopCount: Int { 0 }
        func stop() {
            listener?.cancel()
            let connections: [NWConnection] = lock.withLock {
                let all = open
                open.removeAll()
                return all
            }
            for connection in connections { connection.cancel() }
            RelayUpstreamPool.shared.drain()
        }
    }

    /// 两片（两次请求）只该付一次握手。
    ///
    /// ⛔ 这条断言的意义不在「快」，在「**连接真的被留下来了**」：
    ///    池子拿不到命中时，源站会看到两条连接 —— 功能看起来完全正常，
    ///    只是每片又握了一次手。不钉住连接数，这个退化是静默的。
    @Test func aSecondSegmentReusesTheUpstreamConnection() async throws {
        let origin = try KeepAliveServer()
        try await origin.start()
        defer { origin.stop() }

        let base = try await LocalProxyServer.shared.base()
        for index in 0..<2 {
            let target = URL(string: "http://127.0.0.1:\(origin.port)/seg/\(index).ts")!
            let (data, response) = try await URLSession.shared.data(
                from: LocalProxyServer.directURL(base: base, url: target))
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: data, as: UTF8.self) == "segment")
        }
        #expect(origin.requests == 2, "两次请求应当都到达源站")
        #expect(origin.connections == 1, "第二次请求没有复用上游连接（源站开了 \(origin.connections) 条）")
    }
}
