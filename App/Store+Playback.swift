import Foundation
import TVCore

// MARK: - 播放（收藏 / 剧集 / 历史）

extension Store {

    func playsInWatchPage(_ channel: Channel?) -> Bool {
        guard let scope = channel?.historyContext?.id else { return false }
        return watchPageScopes.contains(scope)
    }

    /// [mi3s] 二开：这一集是不是正挂在坞里（= 界面上画着小窗）。
    ///
    /// ⛔ 判据已换成**坞本身**（`videoTasks.tasks`），不再是「`miniPlayerActive` 为真且
    /// 这一集就是 `playing`」。
    ///
    /// 原来那套读的是 `playing` —— 全局单值，只能表达一集。用户要求坞里能同时挂多个、
    /// 且长按海报新开的那个**不影响已有的**，于是「这一集在坞里吗」必须按集去问坞，
    /// 而不能靠一个全局布尔 + 一个全局频道去推。
    ///
    /// `presentingPlayer` 那一道闸也随之删掉：它当初是为了挡住「点了缩成小窗但
    /// `onDisappear` 还没跑、scope 仍在前台」的那一帧。现在「在坞里」是**显式登记**的
    /// 事实（`VideoTaskCenter.add`），不存在推导，也就没有推导的空窗。
    func floatsInMiniPlayer(_ channel: Channel?) -> Bool {
        guard let channel else { return false }
        return videoTasks.tasks.contains { $0.channel == channel }
    }

    #if os(iOS)
    /// 把**前台这一集**交给坞：登记进坞，然后清掉前台那两个槽 —— **不停止播放**。
    ///
    /// 这是「返回时画面收进小窗继续播」的唯一实现点。为什么必须清前台槽：
    ///
    ///   · 一集要么在前台、要么在坞里。两边同时指向同一个 `PlaybackSession` 时，
    ///     前台那一侧的任何一次 `stopPlaying()`（换集、退出观看页的登出裁决）
    ///     都会把坞里那张卡片正在播的流一起停掉 —— 用户看到的是「小窗黑掉」；
    ///   · `store.playing` 还非 nil 时 `RootView` 的弹层判据会把全屏播放器判出来，
    ///     于是「返回主界面」的同时又弹一层播放器盖在主页上。
    ///
    /// 与 `stopPlaying()` 的分工：那个会跑会话收尾（历史存档、停流），这个**只摘槽**。
    func dockForeground() {
        guard let channel = playing else { return }
        let session = playbackSession(for: channel)
        videoTasks.dock(channel: channel, session: session, store: self)
        // 摘前台槽：`playing = nil` 的 didSet 只清 `activeSession` / `presentingPlayer`，
        // 不碰会话本身，所以坞里那一份继续播。
        playing = nil
    }

    /// **彻底退出某一集**（选集页/全屏播放页的「退出」键）。
    ///
    /// ★ 2026-11-12 用户裁决：「不止是关音频，而是彻底退出那个视频。」
    ///
    /// 与另外两条路的区别必须分清，否则就会出现「以为退出了其实还在播」：
    ///
    /// | 动作 | 结果 |
    /// |---|---|
    /// | `dockForeground()`（返回 / 左滑 / Back） | 画面进坞，**继续播** |
    /// | `stopPlaying()`（换集、登出裁决） | 停前台这一路，不动坞里别的 |
    /// | `quitPlayback(_:)`（退出键，就是这个） | 停 + **从坞里摘掉**这一集，彻底不留 |
    ///
    /// 为什么要额外摘坞：从坞里点卡片回到选集页后，那一集已经 `take` 出坞了；
    /// 但「返回时进了坞 → 又点回来 → 再点退出」这条链上，它会先被 `dockForeground`
    /// 登记回去。此时只 `stopPlaying()` 会让它留在坞里继续播。
    ///
    /// - Parameter channel: 要退掉的那一集；传 nil 时只停前台。
    func quitPlayback(_ channel: Channel?) {
        if let channel {
            videoTasks.removeAll(of: channel)
        }
        stopPlaying()
    }
    #endif

    func toggleFavorite(_ channel: Channel) { favorites.toggle(.live(channel)) }
    func isFavorite(_ channel: Channel) -> Bool { favorites.contains(.live(channel)) }

