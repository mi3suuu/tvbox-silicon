import Foundation
import Testing
@testable import TVCore

// MARK: - Mock

/// 用 URLProtocol 拦截 `SourceProbeRunner.probe` 的 `session.data(for:)`，按请求路径返回
/// 取消 / 超时 / 404 / 200 四种结果，不真联网。
///
/// `probe` 的真实网络方式（SourceProbe.swift:392）是 `try await session.data(for: request)`；
/// URLProtocol 是 URLSession 的官方注入点，`data(for:)` 会照常走 protocol 栈，所以四种结果都能
/// 精确构造，不需要子类化 URLSession（其 async API 也不是 open，无法 override）。
private final class ProbeProtocol: URLProtocol, @unchecked Sendable {
    /// `/flaky` 用：第一次回一张 HTML 错误页，第二次回真清单。
    private static let lock = NSLock()
    nonisolated(unsafe) private static var flakyHits = 0

    static func resetFlaky() { lock.lock(); flakyHits = 0; lock.unlock() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch request.url?.path {
        case "/flaky":
            ProbeProtocol.lock.lock()
            ProbeProtocol.flakyHits += 1
            let hit = ProbeProtocol.flakyHits
            ProbeProtocol.lock.unlock()
            if hit == 1 {
                respond(status: 200, body: Data("<html><body>502 Bad Gateway</body></html>".utf8))
            } else {
                respond(status: 200, body: Data("#EXTM3U\n#EXTINF:4,\nseg1.ts\n".utf8))
            }
        case "/html":
            respond(status: 200, body: Data("<html><body>player</body></html>".utf8))
        case "/cancel":
            // P1-3：取消是一个「非结论」。data(for:) 应抛出 URLError(.cancelled)，
            // 让 probe 走进 `(error as? URLError)?.code == .cancelled` 分支。
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        case "/timeout":
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        case "/notfound":
            respond(status: 404, body: Data())
        default:
            // 64KB 的 200：elapsed 极小、kBps 远大于 64，判为 .reachable（而非 .slow）。
            respond(status: 200, body: Data(repeating: 0x41, count: 64 * 1024))
        }
    }

    override func stopLoading() {}

    private func respond(status: Int, body: Data) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func probingSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ProbeProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - Tests

@Suite struct SourceProbeCancelTests {

    // MARK: P1-3 核心：取消不能污染 5 分钟缓存

    @Test func cancelledProbeIsUnknownAndWritesNoTimestamp() async {
        let result = await SourceProbeRunner.probe(
            url: URL(string: "https://example.com/cancel")!,
            session: probingSession()
        )

        #expect(result.reachability == .unknown)
        // 不写 measuredAt → 落到构造器默认值 .distantPast，缓存里永远过期、下次必重试。
        #expect(result.measuredAt == .distantPast)
    }

    /// 超时**不是**「不通」，是「没测出来」。
    ///
    /// ⛔ 2026-11-17 改的口径。用户报「标注不通，点进去却能播」：探针一次 `timedOut`
    ///    就把线记成 `.unreachable`，界面红点「不通」、按结果分组还会把它搬进不通组；
    ///    而同一地址隔一秒就回 200（实测 `v.lzcdn31.com` 的主清单）。
    ///    现在：没拿到任何答复 → 重试一次 → 仍是没答复则记 `.unknown`（未测）。
    ///    真正的死线仍会判死，它们明确回 4xx/5xx（见 `notFoundResponseIsUnreachable`）。
    @Test func timedOutProbeIsUnknownAfterARetry() async {
        let before = Date()
        let result = await SourceProbeRunner.probe(
            url: URL(string: "https://example.com/timeout")!,
            session: probingSession()
        )

        #expect(result.reachability == .unknown)
        #expect(result.measuredAt >= before)
        #expect(abs(result.measuredAt.timeIntervalSinceNow) < 5)
    }

    // MARK: 缓存新鲜度语义：未知 → 重试，不可达 → 不重试

    @Test func cancelledReadingIsStaleAndWillBeRetried() async {
        let result = await SourceProbeRunner.probe(
            url: URL(string: "https://example.com/cancel")!,
            session: probingSession()
        )
        #expect(result.reachability == .unknown)
        // .distantPast 使 now - measuredAt > 300 恒真 → 缓存视为过期，下次会重试。
        #expect(result.isStale(now: Date(), tolerance: 300))
    }

