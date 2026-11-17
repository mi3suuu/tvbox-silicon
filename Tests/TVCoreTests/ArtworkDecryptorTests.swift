import CommonCrypto
import Foundation
import Testing
@testable import TVCore

/// 加密封面：GS/avbox 与月色那类站给的 `xxx.jpg` 其实是 AES 密文。
///
/// 判定不认站点、只认「解出来像不像图片」，所以这里用一把表里的 key 造一张密文图，
/// 断言能解回来 —— 顺带钉住「明文图不会被白解一遍」与「不是图片的数据不会被当成图片」。
@Suite struct ArtworkDecryptorTests {

    /// `yy` 表里的那组：key/iv 都是 16 字节的可见字符。
    private let key = Data("saIZXc4yMvq0Iz56".utf8)
    private let iv = Data("kbJYtBJUECT0oyjo".utf8)

    private func encrypted(_ plain: Data) -> Data {
        // PKCS7 补到整块。
        var body = plain
        let pad = 16 - (plain.count % 16)
        body.append(contentsOf: [UInt8](repeating: UInt8(pad), count: pad))
        var out = Data(count: body.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outBuffer -> CCCryptorStatus in
            let capacity = outBuffer.count
            return body.withUnsafeBytes { inBuffer in
                key.withUnsafeBytes { keyBuffer in
                    iv.withUnsafeBytes { ivBuffer in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                                keyBuffer.baseAddress, key.count, ivBuffer.baseAddress,
                                inBuffer.baseAddress, body.count, outBuffer.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        precondition(status == kCCSuccess)
        return out.prefix(moved)
    }

    /// 一张最小的 JPEG：只有魔数加几个填充字节 —— 解密只需要魔数对得上。
    private var jpeg: Data {
        Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x11, count: 60)
    }

    @Test func anAESCoverComesBackAsAnImage() throws {
        let cipher = encrypted(jpeg)
        #expect(!ArtworkDecryptor.isImage(cipher))
        let plain = try #require(ArtworkDecryptor.decode(cipher))
        #expect(plain.starts(with: [0xFF, 0xD8, 0xFF]))
        #expect(ArtworkDecryptor.isImage(plain))
    }

    /// 明文的图不该被再解一遍：`isImage` 一次前四字节比较就够。
    @Test func aPlainImageIsRecognisedAndLeftAlone() {
        #expect(ArtworkDecryptor.isImage(jpeg))
        for magic in [[0x89, 0x50, 0x4E, 0x47], Array("GIF89a".utf8), Array("BM".utf8)] {
            let data = Data(magic) + Data(repeating: 0, count: 40)
            #expect(ArtworkDecryptor.isImage(data), "\(magic)")
        }
    }

    /// 解不出来的字节返回 nil，而不是一段乱码 —— 调用方据此按原来的失败处理。
    @Test func nonsenseStaysNonsense() {
        #expect(ArtworkDecryptor.decode(Data(repeating: 0x5A, count: 128)) == nil)
        #expect(ArtworkDecryptor.decode(Data()) == nil)
        // 长度不是整块：连试都不用试。
        #expect(ArtworkDecryptor.decode(Data(repeating: 0xFF, count: 45)) == nil)
    }

    /// 有的站把密文整体套一层 base64。两种形态都要能解。
    @Test func base64WrappedCipherIsUnwrappedToo() throws {
        let wrapped = Data(encrypted(jpeg).base64EncodedString().utf8)
        let plain = try #require(ArtworkDecryptor.decode(wrapped))
        #expect(plain.starts(with: [0xFF, 0xD8, 0xFF]))
    }
}
