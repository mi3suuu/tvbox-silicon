import CryptoKit
import Foundation
import Observation

/// A song kept for listening offline: the audio from the channel that played it best, with its
/// lyrics and its cover.
public struct MusicDownload: Codable, Identifiable, Hashable, Sendable {
    public let track: MusicTrack
    public let created: Date
    public internal(set) var status: DownloadItem.Status = .queued
    public internal(set) var failure: String?
    public internal(set) var received: Int64 = 0
    public internal(set) var expected: Int64?
    /// Where the audio came from and what it is, read from the file as for streaming.
    public internal(set) var candidate: MusicCandidate?
    public internal(set) var probe: MusicProbeResult?
    /// The audio file, relative to the song's folder.
    public internal(set) var media: String?
    /// Bytes on disk once finished.
    public internal(set) var size: Int64 = 0
    public internal(set) var finished: Date?
    /// [mi3s] 二开：多环境隔离。发起下载时打上当时的 `environments.activeID`，列表按当前环境过滤。
    /// nil = 这条记录写在 environments 出现之前，归默认环境 —— 升级不隐藏已经下好的歌。
    public internal(set) var environmentID: UUID?

    public var id: String { track.id }
    /// 0...1 by bytes; 0 until the size is known.
    public var fraction: Double {
        if status == .completed { return 1 }
        guard let expected, expected > 0 else { return 0 }
        return min(1, Double(received) / Double(expected))
    }
    public var isActive: Bool { status == .downloading || status == .finishing }
    /// Not finished: running, waiting or failed.
    public var isPending: Bool { status != .completed }
}

/// An album or playlist downloaded as a whole: its songs in their order, so Downloaded Songs can
/// list it again. A song kept by two of them is saved once.
public struct MusicDownloadedCollection: Codable, Identifiable, Hashable, Sendable {
    public internal(set) var collection: MusicCollection
    public internal(set) var trackIDs: [String]
    public internal(set) var added: Date
    /// [mi3s] 二开：多环境隔离。与歌曲同口径 —— nil 归默认环境，升级不隐藏已经下载的专辑。
    public internal(set) var environmentID: UUID?
    public var id: String { collection.id }
}

/// Downloaded songs and the queue that fetches them, beside the episode downloads. Each song is
/// resolved as playing it would be (best channel, lossless first) and saved by the same transfer
/// as an episode, so a stopped download continues and an expired link is resolved again.
@MainActor @Observable public final class MusicDownloadLibrary {
    public static let shared = MusicDownloadLibrary()
    /// A song is one file, so a couple at a time is enough to keep the connection busy.
    static let simultaneous = 2

    public private(set) var items: [MusicDownload] = []
    /// Albums and playlists downloaded from their pages, most recent first.
    public private(set) var collections: [MusicDownloadedCollection] = []
    public let root: URL
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var running: [String: (run: UUID, task: Task<Void, Never>, meter: DownloadMeter)] = [:]
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var savedAt = Date.distantPast
    /// Called each time a download starts running. The iOS app uses it to keep downloads going in the background.
    @ObservationIgnored public var onStart: (@MainActor () -> Void)?
    /// 跑着的任务数量变化时通知（与 `DownloadLibrary.onActivityChange` 同义）。
    @ObservationIgnored public var onActivityChange: (@MainActor (Bool) -> Void)?

    public init(root: URL = MusicDownloadLibrary.defaultRoot) {
        self.root = root
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var folder = root; try? folder.setResourceValues(values)
        #endif
        load()
        Task { @MainActor in self.schedule() }
    }

    /// Inside the episode downloads' folder, so the system keeps (or on tvOS clears) both alike.
    public nonisolated static var defaultRoot: URL { DownloadLibrary.defaultRoot.appending(path: "Music") }

    public var completed: [MusicDownload] { items.filter { $0.status == .completed } }
    public var pending: [MusicDownload] { items.filter(\.isPending) }
    /// Bytes the finished songs take.
    public var size: Int64 { completed.reduce(0) { $0 + $1.size } }

