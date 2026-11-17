import Foundation
import Observation

public enum FavoriteKind: String, Codable, Sendable, CaseIterable {
    case live, video, episode, music, cloud
}

public struct FavoriteVideo: Codable, Hashable, Sendable {
    public var origin: URL
    public var sourceKey: String
    public var sourceName: String
    public var videoID: String
    public var videoName: String
    public var poster: URL?
    public var posterHeaders: [String: String]
    public var year: String?

    public init(origin: URL, sourceKey: String, sourceName: String, videoID: String, videoName: String, poster: URL?, posterHeaders: [String: String], year: String?) {
        self.origin = origin
        self.sourceKey = sourceKey
        self.sourceName = sourceName
        self.videoID = videoID
        self.videoName = videoName
        self.poster = poster
        self.posterHeaders = posterHeaders
        self.year = year
    }

    public init(origin fallback: URL, site: Site, video: Video) {
        self.init(origin: site.origin(or: fallback), sourceKey: site.sourceKey, sourceName: site.name, videoID: video.id, videoName: video.name, poster: video.poster, posterHeaders: video.posterHeaders, year: video.year)
    }

    /// Enough for the detail page to refetch this title. Playback addresses are not stored.
    public func listingVideo() -> Video? {
        var json: [String: JSONValue] = ["vod_id": .string(videoID), "vod_name": .string(videoName)]
        if let year { json["vod_year"] = .string(year) }
        if let poster { json["vod_pic"] = .string(posterField(poster)) }
        return Video(json: json, origin: origin)
    }

    /// `Video` reads artwork headers from the TVBox suffix on `vod_pic`.
    private func posterField(_ poster: URL) -> String {
        let headers = posterHeaders.filter { name, value in
            name.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil && !value.contains("\r") && !value.contains("\n")
        }
        guard !headers.isEmpty else { return poster.absoluteString }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(headers), let json = String(data: data, encoding: .utf8) else { return poster.absoluteString }
        return poster.absoluteString + "@Headers=" + json
    }
}

public struct FavoriteEpisode: Codable, Hashable, Sendable {
    public var video: FavoriteVideo
    public var episodeFlag: String
    public var episodeName: String
    public var episodeID: String

    public init(video: FavoriteVideo, episodeFlag: String, episodeName: String, episodeID: String) {
        self.video = video
        self.episodeFlag = episodeFlag
        self.episodeName = episodeName
        self.episodeID = episodeID
    }

    public func historyContext() -> PlaybackHistoryContext {
        var context = PlaybackHistoryContext(origin: video.origin, sourceKey: video.sourceKey, sourceName: video.sourceName, videoID: video.videoID, videoName: video.videoName, poster: video.poster, episodeID: episodeID, episodeName: episodeName, episodeFlag: episodeFlag)
        context.year = video.year
        context.posterHeaders = video.posterHeaders.isEmpty ? nil : video.posterHeaders
        return context
    }

    /// Continue Watching's position only when that entry is still this episode. A later episode of the same video starts at 0. A finished entry also starts at 0, matching `resumePosition`.
    public func resumePosition(in entries: [PlaybackHistoryEntry]) -> Double {
        guard let entry = entries.first(where: { item in
            item.context.origin == video.origin && item.context.sourceKey == video.sourceKey && item.context.videoID == video.videoID
                && item.context.episodeFlag == episodeFlag && item.context.episodeName == episodeName
        }) else { return 0 }
        return entry.resumePosition
    }
}

public struct FavoriteCloudFile: Codable, Hashable, Sendable {
    public var driveKey: String
    public var folderID: String
    public var folderName: String
    public var fileID: String
    public var fileName: String
    public var size: Int64

    public init(driveKey: String, folderID: String, folderName: String, fileID: String, fileName: String, size: Int64) {
        self.driveKey = driveKey
        self.folderID = folderID
        self.folderName = folderName
        self.fileID = fileID
        self.fileName = fileName
        self.size = size
    }
}

public enum FavoriteItem: Codable, Hashable, Sendable, Identifiable {
    case live(Channel)
    case video(FavoriteVideo)
    case episode(FavoriteEpisode)
    case music(MusicTrack)
    case cloud(FavoriteCloudFile)

