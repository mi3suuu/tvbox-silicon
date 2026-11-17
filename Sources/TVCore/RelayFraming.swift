import Foundation
import Network

// MARK: - 上游连接的复用

/// 一条 HTTP/1.1 响应体有多长 —— **决定这条上游连接能不能留着再用**。
///
/// ## 为什么必须有这个判定
///
/// 中继原来的做法是「一条请求一条上游连接，发完就关」（`Connection: close`）。
/// 对 HLS 来说这是最贵的一种：一片一个 TCP + 一个到节点的 TLS。
/// 真机实测经中继只有 140–190 KB/s，其中相当一部分不是带宽，是**每片一次的握手**。
///
/// 想复用就必须知道「这条响应的体到哪结束」—— 不然下一片会把上一片的尾巴当成响应头。
/// 只有两种响应能算清长度：
///
/// | 头 | 能复用 | 说明 |
/// |---|---|---|
/// | `Content-Length: n` | ✅ | 数够 n 字节就结束（分片基本都是这个） |
/// | `Transfer-Encoding: chunked` | ✅ | 见到 0 长度块 + 结尾空行才结束 |
/// | 两者都没有 | ❌ | 只能读到连接关闭，读完连接也就没了 |
/// | `Connection: close` | ❌ | 对端明说要关，复用等于自找失败 |
///
/// ⛔ 判错的代价很具体：复用一条其实已经错位的连接，下一片会拿到上一片的残余字节，
///   播放器报的是「内容损坏 / -12881」。所以这里宁可保守 —— 拿不准就 `untilClose`。
public enum RelayBodyFraming: Equatable, Sendable {
    case length(Int)
    case chunked
    case untilClose
}

/// 一条响应的头里，转发与复用需要的全部信息。
public struct RelayResponseHead: Equatable, Sendable {
    public var status: Int
    public var framing: RelayBodyFraming
    /// 对端是否允许复用（HTTP/1.1 默认允许，写了 `Connection: close` 就不允许）。
    public var keepAlive: Bool
    public var isHead: Bool

    /// 解析响应头。`head` 不含结尾的空行也无妨。
    ///
    /// 返回 `nil` 表示「这不像一条 HTTP 响应」—— 调用方应退回「读到关闭为止」。
    public static func parse(_ head: String, requestMethod: String = "GET") -> RelayResponseHead? {
        let lines = head.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }
        let fields = statusLine.split(separator: " ", maxSplits: 2)
        guard fields.count >= 2, fields[0].hasPrefix("HTTP/"), let status = Int(fields[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let method = requestMethod.uppercased()
        // 没有响应体的几种：HEAD、1xx、204、304。
        let noBody = method == "HEAD" || status == 204 || status == 304 || (100..<200).contains(status)
        let connection = (headers["connection"] ?? "").lowercased()
        // HTTP/1.0 默认不保持连接，必须显式写出 `Connection: keep-alive` 才能复用。
        let isOldProtocol = statusLine.hasPrefix("HTTP/1.0")
        let keepAlive = isOldProtocol ? connection.contains("keep-alive") : !connection.contains("close")
        if noBody {
            return RelayResponseHead(status: status, framing: .length(0), keepAlive: keepAlive,
                                     isHead: method == "HEAD")
        }
        if let transfer = headers["transfer-encoding"]?.lowercased(), transfer.contains("chunked") {
            return RelayResponseHead(status: status, framing: .chunked, keepAlive: keepAlive, isHead: false)
        }
        if let raw = headers["content-length"], let length = Int(raw.trimmingCharacters(in: .whitespaces)),
           length >= 0 {
            return RelayResponseHead(status: status, framing: .length(length), keepAlive: keepAlive, isHead: false)
        }
        return RelayResponseHead(status: status, framing: .untilClose,
                                 keepAlive: false, isHead: false)
    }
}

/// 增量数 chunked 体：**只数，不改写**。
///
/// 中继把上游的 chunked 帧原样转发给播放器（不改写就不会破坏长度行），
/// 但需要知道「最后一个 0 长度块 + 结尾空行」什么时候到，才敢把这条连接放回池子。
///
/// 状态机跨多次 `receive` 保持，所以能处理任意切分位置 —— 包括切在
/// `\r` 与 `\n` 之间这种最常见的边界。
public struct ChunkedBodyScanner: Sendable {
    private enum Phase: Sendable {
        case size
        case data(remaining: Int)
        case dataEnd
        case trailers
        case done
    }
    private var phase: Phase = .size
    private var lineBuffer = Data()
    /// `.dataEnd` 里已经吃掉的 CRLF 字节数（0…2）—— 允许切在 `\r` 与 `\n` 之间。
    private var crlfSeen = 0
    public private(set) var finished = false

    public init() {}

    /// 喂一段上游字节；返回这条响应体是否已经结束。
    public mutating func consume(_ data: Data) -> Bool {
        guard !finished else { return true }
        var index = data.startIndex
        while index < data.endIndex {
            switch phase {
            case .size, .trailers:
                // 读一行（到 CRLF）。
                var completedLine = false
                while index < data.endIndex {
                    let byte = data[index]
                    index = data.index(after: index)
                    if byte == 0x0A {
                        var line = lineBuffer
                        if line.last == 0x0D { line = line.dropLast() }
                        lineBuffer.removeAll(keepingCapacity: true)
                        let inTrailers: Bool = { if case .trailers = phase { return true }; return false }()
                        if inTrailers {
                            // 空行 = 尾部结束 = 整个响应体结束。
                            if line.isEmpty { finished = true; return true }
                            completedLine = true
                            break
                        }
                        let text = String(decoding: line, as: UTF8.self)
                        let sizeText = text.split(separator: ";", maxSplits: 1).first.map(String.init) ?? text
                        guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else {
                            // 长度行都读不懂：别再猜，交给调用方按「读到关闭」处理。
                            phase = .done
                            finished = true
                            return true
                        }
                        if size == 0 { phase = .trailers } else { phase = .data(remaining: size) }
                        completedLine = true
                        break
                    }
                    lineBuffer.append(byte)
                }
                if !completedLine, index >= data.endIndex { return finished }
            case .data(let remaining):
                let available = data.distance(from: index, to: data.endIndex)
                if available < remaining {
                    phase = .data(remaining: remaining - available)
                    index = data.endIndex
                } else {
                    index = data.index(index, offsetBy: remaining)
                    phase = .dataEnd
                    crlfSeen = 0
                }
            case .dataEnd:
                let available = data.distance(from: index, to: data.endIndex)
                let needed = 2 - crlfSeen
                let take = min(available, needed)
                crlfSeen += take
                index = data.index(index, offsetBy: take)
                if crlfSeen == 2 {
                    crlfSeen = 0
                    phase = .size
                }
            case .done:
                return true
            }
        }
        return finished
    }
}