    func catalogClient(for video: FavoriteVideo) -> CatalogClient? {
        guard let config = subscription,
              let site = config.sites.first(where: { $0.origin(or: config.origin) == video.origin && $0.sourceKey == video.sourceKey }) else { return nil }
        return CatalogClient(site: resolvedSite(site, origin: config.origin), origin: config.origin, jarURL: config.spiderURL)
    }
    func reportMissingFavoriteSource() {
        error = L10n.text("This favorite's source is no longer in the current subscription. Restore that subscription to open it.")
    }

    func play(_ episode: FavoriteEpisode) {
        guard vault.permitsPlayback(sourceKey: episode.video.sourceKey, origin: episode.video.origin) else {
            error = L10n.text("This title is hidden. Unlock the Privacy Vault to watch it.")
            return
        }
        guard catalogClient(for: episode.video) != nil else { reportMissingFavoriteSource(); return }
        let position = episode.resumePosition(in: playbackHistory.entries(in: activeEnvironmentID))
        resume(PlaybackHistoryEntry(context: episode.historyContext(), position: position, duration: 0, updatedAt: Date()))
    }

    func play(_ file: FavoriteCloudFile) {
        guard let drive = CloudFiles.drive(key: file.driveKey) else {
            error = L10n.text("This file's drive is no longer in Cloud Files.")
            return
        }
        let cloud = CloudFile(id: file.fileID, name: file.fileName, isFolder: false, size: file.size)
        playFile(cloud, in: CloudFilesFolder(drive: drive, id: file.folderID, name: file.folderName, files: [cloud]))
    }

    func catalog(for channel: Channel) -> PlaybackCatalog? {
        guard let catalog = playbackCatalog, catalog.scope == channel.historyContext?.id else { return nil }
        return catalog
    }

    func nextEpisode(after channel: Channel) -> Episode? {
        guard let context = channel.historyContext else { return nil }
        return catalog(for: channel)?.playlist.next(after: context)
    }

    /// Whether the source behind `channel` may keep playing right now.
    ///
    /// Auto-advance, the Next button, and the queued episode all move within one source, so they
    /// inherit the permission checked when that source first started. But an unlock lapses (timeout,
    /// a screenshot, the app going to the background) while a hidden title is still on screen; the
    /// next episode must not then play on in the locked state. This re-checks at the moment of
    /// advance, so the one title the viewer was already watching can finish, but nothing after it.
    ///
    /// Cloud Files and live/URL channels carry no source identity, so they are never vault-hidden.
    func mayContinuePlaying(_ channel: Channel) -> Bool {
        guard let context = channel.historyContext else { return true }
        return vault.permitsPlayback(sourceKey: context.sourceKey, origin: context.origin)
    }

    /// Stops the hidden title and explains why, instead of silently letting the player sit on a dead
    /// frame. Called when an advance is refused because the source was re-hidden mid-title.
    func stopForHiddenSource() {
        stopPlaying()
        error = L10n.text("This title is hidden. Unlock the Privacy Vault to watch it.")
    }

    func previousEpisode(before channel: Channel) -> Episode? {
        guard let context = channel.historyContext else { return nil }
        return catalog(for: channel)?.playlist.previous(before: context)
    }

    /// The same episode on a transcoded line (FTY's 智 lines are the drive's own HLS) when the
    /// playing original can't play here. The same drive's line comes first: 夸父原1 → 夸父智1.
    func transcodedLine(for channel: Channel) -> Episode? {
        guard let context = channel.historyContext, let catalog = catalog(for: channel) else { return nil }
        let current = context.episodeFlag
        let candidates = catalog.video.episodes.filter {
            $0.name == context.episodeName && $0.flag != current && $0.flag.contains("智")
        }
        let sameDrive = current.replacingOccurrences(of: "原", with: "智").replacingOccurrences(of: "无限", with: "智")
        return candidates.first { $0.flag == sameDrive } ?? candidates.first
    }

    /// The source a watched title came from. Any enabled subscription can hold it: it is found by its own origin
    /// and original key. Nil for Cloud Files, and once the source is gone.
    func historyClient(_ entry: PlaybackHistoryEntry) -> CatalogClient? {
        guard entry.context.sourceKey != CloudFiles.sourceKey, let config = subscription,
              let site = config.sites.first(where: { $0.origin(or: config.origin) == entry.context.origin && $0.sourceKey == entry.context.sourceKey })
        else { return nil }
        return CatalogClient(site: resolvedSite(site, origin: config.origin), origin: config.origin, jarURL: config.spiderURL).applying(config)
    }
}
