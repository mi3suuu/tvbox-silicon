// [mi3s] 二开：本文件内新增的测试覆盖 播放环境隔离（见 Sources/TVCore/PlaybackHistory.swift 的 [mi3s] 说明）：
//   分区、旧记录归默认环境、删除不误伤其它环境、重看不重复写入
import Foundation
import Testing
@testable import TVCore

private func historyContext(video: String = "series", episode: String = "1", source: String = "source") -> PlaybackHistoryContext {
    PlaybackHistoryContext(origin: URL(string: "https://example.com/sub.json")!, sourceKey: source, sourceName: "Movies",
        videoID: video, videoName: "Series", episodeID: episode, episodeName: "Episode " + episode, episodeFlag: "line")
}

@Test @MainActor func playbackHistoryPersistsUpdatesAndDeletesWithoutStreamCredentials() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "history.json")
    let history = PlaybackHistory(file: file)
    history.record(historyContext(), position: 143.5, duration: 1800)
    #expect(history.persistenceError == nil)
    let restored = PlaybackHistory(file: file)
    #expect(restored.entries.first?.resumePosition == 143.5)
    #expect(restored.entries.first?.context.episodeName == "Episode 1")
    restored.record(historyContext(episode: "2"), position: 25, duration: 1800)
    #expect(restored.entries.count == 1)
    #expect(restored.entries.first?.context.episodeID == "2")
    restored.record(historyContext(source: "other"), position: 50, duration: 1800)
    #expect(restored.entries.count == 2)
    restored.remove(historyContext().id)
    #expect(PlaybackHistory(file: file).entries.count == 1)
    restored.clear()
    #expect(PlaybackHistory(file: file).entries.isEmpty)
}

@Test @MainActor func playbackHistoryRejectsInvalidProgressAndDoesNotOverwriteWithLoadingZero() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    let history = PlaybackHistory(file: file)
    history.record(historyContext(), position: 90, duration: 1800)
    for position in [0.0, -1, .nan, .infinity] { history.record(historyContext(), position: position, duration: 1800) }
    for duration in [-1.0, .nan, .infinity] { history.record(historyContext(), position: 10, duration: duration) }
    #expect(history.entries.first?.position == 90)
    history.record(historyContext(), position: 1900, duration: 1800)
    #expect(history.entries.first?.position == 1800)
    #expect(history.entries.first?.completed == true)
    #expect(history.entries.first?.resumePosition == 0)
}

@Test func playbackHistoryFindsTheSameEpisodeAfterReorderingAndRejectsMissingEpisodes() {
    let context = historyContext()
    let next = Episode(id: "1", name: "Episode 2", address: "fresh-2", flag: "line")
    let original = Episode(id: "9", name: "Episode 1", address: "fresh-1", flag: "line")
    #expect(context.episode(in: [next, original])?.address == "fresh-1")
    #expect(context.episode(in: [next]) == nil)
    #expect(context.episode(in: [Episode(id: "1", name: "Episode 1", address: "different-line", flag: "other")]) == nil)
    #expect(context.episode(in: [original, Episode(id: "10", name: "Episode 1", address: "ambiguous", flag: "line")]) == nil)
    // The details page opens on the line watched last even when it isn't the first line (#362).
    let otherLine = Episode(id: "20", name: "Episode 1", address: "first-line", flag: "other")
    #expect(context.episode(in: [otherLine, next, original])?.flag == "line")
}

@Test func anEpisodePickedFromAListResumesWhereItStopped() {
    let entry = PlaybackHistoryEntry(context: historyContext(episode: "2"), position: 163, duration: 327,
                                     updatedAt: Date(timeIntervalSince1970: 0))
    let watched = Episode(id: "0-1", name: "Episode 2", address: "fresh-2", flag: "line")
    let next = Episode(id: "0-2", name: "Episode 3", address: "fresh-3", flag: "line")
    let otherLine = Episode(id: "1-1", name: "Episode 2", address: "other-2", flag: "other")
    // Picking the episode watched last picks it up; another episode or another line starts at 0 (#593).
    #expect(entry.resumePosition(for: watched) == 163)
    #expect(entry.resumePosition(for: next) == nil)
    #expect(entry.resumePosition(for: otherLine) == nil)
    // A finished entry and one barely started both start at 0, as `resumePosition` says.
    let finished = PlaybackHistoryEntry(context: historyContext(episode: "2"), position: 327, duration: 327,
                                        updatedAt: Date(timeIntervalSince1970: 0))
    let barely = PlaybackHistoryEntry(context: historyContext(episode: "2"), position: 0.5, duration: 327,
                                      updatedAt: Date(timeIntervalSince1970: 0))
    #expect(finished.resumePosition(for: watched) == nil)
    #expect(barely.resumePosition(for: watched) == nil)
}

