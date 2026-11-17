import Foundation
import Observation

/// Where a download came from: enough to resolve the episode again when its links expire.
public struct DownloadSource: Codable, Hashable, Sendable {
    public let siteKey: String
    public let siteName: String
    public let videoID: String
    public let episodeID: String
    public let episodeName: String
    public let address: String
    public let flag: String
    public let detailID: String?
    // [mi3s] 二开：记录来源订阅（隐私保险库需要）。上游的下载项不带 origin —— 保险库
    // 只能隐藏「能同时说出 origin 与 siteKey」的下载，所以这里补上。为 nil 表示
    // 该字段出现之前存的旧记录，或保存时不知道来源订阅的裸源；nil 一律保持可见。
    /// The subscription this source came from, for the Privacy Vault. Nil for downloads saved before
    /// this field existed, and for a bare source whose subscription origin was not known at save time.
    /// The vault only hides a download whose origin and key it can name, so a nil origin stays visible.
    public let origin: URL?
    /// The source's original key (`Site.sourceKey`), which the vault matches on. Kept beside `siteKey`
    /// because a merged subscription can rename a clashing key, and the vault's identity uses the
    /// original one. Defaults to `siteKey` for downloads saved before this field existed.
    public let sourceKey: String
    public init(site: Site, videoID: String, episode: Episode, origin: URL? = nil) {
        siteKey = site.key; siteName = site.name; self.videoID = videoID
        episodeID = episode.id; episodeName = episode.name; address = episode.address; flag = episode.flag; detailID = episode.videoID
        self.origin = origin ?? site.provenance?.origin
        sourceKey = site.sourceKey
    }
    public var episode: Episode { Episode(id: episodeID, name: episodeName, address: address, flag: flag, videoID: detailID) }
    /// The same episode, on the same source and line.
    public var key: String { [siteKey, videoID, flag, episodeID].joined(separator: "\u{1F}") }

    private enum CodingKeys: String, CodingKey {
        case siteKey, siteName, videoID, episodeID, episodeName, address, flag, detailID, origin, sourceKey
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        siteKey = try c.decode(String.self, forKey: .siteKey)
        siteName = try c.decode(String.self, forKey: .siteName)
        videoID = try c.decode(String.self, forKey: .videoID)
        episodeID = try c.decode(String.self, forKey: .episodeID)
        episodeName = try c.decode(String.self, forKey: .episodeName)
        address = try c.decode(String.self, forKey: .address)
        flag = try c.decode(String.self, forKey: .flag)
        detailID = try c.decodeIfPresent(String.self, forKey: .detailID)
        origin = try c.decodeIfPresent(URL.self, forKey: .origin)
        sourceKey = try c.decodeIfPresent(String.self, forKey: .sourceKey) ?? siteKey
    }
}

extension DownloadItem {
    /// The history entry the episode has when it streams from its source, so playing the saved copy records the
    /// same progress and the same Continue Watching (#960). Nil once the source is no longer in the subscription.
    public func historyContext(in subscription: Subscription?) -> PlaybackHistoryContext? {
        guard let subscription, let site = subscription.sites.first(where: { $0.key == source.siteKey }) else { return nil }
        var context = PlaybackHistoryContext(origin: site.origin(or: subscription.origin), sourceKey: site.sourceKey, sourceName: site.name,
                                             videoID: source.videoID, videoName: title, poster: poster,
                                             episodeID: source.episodeID, episodeName: source.episodeName, episodeFlag: source.flag)
        context.posterHeaders = posterHeaders.isEmpty ? nil : posterHeaders
        context.officialPage = OfficialVideoPage.validated(source.address)
        return context
    }
}

