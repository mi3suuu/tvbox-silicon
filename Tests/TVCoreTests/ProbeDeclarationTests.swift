import Foundation
import Testing
@testable import TVCore

// MARK: - 探针采集四项（分辨率 / 码率 / 色域 / 文件大小）

/// 一次把 m3u8 主列表里的三个声明量都读到 —— 这是「采集能力补齐」的核心。
///
/// 修复前只读 `RESOLUTION`，码率与色域明明在同一段文本里却被丢掉，
/// 于是资源排序里按码率/色彩范围排的两项**永远没有数据**（`speedTestProvides` 恒 false）。
@Test func oneePassReadsResolutionBitrateAndColourRange() {
    let head = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=5200000,AVERAGE-BANDWIDTH=4800000,RESOLUTION=1920x1080,VIDEO-RANGE=PQ,CODECS="hvc1.1.6.L120"
    video.m3u8
    """
    let d = SourceProbeRunner.declaration(in: head, url: URL(string: "https://a/b.m3u8")!)
    #expect(d.height == 1080)
    #expect(d.bitrateKbps == 5200, "BANDWIDTH 是 bit/s，5000 → 5200 kbps")
    #expect(d.colourRange == "PQ")
}

/// 没有 `BANDWIDTH` 时退回 `AVERAGE-BANDWIDTH`。
@Test func averageBandwidthIsTheFallback() {
    let head = "#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=3000000,RESOLUTION=1280x720\nv.m3u8"
    let d = SourceProbeRunner.declaration(in: head, url: URL(string: "https://a/b.m3u8")!)
    #expect(d.height == 720)
    #expect(d.bitrateKbps == 3000)
}

/// 什么都没写时四个量都是 nil —— **不编造**。
@Test func anEmptyPlaylistDeclaresNothing() {
    let d = SourceProbeRunner.declaration(in: "#EXTM3U\n", url: URL(string: "https://a/clip.mp4")!)
    #expect(d.height == nil)
    #expect(d.bitrateKbps == nil)
    #expect(d.colourRange == nil)
}

/// 非标准色域值不认 —— 只有 SDR/HLG/PQ 是 m3u8 规范里存在的。
@Test func anUnknownColourRangeIsDropped() {
    let head = "#EXT-X-STREAM-INF:RESOLUTION=1920x1080,VIDEO-RANGE=DOLBY\nv.m3u8"
    let d = SourceProbeRunner.declaration(in: head, url: URL(string: "https://a/b.m3u8")!)
    #expect(d.colourRange == nil)
}

/// 文件名兜底仍然有效（没有 m3u8 头的老式直链）。
@Test func theFileNameStillSuppliesTheHeight() {
    let d = SourceProbeRunner.declaration(in: "", url: URL(string: "https://a/movie.1080p.mp4")!)
    #expect(d.height == 1080)
}

/// 文件总长只认 `Content-Range` 的总分母。
///
/// ⛔ 分片响应的 `Content-Length` 报的是**这一片**（我们只要 256 KB 它就报 256 KB），
/// 拿它当文件大小会把每个源都记成 256 KB。
@Test func fileSizeComesFromContentRangeNotContentLength() {
    let url = URL(string: "https://a/x.mp4")!
    let ranged = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
                                 headerFields: ["Content-Range": "bytes 0-262143/734003200",
                                                "Content-Length": "262144"])!
    #expect(SourceProbeRunner.totalBytes(from: ranged) == 734_003_200)

    // 206 且没有 Content-Range：拿不到总长，就 return nil，不要拿分片长度冒充。
    let partial = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
                                  headerFields: ["Content-Length": "262144"])!
    #expect(SourceProbeRunner.totalBytes(from: partial) == nil)

    // 200 = 服务端忽略了 Range，此时 Content-Length 才是完整长度。
    let whole = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                headerFields: ["Content-Length": "1048576"])!
    #expect(SourceProbeRunner.totalBytes(from: whole) == 1_048_576)
}

// MARK: - 四项都参与排序

/// 码率余量（实测吞吐 ÷ 声明码率）要真的影响分数。
///
/// 同一个速度下，声明码率高的源得分更低 —— 因为它更喂不饱。
@Test func aStreamThatOutrunsItsBitrateScoresLower() {
    let lowDemand = SourceProbeResult(reachability: .reachable, latencyMilliseconds: 100,
                                      kilobytesPerSecond: 1_000, resolutionHeight: 1080,
                                      declaredBitrateKbps: 2_000, measuredAt: Date())
    let highDemand = SourceProbeResult(reachability: .reachable, latencyMilliseconds: 100,
                                       kilobytesPerSecond: 1_000, resolutionHeight: 1080,
                                       declaredBitrateKbps: 20_000, measuredAt: Date())
    #expect(lowDemand.sortScore > highDemand.sortScore,
            "8 Mbps 实测喂 2 Mbps 需求，应高于喂 20 Mbps 需求：\(lowDemand.sortScore) vs \(highDemand.sortScore)")
}

/// HDR 有加分，但只加一点点 —— 不能压过可达性或速度。
@Test func hdrIsASmallTiebreakerNotAThreshold() {
    let sdr = SourceProbeResult(reachability: .reachable, latencyMilliseconds: 100,
                                kilobytesPerSecond: 1_000, resolutionHeight: 1080,
                                measuredAt: Date())
    var hdr = sdr
    hdr.colourRange = "PQ"
    #expect(hdr.sortScore > sdr.sortScore)
    #expect(hdr.sortScore - sdr.sortScore <= 5, "HDR 加分应 ≤5，实测 \(hdr.sortScore - sdr.sortScore)")
}

/// 小文件轻加分；大文件**不扣分**（大片天然大）。
@Test func aLargeFileIsNotPenalised() {
    let small = SourceProbeResult(reachability: .reachable, latencyMilliseconds: 100,
                                  kilobytesPerSecond: 1_000, resolutionHeight: 1080,
                                  fileSizeBytes: 500_000_000, measuredAt: Date())
    let large = SourceProbeResult(reachability: .reachable, latencyMilliseconds: 100,
                                  kilobytesPerSecond: 1_000, resolutionHeight: 1080,
                                  fileSizeBytes: 20_000_000_000, measuredAt: Date())
    #expect(small.sortScore >= large.sortScore, "小文件不应低于大文件")
    #expect(large.sortScore >= small.sortScore - 5, "大文件最多少 5 分，不该被重罚")
}

/// 四项都能采了 —— 设置页不再有三项是空开关。
@Test func everyRankingAttributeIsNowMeasurable() {
    for attribute in ResourceRanking.Key.Attribute.allCases {
        #expect(attribute.speedTestProvides,
                "\(attribute.rawValue) 应可由探针提供")
    }
}

// MARK: - 并行审查（子代理）抓到的两个数据层 bug

/// 旧存档必须还能解码。
///
/// `declaredConflicted` 曾被我加成**非 Optional** 存储属性。Swift 合成的 `init(from:)`
/// 要求非 Optional 键必须存在（**属性默认值不参与解码**），于是旧 JSON 抛
/// `keyNotFound` → `SourceProbeStore` 用 `try?` 吞掉 → probes/health 双双变 `[:]`
/// → 下一次 record() 的 persist() 把空表写回 → **老用户全部测速读数永久丢失**。
@Test func anOlderArchiveWithoutTheNewKeyStillDecodes() throws {
    // 模拟「新增字段之前」存下来的 JSON：只有原有字段
    let json = """
    {"reachability":"reachable","latencyMilliseconds":120,"kilobytesPerSecond":900,
     "resolutionHeight":1080,"resolutionLabel":"1080P","measuredAt":760000000}
    """
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(SourceProbeResult.self, from: Data(json.utf8))
    #expect(decoded.resolutionHeight == 1080)
    #expect(decoded.kilobytesPerSecond == 900)
    #expect(decoded.declaredConflicted == nil, "缺键时必须是 nil 而不是解码失败")
    // 新增的三项也应是 nil，不报错
    #expect(decoded.declaredBitrateKbps == nil)
    #expect(decoded.fileSizeBytes == nil)
    #expect(decoded.colourRange == nil)
}

/// `Candidate(probe)` 必须把码率/大小/HDR 真正接上 —— 否则设置页那三个开关是「能选但没变化」。
///
/// 原来 `bitrateBitsPerSecond = nil` 硬写、另两项取调用方默认 nil；
/// 唯一的生产调用点是 `Candidate(reading)`，于是三个字段全是 nil，
/// 排序等价于只按分辨率，与修复前那三个空开关是同一个病。
@Test func aCandidateCarriesEveryMeasuredAttribute() {
    let probe = SourceProbeResult(reachability: .reachable, latencyMilliseconds: 100,
                                  kilobytesPerSecond: 1_000, resolutionHeight: 1080,
                                  declaredBitrateKbps: 5_000, fileSizeBytes: 800_000_000,
                                  colourRange: "PQ", measuredAt: Date())
    let candidate = ResourceRanking.Candidate(probe)
    #expect(candidate.bitrateBitsPerSecond == 5_000_000, "码率应取声明的 5000kbps = 5e6 bit/s")
    #expect(candidate.fileSizeBytes == 800_000_000)
    #expect(candidate.isHDR == true)
}

// MARK: - 多档主列表：取最高档，不是第一条

/// 一个 master playlist 常带多档变体，顺序通常是「低 → 高」。
///
/// 旧实现用 `range(of:)` 只匹配**第一个** `RESOLUTION=`，于是把 360P 当成
/// 「这一源的画质」—— 分辨率段 0 分（应 20），而码率余量却被小数字放大拿满，
/// **两个方向同时错且相反**。
@Test func aMultiVariantPlaylistReportsItsBestQuality() {
    let head = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,VIDEO-RANGE=SDR
    low.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,VIDEO-RANGE=SDR
    mid.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=5200000,RESOLUTION=1920x1080,VIDEO-RANGE=PQ
    high.m3u8
    """
    let d = SourceProbeRunner.declaration(in: head, url: URL(string: "https://a/master.m3u8")!)
    #expect(d.height == 1080, "应取最高档 1080，实际 \(d.height ?? -1)")
    #expect(d.bitrateKbps == 5200, "码率应与最高档同源 5200 kbps，实际 \(d.bitrateKbps ?? -1)")
}

/// 顺序反过来（高 → 低）也必须取最高档 —— 不能靠「恰好第一条就是最高」。
@Test func variantOrderDoesNotMatter() {
    let head = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=5200000,RESOLUTION=1920x1080
    high.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
    low.m3u8
    """
    let d = SourceProbeRunner.declaration(in: head, url: URL(string: "https://a/master.m3u8")!)
    #expect(d.height == 1080)
    #expect(d.bitrateKbps == 5200)
}

/// 单档播放列表不受影响（回归保护）。
@Test func aSingleVariantPlaylistIsUnchanged() {
    let head = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720\nv.m3u8"
    let d = SourceProbeRunner.declaration(in: head, url: URL(string: "https://a/b.m3u8")!)
    #expect(d.height == 720)
    #expect(d.bitrateKbps == 3000)
}
