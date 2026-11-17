import Foundation
import Testing
@testable import TVCore

/// 这四份清单是**从真实的成人源抓下来的原始响应**（2026-11-17，由采样任务采集），
/// 不是手工构造的样本 —— 只有这样测试才有资格代表线上行为。
///
/// | 文件 | 来源 | 形态 |
/// |---|---|---|
/// | `A.m3u8`   | 番茄 fqzy.me | 主目录 98.5%，广告两段 1.3% + 0.2%（15.03s 前贴） |
/// | `X1.m3u8`  | 番茄（另一分类，720p 变体） | 主 98.0%，广告同两段；**131 个 DISCONTINUITY** |
/// | `Y2.m3u8`  | 玉兔 apiyutu.com | 主 93.2%，广告 6.8%（26.07s）；**全片零 AES** |
/// | `Z2.m3u8`  | 155 155api.com | 主 99.4%，广告 0.6%（25.76s）；**全片零 AES** |
///
/// 后两个源正是「不能用 `METHOD=NONE` 判广告」的证据：它们正片也是 NONE。
private func playlist(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "m3u8",
                                            subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

private let origin = URL(string: "https://fqts5.top/20261030/dca7e45f5e74e036/index.m3u8")!

private func segments(_ text: String) -> [String] {
    text.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

private func bodySeconds(_ text: String) -> Double {
    zip(segments(text), text.components(separatedBy: "\n").filter { $0.hasPrefix("#EXTINF:") })
        .compactMap { _, inf -> Double? in
            Double(inf.dropFirst(8).prefix { $0 != "," }.trimmingCharacters(in: .whitespaces))
        }.reduce(0, +)
}

@Test func everyRealSourceGetsItsAdGroupsRemoved() throws {
    // 四个源四种形态（两个分类 + 两个不同站），都必须能剥。
    // ⚠️ 只删**开头前缀**，中插广告一律保留（见 AdPrefix 里对时间轴洞的说明）。
    //    所以这里的预期值是各 fixture 的**前缀**时长，不是全部广告时长：
    //      A  前缀 15.03s（另有两段中插 89.80s，故意不删）
    //      X1 前缀 15.03s（另有中插 59.87s）
    //      Y2 前缀 26.07s（没有中插）
    //      Z2 前缀 25.76s（另有中插 25.76s）
    for (name, expectedSeconds) in [("A", 15.03), ("X1", 15.03), ("Y2", 26.07), ("Z2", 25.76)] {
        let text = try playlist(name)
        let result = try #require(AdPrefix.strip(text, origin: origin), "\(name) 没识别出广告")
        #expect(abs(result.seconds - expectedSeconds) < 0.5,
                "\(name) 剥掉 \(result.seconds)s，预期约 \(expectedSeconds)s")
        #expect(result.text.contains("#EXT-X-ENDLIST"))
        #expect(!segments(result.text).isEmpty)
    }
}

@Test func theMainFilmIsKeptWholeAndOnlyTheAdGroupsGo() throws {
    let text = try playlist("A")
    let before = segments(text).count
    let beforeSeconds = bodySeconds(text)
    let result = try #require(AdPrefix.strip(text, origin: origin))
    let after = segments(result.text).count
    let afterSeconds = bodySeconds(result.text)

    // A 的前缀 = 开头 4 片 / 15.03s。中插的 24 片必须**原样留着**。
    #expect(before - after == 4, "before=\(before) after=\(after)")
    #expect(abs((beforeSeconds - afterSeconds) - 15.03) < 0.1,
            "少了 \(beforeSeconds - afterSeconds)s")
    // 正片 98.5% 必须一秒不少。
    #expect(afterSeconds > beforeSeconds * 0.95)
}

@Test func hugeDiscontinuityCountIsNotUsedAsTheBoundary() throws {
    // ⛔ 这是关键回归：X1 有 131 个 DISCONTINUITY，但真实广告块只有 2 组。
    //    若拿 DISCONTINUITY 当切点（上一版的做法），会把正片切得粉碎。
    let text = try playlist("X1")
    let discontinuities = text.components(separatedBy: "\n").filter { $0 == "#EXT-X-DISCONTINUITY" }.count
    #expect(discontinuities > 100, "这份 fixture 应该是高 DISCONTINUITY 形态，实际 \(discontinuities)")

    let result = try #require(AdPrefix.strip(text, origin: origin))
    let after = segments(result.text).count
    let before = segments(text).count
    // X1 的前缀是 4 片。只该少这 4 片（中插不删），
    // 且绝不能因为 131 个 DISCONTINUITY 把正片切碎。
    #expect(before - after == 4,
            "切掉了 \(before - after) 个分片；应恰好是开头 4 片前缀")
}

@Test func theFilmsOwnAESKeyTagsSurvive() throws {
    // ⛔ 上一版我写错过：组装时把每段的标签过滤成只剩 EXTINF，
    //    正片是 AES-128 加密的，KEY 标签一丢就解密失败 ——
    //    「广告没了但正片也放不出来」，比不去广告更糟。
    let text = try playlist("A")
    #expect(text.contains("#EXT-X-KEY:METHOD=AES-128"))

    let result = try #require(AdPrefix.strip(text, origin: origin))
    #expect(result.text.contains("#EXT-X-KEY:METHOD=AES-128"),
            "正片的 AES KEY 标签被吃掉了")
    // 正片每一段都还带着 EXTINF。
    #expect(result.text.components(separatedBy: "\n").filter { $0.hasPrefix("#EXTINF:") }.count
            == segments(result.text).count)
}

