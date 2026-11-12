// [mi3s] 二开：本文件内新增的测试覆盖 下载源携带 origin / originalKey（保险库需要），并兼容无 origin 的旧 JSON
import Foundation
import Testing
@testable import TVCore

@Test func hlsPlaylistsAreRewrittenToLocalParts() throws {
    let text = """
    #EXTM3U
    #EXT-X-VERSION:6
    #EXT-X-TARGETDURATION:6
    #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.com/k1",IV=0x01
    #EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0"
    #EXTINF:6.0,
    #EXT-X-BYTERANGE:1000@720
    media.mp4
    #EXTINF:6.0,
    #EXT-X-BYTERANGE:500
    media.mp4
    #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.com/k1",IV=0x02
    #EXTINF:4.0,
    https://cdn.example.com/seg/3.png?token=a
    #EXT-X-ENDLIST
    """
    let local = try HLS.localize(text, base: URL(string: "https://example.com/v/index.m3u8")!)
    #expect(local.parts.map(\.name) == ["parts/key-0.key", "parts/init-1.mp4", "parts/00000.mp4", "parts/00001.mp4", "parts/00002.ts"])
    #expect(local.parts[1].range == 0...719)
    #expect(local.parts[2].range == 720...1719)
    // A byte range without an offset continues where the previous one of the same file ended.
    #expect(local.parts[3].range == 1720...2219)
    #expect(local.parts[2].url.absoluteString == "https://example.com/v/media.mp4")
    #expect(local.parts.map(\.transportStream) == [false, false, false, false, true])
    #expect(local.playlist.contains("#EXT-X-KEY:METHOD=AES-128,URI=\"parts/key-0.key\",IV=0x02"))
    #expect(local.playlist.contains("#EXT-X-MAP:URI=\"parts/init-1.mp4\"\n"))
    #expect(!local.playlist.contains("BYTERANGE"))
    #expect(local.playlist.hasSuffix("parts/00002.ts\n#EXT-X-ENDLIST\n"))
}

@Test func liveAndProtectedPlaylistsAreRefused() {
    let base = URL(string: "https://example.com/live.m3u8")!
    #expect(throws: TransferError.live) { try HLS.localize("#EXTM3U\n#EXTINF:6,\na.ts\n", base: base) }
    #expect(throws: TransferError.protected) {
        try HLS.localize("#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://key\"\n#EXTINF:6,\na.ts\n#EXT-X-ENDLIST\n", base: base)
    }
}

@Test func theBestVariantIsChosenByBandwidth() {
    let text = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\nlow/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS=\"avc1.640028,mp4a.40.2\"\nhigh/index.m3u8\n"
    let variants = HLS.variants(text, base: URL(string: "https://example.com/master.m3u8")!)
    let best = variants.max { $0.bandwidth < $1.bandwidth }
    #expect(variants.count == 2)
    #expect(best?.url.absoluteString == "https://example.com/high/index.m3u8")
    #expect(best?.height == 1080)
}

@Test func rangedFilesSplitIntoChunks() {
    let file = TransferPlan.RemoteFile(urls: [], name: "media.part", length: Transfer.chunk * 2 + 10, ranged: true,
                                       spans: [ByteSpan(start: 0, end: Transfer.chunk),
                                               ByteSpan(start: Transfer.chunk * 2, end: Transfer.chunk * 2 + 10)])
    #expect(file.chunks == 3)
    #expect(file.range(2) == Transfer.chunk * 2...Transfer.chunk * 2 + 9)
    #expect(file.saved == Transfer.chunk + 10)
    #expect(!file.complete())
}

