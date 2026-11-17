import Foundation
import CryptoKit
import Network

/// Shadowsocks AEAD 客户端：只做「TCP + HTTP/1.1 请求」，用来直连节点。
///
/// 为什么要有它：Loon 的规则模式会给域名/IP 判一条腿，App 改不了（域名规则优先于
/// SRC-PORT，实测）。唯一能绕开规则引擎的办法是**不经 Loon**，直接连节点。
///
/// 实现范围刻意很小：单条 TCP、AEAD（aes-gcm / chacha20-poly1305）、HTTP/1.1。
/// 不做 UDP、不做多路复用 —— 我们只拿它取片单、封面、探测出口 IP。
public final class ShadowsocksAEAD: @unchecked Sendable {
    public enum SSFailure: Error {
        case unsupportedMethod
        case connect(String)
        case protocolViolation(String)
        case timeout
    }

    public static let supportedMethods: Set<String> = [
        "aes-128-gcm", "aes-256-gcm",
        "chacha20-ietf-poly1305", "chacha20-poly1305"
    ]

    private static func keyLength(_ method: String) -> Int {
        switch method {
        case "aes-128-gcm": return 16
        case "aes-256-gcm", "chacha20-ietf-poly1305", "chacha20-poly1305": return 32
        default: return 0
        }
    }

    private static func saltLength(_ method: String) -> Int { keyLength(method) }

    /// OpenSSL 的 `EVP_BytesToKey`（MD5、无 salt）：SS 用它把口令导成主密钥。
    static func masterKey(password: String, length: Int) -> Data {
        let pw = Data(password.utf8)
        var key = Data()
        var previous = Data()
        while key.count < length {
            var input = previous
            input.append(pw)
            previous = Data(Insecure.MD5.hash(data: input))
            key.append(previous)
        }
        return key.prefix(length)
    }

