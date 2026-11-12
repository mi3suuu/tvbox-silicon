import Foundation
import Testing
@testable import TVCore

/// 源排序分数与读数可信度。
///
/// 这些断言针对的都是**可算的失衡**，不是口味问题：旧实现里
/// 「720p→1080p」只值 360 分，而「1 KB/s」值 10 分，于是速度高 36 KB/s
/// 就能盖过整个分辨率档位。测试把新权重的边界钉住，防止有人再调回去。

private func probe(reach: SourceProbeResult.Reachability = .reachable, height: Int? = nil, speed: Int? = nil, latency: Int? = nil, conflicted: Bool = false) -> SourceProbeResult {
    SourceProbeResult(reachability: reach, latencyMilliseconds: latency, kilobytesPerSecond: speed,
                      resolutionHeight: height, resolutionLabel: nil, measuredAt: Date(),
                      declaredConflicted: conflicted)
}

// MARK: - 权重

@Test func anUnreachableSourceScoresZeroWhateverElseItSays() {
    // 不可达是门槛不是加分项：哪怕它声称 2160p、8 MB/s。
    #expect(probe(reach: .unreachable, height: 2160, speed: 8000, latency: 10).sortScore == 0)
}

@Test func resolutionAndSpeedAreInTheSameLeague() {
    // 旧实现的失衡：720p→1080p 只值 360 分，而 1 KB/s 值 10 分，
    // 于是速度高 36 KB/s 就抹平整个分辨率档位 —— 分辨率形同虚设。
    //
    // 现在分辨率是独立的一段（0–20），速度满分 30 需要 512 KB/s。
    // 「1080p / 300 KB/s」与「480p / 512 KB/s」的总分差必须落在同一量级，
    // 而不是旧实现那种「速度随便高一点就盖过画质」。
    let sharp = probe(height: 1080, speed: 300, latency: 200)
    let fast = probe(height: 480, speed: 512, latency: 200)
    #expect(abs(sharp.sortScore - fast.sortScore) <= 30)
    // 且两者都明显高于「480p + 64 KB/s」这种真的差的源。
    let poor = probe(height: 480, speed: 64, latency: 1_200)
    #expect(sharp.sortScore > poor.sortScore)
    #expect(fast.sortScore > poor.sortScore)
}

@Test func aFasterSourceOutranksASlowerOneAtTheSameQuality() {
    let fast = probe(height: 1080, speed: 512, latency: 100)
    let slow = probe(height: 1080, speed: 64, latency: 100)
    #expect(fast.sortScore > slow.sortScore)
}

@Test func speedSaturatesButResolutionDoesNotUntilItCanActuallyBeServed() {
    // ⛔ 这条断言原本写的是「512 KB/s 与 5 MB/s 同分」，在加入**有效画质**之后不再成立，
    // 而且不该成立：512 KB/s 只撑得住 720p（1080p 需 750 KB/s），
    // 5 MB/s 撑得住 1080p。两者分数不同是正确行为，不是回归。
    //
    // 速度**本身**仍然饱和：同为 720p 声明时，512 与 5000 的速度分相同。
    #expect(probe(height: 720, speed: 512, latency: 100).sortScore
            == probe(height: 720, speed: 5_000, latency: 100).sortScore)
    // 但当速度跨过有效画质的门槛时，总分应当更高 —— 那多出来的带宽确实换来了画面。
    #expect(probe(height: 1080, speed: 5_000, latency: 100).sortScore
            > probe(height: 1080, speed: 512, latency: 100).sortScore)
}

@Test func resolutionSaturatesAt1080p() {
    #expect(probe(height: 1080, speed: 512, latency: 100).sortScore
            == probe(height: 2160, speed: 512, latency: 100).sortScore)
}

@Test func lowLatencyScoresHigherAndIsCapped() {
    let quick = probe(height: 1080, speed: 512, latency: 50)
    let sluggish = probe(height: 1080, speed: 512, latency: 1_400)
    #expect(quick.sortScore > sluggish.sortScore)
    // ≤300 ms 都是满分，50 与 300 应当相同。
    #expect(probe(height: 1080, speed: 512, latency: 50).sortScore
            == probe(height: 1080, speed: 512, latency: 300).sortScore)
}