@Test func chunkMarksFromOlderPlansStillCount() {
    // A plan written before spans existed: chunk numbers only. It must resume, not start over.
    let file = TransferPlan.RemoteFile(urls: [], name: "media.part", length: Transfer.chunk * 2 + 10, ranged: true, done: [0, 2])
    #expect(file.saved == Transfer.chunk + 10)
    #expect(file.finished.count == 2)
    // ...and once one more range lands, the old marks are folded into spans and stop being read.
    var merged = file
    merged.merge(ByteSpan(start: Transfer.chunk, end: Transfer.chunk * 2))
    #expect(merged.done.isEmpty)
    #expect(merged.spans == [ByteSpan(start: 0, end: Transfer.chunk * 2 + 10)])
    #expect(merged.complete())
}

@Test func aSplitRangeIsRecordedAsTwoHalvesThatJoin() {
    var file = TransferPlan.RemoteFile(urls: [], name: "media.part", length: 100, ranged: true, chunk: 100)
    file.merge(ByteSpan(start: 50, end: 100))   // the second half, fetched by a lane that stole the tail
    #expect(!file.complete())
    #expect(file.saved == 50)
    file.merge(ByteSpan(start: 0, end: 50))     // the first half arrives later
    // Two halves that meet become one span; the file is complete without a third request.
    #expect(file.spans == [ByteSpan(start: 0, end: 100)])
    #expect(file.complete())
}

@Test func aRangeQueueHandsOutOnlyWhatIsMissingAndSplitstheLargest() throws {
    let chunk: Int64 = 4 << 20
    let queue = RangeQueue(length: chunk * 4, chunk: chunk, skip: [0..<chunk])
    // Four ranges, one already on disk: three to fetch.
    #expect(queue.depth == 3)
    let first = try #require(queue.take(lane: 0))
    #expect(first == chunk..<(chunk * 2))
    let second = try #require(queue.take(lane: 1))
    let third = try #require(queue.take(lane: 2))
    #expect(first.lowerBound < second.lowerBound && second.lowerBound < third.lowerBound)
    // Everything is claimed: a lane splitting the largest range is what keeps the tail at full speed.
    #expect(queue.isEmpty)
    #expect(queue.split(avoid: -1))
    #expect(queue.depth == 1)
    // Each claim is now half a chunk, so nothing is left to cut.
    let stolen = try #require(queue.take(lane: 3))
    #expect(stolen.count == chunk / 2)
}

/// A resumed download must not report the bytes already on disk as a burst of speed.
///
/// The failure this pins down is loud: resuming a 500 MB file claimed 1885 MB/s on a 50 Mbit line.
/// A rate above the link is not a fast download, it is a wrong number, and the row it lands in is
/// read by a person deciding whether to wait.
@Test func aResumedDownloadDoesNotClaimTheBytesItAlreadyHad() async throws {
    let meter = SpeedMeter()
    let already: Int64 = 500 << 20
    // First reading: bytes on disk, not bytes that arrived.
    meter.sample(already)
    #expect(meter.speed == 0)
    try await Task.sleep(for: .milliseconds(250))
    // One more megabyte in a quarter second is about 4 MB/s, not 500.
    meter.sample(already + (1 << 20))
    #expect(meter.speed > Double(2 << 20))
    #expect(meter.speed < Double(8 << 20))
    // A finished transfer stops claiming a rate.
    meter.settle()
    #expect(meter.speed == 0)
}

@Test func tuningClampsAndReportsItsSocketCount() {
    #expect(DownloadTuning(connections: 99, chunkMB: 0, parallel: 99).connections == 16)
    #expect(DownloadTuning(connections: 99, chunkMB: 0, parallel: 99).chunkMB == 1)
    #expect(DownloadTuning(connections: 99, chunkMB: 0, parallel: 99).parallel == 8)
    #expect(DownloadTuning(connections: 8, chunkMB: 4, parallel: 2).sockets == 16)
    #expect(DownloadTuning(connections: 8, chunkMB: 4, parallel: 2).chunk == 4 << 20)
}