public struct DownloadItem: Codable, Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Waiting for a free slot in the queue.
        case queued
        case downloading
        /// Joining or writing the final file.
        case finishing
        case paused, completed, failed
    }
    public enum Kind: String, Codable, Sendable { case file, hls, dash }
    public let id: String
    public let title: String
    public let episode: String
    public let poster: URL?
    public let posterHeaders: [String: String]
    public let source: DownloadSource
    public let created: Date
    public internal(set) var status: Status = .queued
    public internal(set) var failure: String?
    public internal(set) var kind: Kind?
    /// Quality label ("1080P") when the source names one.
    public internal(set) var quality: String?
    public internal(set) var received: Int64 = 0
    /// Total bytes: exact for files, estimated from finished segments for HLS.
    public internal(set) var expected: Int64?
    public internal(set) var completedParts = 0
    public internal(set) var totalParts = 0
    /// The playable file, relative to the download's folder.
    public internal(set) var media: String?
    /// Bytes on disk once finished.
    public internal(set) var size: Int64 = 0
    /// Sockets actually carrying this download right now, and how fast they are going together.
    /// The pair is what makes an accelerator legible: 8 sockets at 12 MB/s reads differently from
    /// 1 socket at 1.5 MB/s, and only the number tells you which one you got.
    public internal(set) var connections: Int = 0
    public internal(set) var speed: Double = 0
    public internal(set) var finished: Date?
    public internal(set) var cid: String?
    public internal(set) var duration: Double?
    /// [mi3s] 二开：多环境隔离。下载发起时打上当时的 `environments.activeID`，
    /// 列表按当前环境过滤（见 `DownloadsView.visibleItems`）。nil = environments 出现
    /// 之前写入的旧记录，归默认环境 —— 升级不隐藏已有下载。
    public internal(set) var environmentID: UUID?

    /// 0...1, by bytes where the total is known, else by pieces.
    public var fraction: Double {
        if status == .completed { return 1 }
        if kind != .hls, let expected, expected > 0 { return min(1, Double(received) / Double(expected)) }
        return totalParts > 0 ? Double(completedParts) / Double(totalParts) : 0
    }
    public var isActive: Bool { status == .downloading || status == .finishing }
    /// Not finished: running, waiting, paused or failed.
    public var isPending: Bool { status != .completed }

    /// One show's episodes in episode order, by name without what drive sources put around it: a size tag first
    /// ("[2.3GB]Show.S09E16.mkv" sorted before "[2.9GB]Show.S09E15.mkv", so 14 played on into 16, #1022), the share's tag
    /// and the file extension. Each name is cleaned once.
    public static func inEpisodeOrder(_ items: [DownloadItem]) -> [DownloadItem] {
        items.map { (key: EpisodeLabels.clean($0.episode), item: $0) }.sorted { a, b in
            let order = a.key.localizedStandardCompare(b.key)
            if order != .orderedSame { return order == .orderedAscending }
            return a.item.episode.localizedStandardCompare(b.item.episode) == .orderedAscending
        }.map(\.item)
    }
}

/// Downloaded episodes and the queue that fetches them. A fixed number of downloads run at once
/// (`simultaneous`); the rest wait in order. Progress survives pausing, quitting and expired links:
/// each download keeps its finished pieces on disk and resolves the episode again when needed.
@MainActor @Observable public final class DownloadLibrary {
    public static let shared = DownloadLibrary()
    /// Addresses of downloaded episodes for the player: `tvbox-download://<id>`.
    public static let scheme = "tvbox-download"

    public private(set) var items: [DownloadItem] = []
    /// Bytes per second for each running download, smoothed over a few seconds.
    public private(set) var rates: [String: Double] = [:]
    /// Disk use, refreshed by `measure()`.
    public private(set) var usage = Usage()
    public struct Usage: Sendable, Equatable {
        public var downloads: Int64 = 0
        public var available: Int64?
        public var capacity: Int64?
    }
    /// How many downloads run at once, 1 to 8. Kept on the library because the queue is what it governs;
    /// the value lives in `DownloadSettings` so the two knobs beside it do too.
    public var simultaneous: Int {
        get { settings.tuning.parallel }
        set {
            settings.set(parallel: newValue)
            schedule()
        }
    }
    /// Range requests per file, range size in MB, and files at once — the three knobs One exposes.
    @ObservationIgnored public let settings: DownloadSettings
    /// Resolves an episode to its current media address; set by the app, which knows the sources.
    @ObservationIgnored public var resolver: (@MainActor @Sendable (DownloadItem) async throws -> Channel)?
    /// Called each time a download starts running. The iOS app uses it to keep downloads going in the background.
    @ObservationIgnored public var onStart: (@MainActor () -> Void)?
    /// Called whenever the set of running downloads changes — a start, a finish, a pause, a removal.
    ///
    /// 存在的理由只有一个：**「下载时保持屏幕常亮」必须能自己关掉**。
    /// 只有 `onStart` 而没有「结束」信号时，压住自动锁屏的那一次调用永远不会被撤销，
    /// 用户下完一集之后手机再也睡不着 —— 比不加这个功能更糟。
    /// `schedule()` 是唯一知道「现在到底还有几个在跑」的地方，所以由它发。
    @ObservationIgnored public var onActivityChange: (@MainActor (Bool) -> Void)?