@Test func aPlaylistWhoseBodyIsUnencryptedWasNeverCutByMethodNone() throws {
    // 玉兔/155 全片 METHOD=NONE。若判据是「NONE=广告」，这两个源会被整片删掉。
    for name in ["Y2", "Z2"] {
        let text = try playlist(name)
        #expect(!text.contains("AES-128"), "\(name) 应该全片无 AES")
        let result = try #require(AdPrefix.strip(text, origin: origin), "\(name) 没识别出广告")
        // 留下的必须仍是绝大部分。
        #expect(bodySeconds(result.text) > bodySeconds(text) * 0.9,
                "\(name) 被切掉太多：留 \(bodySeconds(result.text))s / 原 \(bodySeconds(text))s")
    }
}

@Test func aPlaylistWithOneSingleSourceIsLeftAlone() throws {
    // 只有一组来源（正常单目录）→ 没有任何"外来组"，必须原样放行。
    let text = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:8
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXT-X-KEY:METHOD=AES-128,URI="k"
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00000.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00001.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00002.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00003.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00004.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00005.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00006.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00007.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00008.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00009.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00010.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00011.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00012.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00013.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00014.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00015.ts
    #EXT-X-ENDLIST
    """
    #expect(AdPrefix.strip(text, origin: origin) == nil)
}

@Test func aLivePlaylistIsNeverTouched() throws {
    let text = try playlist("A").replacingOccurrences(of: "#EXT-X-ENDLIST", with: "")
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

@Test func aShortClipIsNotCut() throws {
    // 短片前几秒本来就是内容，不是广告。
    var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:8", "#EXT-X-PLAYLIST-TYPE:VOD"]
    for i in 0..<10 { lines += ["#EXTINF:4,", "https://b/y/seg_\(i).jpg"] }
    for i in 0..<3 { lines += ["#EXTINF:4,", "/other/z/ad_\(i).jpg"] }
    lines.append("#EXT-X-ENDLIST")
    #expect(AdPrefix.strip(lines.joined(separator: "\n"), origin: origin) == nil)
}

@Test func twoRoughlyEqualSourcesAreNotTreatedAsAdPlusFilm() throws {
    // 五五开说明这不是"一个主片 + 若干广告"，可能是多段正片 → 必须放行。
    var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:8", "#EXT-X-PLAYLIST-TYPE:VOD"]
    for i in 0..<30 { lines += ["#EXTINF:4,", "https://a/main/seg_\(i).jpg"] }
    for i in 0..<25 { lines += ["#EXTINF:4,", "/b/other/seg_\(i).jpg"] }
    lines.append("#EXT-X-ENDLIST")
    #expect(AdPrefix.strip(lines.joined(separator: "\n"), origin: origin) == nil)
}

@Test func midrollAdsAreDeliberatelyKeptBecauseCuttingThemLeavesATimelineHole() throws {
    // ⛔ 这是本模块最重要的一条回归，别把它改"绿"了。
    //
    //    实测（ffmpeg 9.0.2，本地构造 c1+广告+c2 的 HLS，见 ad-scan/gap/）：
    //      原样                     最大帧间隔 0.0400s
    //      删中插广告段             最大帧间隔 **4.0400s**  ← 等于广告长度的时间轴洞
    //      删中插 + DISCONTINUITY   仍 4.0400s            ← 该标签一秒都补不上
    //      删**开头**前缀           0.0400s              ← 没有洞
    //
    //    而且实测广告段是 1080p/1.1MB、正片段 720p/0.3MB，拼接点必然重建解码器。
    //    所以中插广告**只删前缀、不动中插**：宁可留广告，也不能让正片卡顿/跳帧。
    let text = try playlist("A")
    let result = try #require(AdPrefix.strip(text, origin: origin))

    // 中插的广告目录必须还在清单里。
    #expect(result.text.contains("625264b24905f8e9"),
            "中插广告的分片被删掉了 —— 这会在时间轴上留洞，正片会卡")
    // 并且要在结果里如实报告"还剩多少处中插没处理"。
    #expect(result.keptMidrolls > 0, "应如实报告未处理的中插数量，实际 \(result.keptMidrolls)")
}

@Test func aPlaylistWhoseAdIsOnlyAtTheHeadRemovesExactlyThatHead() throws {
    // 玉兔没有中插：删完前缀后，清单里不该再有任何广告目录。
    let text = try playlist("Y2")
    let result = try #require(AdPrefix.strip(text, origin: origin))
    #expect(!result.text.contains("5jnnmlLG"), "玉兔的广告前缀应被完整删除")
    #expect(result.keptMidrolls == 0, "玉兔没有中插，不该报告残留，实际 \(result.keptMidrolls)")
}

@Test func theFirstSegmentAfterStrippingIsAFilmSegment() throws {
    // 删完之后第一段必须是正片目录的分片 —— 否则等于把正片开头也吃了。
    for name in ["A", "X1", "Y2", "Z2"] {
        let text = try playlist(name)
        let result = try #require(AdPrefix.strip(text, origin: origin), "\(name) 未识别")
        let firstSegment = result.text.components(separatedBy: "\n")
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
        let first = try #require(firstSegment, "\(name) 删完没有段了")
        // 广告目录的特征串不许出现在第一段里。
        for ad in ["seg_k8bord", "625264b24905f8e9", "5jnnmlLG", "RCP0FQBQ"] {
            #expect(!first.contains(ad), "\(name) 删完后第一段仍是广告（\(ad)）")
        }
    }
}