@MainActor @Test func tuningIsPersistedUnderOnesKeyNames() throws {
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    let settings = DownloadSettings(defaults: defaults)
    settings.set(connections: 12, chunkMB: 8, parallel: 3)
    #expect(settings.tuning == DownloadTuning(connections: 12, chunkMB: 8, parallel: 3))
    // The same three keys One reads, so a backup from either app restores in the other.
    #expect(defaults.integer(forKey: "downloadConnections") == 12)
    #expect(defaults.integer(forKey: "downloadChunkMB") == 8)
    #expect(defaults.integer(forKey: "downloadParallel") == 3)
    let reloaded = DownloadSettings(defaults: defaults)
    #expect(reloaded.tuning.connections == 12)
    #expect(reloaded.tuning.chunkMB == 8)
    #expect(reloaded.tuning.parallel == 3)
    // A knob turned mid-download reaches the file in flight, not just the next one: the library pushes
    // the new tuning into every running transfer's box.
    let box = TuningBox(settings.tuning)
    #expect(box.value.connections == 12)
    settings.onTuning = { box.value = $0 }
    settings.set(connections: 4, chunkMB: 2, parallel: 1)
    #expect(box.value == DownloadTuning(connections: 4, chunkMB: 2, parallel: 1))
    // Setting the same values again must not fire, or every keystroke would reschedule the queue.
    var fired = 0
    settings.onTuning = { _ in fired += 1 }
    settings.set(connections: 4)
    #expect(fired == 0)
}

/// One file, fetched by several Range requests at once, must come out byte for byte.
@Test func aRangedFileIsFetchedOnManyConnectionsAtOnce() async throws {
    let size = (4 << 20) + 1234
    let name = "accel-(UUID().uuidString).mp4"
    var bytes = Data(count: size)
    bytes.withUnsafeMutableBytes { raw in
        for i in 0..<size { raw[i] = UInt8(truncatingIfNeeded: i &* 7 &+ (i >> 11)) }
    }
    let url = RangeServer.add(name, bytes)
    let folder = FileManager.default.temporaryDirectory.appending(path: "accel-(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let meter = DownloadMeter()
    let speed = SpeedMeter()
    let transfer = Transfer(folder: folder, meter: meter, session: RangeServer.session,
                            tuning: TuningBox(DownloadTuning(connections: 4, chunkMB: 1, parallel: 1)),
                            speed: speed,
                            resolve: { Channel(name: "t", group: "t", url: url, headers: [:]) },
                            note: { _ in })
    let media = try await transfer.run()
    let written = try Data(contentsOf: folder.appending(path: media))
    #expect(written.count == size)
    #expect(written == bytes)
    // A four-megabyte file in one-megabyte ranges: one probe, then at least four more.
    #expect(RangeServer.requests(name) >= 5)
    // And they really did overlap. Without this the test would pass on a single-stream downloader:
    // the point of the engine is the socket count, not the byte count.
    #expect(RangeServer.peakConnections(name) > 1)
}

/// Stopping mid-file and starting again must not fetch again what is already on disk.
@Test func aStoppedDownloadResumesWithoutRefetching() async throws {
    let size = 6 << 20
    let name = "resume-(UUID().uuidString).mp4"
    var bytes = Data(count: size)
    bytes.withUnsafeMutableBytes { raw in
        for i in 0..<size { raw[i] = UInt8(truncatingIfNeeded: i &* 13) }
    }
    let url = RangeServer.add(name, bytes)
    let folder = FileManager.default.temporaryDirectory.appending(path: "resume-(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    func transfer() -> Transfer {
        Transfer(folder: folder, meter: DownloadMeter(), session: RangeServer.session,
                 tuning: TuningBox(DownloadTuning(connections: 2, chunkMB: 1, parallel: 1)),
                 resolve: { Channel(name: "t", group: "t", url: url, headers: [:]) },
                 note: { _ in })
    }
    // First run, cancelled once some ranges have landed and the marks are on disk.
    let first = Task { try await transfer().run() }
    while !FileManager.default.fileExists(atPath: folder.appending(path: "plan.json").path) {
        try await Task.sleep(for: .milliseconds(20))
    }
    try await Task.sleep(for: .milliseconds(150))
    first.cancel()
    _ = try? await first.value
    let before = RangeServer.requests(name)
    // Second run: replays the plan and asks only for what is missing.
    let media = try await transfer().run()
    #expect(try Data(contentsOf: folder.appending(path: media)) == bytes)
    #expect(RangeServer.requests(name) - before < 4)
}

@Test func aPositionalFileTakesWritesOutOfOrder() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "pos-(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try PositionalFile(url)
    defer { file.closeHandle() }
    try file.reserve(12)
    // Two lanes, the later range written first: an offset, not a file pointer, decides where it lands.
    try file.write(Data("GHIJKL".utf8), at: 6)
    try file.write(Data("ABCDEF".utf8), at: 0)
    file.flush()
    #expect(try Data(contentsOf: url) == Data("ABCDEFGHIJKL".utf8))
}

