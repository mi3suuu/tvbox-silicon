import Foundation
import Testing
@testable import TVCore

/// 在线播放加速的**准入判据**。
///
/// 这一层最容易出的错不是「不够快」，而是「不该包的也包了」：
/// 每多包一跳就多一次回环转发，对已经并发的 HLS 是净损失；
/// 对自己代理自己则是死循环。所以下面每条否决条件都单独钉住。

private func url(_ text: String) -> URL { URL(string: text)! }

// MARK: - 该包的

@Test func aPlainHTTPMediaLinkCanBeAccelerated() {
    #expect(PlaybackAccelerator.canAccelerate(url("https://cdn.example.com/movie.mp4")))
    #expect(PlaybackAccelerator.canAccelerate(url("http://1.2.3.4:8100/a/b/index.mkv")))
}

/// 没有扩展名的直链也要能加速 —— 很多 CMS 的播放地址形如 `/play/12345`。
@Test func anExtensionlessLinkIsStillEligible() {
    #expect(PlaybackAccelerator.canAccelerate(url("https://cdn.example.com/play/12345")))
}

// MARK: - 不该包的（每条都有具体理由）

/// HLS 的分片本来就是独立 HTTP 资源，AVPlayer 自己会并发拉。
/// 再包一层只多一跳，反而更慢。
@Test func hlsPlaylistsAreNeverWrapped() {
    #expect(!PlaybackAccelerator.canAccelerate(url("https://cdn.example.com/live/index.m3u8")))
    #expect(!PlaybackAccelerator.canAccelerate(url("https://cdn.example.com/hls/master")))
    #expect(!PlaybackAccelerator.canAccelerate(url("https://cdn.example.com/a/.m3u8")))
}

/// 自己代理自己会形成递归。
@Test func loopbackAddressesAreNeverWrapped() {
    #expect(!PlaybackAccelerator.canAccelerate(url("http://127.0.0.1:9000/a.mp4")))
    #expect(!PlaybackAccelerator.canAccelerate(url("http://localhost:9000/a.mp4")))
}

/// 本地文件与自造协议不需要代理 —— 它们本来就不走网络。
@Test func localAndCustomSchemesAreNeverWrapped() {
    #expect(!PlaybackAccelerator.canAccelerate(url("file:///tmp/a.mp4")))
    #expect(!PlaybackAccelerator.canAccelerate(url("tvbox-download://abc")))
}

// MARK: - 并发数

/// 只开一条连接等于没加速，应当直接不包装（省掉一跳回环）。
///
/// 这条用 `session` 的返回值验证而不是看 `canAccelerate`：
/// 准入是「能不能」，包装与否还取决于「值不值」。
@Test func aSingleLaneIsNotWorthWrapping() async {
    let session = await PlaybackAccelerator.shared.session(
        for: url("https://cdn.example.com/movie.mp4"), headers: [:], lanes: 1)
    #expect(session == nil)
}

/// 并发数有上限：开太多会被源站限流或直接拒连，也会挤占下载队列的带宽。
@Test func theLaneCountIsCapped() async {
    let session = await PlaybackAccelerator.shared.session(
        for: url("https://cdn.example.com/movie.mp4"), headers: [:], lanes: 64)
    let lanes = try! #require(session).lanes
    #expect(lanes <= 8)
    if let session { PlaybackAccelerator.shared.release(session) }
}

/// 合格的地址会拿到一个回环 URL —— 那才是能交给 AVPlayer 的东西。
@Test func anEligibleLinkGetsALoopbackAddress() async throws {
    let session = try #require(await PlaybackAccelerator.shared.session(
        for: url("https://cdn.example.com/movie.mp4"), headers: [:], lanes: 4))
    #expect(session.url.host == "127.0.0.1")
    #expect(session.url.scheme == "http")
    #expect(session.origin.absoluteString == "https://cdn.example.com/movie.mp4")
    // 扩展名要带过去：AVPlayer 靠它判断容器类型。
    #expect(session.url.pathExtension == "mp4")
    PlaybackAccelerator.shared.release(session)
}
