import Foundation
import Testing
@testable import TVCore

/// Pins the three mechanisms that made the play page slow on entry, each measured against the
/// shipped One 1.7.1 behaviour they were copied from.
///
/// The symptom was: opening a title, the video took much longer to start, and the page itself
/// stuttered. The cause was not one bug but a set of them, all of the same shape — the line probe
/// competing with playback for something playback needs. These tests hold each fix in place, so a
/// future change cannot quietly hand the resource back to the probe.
@Suite struct ProbeIsolationTests {

    @MainActor
    private func store() -> SourceProbeStore {
        SourceProbeStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    // MARK: - A reading belongs to a host, not to a video

    /// One keeps `latencyByBase: [String: Int]` — a reading is filed under the line's host, with no
    /// video dimension at all. Ours was filed under `sourceKey|videoID|lineFlag`, so **every new
    /// title missed the cache** and re-measured all its lines. That is the "slow on entry" the
    /// viewer feels most often: not one slow probe, but a fresh sweep per title.
    @MainActor
    @Test func aReadingIsReusedByAnotherTitleOnTheSameHost() throws {
        let probes = store()
        let now = Date()
        let url = try #require(URL(string: "https://cdn.example.com/a/b/index.m3u8"))

        probes.record(SourceProbeResult(reachability: .reachable, latencyMilliseconds: 120, measuredAt: now),
                      sourceKey: "alpha", videoID: "title-1", lineFlag: "线路1", url: url)

        // A different title, a different source key, a different line name: same host, same answer.
        let reused = try #require(probes.baseReading(for: url))
        #expect(reused.latencyMilliseconds == 120)

        // The per-video detail table still answers only for the title it was measured on.
        #expect(probes.probe(sourceKey: "alpha", videoID: "title-1", lineFlag: "线路1") != nil)
        #expect(probes.probe(sourceKey: "alpha", videoID: "title-2", lineFlag: "线路1") == nil)
    }

    /// A stale reading on a host is not reused: a CDN that went bad an hour ago must be measured
    /// again rather than trusted because some other title measured it once.
    @MainActor
    @Test func aStaleHostReadingIsNotReused() throws {
        let probes = store()
        let url = try #require(URL(string: "https://cdn.example.com/x.m3u8"))
        probes.record(SourceProbeResult(reachability: .reachable,
                                        measuredAt: Date().addingTimeInterval(-sourceProbeStaleness - 60)),
                      sourceKey: "alpha", videoID: "title-1", lineFlag: "l", url: url)
        #expect(probes.baseReading(for: url) == nil)
    }

    /// A different host is a different line, whatever the source key says.
    @MainActor
    @Test func aReadingDoesNotLeakToAnotherHost() throws {
        let probes = store()
        let measured = try #require(URL(string: "https://cdn-a.example.com/v.m3u8"))
        let other = try #require(URL(string: "https://cdn-b.example.com/v.m3u8"))
        probes.record(SourceProbeResult(reachability: .reachable, measuredAt: Date()),
                      sourceKey: "alpha", videoID: "t", lineFlag: "l", url: measured)
        #expect(probes.baseReading(for: measured) != nil)
        #expect(probes.baseReading(for: other) == nil)
    }

    // MARK: - A global ceiling on probes in flight

    /// One keeps `PlayLines.pendingTests` for exactly this: one counter, one ceiling, whatever the
    /// caller. Four separate entry points (play page, episode sheet, cross-source matrix, full
    /// sweep) each had their own private width, so their sum — not their individual numbers — was
    /// what the viewer's link had to carry, at the moment playback needed it.
    @MainActor
    @Test func theGlobalProbeCeilingHoldsAndReleases() {
        let probes = store()
        var claimed = 0
        while probes.claimProbeSlot() { claimed += 1 }
        #expect(claimed == SourceProbeStore.maxGlobalProbes)
        #expect(probes.inflightProbes == SourceProbeStore.maxGlobalProbes)

        // Released slots come back, and the ceiling is still the ceiling.
        probes.releaseProbeSlot()
        #expect(probes.inflightProbes == SourceProbeStore.maxGlobalProbes - 1)
        #expect(probes.claimProbeSlot())
        #expect(!probes.claimProbeSlot())
    }

    /// Releasing more than was claimed must not push the counter negative: a negative count would
    /// let the next caller skip the check and hand out more slots than the ceiling allows.
    @MainActor
    @Test func releasingWithoutClaimingDoesNotGoNegative() {
        let probes = store()
        probes.releaseProbeSlot()
        #expect(probes.inflightProbes == 0)
    }

    // MARK: - A new round invalidates the old one

    /// One's `PlayLines.generation` exists so that a reading from an abandoned round cannot land in
    /// the new one's UI. Opening a second title while the first is still resolving used to run both
    /// rounds at once, doubling the load at the worst moment.
    @MainActor
    @Test func startingANewRoundInvalidatesTheOldOne() {
        let probes = store()
        let first = probes.beginProbeGeneration()
        #expect(probes.isCurrentGeneration(first))

        let second = probes.beginProbeGeneration()
        #expect(second > first)
        #expect(!probes.isCurrentGeneration(first))
        #expect(probes.isCurrentGeneration(second))
    }

    // MARK: - The probe session is not the player's session

    /// Both URLSession instances get their own connection pool, so the probe genuinely cannot hold
    /// a connection the player is waiting for. This pins the separation itself rather than the
    /// numbers on the probe session: what matters is that they are two different sessions.
    @Test func theProbeSessionIsNotTheSharedSession() {
        #expect(SourceProbeRunner.probeSession !== URLSession.shared)
        // The probe session is ephemeral: a Range probe's bytes are never worth keeping on disk.
        #expect(SourceProbeRunner.probeSession.configuration.urlCache == nil)
    }

    /// A light probe pulls half of a full one. The play page and the episode sheet now use it while
    /// the viewer is still choosing, so four lines cost 512 KB instead of 1 MB.
    @Test func aLightProbePullsLessThanAFullOne() {
        #expect(SourceProbeRunner.lightSampleBytes < SourceProbeRunner.sampleBytes)
        #expect(SourceProbeRunner.sampleBytes < SourceProbeRunner.deepSampleBytes)
    }

    /// The warm-up boundary must leave room for a steady-state window at every budget.
    ///
    /// The boundary used to be a fixed 96 KB while `lightSampleBytes` is 128 KB, leaving 32 KB of
    /// "steady" window — small enough that RTT jitter dominates and one host's two readings can
    /// differ twofold. That turns the speed numbers in the line menu into noise, which is worse than
    /// no numbers: the picker's whole point is comparing lines.
    ///
    /// The boundary is `min(warmupBytes, max(budget / 2, 16 KiB))`, so:
    ///   · the full 256 KB probe keeps 96 KB (unchanged — existing readings stay comparable);
    ///   · the 128 KB light probe gets 64 KB, leaving exactly half as steady window.
    @Test func theWarmupBoundaryAlwaysLeavesASteadyWindow() {
        func boundary(_ budget: Int) -> Int { min(SourceProbeRunner.warmupBytes, max(budget / 2, 16 * 1024)) }

        // The full probe is untouched: this is what keeps old readings comparable.
        #expect(boundary(SourceProbeRunner.sampleBytes) == SourceProbeRunner.warmupBytes)
        // Every budget leaves at least half of itself for the steady window.
        for budget in [SourceProbeRunner.lightSampleBytes, SourceProbeRunner.sampleBytes, SourceProbeRunner.deepSampleBytes] {
            let steady = budget - boundary(budget)
            #expect(steady >= budget / 2, "budget \(budget) leaves only \(steady) steady bytes")
        }
    }
}

/// 包内标签不许覆盖这台设备量到的结论。
///
/// 旧实现只比时间戳，而导入层给包内读数打的是「此刻」—— 于是每次刷新订阅都会把用户
/// 昨天真测的 `unreachable` 按时间压回「直连」。来源比时间可靠：不是这台设备量的，
/// 就没有资格覆盖这台设备量到的。
@MainActor
@Test func anImportedLabelNeverOverwritesAReadingTakenHere() {
    let probes = SourceProbeStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    let measured = SourceProbeResult(reachability: .unreachable, measuredAt: Date())
    probes.record(measured, sourceKey: "alpha", videoID: "v1", lineFlag: "线路1")

    // 包说它好得很 —— 而且日期比自测新（模拟「此刻打戳」那种写法）。
    let label = SourceProbeResult(reachability: .reachable, kilobytesPerSecond: 900,
                                 measuredAt: Date().addingTimeInterval(60), declared: true)
    #expect(probes.importReadings(["alpha": label]) == 0)
    #expect(probes.latest(sourceKey: "alpha")?.reachability == .unreachable)
}

/// 反过来：只有包标签时，更新的那份包才替换旧的；同一份重复导入不算「写入」。
@MainActor
@Test func reimportingTheSameLabelIsANoOp() {
    let probes = SourceProbeStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    let day = Date(timeIntervalSince1970: 1_700_000_000)
    let older = SourceProbeResult(reachability: .reachable, kilobytesPerSecond: 400,
                                 measuredAt: day, declared: true)
    #expect(probes.importReadings(["beta": older]) == 1)
    // 同一份再导一次：没有变化，就不该重写整张表（否则每次启动都要编码一遍）。
    #expect(probes.importReadings(["beta": older]) == 0)

    let newer = SourceProbeResult(reachability: .slow, kilobytesPerSecond: 120,
                                 measuredAt: day.addingTimeInterval(86_400), declared: true)
    #expect(probes.importReadings(["beta": newer]) == 1)
    #expect(probes.latest(sourceKey: "beta")?.kilobytesPerSecond == 120)
}