@Test func theLocalServerAnswersRangesInsideItsFolderOnly() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "downloads-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appending(path: "item/parts"), withIntermediateDirectories: true)
    try Data("0123456789".utf8).write(to: root.appending(path: "item/parts/00000.ts"))
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try await LocalMediaServer.shared.address(of: root.appending(path: "item/parts/00000.ts"), root: root)
    var request = URLRequest(url: url)
    request.setValue("bytes=2-5", forHTTPHeaderField: "Range")
    let (data, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 206)
    #expect(String(decoding: data, as: UTF8.self) == "2345")
    #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "video/mp2t")
    let outside = url.deletingLastPathComponent().appending(path: "../../../etc/hosts")
    let (_, refused) = try await URLSession.shared.data(from: outside)
    #expect((refused as? HTTPURLResponse)?.statusCode == 404)
}

@Test func songFilesAreNamedByTheirFirstBytes() {
    let bare = URL(string: "https://music.example.com/stream?id=1")!
    #expect(Transfer.fileExtension(bare, mime: "application/octet-stream", head: Data("fLaC\0\0\0\"".utf8)) == "flac")
    #expect(Transfer.fileExtension(bare, mime: "", head: Data("ID3\u{4}\0\0\0\0\0\0\0\0".utf8)) == "mp3")
    #expect(Transfer.fileExtension(bare, mime: "", head: Data([0xFF, 0xFB, 0x90, 0x64])) == "mp3")
    #expect(Transfer.fileExtension(bare, mime: "", head: Data([0xFF, 0xF1, 0x50, 0x80])) == "aac")
    #expect(Transfer.fileExtension(bare, mime: "audio/x-flac") == "flac")
    // Video detection is unchanged.
    #expect(Transfer.fileExtension(bare, mime: "", head: Data([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])) == "mp4")
}

@Test func savedLyricsReadBackTheSame() throws {
    let lyrics = try #require(MusicLyrics.parse("[00:01.00]故事的小黄花\n[00:05.50]从出生那年就飘着", platform: .qq))
    let decoded = try JSONDecoder().decode(MusicLyrics.self, from: JSONEncoder().encode(lyrics))
    #expect(decoded == lyrics)
    #expect(decoded.index(at: 6) == 1)
}