    public func item(for track: MusicTrack) -> MusicDownload? { item(id: track.id) }
    public func item(id: String) -> MusicDownload? { items.first { $0.id == id } }
    /// 本环境下这张专辑/歌单的条目。
    ///
    /// **必须按环境取**：`MusicDownloadedCollection.id` 是「平台+类型+专辑号」，
    /// 两个环境下同一张专辑 id 完全相同、而 `collections` 里可以同时存在两条。
    /// 用裸 `first` 时取到哪条取决于数组顺序（重下一次会把它挪到 index 0），
    /// 于是 B 环境点开专辑会列出 A 环境的歌。
    public func collection(id: String) -> MusicDownloadedCollection? {
        let active = activeEnvironmentID ?? defaultEnvironmentID
        return collections.first { $0.id == id && ($0.environmentID ?? defaultEnvironmentID) == active }
    }
    /// An album's or playlist's songs that are saved or on their way, in its order.
    /// [mi3s] 二开：本环境的专辑/歌单，页面一律从这里取。
    public var visibleCollections: [MusicDownloadedCollection] {
        let active = activeEnvironmentID ?? defaultEnvironmentID
        return collections.filter { ($0.environmentID ?? defaultEnvironmentID) == active }
    }

    /// 本条专辑下的歌。有一条 env 归属不对就不再计入 —— 同一首歌只归一个环境（见 `visibleItems`），
    /// 所以另一个环境下过的那首不该算进这张专辑的「已下载」计数，也不该列在这里。
    public func items(in collection: MusicDownloadedCollection) -> [MusicDownload] {
        let active = collection.environmentID ?? defaultEnvironmentID
        return collection.trackIDs.compactMap { id in
            items.first { $0.id == id && ($0.environmentID ?? defaultEnvironmentID) == active }
        }
    }
    /// Songs on their way that are paused, and none running or waiting: Resume All rather than Pause All.
    public var isPaused: Bool {
        pending.contains { $0.status == .paused } && !pending.contains { $0.status == .queued || $0.isActive }
    }

    // MARK: Queue

    /// Queues the songs not saved yet, in order; failed and paused ones are tried again. Songs from an
    /// album's or playlist's page remember it, so Downloaded Songs lists it with them.
    public func download(_ tracks: [MusicTrack], from collection: MusicCollection? = nil) {
        if let collection {
            // 只替换**本环境**同名的那条：另一个环境也下过同一张专辑时，两条各自保留。
            let active = activeEnvironmentID ?? defaultEnvironmentID
            collections.removeAll { $0.id == collection.id && ($0.environmentID ?? defaultEnvironmentID) == active }
            collections.insert(MusicDownloadedCollection(collection: collection, trackIDs: tracks.map(\.id),
                                                         added: Date(), environmentID: activeEnvironmentID), at: 0)
            saveCollections()
        }
        for track in tracks {
            if let existing = item(for: track) {
                if existing.status == .failed || existing.status == .paused { update(existing.id) { $0.status = .queued; $0.failure = nil } }
                // [mi3s] 二开：同一首歌在另一个环境已经存过时，本环境不再排队 —— 见 `visibleItems`
                // 的说明：一个文件一份，归属只记在首次下载它的环境。这里显式 `continue`，
                // 而不是把它算作「本环境已下」，否则本环境会显示一首自己名下没有文件的歌。
                continue
            }
            var song = MusicDownload(track: track, created: Date())
            // [mi3s] 二开：打上发起下载时的环境，列表才能只显示当前环境下的歌。
            song.environmentID = activeEnvironmentID
            items.append(song)
        }
        save(); schedule()
    }