    public var kind: FavoriteKind {
        switch self {
        case .live: .live
        case .video: .video
        case .episode: .episode
        case .music: .music
        case .cloud: .cloud
        }
    }

    public var key: String {
        switch self {
        case .live(let channel):
            if LiveCatalog.isRoomAddress(channel.url) { return "live|" + channel.url.absoluteString }
            return "live|" + channel.id
        case .video(let video):
            return "video|" + EpisodeSkipSettings.scope(origin: video.origin, source: video.sourceKey, video: video.videoID)
        case .episode(let episode):
            let videoKey = EpisodeSkipSettings.scope(origin: episode.video.origin, source: episode.video.sourceKey, video: episode.video.videoID)
            return "episode|" + videoKey + "|" + episode.episodeFlag + "|" + episode.episodeName
        case .music(let track):
            return "music|" + track.id
        case .cloud(let file):
            return "cloud|" + file.driveKey + "|" + file.fileID
        }
    }

    public var id: String { key }

    public func matches(_ other: FavoriteItem) -> Bool {
        switch (self, other) {
        case (.live(let saved), .live(let channel)):
            return saved.id == channel.id || (LiveCatalog.isRoomAddress(channel.url) && saved.url == channel.url)
        default:
            return key == other.key
        }
    }
}

struct FavoriteDocument: Codable {
    var version: Int
    var items: [FavoriteItem]
    /// version 2 kept environments in a `[item.key: environment]` map beside `items`. That map
    /// collapses when the same show is favorited in more than one environment (its `key` is
    /// environment-free), so one environment's copy silently took over the others on relaunch.
    /// Kept for reading old documents only; new writes use `records` (version 3).
    var environments: [String: String]?
    /// version 3: each record carries its own environment inline, so two copies of the same item
    /// in different environments no longer collide.
    var records: [FavoriteRecord]?
}

/// One favourite plus the environment it belongs to. `FavoriteItem` stays as-is; the environment
/// rides alongside in the document so an item's identity (its `key`) is never polluted.
struct FavoriteRecord: Codable, Hashable, Sendable {
    var item: FavoriteItem
    var environment: UUID?
}

@MainActor @Observable public final class Favorites {
    /// Every favourite, across all environments. The environment is stored per record, not per item,
    /// so `FavoriteItem` and its `key` stay untouched and sync keeps working.
    private var records: [FavoriteRecord] = []
    /// The environment whose favourites `items` exposes. The app keeps this in step with
    /// `Environments.activeID`; nil means "default environment" and matches records with no
    /// environment (everything saved before environments existed).
    public var activeEnvironmentID: UUID?
    public var defaultEnvironmentID: UUID?
    public private(set) var persistenceError: String?
    private let defaults: UserDefaults
    private static let storageKey = "favorites"
    /// Called after the viewer changes the list (not after `adopt`), for iCloud sync.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    /// The favourites of the active environment, in order.
    public var items: [FavoriteItem] {
        let active = activeEnvironmentID ?? defaultEnvironmentID
        return records.filter { ($0.environment ?? defaultEnvironmentID) == active }.map(\.item)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var migrated = false
        if let data = defaults.data(forKey: Self.storageKey) {
            if let document = try? JSONDecoder().decode(FavoriteDocument.self, from: data), document.version >= 2 {
                if let saved = document.records {
                    // version 3: the environment rides on each record, so duplicate keys across
                    // environments are preserved exactly as saved.
                    records = saved
                } else {
                    // version 2: environments lived in a key-based map; rebuild records from it.
                    // (The map already collapsed duplicates, but we still read what it has.)
                    let env = document.environments ?? [:]
                    records = document.items.map { item in
                        FavoriteRecord(item: item, environment: env[item.key].flatMap(UUID.init(uuidString:)))
                    }
                }
            } else if let channels = try? JSONDecoder().decode([Channel].self, from: data) {
                records = channels.map { FavoriteRecord(item: .live($0), environment: nil) }
                migrated = true
            }
        }
        if adoptVideoFavorites() { migrated = true }
        if migrated { persist() }
    }