@Test func anUnknownReadingScoresBelowAReachableOne() {
    #expect(probe(reach: .reachable, height: 1080, speed: 512, latency: 100).sortScore
            > probe(reach: .unknown, height: 1080, speed: 512, latency: 100).sortScore)
}

// MARK: - 可信度

/// 外部导入的读数里两个速度字段互相矛盾（实测 38/38 不符），
/// 那种数字不能参与打分，只能信可达性。
@Test func aConflictedReadingIsNotTrustedForSpeedOrLatency() {
    let conflicted = probe(height: 1080, speed: 512, latency: 50, conflicted: true)
    let measured = probe(height: 1080, speed: 512, latency: 50)
    #expect(conflicted.confidence == .conflicted)
    #expect(measured.confidence == .measured)
    // 矛盾读数不吃速度与延迟那两段，所以分数更低。
    #expect(conflicted.sortScore < measured.sortScore)
    // 但分辨率与可达性照常算：它至少还是「能连、1080p」。
    #expect(conflicted.sortScore > 0)
}

@Test func aReadingWithoutSpeedIsPartial() {
    let onlyReachability = probe(height: 1080, speed: nil, latency: nil)
    #expect(onlyReachability.confidence == .partial)
    #expect(!onlyReachability.confidence.trustsSpeed)
}

@Test func aNeverMeasuredReadingIsAbsent() {
    #expect(SourceProbeResult.unknown.confidence == .absent)
}

@Test func ourOwnMeasurementIsAlwaysMeasured() {
    #expect(probe(height: 720, speed: 300, latency: 120).confidence == .measured)
}

@Test func anUnreachableReadingKeepsItsVerdictAtFullConfidence() {
    // 「连不上」是确定的事实，不该因为它没有速度就被降级成「部分」。
    #expect(probe(reach: .unreachable).confidence == .measured)
}

@Test func conflictedSortsBelowAnEquallySpeccedTrustedSource() {
    // 两个源规格完全一样，只有可信度不同：可信的那条必须在前。
    let trusted = probe(height: 1080, speed: 480, latency: 90)
    let suspect = probe(height: 1080, speed: 480, latency: 90, conflicted: true)
    let ranked = [suspect, trusted].sorted { $0.sortScore > $1.sortScore }
    #expect(ranked.first?.confidence == .measured)
}

// MARK: - 测速入口收敛（ProbePlanTarget）

@Test func aPlayParameterIsNotARequestableAddress() {
    // `URL(string:)` accepts these as *relative* URLs, which is how the old
    // `URL(string: $0.address) != nil` filter let every plugin source through to be measured at an
    // address that does not exist. Only an absolute http(s) URL may reach a URLRequest.
    #expect(!ProbePlanTarget.isRequestable("abc123"))
    #expect(!ProbePlanTarget.isRequestable("/play/123-1-1"))
    #expect(!ProbePlanTarget.isRequestable("第1集"))
    #expect(!ProbePlanTarget.isRequestable(""))
    #expect(ProbePlanTarget.isRequestable("https://cdn.example/x.m3u8"))
    #expect(ProbePlanTarget.isRequestable("http://cdn.example/x.mp4"))
    // A scheme without a host cannot be requested either.
    #expect(!ProbePlanTarget.isRequestable("file:///tmp/x.m3u8"))
}

@Test func theEmptyFlagIsNormalisedBeforeItReachesTheStore() {
    // `SourceProbeStore.record` silently drops an empty flag, while every page displays
    // `flag.isEmpty ? "default" : flag`. Two spellings of one line means its cache hit rate is zero
    // and nothing in the UI says so — so normalisation has to happen at the target, once.
    let url = URL(string: "https://cdn.example/x.m3u8")!
    #expect(ProbePlanTarget.direct(url: url, headers: [:], flag: "").flag == ProbePlanTarget.defaultFlag)
    #expect(ProbePlanTarget.direct(url: url, headers: [:], flag: "ffm3u8").flag == "ffm3u8")
}