    /// [mi3s] 二开：歌曲所属环境。与 `PlaybackHistory` 同一套口径 —— nil 归默认环境，
    /// 这样升级前下好的歌不会因为一个没写过的字段而消失。
    public var activeEnvironmentID: UUID?
    /// 默认环境 id，由 App 在 `Environments` 加载后写入。
    public var defaultEnvironmentID: UUID?

    /// 当前环境下的歌。页面一律从这里取，不要直读 `items`。
    ///
    /// **一个文件只属于一个环境。** 与视频下载不同，歌曲的 `id` 就是 `track.id`，文件夹
    /// (`folder(id)`) 与封面 (`artworkFile(for:)`，按封面 URL 哈希) 都因此是**全机唯一**的：
    /// 同一条音轨若在两个环境各存一份记录，两条会指向同一个文件夹和同一张封面，删掉其中一个
    /// 环境就把另一个环境正在用的文件和封面一起删了。所以这里刻意不做「一个环境一份」，
    /// 而是一份文件归首次下载它的那个环境，另一个环境当作没下过（可以照常在线听）。
    public var visibleItems: [MusicDownload] {
        let active = activeEnvironmentID ?? defaultEnvironmentID
        return items.filter { ($0.environmentID ?? defaultEnvironmentID) == active }
    }
    /// 当前环境下已下好的歌。
    public var visibleCompleted: [MusicDownload] { visibleItems.filter { $0.status == .completed } }
    /// 当前环境下还在队列里的歌。
    public var visiblePending: [MusicDownload] { visibleItems.filter(\.isPending) }
    /// 当前环境下这些字节的合计。
    public var visibleSize: Int64 { visibleCompleted.reduce(0) { $0 + $1.size } }

    /// 本环境下这首歌的下载记录；另一环境存过的那首在这里是 nil。
    public func visibleItem(for track: MusicTrack) -> MusicDownload? {
        let active = activeEnvironmentID ?? defaultEnvironmentID
        return items.first {
            $0.id == track.id && ($0.environmentID ?? defaultEnvironmentID) == active
        }
    }

    /// Whether some *other* environment already keeps this song on disk or on its way. The download
    /// page asks so it can say "已在另一个环境下载" instead of quietly doing nothing when the queue
    /// ignores it. Any status counts, because `download(_:from:)` skips on any existing record —
    /// the two must agree, or the page promises a download the queue will not start.
    public func isSavedInAnotherEnvironment(_ track: MusicTrack) -> Bool {
        let active = activeEnvironmentID ?? defaultEnvironmentID
        return items.contains {
            $0.id == track.id && ($0.environmentID ?? defaultEnvironmentID) != active
        }
    }

    /// Puts a failed download back in the queue.
    public func retry(_ id: String) {
        guard let item = item(id: id), item.status == .failed || item.status == .paused else { return }
        update(id) { $0.status = .queued; $0.failure = nil }
        save(); schedule()
    }

    /// Stops and deletes songs, saved or not, with covers no other saved song shows.
    public func remove(_ ids: [String]) {
        let covers = Set(items.filter { ids.contains($0.id) }.compactMap(\.track.artwork))
        // ⛔ 必须在 `items.removeAll` **之前**取：之后再算就只剩空集合，
        // 于是「受影响环境」永远为空、专辑条目一个都不修剪，删歌后专辑卡片会一直挂着。
        let removed = Set(ids)
        let removedEnvironments = Set(
            items.filter { removed.contains($0.id) }.map { $0.environmentID ?? defaultEnvironmentID }
        )
        for id in ids {
            stop(id)
            try? FileManager.default.removeItem(at: folder(id))
        }
        items.removeAll { ids.contains($0.id) }
        let kept = Set(items.compactMap(\.track.artwork))
        for cover in covers.subtracting(kept) { try? FileManager.default.removeItem(at: Self.artworkFile(for: cover)) }
        // An album or playlist goes once none of its songs is left.
        //
        // 只修剪**受影响环境**的条目：`trackIDs` 存的是裸 `track.id`，两个环境的条目可能都
        // 列着同一个 id。不按环境过滤的话，删 A 会把 B 的条目悄悄剪掉一首。
        collections = collections.compactMap { entry in
            var entry = entry
            guard removedEnvironments.contains(entry.environmentID ?? defaultEnvironmentID) else { return entry }
            entry.trackIDs.removeAll { removed.contains($0) }
            return entry.trackIDs.isEmpty ? nil : entry
        }
        save(); saveCollections(); schedule()
    }