@MainActor @Test func musicDownloadsKeepTheirAlbumsAndPlaylistsAndPauseTogether() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "music-downloads-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let songs = (1...3).map { MusicTrack(platform: .qq, songID: "s\($0)", title: "Song \($0)", artists: ["A"]) }
    let album = MusicCollection(kind: .album, platform: .qq, collectionID: "a1", title: "Album")
    let playlist = MusicCollection(kind: .playlist, platform: .qq, collectionID: "p1", title: "Mix")
    let library = MusicDownloadLibrary(root: root)
    library.download(Array(songs.prefix(2)), from: album)
    library.download([songs[2], songs[0]], from: playlist)
    // Most recent first, each in its own order; a song in both is saved once.
    #expect(library.collections.map(\.id) == [playlist.id, album.id])
    #expect(library.items(in: try #require(library.collection(id: playlist.id))).map(\.id) == [songs[2].id, songs[0].id])
    #expect(library.items.count == 3)

    library.pauseAll()
    #expect(library.items.allSatisfy { $0.status == .paused })
    #expect(library.isPaused)
    // Still paused, and still grouped, when the app opens again.
    let reopened = MusicDownloadLibrary(root: root)
    #expect(reopened.items.allSatisfy { $0.status == .paused })
    #expect(reopened.collections.map(\.id) == [playlist.id, album.id])

    // Removing the album keeps the song the playlist shares.
    library.remove(collection: album.id)
    #expect(Set(library.items.map(\.id)) == [songs[0].id, songs[2].id])
    #expect(library.collections.map(\.id) == [playlist.id])
    library.resumeAll()
    #expect(!library.isPaused)
    library.remove(library.items.map(\.id))
    #expect(library.collections.isEmpty)
}

@MainActor @Test func downloadsWhoseFilesWereDeletedOrMovedAreForgotten() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "downloads-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let site = Site(key: "s", name: "S", type: 3, api: "csp_Test", raw: [:])
    let items = (1...3).map { number in
        let episode = Episode(id: "\(number)", name: "第 \(number) 集", address: "https://example.com/\(number).mp4", flag: "line")
        return DownloadItem(id: "e\(number)", title: "Show", episode: episode.name, poster: nil, posterHeaders: [:],
                            source: DownloadSource(site: site, videoID: "v", episode: episode), created: Date(), status: .completed, media: "media.mp4")
    }
    for item in items {
        try FileManager.default.createDirectory(at: root.appending(path: item.id), withIntermediateDirectories: true)
        try Data("mp4".utf8).write(to: root.appending(path: item.id).appending(path: "media.mp4"))
    }
    try JSONEncoder().encode(items).write(to: root.appending(path: "downloads.json"))
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    let library = DownloadLibrary(root: root, defaults: defaults)
    #expect(library.items.map(\.id) == ["e1", "e2", "e3"])
    #expect(library.file(for: items[0]) == root.appending(path: "e1").appending(path: "media.mp4"))

    // Moved away in Finder: playing it says so and it leaves the list.
    try FileManager.default.removeItem(at: root.appending(path: "e1").appending(path: "media.mp4"))
    await #expect(throws: TVError.self) { try await library.playbackAddress(for: URL(string: "tvbox-download://e1")!) }
    #expect(library.items.map(\.id) == ["e2", "e3"])
    // Deleted while the app was open: the next look at the page drops it, and a relaunch agrees.
    try FileManager.default.removeItem(at: root.appending(path: "e2"))
    library.forgetMissing()
    #expect(library.items.map(\.id) == ["e3"])
    #expect(DownloadLibrary(root: root, defaults: defaults).items.map(\.id) == ["e3"])
    // The whole folder deleted: the list is still saved, in a new folder.
    try FileManager.default.removeItem(at: root)
    library.forgetMissing()
    #expect(library.items.isEmpty)
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "downloads.json").path))
}

@MainActor @Test func downloadsAtATimeCanBeChanged() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "downloads-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    let settings = DownloadSettings(defaults: defaults)
    let library = DownloadLibrary(root: root, defaults: defaults, settings: settings)
    #expect(library.simultaneous == DownloadTuning.standard.parallel)
    library.simultaneous = 3
    #expect(library.simultaneous == 3)
    #expect(defaults.integer(forKey: "downloadParallel") == 3)
    library.simultaneous = 9
    // The queue's own ceiling, not the tuning struct's: eight files would starve the sockets.
    #expect(library.simultaneous == 8)
    #expect(defaults.integer(forKey: "downloadParallel") == 8)
    #expect(DownloadLibrary(root: root, defaults: defaults, settings: DownloadSettings(defaults: defaults)).simultaneous == 8)
}