// MARK: - 「多处测速是否同一套」的契约

/// 四个入口（设置页 / 点播源面板 / 选集页 / 播放页）必须对**同一条线路**给出同一个判定。
///
/// 这条测试钉的是判定的**门槛**而不是网络：三个字段（可达性、稳态吞吐、分辨率）来自同一个
/// `SourceProbeRunner.probe`，任何一处自己另算一套，用户就会在两个页面看到同一源的两个结论。
/// 真正容易分叉的不是算法，是**喂给它的东西**（地址是否已解析、要不要带请求头、写哪个缓存键），
/// 那三件事由 `ProbePlanTarget` 独占 —— 下面的断言用它的公开口径表达。
@Test func oneLineHasOneVerdictWhicheverPageAsks() {
    // 同一个读数，四处的「能播吗」必须一致：`isUsable` 是唯一的判据出口。
    let reachable = SourceProbeResult(reachability: .reachable, latencyMilliseconds: 120,
                                      kilobytesPerSecond: 2_400, resolutionHeight: 1080,
                                      measuredAt: Date())
    #expect(reachable.isUsable)
    // 慢但仍能用 —— 不能因为「慢」就在某一页被判死。
    let slow = SourceProbeResult(reachability: .slow, latencyMilliseconds: 900,
                                 kilobytesPerSecond: 180, resolutionHeight: 720, measuredAt: Date())
    #expect(slow.isUsable)
    // 不可达是唯一判死的一种。
    let dead = SourceProbeResult(reachability: .unreachable, measuredAt: Date())
    #expect(!dead.isUsable)
    // 「没测出来」既不算能用也不算死 —— 它必须能被和上面两种区分开。
    let unknown = SourceProbeResult(reachability: .unknown, measuredAt: Date())
    #expect(!unknown.isUsable)
    #expect(unknown.reachability != dead.reachability)
}

@Test func everyEntryPointAgreesOnWhatMayBeRequested() {
    // 四处都必须走同一个「这个地址能不能测」的判据，否则 type 3/4 源的 play 参数
    // 会在某一处被当成 URL 去 HEAD（`URL(string:)` 对它是非 nil 的），把好线路测成死路。
    let playParameter = "第1集$abc123"
    let relativeAPI = "./FTY/drpy2.min.js"
    let realURL = "https://cdn.example/x.m3u8"
    for address in [playParameter, relativeAPI] {
        #expect(!ProbePlanTarget.isRequestable(address), "\(address) 不该被送去测")
        // 同时确认旧判据确实会放行它 —— 这正是当初分叉的成因。
        #expect(URL(string: address) != nil, "\(address) 的旧判据会误放行")
    }
    #expect(ProbePlanTarget.isRequestable(realURL))
}

@Test func virtualStreamAddressesAreMeasurableThroughTheirOwnReader() async {
    // 云盘 / 红果 / DASH 的播放地址是 App 内的虚拟流 scheme。它们**不是 HTTP**，
    // 但同样能测：探针会把它解析成字节流，用同一套两段计时量真实吞吐。
    //
    // 这条测试钉的是「不许按 scheme 拦」这件事本身：
    // 对这三类地址，`isRequestable` 为 false（它们没有 host、不是 http/https），
    // 所以任何在调用 `probe` 之前先问 `isRequestable` 的写法都会把它们永久判死。
    // 真实的吞吐量测不了（没有注册过的流），但「没注册」必须落成 `.unknown`（没测出来），
    // 而不是 `.unreachable`（判死）—— 判死会把能播的源分进「不通」。
    for scheme in ["tvbox-cloud", "tvbox-hongguo", "tvbox-dash"] {
        let url = URL(string: "\(scheme)://abc/video.mp4")!
        #expect(!ProbePlanTarget.isRequestable(url.absoluteString), "\(scheme) 本来就不是 HTTP")
        let result = await SourceProbeRunner.probe(url: url)
        #expect(result.reachability != .unreachable, "\(scheme) 未注册时不能判死")
    }
}
