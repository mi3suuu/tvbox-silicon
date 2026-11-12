import SwiftUI
import TVCore

/// Store as the Web Cast data source: it lists the same sources the app shows (every enabled
/// subscription plus the built-ins, in display order) and builds a ready `CatalogClient` for any of
/// them, so the web UI can browse, search and play *any* source the app can run.
extension Store: WebCastDataSource {
    func webCastState() async -> WebCastState {
        guard let config = subscription else {
            return WebCastState(sources: [], enabled: WebCastSettings.shared.enabled, port: WebCastSettings.shared.port)
        }
        let origin = config.origin
        // ⛔ 真删的源不进投屏列表。`sourceGroups(includeHidden: true)` 会把它们带回来
        // （它们同时写在 `hiddenSources` 里，而这里的 `isHidden` 只给灰卡、不剔除），
        // 于是网页端会列出一个用户已经删掉的源 —— 名字可见、还能从网页恢复。
        let sources = sourceGroups(includeHidden: true).flatMap(\.sites)
            .filter { !deletedSources.contains($0, origin: origin) }
            .map { site -> WebCastState.SourceInfo in
            let isHidden = hiddenSources.contains(site, origin: origin) || !vault.permits(site: site, fallback: origin)
            return WebCastState.SourceInfo(key: site.sourceKey, name: site.name,
                                           runtime: site.compatibility, hidden: isHidden)
        }
        return WebCastState(sources: sources, enabled: WebCastSettings.shared.enabled, port: WebCastSettings.shared.port)
    }

    func webCastClient(for sourceKey: String) async throws -> (CatalogClient, siteName: String) {
        guard let config = subscription,
              let site = config.sites.first(where: { $0.sourceKey == sourceKey }) else {
            throw TVError.unsupported(L10n.text("This source is no longer available."))
        }
        // The web UI browses, searches and plays through this one client, so a vault-hidden source
        // must be refused here — the `hidden` flag in `webCastState` only greys the card in the UI.
        guard !hiddenSources.contains(site, origin: config.origin),
              vault.permits(site: site, fallback: config.origin) else {
            throw TVError.unsupported(L10n.text("This source is hidden. Unlock the Privacy Vault to use it."))
        }
        let resolved = resolvedSite(site, origin: config.origin)
        let client = CatalogClient(site: resolved, origin: config.origin, jarURL: config.spiderURL).applying(config)
        return (client, site.name)
    }

    /// Applies a settings edit from the web UI (hide/show a source).
    func webCastSetHidden(_ key: String, hidden: Bool) {
        guard let config = subscription else { return }
        guard let site = config.sites.first(where: { $0.sourceKey == key }) else {
            NSLog("[webcast] webCastSetHidden: site not found for key=\(key)")
            return
        }
        NSLog("[webcast] webCastSetHidden key=\(key) hidden=\(hidden) site.sourceKey=\(site.sourceKey)")
        // 真删的源不能被「显示」请求救回来 —— 它已经不在 App 的任何列表里了，
        // 网页端只是陈旧视图。`deletedSources` 是唯一真相，网页端无权推翻。
        if !hidden, deletedSources.contains(site, origin: config.origin) {
            NSLog("[webcast] webCastSetHidden: refused, source is deleted key=\(key)")
            return
        }
        if hidden { hiddenSources.insert(site, origin: config.origin) }
        else { hiddenSources.setHidden([site], origin: config.origin, hidden: false) }
    }
}

// MARK: - 网页端另四张列表（直播 / 收藏 / 继续观看 / 下载）

/// 这四张表**必须走 App 自己的可见出口**，不能直接读原始集合：
/// `visibleHistory` / `visibleFavorites` / `DownloadLibrary.visibleItems()` 已经做了
/// 当前环境过滤（多环境隔离）+ 隐私保险库过滤。绕过它们会让网页把别的环境、
/// 或保险库藏起来的记录泄漏到电脑上 —— 这正是「切换环境后还残留上个环境信息」
/// 那个 bug 的同款成因。
extension Store {
    func webCastLive() async -> [WebCastState.LiveInfo] {
        // The playlist's own headers travel with it: `LiveSource.headers` is what the app passes when
        // it fetches an m3u (`HTTPClient.channels`), and a feed behind a Referer check refuses the
        // browser otherwise — the same "plays on the phone, not on the computer" gap as streams.
        subscription?.lives.map { live in
            WebCastState.LiveInfo(name: live.name, url: live.url.absoluteString, builtIn: live.isBuiltIn,
                                  headerID: ProxyHeaders.shared.store(live.headers), logo: "")
        } ?? []
    }

    func webCastFavorites() async -> [WebCastState.FavoriteInfo] {
        visibleFavorites.map { item in
            switch item {
            case .video(let video):
                return WebCastState.FavoriteInfo(kind: item.kind.rawValue, videoName: video.videoName,
                                                 sourceName: video.sourceName, poster: video.poster?.absoluteString ?? "",
                                                 episodeName: "", year: video.year ?? "")
            case .episode(let episode):
                return WebCastState.FavoriteInfo(kind: item.kind.rawValue, videoName: episode.video.videoName,
                                                 sourceName: episode.video.sourceName,
                                                 poster: episode.video.poster?.absoluteString ?? "",
                                                 episodeName: episode.episodeName, year: episode.video.year ?? "")
            case .live(let channel):
                return WebCastState.FavoriteInfo(kind: item.kind.rawValue, videoName: channel.name,
                                                 sourceName: channel.group, poster: channel.logo?.absoluteString ?? "",
                                                 episodeName: "", year: "")
            case .music(let track):
                return WebCastState.FavoriteInfo(kind: item.kind.rawValue, videoName: track.title,
                                                 sourceName: track.artists.joined(separator: ", "), poster: track.artwork?.absoluteString ?? "",
                                                 episodeName: "", year: "")
            case .cloud(let file):
                return WebCastState.FavoriteInfo(kind: item.kind.rawValue, videoName: file.fileName,
                                                 sourceName: file.folderName, poster: "",
                                                 episodeName: "", year: "")
            }
        }
    }

    func webCastHistory() async -> [WebCastState.HistoryInfo] {
        // 只报「看得见」的那条时间线；位置与总时长一并给出，网页据此画进度条与续播点。
        visibleHistory.map { entry in
            WebCastState.HistoryInfo(videoName: entry.context.videoName,
                                     episodeName: entry.context.episodeName,
                                     sourceName: entry.context.sourceName,
                                     poster: entry.context.poster?.absoluteString ?? "",
                                     progress: entry.progress, position: entry.position,
                                     duration: entry.duration, updatedAt: entry.updatedAt,
                                     completed: entry.completed)
        }
    }

    func webCastDownloads() async -> [WebCastState.DownloadInfo] {
        // 文件仍留在手机上，这里只暴露状态与进度，不提供下载地址。
        //
        // `visibleItems()` only filters by environment; the vault is a *separate* gate. The app's own
        // downloads screen wraps it in `vault.visibleDownloads(...)` (DownloadsView:28), so doing
        // without it here would show a locked source's episodes on the computer —片名、集名、
        // 海报、进度全都露出去，正是上面注释警告的那种泄漏。
        vault.visibleDownloads(DownloadLibrary.shared.visibleItems()).map { item in
            WebCastState.DownloadInfo(title: item.title, episode: item.episode,
                                      poster: item.poster?.absoluteString ?? "",
                                      status: item.status.rawValue, progress: item.fraction,
                                      failure: item.failure ?? "")
        }
    }
}