    /// Deletes the songs that belong to one environment, used when that environment is removed.
    ///
    /// A song is stored once per device (see `visibleItems`), so this cannot take a file away from
    /// another environment: the records it deletes are the only ones naming those folders. Legacy
    /// `nil` records count as the default environment, matching `visibleItems`.
    public func delete(environment: UUID) {
        let doomed = items.filter { ($0.environmentID ?? defaultEnvironmentID) == environment }
        if !doomed.isEmpty { remove(doomed.map(\.id)) }
        // 这条环境的专辑/歌单条目也要走 —— 否则删了环境，「已下载的专辑」卡片还在，
        // 而它底下的歌已经没了。
        let doomedCollections = collections.filter { ($0.environmentID ?? defaultEnvironmentID) == environment }
        guard !doomedCollections.isEmpty else { return }
        let removed = Set(doomedCollections.map(\.id))
        collections.removeAll { removed.contains($0.id) && ($0.environmentID ?? defaultEnvironmentID) == environment }
        saveCollections()
    }

    /// Empties the list and the disk, including what the list lost track of.
    public func removeAll() {
        for id in Array(running.keys) { stop(id) }
        items.removeAll()
        collections.removeAll()
        // The whole folder, not per-song folders: a song whose record never persisted still has a folder.
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        save(); saveCollections(); schedule()
    }

    /// Removes an album or playlist with its songs, except those another saved one also keeps.
    public func remove(collection id: String) {
        let active = activeEnvironmentID ?? defaultEnvironmentID
        guard let entry = collection(id: id) else { return }
        // 只删**本环境**那一条：两个环境下同一张专辑各有一条独立条目，
        // 裸 `removeAll { $0.id == id }` 会把另一条也清掉，并把它的歌一起删了。
        collections.removeAll { $0.id == id && ($0.environmentID ?? defaultEnvironmentID) == active }
        let shared = Set(collections.flatMap(\.trackIDs))
        remove(entry.trackIDs.filter { !shared.contains($0) })
    }

    /// Forgets saved songs whose file is gone: deleted or moved away in Finder, or cleared by tvOS to
    /// free space. They play from the network again and can be downloaded again.
    public func forgetMissing() {
        let missing = items.filter { $0.status == .completed && !hasMedia($0) }.map(\.id)
        if !missing.isEmpty { remove(missing) }
    }

    /// Stops every song on its way and keeps it paused, also after a relaunch, until `resumeAll()`.
    public func pauseAll() {
        for item in items where item.status == .queued || item.isActive {
            stop(item.id)
            update(item.id) { $0.status = .paused }
        }
        save(); schedule()
    }

    /// Puts every failed song back in the queue.
    public func retryFailed() {
        for item in items where item.status == .failed { update(item.id) { $0.status = .queued; $0.failure = nil } }
        save(); schedule()
    }

    /// Puts paused songs back in the queue; they continue from where they stopped.
    public func resumeAll() {
        for item in items where item.status == .paused { update(item.id) { $0.status = .queued } }
        save(); schedule()
    }

    /// Stops running downloads without failing them, for when the app goes to the background:
    /// they continue from where they were on `wake()`.
    public func suspend() {
        // [mi3s] 二开：全部暂停时把在跑的条目退回 queued（上游只 stop 不改状态，
        // 恢复后这些条目仍显示为正在下载）。索引读写统一走 JSONFileStore --
        // 上游裸 Data(contentsOf:)/write，无原子写与损坏容忍。
        for id in Array(running.keys) { stop(id); update(id) { $0.status = .queued } }
        save()
    }
    public func wake() { schedule() }

