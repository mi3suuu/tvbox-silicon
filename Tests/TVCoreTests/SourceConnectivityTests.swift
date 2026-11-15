import Foundation
import Testing
@testable import TVCore

/// 「这个源现在能不能用」的四档，以及按它分的书架。
@Suite struct SourceConnectivityTests {

    private func site(_ name: String, raw: [String: JSONValue] = [:]) -> Site {
        var raw = raw
        raw["key"] = .string(name)
        raw["name"] = .string(name)
        return Site(key: name, name: name, type: 3, api: "https://example.com/\(name)", raw: raw)
    }

    private func reading(_ reachability: SourceProbeResult.Reachability,
                         kbps: Int? = nil, height: Int? = nil,
                         at: Date = Date(timeIntervalSince1970: 1_700_000_000),
                         declared: Bool? = nil) -> SourceProbeResult {
        SourceProbeResult(reachability: reachability, kilobytesPerSecond: kbps,
                          resolutionHeight: height, measuredAt: at, declared: declared)
    }

    // MARK: 读数 → 档位

    @Test func aFastReadingIsPlayable() {
        #expect(SourceConnectivity.tier(of: reading(.reachable, kbps: 1200)) == .playable)
    }

    /// 300 KB/s 是**没有声明画质**时的门槛：它自己就是「能播」。
    @Test func theThresholdItselfIsPlayable() {
        #expect(SourceConnectivity.tier(of: reading(.reachable, kbps: 300)) == .playable)
        #expect(SourceConnectivity.tier(of: reading(.reachable, kbps: 299)) == .slow)
    }

    /// 门槛跟着画质走，而不是一刀切 300。
    ///
    /// 反例来自随包数据：`👭播剧影视👭` 实测 495 KB/s、自报 1080P —— 495 KB/s ≈ 4 Mbps，
    /// 刚好是一部 1080P 剧的码率，没有余量，打开必然转圈。按 300 的门槛它算「能播」，
    /// 按 1080P 的 750 它算「偏慢」。后者才是这台设备上的实际观感。
    @Test func theThresholdScalesWithDeclaredQuality() {
        #expect(SourceConnectivity.requiredSpeed(for: nil) == 300)
        #expect(SourceConnectivity.requiredSpeed(for: 480) == 150)
        #expect(SourceConnectivity.requiredSpeed(for: 720) == 375)
        #expect(SourceConnectivity.requiredSpeed(for: 1080) == 750)
        #expect(SourceConnectivity.requiredSpeed(for: 2160) == 3_000)
        // 同一份速度、不同画质 → 不同结论。
        #expect(SourceConnectivity.tier(of: reading(.reachable, kbps: 495, height: 1080)) == .slow)
        #expect(SourceConnectivity.tier(of: reading(.reachable, kbps: 495, height: 720)) == .playable)
        // 4K 组不再被 720P 的底线放过。
        #expect(SourceConnectivity.tier(of: reading(.reachable, kbps: 800, height: 2160)) == .slow)
    }

    @Test func aSilentReadingIsDead() {
        #expect(SourceConnectivity.tier(of: reading(.unreachable)) == .dead)
    }

    /// 连上了但只拿到握手、没有吞吐：不是「不通」，是「会转圈」。
    @Test func reachableWithoutThroughputIsSlowNotPlayable() {
        // 曾经判成 `.playable`（「能连上就能看」）。实测反例：只拿到握手、一个字节正文都
        // 没读到的源，播放器打开是黑屏。`SourceTier.slow` 的定义本来就写着这种情形。
        #expect(SourceConnectivity.tier(of: reading(.reachable)) == .slow)
        // 而「不知道」且没有数字，就是没有结论。
        #expect(SourceConnectivity.tier(of: reading(.unknown)) == .untested)
    }

    // MARK: 读数过期

