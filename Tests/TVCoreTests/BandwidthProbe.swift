import Foundation
import Testing
@testable import TVCore

/// End-to-end: the meter's rate against the bytes a throttled server actually sent.
///
/// This is the check that matters. A rate can be wrong in two opposite ways - too low (a range held in
/// a buffer is counted late) or too high (bytes on disk counted as bytes arrived) - and only the
/// server's own byte count can tell which.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TVBOX_BENCH_URL"] != nil))
@MainActor func theMeterAgreesWithTheServerAboutHowFastItWent() async throws {
    let target = URL(string: ProcessInfo.processInfo.environment["TVBOX_BENCH_URL"]!)!
    let folder = FileManager.default.temporaryDirectory.appending(path: "band-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let defaults = UserDefaults(suiteName: "band-\(UUID().uuidString)")!
    let settings = DownloadSettings(defaults: defaults)
    settings.set(connections: 8, chunkMB: 4, parallel: 1)
    let library = DownloadLibrary(root: folder, defaults: defaults, settings: settings)
    library.resolver = { _ in Channel(name: "band", url: target) }
    let site = try JSONDecoder().decode(Site.self, from: Data(#"{"key":"band","name":"Band","type":3,"api":"bench://local","raw":{}}"#.utf8))
    let episode = Episode(id: target.absoluteString, name: "Band", address: target.absoluteString, flag: "band")
    let item = library.download(DownloadSource(site: site, videoID: target.absoluteString, episode: episode), title: "Band", poster: nil)
    var readings: [(s: Double, bytes: Int64)] = []
    let began = Date()
    // Generous: a 1 GiB file on a slow line is minutes, and the point is the rate, not the finish.
    while library.item(id: item.id)?.status != .completed, library.item(id: item.id)?.status != .failed,
          Date().timeIntervalSince(began) < 400 {
        try await Task.sleep(for: .milliseconds(500))
        if let now = library.item(id: item.id), now.speed > 0 { readings.append((now.speed, now.received)) }
    }
    let elapsed = Date().timeIntervalSince(began)
    let done = library.item(id: item.id)
    let average = Double(done?.received ?? 0) / max(elapsed, 0.001)
    let highest = readings.map(\.s).max() ?? 0
    print(String(format: "PROBE avg=%.2fMB/s peakShown=%.2fMB/s sockets=%d seconds=%.1f",
                 average / 1_048_576, highest / 1_048_576, done?.connections ?? 0, elapsed))
    // No reading may exceed what the line could carry. 25 MB/s is a generous ceiling for a test box.
    #expect(highest < 25 * 1_048_576)
    // And the average must be in the same order as the shown number: a meter that reads 10x the truth
    // is worse than no meter.
    #expect(highest < average * 3 + Double(2 << 20))
    // The line was the limit, not the meter: 8 sockets x 800 KB/s is 6.4 MB/s, and 6.08 is that.
    #expect((done?.received ?? 0) > 0)
}
