import Foundation

/// 反查「Loon 现在用的是哪台节点」。
///
/// Loon 的 API 只开了一个只读端点（配置文件），策略组当前选中谁属于运行态，读不到。
/// 但节点的身份有一件东西**可以从外部观察**：它出去时的公网 IP。
/// 于是：
///   1. 经 Loon 请求一次「我是什么 IP」→ 拿到当前出口 IP；
///   2. 逐台直连节点（SS-AEAD）请求同一个地址 → 拿到每台的出口 IP；
///   3. 两者相等的就是 Loon 正在用的那台。
///
/// 前提是能直连节点（`ShadowsocksAEAD`）。vless/trojan 暂不参与。
public enum CurrentNodeIdentifier {
    public struct Result: Sendable {
        public var exitIP: String?
        public var node: LoonNode?
        public var candidates: [(name: String, exitIP: String?)]
    }

    private static let echo = URL(string: "http://api.ipify.org/")!

    /// 从 Loon 的配置 API 读节点清单（凭据只在内存里）。
    public static func loadNodes(apiHost: String, apiPort: Int) async -> [LoonNode] {
        var components = URLComponents()
        components.scheme = "http"
        components.host = apiHost
        components.port = apiPort
        components.path = "/loonapi/v1/config/file.conf"
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url) else { return [] }
        return LoonNodeParser.parse(config: String(decoding: data, as: UTF8.self))
    }

    /// 经 Loon 出去时的公网 IP。
    public static func exitIPThroughLoon() async -> String? {
        let proxyID = CustomProxyStore.shared.bestEndpointID()
        let policy: EgressPolicy = proxyID.map { .preferProxy(proxyID: $0) } ?? .directOnly
        guard let (data, _) = try? await EgressRouter.shared.data(for: echo, purpose: .catalog, policy: policy)
        else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 逐台直连节点取出口 IP，并与 Loon 的对比。
    public static func resolve(nodes: [LoonNode]) async -> Result {
        let target = await exitIPThroughLoon()
        var candidates: [(String, String?)] = []
        var matched: LoonNode?
        for node in nodes where LoonNodeParser.isSupported(node) {
            let ip = await exitIP(node: node)
            candidates.append((node.name, ip))
            if matched == nil, let ip, ip == target { matched = node }
        }
        return Result(exitIP: target, node: matched, candidates: candidates)
    }

    private static func exitIP(node: LoonNode) async -> String? {
        guard let data = try? await ShadowsocksAEAD.httpGet(
            node: node, host: "api.ipify.org", port: 80, path: "/", timeout: 6)
        else { return nil }
        guard let text = String(data: data, encoding: .utf8),
              let headerEnd = text.range(of: "\r\n\r\n") else { return nil }
        let body = text[headerEnd.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        // 只接受形如 IPv4 的结果，避免把错误页当成 IP。
        let parts = body.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return nil }
        return body
    }
}
