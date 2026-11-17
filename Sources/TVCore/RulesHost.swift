import Foundation
import Network

/// 只做一件事：把「必须显式走节点」的域名，作为一份规则文件发给本机的 Loon。
///
/// 为什么不复用中继的监听：那个绑在 `127.0.0.1`，而 Loon 拉订阅时用的是设备局域网地址，
/// 于是真机上报「更新订阅资源失败；无法连接服务器」—— 地址上没有服务在听。
/// 这里单独绑所有网卡，两种地址都通。
public final class RulesHost: @unchecked Sendable {
    public static let shared = RulesHost()

    private let queue = DispatchQueue(label: "tvbox.rules-host")
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16?

    public init() {}

    /// 监听端口；还没起来时为 nil。
    public var listeningPort: UInt16? {
        lock.withLock { port }
    }

    public func start() {
        lock.lock()
        guard listener == nil else { lock.unlock(); return }
        lock.unlock()
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // ⛔ 不要限定 `requiredInterfaceType = .wifi`。
            //    真机上踩过：设备走蜂窝（或蜂窝优先的热点）时，限定 WiFi 的监听**永远不 ready**，
            //    端口拿不到 → 规则地址一个都取不到，表现为「127.0.0.1 也经常拉不到」。
            //    绑所有接口，回环与局域网才都在。
            let listener = try NWListener(using: parameters, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state, let assigned = listener.port?.rawValue {
                    self.lock.withLock { self.port = assigned }
                    Diagnostics.shared.record(.info, "proxy", "rules host listening port=\(assigned)")
                }
                if case .failed = state {
                    self.lock.withLock {
                        self.port = nil
                        self.listener = nil
                    }
                }
            }
            lock.withLock { self.listener = listener }
            listener.start(queue: queue)
        } catch {
            Diagnostics.shared.record(.warning, "proxy", "rules host failed to start: \(error.localizedDescription)")
        }
    }

    /// 给 Loon 的订阅地址：优先局域网地址（同机也可能被 TUN 拦），回环作为退路。
    public func rulesURLs() -> [URL] {
        urls(path: "/loon/rules.list")
    }

    /// 给 Loon 导入的**插件**地址。
    ///
    /// 插件只在导入那一刻被取一次，之后内容由 Loon 自己保存 ——
    /// 所以这个地址不需要常驻，App 退出也不影响已经装上的规则。
    public func pluginURLs() -> [URL] {
        urls(path: LoonPlugin.path)
    }

    private func urls(path: String) -> [URL] {
        guard let port = listeningPort else { return [] }
        var found: [URL] = []
        if let host = LocalNetwork.currentIPv4, let url = URL(string: "http://\(host):\(port)\(path)") {
            found.append(url)
        }
        if let url = URL(string: "http://127.0.0.1:\(port)\(path)") { found.append(url) }
        return found
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let body: String
            if path.hasPrefix("/loon/plugin") {
                body = LoonPlugin.text(hosts: ForcedNodeHosts.shared.hosts)
            } else if path.hasPrefix("/loon/rules") {
                let lines = ForcedNodeHosts.shared.subscriptionRules()
                body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
            } else {
                body = ""
            }
            let bytes = Data(body.utf8)
            var head = "HTTP/1.1 200 OK\r\n"
            head += "Content-Type: text/plain; charset=utf-8\r\n"
            head += "Content-Length: \(bytes.count)\r\n"
            head += "Connection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + bytes, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