    /// Shows saved by the earlier favorites list, once. Unfavoriting one afterwards stays removed.
    private func adoptVideoFavorites() -> Bool {
        let adopted = "videoFavorites.adopted.v1"
        guard !defaults.bool(forKey: adopted) else { return false }
        defaults.set(true, forKey: adopted)
        guard let data = defaults.data(forKey: "videoFavorites"),
              let shows = try? JSONDecoder().decode([VideoFavorite].self, from: data) else { return false }
        var added = false
        for show in shows.reversed() {
            let video = FavoriteVideo(origin: show.origin, sourceKey: show.sourceKey, sourceName: show.sourceName, videoID: show.videoID, videoName: show.name, poster: show.poster, posterHeaders: show.posterHeaders ?? [:], year: show.year)
            let item = FavoriteItem.video(video)
            guard !records.contains(where: { $0.item.matches(item) }) else { continue }
            records.insert(FavoriteRecord(item: item, environment: nil), at: 0)
            added = true
        }
        return added
    }

    public func contains(_ item: FavoriteItem) -> Bool { records.contains { $0.item.matches(item) && isActive($0) } }

    public func toggle(_ item: FavoriteItem) {
        if let index = records.firstIndex(where: { $0.item.matches(item) && isActive($0) }) {
            records.remove(at: index)
        } else {
            records.insert(FavoriteRecord(item: item, environment: activeEnvironmentID ?? defaultEnvironmentID), at: 0)
        }
        persist()
        onChange?()
    }

    /// 删掉**所有来源为这一条源**的收藏（跨全部环境）。
    ///
    /// 为什么需要它：删源（`Store.deleteSite`）只写了 `deletedSources` 与 `hiddenSources`，
    /// 而收藏与「继续观看」都不看那两份记账。删完源之后，收藏页会留下一张点一下就
    /// 弹「这个源已不在当前订阅里」的死卡片（`Store.reportMissingFavoriteSource`），
    /// 而用户已经明确删掉了那条源 —— 这张卡片没有任何意义，只能一条条手删。
    ///
    /// 跨环境删是刻意的：源是按**地址 + sourceKey** 删除的，同一个源在各环境里
    /// 是同一件事，留下的都是同样的死卡片。
    ///
    /// - Returns: 删掉的条数（0 表示没有受影响的收藏）。
    @discardableResult
    public func removeAll(fromSource sourceKey: String, origin: URL) -> Int {
        let before = records.count
        records.removeAll { record in
            guard case .video(let video) = record.item else { return false }
            return video.sourceKey == sourceKey && video.origin == origin
        }
        let removed = before - records.count
        guard removed > 0 else { return 0 }
        persist()
        onChange?()
        return removed
    }

    private func isActive(_ record: FavoriteRecord) -> Bool {
        (record.environment ?? defaultEnvironmentID) == (activeEnvironmentID ?? defaultEnvironmentID)
    }

    /// Deletes every favourite belonging to `environment` (legacy `nil` records count as the default
    /// environment), used when that environment is removed.
    public func delete(environment: UUID) {
        records.removeAll { ($0.environment ?? defaultEnvironmentID) == environment }
        persist()
        onChange?()
    }

    /// Every item across all environments, keyed by environment + item key, as iCloud sync compares
    /// them. The environment rides in the key (`env\u{1F}<uuid>\u{1F}<item.key>`) so each environment's
    /// favorites sync independently: switching environments no longer makes one environment's list look
    /// deleted to iCloud, and two devices in different environments no longer merge their lists.
    public var syncValues: [String: FavoriteItem] {
        var result: [String: FavoriteItem] = [:]
        for record in records {
            let env = record.environment ?? defaultEnvironmentID
            result[Self.syncKey(environment: env, item: record.item)] = record.item
        }
        return result
    }

    /// The list merged with other devices', per environment: each item carries its environment in its
    /// sync key, so a device only ever adopts favorites into the environment they were saved under.
    public func adopt(_ synced: [CloudSyncItem<FavoriteItem>]) {
        // Group incoming items by the environment encoded in their key.
        var byEnvironment: [UUID?: [CloudSyncItem<FavoriteItem>]] = [:]
        for item in synced {
            let env = Self.environment(fromSyncKey: item.id)
            byEnvironment[env, default: []].append(item)
        }
        for (env, items) in byEnvironment {
            adopt(items, into: env)
        }
        persist()
    }