    @Test func unreachableReadingIsFreshAndWillNotBeRetried() async {
        // 用 404（明确答复）而不是超时：超时现在记 `.unknown`，那条路径由
        // `timedOutProbeIsUnknownAfterARetry` 负责。
        let result = await SourceProbeRunner.probe(
            url: URL(string: "https://example.com/notfound")!,
            session: probingSession()
        )
        #expect(result.reachability == .unreachable)
        // measuredAt 是「现在」→ 5 分钟内不重试。
        #expect(!result.isStale(now: Date(), tolerance: 300))
    }

    // MARK: 成功与状态码路径

    @Test func okResponseIsReachableWithMetrics() async {
        let result = await SourceProbeRunner.probe(
            url: URL(string: "https://example.com/ok")!,
            session: probingSession()
        )

        #expect(result.reachability == .reachable)
        #expect(result.latencyMilliseconds != nil)
        #expect((result.kilobytesPerSecond ?? 0) > 0)
        #expect(abs(result.measuredAt.timeIntervalSinceNow) < 5)
    }

    @Test func notFoundResponseIsUnreachable() async {
        // 404 不抛错：走 do 分支，状态码不在 200..<400 → .unreachable。
        let result = await SourceProbeRunner.probe(
            url: URL(string: "https://example.com/notfound")!,
            session: probingSession()
        )

        #expect(result.reachability == .unreachable)
        #expect(abs(result.measuredAt.timeIntervalSinceNow) < 5)
    }

    // MARK: isStale 严格大于边界

    @Test func staleUsesStrictlyGreaterThanTolerance() {
        let now = Date()

        let exactlyTolerance = SourceProbeResult(
            reachability: .reachable, measuredAt: now.addingTimeInterval(-300)
        )
        #expect(!exactlyTolerance.isStale(now: now, tolerance: 300))

        let justPastTolerance = SourceProbeResult(
            reachability: .reachable, measuredAt: now.addingTimeInterval(-301)
        )
        #expect(justPastTolerance.isStale(now: now, tolerance: 300))
    }

    // MARK: - 抖动重试（2026-11-17）

    /// 200 却回了一张 HTML 错误页：再问一次，第二次是真清单 —— 判它 `hls`，不是「需解析」。
    ///
    /// 实测原型：`v.lzcdn31.com/…/index.m3u8` 第一次回错误页、同一时刻复测回 96 字节的主清单。
    /// 没有这一次重试，这条 1080×608 的线会在界面上被标成「需解析」并停止播放。
    @Test func aTransientErrorPageIsRetriedOnce() async {
        ProbeProtocol.resetFlaky()
        let result = await SourceProbeRunner.probe(
            url: URL(string: "https://example.com/flaky")!,
            session: probingSession()
        )
        #expect(result.mediaKind == "hls")
        #expect(!result.isPageOnly)
    }

    /// 两次都是网页才认定「需解析」。
    @Test func anAlwaysPageIsPageOnly() async {
        let result = await SourceProbeRunner.probe(
            url: URL(string: "https://example.com/html")!,
            session: probingSession()
        )
        #expect(result.mediaKind == "html")
        #expect(result.isPageOnly)
    }

    // MARK: - 失败不覆盖刚测到的好读数

    /// 刚测到能播，两分钟内的失败不覆盖它 —— 否则界面闪一下「不通」，用户点进去能播。
    @Test func aFreshSuccessIsNotOverwrittenByAFailure() {
        let now = Date()
        let good = SourceProbeResult(reachability: .reachable, measuredAt: now.addingTimeInterval(-30))
        let failed = SourceProbeResult(reachability: .unreachable, measuredAt: now)
        #expect(SourceProbeStore.shouldKeepExisting(good, over: failed))
    }

    /// 旧读数已经过期（超过宽限期）就让它被覆盖：真的掉线必须能反映出来。
    @Test func anOldSuccessYieldsToAFailure() {
        let now = Date()
        let old = SourceProbeResult(reachability: .reachable, measuredAt: now.addingTimeInterval(-600))
        let failed = SourceProbeResult(reachability: .unreachable, measuredAt: now)
        #expect(!SourceProbeStore.shouldKeepExisting(old, over: failed))
    }

    /// 新的成功永远覆盖旧的失败。
    @Test func aSuccessAlwaysReplacesAFailure() {
        let now = Date()
        let failed = SourceProbeResult(reachability: .unreachable, measuredAt: now.addingTimeInterval(-10))
        let good = SourceProbeResult(reachability: .reachable, measuredAt: now)
        #expect(!SourceProbeStore.shouldKeepExisting(failed, over: good))
    }
}