    public let root: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var running: [String: (run: UUID, task: Task<Void, Never>, meter: DownloadMeter, speed: SpeedMeter)] = [:]
    @ObservationIgnored private var samples: [String: (date: Date, bytes: Int64)] = [:]
    /// The live knobs each running transfer shares, so a change reaches it mid-file.
    @ObservationIgnored private var boxes: [String: TuningBox] = [:]
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var savedAt = Date.distantPast

    public init(root: URL = DownloadLibrary.defaultRoot, defaults: UserDefaults = .standard,
                settings: DownloadSettings = .shared) {
        self.root = root; self.defaults = defaults; self.settings = settings
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        // The limit is per host, so it must be at least the sockets one file opens, or URLSession would
        // queue the very ranges this download exists to run in parallel.
        configuration.httpMaximumConnectionsPerHost = max(8, settings.tuning.sockets)
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var folder = root; try? folder.setResourceValues(values)
        #endif
        load()
        // A knob turned in Settings reaches the files already in flight, not just the next one.
        settings.onTuning = { [weak self] tuning in
            guard let self else { return }
            for box in self.boxes.values { box.value = tuning }
            self.session.configuration.httpMaximumConnectionsPerHost = max(8, tuning.sockets)
            self.schedule()
        }
        // Downloads that were running when the app quit wait for the app to set `resolver`.
        Task { @MainActor in self.schedule() }
    }