    /// Merges one environment's incoming items into that environment's records.
    private func adopt(_ synced: [CloudSyncItem<FavoriteItem>], into environment: UUID?) {
        let rank = Dictionary(records.filter { ($0.environment ?? defaultEnvironmentID) == (environment ?? defaultEnvironmentID) }
            .enumerated().map { ($0.element.item.key, $0.offset) }, uniquingKeysWith: min)
        let incoming = synced.sorted { lhs, rhs in
            if lhs.stamp != rhs.stamp { return lhs.stamp > rhs.stamp }
            return (rank[lhs.value.key] ?? Int.max, lhs.id) < (rank[rhs.value.key] ?? Int.max, rhs.id)
        }.map { FavoriteRecord(item: $0.value, environment: environment) }
        let incomingKeys = Set(incoming.map { $0.item.key })
        records.removeAll { ($0.environment ?? defaultEnvironmentID) == (environment ?? defaultEnvironmentID) && incomingKeys.contains($0.item.key) }
        records.insert(contentsOf: incoming, at: 0)
    }

    /// Encodes an environment into a sync key. `nil` means the default environment (legacy records).
    static func syncKey(environment: UUID?, item: FavoriteItem) -> String {
        "env\u{1F}\(environment?.uuidString ?? "default")\u{1F}" + item.key
    }

    /// Reads the environment back out of a sync key. Returns nil for the default environment.
    static func environment(fromSyncKey key: String) -> UUID? {
        let parts = key.split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "env" else { return nil }
        return parts[1] == "default" ? nil : UUID(uuidString: parts[1])
    }

    /// Shows and episodes saved from a subscription whose address changed (#982), under the new address.
    public func moveOrigin(from old: URL, to new: URL) {
        var changed = false
        func move(_ video: FavoriteVideo) -> FavoriteVideo {
            guard video.origin.absoluteString == old.absoluteString else { return video }
            changed = true
            var video = video
            video.origin = new
            return video
        }
        let next = items.map { item -> FavoriteItem in
            switch item {
            case .video(let video): return .video(move(video))
            case .episode(var episode): episode.video = move(episode.video); return .episode(episode)
            default: return item
            }
        }
        guard changed else { return }
        // 我方模型：`items` 是从 `records` 算出来的只读视图，写入必须落回 `records`（version 3），
        // 并保留每条记录自己的 environment（不能按当前环境重写，否则会跨环境搬动收藏）。
        var seen = Set<String>()
        var byKey: [String: UUID?] = [:]
        for record in records { byKey[record.item.key] = record.environment }
        records = next.filter { seen.insert($0.key).inserted }
            .map { FavoriteRecord(item: $0, environment: byKey[$0.key] ?? defaultEnvironmentID) }
        persist()
        onChange?()
    }

    public func items(_ kind: FavoriteKind) -> [FavoriteItem] { items.filter { $0.kind == kind } }

    /// The kinds that have favorites, in the Favorites page's section order: what its filter offers.
    public var kinds: [FavoriteKind] {
        let present = Set(items.map(\.kind))
        return FavoriteKind.allCases.filter(present.contains)
    }

    public var liveChannels: [Channel] {
        items.compactMap { if case .live(let channel) = $0 { channel } else { nil } }
    }

    // [mi3s] 二开融合：上游 1.8.11 (#523 Liked Songs) 新增。我方记录式收藏模型里 items 已是「当前环境」的列表，
    // 语义一致，直接沿用上游实现。
    /// The songs saved with Like, newest first, which Liked Songs plays as one list.
    public var musicTracks: [MusicTrack] {
        items.compactMap { if case .music(let track) = $0 { track } else { nil } }
    }

    private func persist() {
        do {
            // version 3 writes each record with its environment inline. A key-based environment map
            // (version 2) could not hold the same show favorited in two environments at once, so it
            // must not be written again. `items` stays for backward-compatible reading of old data.
            let document = FavoriteDocument(version: 3, items: records.map(\.item), environments: nil, records: records)
            defaults.set(try JSONEncoder().encode(document), forKey: Self.storageKey)
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }
}