    private func schedule() {
        let before = running.count
        for item in items where item.status == .queued {
            guard running.count < Self.simultaneous else { break }
            start(item.id)
        }
        // 与 `DownloadLibrary.schedule()` 同一条契约：跑着的数量变了才通知。
        // 「下载时保持屏幕常亮」靠它收回 —— 只有 onStart 没有 onActivityChange，
        // 压住自动锁屏的那次调用就永远不会撤销。
        if running.count != before { onActivityChange?(!running.isEmpty) }
        if running.isEmpty { ticker?.cancel(); ticker = nil }
        else if ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    self?.tick()
                }
            }
        }
    }

    private func start(_ id: String) {
        guard let track = item(id: id)?.track else { return }
        let run = UUID(), meter = DownloadMeter(), folder = folder(id)
        update(id) { $0.status = .downloading; $0.failure = nil }
        let transfer = Transfer(folder: folder, meter: meter, session: session, resolve: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.resolve(id, run: run)
        }, note: { [weak self] note in
            await self?.apply(note, to: id, run: run)
        })
        let task = Task { [weak self] in
            do {
                let media = try await transfer.run()
                // Lyrics and the cover are extras: the song is saved without them if they fail.
                let platform = self?.item(id: id)?.candidate?.platform
                if let lyrics = await MusicLyricsLoader().lyrics(for: track, playing: platform), let data = try? JSONEncoder().encode(lyrics) {
                    try? data.write(to: folder.appending(path: "lyrics.json"), options: .atomic)
                }
                await Self.saveArtwork(track.artwork)
                let size = DownloadLibrary.allocatedSize(folder)
                self?.finish(id, run: run) { $0.status = .completed; $0.media = media; $0.size = size; $0.finished = Date(); $0.received = size }
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                Diagnostics.shared.failure("music", "download failed", error)
                self?.finish(id, run: run) { $0.status = .failed; $0.failure = error.localizedDescription }
            }
        }
        running[id] = (run, task, meter)
        onStart?()
    }

    /// Finds the song's channel now, as playing it would, and remembers which it was. The
    /// transfer asks again when the address expires.
    private func resolve(_ id: String, run: UUID) async throws -> Channel {
        guard let track = item(id: id)?.track else { throw CancellationError() }
        let preferences = MusicPreferences.load()
        let selection = try await MusicResolver(preferences: preferences).select(track, preference: preferences.quality)
        guard running[id]?.run == run else { throw CancellationError() }
        update(id) { $0.candidate = selection.candidate; $0.probe = selection.probe }
        Diagnostics.shared.record(.info, "music", "download \(selection.candidate.provider.rawValue) \(selection.probe.format.label)")
        return Channel(name: track.title, url: selection.stream.url, headers: selection.stream.headers)
    }

    private func apply(_ note: TransferNote, to id: String, run: UUID) {
        guard running[id]?.run == run else { return }
        switch note {
        case .prepared(let plan): update(id) { $0.expected = plan.expected }; tick()
        case .finishing: update(id) { $0.status = .finishing }
        }
    }

    private func finish(_ id: String, run: UUID, _ change: (inout MusicDownload) -> Void) {
        guard running[id]?.run == run else { return }
        tick()
        running[id] = nil
        update(id, change)
        save(); schedule()
    }

    private func stop(_ id: String) {
        running[id]?.task.cancel()
        running[id] = nil
    }

    private func tick() {
        for (id, entry) in running {
            let value = entry.meter.snapshot
            update(id) { item in
                item.received = value.received
                if let expected = value.expected { item.expected = expected }
            }
        }
        if Date().timeIntervalSince(savedAt) > 5 { save() }
    }

    private func update(_ id: String, _ change: (inout MusicDownload) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    // MARK: Playback

    /// The saved file as the song's channel, when it is on this device.
    public func localSelection(for track: MusicTrack) -> MusicPlaybackSelection? {
        guard let item = item(for: track), item.status == .completed, let media = item.media,
              let candidate = item.candidate, let probe = item.probe else { return nil }
        let file = folder(item.id).appending(path: media)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return MusicPlaybackSelection(track: track, candidate: candidate, stream: ResolvedMusicStream(url: file), probe: probe,
                                      degraded: !probe.format.isLossless, attempts: [], untried: [])
    }

    /// The lyrics saved with a song, if it had any.
    public func lyrics(for track: MusicTrack) -> MusicLyrics? {
        guard item(for: track)?.status == .completed,
              let data = try? Data(contentsOf: folder(track.id).appending(path: "lyrics.json")) else { return nil }
        return try? JSONDecoder().decode(MusicLyrics.self, from: data)
    }

    /// Where a saved song's cover is kept, by its address; the artwork loader looks here before
    /// the network. Songs of one album share it.
    public nonisolated static func artworkFile(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return defaultRoot.appending(path: "Artwork").appending(path: digest)
    }

    private nonisolated static func saveArtwork(_ url: URL?) async {
        guard let url else { return }
        let file = artworkFile(for: url)
        guard !FileManager.default.fileExists(atPath: file.path), let data = try? await HTTPClient().get(url).0 else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    // MARK: Persistence

    /// Song IDs hold ":"; the folder name keeps only letters and digits plain.
    func folder(_ id: String) -> URL { root.appending(path: id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id) }
    private var index: URL { root.appending(path: "music-downloads.json") }
    private var collectionIndex: URL { root.appending(path: "music-collections.json") }
    private var store: JSONFileStore<[MusicDownload]> { JSONFileStore(file: index) }
    private var collectionStore: JSONFileStore<[MusicDownloadedCollection]> { JSONFileStore(file: collectionIndex) }
    private func hasMedia(_ item: MusicDownload) -> Bool {
        guard let media = item.media else { return false }
        return FileManager.default.fileExists(atPath: folder(item.id).appending(path: media).path)
    }

    /// 切环境后把「正在下、但属于别的环境」的任务停掉。
    ///
    /// 下载队列是全局的（一首歌只归一个环境），但换环境后继续为看不见的队列跑没有意义：
    /// 用户已经不在那个环境里，进度也不在眼前。记录本身保留，切回去仍是排队/可续。
    public func pauseWorkForOtherEnvironments() {
        let active = activeEnvironmentID ?? defaultEnvironmentID
        for item in items where item.isActive && (item.environmentID ?? defaultEnvironmentID) != active {
            stop(item.id)
            // 必须写回 `.queued`（与 `suspend()` 一致）：`stop` 只取消 task、不动状态，
            // 记录会永远停在 `.downloading` —— `schedule()` 只捡 `.queued` 所以切回来也不会
            // 重跑，而且 `isActive` 恒真会让 `hasWork` 恒真（屏幕常亮 + 后台任务常驻）。
            update(item.id) { $0.status = .queued }
        }
        if !items.isEmpty { save() }
    }

    private func load() {
        if let stored = collectionStore.load() {
            collections = stored
        }
        guard let stored = store.load() else { return }
        items = stored.compactMap { item in
            var item = item
            if item.status == .completed {
                // tvOS may have cleared the folder to free space, or the file was moved away.
                guard hasMedia(item) else { return nil }
            } else if item.isActive {
                item.status = .queued
            }
            return item
        }
        let kept = Set(items.map(\.id))
        collections = collections.compactMap { entry in
            var entry = entry
            entry.trackIDs.removeAll { !kept.contains($0) }
            return entry.trackIDs.isEmpty ? nil : entry
        }
    }

    private func save() {
        savedAt = Date()
        store.save(items)
    }

    private func saveCollections() {
        collectionStore.save(collections)
    }
}
