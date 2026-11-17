import Foundation
import CommonCrypto

/// 加密封面（`xxx.jpg.aes`）的解密内核 —— 服务端 `deimg` 能力的离线版。
///
/// 为什么映匣本体需要它
/// ------------------
/// GS(avbox)、月色这类站给的封面不是明文：URL 可以是 `.jpg`，字节却是 AES 密文。
/// 它们各自的 App 里都带一份按站点硬编码的解密表（`avbox/image/decrypt_image.dart`
/// 一个站一个分支）；149 上那台 `deimg` 服务做的就是这件事，而它一直是映匣的一块外部依赖。
///
/// **不认站点，只认能不能解出图片魔数。** 对每组已知 (key, iv) 依次试解，解出来的头几个
/// 字节是 `FFD8FF` / `89504E47` / `GIF8` / `RIFF…WEBP` 就算命中。好处是域名一换不用跟着改；
/// 代价是一张图最多试几十次 AES-CBC（20 KB 大约几毫秒，且解不出的图只试一次就放弃）。
///
/// 什么时候用：**只在下载到的字节不像图片时**（`isImage` 为 false）。明文图是零开销的 ——
/// 一次前四字节比较的事。
///
/// 密钥表来自 `deimg/aesimg.py`（那份是从 GS 1.14 的 blutter 反汇编里逐字取出的）。
/// 新增站点时往 `explicit` 里加一行就行，别改判定逻辑。
public enum ArtworkDecryptor {

    /// 这张图已经是明文了吗 —— 只看魔数，不解码。
    public static func isImage(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        return magic(of: data) != nil
    }

    /// 尝试把密文解成图片字节。不是已知加密格式时返回 nil（调用方按原来的失败处理）。
    ///
    /// - Parameter hint: 图片来源的 host，用来记住「这个站命中过哪一组」——
    ///   同一屏 20 张封面时，第一条试出来的组会被后面的优先试。
    public static func decode(_ data: Data, hint: String? = nil) -> Data? {
        guard data.count >= 32 else { return nil }
        let forms = unguarded(data)
        var candidates = self.candidates()
        if let hint, let preferred = preferred[hint] {
            // 命中过的组排到最前，但不排除其它：同一个站也可能混两种格式。
            candidates.sort { lhs, rhs in
                (lhs.label == preferred ? 0 : 1) < (rhs.label == preferred ? 0 : 1)
            }
        }
        for (name, buffer) in forms {
            for candidate in candidates {
                if let plain = attempt(buffer, candidate) {
                    if let hint { preferred[hint] = candidate.label }
                    _ = name
                    return plain
                }
            }
        }
        return nil
    }

    // MARK: - 候选

    private struct Candidate {
        let label: String
        let key: Data
        /// nil = IV 取 key 本身（`kptv` / `lls` / `asgj` 这类只给了 key 的站）。
        let iv: Data?
        /// IV = 密文前 16 字节，且把整段（含那 16 字节）一起解 —— 月色那一种。
        let ivFromFile = false
    }

    /// 站点表 —— 全部来自 `deimg/aesimg.py` 的 `EXPLICIT`。字面量保持原样，
    /// 形态（utf8 / hex / base64）由 `variants` 现猜。
    private static let explicit: [(name: String, key: String, iv: String?)] = [
        ("oksp", "MIGfMA0GCSqGSIb3", "5efd3f6060e20765"),
        ("zlt", "saIZXc4yMvq0Iz56", "kbJYtBJUECT0oyjo"),
        ("ltb", "svOEKGb5WD0ezmHE4FXCVQ==", "4B7eYzHTevzHvgVZfWVNIg=="),
        ("mimeianim", "204149A15B092E24E89CEB31040148DB", "AC14AECE2E0681EE730A4D773F3B2EE6"),
        ("mimeicomic", "D94E86BC48615C397146E9A1CA0870E244F2C7920D7535D2F20039E9D54AD810",
         "CA87D9018CC39C86FA25E7876AC079CB"),
        ("prefix", "f5d965df75336270", "97b60394abc2fbe1"),
        ("kptv", "7af630c7e06ccecfa70d5a085f189c06", nil),
        ("mw", "my2ecret782ecret", "my2ecret782ecret"),
        ("lls", "525202f9149e061d", nil),
        ("asgj", "2019ysapp7527", nil),
    ]

    /// 月色：key 固定，IV 是文件前 16 字节，整段一起解。
    private static let fileIVKey = "yuese!niubia!666"

