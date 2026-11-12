#if DEBUG
import AVFoundation
import SwiftUI
import TVCore
#if os(macOS)
import WebKit
#endif

/// Debug-only launch hooks for screenshot QA on simulators without input:
/// `simctl launch <device> <bundle> -qaSection live -qaPage channels:0`.
/// Launch arguments land in UserDefaults' argument domain, so nothing persists.
enum QALaunch {
    static var section: AppSection? { UserDefaults.standard.string(forKey: "qaSection").flatMap(AppSection.init(rawValue:)) ?? sectionByKey }
    private static var sectionByKey: AppSection? {
        switch UserDefaults.standard.string(forKey: "qaSection") {
        case "home": .home
        case "discover": .discover
        case "live": .live
        case "music": .music
        case "manga": .manga
        case "search": .search
        case "sites": .sites
        case "favorites": .favorites
        case "downloads": .downloads
        case "files": .files
        case "history": .history
        case "settings": .settings
        case "messages": .messages
        case "more": .more
        default: nil
        }
    }
    static var page: String? { UserDefaults.standard.string(forKey: "qaPage") }
    /// `-qaScroll live` scrolls Watch Now to that section once recommendations have loaded.
    static var scrollTarget: String? { UserDefaults.standard.string(forKey: "qaScroll") }

