import Foundation
import TVCore

// MARK: - 播放（收藏 / 剧集 / 历史）

extension Store {

    func playsInWatchPage(_ channel: Channel?) -> Bool {
        guard let scope = channel?.historyContext?.id else { return false }
        return watchPageScopes.contains(scope)
    }

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