    /// tvOS gives apps no lasting storage besides Caches, which the system may clear when space runs low.
    public nonisolated static var defaultRoot: URL {
        #if os(tvOS)
        URL.cachesDirectory.appending(path: "Downloads")
        #elseif os(macOS)
        URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "Yingxia").appending(path: "Downloads")
        #else
        URL.applicationSupportDirectory.appending(path: "Downloads")
        #endif
    }

    // MARK: Queue

    /// Adds an episode to the queue. Already downloaded or queued episodes are left as they are;
    /// a failed one is retried. Returns the episode's download.
    @discardableResult
    public func download(_ source: DownloadSource, title: String, poster: URL?, posterHeaders: [String: String] = [:], environmentID: UUID? = nil) -> DownloadItem {
        // 去重只在**这次下载要落到的那个环境**里做：同一个地址在另一个环境下是一条独立记录，
        // 拿它的条目返回会让 B 环境点下载看起来「已经有了」而其实什么都没下。
        let target = environmentID ?? activeEnvironmentID
        if let existing = item(for: source, environment: target) {
            if existing.status == .failed || existing.status == .paused { resume(existing.id) }
            return existing
        }
        let item = DownloadItem(id: UUID().uuidString.lowercased(), title: title, episode: source.episodeName, poster: poster,
                                posterHeaders: posterHeaders, source: source, created: Date(), environmentID: target)
        items.append(item)
        save()
        schedule()
        return item
    }

    /// 某环境下这一集的记录（nil 归默认环境）。`download` 的去重与详情页的「下过没有」都用它。
    func item(for source: DownloadSource, environment: UUID?) -> DownloadItem? {
        let target = environment ?? defaultEnvironmentID
        return items.first {
            $0.source.key == source.key && ($0.environmentID ?? defaultEnvironmentID) == target
        }
    }

    public func item(for source: DownloadSource) -> DownloadItem? { items.first { $0.source.key == source.key } }
    public func item(id: String) -> DownloadItem? { items.first { $0.id == id } }

    /// [mi3s] 二开：下载所属环境的两个出口。记录自带 `environmentID`（nil 归默认环境），
    /// 页面和「这一集下过没有」的判断都从这里取，避免再出现「切了环境还看得见」或
    /// 「新环境里那一集显示已下载、点了却播不了」。
    /// 默认环境 id 由 App 在 `Environments` 加载后写入。
    public var defaultEnvironmentID: UUID?
    /// 当前环境 id，由 App 跟着 `Environments.activeID` 保持同步。
    public var activeEnvironmentID: UUID?

    /// `items` 里属于当前环境的那些。
    public func visibleItems() -> [DownloadItem] {
        let active = activeEnvironmentID ?? defaultEnvironmentID
        return items.filter { ($0.environmentID ?? defaultEnvironmentID) == active }
    }
    /// 当前环境里这一集的下载记录。另一环境下过的那一集在这里是 nil —— 它确实还不能在本环境播。
    public func visibleItem(for source: DownloadSource) -> DownloadItem? {
        let active = activeEnvironmentID ?? defaultEnvironmentID
        return items.first { $0.source.key == source.key && ($0.environmentID ?? defaultEnvironmentID) == active }
    }

    /// 删掉某一环境下的下载记录和文件，用于删除环境。
    ///
    /// 每条记录有自己的 id 和文件夹，所以另一个环境下过同一集时它是一条**独立记录**、
    /// 独立文件，删这一环境的不会动到那一条。
    public func delete(environment: UUID) {
        let doomed = items.filter { ($0.environmentID ?? defaultEnvironmentID) == environment }
        guard !doomed.isEmpty else { return }
        remove(doomed.map(\.id))
    }

    public func pause(_ id: String) {
        guard let item = item(id: id), item.isPending, item.status != .failed else { return }
        stop(id)
        update(id) { $0.status = .paused }
        save(); schedule()
    }

    /// Puts a paused or failed download back in the queue.
    public func resume(_ id: String) {
        guard let item = item(id: id), item.status == .paused || item.status == .failed else { return }
        update(id) { $0.status = .queued; $0.failure = nil }
        save(); schedule()
    }

    /// Moves a waiting download to the front of the queue.
    public func prioritize(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status == .queued,
              let first = items.firstIndex(where: { $0.status == .queued }), first < index else { return }
        items.insert(items.remove(at: index), at: first)
        save()
    }

    public func remove(_ ids: [String]) {
        for id in ids {
            stop(id)
            try? FileManager.default.removeItem(at: folder(id))
        }
        items.removeAll { ids.contains($0.id) }
        save(); schedule()
        Task { await measure() }
    }

    /// Empties the list and the disk: every running transfer stops, every folder goes, and anything the
    /// list does not know about goes with them.
    ///
    /// The orphans are the reason this is not just `remove(items.map(\.id))`: a crash leaves a folder whose
    /// plan names a download that never made it into `downloads.json`, and on a phone those gigabytes are
    /// invisible until the storage bar is full.
    public func removeAll() {
        // Stop first, then wait for the lanes to actually let go: deleting the root while a lane is
        // still in `pwrite` leaves that write failing into a removed directory, and on iOS that
        // surfaces as a download that "finished" with zero bytes.
        for id in Array(running.keys) { stop(id) }
        boxes.removeAll()
        let ids = Set(items.map(\.id))
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        items.removeAll()
        rates.removeAll(); samples.removeAll(); boxes.removeAll()
        save()
        Task { await measure() }
        Diagnostics.shared.record(.info, "download", "cleared (ids.count) downloads folder=(root.lastPathComponent)")
    }

    /// Deletes folders the list does not know about: left behind by a crash, or by a version that saved a
    /// plan before the download was recorded. Cheap to run, so `measure()` does.
    public func purgeOrphans() {
        let known = Set(items.map(\.id))
        // Folders this instance is actively writing are not orphans, whatever the list says: a
        // download whose record has not been saved yet (the first second of its life, or a plan being
        // built after a renew) would otherwise be deleted from under the sockets writing into it.
        let live = Set(running.keys).union(boxes.keys)
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for url in contents {
            let name = url.lastPathComponent
            // ⛔ 只删**下载文件夹**（名字是 `UUID().uuidString.lowercased()`，见 `download(_:…)`）。
            //
            // 不能只豁免 `downloads.json`：音乐库的根目录是 `<Downloads>/Music`
            // （`MusicDownloadLibrary.defaultRoot`），是这里 root 的**子目录**且名字不是任何
            // download id。按「不在 known 里就删」的老写法，进一次下载页（`measure()` 会调
            // 这里）就把整棵音乐库连同 `music-downloads.json` 递归删掉 —— 所有下载的歌与
            // 专辑记录一起消失，且索引没了、重启也恢复不了。
            //
            // 用「是否形如 UUID 目录」当判据，而不是逐个列白名单：以后再加子目录
            // （封面、缓存、临时文件）就不会重蹈覆辙。
            guard Self.isDownloadFolderName(name) else { continue }
            guard !known.contains(name), !live.contains(name) else { continue }
            try? FileManager.default.removeItem(at: url)
            Diagnostics.shared.record(.info, "download", "purged orphan folder=\(name)")
        }
    }

    /// Whether a directory name in the downloads root is one of ours (a download's own folder).
    ///
    /// Downloads are named `UUID().uuidString.lowercased()`; anything else in that root — the index
    /// file, the Music library subdirectory, future side stores — must never be treated as an orphan.
    nonisolated static func isDownloadFolderName(_ name: String) -> Bool {
        UUID(uuidString: name) != nil
    }

    public func pauseAll() {
        for item in items where item.status == .queued || item.isActive { stop(item.id); update(item.id) { $0.status = .paused } }
        save(); schedule()
    }

    public func resumeAll() {
        for item in items where item.status == .paused || item.status == .failed { update(item.id) { $0.status = .queued; $0.failure = nil } }
        save(); schedule()
    }

    /// Stops running downloads without pausing them, for when the app goes to the background:
    /// they continue from where they were on `wake()`.
    public func suspend() {
        for id in Array(running.keys) { stop(id); update(id) { $0.status = .queued } }
        save()
    }
    public func wake() { schedule() }

    /// Starts waiting downloads, oldest first, while fewer than `simultaneous` run.
    private func schedule() {
        guard resolver != nil else { return }
        let before = running.count
        for item in items where item.status == .queued {
            guard running.count < simultaneous else { break }
            start(item.id)
        }
        // 只有「跑着的数量」真的变了才发通知：`schedule()` 被 save/pause/remove/wake 各条
        // 路径反复调用，每次无条件通知会让 `isIdleTimerDisabled` 每秒被写一遍。
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
        let run = UUID(), meter = DownloadMeter(), speed = SpeedMeter()
        update(id) { $0.status = .downloading; $0.failure = nil }
        let folder = folder(id)
        let box = TuningBox(settings.tuning)
        boxes[id] = box
        let transfer = Transfer(folder: folder, meter: meter, session: session, tuning: box, speed: speed, resolve: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.resolve(id)
        }, note: { [weak self] note in
            await self?.apply(note, to: id, run: run)
        })
        let task = Task { [weak self] in
            do {
                let media = try await transfer.run()
                let size = Self.allocatedSize(folder)
                self?.finish(id, run: run) { $0.status = .completed; $0.media = media; $0.size = size; $0.finished = Date(); $0.received = size }
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                Diagnostics.shared.failure("download", "failed id=\(id)", error)
                self?.finish(id, run: run) { $0.status = .failed; $0.failure = error.localizedDescription }
            }
        }
        running[id] = (run, task, meter, speed)
        onStart?()
    }

    private func resolve(_ id: String) async throws -> Channel {
        guard let resolver, let item = item(id: id) else { throw CancellationError() }
        return try await resolver(item)
    }

    private func apply(_ note: TransferNote, to id: String, run: UUID) {
        guard running[id]?.run == run else { return }
        switch note {
        case .prepared(let plan):
            update(id) {
                $0.kind = DownloadItem.Kind(rawValue: plan.kind.rawValue)
                $0.quality = plan.label; $0.cid = plan.cid; $0.duration = plan.duration
                $0.expected = plan.expected
            }
            tick()
        case .finishing:
            update(id) { $0.status = .finishing }
        }
    }

    private func finish(_ id: String, run: UUID, _ change: (inout DownloadItem) -> Void) {
        guard let entry = running[id], entry.run == run else { return }
        // The last tick before the row settles: without it a finished download keeps the rate it had
        // a second ago, and a paused one keeps it forever.
        entry.speed.settle()
        tick()
        running[id] = nil; samples[id] = nil; rates[id] = nil; boxes[id] = nil
        update(id, change)
        save(); schedule()
        Task { await measure() }
    }

    private func stop(_ id: String) {
        running[id]?.task.cancel()
        running[id] = nil; samples[id] = nil; rates[id] = nil; boxes[id] = nil
    }

    /// Copies running downloads' counters into their items and works out speeds.
    private func tick() {
        let now = Date()
        for (id, entry) in running {
            let value = entry.meter.snapshot
            entry.speed.sample(value.received)
            update(id) { item in
                item.received = value.received; item.completedParts = value.parts; item.totalParts = value.total
                if !item.isActive { item.speed = 0 }
                if item.kind == .hls, value.parts > 0, value.total > 0 {
                    item.expected = Int64(Double(value.received) / Double(value.parts) * Double(value.total))
                } else if let expected = value.expected { item.expected = expected }
                // Both move with the transfer, so they belong on the item the page is already reading.
                item.speed = entry.speed.speed
                // The peak, not the instant: a lane between two ranges is closed for a moment, and a
                // number that flickers to zero reads as a bug rather than as a finished request.
                if entry.speed.activeConnections > 0 { item.connections = entry.speed.activeConnections }
                else { item.connections = max(item.connections, entry.speed.peakConnections) }
            }
            // The meter has the true rate now; the queue's own sampler stays for rows whose speed comes
            // from the item rather than from a live meter.
            if entry.speed.speed > 0 { rates[id] = entry.speed.speed }
            if let last = samples[id], now.timeIntervalSince(last.date) > 0.5 {
                let rate = max(0, Double(value.received - last.bytes) / now.timeIntervalSince(last.date))
                if rates[id] == nil { rates[id] = rate }
            }
            samples[id] = (now, value.received)
        }
        if now.timeIntervalSince(savedAt) > 5 { save() }
    }

    private func update(_ id: String, _ change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    // MARK: Playback

    /// The finished download `offset` places from the one `url` plays, among its show's saved episodes in the
    /// order Downloads lists them: what the player's Previous and Next reach, and what plays on after it.
    public func neighbor(of url: URL, offset: Int) -> DownloadItem? {
        guard url.scheme == Self.scheme, let id = url.host(), let current = item(id: id) else { return nil }
        let show = DownloadItem.inEpisodeOrder(items.filter {
            $0.status == .completed && $0.source.siteKey == current.source.siteKey && $0.source.videoID == current.source.videoID
        })
        guard let index = show.firstIndex(where: { $0.id == id }), show.indices.contains(index + offset) else { return nil }
        return show[index + offset]
    }

    /// What the player opens for a finished download: under the episode's history entry when there is one
    /// (`DownloadItem.historyContext(in:)`), so it records progress and opens where it stopped.
    public func channel(for item: DownloadItem, context: PlaybackHistoryContext? = nil, resumePosition: Double? = nil) -> Channel {
        Channel(name: "\(item.title) · \(item.episode)", group: L10n.text("Offline Cache"), url: URL(string: "\(Self.scheme)://\(item.id)")!,
                skipScope: context?.id, historyContext: context, resumePosition: resumePosition)
    }

    /// The file (or, for HLS, the loopback address) that plays a `tvbox-download://` address. An HDR MKV saved
    /// before downloads became MP4s is rewrapped first, which `progress` follows (0...1).
    public func playbackAddress(for url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        guard url.scheme == Self.scheme, let id = url.host(), let item = item(id: id), item.status == .completed, var media = item.media else {
            throw TVError.unsupported(L10n.text("This cached video is no longer on this device."))
        }
        var file = folder(id).appending(path: media)
        guard FileManager.default.fileExists(atPath: file.path) else {
            // Deleted or moved away in Finder: stop listing it as downloaded.
            remove([id])
            throw TVError.unsupported(L10n.text("This cached video is no longer on this device."))
        }
        if Remux.handles(name: media) {
            let rewrapped = await Self.rewrap(media, in: folder(id), progress: progress)
            try Task.checkCancellation()
            if rewrapped != media {
                media = rewrapped
                file = folder(id).appending(path: media)
                let size = Self.allocatedSize(folder(id))
                update(id) { $0.media = rewrapped; $0.size = size }
                save()
            }
        }
        if let cid = item.cid { DanmakuSource.register(url, bilibiliCID: cid, duration: item.duration) }
        if media.hasSuffix(".m3u8") { return try await LocalMediaServer.shared.address(of: file, root: root) }
        return file
    }

    // MARK: Storage

    /// A finished download's playable file, for showing it in Finder.
    public func file(for item: DownloadItem) -> URL? {
        guard item.status == .completed, let media = item.media else { return nil }
        return folder(item.id).appending(path: media)
    }

    /// Forgets finished downloads whose file is gone: deleted or moved away in Finder, or cleared by
    /// tvOS to free space. They would otherwise stay listed and fail to play.
    public func forgetMissing() {
        let missing = items.filter { $0.status == .completed && !hasMedia($0) }.map(\.id)
        if !missing.isEmpty { remove(missing) }
    }

    /// Measures the downloads on disk and the space left on the device.
    public func measure() async {
        forgetMissing()
        purgeOrphans()
        let root = root, ids = items.map(\.id)
        let sizes = await Task.detached { ids.map { (id: $0, size: Self.allocatedSize(root.appending(path: $0))) } }.value
        for entry in sizes {
            if let item = item(id: entry.id), item.status == .completed { update(entry.id) { $0.size = entry.size } }
        }
        let values = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey])
        usage = Usage(downloads: sizes.reduce(0) { $0 + $1.size }, available: Self.availableCapacity(at: root),
                      capacity: values?.volumeTotalCapacity.map(Int64.init))
    }

    nonisolated static func availableCapacity(at url: URL) -> Int64? {
        var url = url
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        #if os(tvOS)
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init)
        #else
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
        #endif
    }

    /// Keeps a downloaded HDR MKV as an MP4 that AVPlayer opens itself (see `Rewrap`) and returns the playable
    /// file's name. The MKV stays when no MP4 is needed, there is no room for one, or writing it fails.
    nonisolated static func rewrap(_ name: String, in folder: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> String {
        guard Remux.handles(name: name) else { return name }
        let source = folder.appending(path: name), target = folder.appending(path: rewrappedName)
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let began = Date()
        do {
            if let free = availableCapacity(at: folder), size + (64 << 20) > free {
                // Probed first: an SDR file needs no room.
                guard try await Rewrap.needed(source) else { return name }
                Diagnostics.shared.record(.warning, "download", "rewrap skipped size=\(size) free=\(free)")
                return name
            }
            guard let selection = try await Rewrap.run(source, to: target, progress: progress) else { return name }
            try FileManager.default.removeItem(at: source)
            Diagnostics.shared.record(.info, "download", "rewrap mp4 streams=\(selection.streams.map(\.codec)) dropped=\(selection.dropped.map(\.codec)) size=\(size) s=\(Int(Date().timeIntervalSince(began)))")
            return rewrappedName
        } catch {
            try? FileManager.default.removeItem(at: target)
            if !(error is CancellationError) { Diagnostics.shared.failure("download", "rewrap", error) }
            return name
        }
    }
    /// The MP4 a downloaded MKV becomes.
    nonisolated static let rewrappedName = "media.mp4"

    nonisolated static func allocatedSize(_ folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: Persistence

    private func folder(_ id: String) -> URL { root.appending(path: id) }
    private var index: URL { root.appending(path: "downloads.json") }
    private var store: JSONFileStore<[DownloadItem]> { JSONFileStore(file: index) }
    private func hasMedia(_ item: DownloadItem) -> Bool {
        guard let media = item.media else { return false }
        return FileManager.default.fileExists(atPath: folder(item.id).appending(path: media).path)
    }

    private func load() {
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
    }

    private func save() {
        savedAt = Date()
        store.save(items)
    }
}