    private static func candidates() -> [Candidate] {
        var out: [Candidate] = []
        var seen = Set<String>()
        for entry in explicit {
            for (keyName, key) in variants(entry.key) {
                if let ivLiteral = entry.iv {
                    for (ivName, iv) in variants(ivLiteral) where iv.count == 16 {
                        let id = key.base64EncodedString() + "/" + iv.base64EncodedString()
                        guard seen.insert(id).inserted else { continue }
                        out.append(Candidate(label: "\(entry.name)/\(keyName)/\(ivName)", key: key, iv: iv))
                    }
                } else {
                    // 只给 key：IV 先试 key 本身，再试全零。
                    out.append(Candidate(label: "\(entry.name)/\(keyName)/ivkey", key: key, iv: key.count == 16 ? key : nil))
                    if key.count != 16 {
                        out.append(Candidate(label: "\(entry.name)/\(keyName)/ivzero", key: key, iv: Data(repeating: 0, count: 16)))
                    }
                }
            }
        }
        if let key = fileIVKey.data(using: .utf8), key.count == 16 {
            out.append(Candidate(label: "yuese/ivfile16", key: key, iv: nil))
        }
        return out
    }

    /// 字面量 → 若干候选字节串（utf8 / hex / base64），只留 AES 能吃的长度。
    private static func variants(_ literal: String) -> [(String, Data)] {
        var out: [(String, Data)] = []
        if let utf8 = literal.data(using: .utf8) { out.append(("utf8", utf8)) }
        if literal.count % 2 == 0, literal.allSatisfy(\.isHexDigit), let hex = Data(hexString: literal) {
            out.append(("hex", hex))
        }
        if literal.count % 4 == 0, let b64 = Data(base64Encoded: literal), b64 != literal.data(using: .utf8) {
            out.append(("b64", b64))
        }
        return out.filter { [16, 24, 32].contains($0.1.count) }
    }

    // MARK: - 解密

    private static func attempt(_ buffer: Data, _ candidate: Candidate) -> Data? {
        // 月色那种：IV 取前 16 字节，密文就是整段。
        if candidate.label == "yuese/ivfile16" {
            guard buffer.count >= 32, buffer.count % 16 == 0,
                  let iv = buffer.prefix(16).nilIfEmpty else { return nil }
            guard let plain = cbc(buffer, key: candidate.key, iv: iv) else { return nil }
            return trimmed(plain)
        }
        guard let iv = candidate.iv, buffer.count % 16 == 0,
              let plain = cbc(buffer, key: candidate.key, iv: iv) else { return nil }
        if let hit = trimmed(plain) { return hit }
        // 兜底：跳过前 16 字节再解（「IV 前缀 + 密文」而 IV 另给的那种格式）。
        guard buffer.count > 32, (buffer.count - 16) % 16 == 0,
              let shifted = cbc(buffer.dropFirst(16), key: candidate.key, iv: iv) else { return nil }
        return trimmed(shifted)
    }

    /// 去掉 PKCS7 尾巴；去掉之后必须像图片，否则不算命中。
    private static func trimmed(_ plain: Data) -> Data? {
        var body = plain
        if let last = body.last, (1...16).contains(Int(last)) {
            let pad = Int(last)
            if body.count > pad, body.suffix(pad).allSatisfy({ $0 == last }) { body = body.dropLast(pad) }
        }
        guard magic(of: body) != nil else { return nil }
        return body
    }

    private static func cbc(_ data: Data, key: Data, iv: Data) -> Data? {
        let size = data.count + kCCBlockSizeAES128
        var out = Data(count: size)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outBuffer -> CCCryptorStatus in
            let capacity = outBuffer.count
            return data.withUnsafeBytes { inBuffer in
                key.withUnsafeBytes { keyBuffer in
                    iv.withUnsafeBytes { ivBuffer in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                                keyBuffer.baseAddress, key.count, ivBuffer.baseAddress,
                                inBuffer.baseAddress, data.count, outBuffer.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess, moved > 0 else { return nil }
        return out.prefix(moved)
    }

    // MARK: - 形状

    /// 有的站把密文整体再套一层 base64 文本。
    private static func unguarded(_ data: Data) -> [(String, Data)] {
        let head = data.prefix(32)
        if head.contains(0xFF) || magic(of: data) != nil { return [("raw", data)] }
        // 纯 base64 文本：全是可见的 b64 字符，且长度是 4 的倍数。
        let isBase64ish = data.count > 64 && data.count % 4 == 0
            && data.allSatisfy { byte in
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                    || byte == 43 || byte == 47 || byte == 61 || byte == 10 || byte == 13
            }
        if isBase64ish, let decoded = Data(base64Encoded: data, options: .ignoreUnknownCharacters), decoded.count >= 32 {
            return [("b64", decoded), ("raw", data)]
        }
        return [("raw", data)]
    }

    private static func magic(of data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8)) { return "image/gif" }
        if data.starts(with: Array("RIFF".utf8)), data.dropFirst(8).prefix(4) == Data("WEBP".utf8) { return "image/webp" }
        if data.starts(with: Array("BM".utf8)) { return "image/bmp" }
        return nil
    }

    /// host → 最近命中的候选标签。同一个站连续出一屏封面时不必每次从第一组试起。
    private static let lock = NSLock()
    nonisolated(unsafe) private static var preferred: [String: String] = [:]
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }

    var nilIfEmpty: Data? { isEmpty ? nil : self }
}
