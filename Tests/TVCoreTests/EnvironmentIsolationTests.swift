import Foundation
import Testing
@testable import TVCore

/// 多环境隔离：偏好式数据按 key 分环境、下载与歌曲按记录分环境。
///
/// 这组测试锁的是「切了环境，点播源 / 下载内容 / 播放记录 / 待播记录里还残留着上一个环境的东西」
/// 这条线上每一处真实来路：
///
/// 1. 置顶 / 隐藏 / 源排序 / 源改派 / 自定义分组是**偏好**，没有记录可打戳，只能按 key 分环境；
/// 2. 视频下载与歌曲下载是**记录**，各自带 `environmentID`，但页面和「这一集下过没有」
///    必须走可见出口，不能直读 `items`。
///
/// 默认环境永远用**原 key**（升级不丢任何旧偏好），这条也在断言里 —— 它是这套分键唯一
/// 有破坏性的地方，改了就等于把老用户的数据藏起来。

private func freshDefaults(_ name: String) -> UserDefaults {
    let suite = "env-isolation-" + name + "-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

/// 本文件自用的上下文构造器（`PlaybackHistoryTests` 里那个是 private，用不到）。
private func envHistoryContext(video: String) -> PlaybackHistoryContext {
    PlaybackHistoryContext(origin: URL(string: "https://example.com/sub.json")!, sourceKey: "source",
                           sourceName: "Movies", videoID: video, videoName: "Series",
                           episodeID: "1", episodeName: "Episode 1", episodeFlag: "line")
}

private func site(_ key: String, name: String = "源") -> Site {
    Site(key: key, name: name, type: 1, api: "https://example.com/" + key, raw: [:])
}

// MARK: - 偏好按环境分键

@Test @MainActor func pinsDoNotLeakAcrossEnvironments() {
    let defaults = freshDefaults("pins")
    let first = UUID(), second = UUID()
    let origin = URL(string: "https://example.com/sub")!
    let target = site("a")

    let store = PinnedSources(defaults: defaults)
    store.defaultEnvironmentID = first
    store.environmentID = first
    store.toggle(target, origin: origin)
    #expect(store.contains(target, origin: origin))
    #expect(defaults.stringArray(forKey: "pinnedSources.v1")?.isEmpty == false)  // 默认环境用原 key

    // 切到第二个环境：不该再看见第一个环境的置顶。
    store.environmentID = second
    store.reloadForEnvironment()
    #expect(!store.contains(target, origin: origin))
    #expect(store.isEmpty)

    // 切回去：原来那条还在，且落的是原 key。
    store.environmentID = first
    store.reloadForEnvironment()
    #expect(store.contains(target, origin: origin))
    #expect(defaults.stringArray(forKey: "pinnedSources.v1.\(second.uuidString)") == nil)
}

@Test @MainActor func hidesDoNotLeakAcrossEnvironments() {
    let defaults = freshDefaults("hides")
    let first = UUID(), second = UUID()
    let origin = URL(string: "https://example.com/sub")!
    let target = site("b")

    let store = HiddenSources(defaults: defaults)
    store.defaultEnvironmentID = first
    store.environmentID = first
    store.toggle(target, origin: origin)
    #expect(store.contains(target, origin: origin))

    store.environmentID = second
    store.reloadForEnvironment()
    #expect(!store.contains(target, origin: origin))
    // 切回去必须还在：只断言「切走后为空」的话，一个把 keys 永远清空的实现也能通过。
    store.environmentID = first
    store.reloadForEnvironment()
    #expect(store.contains(target, origin: origin))
}

@Test @MainActor func sourceOrderDoesNotLeakAcrossEnvironments() {
    let defaults = freshDefaults("order")
    let first = UUID(), second = UUID()
    let origin = URL(string: "https://example.com/sub")!
    let one = site("one"), two = site("two")

    let store = SourceOrder(defaults: defaults)
    store.defaultEnvironmentID = first
    store.environmentID = first
    store.enabled = true
    store.save([two, one], origin: origin)
    #expect(store.arrange([one, two], origin: origin).map(\.key) == ["two", "one"])

    // 第二个环境：开关回到默认（关），顺序也是空的，不会按上一个环境的顺序重排。
    store.environmentID = second
    store.reloadForEnvironment()
    #expect(store.enabled == false)
    #expect(store.isEmpty)
    #expect(store.arrange([one, two], origin: origin).map(\.key) == ["one", "two"])
    // 切回去：开关与顺序都还在。
    store.environmentID = first
    store.reloadForEnvironment()
    #expect(store.enabled == true)
    #expect(store.arrange([one, two], origin: origin).map(\.key) == ["two", "one"])
}

@Test @MainActor func sourceMovesDoNotLeakAcrossEnvironments() {
    let defaults = freshDefaults("moves")
    let first = UUID(), second = UUID()
    let origin = URL(string: "https://example.com/sub")!
    let moved = site("c")

    let store = SourceReassignment(defaults: defaults)
    store.defaultEnvironmentID = first
    store.environmentID = first
    store.reassign(moved, address: "own", origin: origin, to: "other")
    #expect(store.destination(address: "own", sourceKey: "c") == "other")

    store.environmentID = second
    store.reloadForEnvironment()
    #expect(store.destination(address: "own", sourceKey: "c") == nil)
    #expect(store.moves.isEmpty)
    // 切回去：那条改派要回来（v2 与 legacy 两个 key 都必须被重读）。
    store.environmentID = first
    store.reloadForEnvironment()
    #expect(store.destination(address: "own", sourceKey: "c") == "other")
    #expect(store.moves.count == 1)
}

@Test @MainActor func customGroupsDoNotLeakAcrossEnvironments() {
    let defaults = freshDefaults("groups")
    let first = UUID(), second = UUID()

    let store = SourceGroupBook(defaults: defaults)
    store.defaultEnvironmentID = first
    store.environmentID = first
    let group = store.add(name: "可用")
    #expect(group != nil)

    store.environmentID = second
    store.reloadForEnvironment()
    #expect(store.isEmpty)
    // 切回去：分组还在，且名字没变。
    store.environmentID = first
    store.reloadForEnvironment()
    #expect(store.groups.map(\.name) == ["可用"])
}

@Test @MainActor func deletingAnEnvironmentDropsOnlyItsPreferences() {
    let defaults = freshDefaults("delete")
    let first = UUID(), second = UUID()
    let origin = URL(string: "https://example.com/sub")!
    let target = site("d")

    let pins = PinnedSources(defaults: defaults)
    pins.defaultEnvironmentID = first
    pins.environmentID = second
    pins.toggle(target, origin: origin)
    #expect(pins.contains(target, origin: origin))

    PinnedSources.delete(environment: second, defaults: defaults, default: first)
    #expect(defaults.stringArray(forKey: "pinnedSources.v1.\(second.uuidString)") == nil)
    // 删默认环境必须什么都不做：先把一条置顶写进默认环境的裸 key，再调一次删除，
    // 裸 key 必须还在。（原来这里写的是 `== Void()`，恒真，什么都没验 —— audit 指出的假绿。）
    pins.environmentID = first
    pins.reloadForEnvironment()
    pins.toggle(target, origin: origin)
    #expect(defaults.stringArray(forKey: "pinnedSources.v1")?.isEmpty == false)
    PinnedSources.delete(environment: first, defaults: defaults, default: first)
    #expect(defaults.stringArray(forKey: "pinnedSources.v1")?.isEmpty == false)
}

// MARK: - 下载按记录分环境

private func downloadSource(_ name: String) -> DownloadSource {
    DownloadSource(site: site("src"), videoID: "v",
                   episode: Episode(id: "e-" + name, name: name, address: "https://example.com/" + name, flag: "line"),
                   origin: URL(string: "https://example.com/sub")!)
}

@Test @MainActor func downloadsAreStampedAndFilteredByEnvironment() async {
    let root = FileManager.default.temporaryDirectory.appending(path: "dl-env-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = DownloadLibrary(root: root, settings: DownloadSettings(defaults: freshDefaults("dlsettings")))
    let first = UUID(), second = UUID()
    library.defaultEnvironmentID = first
    library.activeEnvironmentID = first

    let a = library.download(downloadSource("a"), title: "t", poster: nil, environmentID: first)
    #expect(a.environmentID == first)
    #expect(library.visibleItems().map(\.id) == [a.id])

    // 切到第二个环境：这条不是它的。
    library.activeEnvironmentID = second
    #expect(library.visibleItems().isEmpty)
    #expect(library.visibleItem(for: downloadSource("a")) == nil)

    // 在第二个环境下下同一集：是一条**独立记录**，不会撞上第一个环境那条。
    let b = library.download(downloadSource("a"), title: "t", poster: nil, environmentID: second)
    #expect(b.id != a.id)
    #expect(b.environmentID == second)
    #expect(library.visibleItems().map(\.id) == [b.id])

    // 删掉第二个环境只掉它自己那条。
    library.delete(environment: second)
    #expect(library.visibleItems().isEmpty)
    library.activeEnvironmentID = first
    #expect(library.visibleItems().map(\.id) == [a.id])
}

@Test @MainActor func migrationOfDownloadWithoutEnvironmentBelongsToTheDefault() async {
    let root = FileManager.default.temporaryDirectory.appending(path: "dl-legacy-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = DownloadLibrary(root: root, settings: DownloadSettings(defaults: freshDefaults("dlsettings2")))
    let first = UUID(), second = UUID()
    library.defaultEnvironmentID = first
    library.activeEnvironmentID = first
    // 没传 environment（升级前的调用方就是这样）：归默认环境，而不是凭空消失。
    _ = library.download(downloadSource("legacy"), title: "t", poster: nil)
    #expect(library.visibleItems().count == 1)
    library.activeEnvironmentID = second
    #expect(library.visibleItems().isEmpty)
}

@Test @MainActor func musicDownloadsAreFilteredByEnvironment() async {
    let root = FileManager.default.temporaryDirectory.appending(path: "music-env-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = MusicDownloadLibrary(root: root)
    let first = UUID(), second = UUID()
    library.defaultEnvironmentID = first
    library.activeEnvironmentID = first

    let track = MusicTrack(platform: .netease, songID: "song-1", title: "歌", artists: ["人"], album: "集", duration: 100)
    library.download([track])
    #expect(library.visibleItems.count == 1)
    #expect(library.items.first?.environmentID == first)

    library.activeEnvironmentID = second
    #expect(library.visibleItems.isEmpty)
    #expect(library.visibleCompleted.isEmpty)
    #expect(library.visiblePending.isEmpty)
    // 切回去：那首歌还在（只断言「切走后为空」会被「永远清空」的实现骗过）。
    library.activeEnvironmentID = first
    #expect(library.visibleItems.count == 1)
}

// MARK: - 歌曲「一个文件只归一个环境」

@Test @MainActor func oneTrackStoredOnceAndNotClaimedByAnotherEnvironment() async {
    let root = FileManager.default.temporaryDirectory.appending(path: "music-once-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = MusicDownloadLibrary(root: root)
    let first = UUID(), second = UUID()
    library.defaultEnvironmentID = first
    library.activeEnvironmentID = first

    let track = MusicTrack(platform: .netease, songID: "dup-1", title: "歌", artists: ["人"])
    library.download([track])
    #expect(library.items.count == 1)
    #expect(library.visibleItems.count == 1)

    // 第二个环境再点同一首：不新增记录（文件夹/封面全机唯一，一份文件只能归一个环境），
    // 且这个环境**不能**把它算成自己名下已下载。
    library.activeEnvironmentID = second
    library.download([track])
    #expect(library.items.count == 1)
    #expect(library.visibleItems.isEmpty)
    #expect(library.visibleItem(for: track) == nil)
    #expect(library.isSavedInAnotherEnvironment(track))

    // 切回去仍然是它自己的。
    library.activeEnvironmentID = first
    #expect(library.visibleItem(for: track) != nil)
    #expect(!library.isSavedInAnotherEnvironment(track))
}

@Test @MainActor func deletingAnEnvironmentDoesNotTakeAnotherEnvironmentsSongs() async {
    let root = FileManager.default.temporaryDirectory.appending(path: "music-del-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = MusicDownloadLibrary(root: root)
    let first = UUID(), second = UUID()
    library.defaultEnvironmentID = first
    library.activeEnvironmentID = first

    let mine = MusicTrack(platform: .netease, songID: "keep-1", title: "留着", artists: ["人"])
    library.download([mine])
    // 第二个环境下一首自己的歌。
    library.activeEnvironmentID = second
    let other = MusicTrack(platform: .netease, songID: "go-1", title: "会删", artists: ["人"])
    library.download([other])
    #expect(library.items.count == 2)

    // 删掉第二个环境：只掉它那首，第一个环境的歌与文件都还在。
    library.delete(environment: second)
    #expect(library.items.map(\.id) == [mine.id])
    library.activeEnvironmentID = first
    #expect(library.visibleItem(for: mine) != nil)
}

// MARK: - 专辑/歌单条目也按环境

@Test @MainActor func downloadedCollectionsDoNotLeakAcrossEnvironments() async {
    let root = FileManager.default.temporaryDirectory.appending(path: "music-coll-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = MusicDownloadLibrary(root: root)
    let first = UUID(), second = UUID()
    library.defaultEnvironmentID = first
    library.activeEnvironmentID = first

    let collection = MusicCollection(kind: .album, platform: .netease, collectionID: "coll-1", title: "专辑")
    let track = MusicTrack(platform: .netease, songID: "c-1", title: "歌", artists: ["人"])
    library.download([track], from: collection)
    #expect(library.visibleCollections.count == 1)

    // 第二个环境：这张专辑不该出现。
    library.activeEnvironmentID = second
    #expect(library.visibleCollections.isEmpty)

    // 同一张专辑在第二个环境下过一次：两条各自保留，各自只看见自己那条。
    library.download([track], from: collection)
    #expect(library.visibleCollections.count == 1)
    library.activeEnvironmentID = first
    #expect(library.visibleCollections.count == 1)

    // 删掉第二个环境，第一个环境的专辑与歌都还在。
    library.delete(environment: second)
    #expect(library.visibleCollections.count == 1)
    #expect(library.visibleItem(for: track) != nil)
}

// MARK: - 会话固定归属环境（写入侧）

/// 一个正在播的会话跨过一次环境切换后，后续进度必须继续写回**它开始时**的环境。
///
/// 这是「播放记录残留」的写入侧来路：`record` 不传 environment 时用的是
/// `activeEnvironmentID`，也就是「此刻屏幕上显示的环境」。小窗 / PiP 能活过一次切换，
/// 于是 A 环境那一集的进度就被写进了 B —— 只测读出口（`entries(in:)`）永远测不出来。
/// `PlaybackView` 用 `sessionEnvironmentID` 在 `begin()` 时钉住会话环境，这条测试锁住该语义。
@Test @MainActor func aSessionKeepsWritingToTheEnvironmentItStartedIn() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "history-session-" + UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    let history = PlaybackHistory(file: file)
    let first = UUID(), second = UUID()
    history.defaultEnvironmentID = first

    // A 环境里开始播：会话记下自己的环境。
    history.activeEnvironmentID = first
    let sessionEnvironment = history.activeEnvironmentID

    // 播到一半，用户去设置里切到 B。
    history.activeEnvironmentID = second

    // 后续 tick 仍带上会话自己的环境（`PlaybackView.saveHistory` 就是这么传的）。
    history.record(envHistoryContext(video: "session"), position: 30, duration: 100, environment: sessionEnvironment)

    #expect(history.entries(in: first).map(\.context.videoID) == ["session"])
    #expect(history.entries(in: second).isEmpty)

    // 反证：不传 environment（即用 activeEnvironmentID 的旧行为）会串到 B。
    history.record(envHistoryContext(video: "leaky"), position: 30, duration: 100)
    #expect(history.entries(in: second).map(\.context.videoID) == ["leaky"])
}

// MARK: - 下载页不能删掉音乐库

/// `measure()`（进下载页就会跑）里的 `purgeOrphans()` 只许删**下载文件夹**。
///
/// 音乐库根目录是 `<Downloads>/Music`，是同一个 root 的子目录。老写法「不在 items 里就删、
/// 只豁免 downloads.json」会把它连同 `music-downloads.json` 一起递归删掉 —— 所有下载的歌
/// 瞬间消失，索引也没了，重启无法恢复。这条测试锁住这个不可逆的破坏。
@Test @MainActor func measuringDownloadsNeverDeletesTheMusicLibrary() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "dl-purge-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    // 音乐库（与 App 里同构：视频库根目录下的 Music 子目录）+ 一首歌 + 它的索引。
    let musicRoot = root.appending(path: "Music")
    let songFolder = musicRoot.appending(path: "song-1")
    try FileManager.default.createDirectory(at: songFolder, withIntermediateDirectories: true)
    let songFile = songFolder.appending(path: "audio.m4a")
    try Data("audio".utf8).write(to: songFile)
    let index = musicRoot.appending(path: "music-downloads.json")
    try Data("[]".utf8).write(to: index)

    // 一个真正的孤儿（形如 UUID 的目录）。
    let orphan = root.appending(path: UUID().uuidString.lowercased())
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

    let library = DownloadLibrary(root: root, settings: DownloadSettings(defaults: freshDefaults("purge")))
    await library.measure()

    #expect(FileManager.default.fileExists(atPath: songFile.path), "音乐文件必须还在")
    #expect(FileManager.default.fileExists(atPath: index.path), "音乐索引必须还在")
    #expect(!FileManager.default.fileExists(atPath: orphan.path), "UUID 孤儿目录应当被清掉")
}

@Test func onlyUuidNamedDirectoriesAreDownloadFolders() {
    #expect(DownloadLibrary.isDownloadFolderName(UUID().uuidString.lowercased()))
    #expect(!DownloadLibrary.isDownloadFolderName("Music"))
    #expect(!DownloadLibrary.isDownloadFolderName("downloads.json"))
    #expect(!DownloadLibrary.isDownloadFolderName("Artwork"))
}

// MARK: - 同一张专辑在两环境各一条时，不能互相删除

@Test @MainActor func removingThisEnvironmentsAlbumKeepsTheOtherEnvironmentsCopy() async {
    let root = FileManager.default.temporaryDirectory.appending(path: "music-coll-rm-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = MusicDownloadLibrary(root: root)
    let first = UUID(), second = UUID()
    library.defaultEnvironmentID = first
    library.activeEnvironmentID = first

    let collection = MusicCollection(kind: .album, platform: .netease, collectionID: "same", title: "同名专辑")
    let aTrack = MusicTrack(platform: .netease, songID: "a-1", title: "A 歌", artists: ["人"])
    library.download([aTrack], from: collection)

    // 第二个环境同一张专辑、不同的歌。
    library.activeEnvironmentID = second
    let bTrack = MusicTrack(platform: .netease, songID: "b-1", title: "B 歌", artists: ["人"])
    library.download([bTrack], from: collection)

    // 本环境取到的必须是**自己**那条，列出的也必须是自己那首。
    // `MusicCollection.id` 是「平台:类型:专辑号」，必须用完整 id 查。
    let mine = try! #require(library.collection(id: collection.id))
    #expect(mine.environmentID == second)
    #expect(library.items(in: mine).map(\.id) == [bTrack.id])

    // 删本环境这张专辑：另一环境那条与它的歌必须完好。
    library.remove(collection: collection.id)
    #expect(library.visibleCollections.isEmpty)
    library.activeEnvironmentID = first
    #expect(library.visibleCollections.count == 1)
    #expect(library.visibleItem(for: aTrack) != nil)
}

// MARK: - 切环境暂停别环境的下载后，记录必须退回排队

@Test @MainActor func pausingAnotherEnvironmentsWorkLeavesItQueuedNotStuckDownloading() async {
    let root = FileManager.default.temporaryDirectory.appending(path: "music-pause-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = MusicDownloadLibrary(root: root)
    let first = UUID(), second = UUID()
    library.defaultEnvironmentID = first
    library.activeEnvironmentID = first

    // 排队一首（不真的跑网络：`schedule` 拿不到候选就会失败/停下，这里只关心状态记录）。
    let track = MusicTrack(platform: .netease, songID: "p-1", title: "歌", artists: ["人"])
    library.download([track])

    library.activeEnvironmentID = second
    library.pauseWorkForOtherEnvironments()

    // 关键：不能停在 `.downloading`（否则 `isActive` 恒真 → hasWork 恒真 → 屏幕常亮/
    // 后台任务常驻，且 `schedule()` 只捡 `.queued`，切回来也永远不重跑）。
    #expect(library.items.first?.isActive == false)
}


// MARK: - 源改名 / 线路开关（读写都必须分环境）

/// 这两个 store 的父类 `write()` 写的是构造时的 baseKey。只改读不改写就会「读 scoped、写裸 key」：
/// 在非默认环境里改名会落进默认环境的 key，再 reload 时改动凭空消失。
/// 这条测试必须先写、再重读，才能抓住那个不对称。
@Test @MainActor func sourceOverridesRoundTripInsideANonDefaultEnvironment() {
    let defaults = freshDefaults("overrides")
    let first = UUID(), second = UUID()
    let origin = URL(string: "https://example.com/sub")!
    let target = site("rename-me")

    let store = SourceOverrides(defaults: defaults)
    store.defaultEnvironmentID = first
    store.environmentID = second
    store.rename(target, origin: origin, to: "我的源")
    #expect(store.override(for: target, origin: origin)?.name == "我的源")

    // 写进的是 second 的 key，默认环境的裸 key 不能被污染。
    #expect(defaults.data(forKey: "sourceOverrides.v1.\(second.uuidString)") != nil,
            "必须写进本环境的 key")
    #expect(defaults.data(forKey: "sourceOverrides.v1") == nil,
            "不能把非默认环境的改动写进默认环境")

    // 同实例 reload 后仍在（读与写用的是同一个 key）。
    store.reloadForEnvironment()
    #expect(store.override(for: target, origin: origin)?.name == "我的源")

    // 换到默认环境：看不到这条改名。
    store.environmentID = first
    store.reloadForEnvironment()
    #expect(store.override(for: target, origin: origin) == nil)
}

@Test @MainActor func lineSettingsRoundTripInsideANonDefaultEnvironment() {
    let defaults = freshDefaults("lines")
    let first = UUID(), second = UUID()

    let store = LineSettings(defaults: defaults)
    store.defaultEnvironmentID = first
    store.environmentID = second
    store.setHidden(true, origin: URL(string: "https://example.com/s")!, sourceKey: "src", flag: "line-1")
    #expect(store.isHidden(origin: URL(string: "https://example.com/s")!, sourceKey: "src", flag: "line-1"))

    #expect(defaults.data(forKey: "lineSettings.v1.\(second.uuidString)") != nil)
    #expect(defaults.data(forKey: "lineSettings.v1") == nil)

    store.reloadForEnvironment()
    #expect(store.isHidden(origin: URL(string: "https://example.com/s")!, sourceKey: "src", flag: "line-1"))

    store.environmentID = first
    store.reloadForEnvironment()
    #expect(!store.isHidden(origin: URL(string: "https://example.com/s")!, sourceKey: "src", flag: "line-1"))
}