@Test func continueGoesOnToTheNextEpisodeOnceOneIsFinished() {
    let first = Episode(id: "0-0", name: "Episode 1", address: "fresh-1", flag: "line")
    let watched = Episode(id: "0-1", name: "Episode 2", address: "fresh-2", flag: "line")
    let next = Episode(id: "0-2", name: "Episode 3", address: "fresh-3", flag: "line")
    let otherLine = Episode(id: "1-2", name: "Episode 3", address: "other-3", flag: "other")
    let episodes = [first, watched, otherLine, next]
    func entry(_ episode: String, at position: Double) -> PlaybackHistoryEntry {
        PlaybackHistoryEntry(context: historyContext(episode: episode), position: position, duration: 327,
                             updatedAt: Date(timeIntervalSince1970: 0))
    }
    // Half watched: Continue picks that episode up. Finished: the next one on its line, not the first (#593).
    #expect(entry("2", at: 163).continuation(in: episodes) == watched)
    #expect(entry("2", at: 327).continuation(in: episodes) == next)
    // The line's last episode finished, or the episode gone from the details: Play starts the line instead.
    #expect(entry("3", at: 327).continuation(in: episodes) == nil)
    #expect(entry("2", at: 163).continuation(in: [first, next]) == nil)
}

@Test @MainActor func playbackHistoryBoundsAndRecoversItsPersistentFile() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("broken history".utf8).write(to: file)
    let history = PlaybackHistory(file: file)
    #expect(history.entries.isEmpty)
    for index in 0...PlaybackHistory.limit {
        history.record(historyContext(video: String(index)), position: 10, duration: 100,
                       now: Date(timeIntervalSince1970: Double(index)))
    }
    #expect(history.entries.count == PlaybackHistory.limit)
    #expect(history.entries.first?.context.videoID == String(PlaybackHistory.limit))
    #expect(history.entries.contains { $0.context.videoID == "0" } == false)
    #expect(PlaybackHistory(file: file).entries == history.entries)
}

@Test func historyResumeClampsChangedDurationsAndCoexistsWithSegmentSkipping() {
    #expect(PlaybackHistoryEntry.resumeTarget(143.5, duration: 1800) == 143.5)
    #expect(PlaybackHistoryEntry.resumeTarget(143.5, duration: 100) == 99.75)
    #expect(PlaybackHistoryEntry.resumeTarget(.nan, duration: 1800) == nil)
    #expect(PlaybackHistoryEntry.resumeTarget(10, duration: .infinity) == nil)
    var pass = EpisodeSkipPass()
    let settings = EpisodeSkipSettings(enabled: true, introEnd: 90, outroLength: 120)
    #expect(pass.target(time: 143.5, duration: 1800, playing: true, settings: settings) == nil)
    #expect(pass.target(time: 20, duration: 1800, playing: true, settings: settings) == nil)
    #expect(pass.target(time: 1680, duration: 1800, playing: true, settings: settings) == 1799.95)
}