    #if os(macOS)
    @MainActor private static func webView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for child in view.subviews { if let web = webView(in: child) { return web } }
        return nil
    }
    #endif

    @MainActor static func start(_ store: Store) async {
        #if os(iOS)
        // Temporary screenshot sessions only; a regular launch restores normal auto-lock.
        UIApplication.shared.isIdleTimerDisabled = UserDefaults.standard.bool(forKey: "qaKeepAwake")
        UserDefaults.standard.removeObject(forKey: "qaDiscoverTrailer")
        #endif
        // `-qaAListServer <address>` adds that AList server to Cloud Files, as the Add form would.
        if let address = UserDefaults.standard.string(forKey: "qaAListServer"), let url = try? WebAddress.resolve(address) {
            if let server = await AList.probe(url) { _ = try? AListServers.add([server]) }
        }
        // ⚠️ 这一段必须写在**门控之前**。
        //
        // 下面的 `guard` 只要 section / page / qaPlay / qaDownload / qaPlayLive / qaPlayURL
        // 一个都没有就 return —— 而换皮参数不属于其中任何一个。第一版写在 guard 之后，
        // 结果 `-qaBiliSkin 1` 单独传入时整段被跳过（截图与不传一模一样，就是这个原因）。
        //
        // 换皮走 UserDefaults 而不是只认启动参数：`apps.launch` 的 args 只有首次冷启动
        // 会进 argument domain，之后 relaunch 全部读不到（本仓库已实测过三次）。
        // 换皮只在 iOS 存在（`PlaySkin` 定义在 BiliSkin.swift 的 `#if os(iOS)` 里）。
        // 不加守卫时，tvOS / macOS 的 QA 包在这里直接编译失败。
        #if os(iOS)
        if UserDefaults.standard.object(forKey: "qaBiliSkin") != nil {
            UserDefaults.standard.set(true, forKey: "qaBiliSkin")
            UserDefaults.standard.set(PlaySkin.bilibili.rawValue, forKey: PlaySkin.key)
        } else {
            // ⚠️ 必须**双向**写，和下面 `qaBiliFullScreen` 的做法一致。
            //
            // 只写不清的后果（真机实测踩到）：某次用 `-qaBiliSkin 1` 截过图之后，
            // `playSkin` 就被永久写成 `bilibili`；这个键是持久化的，之后每次
            // 正常启动都读到 `bilibili` —— 用户看到的是「整个 App 都变成哔哩哔哩，
            // One 界面不见了」。而 `PlaySkin.adoptCurrentIfNeeded()` 只在键
            // 不存在时才写，救不回来。
            //
            // 所以这里必须把 `qaBiliSkin` 关掉，并把 `playSkin` 交还给
            // `PlaySkin.current` 的自然推断（没有显式选择时不落盘，
            // 由 `adoptCurrentIfNeeded` 按旧布尔决定 one / native）。
            UserDefaults.standard.set(false, forKey: "qaBiliSkin")
            if UserDefaults.standard.string(forKey: PlaySkin.key) == PlaySkin.bilibili.rawValue {
                UserDefaults.standard.removeObject(forKey: PlaySkin.key)
            }
        }
        #endif
        // `-qaBiliFullScreen 1`：直接进全屏，用来看全屏控件与右侧设置面板。
        //
        // ⚠️ 必须**双向**写。`watchFullScreen` 是 @AppStorage 持久键，只写不清的后果：
        // 截过一次全屏之后，之后每次不带参数启动都直接进全屏，而全屏控件几秒后自动
        // 收起 —— 实测连续三张截图全是同一块纯色(9,11,13)，看起来像「三态都没生效」，
        // 实际是三次都在全屏黑底上。
        if UserDefaults.standard.object(forKey: "qaBiliFullScreen") != nil {
            UserDefaults.standard.set(true, forKey: "watchFullScreen")
        } else {
            UserDefaults.standard.set(false, forKey: "watchFullScreen")
        }
        // `-qaBiliSettings 1`：起播后自动展开设置面板，给截图用。
        //
        // ⚠️ 每次启动都要**按本次参数重设，并在没传时清掉**。第一版只写不清，
        // 于是下一次不带参数启动，面板仍然自动展开 —— 实测把双列与全屏两张图
        // 都盖成了同一张设置面板，看起来像「三态没生效」。
        if UserDefaults.standard.object(forKey: "qaBiliSettings") != nil {
            UserDefaults.standard.set(true, forKey: "qaBiliOpenSettings")
        } else {
            UserDefaults.standard.removeObject(forKey: "qaBiliOpenSettings")
        }
        guard section != nil || page != nil || UserDefaults.standard.string(forKey: "qaPlay") != nil
                || UserDefaults.standard.string(forKey: "qaDownload") != nil
                || UserDefaults.standard.string(forKey: "qaPlayLive") != nil
                || UserDefaults.standard.string(forKey: "qaPlayURL") != nil else { return }
        if UserDefaults.standard.bool(forKey: "qaResetHistory") { store.playbackHistory.clear() }
        #if os(macOS)
        // `-qaWindowSnapshot <png> [-qaWindowSize 1230x830] [-qaSnapshotDelay 20]`: draws the main window into a PNG
        // itself, for a Mac with no display or no screen-recording permission.
        if let path = UserDefaults.standard.string(forKey: "qaWindowSnapshot") {
            Task { @MainActor in
                let size = (UserDefaults.standard.string(forKey: "qaWindowSize") ?? "").split(separator: "x").compactMap { Double($0) }
                try? await Task.sleep(for: .seconds(1))
                if size.count == 2 { NSApp.windows.first { $0.isVisible }?.setContentSize(NSSize(width: size[0], height: size[1])) }
                // `-qaResizeSheet 1300x850`: resizes the window showing a web page (a sign-in sheet) as a person would, while it loads.
                let resize = (UserDefaults.standard.string(forKey: "qaResizeSheet") ?? "").split(separator: "x").compactMap { Double($0) }
                if resize.count == 2 {
                    try? await Task.sleep(for: .seconds(6))
                    for window in NSApp.windows where window.isVisible {
                        if let view = window.contentView?.superview, Self.webView(in: view) != nil { window.setContentSize(NSSize(width: resize[0], height: resize[1])) }
                    }
                }
                let delay = UserDefaults.standard.object(forKey: "qaSnapshotDelay") == nil ? 20 : UserDefaults.standard.double(forKey: "qaSnapshotDelay")
                try? await Task.sleep(for: .seconds(delay))
                // The main window into the path; each other visible window (a sheet, a popover) beside it as <path>-1.png, -2…
                for (index, window) in NSApp.windows.filter(\.isVisible).enumerated() {
                    guard let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let file = index == 0 ? path : (path as NSString).deletingPathExtension + "-\(index).png"
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
                    // A web view draws in another process, so cacheDisplay leaves it blank: its own snapshot goes beside
                    // as <file>-web.png, with the window's size limits and the page zoom in <file>.txt.
                    if let web = Self.webView(in: view) {
                        let base = (file as NSString).deletingPathExtension
                        let info = "frame=\(window.frame) resizable=\(window.styleMask.contains(.resizable)) min=\(window.minSize) contentMin=\(window.contentMinSize) web=\(web.bounds.size) pageZoom=\(web.pageZoom)\n"
                        try? info.write(toFile: base + ".txt", atomically: true, encoding: .utf8)
                        if let image = try? await web.takeSnapshot(configuration: nil), let tiff = image.tiffRepresentation {
                            try? NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: base + "-web.png"))
                        }
                    }
                }
            }
        }
        #endif
        // `-qaEnhance up,smooth` saves the Picture settings (unlike passing the keys, which would pin them
        // and stop the player's menu from switching them).
        if let enhance = UserDefaults.standard.string(forKey: "qaEnhance") {
            UserDefaults.standard.set(enhance.contains("up"), forKey: VideoEnhancement.upscaleKey)
            UserDefaults.standard.set(enhance.contains("smooth"), forKey: VideoEnhancement.smoothKey)
        }
        if UserDefaults.standard.bool(forKey: "qaResetPlayerSettings") {
            EpisodeSkipSettings().saveGlobal(defaults: store.playbackDefaults)
            for key in store.playbackDefaults.dictionaryRepresentation().keys where key.hasPrefix("episodeSkip.v1.") || key == "episodeSkip.auto.v2" {
                store.playbackDefaults.removeObject(forKey: key)
            }
        }
        if UserDefaults.standard.bool(forKey: "qaResetCache") { MediaCache.shared.clear() }
        // `-qaConfig <url-or-path>`: import a Mi3s config export (yingxia-config.json).
        // Accepts an http(s) URL (fetched) or a file name / absolute path inside the app
        // sandbox (pushed in via `devicectl device copy to --domain-type appDataContainer`).
        // Restores every subscription plus its cached document, so sources come back even
        // where the original address is unreachable.
        if let configRef = UserDefaults.standard.string(forKey: "qaConfig") {
            let data: Data?
            if configRef.hasPrefix("http://") || configRef.hasPrefix("https://") {
                data = try? await URLSession.shared.data(from: URL(string: configRef)!).0
            } else {
                let docURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let candidate = configRef.hasPrefix("/")
                    ? URL(fileURLWithPath: configRef)
                    : docURL.appendingPathComponent(configRef)
                data = try? Data(contentsOf: candidate)
            }
            if let data, let config = SubscriptionConfig.decode(data) {
                store.importConfig(config, overwrite: true)
            }
        }
        if let subscription = UserDefaults.standard.string(forKey: "qaSubscription") {
            // With isolated data the QA subscription is the only one, as before several subscriptions:
            // one left from an earlier run would come first and win the duplicate source keys.
            if UserDefaults.standard.bool(forKey: "qaIsolatedData") {
                for entry in store.subscriptions where entry.address != subscription { store.removeSubscription(entry) }
            }
            await store.importSubscription(address: subscription)
        }
        else if section != .discover, store.subscription == nil, !Distribution.isAppStore { await store.importSubscription(address: Store.defaultURL) }
        if QASweep.enabled, let config = store.subscription { Task.detached(priority: .utility) { await QASweep.run(config) } }
        // `-qaSeedHistory <source key>:<video id>` records that video's first episode as part watched, for Watch Now's
        // Up Next and Continue Watching.
        if let seed = UserDefaults.standard.string(forKey: "qaSeedHistory"), let config = store.subscription {
            let parts = seed.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let site = config.sites.first(where: { $0.key == parts[0] }) {
                let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL).applying(config)
                if let video = try? await client.detail(parts[1]), let episode = video.episodes.first {
                    store.playbackHistory.record(PlaybackHistoryContext(origin: config.origin, site: site, video: video, episode: episode),
                                                 position: 30, duration: 120)
                }
            }
        }
        if let section { store.section = section }
        if let page, page.hasPrefix("search:") {
            // Let the tab settle first: switching sections suspends a search that is already running.
            try? await Task.sleep(for: .seconds(2))
            store.searchVideos(String(page.dropFirst(7)))
        }
        // `-qaPlayLive [<platform>:]<room>` opens a live room (Bilibili by default) in the player.
        if let target = UserDefaults.standard.string(forKey: "qaPlayLive") {
            let parts = target.split(separator: ":", maxSplits: 1).map(String.init)
            if let platform = LivePlatform(rawValue: parts.count == 2 ? parts[0] : "bilibili"), let room = parts.last,
               let url = URL(string: "\(platform.scheme)://room/\(room)") {
                store.playing = Channel(name: "Live \(room)", group: platform.name, url: url)
            }
        }
        // `-qaPlayURL <address>` plays a media link as it is (an MKV on a local server, say); with `-qaResume <seconds>`,
        // from there, as a saved position resumes.
        if let address = UserDefaults.standard.string(forKey: "qaPlayURL"), let url = URL(string: address) {
            let resume = UserDefaults.standard.double(forKey: "qaResume")
            store.playing = Channel(name: url.lastPathComponent, group: "QA", url: url, resumePosition: resume > 0 ? resume : nil)
        }
        // `-qaPlay <site key>:<video id>[:<episode index>]` opens that source's video in the player.
        if let target = UserDefaults.standard.string(forKey: "qaPlay"), let config = store.subscription {
            let parts = target.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count >= 2, let site = config.sites.first(where: { $0.key == parts[0] }) {
                let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL)
                do {
                    let video = try await client.detail(parts[1])
                    let index = min(parts.count > 2 ? Int(parts[2]) ?? 0 : 0, max(0, video.episodes.count - 1))
                    if video.episodes.indices.contains(index) {
                        let episode = video.episodes[index]
                        store.playing = store.catalogChannel(try await client.playback(episode), video: video, episode: episode, client: client)
                    }
                } catch { store.error = error.localizedDescription }
            }
        }
        // `-qaDownload <site key>:<video id>[:<count>]` queues that video's first episodes (2 by default).
        if let target = UserDefaults.standard.string(forKey: "qaDownload"), let config = store.subscription {
            let parts = target.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count >= 2, let site = config.sites.first(where: { $0.key == parts[0] }) {
                do {
                    let video = try await CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL).detail(parts[1])
                    for episode in video.episodes.prefix(parts.count > 2 ? Int(parts[2]) ?? 2 : 2) {
                        DownloadLibrary.shared.download(DownloadSource(site: site, videoID: parts[1], episode: episode), title: video.name,
                                                        poster: video.poster, posterHeaders: video.posterHeaders)
                    }
                } catch { store.error = error.localizedDescription }
            }
        }
        if let page, page.hasPrefix("play-source:"), let config = store.subscription {
            let key = String(page.dropFirst("play-source:".count))
            do {
                guard let site = config.sites.first(where: { $0.key == key }) else { throw QASweep.Failure(message: "Source not found") }
                let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL).applying(config)
                var videos: [Video]
                if let query = UserDefaults.standard.string(forKey: "qaVideoQuery") {
                    videos = try await QASweep.limit(60) { try await client.list(category: nil, query: query, page: 1).videos }
                } else {
                    let home = try await QASweep.limit(60) { try await client.home() }
                    videos = home.videos
                    if videos.isEmpty, let category = home.categories.first {
                        videos = try await QASweep.limit(60) { try await client.list(category: category.id, query: "", page: 1).videos }
                    }
                }
                let videoID = UserDefaults.standard.string(forKey: "qaVideoID")
                guard let first = videoID.flatMap({ id in videos.first { $0.id == id } }) ?? videos.first else { throw QASweep.Failure(message: "No videos") }
                let video = try await QASweep.limit(60) { try await client.detail(first.id) }
                let selectedEpisode = UserDefaults.standard.string(forKey: "qaEpisodeName")
                // `-qaEpisodeFlag <text>` keeps to lines whose name contains it (嘟嘟 for Baidu).
                let line = UserDefaults.standard.string(forKey: "qaEpisodeFlag")
                let episodes = line.map { line in video.episodes.filter { $0.flag.contains(line) } } ?? video.episodes
                guard let episode = selectedEpisode.flatMap({ name in episodes.first { $0.name == name } ?? episodes.first { $0.name.contains(name) } })
                    ?? (selectedEpisode == nil ? episodes.first : nil) else { throw QASweep.Failure(message: "No episodes") }
                // Long enough for a Baidu or Aliyun line's sign-in code to be scanned (PluginSignIn).
                let channel = try await QASweep.limit(240) { try await client.playback(episode) }
                let start = UserDefaults.standard.object(forKey: "qaStartAt") == nil ? nil : UserDefaults.standard.double(forKey: "qaStartAt")
                store.playing = store.catalogChannel(channel, video: video, episode: episode, client: client, resumePosition: start)
            } catch {
                store.error = error.localizedDescription
                let file = URL.cachesDirectory.appending(path: "qa-playback.json")
                try? JSONSerialization.data(withJSONObject: ["source": key, "stage": "resolve", "error": error.localizedDescription]).write(to: file, options: .atomic)
            }
        }
        // `-qaPage play-file:<quark|uc|alist|drive key>:<folder>` plays the folder's first video, or with
        // `-qaFileName <text>` the first whose name contains it, as choosing it in Cloud Files does.
        if let page, page.hasPrefix("play-file:") {
            let parts = page.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count == 3, let drive = filesDrive(parts[1]) {
                do {
                    let files = try await CloudFiles.list(drive, folder: parts[2])
                    let wanted = UserDefaults.standard.string(forKey: "qaFileName")
                    guard let file = files.first(where: { drive.plays($0) && (wanted == nil || $0.name.contains(wanted!)) }) else { throw QASweep.Failure(message: "No file") }
                    store.playFile(file, in: CloudFilesFolder(drive: drive, id: parts[2], name: folderName(parts[2], drive),
                                                              files: files.filter { $0.kind == file.kind && drive.plays($0) }))
                } catch { store.error = error.localizedDescription }
            }
        }
        if page == "resume-last", let entry = store.playbackHistory.entries.first {
            await store.resumeHistory(entry)
        }
        // ⛔ 地址必须是 **guest 能访问到的宿主**，不能写 `127.0.0.1`。
        //
        // `127.0.0.1` 在 guest 里指的是 guest 自己 —— vphone 的虚拟机里没有这个服务，
        // 于是 AVPlayer 拿到的 item 永远停在「暂时播放不了」。后果不只是没画面：
        // **AVPlayer 没进入播放态，App 就拿不到后台保活资格，一切到后台立刻被系统杀掉**
        // （实测 `devicectl info processes` 里进程数直接变 0），PiP 自然起不来。
        //
        // `192.168.64.1` 是宿主在 Virtualization.framework 的 NAT 网段里的地址；
        // fixture 服务用 `--bind 0.0.0.0` 就能被 guest 访问。
        // 环境变量 `QA_FIXTURE_HOST` 可以覆盖（模拟器上仍可用 127.0.0.1）。
        let fixtureHost = UserDefaults.standard.string(forKey: "qaFixtureHost") ?? "192.168.64.1"
        // `-qaClipPath <path>` 直接播设备上的本地文件。
        //
        // 为什么需要它：vphone 的 guest 网络打不到宿主（试过 192.168.64.1 / 192.168.124.6 /
        // 10.211.55.2，fixture 日志全空），所以 `http://<host>:8765/clip.mp4` 在 VM 上取不到流。
        // 拿不到流 → AVPlayer 不进播放态 → 截图静止、后台立刻被回收 → PiP 无从验证。
        //
        // 用 `pymobiledevice3 afc push` 把片段放进 guest（`/var/mobile/Media`）后，
        // 用 `-qaClipPath /var/mobile/Media/DCIM/clip.mp4` 就能真播起来。
        if page == "player", let clip = UserDefaults.standard.string(forKey: "qaClipPath") {
            store.playing = Channel(name: "测试频道 01", url: URL(fileURLWithPath: clip))
        } else if page == "player", let url = URL(string: "http://\(fixtureHost):8765/clip.mp4") {
            store.playing = Channel(name: "测试频道 01", url: url)
        }
        if page == "player-error", let url = URL(string: "http://127.0.0.1:8765/missing.mp4") {
            store.playing = Channel(name: "无法播放的频道", url: url)
        }
        // A live channel whose stream never answers, from Scripts/test-tv-ui.sh's server.
        if page == "player-stall", let url = URL(string: "http://127.0.0.1:8776/stall.m3u8") {
            store.playing = Channel(name: "卡住的直播", url: url)
        }
    }

    /// "quark", "uc", "alist" (the first AList server) or a drive's key.
    static func filesDrive(_ spec: String) -> CloudFilesDrive? {
        spec == "alist" ? CloudFiles.drives().first { if case .alist = $0 { true } else { false } } : CloudFiles.drive(key: spec)
    }

    static func folderName(_ folder: String, _ drive: CloudFilesDrive) -> String {
        folder == drive.root ? drive.name : (folder as NSString).lastPathComponent
    }

    /// The pushed page to show as the section's root, so detail screens can be captured without taps.
    @MainActor @ViewBuilder static func page(for section: AppSection, store: Store) -> some View {
        // `-qaPage one-preview -qaOneShape <column|split|fullBleed|halfFold>`:
        // One 皮肤按**真实窗口尺寸**渲染一份固定 mock 数据，用来和真 One 截图逐像素比对。
        // 不读订阅、不连网络，所以不受「本机没配订阅 / 网络慢」影响 —— 这是唯一能
        // 稳定复现四种形态版式的入口（真机折叠只能手掰，模拟器又要先过播放链路）。
        if page == "one-preview" {
            OneSkinQAHost(shapeKey: UserDefaults.standard.string(forKey: "qaOneShape") ?? "column")
        // Pages that need no subscription, so an App Store build (`-qaAppStore 1`) can show them before one is added.
        } else if section == self.section, store.subscription == nil, page == "cloud-accounts" {
            CloudDriveView()
        } else if section == self.section, page == "subtitle-style" {
            SubtitleStyleView()
        } else if section == self.section, page == "speed-test" {
            // `-qaPage speed-test`: opens the speed / grouping page straight away, so a build can be
            // checked for opening it without driving the settings list.
            SourceSpeedTestView()
        } else if page == "speed-lab" {
            // `-qaPage speed-lab`: the sheet the Sources page opens — incremental sweeps, per-group
            // measurement, batch filing and batch routing. It is a sheet on that page, so a deep link
            // is the only way to land on it without a tap.
            SourceSpeedLab()
        } else if section == self.section, let page, let config = store.subscription {
            let parts = page.split(separator: ":", maxSplits: 2).map(String.init)
            switch parts.first {
            case "site":
                if let site = config.sites.first(where: { $0.key == parts.dropFirst().first }) {
                    SiteView(site: site, origin: config.origin, jarURL: config.spiderURL, initialQuery: UserDefaults.standard.string(forKey: "qaQuery") ?? "")
                }
            case "detail":
                if parts.count == 3, let site = config.sites.first(where: { $0.key == parts[1] }),
                   // `-qaVideoName`, `-qaVideoPoster` and `-qaVideoRemarks` stand in for the list card a real video opens from.
                   let video = Video(json: ["vod_id": .string(parts[2]), "vod_name": .string(UserDefaults.standard.string(forKey: "qaVideoName") ?? "测试影片 \(parts[2])"),
                                            "vod_pic": .string(UserDefaults.standard.string(forKey: "qaVideoPoster") ?? "http://127.0.0.1:8765/poster.png"),
                                            "vod_remarks": .string(UserDefaults.standard.string(forKey: "qaVideoRemarks") ?? "更新至 36 集")],
                                     origin: config.origin) {
                    VideoDetailView(video: video, client: CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL))
                }
            case "open-detail":
                if parts.count == 3, let site = config.sites.first(where: { $0.key == parts[1] }),
                   let video = Video(json: ["vod_id": .string(parts[2]), "vod_name": .string("测试影片 \(parts[2])")], origin: config.origin) {
                    RouteLink { VideoDetailView(video: video, client: CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL)) } label: {
                        Text("Open video").font(.title2).padding(24)
                    }
                    .accessibilityIdentifier("qa.open-detail")
                }
            case "channels":
                if let index = Int(parts.dropFirst().first ?? ""), config.lives.indices.contains(index) {
                    ChannelListView(source: config.lives[index])
                }
            // `-qaPage folder:<quark|uc|alist|drive key>:<folder>` opens that Cloud Files folder.
            case "folder":
                if parts.count == 3, let drive = filesDrive(parts[1]) {
                    CloudFolderView(drive: drive, folder: parts[2], name: folderName(parts[2], drive))
                }
            case "alist-add": QASheet { AListServerForm(server: AListServer(name: "", address: "")) {} }
            case "runtime": RuntimeView()
            case "logs": DiagnosticsView()
            case "feedback": FeedbackView()
            #if os(tvOS)
            case "telegram": TelegramGroupView()
            #endif
            case "cache": CacheSettingsView()
            #if os(iOS)
            case "playback": PlaybackSettingsView()
            case "privacy": PrivacySettingsView()
            #endif
            case "licenses": LicensesView()
            case "bilibili-account": BilibiliAccountView()
            case "douyin-account": DouyinAccountView()
            #if !os(tvOS)
            case "douyin-login": DouyinLoginView { _ in }
            #endif
            #if os(iOS)
            // The sheet a scanned Apple TV code opens, for a TV at a made-up address.
            case "douyin-handoff":
                if let link = DouyinHandoff.Link(URL(string: "yingxia://douyin-login?host=192.168.1.20&port=50000&key=" + String(repeating: "A", count: 43))!) {
                    DouyinHandoffView(link: link)
                }
            #endif
            case "bilibili-live": if let platform = LivePlatform(rawValue: "bilibili") { LivePlatformView(platform: platform) }
            // `-qaPage live:<douyu|huya|douyin|bilibili>`, with `-qaQuery <text>` to show its search.
            case "live":
                if let platform = parts.dropFirst().first.flatMap(LivePlatform.init(rawValue:)) {
                    LivePlatformView(platform: platform, initialQuery: UserDefaults.standard.string(forKey: "qaQuery") ?? "")
                }
            case "danmaku-list": QADanmakuList()
            #if !os(tvOS)
            case "danmaku-settings": QADanmakuSettings()
            #endif
            // `-qaPage cloud-login:<quark|uc|baidu|aliyun>`; `cloud-accounts` shows the accounts page.
            case "cloud-login": CloudQRLoginView(drive: parts.dropFirst().first.flatMap(CloudDriveQRLogin.Drive.init(rawValue:)) ?? .quark) {}
            case "cloud-accounts": CloudDriveView()
            #if os(macOS)
            // `-qaPage drive-sign-in:<quark|uc>`: the Mac's sign-in sheet on the drive's own page.
            case "drive-sign-in":
                if let provider = parts.dropFirst().first.flatMap(CloudProvider.init(rawValue:)), provider.signsInOnWeb {
                    QASheet { CloudLoginView(provider: provider) { _, _ in } }
                }
            #endif
            #if os(iOS)
            // `-qaPage web-sign-in:<bilibili|quark|uc|baidu|aliyun>`: the service's sign-in sheet; with
            // `-qaShowCode 1` it opens on the code for another phone.
            case "web-sign-in":
                if let service = parts.dropFirst().first.flatMap(WebSignIn.init(rawValue:)) {
                    QASheet {
                        WebSignInView(service: service, showingCode: UserDefaults.standard.bool(forKey: "qaShowCode"), signedIn: {}) {
                            if let drive = CloudDriveQRLogin.Drive(rawValue: service.rawValue) { CloudQRLoginView(drive: drive) {} }
                            else { ScrollView { BilibiliCodeSignIn { _ in }.padding(24) }.screenBackdrop() }
                        }
                    }
                }
            #endif
            #if DEBUG
            // `-qaPage plugin-sign-in:<baidu|aliyun>`: a source's sign-in prompt with a made-up code.
            case "plugin-sign-in":
                if let prompt = PluginSignIn.Prompt.sample(drive: parts.dropFirst().first ?? "baidu") { QASheet { PluginSignInView(prompt: prompt) } }
            #if !os(tvOS)
            // `-qaPage catpaw-sign-in -qaCatPawBundle <index.js address> -qaCatPawSource /spider/<key>/3`: UC's TV token
            // sheet against that bundle (on iPhone and iPad, a simulator with NodeMobile).
            case "catpaw-sign-in":
                let bundle = UserDefaults.standard.string(forKey: "qaCatPawBundle") ?? ""
                let source = UserDefaults.standard.string(forKey: "qaCatPawSource") ?? "/spider/wogg/3"
                let entry = try? JSONSerialization.data(withJSONObject: ["key": "qa_catpaw", "name": "CatPawOpen", "type": 3, "api": bundle, "catPawOpen": source])
                if let origin = URL(string: bundle), let entry, let site = try? JSONDecoder().decode(Site.self, from: entry) {
                    QASheet { CatPawSignInView(client: CatalogClient(site: site, origin: origin), provider: "ucToken") {} }
                }
            #endif
            #endif
            default: EmptyView()
            }
        }
    }

    static func overrides(_ section: AppSection) -> Bool {
        guard section == self.section, let page else { return false }
        return ["site", "detail", "open-detail", "channels", "runtime", "logs", "feedback", "telegram", "cache", "playback", "privacy", "licenses", "cloud-login", "cloud-accounts", "subtitle-style", "speed-test", "drive-sign-in", "bilibili-account", "douyin-account", "douyin-login", "douyin-handoff", "bilibili-live", "live", "danmaku-list", "danmaku-settings", "web-sign-in", "plugin-sign-in", "catpaw-sign-in", "folder", "alist-add", "one-preview"].contains(page.split(separator: ":").first.map(String.init) ?? "")
    }
}

