import Foundation
import Testing
@testable import TVCore

/// 源中转（SourceRelay）：旧公共中继只负责**解包**，新的中转地址是映匣自己的回环中继。
///
/// 这一套钉两件事：
///   ① 历史订阅里带过来的 `149.104.28.149:8100/cms[r]/<token>/<host>/<path>` 能还原成真实地址
///      （scheme / host / port / path / query 全保留），升级后自动落到直连；
///   ② 新的中转**不再产生任何外部服务器地址** —— 只有 `127.0.0.1` 的回环，
///      配了出口代理走 `/p/<proxyID>/…`，没配就走 `/d/…`。
@Suite struct SourceRelayTests {

    @Test func legacyRelayIsUnwrappedWithPortAndQueryIntact() {
        let direct = "https://api.example.com:8443/api.php?id=1&v=2"
        let legacy = "http://149.104.28.149:8100/cmsr/rex8f3a2c1d/api.example.com:8443/api.php?id=1&v=2"
        #expect(SourceRelay.isRelayed(legacy))
        #expect(SourceRelay.directAddress(legacy) == direct)
    }

    @Test func legacyRelayUnwrapsPlainHTTP() {
        let legacy = "http://149.104.28.149:8100/cms/rex8f3a2c1d/91md.me/api.php/provide/vod"
        #expect(SourceRelay.directAddress(legacy) == "http://91md.me/api.php/provide/vod")
    }

    @Test func aRelayedAddressIsNeverProducedForAnOrdinarySource() {
        let direct = "https://api.example.com/api.php?id=1"
        let relayed = SourceRelay.relayedAddress(direct, base: URL(string: "http://127.0.0.1:9999/"), proxyID: "p1")
        #expect(relayed.hasPrefix("http://127.0.0.1:9999/p/p1/https/api.example.com/443/"))
        #expect(!relayed.contains("149.104.28.149"))
        // 回环编码是自洽的：端口、路径、query 都能原样解回来。
        let target = try? #require(LocalProxyServer.parse(URL(string: relayed)!.path + "?" + (URL(string: relayed)!.query ?? "")))
        #expect(target?.host == "api.example.com")
        #expect(target?.port == 443)
        #expect(target?.proxyID == "p1")
        #expect(target?.path.hasSuffix("/api.php?id=1") == true)
    }

    @Test func noProxyMeansNoHop() {
        // 没有出口代理时中转没有意义：地址保持原样，不为绕一圈回环多付一次转发。
        #expect(SourceRelay.apply(.proxy, to: "https://api.example.com/api",
                                  base: URL(string: "http://127.0.0.1:9999/"), proxyID: nil) == "https://api.example.com/api")
        // 中继没起来（base 为 nil）时同理：退直连，不产生一个打不开的地址。
        #expect(SourceRelay.apply(.proxy, to: "https://api.example.com/api", base: nil, proxyID: "p1") == "https://api.example.com/api")
    }

    @Test func nonHTTPApisAreReturnedUnchanged() {
        // JAR/csp 类、本地文件不是原生 CMS 端点，不中转。
        let base = URL(string: "http://127.0.0.1:9999/")
        #expect(SourceRelay.relayedAddress("csp_Spider", base: base, proxyID: "p1") == "csp_Spider")
        #expect(SourceRelay.relayedAddress("file:///tmp/a.json", base: base, proxyID: "p1") == "file:///tmp/a.json")
        #expect(SourceRelay.relayedAddress("jar://com.x.Spider", base: base, proxyID: "p1") == "jar://com.x.Spider")
    }

    @Test func directAddressLeavesAnOrdinaryAddressAlone() {
        #expect(SourceRelay.directAddress("https://api.example.com/api") == "https://api.example.com/api")
    }
}

/// 测速里「从 m3u8 / 路径读出声明分辨率」的纯解析。网络探测本身不测，这里锁解析不臆造。
@Suite struct SourceProbeDeclaredHeightTests {

    @Test func readsResolutionFromAnM3U8() {
        let head = #"#EXT-X-STREAM-INF:RESOLUTION=1920x1080,BANDWIDTH=5000000"#
        #expect(SourceProbeRunner.declaredHeight(in: head, url: URL(string: "https://x.com/a.m3u8")!) == 1080)
    }

    @Test func readsResolutionFromAPathToken() {
        #expect(SourceProbeRunner.declaredHeight(in: "", url: URL(string: "https://x.com/a/1080p.m3u8")!) == 1080)
        #expect(SourceProbeRunner.declaredHeight(in: "", url: URL(string: "https://x.com/x720.m3u8")!) == 720)
        #expect(SourceProbeRunner.declaredHeight(in: "", url: URL(string: "https://x.com/2160p.m3u8")!) == 2160)
        #expect(SourceProbeRunner.declaredHeight(in: "", url: URL(string: "https://x.com/film_480p.mp4")!) == 480)
    }

    @Test func returnsNilInsteadOfGuessing() {
        #expect(SourceProbeRunner.declaredHeight(in: "", url: URL(string: "https://x.com/video.mp4")!) == nil)
        #expect(SourceProbeRunner.declaredHeight(in: "just text", url: URL(string: "https://x.com/a.m3u8")!) == nil)
    }
}