@Test func historyChannelDecodesLegacyFavoritesAndDoesNotNeedAnOldStreamToResume() throws {
    let legacy = Data(#"{"name":"Live","group":"TV","url":"https://example.com/live.m3u8","headers":{}}"#.utf8)
    let channel = try JSONDecoder().decode(Channel.self, from: legacy)
    #expect(channel.historyContext == nil)
    #expect(channel.resumePosition == nil)
    let encoded = try JSONEncoder().encode(historyContext())
    let text = String(decoding: encoded, as: UTF8.self)
    #expect(!text.contains("headers"))
    #expect(!text.contains("address"))
}

@Test func detailsWithoutAPosterKeepTheListOrSavedOne() {
    let list = URL(string: "https://img.example.com/list.jpg")!, own = URL(string: "https://img.example.com/own.jpg")!
    let bare = Video(id: "1", name: "肖申克的救赎", year: "1994", episodes: [Episode(id: "0-0", name: "正片", address: "a", flag: "line")])
    let kept = bare.keepingPoster(list, headers: ["Referer": "https://example.com/"])
    #expect(kept.poster == list && kept.posterHeaders == ["Referer": "https://example.com/"])
    #expect(kept.name == bare.name && kept.year == "1994" && kept.episodes == bare.episodes)
    // A poster of its own wins, and no fallback leaves it as it was.
    let posted = Video(id: "1", name: "x", poster: own)
    #expect(posted.keepingPoster(list).poster == own)
    #expect(bare.keepingPoster(nil).poster == nil)
}

// MARK: - 环境隔离

@Test @MainActor func historyPartitionsByEnvironmentAndDefaultsToTheActiveOne() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "history-env-" + UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    let history = PlaybackHistory(file: file)
    let first = UUID(), second = UUID()
    history.defaultEnvironmentID = first
    // 不传 environment 的记录（视频播放器走的就是这条路）应落在 active 环境，而不是 nil 全归默认。
    history.activeEnvironmentID = first
    history.record(historyContext(video: "A"), position: 10, duration: 100)
    history.activeEnvironmentID = second
    history.record(historyContext(video: "B"), position: 20, duration: 100)
    // 第一个环境只看到 A，第二个只看到 B。
    #expect(history.entries(in: first).map(\.context.videoID) == ["A"])
    #expect(history.entries(in: second).map(\.context.videoID) == ["B"])
    // 落盘后再读，环境跟着记录走。
    let restored = PlaybackHistory(file: file)
    restored.defaultEnvironmentID = first
    #expect(restored.entries(in: first).map(\.context.videoID) == ["A"])
    #expect(restored.entries(in: second).map(\.context.videoID) == ["B"])
}

@Test @MainActor func historyBeforeEnvironmentsBelongsToTheDefault() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "history-legacy-" + UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    let history = PlaybackHistory(file: file)
    let defaultID = UUID()
    // 升级前写的记录 environment == nil，必须归默认环境而不是凭空消失。
    history.defaultEnvironmentID = defaultID
    history.record(historyContext(video: "legacy"), position: 10, duration: 100, environment: nil)
    #expect(history.entries(in: defaultID).map(\.context.videoID) == ["legacy"])
    #expect(history.entries(in: UUID()).isEmpty)
}

@Test @MainActor func removingALegacyNilEntryDoesNotDeleteOtherEnvironments() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "history-remove-" + UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    let history = PlaybackHistory(file: file)
    let defaultID = UUID(), other = UUID()
    history.defaultEnvironmentID = defaultID
    // 同一条视频：一条 legacy（nil，归默认环境），一条在 other 环境。
    history.record(historyContext(video: "shared"), position: 10, duration: 100, environment: nil)
    history.record(historyContext(video: "shared"), position: 20, duration: 100, environment: other)
    // 删 legacy 那条（environment == nil）时，other 环境的记录必须保留。
    let legacy = history.entries(in: defaultID).first!
    history.remove(legacy.id, environment: legacy.environment)
    #expect(history.entries(in: defaultID).isEmpty)
    #expect(history.entries(in: other).map(\.context.videoID) == ["shared"])
}

@Test @MainActor func rewatchOfALegacyEntryInTheDefaultEnvironmentReplacesIt() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "history-rewatch-" + UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    let history = PlaybackHistory(file: file)
    let defaultID = UUID()
    history.defaultEnvironmentID = defaultID
    history.activeEnvironmentID = defaultID
    // 一条 legacy nil 记录，之后在默认环境重看同一条视频（environment 显式 = defaultID）。
    history.record(historyContext(video: "show"), position: 10, duration: 100, environment: nil)
    history.record(historyContext(video: "show"), position: 50, duration: 100, environment: defaultID)
    // nil 与 defaultID 归一化后是同一条，去重后只留一条（新位置 50）。
    let entries = history.entries(in: defaultID)
    #expect(entries.count == 1)
    #expect(entries.first?.position == 50)
}

@Test @MainActor func clearHistoryRemovesLegacyNilEntriesToo() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "history-clear-" + UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    let history = PlaybackHistory(file: file)
    let defaultID = UUID()
    history.defaultEnvironmentID = defaultID
    history.record(historyContext(video: "legacy"), position: 10, duration: 100, environment: nil)
    // Clear-history 的删除集合用当前环境的 visible 计算，其中含 legacy 记录；用归一化环境删除后应清空。
    let visible = history.entries(in: defaultID)
    history.remove(Set(visible.map(\.id)), environment: defaultID)
    #expect(history.entries(in: defaultID).isEmpty)
}