/// Shows a page the app presents as a sheet the same way, over an empty page.
private struct QASheet<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var shown = false
    var body: some View {
        Color.clear.task { shown = true }.sheet(isPresented: $shown) { content() }
    }
}

/// Debug-only on-device source sweep: `-qaSection settings -qaSweep 1 [-qaSweepWorkers 1] [-qaSweepFresh 1] [-qaSweepHomeTimeout 60] [-qaSweepRuntime javascript] [-qaSweepPorted 1]`.
/// `-qaSweepPorted 1` runs only sources with a bundled lite port; each record then says whether the port or the JAR answered.
/// Use one worker for JAR sources: the embedded runtime keeps two plugin runtimes, so parallel sources evict each other.
/// Runs every source the platform can run through the app's own CatalogClient
/// (home -> category -> detail -> playback -> first media bytes) and writes
/// Library/Caches/qa-sweep/results.json after each source, so a relaunch resumes where it stopped.
enum QASweep {
    struct Record: Codable, Sendable {
        var key: String, name: String, type: Int, api: String, runtime: String, hidden: Bool
        var ok = false
        var stage = "home"
        var error: String?
        var steps: [String] = []
        var seconds = 0.0
    }
    struct Timeout: LocalizedError { let seconds: Double; var errorDescription: String? { "timed out after \(Int(seconds))s" } }
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "qaSweep") }
    static let folder = URL.cachesDirectory.appending(path: "qa-sweep")

    static func run(_ config: Subscription) async {
        await PluginLocator.shared.use(config.pluginArchives)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "results.json")
        let fresh = UserDefaults.standard.bool(forKey: "qaSweepFresh")
        let previous = fresh ? [] : ((try? JSONDecoder().decode([Record].self, from: Data(contentsOf: file))) ?? [])
        let recorder = Recorder(file: file, records: previous)
        let done = Set(previous.map(\.key))
        let only = UserDefaults.standard.string(forKey: "qaSweepRuntime")
        let ported = UserDefaults.standard.bool(forKey: "qaSweepPorted")
        let sites = config.sites.filter { !done.contains($0.key) && (only == nil || "\($0.runtime)" == only) && (!ported || $0.runsLitePort) }
        let workers = max(1, UserDefaults.standard.integer(forKey: "qaSweepWorkers").nonZero ?? 3)
        await recorder.status("running \(sites.count) of \(config.sites.count) sources, \(done.count) already done")
        await withTaskGroup(of: Void.self) { group in
            var iterator = sites.makeIterator()
            for _ in 0..<workers { if let site = iterator.next() { group.addTask { await recorder.add(test(site, config)) } } }
            while await group.next() != nil {
                if let site = iterator.next() { group.addTask { await recorder.add(test(site, config)) } }
            }
        }
        await recorder.status("finished")
    }

    static func test(_ site: Site, _ config: Subscription) async -> Record {
        var record = Record(key: site.key, name: site.name, type: site.type, api: site.api, runtime: "\(site.runtime)", hidden: site.hidden)
        let started = Date()
        defer { record.seconds = Date().timeIntervalSince(started) }
        guard site.canBrowse(jarURL: config.spiderURL) else {
            record.stage = "support"; record.error = site.compatibility
            return record
        }
        let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL).applying(config)
        do {
            let homeLimit = UserDefaults.standard.double(forKey: "qaSweepHomeTimeout")
            let home = try await limit(homeLimit > 0 ? homeLimit : 120) { try await client.home() }
            record.steps.append("home: \(home.categories.count) categories, \(home.videos.count) videos")
            var videos = home.videos
            if videos.isEmpty {
                record.stage = "category"
                for category in home.categories.prefix(3) {
                    do {
                        videos = try await limit(60) { try await client.list(category: category.id, query: "", page: 1) }.videos
                        record.steps.append("category \(category.name): \(videos.count) videos")
                    } catch { record.steps.append("category \(category.name): \(describe(error))") }
                    if !videos.isEmpty { break }
                }
            }
            if videos.isEmpty, site.searchable {
                record.stage = "search"
                videos = try await limit(60) { try await client.list(category: nil, query: "我的", page: 1) }.videos
                record.steps.append("search: \(videos.count) videos")
            }
            guard let first = videos.first else { throw Failure(message: "no videos from home, categories or search") }
            record.stage = "detail"
            let video = try await limit(60) { try await client.detail(first.id) }
            record.steps.append("detail \(video.name): \(video.episodes.count) episodes")
            guard let episode = video.episodes.first else { throw Failure(message: "detail has no episodes") }
            record.stage = "play"
            let channel = try await limit(60) { try await client.playback(episode) }
            record.steps.append("play: \(channel.url.absoluteString.prefix(160))")
            record.stage = "media"
            record.steps.append("media: " + (try await limit(30) { try await probe(channel) }))
            record.ok = true
            record.stage = "done"
        } catch { record.error = describe(error) }
        if site.runsLitePort {
            let fallbacks = await Diagnostics.shared.snapshot().entries.filter { $0.category == "lite.fallback" && $0.message.hasPrefix(site.key + " ") }
            record.steps.append(fallbacks.isEmpty ? "runtime: lite port" : "runtime: JAR fallback (\(fallbacks.last!.message))")
        }
        return record
    }

    /// Reads the first bytes of the media and names what it looks like.
    static func probe(_ channel: Channel) async throws -> String {
        var request = URLRequest(url: channel.url, timeoutInterval: 20)
        for (field, value) in channel.headers { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        var head: [UInt8] = []
        for try await byte in bytes { head.append(byte); if head.count >= 512 { break } }
        guard (200..<300).contains(status) else { throw Failure(message: "media HTTP \(status)") }
        let text = String(decoding: head, as: UTF8.self)
        let page = response.mimeType == "text/html" || ["<html", "<!doctype", "<head"].contains { text.lowercased().contains($0) }
        let kind = text.hasPrefix("#EXTM3U") ? "m3u8" : head.count > 8 && String(decoding: head[4..<8], as: UTF8.self) == "ftyp" ? "mp4"
            : head.first == 0x47 ? "mpeg-ts" : page ? "HTML page" : "unknown"
        if kind == "HTML page" { throw Failure(message: "media URL returned an HTML page") }
        return "HTTP \(status) \(response.mimeType ?? "?") \(kind)"
    }

    static func describe(_ error: Error) -> String {
        let text = error.localizedDescription
        let detail = String(describing: error)
        return (text == detail ? text : text + " | " + detail).prefix(400).description
    }

    /// A stuck plugin call cannot be cancelled, so the caller stops waiting instead.
    static func limit<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = Gate()
        return try await withCheckedThrowingContinuation { continuation in
            let work = Task {
                do { let value = try await operation(); if gate.claim() { continuation.resume(returning: value) } }
                catch { if gate.claim() { continuation.resume(throwing: error) } }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if gate.claim() { work.cancel(); continuation.resume(throwing: Timeout(seconds: seconds)) }
            }
        }
    }
    final class Gate: @unchecked Sendable {
        private let lock = NSLock(); private var claimed = false
        func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
    }
    actor Recorder {
        let file: URL
        var records: [Record]
        init(file: URL, records: [Record]) { self.file = file; self.records = records }
        func add(_ record: Record) {
            records.append(record)
            try? JSONEncoder().encode(records).write(to: file, options: .atomic)
            status("\(records.count) done, \(records.filter(\.ok).count) ok, last \(record.key)")
        }
        func status(_ text: String) {
            try? Data(text.utf8).write(to: file.deletingLastPathComponent().appending(path: "status.txt"), options: .atomic)
        }
    }
}