    /// 每一轮的子密钥 = HKDF-SHA1(master, salt, "ss-subkey")。
    static func subkey(master: Data, salt: Data, length: Int) -> Data {
        let derived = HKDF<Insecure.SHA1>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: master),
            salt: salt,
            info: Data("ss-subkey".utf8),
            outputByteCount: length)
        return derived.withUnsafeBytes { Data($0) }
    }

    /// AEAD 的 nonce 是「小端 96 位计数器」，每加密一次自增。
    static func nonce(_ counter: UInt64) -> Data {
        var value = counter.littleEndian
        var bytes = withUnsafeBytes(of: &value) { Data($0) }
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 4))
        return bytes
    }

    private static func isChaCha(_ method: String) -> Bool {
        method.hasPrefix("chacha20")
    }

    private static func seal(_ plain: Data, key: Data, counter: UInt64, method: String) throws -> Data {
        let nonceData = nonce(counter)
        let symmetric = SymmetricKey(data: key)
        if isChaCha(method) {
            let box = try ChaChaPoly.seal(plain, using: symmetric,
                                          nonce: try ChaChaPoly.Nonce(data: nonceData))
            return box.ciphertext + box.tag
        }
        let box = try AES.GCM.seal(plain, using: symmetric,
                                   nonce: try AES.GCM.Nonce(data: nonceData))
        return box.ciphertext + box.tag
    }

    private static func open(_ sealed: Data, key: Data, counter: UInt64, method: String) throws -> Data {
        let tagSize = 16
        guard sealed.count >= tagSize else { throw SSFailure.protocolViolation("short chunk") }
        let combined = sealed
        let symmetric = SymmetricKey(data: key)
        if isChaCha(method) {
            return try ChaChaPoly.open(try ChaChaPoly.SealedBox(combined: combined), using: symmetric)
        }
        return try AES.GCM.open(try AES.GCM.SealedBox(combined: combined), using: symmetric)
    }

    // MARK: - 一条连接

    /// 通过节点发一个 HTTP/1.1 GET，返回响应头 + 正文（原始字节）。
    public static func httpGet(node: LoonNode, host: String, port: Int, path: String,
                               timeout: TimeInterval = 8) async throws -> Data {
        guard supportedMethods.contains(node.method) else { throw SSFailure.unsupportedMethod }
        let keyLen = keyLength(node.method)
        let master = masterKey(password: node.password, length: keyLen)
        let outSalt = randomData(keyLen)
        let outKey = subkey(master: master, salt: outSalt, length: keyLen)

        let connection = NWConnection(host: NWEndpoint.Host(node.server),
                                      port: NWEndpoint.Port(rawValue: UInt16(node.port)) ?? 443,
                                      using: .tcp)
        let queue = DispatchQueue(label: "tvbox.ss")
        try await start(connection, queue: queue, timeout: timeout)

        var buffer = outSalt
        let request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: \(HTTPClient.userAgent)\r\n"
            + "Accept: */*\r\nConnection: close\r\n\r\n"
        var counter: UInt64 = 0
        let payloads: [Data] = [Data("\(host):\(port)".utf8), Data(request.utf8)]
        for payload in payloads {
            let length = Data([UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
            buffer.append(try seal(length, key: outKey, counter: counter, method: node.method))
            counter += 1
            buffer.append(try seal(payload, key: outKey, counter: counter, method: node.method))
            counter += 1
        }
        try await send(connection, buffer)

        // 读：第一块是 salt，之后是按块加密的流。
        var pending = Data()
        var inKey: Data?
        var inCounter: UInt64 = 0
        var response = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let chunk = try await receive(connection) else { break }
            pending.append(chunk)
            if inKey == nil {
                guard pending.count >= keyLen else { continue }
                let salt = pending.prefix(keyLen)
                inKey = subkey(master: master, salt: Data(salt), length: keyLen)
                pending = pending.dropFirst(keyLen)
            }
            guard let key = inKey else { continue }
            while true {
                guard pending.count >= 2 + 16 else { break }
                let lengthPlain = try open(Data(pending.prefix(2 + 16)), key: key,
                                           counter: inCounter, method: node.method)
                guard lengthPlain.count == 2 else { throw SSFailure.protocolViolation("length") }
                let length = Int(lengthPlain[lengthPlain.startIndex]) << 8
                    | Int(lengthPlain[lengthPlain.index(after: lengthPlain.startIndex)])
                guard length > 0, length <= 0x3FFF else { throw SSFailure.protocolViolation("size") }
                guard pending.count >= 2 + 16 + length + 16 else { break }
                let start = pending.index(pending.startIndex, offsetBy: 2 + 16)
                let end = pending.index(start, offsetBy: length + 16)
                let body = try open(Data(pending[start..<end]), key: key,
                                    counter: inCounter + 1, method: node.method)
                inCounter += 2
                response.append(body)
                pending = pending[end...]
            }
            if response.count > 0, isComplete(response) { break }
        }
        connection.cancel()
        guard !response.isEmpty else { throw SSFailure.timeout }
        return response
    }

    /// 响应已经收全了吗：头里有 Content-Length 且正文够了，或者头里写了 Connection: close
    /// 并且已经出现空行之后的完整正文（我们无法知道长度，就让调用方按超时兜底）。
    private static func isComplete(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8),
              let headerEnd = text.range(of: "\r\n\r\n") else { return false }
        let head = text[text.startIndex..<headerEnd.lowerBound].lowercased()
        let bodyCount = text[headerEnd.upperBound...].utf8.count
        if let range = head.range(of: "content-length:") {
            let rest = head[range.upperBound...]
            let number = rest.prefix { $0.isNumber }
            if let length = Int(number) { return bodyCount >= length }
        }
        return false
    }

    // MARK: - NWConnection 的 async 包装

    private static func randomData(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private static func start(_ connection: NWConnection, queue: DispatchQueue,
                              timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            connection.start(queue: queue)
            connection.stateUpdateHandler = { state in
                guard once.claim() else { return }
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    continuation.resume(throwing: SSFailure.connect(error.localizedDescription))
                default:
                    once.release()
                }
            }
        }
    }

    private static func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: SSFailure.connect(error.localizedDescription)) }
                else { continuation.resume() }
            })
        }
    }

    private static func receive(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let error {
                    continuation.resume(throwing: SSFailure.connect(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if complete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

/// 只许第一次通过：`NWConnection` 的状态回调会反复触发，重复 resume 会让 continuation 崩溃。
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
    func release() {
        lock.lock(); defer { lock.unlock() }
        used = false
    }
}
