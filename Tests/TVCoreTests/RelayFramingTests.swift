import Foundation
import Testing
@testable import TVCore

// MARK: - 上游响应体的长度判定

/// 中继能不能把这条上游连接留着再用，全看这几个判定。
///
/// 判错的代价很具体：复用一条其实已经错位的连接，下一片会读到上一片的残余字节，
/// 播放器报「内容损坏 / -12881」。所以这些断言只钉一件事：**拿不准就算不能用**。
@Suite struct RelayFramingTests {

    private func parse(_ head: String, method: String = "GET") -> RelayResponseHead? {
        RelayResponseHead.parse(head, requestMethod: method)
    }

    @Test func contentLengthIsAReusableWindow() {
        let head = parse("HTTP/1.1 206 Partial Content\r\nContent-Length: 1024\r\nContent-Range: bytes 0-1023/9000")
        #expect(head?.framing == .length(1024))
        #expect(head?.keepAlive == true)
    }

    @Test func chunkedWinsOverContentLength() {
        // 两者同时出现在真实 CDN 上并不少见；按 RFC，`Transfer-Encoding` 说了算。
        let head = parse("HTTP/1.1 200 OK\r\nContent-Length: 12\r\nTransfer-Encoding: chunked")
        #expect(head?.framing == .chunked)
    }

    @Test func aCloseIsHonoured() {
        let head = parse("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close")
        #expect(head?.keepAlive == false)
        #expect(head?.framing == .length(4))
    }

    /// HTTP/1.0 默认不保持连接 —— 没写 `keep-alive` 就不能复用。
    @Test func http10IsNotKeepAliveByDefault() {
        #expect(parse("HTTP/1.0 200 OK\r\nContent-Length: 4")?.keepAlive == false)
        #expect(parse("HTTP/1.0 200 OK\r\nContent-Length: 4\r\nConnection: keep-alive")?.keepAlive == true)
    }

    /// 没有长度信息：只能读到关闭为止，读完连接也就没了。
    @Test func noLengthIsNeverReusable() {
        let head = parse("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t")
        #expect(head?.framing == .untilClose)
        #expect(head?.keepAlive == false)
    }

    /// 没有体的几个状态码：读完头就结束，可以复用。
    @Test func emptyBodiesEndAtTheHead() {
        #expect(parse("HTTP/1.1 304 Not Modified")?.framing == .length(0))
        #expect(parse("HTTP/1.1 204 No Content", method: "GET")?.framing == .length(0))
        #expect(parse("HTTP/1.1 200 OK\r\nContent-Length: 999", method: "HEAD")?.framing == .length(0))
    }

    @Test func aNonHTTPAnswerIsRejected() {
        // 有些站会先吐一段空白或错误文本；这种不能按 HTTP 处理。
        #expect(parse("") == nil)
        #expect(parse("not http at all") == nil)
        #expect(parse("HTTP/1.1 abc OK") == nil)
    }
}

// MARK: - chunked 体的结束判定

@Suite struct ChunkedBodyScannerTests {

    private func chunked(_ text: String) -> Data { Data(text.utf8) }

    @Test func aSimpleChunkedBodyFinishes() {
        var scanner = ChunkedBodyScanner()
        let finished = scanner.consume(chunked("4\r\nWiki\r\n0\r\n\r\n"))
        #expect(finished)
        #expect(scanner.finished)
    }

    /// 切在任何位置都要能续上 —— 包括切在 `\r\n` 中间、切在长度行中间。
    @Test func everySplitPointSurvives() {
        let body = "1a\r\nabcdefghijklmnopqrstuvwxyz\r\n5\r\n12345\r\n0\r\n\r\n"
        let bytes = Array(body.utf8)
        for split in 1..<bytes.count {
            var scanner = ChunkedBodyScanner()
            let first = scanner.consume(Data(bytes[0..<split]))
            let second = scanner.consume(Data(bytes[split...]))
            #expect(second || first, "切在 \(split) 处时没有判定结束")
            #expect(scanner.finished, "切在 \(split) 处时没有判定结束")
        }
    }

    /// 尾部（trailer）存在时，要读到最后一个空行才算结束。
    @Test func trailersDelayTheEnd() {
        var scanner = ChunkedBodyScanner()
        let firstPart = scanner.consume(chunked("2\r\nhi\r\n0\r\nX-Checksum: abc\r\n"))
        #expect(!firstPart)
        #expect(!scanner.finished)
        let trailerEnd = scanner.consume(chunked("\r\n"))
        #expect(trailerEnd)
        #expect(scanner.finished)
    }

    /// 长度行带扩展（`;name=value`）也要认。
    @Test func chunkExtensionsAreIgnored() {
        var scanner = ChunkedBodyScanner()
        let withExtension = scanner.consume(chunked("3;foo=bar\r\nabc\r\n0\r\n\r\n"))
        #expect(withExtension)
        #expect(scanner.finished)
    }

    /// 大块（超过一次 receive 的 64 KB）跨多次到达。
    @Test func aLargeChunkSpansReads() {
        var scanner = ChunkedBodyScanner()
        let size = 200_000
        let header = Data("\(String(size, radix: 16))\r\n".utf8)
        let head = scanner.consume(header + Data(repeating: 0x41, count: 100_000))
        #expect(!head)
        #expect(!scanner.finished)
        let tail = scanner.consume(Data(repeating: 0x41, count: 100_000) + Data("\r\n0\r\n\r\n".utf8))
        #expect(tail)
        #expect(scanner.finished)
    }
}

// MARK: - 复用池的键

@Suite struct RelayUpstreamPoolTests {

    /// 键必须区分「走哪条腿」—— 同一条连接复用到另一条腿，出口判定就反了。
    @Test func theKeySeparatesLegs() {
        let direct = RelayUpstreamPool.key(proxyID: nil, dialHost: nil, scheme: "https",
                                           host: "cdn.example.com", port: 443)
        let proxied = RelayUpstreamPool.key(proxyID: "loon", dialHost: "192.168.1.5", scheme: "https",
                                            host: "cdn.example.com", port: 443)
        #expect(direct != proxied)
        // 同一个地址大小写不同要落到同一个键（域名不区分大小写）。
        #expect(direct == RelayUpstreamPool.key(proxyID: nil, dialHost: nil, scheme: "HTTPS",
                                                host: "CDN.Example.com", port: 443))
    }

    /// 开关能关：真机上万一复用出问题，一条偏好就能退回逐条连接。
    @Test func thePoolCanBeSwitchedOff() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: RelayUpstreamPool.key)
        defer {
            if let saved { defaults.set(saved, forKey: RelayUpstreamPool.key) }
            else { defaults.removeObject(forKey: RelayUpstreamPool.key) }
        }
        RelayUpstreamPool.enabled = false
        #expect(RelayUpstreamPool.enabled == false)
        RelayUpstreamPool.enabled = true
        #expect(RelayUpstreamPool.enabled)
    }
}