private extension Int { var nonZero: Int? { self == 0 ? nil : self } }

#if !os(tvOS)
/// `-qaPage danmaku-settings`: the player's Danmaku sheet over a page's player, which makes only its own views dark.
private struct QADanmakuSettings: View {
    @State private var model = CatalogDanmakuModel()
    var body: some View {
        Color.black.ignoresSafeArea()
            .sheet(isPresented: .constant(true)) {
                CatalogDanmakuSettingsView(model: model, channelName: "仙逆 · 第01集").playerSheet()
            }
            .environment(\.colorScheme, .dark)
    }
}
#endif

/// `-qaPage danmaku-list`: the player's 弹幕 tab with sample comments, to check the focused row.
private struct QADanmakuList: View {
    /// `-qaDanmakuPlayer <hls url>` gives the list a real clock (paused at 2:20) for the now-highlight and the strip.
    @State private var player: AVPlayer = {
        guard let address = UserDefaults.standard.string(forKey: "qaDanmakuPlayer"), let url = URL(string: address) else { return AVPlayer() }
        let player = AVPlayer(url: url)
        player.seek(to: CMTime(seconds: 140, preferredTimescale: 600))
        return player
    }()
    private let comments: [Danmaku] = {
        let texts = ["失恋模式", "有用的小玩意增加了", "见缝插针属于是", "我曾经有一部手机", "这个好", "直击要害", "前方高能",
                     "哈哈哈哈哈哈哈", "这一段的配乐真的绝了，建议单曲循环", "第一次看到这里的人举个手", "细节拉满", "泪目", "打卡", "这个镜头太美了"]
        let colors: [UInt32] = [0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFD700, 0xFE0302, 0x00CD00, 0x4266BE, 0xFFFFFF, 0xCC0273]
        var list: [Danmaku] = []
        for index in 0..<300 {
            // Clusters around 1:00, 2:20 and 7:30, like a real episode's busy moments.
            let centre = [60.0, 140.0, 450.0, Double(index % 600)][index % 4]
            let time = max(1, min(599, centre + Double((index * 37) % 41) - 20))
            list.append(Danmaku(time: time, position: .scroll, color: colors[index % colors.count], text: texts[(index * 5 + index / 14) % texts.count]))
        }
        return list.sorted { $0.time < $1.time }
    }()
    var body: some View {
        #if os(tvOS)
        // A cover so focus starts on the first row instead of the tab bar.
        Color.clear.fullScreenCover(isPresented: .constant(true)) { DanmakuListView(player: player, comments: comments) }
        #else
        // The list as the player shows it: a sheet over the picture.
        LinearGradient(colors: [Color(red: 0.1, green: 0.16, blue: 0.3), .black], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .sheet(isPresented: .constant(true)) { DanmakuListView(player: player, comments: comments).danmakuListPresentation() }
        #endif
    }
}
#endif
