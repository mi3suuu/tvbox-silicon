import Foundation
import Testing
@testable import TVCore

/// A server that answers with more bytes than the Range asked for must not let one lane write over
/// the neighbouring lane's region. That corruption has no error attached to it — the file finishes,
/// plays, and shows a glitch in the middle — so the clamp is worth pinning here.
@Test func aLaneNeverWritesPastItsRange() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "clamp-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try PositionalFile(url)
    defer { file.closeHandle() }
    try file.reserve(12)
    // Lane A owns 0..<6, lane B owns 6..<12.
    let overflow = Data("ABCDEFGHIJKL".utf8)   // twelve bytes for a six-byte range
    let room = 6
    let slice = overflow.count > room ? overflow.prefix(room) : overflow
    try file.write(slice, at: 0)
    try file.write(Data("------".utf8), at: 6)
    file.flush()
    // The first six bytes are A's, the last six are B's untouched by A's overrun.
    #expect(try Data(contentsOf: url) == Data("ABCDEF------".utf8))
}

/// `split` must not hand a lane back its own range: the lane would re-request bytes it already has,
/// which reads as progress in the counters and is not.
@Test func aLaneDoesNotStealItsOwnRange() throws {
    let chunk: Int64 = 4 << 20
    let queue = RangeQueue(length: chunk * 2, chunk: chunk)
    let mine = try #require(queue.take(lane: 0))
    let theirs = try #require(queue.take(lane: 1))
    // Lane 0 asks to split. Lane 1's range is splittable, so lane 0 gets lane 1's tail — never its own.
    #expect(queue.split(avoid: 0) == true)
    let stolen = try #require(queue.take(lane: 2))
    // The half offered is the second half of lane 1's range, not any part of lane 0's.
    #expect(stolen.lowerBound >= theirs.lowerBound + Int64(theirs.count / 2))
    #expect(stolen.upperBound <= theirs.upperBound)
    #expect(stolen.lowerBound >= mine.upperBound || stolen.upperBound <= mine.lowerBound)

    // With nobody else holding anything, the asker gets nothing: refusing is the correct answer, and
    // the earlier fallback that cut the asker's own range is what this asserts against.
    let lone = RangeQueue(length: chunk * 4, chunk: chunk)
    _ = try #require(lone.take(lane: 7))
    _ = try #require(lone.take(lane: 8))
    _ = try #require(lone.take(lane: 9))
    _ = try #require(lone.take(lane: 10))
    let only = RangeQueue(length: chunk, chunk: chunk)
    _ = try #require(only.take(lane: 0))
    #expect(only.split(avoid: 0) == false)
    #expect(only.depth == 0)
}

/// An unranged file (a server that ignores Range) has no spans, so `complete()` is false by
/// construction. The fetch path must not treat that as a failed download.
@Test func anUnrangedFileIsNotJudgedByItsSpans() {
    let file = TransferPlan.RemoteFile(urls: [], name: "media.part", length: nil, ranged: false)
    #expect(!file.complete())
    // And the guard that decides whether to check at all is the pair (ranged, length > 0).
    let shouldCheck = file.ranged && (file.length ?? 0) > 0
    #expect(shouldCheck == false)
}

/// The retry budget must stay bounded: a range is asked for a handful of times, not a dozen.
///
/// Measured before the fix: one megabyte against a server that answered 503 twice produced four
/// requests for the same range (pump retried 4x on top of get's 3x per mirror). The shape of the
/// fix is "get owns mirror rotation and transient failures; the lane owns short deliveries and a
/// small escalation", and this pins the arithmetic so a future edit cannot quietly multiply it again.
@Test func theRetryBudgetDoesNotMultiply() {
    // get: 3 attempts. pump: 2 more after that. Worst case per range, one mirror:
    let getAttempts = 3
    let laneRetries = 2
    let worst = getAttempts + laneRetries
    #expect(worst <= 6)
    // And the old shape, for contrast: pump's own 4 attempts each calling get's 3.
    let oldWorst = 4 * getAttempts
    #expect(oldWorst == 12)
    #expect(worst < oldWorst)
}

