import Foundation

/// Loon 配置里的一个出站节点。
///
/// 只解析、不使用：真正拨号在 `ShadowsocksAEAD` 里。凭据仅存在内存，
/// 不写日志、不落盘、不外传 —— 日志里最多出现节点名。
public struct LoonNode: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case shadowsocks, vless, vmess, trojan, other
    }
    public var name: String
    public var kind: Kind
    public var server: String
    public var port: Int
    /// shadowsocks 的 method（aes-128-gcm 等）；其它协议留空。
    public var method: String
    public var password: String
    public var uuid: String
    public var tls: Bool
    public var sni: String?
}

public enum LoonNodeParser {
    /// 解析 `[Proxy]` 段。Loon 的写法是：
    /// `名字 = shadowsocks, 服务器, 端口, method, 密码` / `名字 = vless, 服务器, 端口, tls, uuid`
    public static func parse(config text: String) -> [LoonNode] {
        var inside = false
        var nodes: [LoonNode] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inside = line.lowercased().hasPrefix("[proxy]")
                continue
            }
            guard inside, !line.isEmpty, !line.hasPrefix("#"),
                  let equals = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            let fields = line[line.index(after: equals)...]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 3 else { continue }
            let kind = LoonNode.Kind(rawValue: fields[0].lowercased()) ?? .other
            guard let port = Int(fields[2]), port > 0 else { continue }
            var node = LoonNode(name: name, kind: kind, server: fields[1], port: port,
                                method: "", password: "", uuid: "", tls: false, sni: nil)
            switch kind {
            case .shadowsocks:
                guard fields.count >= 5 else { continue }
                node.method = fields[3].lowercased()
                node.password = fields[4]
            case .vless:
                // vless, host, port, tls|none, uuid[, 其它参数]
                node.tls = fields[3].lowercased() != "none"
                node.uuid = fields.count >= 5 ? fields[4] : ""
            case .trojan:
                node.password = fields.count >= 4 ? fields[3] : ""
                node.tls = true
            default:
                break
            }
            nodes.append(node)
        }
        return nodes
    }

    /// 只有 AEAD 且系统加密库支持的 SS 节点，才可能在 App 内直连。
    public static func isSupported(_ node: LoonNode) -> Bool {
        guard node.kind == .shadowsocks else { return false }
        return ShadowsocksAEAD.supportedMethods.contains(node.method)
    }
}
