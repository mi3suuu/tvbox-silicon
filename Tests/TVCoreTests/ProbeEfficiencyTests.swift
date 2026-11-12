import Foundation
import Testing
@testable import TVCore

/// 探测的准确度与成本。
///
/// 这里的断言对着的都是**实测出来的偏差**，不是设计意见：
///   · 27 个同时带画质与速度的源里 7 个标称画质撑不住自己的速度（26%）
///   · 慢启动对 256 KB 采样的低估是等比例的（约 43%），所以它不改排序，
///     但会让高速源撞上同一堵假天花板

private func probe(height: Int? = nil, speed: Int? = nil, reach: SourceProbeResult.Reachability = .reachable,
                   conflicted: Bool = false) -> SourceProbeResult {
    SourceProbeResult(reachability: reach, latencyMilliseconds: 100, kilobytesPerSecond: speed,
                      resolutionHeight: height, resolutionLabel: nil, measuredAt: Date(),
                      declaredConflicted: conflicted)
}

// MARK: - 有效画质

/// 实测反例：「乐播 1080P」测得 62.4 KB/s —— 连 480p 的码率都不够。
/// 按标称给满分等于奖励虚标。
@Test func aSourceCannotClaimMoreQualityThanItsSpeedSupports() {
    let overclaiming = probe(height: 1080, speed: 62)
    // 62 KB/s 连 480p 的 150 KB/s 门槛都不到 → 只能认 360p。
    #expect(overclaiming.effectiveResolutionHeight == 360)
    #expect(overclaiming.claimsMoreThanItCanDeliver)
}

@Test func aGenuinelyFast1080pSourceKeepsItsHeight() {
    let honest = probe(height: 1080, speed: 900)
    #expect(honest.effectiveResolutionHeight == 1080)
    #expect(!honest.claimsMoreThanItCanDeliver)
}

/// 速度够 720p 但不够 1080p：声明 1080p 应当被压到 720p。
@Test func aMidSpeedSourceIsCappedAtItsRealTier() {
    // 门槛：480p→150、720p→375、1080p→750、2160p→3000 KB/s
    #expect(probe(height: 1080, speed: 500).effectiveResolutionHeight == 720)   // 375..<750
    #expect(probe(height: 1080, speed: 250).effectiveResolutionHeight == 480)   // 150..<375
    #expect(probe(height: 1080, speed: 900).effectiveResolutionHeight == 1080)  // 750..<3000
    #expect(probe(height: 2160, speed: 3_200).effectiveResolutionHeight == 2160) // 3000+
}

/// 声明低于能力时按声明走 —— 不因为网快就把 480p 的源吹成 1080p。
@Test func aSourceDeclaringLessThanItCanDeliverIsNotInflated() {
    #expect(probe(height: 480, speed: 2000).effectiveResolutionHeight == 480)
}

/// 没有速度读数：只能信声明（那是唯一的信息）。
@Test func withoutASpeedReadingTheDeclarationIsAllThereIs() {
    #expect(probe(height: 1080, speed: nil).effectiveResolutionHeight == 1080)
    // 但矛盾读数的速度被丢弃了，同样只能信声明。
    #expect(probe(height: 1080, speed: nil, conflicted: true).effectiveResolutionHeight == 1080)
}

/// 没声明画质就不猜 —— 不用速度反推一个数冒充测量。
@Test func anUndeclaredHeightIsNeverInferredFromSpeed() {
    #expect(probe(height: nil, speed: 2000).effectiveResolutionHeight == nil)
}

/// 不可达的源不谈画质。
@Test func anUnreachableSourceHasNoEffectiveHeight() {
    #expect(probe(height: 1080, speed: 2000, reach: .unreachable).effectiveResolutionHeight == nil)
}

/// 有效画质必须真的改变排序：虚标的 1080p 不能压过诚实的 720p。
@Test func anOverclaimingSourceRanksBelowAnHonestOne() {
    let liar = probe(height: 1080, speed: 62)     // 撑不住 → 有效 360p
    let honest = probe(height: 720, speed: 500)   // 撑得住 → 有效 720p
    #expect(honest.sortScore > liar.sortScore)
}

// MARK: - 两阶段调度

/// 阶段 1 的并发必须显著高于阶段 2，否则拆分没有意义。
@Test func screeningIsWiderThanMeasuring() {
    let schedule = ProbeSchedule.standard
    #expect(schedule.screenWidth > schedule.measureWidth)
    #expect(schedule.screenWidth >= 8)
}

/// 筛的门槛必须比细测超时短：先便宜地判掉，再花大钱。
@Test func theScreenDeadlineIsTighterThanTheScreenTimeout() {
    let schedule = ProbeSchedule.standard
    #expect(schedule.screenDeadline < schedule.screenTimeout)
}

/// 估算要偏向「说清代价」，不能乐观到骗用户。
@Test func theEstimateScalesWithSourcesAndPassRate() {
    let schedule = ProbeSchedule.standard
    let all = schedule.estimate(sources: 100, linesPerSource: 4, passRate: 1.0)
    let half = schedule.estimate(sources: 100, linesPerSource: 4, passRate: 0.5)
    #expect(all.passedSources == 100)
    #expect(half.passedSources == 50)
    #expect(all.measureBytes > half.measureBytes)
    #expect(all.screenedRequests == 100)
}

/// 通过率越界要夹住，不能算出负数或超过源数。
@Test func anOutOfRangePassRateIsClamped() {
    let schedule = ProbeSchedule.standard
    #expect(schedule.estimate(sources: 10, passRate: -1).passedSources == 0)
    #expect(schedule.estimate(sources: 10, passRate: 5).passedSources == 10)
}

// MARK: - 深测开关

/// 深测必须比常规采样大得多，否则测不出高速源的真本事。
@Test func deepSamplingPullsMuchMoreThanTheDefault() {
    #expect(SourceProbeRunner.deepSampleBytes >= SourceProbeRunner.sampleBytes * 4)
}

/// 慢启动区必须小于常规采样，否则一次常规探测根本走不完预热，永远拿不到稳态。
@Test func theWarmupFitsInsideTheDefaultSample() {
    #expect(SourceProbeRunner.warmupBytes < SourceProbeRunner.sampleBytes)
    // 且要留足够多的稳态字节，否则稳态区太短、噪声大。
    #expect(SourceProbeRunner.sampleBytes - SourceProbeRunner.warmupBytes >= 96 * 1024)
}
