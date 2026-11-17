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
            parameters.requiredInterfaceType = .wifi
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
        guard let port = listeningPort else { return [] }
        var urls: [URL] = []
        if let host = LocalNetwork.currentIPv4, let url = URL(string: "http://\(host):\(port)/loon/rules.list") {
            urls.append(url)
        }
        if let url = URL(string: "http://127.0.0.1:\(port)/loon/rules.list") { urls.append(url) }
        return urls
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let body: String
            if path.hasPrefix("/loon/rules") {
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