    /// 三周前测死的源不能永远算「不通」—— 只看能播据此会把它永久藏起来。
    @Test func anOldReadingStopsBeingEvidence() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = reading(.unreachable, at: now.addingTimeInterval(-60 * 60))
        let old = reading(.unreachable, at: now.addingTimeInterval(-21 * 24 * 60 * 60))
        #expect(SourceConnectivity.tier(of: fresh) == .dead)
        #expect(fresh.isExpired(now: now) == false)
        #expect(old.isExpired(now: now))
        // 过期之后不再当证据，回落到源定义上的结论（这里没有，所以是「未测」）。
        #expect(SourceConnectivity.tier(of: site("a"), reading: old, now: now) == .untested)
    }

    /// 看不出日期的包内结论**不得**判过期。
    ///
    /// 旧包里大量源只有 `_route: "直连"` / `_probe.verdict`，没有 `at` / `_note` 日期。
    /// 如果「拿不到日期」被当成「很旧」，老用户一升级就会看到整页「未测」（徽标全灭、
    /// 「只看能播」清空）—— 那不是诚实，是把一个数据缺口变成一次显然的错误结论。
    @Test func anUndatedDeclaredVerdictNeverExpires() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // 只有 verdict、没有任何日期字段。
        let undated = site("u", raw: ["_probe": .object(["verdict": .string("direct")])])
        #expect(SourceConnectivity.declaredTier(of: undated, now: now) == .playable)

        // 对照：同样内容 + 一个很旧的日期 ⇒ 过期后回落到「未测」。
        let dated = site("d", raw: ["_probe": .object(["verdict": .string("direct"),
                                                      "at": .string("2020-01-01")])])
        #expect(SourceConnectivity.declaredTier(of: dated, now: now) == .untested)
    }

    /// 包内读数比自测宽：它是打包那天的实测行，且随每次发版刷新。
    @Test func declaredReadingsLiveLongerThanMeasuredOnes() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tenDaysAgo = now.addingTimeInterval(-10 * 24 * 60 * 60)
        #expect(reading(.reachable, kbps: 900, at: tenDaysAgo).isExpired(now: now))
        #expect(reading(.reachable, kbps: 900, at: tenDaysAgo, declared: true).isExpired(now: now) == false)
    }

    /// 包标签没有速度时，结论仍由 `declaredTier` 给 —— 不能拿「直连」这个路由标签当吞吐证据。
    @Test func aDeclaredLabelWithoutSpeedDefersToTheRouteVerdict() {
        let direct = site("direct", raw: ["_route": .string("直连")])
        let label = reading(.reachable, at: Date(), declared: true)
        #expect(SourceConnectivity.tier(of: direct, reading: label) == .playable)
        let dead = site("dead", raw: ["_route": .string("失效")])
        #expect(SourceConnectivity.tier(of: dead, reading: label) == .dead)
    }

    // MARK: 包内结论 → 档位

    @Test func theShippedVerdictCountsWhenNothingWasMeasuredHere() {
        let played = site("a", raw: ["_probe": .object(["verdict": .string("direct"), "kbps": .number(900)])])
        let silent = site("b", raw: ["_probe": .object(["verdict": .string("unreachable"), "kbps": .number(0)])])
        #expect(SourceConnectivity.tier(of: played, reading: nil) == .playable)
        #expect(SourceConnectivity.tier(of: silent, reading: nil) == .dead)
    }

    @Test func theOldRouteLabelIsTheLastResort() {
        #expect(SourceConnectivity.tier(of: site("direct", raw: ["_route": .string("直连")]), reading: nil) == .playable)
        #expect(SourceConnectivity.tier(of: site("dead", raw: ["_route": .string("失效")]), reading: nil) == .dead)
        #expect(SourceConnectivity.tier(of: site("waiting", raw: ["_route": .string("待测")]), reading: nil) == .untested)
        #expect(SourceConnectivity.tier(of: site("plain"), reading: nil) == .untested)
    }

    /// App 里刚测的读数优先于包里那条：包说它直连，刚才这台设备连不上，就是不通。
    ///
    /// 「刚」是前提：过期的读数不再当证据（见 `anOldReadingStopsBeingEvidence`），
    /// 那时包内结论重新说了算。
    @Test func aFreshReadingBeatsTheShippedVerdict() {
        let shipped = site("a", raw: ["_route": .string("直连")])
        #expect(SourceConnectivity.tier(of: shipped, reading: reading(.unreachable, at: Date())) == .dead)
    }

    // MARK: 分布与书架

    @Test func countsAddUp() {
        var counts = TierCounts()
        for tier in [SourceTier.playable, .playable, .slow, .untested, .dead, .dead, .dead] {
            counts.add(tier)
        }
        #expect(counts.total == 7)
        #expect(counts.playable == 2)
        #expect(counts.usable == 3)
        #expect(counts.measured == 6)
        #expect(counts[.dead] == 3)
    }

    @Test func shelvesGoPlayableSlowUntestedDead() {
        var sites: [Site] = []
        sites += (0..<4).map { site("dead\($0)") }
        sites += (0..<5).map { site("waiting\($0)") }
        sites += (0..<3).map { site("slow\($0)") }
        sites += (0..<6).map { site("good\($0)") }
        let pin: [String: SourceTier] = Dictionary(uniqueKeysWithValues: sites.map { candidate in
            let name = candidate.name
            if name.hasPrefix("good") { return (candidate.key, .playable) }
            if name.hasPrefix("slow") { return (candidate.key, .slow) }
            if name.hasPrefix("waiting") { return (candidate.key, .untested) }
            return (candidate.key, .dead)
        })
        let shelves = SourceShelf.shelves(byConnectivity: sites) { pin[$0.key] ?? .untested }
        #expect(shelves.map(\.tier) == [.playable, .slow, .untested, .dead])
        // 一个源都不能丢。
        #expect(shelves.reduce(0) { $0 + $1.sites.count } == sites.count)
        // 折叠状态靠这个 id，两种书架的 id 不能撞。
        #expect(Set(shelves.map(\.id)).count == shelves.count)
    }

    /// 只有一个档位时不分层：一条「能播 46」的书架没有信息量。
    @Test func oneTierIsNoShelf() {
        let sites = (0..<20).map { site("good\($0)") }
        #expect(SourceShelf.shelves(byConnectivity: sites) { _ in .playable }.isEmpty)
    }

    // MARK: 自动档

    /// 没测出能用的源时，`auto` 仍按内容分 —— 一组全是「未测 / 不通」的 4K 源，
    /// 按连通分只会得到两层没用的货架。
    @Test func autoKeepsContentShelvesUntilSomethingPlays() {
        var sites: [Site] = (0..<30).map { site("蓝光站\($0)") }
        sites += (0..<10).map { site("磁力站\($0)") }
        var counts = TierCounts()
        for _ in sites { counts.add(.untested) }
        let shelves = SourceShelf.shelves(for: sites, mode: .auto, counts: counts) { _ in .untested }
        #expect(shelves.contains { $0.shelf == .bluRay })
        #expect(shelves.allSatisfy { $0.tier == nil })
    }

    /// 测出了三个以上能用的源之后，同一组自动换成按连通分。
    @Test func autoSwitchesOnceThreeSourcesPlay() {
        var sites: [Site] = (0..<30).map { site("蓝光站\($0)") }
        sites += (0..<10).map { site("磁力站\($0)") }
        var counts = TierCounts()
        for _ in sites { counts.add(.untested) }
        for _ in 0..<3 { counts.add(.playable) }
        let playing: Set<String> = Set(sites.prefix(3).map(\.key))
        let shelves = SourceShelf.shelves(for: sites, mode: .auto, counts: counts) {
            playing.contains($0.key) ? .playable : .untested
        }
        #expect(shelves.first?.tier == .playable)
        #expect(shelves.last?.tier == .untested)
    }

    // MARK: 组内排序

    /// 能播的排前面，同一档里不动 —— 原来的顺序是 `SourceStrategy.arrange` 排出来的。
    @Test func sortingPutsPlayableFirstAndKeepsTheOrderInsideATier() {
        let sites = ["a", "b", "c", "d", "e"].map { site($0) }
        let pin: [String: SourceTier] = [
            "a": .untested, "b": .playable, "c": .dead, "d": .playable, "e": .slow,
        ]
        let sorted = SourceConnectivity.sorted(sites) { pin[$0.key] ?? .untested }
        #expect(sorted.map(\.key) == ["b", "d", "e", "a", "c"])
    }

    /// 强制按连通时听读者的：即便还没测过，也给出那一层「未测」。
    @Test func forcingConnectionKeepsTheChoice() {
        var sites: [Site] = (0..<6).map { site("good\($0)") }
        sites += (0..<6).map { site("other\($0)") }
        var counts = TierCounts()
        for _ in sites { counts.add(.untested) }
        let shelves = SourceShelf.shelves(for: sites, mode: .connectivity, counts: counts) { _ in .untested }
        // 只有一层，仍然不分 —— 分层的意义在于「分得开」。
        #expect(shelves.isEmpty)
    }
}