/// Clearing the list must clear the disk, including folders the list lost track of: those are where a
/// phone's storage goes after a crash, invisible until the bar is full.
@MainActor @Test func clearingAllAlsoRemovesFoldersTheListLostTrackOf() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "clear-(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    let library = DownloadLibrary(root: root, defaults: defaults, settings: DownloadSettings(defaults: defaults))
    // A known download and an orphan left by a crash mid-plan.
    //
    // 名字必须是 UUID：`purgeOrphans` 只认「形如 UUID 的目录」为下载文件夹，
    // 其余（`downloads.json`、音乐库的 `Music` 子目录）一律不动 —— 老写法会把音乐库整个删掉。
    let knownID = UUID().uuidString.lowercased()
    let orphanID = UUID().uuidString.lowercased()
    for id in [knownID, orphanID] {
        try FileManager.default.createDirectory(at: root.appending(path: id), withIntermediateDirectories: true)
        try Data(repeating: 0, count: 4096).write(to: root.appending(path: id).appending(path: "media.part"))
    }
    #expect(FileManager.default.fileExists(atPath: root.appending(path: orphanID).path))
    library.purgeOrphans()
    // The list knows neither, so both go — the point is that the folder follows the record, not the reverse.
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: orphanID).path))
    #expect(FileManager.default.fileExists(atPath: root.path))
    library.removeAll()
    // Only the empty list itself is left: no folders, and nothing to measure.
    let left = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).map(\.lastPathComponent)
    #expect(left == ["downloads.json"])
    #expect(library.items.isEmpty)
}

@MainActor @Test func savedSongsWhoseFilesAreGoneAreForgotten() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "music-downloads-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let songs = (1...2).map { MusicTrack(platform: .qq, songID: "s\($0)", title: "Song \($0)", artists: ["A"]) }
    let items = songs.map { MusicDownload(track: $0, created: Date(), status: .completed, media: "audio.flac") }
    for item in items {
        let folder = root.appending(path: item.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("fLaC".utf8).write(to: folder.appending(path: "audio.flac"))
    }
    try JSONEncoder().encode(items).write(to: root.appending(path: "music-downloads.json"))
    let library = MusicDownloadLibrary(root: root)
    #expect(library.completed.count == 2)
    try FileManager.default.removeItem(at: root.appending(path: items[0].id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!))
    #expect(library.localSelection(for: songs[0]) == nil)
    library.forgetMissing()
    #expect(library.items.map(\.id) == [songs[1].id])
}

@MainActor @Test func startingADownloadIsAnnounced() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "downloads-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    let library = DownloadLibrary(root: root, defaults: defaults)
    var starts = 0
    library.onStart = { starts += 1 }
    library.resolver = { _ in try await Task.sleep(for: .seconds(60)); throw CancellationError() }
    let site = Site(key: "s", name: "S", type: 3, api: "csp_Test", raw: [:])
    let episode = Episode(id: "1", name: "第 1 集", address: "https://example.com/1.mp4", flag: "line")
    let item = library.download(DownloadSource(site: site, videoID: "v", episode: episode), title: "Show", poster: nil)
    #expect(starts == 1)
    #expect(library.item(id: item.id)?.status == .downloading)
    library.pause(item.id)
    library.resume(item.id)
    #expect(starts == 2)
    library.pause(item.id)
}

