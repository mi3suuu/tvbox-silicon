import Foundation

/// How far ahead of the player a cloud file is read, and how many chunks are kept: worked out from the
/// device's memory and the video's bitrate, not fixed numbers (#702). A 4K file at 10 MB/s was read 1.6
/// seconds ahead by the old 16 MB window; a low-bitrate file never needed that much.
struct CloudBufferPlan: Equatable {
    /// Chunks fetched ahead of where the player is reading.
    let readAhead: Int
    /// Chunks kept in memory.
    let cacheChunks: Int
    /// How many seconds of playback `readAhead` covers; 0 while the bitrate isn't known.
    let seconds: Double

    /// Before the duration is known, and for reads that aren't playback (remuxing, downloads).
    static let fallback = CloudBufferPlan(readAhead: CloudByteStream.readAhead, cacheChunks: CloudByteStream.cacheChunks, seconds: 0)
    /// What the buffer aims for when the device has the memory.
    static let targetSeconds = 90.0
    static let fewestAhead = 8
    static let fewestCached = 24, mostCached = 192

    /// `budget` is the bytes of memory the cache may use.
    ///
    /// - Parameter share: 现在**同时活着几条**云流。预算按它均分。
    ///
    ///   ⛔ 2026-11-17 必须加这一条：`budget` 是**进程级**的总量（iPhone 8 GB 机型 320 MB），
    ///   而原实现让**每一条**流都能吃满它 —— 一条 4K 片就能把 160 个 2 MB 块占住。
    ///   坞扩到 20 个窗之后，「20 条各吃 320 MB」不是慢，是立刻被系统杀掉。
    ///   均分之后单路变浅（20 路 ≈ 每路 16 MB / 8 块），但每一路都还在播；
    ///   单路时 `share == 1`，行为与改动前完全相同。
    static func make(length: Int, duration: Double?, budget: Int, chunkSize: Int,
                     share: Int = 1) -> CloudBufferPlan {
        let streams = max(1, share)
        let perStream = budget / streams
        // 均分之后下限也要跟着降，否则 20 路 × 24 块 = 960 MB，等于没均分。
        // 6 块（12 MB）是「一次 seek 不立刻断流」的最小值。
        let floorChunks = streams <= 1 ? fewestCached : max(6, fewestCached / streams)
        let cached = max(floorChunks, min(mostCached, perStream / chunkSize))
        // Video and audio can be read in two places at once, each with its own window, and a few chunks are
        // behind the player for a short step back.
        let room = max(fewestAhead, (cached - 4) / 2)
        guard let duration, duration > 1, length > 0 else {
            return CloudBufferPlan(readAhead: min(CloudByteStream.readAhead, room), cacheChunks: cached, seconds: 0)
        }
        let bytesPerSecond = Double(length) / duration
        let wanted = Int((bytesPerSecond * targetSeconds / Double(chunkSize)).rounded(.up))
        let ahead = min(max(wanted, fewestAhead), room)
        return CloudBufferPlan(readAhead: ahead, cacheChunks: cached, seconds: Double(ahead * chunkSize) / bytesPerSecond)
    }
}
