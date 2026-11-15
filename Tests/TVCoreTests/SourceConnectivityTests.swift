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
                         kbps: Int? = nil) -> SourceProbeResult {
        SourceProbeResult(reachability: reachability, kilobytesPerSecond: kbps,
                          measuredAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: 读数 → 档位

    @Test func aFastReadingIsPlayable() {
        #expect(SourceConnectivity.tier(of: reading(.reachable, kbps: 1200)) == .playable)
    }

    /// 300 KB/s 是 720P 的门槛：它自己就是「能播」。
    @Test func theThresholdItselfIsPlayable() {
        #expect(SourceConnectivity.tier(of: reading(.reachable, kbps: 300)) == .playable)
        #expect(SourceConnectivity.tier(of: reading(.reachable, kbps: 299)) == .slow)
    }

    @Test func aSilentReadingIsDead() {
        #expect(SourceConnectivity.tier(of: reading(.unreachable)) == .dead)
    }

    /// 连上了但只拿到握手、没有吞吐：不是「不通」，是「会转圈」。
    @Test func reachableWithoutThroughputStaysPlayable() {
        #expect(SourceConnectivity.tier(of: reading(.reachable)) == .playable)
        // 而「不知道」且没有数字，就是没有结论。
        #expect(SourceConnectivity.tier(of: reading(.unknown)) == .untested)
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
    @Test func aFreshReadingBeatsTheShippedVerdict() {
        let shipped = site("a", raw: ["_route": .string("直连")])
        #expect(SourceConnectivity.tier(of: shipped, reading: reading(.unreachable)) == .dead)
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