@MainActor @Test func sharedDownloadsAreRenamedCopiesThatLeaveTheDownloadAlone() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "downloads-\(UUID().uuidString)")
    let shared = FileManager.default.temporaryDirectory.appending(path: "shared-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: shared) }
    let site = Site(key: "s", name: "S", type: 3, api: "csp_Test", raw: [:])
    func item(_ id: String, _ episode: String, media: String) -> DownloadItem {
        let source = Episode(id: id, name: episode, address: "https://example.com/\(id)", flag: "line")
        return DownloadItem(id: id, title: "嫁金钗", episode: episode, poster: nil, posterHeaders: [:],
                            source: DownloadSource(site: site, videoID: "v", episode: source), created: Date(), status: .completed, media: media)
    }
    let movie = item("e1", "第30集", media: "media.mp4"), hls = item("e2", "第31集", media: "index.m3u8")
    for (entry, name) in [(movie, "media.mp4"), (hls, "index.m3u8")] {
        try FileManager.default.createDirectory(at: root.appending(path: entry.id), withIntermediateDirectories: true)
        try Data("mp4".utf8).write(to: root.appending(path: entry.id).appending(path: name))
    }
    try JSONEncoder().encode([movie, hls]).write(to: root.appending(path: "downloads.json"))
    let library = DownloadLibrary(root: root, defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))

    // An HLS download is many files: nothing to hand over.
    #expect(library.exportableFile(for: hls) == nil)
    let file = try #require(library.exportableFile(for: movie))
    let copy = try DownloadExport.copy(file, named: DownloadLibrary.exportName(for: movie), into: shared)
    #expect(copy.lastPathComponent == "嫁金钗 · 第30集.mp4")
    #expect(try Data(contentsOf: copy) == Data("mp4".utf8))
    // Deleting what was saved elsewhere keeps the episode in the app.
    try FileManager.default.removeItem(at: copy)
    library.forgetMissing()
    #expect(library.items.map(\.id) == ["e1", "e2"])
    #expect(FileManager.default.fileExists(atPath: file.path))
    // The next share replaces the last one's copy.
    _ = try DownloadExport.copy(file, named: "Other", into: shared)
    #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path) == ["Other.mp4"])
    DownloadExport.clear(shared)
    #expect(!FileManager.default.fileExists(atPath: shared.path))

    #expect(DownloadExport.fileName("a/b:c?\n d", extension: "mkv") == "a b c d.mkv")
    #expect(DownloadExport.fileName("..", extension: "mp4") == "Yingxia.mp4")
    #expect(MusicDownloadLibrary.exportName(for: MusicTrack(platform: .qq, songID: "s", title: "Song", artists: ["A", "B"])) == "A, B - Song")
}

// MARK: - 下载时保持屏幕常亮

/// One 的 `keepScreenAwake`：键名一致（备份互读），默认开。
///
/// 默认必须是 **true**：用户点下载就是为了下完，锁屏把传输掐掉是静默失败，
/// 比多耗一点电坏得多。这条断言防的正是「有人觉得省电更好」而把它改成 false。
@MainActor @Test func theScreenStaysAwakeByDefault() throws {
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    let settings = DownloadSettings(defaults: defaults)
    #expect(settings.keepScreenAwake)
}

@MainActor @Test func theKeepAwakeSwitchIsPersistedUnderOnesKey() throws {
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    let settings = DownloadSettings(defaults: defaults)
    settings.keepScreenAwake = false
    #expect(defaults.object(forKey: "keepScreenAwake") as? Bool == false)
    // A fresh instance reads what was written, not the default.
    #expect(!DownloadSettings(defaults: defaults).keepScreenAwake)
    settings.keepScreenAwake = true
    #expect(DownloadSettings(defaults: defaults).keepScreenAwake)
}

/// 关掉开关必须通知界面层 —— 否则压住自动锁屏的那次调用永远不会撤销，
/// 用户下完之后手机再也睡不着。
@MainActor @Test func turningTheSwitchOffReachesTheScreen() throws {
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    let settings = DownloadSettings(defaults: defaults)
    var seen: [Bool] = []
    settings.onKeepAwakeChange = { seen.append($0) }
    settings.keepScreenAwake = false
    settings.keepScreenAwake = false   // 同值不重复通知
    settings.keepScreenAwake = true
    #expect(seen == [false, true])
}
