import Foundation
import Testing
@testable import TVCore

/// 这三个清单是**从番茄资源采集接口真机抓下来的原始响应**（2026-11-17），
/// 不是手工构造的样本 —— 这样测试才有资格代表线上行为。
///
/// 抓取命令：
/// ```
/// curl -H "User-Agent: <chrome>" "https://fqm3u8.cc/20261030/9fcf6455e14b0264/index.m3u8"
/// ```
/// 三个视频（vod_id 119829 / 119830 / 119832）用的是**同一段开头广告**。
private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "m3u8",
                                            subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

private let origin = URL(string: "https://fqm3u8.cc/20261030/9fcf6455e14b0264/index.m3u8")!

@Test func theSameAdPrefixIsStrippedFromEveryVideoOfThisSource() throws {
    // 用户报的现象：「每个视频前 15 秒都是一样的」。
    // 三个不同视频的清单，前缀都是同一批分片 → 必须都能剥掉，且剥掉的长度一致。
    var stripped: [Double] = []
    for name in ["p0", "p1", "p3"] {
        let text = try fixture(name)
        let result = try #require(AdPrefix.strip(text, origin: origin), "\(name) 没识别出前缀")
        // 实测：4 个分片、15.03 秒。
        #expect(result.segments == 4)
        #expect(abs(result.seconds - 15.033333) < 0.01)
        stripped.append(result.seconds)
        // 剥完必须还留着正片。
        #expect(result.text.contains("#EXT-X-ENDLIST"))
        #expect(result.text.contains("seg_00000.jpg"))
    }
    // 三个视频剥掉的时长必须完全一致 —— 这就是「固定前缀」的定义。
    #expect(Set(stripped).count == 1)
}

@Test func theAdSegmentsAreGoneAndTheBodyIsIntact() throws {
    let text = try fixture("p0")
    let result = try #require(AdPrefix.strip(text, origin: origin))

    // ① 广告分片的路径在结果里**一个都不能剩**
    #expect(!result.text.contains("seg_k8bord"))

    // ② 正片分片一个都不能少：原清单 1313 段，去掉 4 段应为 1309
    let before = text.components(separatedBy: "\n").filter { $0.contains("/seg_") && !$0.hasPrefix("#") }.count
    let after = result.text.components(separatedBy: "\n").filter { $0.contains("/seg_") && !$0.hasPrefix("#") }.count
    #expect(before - after == 4, "只该少 4 个分片，实际 before=\(before) after=\(after)")

    // ③ 正片首段必须还在，且成为新的第一段
    let bodyLines = result.text.components(separatedBy: "\n").filter { $0.contains("/seg_") && !$0.hasPrefix("#") }
    #expect(bodyLines.first?.contains("seg_00000.jpg") == true)
}

@Test func onlyTheLeadingPrefixIsCutNotTheDiscontinuitiesInsideTheFilm() throws {
    // 这条清单全片有 13 个 DISCONTINUITY，只有第 1 个是"广告→正片"。
    // 切错会把正片切碎，所以必须验证剩下的 discontinuity 数量。
    let text = try fixture("p0")
    let totalDiscontinuities = text.components(separatedBy: "\n").filter { $0 == "#EXT-X-DISCONTINUITY" }.count
    #expect(totalDiscontinuities == 13)

    let result = try #require(AdPrefix.strip(text, origin: origin))
    let kept = result.text.components(separatedBy: "\n").filter { $0 == "#EXT-X-DISCONTINUITY" }.count
    // 被去掉的只有开头那一个；正片内部的 12 个必须原样保留。
    #expect(kept == 12)
}

@Test func aPlaylistWithoutAPrefixIsLeftExactlyAsItIs() throws {
    // 把广告段换成与正片同目录的分片 → 结构上是"正片被正常分段"，不是广告前缀，必须拒绝。
    let text = try fixture("p0")
    let patched = text.replacingOccurrences(
        of: "/20261116/df50c5905e2cbc7e/seg_k8bord_",
        with: "https://fqts5.top/20261030/9fcf6455e14b0264/seg_")
    #expect(AdPrefix.strip(patched, origin: origin) == nil)
}

@Test func aLivePlaylistIsNeverTouched() throws {
    // 直播清单没有 ENDLIST：切了会让播放器追不上直播边缘。
    let text = try fixture("p0").replacingOccurrences(of: "#EXT-X-ENDLIST", with: "")
    #expect(AdPrefix.strip(text, origin: origin) == nil)
}

@Test func aMasterPlaylistIsNeverTouched() throws {
    let master = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
    360/index.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
    720/index.m3u8
    #EXT-X-ENDLIST
    """
    #expect(AdPrefix.strip(master, origin: origin) == nil)
}

@Test func aShortClipWhoseStartIsContentIsNotCut() throws {
    // 全片 60 秒的短片：前 15 秒是内容不是广告（占比也超 10%）。必须拒绝。
    var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:8", "#EXT-X-PLAYLIST-TYPE:VOD"]
    lines += ["#EXT-X-KEY:METHOD=NONE"]
    for i in 0..<4 { lines += ["#EXTINF:4,", "/ad/x/seg_\(i).jpg"] }
    lines.append("#EXT-X-DISCONTINUITY")
    for i in 0..<11 { lines += ["#EXTINF:4,", "https://b/y/seg_\(i).jpg"] }
    lines.append("#EXT-X-ENDLIST")
    #expect(AdPrefix.strip(lines.joined(separator: "\n"), origin: origin) == nil)
}

@Test func aPrefixThatSharesTheFilmsFolderIsNotAnAd() throws {
    // 广告与正片同目录 = 同一批编号连续分片，那是正片的正常分段，不能切。
    let text = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:8
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXTINF:4,
    https://cdn.example/v/abc/seg_00000.ts
    #EXTINF:4,
    https://cdn.example/v/abc/seg_00001.ts
    #EXT-X-DISCONTINUITY
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00002.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00003.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00004.ts
    #EXT-X-ENDLIST
    """
    #expect(AdPrefix.strip(text, origin: origin) == nil)
}
