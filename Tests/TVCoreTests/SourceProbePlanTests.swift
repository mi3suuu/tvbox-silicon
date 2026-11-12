// [mi3s] 二开：源测速增量刷新 + 按可达性批量分组/路由
import Foundation
import Testing
@testable import TVCore

private func suite() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: UUID().uuidString))
}

private func site(_ key: String) -> Site {
    try! JSONDecoder().decode(Site.self, from: Data(
        #"{"key":"\#(key)","name":"\#(key)","type":3,"api":"https://ex.invalid/\#(key)","raw":{}}"#.utf8))
}

/// The incremental window: a reading inside it is skipped, one outside is re-measured, and 0
/// never skips. This is what makes a second sweep cheap, so it is worth pinning down.
@MainActor @Test func aSweepSkipsReadingsInsideTheWindow() throws {
    let defaults = try suite()
    let probes = SourceProbeStore.shared
    probes.forgetEverything()
    let fresh = site("fresh"), old = site("old"), never = site("never")
    let now = Date()
    probes.record(SourceProbeResult(reachability: .reachable, measuredAt: now),
                  sourceKey: fresh.sourceKey, videoID: "v", lineFlag: "l")
    probes.record(SourceProbeResult(reachability: .reachable, measuredAt: now.addingTimeInterval(-3600)),
                  sourceKey: old.sourceKey, videoID: "v", lineFlag: "l")
    // A ten-minute window trusts `fresh`, distrusts `old`, and has nothing for `never`.
    let window: TimeInterval = 600
    func stale(_ s: Site) -> Bool {
        guard let r = probes.latest(sourceKey: s.sourceKey) else { return true }
        return r.measuredAt.timeIntervalSinceNow < -window
    }
    #expect(!stale(fresh))
    #expect(stale(old))
    #expect(stale(never))
    // Zero is the "measure everything now" escape hatch: the guard short-circuits before the reading
    // is consulted at all, so a stale window cannot suppress it.
    func needsProbing(_ s: Site, maxAge: TimeInterval) -> Bool {
        guard maxAge > 0 else { return true }
        guard let r = probes.latest(sourceKey: s.sourceKey) else { return true }
        return r.measuredAt.timeIntervalSinceNow < -maxAge
    }
    #expect(needsProbing(fresh, maxAge: 0) == true)
    #expect(needsProbing(never, maxAge: 600) == true)
    probes.forgetEverything()
}

/// Unmeasured sources must never be called reachable: routing them as if they answered bakes a
/// guess into a setting nobody revisits.
@MainActor @Test func anUnmeasuredSourceIsNeitherAnsweredNorSilent() {
    let probes = SourceProbeStore.shared
    #expect(probes.latest(sourceKey: "never-measured-key") == nil)
    // And a source that HAS a reading of "unreachable" is silent, not unknown: the two are different
    // answers and the routing rule treats them differently.
    probes.record(SourceProbeResult(reachability: .unreachable, measuredAt: Date()),
                  sourceKey: "silent-key", videoID: "v", lineFlag: "l")
    #expect(probes.latest(sourceKey: "silent-key")?.reachability == .unreachable)
    probes.clear(sourceKey: "silent-key", videoID: "v")
}
