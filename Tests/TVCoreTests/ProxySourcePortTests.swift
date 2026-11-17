import Foundation
import Network
import Testing
@testable import TVCore

/// 「Loon 按我们规定的端口分流」这件事的**唯一判据**：
/// 从中继出去的那条 TCP 连接，源端口是不是落在 `SRCPortPool` 的端口段里。
///
/// ## 为什么必须端到端测
///
/// `requiredLocalEndpoint` 的绑定不发生在这个进程里 —— 是 Network 栈在建连时做的。
/// 所以「代码里写了一行 requiredLocalEndpoint」和「Loon 真的看到 41500+ 的源端口」
/// 之间隔着好几层：代理隧道、TLS 包装、隐私上下文。上一版把「绑定成功」当成
/// 已经用 EADDRINUSE 验证过，但那只证明**参数生效**，没证明**对端看到的端口**是它。
///
/// 用户报的「设置好了 Loon 但没有按我们规定好的端口去连接」正是这一层。
/// 这个测试起一个假源站，让中继真的拨一次，然后看源站看到的**对端端口**。
@Suite(.serialized) struct ProxySourcePortTests {

    /// 本机的局域网 IPv4（找不到就退回回环）。
    ///
    /// ⛔ 目标**不能是 127.0.0.1**：系统代理栈对回环地址有隐式 bypass
    ///    （等价于 `NO_PROXY=127.0.0.1`），隐私上下文里的代理会被直接跳过。
    ///    实测过：同一份代码拨 127.0.0.1 时假代理一条 CONNECT 都收不到，
    ///    而请求仍然成功 —— 那会让人误判成「代理没生效」。
    ///    手机拨的是 Loon 的**局域网地址**，所以这里也用局域网地址，场景才对得上。
    static var lanHost: String {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return "127.0.0.1" }
        defer { freeifaddrs(addrs) }
        var found = "127.0.0.1"
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            let flags = Int32(ptr.pointee.ifa_flags)
            if let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_LOOPBACK) == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if text.hasPrefix("192.168.") || text.hasPrefix("10.") || text.hasPrefix("172.") {
                        found = text
                        break
                    }
                }
            }
            cursor = ptr.pointee.ifa_next
        }
        return found
    }

    /// 只回一次响应、并记下「对端从哪个端口来」的极小服务。
    private final class PortSpy: @unchecked Sendable {
        let listener: NWListener
        let queue = DispatchQueue(label: "test.port.spy")
        private let lock = NSLock()
        private var _peerPorts: [UInt16] = []

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "0.0.0.0", port: .any)
            listener = try NWListener(using: parameters)
        }

        var port: UInt16 { listener.port?.rawValue ?? 0 }
        var peerPorts: [UInt16] { lock.withLock { _peerPorts } }

        func start() async throws {
            listener.newConnectionHandler = { [self] connection in
                if case let .hostPort(_, port) = connection.endpoint {
                    lock.withLock { _peerPorts.append(port.rawValue) }
                }
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                    let body = "spy-ok"
                    let response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                    connection.send(content: Data(response.utf8),
                                    completion: .contentProcessed { _ in connection.cancel() })
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

    /// 直连段（41600-41699）：不经代理时，源站看到的源端口必须落在这一段。
    @Test func theDirectLaneDialsFromTheDirectRange() async throws {
        let spy = try PortSpy()
        try await spy.start()
        defer { spy.stop() }

        let base = try await LocalProxyServer.shared.base()
        let target = URL(string: "http://\(Self.lanHost):\(spy.port)/probe")!
        let (data, _) = try await URLSession.shared.data(from: LocalProxyServer.directURL(base: base, url: target))
        #expect(String(decoding: data, as: UTF8.self) == "spy-ok")

        // 等一拍，让监听侧的 accept 回调把端口记下来。
        try await Task.sleep(for: .milliseconds(120))
        let ports = spy.peerPorts
        #expect(!ports.isEmpty, "源站一条连接都没收到")
        for port in ports {
            #expect(SRCPortPool.directRange.contains(Int(port)),
                    "直连段请求的源端口是 \(port)，不在 \(SRCPortPool.directRange)")
        }
    }

    /// 一个只做 CONNECT 转发的假代理，并记下**它看到的源端口**。
    ///
    /// 这正是 Loon 的视角：Loon 是那个「接收 CONNECT 的进程」，
    /// 它按 `SRC-PORT` 分流时看的就是这里记下来的那个端口。
    private final class ConnectSpy: @unchecked Sendable {
        let listener: NWListener
        let queue = DispatchQueue(label: "test.connect.spy")
        private let lock = NSLock()
        private var _peerPorts: [UInt16] = []

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "0.0.0.0", port: .any)
            listener = try NWListener(using: parameters)
        }

        var port: UInt16 { listener.port?.rawValue ?? 0 }
        var peerPorts: [UInt16] { lock.withLock { _peerPorts } }

        func start() async throws {
            listener.newConnectionHandler = { [self] connection in
                if case let .hostPort(_, port) = connection.endpoint {
                    lock.withLock { _peerPorts.append(port.rawValue) }
                }
                connection.start(queue: queue)
                readHead(connection, buffer: Data())
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

        /// 收到 CONNECT 后回 200，然后**自己当源站**回一段固定响应。
        ///
        /// 不真的去连目标：这一条要证的只是「CONNECT 从哪个端口来的」，
        /// 而真目标会让测试依赖外网。
        private func readHead(_ connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                var bytes = buffer
                if let data { bytes.append(data) }
                guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                    if error != nil || complete { connection.cancel() } else { self.readHead(connection, buffer: bytes) }
                    return
                }
                let head = String(decoding: bytes[..<end.lowerBound], as: UTF8.self)
                guard let first = head.components(separatedBy: "\r\n").first,
                      first.hasPrefix("CONNECT ") else { connection.cancel(); return }
                connection.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8),
                                completion: .contentProcessed { _ in
                    self.readRequest(connection, buffer: Data(bytes[end.upperBound...]))
                })
            }
        }

        /// 隧道里进来的第一条请求：回一个完整的 HTTP 响应，然后关掉。
        private func readRequest(_ connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                var bytes = buffer
                if let data { bytes.append(data) }
                guard bytes.range(of: Data("\r\n\r\n".utf8)) != nil else {
                    if error != nil || complete { connection.cancel() } else { self.readRequest(connection, buffer: bytes) }
                    return
                }
                let body = "spy-ok"
                let response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                connection.send(content: Data(response.utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    /// 代理段（41500-41599）：配了代理时，**代理进程**看到的源端口必须落在这一段。
    ///
    /// ⛔ 这条就是用户报的「设置好了 Loon，但没有按我们规定好的端口去连接」。
    ///    走代理时那条 TCP 连接是 Network 自己拨向代理的，`requiredLocalEndpoint`
    ///    要穿过隐私上下文/隧道那一层才生效 —— 直连段的成功不能替它作证。
    @Test func theProxyLaneDialsTheProxyFromTheProxyRange() async throws {
        let spy = try PortSpy()
        try await spy.start()
        defer { spy.stop() }
        let proxy = try ConnectSpy()
        try await proxy.start()
        defer { proxy.stop() }

        let endpoint = CustomProxyEndpoint(name: "ConnectSpy", scheme: .http,
                                           host: Self.lanHost, port: Int(proxy.port))
        CustomProxyStore.shared.upsert(endpoint)
        defer { CustomProxyStore.shared.removeEndpoint(id: endpoint.id) }

        let base = try await LocalProxyServer.shared.base()
        // ⛔ 目标必须是公网**域名**：
        //    · 私网/回环地址被系统代理栈隐式 bypass（等价 `NO_PROXY`），隐私上下文里的代理会被跳过；
        //    · 字面 IP（即使是公网）有时也不进代理。
        //    那两种都会让测试得到「代理没生效」的假阴性 —— 而真实源站用的是域名。
        let target = URL(string: "http://example.com/through-proxy")!
        let relayed = LocalProxyServer.proxyURL(base: base, url: target, proxyID: endpoint.id)
        print("DBG relayed=\(relayed.absoluteString)")
        print("DBG parsed=\(String(describing: LocalProxyServer.parse(relayed.path)))")
        print("DBG found=\(String(describing: CustomProxyStore.shared.proxy(for: endpoint.id)))")
        let (data, _) = try await URLSession.shared.data(from: relayed)
        #expect(String(decoding: data, as: UTF8.self) == "spy-ok")

        try await Task.sleep(for: .milliseconds(120))
        let ports = proxy.peerPorts
        #expect(!ports.isEmpty, "代理一条 CONNECT 都没收到")
        for port in ports {
            #expect(SRCPortPool.proxyRange.contains(Int(port)),
                    "走代理时 Loon 看到的源端口是 \(port)，不在 \(SRCPortPool.proxyRange)")
        }
    }

    /// 用户真机上的那一套：**Loon 在本机 `127.0.0.1:7221`，SOCKS5**。
    ///
    /// 这条测试要证的是：目标是公网域名时，SOCKS5 握手那条连接也是从**代理段**端口拨出去的。
    /// （目标不能是私网/回环地址 —— 系统代理栈对它们有隐式 bypass，测出来是假阴性。）
    @Test func theSocksLaneDialsLoonFromTheProxyRange() async throws {
        let socks = try SocksSpy()
        try await socks.start()
        defer { socks.stop() }

        let endpoint = CustomProxyEndpoint(name: "Loon", scheme: .socks5,
                                           host: "127.0.0.1", port: Int(socks.port))
        CustomProxyStore.shared.upsert(endpoint)
        defer { CustomProxyStore.shared.removeEndpoint(id: endpoint.id) }

        let base = try await LocalProxyServer.shared.base()
        let target = URL(string: "http://example.com/socks-probe")!
        let relayed = LocalProxyServer.proxyURL(base: base, url: target, proxyID: endpoint.id)
        let (data, _) = try await URLSession.shared.data(from: relayed)
        #expect(String(decoding: data, as: UTF8.self) == "socks-ok")

        try await Task.sleep(for: .milliseconds(120))
        let ports = socks.peerPorts
        #expect(!ports.isEmpty, "SOCKS5 代理一条连接都没收到")
        for port in ports {
            #expect(SRCPortPool.proxyRange.contains(Int(port)),
                    "SOCKS5 握手时的源端口是 \(port)，不在 \(SRCPortPool.proxyRange)")
        }
    }

    /// 只做 SOCKS5 握手（无认证），然后自己当源站回一段固定响应。
    private final class SocksSpy: @unchecked Sendable {
        let listener: NWListener
        let queue = DispatchQueue(label: "test.socks.spy")
        private let lock = NSLock()
        private var _peerPorts: [UInt16] = []

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
        }

        var port: UInt16 { listener.port?.rawValue ?? 0 }
        var peerPorts: [UInt16] { lock.withLock { _peerPorts } }

        func start() async throws {
            listener.newConnectionHandler = { [self] connection in
                if case let .hostPort(_, port) = connection.endpoint {
                    lock.withLock { _peerPorts.append(port.rawValue) }
                }
                connection.start(queue: queue)
                step(connection, buffer: Data(), phase: 0)
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

        /// phase 0 = 等问候，1 = 等请求，2 = 等 HTTP 请求，3 = 收尾。
        private func step(_ connection: NWConnection, buffer: Data, phase: Int) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                var bytes = buffer
                if let data { bytes.append(data) }
                if phase == 0 {
                    guard bytes.count >= 3 else {
                        if error != nil || complete { connection.cancel() }
                        else { self.step(connection, buffer: bytes, phase: 0) }
                        return
                    }
                    let rest = Data(bytes.dropFirst(bytes.count))
                    connection.send(content: Data([0x05, 0x00]), completion: .contentProcessed { _ in
                        self.step(connection, buffer: rest, phase: 1)
                    })
                    return
                }
                if phase == 1 {
                    guard bytes.count >= 5 else {
                        if error != nil || complete { connection.cancel() }
                        else { self.step(connection, buffer: bytes, phase: 1) }
                        return
                    }
                    // 05 01 00 03 <len> <domain> <port hi> <port lo>
                    let addressLength = Int(bytes[4])
                    let needed = 5 + addressLength + 2
                    guard bytes.count >= needed else {
                        if error != nil || complete { connection.cancel() }
                        else { self.step(connection, buffer: bytes, phase: 1) }
                        return
                    }
                    let rest = Data(bytes.dropFirst(needed))
                    let reply: [UInt8] = [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
                    connection.send(content: Data(reply), completion: .contentProcessed { _ in
                        self.step(connection, buffer: rest, phase: 2)
                    })
                    return
                }
                if phase == 2 {
                    guard bytes.range(of: Data("\r\n\r\n".utf8)) != nil else {
                        if error != nil || complete { connection.cancel() }
                        else { self.step(connection, buffer: bytes, phase: 2) }
                        return
                    }
                    let body = "socks-ok"
                    let response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                    connection.send(content: Data(response.utf8),
                                    completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
    }
}
