import Foundation
import AVFoundation
import TVCore

@main struct Probe {
    /// The same file at one connection and at N: the only honest way to state what the engine buys.
    @MainActor static func benchmark(_ target: String, folder: URL, connections: Int, chunkMB: Int) async throws {
        guard let url = URL(string: target) else { return }
        // Probe once for the length, which is what an unranged download would move in one request.
        var head = URLRequest(url: url)
        head.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await URLSession.shared.data(for: head)
        let length = Int64((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range")?
            .split(separator: "/").last.flatMap { Int64($0) } ?? 0)
        print("file length=\(length) bytes")
        for tuning in [DownloadTuning(connections: 1, chunkMB: chunkMB, parallel: 1),
                       DownloadTuning(connections: connections, chunkMB: chunkMB, parallel: 1)] {
            let root = folder.appending(path: "c\(tuning.connections)")
            try? FileManager.default.removeItem(at: root)
            let library = DownloadLibrary(root: root, defaults: UserDefaults(suiteName: "probe-bench")!,
                                          settings: DownloadSettings(defaults: UserDefaults(suiteName: "probe-bench")!))
            library.settings.set(connections: tuning.connections, chunkMB: tuning.chunkMB, parallel: 1)
            library.resolver = { _ in Channel(name: "probe", url: url) }
            let episode = Episode(id: target, name: "Bench", address: target, flag: "bench")
            // A benchmark only needs a source record to hang the download on, not a real site. Built by
            // decoding because Site's initialiser is internal to TVCore.
            let site = try JSONDecoder().decode(Site.self, from: Data(#"{"key":"bench","name":"Bench","type":3,"api":"bench://local","raw":{}}"#.utf8))
            let item = library.download(DownloadSource(site: site, videoID: target, episode: episode),
                                        title: "Bench", poster: nil)
            let began = Date()
            while library.item(id: item.id)?.status != .completed, library.item(id: item.id)?.status != .failed {
                try await Task.sleep(for: .milliseconds(200))
                if Date().timeIntervalSince(began) > 300 { break }
            }
            let elapsed = Date().timeIntervalSince(began)
            let done = library.item(id: item.id)
            let bytes = done?.received ?? 0
            print(String(format: "connections=%d chunk=%dMB %.2fs %.2f MB/s peakSockets=%d status=%@",
                         tuning.connections, tuning.chunkMB, elapsed, Double(bytes) / elapsed / 1_048_576,
                         done?.connections ?? 0, done?.status.rawValue ?? "-"))
        }
    }

    @MainActor static func download(_ target: String, folder: URL, pauseAfter: Double?) async throws {
        let library = DownloadLibrary(root: folder, defaults: UserDefaults(suiteName: "probe-downloads")!)
        library.resolver = { _ in
            guard target.hasPrefix("bili:") else { return Channel(name: "probe", url: URL(string: target)!) }
            let parts = target.split(separator: ":").map(String.init)
            let client = CatalogClient(site: try await cloudSite(\.isBilibili), origin: try CloudSources.address)
            let video = try await client.detail(parts[1])
            let channel = try await client.playback(video.episodes[min(parts.count > 2 ? Int(parts[2]) ?? 0 : 0, video.episodes.count - 1)])
            print("resolved \(channel.url.absoluteString.prefix(100))")
            return channel
        }
        let episode = Episode(id: target, name: "Probe", address: target, flag: "probe")
        let item = library.download(DownloadSource(site: try await cloudSite(\.isBilibili), videoID: target, episode: episode), title: "Probe", poster: nil)
        let started = Date()
        var paused = false
        while true {
            try await Task.sleep(for: .seconds(1))
            guard let current = library.item(id: item.id) else { return }
            let rate = library.rates[item.id].map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) + "/s" } ?? "-"
            // connections= is the accelerator's own number: how many sockets carried this download.
            print("\(Int(Date().timeIntervalSince(started)))s \(current.status.rawValue) kind=\(current.kind?.rawValue ?? "-") \(current.quality ?? "") \(String(format: "%.1f%%", current.fraction * 100)) \(current.received)/\(current.expected ?? -1) parts=\(current.completedParts)/\(current.totalParts) connections=\(current.connections) \(rate) \(current.failure ?? "")")
            if let pauseAfter, !paused, Date().timeIntervalSince(started) > pauseAfter {
                paused = true
                library.pause(item.id); print("paused")
                try await Task.sleep(for: .seconds(2))
                library.resume(item.id); print("resumed")
            }
            if current.status == .failed { return }
            if current.status == .completed { break }
        }
        await library.measure()
        print("usage downloads=\(library.usage.downloads) free=\(library.usage.available ?? -1) capacity=\(library.usage.capacity ?? -1)")
        let address = try await library.playbackAddress(for: library.channel(for: library.item(id: item.id)!).url)
        print("playing \(address)")
        let player = AVPlayer(playerItem: AVPlayerItem(url: address))
        player.isMuted = true; player.play()
        for second in 1...5 {
            try await Task.sleep(for: .seconds(1))
            let current = player.currentItem!
            print("t=\(second) status=\(current.status.rawValue) time=\(String(format: "%.1f", player.currentTime().seconds)) size=\(Int(current.presentationSize.width))x\(Int(current.presentationSize.height)) tracks=\(current.tracks.count) error=\(current.error.map { "\($0)" } ?? "-")")
        }
        if let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 30 {
            await player.seek(to: CMTime(seconds: duration - 10, preferredTimescale: 600))
            try await Task.sleep(for: .seconds(2))
            print("after seek duration=\(Int(duration)) time=\(String(format: "%.1f", player.currentTime().seconds))")
        }
    }
    /// For each drive (play flag) of one video, how playback gets its bytes: straight from the CDN
    /// (CloudStreams) or through the plugin's proxy, with the address lookup time and a read speed.
    static func driveCheck(subscription: String, source: String, query: String?) async throws {
        let config = try await HTTPClient().subscription(WebAddress.resolve(subscription))
        guard let site = config.sites.first(where: { $0.key == source || $0.name.contains(source) }) else { print("no source matches \(source)"); return }
        let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL)
        print("loading \(site.name)")
        let videos = if let query { try await client.list(category: nil, query: query, page: 1).videos } else { try await client.home().videos }
        guard let first = videos.first else { print("no videos"); return }
        print("\(videos.count) videos, opening \(first.name)")
        let video = try await client.detail(first.id)
        print("\(site.name) · \(video.name) · drives: \(EpisodePlaylist(video.episodes).flags.joined(separator: ", "))")
        for flag in EpisodePlaylist(video.episodes).flags {
            guard let episode = video.episodes.first(where: { $0.flag == flag }) else { continue }
            do {
                let channel = try await client.playback(episode)
                let address = try await EmbeddedJarHost.shared.recoverProxy(channel.url)
                guard EmbeddedJarHost.isPluginProxy(address) else {
                    print("\(flag): no proxy, plays from \(address.host() ?? address.scheme ?? "-")")
                    continue
                }
                let started = Date()
                let media = await EmbeddedJarHost.shared.directMedia(address)
                let lookup = String(format: "%.1f", Date().timeIntervalSince(started))
                if let media {
                    print("\(flag): DIRECT \(media.url.host() ?? "-") \(media.length / 1_048_576) MB, lookup \(lookup)s, \(try await readSpeed(media.url, headers: media.headers, parallel: true))")
                } else {
                    print("\(flag): PROXY \(EmbeddedJarHost.proxyRoute(address)), lookup \(lookup)s, \(try await readSpeed(address, headers: [:], parallel: false))")
                }
            } catch { print("\(flag): failed \(error.localizedDescription)") }
        }
    }
    /// Reads the first 8 MB in 2 MB ranges, four at once like CloudStreams or one after another like AVPlayer on a proxy.
    static func readSpeed(_ url: URL, headers: [String: String], parallel: Bool) async throws -> String {
        let piece = 2 << 20
        @Sendable func fetch(_ index: Int) async throws -> Int {
            var request = URLRequest(url: url, timeoutInterval: 30)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            request.setValue("bytes=\(index * piece)-\((index + 1) * piece - 1)", forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 206 else { throw TVError.unsupported("HTTP \(status) for a range") }
            return data.count
        }
        let started = Date()
        var bytes = 0
        if parallel {
            bytes = try await withThrowingTaskGroup(of: Int.self) { group in
                for index in 0..<4 { group.addTask { try await fetch(index) } }
                return try await group.reduce(0, +)
            }
        } else {
            for index in 0..<4 { bytes += try await fetch(index) }
        }
        let seconds = Date().timeIntervalSince(started)
        return String(format: "%d MB in %.1fs = %.2f MB/s", bytes >> 20, seconds, Double(bytes) / seconds / 1_048_576)
    }
    /// A subscription named on the command line. A `builtin://` address answers from the app's own
    /// bundle, exactly as the app imports it, so the shipped pack can be measured without a server.
    static func cliSubscription(_ address: String) async throws -> Subscription {
        if let bundled = BundledSubscriptions.document(for: address) { return bundled }
        return try await HTTPClient().subscription(WebAddress.resolve(address))
    }
    /// One of Yingxia's own sources, from its subscription (fetched once).
    static func sourcesAddress() throws -> URL {
        guard let text = ProcessInfo.processInfo.environment["SOURCES_URL"], let url = URL(string: text) else {
            throw TVError.unsupported("Set SOURCES_URL to the subscription to test.")
        }
        return url
    }
    static func cloudSite(_ matches: @Sendable (Site) -> Bool) async throws -> Site {
        // SOURCES_URL: another copy of the recommended sources' subscription (a local Worker), never cached.
        if CloudSources.current == nil, let address = ProcessInfo.processInfo.environment["SOURCES_URL"].flatMap(URL.init(string:)) {
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData))
            CloudSources.current = try Subscription.parse(data, origin: address)
        }
        if CloudSources.current == nil { CloudSources.current = try await CloudSources.fetch(http: HTTPClient(), address: Self.sourcesAddress()) }
        guard let site = CloudSources.site(where: matches) else { throw TVError.invalidConfiguration }
        return site
    }
    static func manga(_ address: String, keyword: String?) async throws {
        let started = Date()
        func step(_ text: String) { print(String(format: "[%5.1fs] ", Date().timeIntervalSince(started)) + text) }
        let source = address.hasPrefix("http") ? try await MangaSources.shared.install(from: URL(string: address)!)
            : try await MangaSources.shared.install(code: String(contentsOfFile: address, encoding: .utf8), origin: nil)
        let runtime = MangaRuntime.shared
        let info = try await runtime.info(source.key)
        step("installed \(info.name) \(info.key) v\(info.version) explore=\(info.explore.map { "\($0.title)(\($0.type))" }) search=\(info.canSearch) category=\(info.categoryParts.map(\.name)) settings=\(info.settings.map(\.key))")
        var first: MangaComic?
        if !info.explore.isEmpty {
            do {
                let result = try await runtime.explore(source.key, page: 0, cursor: nil)
                step("explore: \(result.shelves.count) shelves \(result.shelves.map { "\($0.title):\($0.comics.count)" }) list=\(result.page.comics.count) next=\(String(describing: result.page.next))")
                first = result.shelves.first?.comics.first ?? result.page.comics.first
            } catch { step("explore FAILED: \(error.localizedDescription)") }
        }
        if let keyword, info.canSearch {
            do {
                let page = try await runtime.search(source.key, keyword: keyword, options: info.searchOptions.map { $0.defaultValue ?? $0.choices.first?.value }, cursor: nil)
                step("search \(keyword): \(page.comics.count) next=\(String(describing: page.next)) first=\(page.comics.prefix(3).map(\.title))")
                first = page.comics.first ?? first
            } catch { step("search FAILED: \(error.localizedDescription)") }
        }
        guard let comic = first else { step("no comic to open"); return }
        step("comic \(comic.title) id=\(comic.id) cover=\(comic.cover.prefix(90))")
        do {
            await MangaImages.shared.prepareCovers(source: source.key, urls: [comic.cover])
            let cover = try await MangaImages.shared.data(source: source.key, url: comic.cover, kind: .cover)
            step("cover \(cover.count) bytes")
        } catch { step("cover FAILED: \(error.localizedDescription)") }
        let details = try await runtime.details(source.key, id: comic.id)
        step("details \(details.comic.title) tags=\(details.tags.map { "\($0.name):\($0.values.prefix(3))" }) groups=\(details.groups.map { "\($0.title):\($0.chapters.count)" }) first=\(details.chapters.prefix(2).map(\.title)) last=\(details.chapters.last?.title ?? "-")")
        let chapter = details.chapters.first
        let pages = try await runtime.pages(source.key, comic: comic.id, chapter: chapter?.id)
        step("pages \(pages.count): \(pages.first?.prefix(120) ?? "")")
        for url in pages.prefix(2) {
            do {
                let data = try await MangaImages.shared.data(source: source.key, url: url, kind: .page, comic: comic.id, chapter: chapter?.id)
                let image = MangaImages.bitmap(data, width: 1200)
                step("page \(data.count) bytes \(image.map { "\($0.width)x\($0.height)" } ?? "undecodable")")
            } catch { step("page FAILED: \(error.localizedDescription)") }
        }
    }
    /// One WeBox plugin through the same calls the app makes: home, search, detail, play. The plugin is
    /// edited by its author, not by us, so this reports what it answers rather than asserting a shape.
    static func webox(_ address: String, keyword: String?) async throws {
        // The api goes through the same resolution the app uses for a subscription entry, so an
        // `assets://` plugin proves the bundled path and not just a direct URL.
        let origin = URL(string: "http://localhost/")!
        let escaped = address.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        // TVBOX_EXT carries a source's `ext` (the plugin's settings), so a plugin's non-default
        // settings — a mirror site, a cookie — are tried exactly as a subscription would supply them.
        let extra = (ProcessInfo.processInfo.environment["TVBOX_EXT"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = extra.isEmpty || extra == "{}" ? "{\"webox\":1}" : "{\"webox\":1,\"ext\":\(extra.debugDescription)}"
        let site = try JSONDecoder().decode(Site.self, from: Data(#"{"key":"webox-probe","name":"WeBox","type":3,"api":"\#(escaped)","raw":\#(settings)}"#.utf8))
        let script = try site.scriptURL(origin: origin)
        print("api: \(script.absoluteString)")
        let http = HTTPClient()
        func call(_ params: [String: String]) async -> [String: JSONValue]? {
            let began = Date()
            do {
                let json = try await ScriptRuntime.shared.request(site: site, scriptURL: script, params: params, http: http, origin: origin)
                print(String(format: "  (%.0fms, %d fields)", Date().timeIntervalSince(began) * 1000, json.count))
                return json
            } catch {
                print(String(format: "  FAILED (%.0fms): %@", Date().timeIntervalSince(began) * 1000, error.localizedDescription))
                return nil
            }
        }
        func items(_ json: [String: JSONValue]?) -> [[String: JSONValue]] {
            (json?["list"]?.array ?? []).compactMap(\.object)
        }

        print("home …")
        guard let home = await call([:]) else { return }
        let classes = (home["class"]?.array ?? []).compactMap(\.object)
        print("  classes: " + classes.compactMap { $0["type_name"]?.string }.joined(separator: " / "))
        let homeItems = items(home)
        print("  home: \(homeItems.count) items; first: \(homeItems.first?["vod_name"]?.string ?? "-")")

        var chosen: String? = homeItems.first?["vod_id"]?.string
        if let keyword, !keyword.isEmpty {
            print("search “\(keyword)” …")
            if let result = await call(["wd": keyword, "pg": "1"]) {
                let found = items(result)
                print("  \(found.count) results; first: \(found.first?["vod_name"]?.string ?? "-")")
                if let id = found.first?["vod_id"]?.string { chosen = id }
            }
        }
        if let category = classes.dropFirst().first?["type_id"]?.string {
            print("category \(category) …")
            if let result = await call(["t": category, "pg": "1"]) {
                let listed = items(result)
                print("  \(listed.count) items; first: \(listed.first?["vod_name"]?.string ?? "-")")
                // A probe of many candidates at once returns one item per candidate: show them all.
                if listed.count > 1, listed.count <= 12 { for item in listed.dropFirst() { print("    · \(item["vod_name"]?.string ?? "-")") } }
                chosen = chosen ?? listed.first?["vod_id"]?.string
            }
        }
        guard let id = chosen else { print("nothing to open"); return }
        print("detail \(id) …")
        guard let detail = await call(["ids": id]), let vod = items(detail).first else { return }
        print("  title: \(vod["vod_name"]?.string ?? "-")")
        print("  poster: \(vod["vod_pic"]?.string ?? "-")")
        let flags = (vod["vod_play_from"]?.string ?? "").components(separatedBy: "$$$")
        let groups = (vod["vod_play_url"]?.string ?? "").components(separatedBy: "$$$")
        print("  lines: \(flags.joined(separator: " / "))")
        guard let first = groups.first, !first.isEmpty else { print("  no episodes"); return }
        let episodes = first.components(separatedBy: "#").filter { !$0.isEmpty }
        print("  episodes: \(episodes.count); first: \(episodes.first ?? "-")")
        let parts = (episodes.first ?? "").split(separator: "$", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { print("  episode has no address"); return }
        print("play …")
        let played = await call(["play": parts[1], "flag": flags.first ?? ""])
        print("  url: \(played?["url"]?.string ?? "-")")
        // A media proxy lives in this process, so a check of the address it answered needs the process alive.
        if let hold = ProcessInfo.processInfo.environment["TVBOX_HOLD"], let seconds = Double(hold) {
            print("holding \(Int(seconds))s …")
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    // MARK: - 播放探测（配置包版）

    /// 一条源的探测结果。`media` 是**字节级**结论，不是「接口应答了」：
    /// `ok` 拉到媒体字节且够快，`fail` 拿不到，`web` 播放地址是网页需要嗅探，
    /// `none` 是插件代理/磁力等没有 HTTP 地址，`timeout` 整个源超时。
    struct ProbeRow: Encodable, Sendable {
        let sub: String
        let key: String
        let name: String
        let type: Int
        let api: String
        var stage: String = "home"
        var play: String? = nil
        var media: String = "none"
        var kbps: Int? = nil
        var peers: Int? = nil
        var height: Int? = nil
        var ms: Int? = nil
        var error: String? = nil
        /// 真的出字节的那一条（片名 · 集名），证明结论不是只看海报得出的。
        var title: String? = nil
        /// 试了几个「视频 × 线路」组合。
        var attempts: Int = 0
    }

    /// 只解探测需要的字段：`yingxia-config` / `mi3s-config` 两种格式名都带 `subscriptions`。
    struct ConfigBundle: Decodable {
        struct Item: Decodable {
            let entry: SubscriptionEntry
            let document: Subscription?
        }
        let subscriptions: [Item]
    }

    /// 到一个截止时间就放弃，把这个源判成 timeout 而不是让它拖住整轮。
    static func withDeadline<T: Sendable>(_ seconds: Double,
                                          _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(seconds, 1) * 1_000_000_000))
                throw TVError.unsupported("timed out after \(Int(seconds))s")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TVError.unsupported("no answer") }
            return first
        }
    }

    /// 拉一小段字节，确认这条地址真的出流。HLS 会再往里走一层：主清单 → 变体 → 分片，
    /// 只有分片拿得到字节才算可播 —— 清单能拉、分片全 404 的源很常见。
    static func fetchHead(_ url: URL, headers: [String: String], bytes: Int) async -> (status: Int, data: Data)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("bytes=0-\(bytes - 1)", forHTTPHeaderField: "Range")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }

    /// `ok` / `fail`，以及真正取到字节的那条地址（分片）。
    static func verify(_ address: String, headers: [String: String], depth: Int = 0) async -> (media: String, leaf: URL?) {
        guard let url = URL(string: address) else { return ("fail", nil) }
        guard let head = await fetchHead(url, headers: headers, bytes: 65_536) else { return ("fail", nil) }
        guard (200..<400).contains(head.status), !head.data.isEmpty else { return ("fail", nil) }
        let text = String(decoding: head.data.prefix(16_384), as: UTF8.self)
        guard text.contains("#EXTM3U") else { return ("ok", url) }
        guard depth < 2 else { return ("fail", nil) }
        // 第一条不是注释的行就是下一层：主清单里是变体清单，媒体清单里是分片。
        let next = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
        guard let next, let resolved = URL(string: next, relativeTo: url)?.absoluteURL else { return ("fail", nil) }
        return await verify(resolved.absoluteString, headers: headers, depth: depth + 1)
    }

    /// 一条播放地址到底能不能出字节。
    ///
    /// 磁力真的加入种子网络读一片；网页地址（`requiresWebDetection`）记为需要嗅探；HTTP 地址按 Range
    /// 拉 64 KB，HLS 一路下钻到分片——只看清单回 200 是不够的，海报点进去放不出来正是差在这一步。
    static func examine(_ choice: PlaybackChoice, plan: PlaybackPlan) async
        -> (ok: Bool, media: String, error: String?, kbps: Int?, height: Int?, ms: Int?, peers: Int?) {
        let address = choice.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return (false, "none", "empty address", nil, nil, nil, nil) }
        if address.lowercased().hasPrefix("magnet:") {
            do {
                let torrent = try await TorrentBridge.shared.open(address, wait: 60)
                let data = try await TorrentBridge.shared.read(torrent, at: 0, count: 262_144)
                return (data.count > 512, data.count > 512 ? "ok" : "fail",
                        data.count > 512 ? nil : "torrent gave no bytes", data.count, nil, nil, torrent.peers)
            } catch {
                return (false, "fail", error.localizedDescription, nil, nil, nil, nil)
            }
        }
        if plan.requiresWebDetection { return (false, "web", "needs in-app web detection", nil, nil, nil, nil) }
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return (false, "none", "not an http address: \(address.prefix(40))", nil, nil, nil, nil)
        }
        let checked = await verify(address, headers: plan.headers)
        guard checked.media == "ok", let leaf = checked.leaf else {
            return (false, checked.media, "no bytes from \(url.host() ?? address)", nil, nil, nil, nil)
        }
        let reading = await SourceProbeRunner.probe(url: leaf, headers: plan.headers)
        return (reading.isUsable, reading.isUsable ? "ok" : "fail",
                reading.isUsable ? nil : "probe could not read", reading.kilobytesPerSecond,
                reading.resolutionHeight, reading.latencyMilliseconds, nil)
    }

    /// 走 App 真实的目录链路：首页 →（无片时）分类 → 详情 → 播放地址，再拉一段字节。
    ///
    /// 只试第一个视频不够：首页挂着海报、点进去那条线路已经死掉的源很常见。所以轮一遍
    /// 「多个视频 × 每集的前几条线路」，任何一个组合真的出字节就算可播；全都拉不到才判 `fail`，
    /// 并把最后一次的原因写进 `error`，免得把「海报能点」当成「能播」。
    static func runProbe(site: Site, sub: String, origin: URL, jar: URL?,
                         videos maxVideos: Int = 4, episodes maxEpisodes: Int = 1,
                         choices maxChoices: Int = 2) async throws -> ProbeRow {
        var row = ProbeRow(sub: sub, key: site.key, name: site.name, type: site.type, api: site.api)
        let client = CatalogClient(site: site, origin: origin, jarURL: jar)
        var pool: [Video] = []
        do {
            let home = try await client.home()
            pool = home.videos
            if pool.isEmpty, let category = home.categories.first {
                row.stage = "category"
                pool = try await client.list(category: category.id, query: "", page: 1).videos
            }
        } catch {
            row.error = error.localizedDescription
            return row
        }
        guard !pool.isEmpty else {
            row.error = "no videos on the home page"
            return row
        }

        var attempts = 0
        var lastError: String?
        var sawWeb = false
        for video in pool.prefix(maxVideos) {
            row.stage = "detail"
            guard let full = try? await client.detail(video.id), !full.episodes.isEmpty else {
                lastError = "no episodes for \(video.name)"
                continue
            }
            for episode in full.episodes.prefix(maxEpisodes) {
                row.stage = "play"
                guard let plan = try? await client.preparePlayback(episode), !plan.choices.isEmpty else {
                    lastError = "no playback address for \(video.name)"
                    continue
                }
                for choice in plan.choices.prefix(maxChoices) {
                    attempts += 1
                    let outcome = await examine(choice, plan: plan)
                    if outcome.media == "web" { sawWeb = true }
                    if outcome.ok {
                        row.media = "ok"
                        row.play = choice.address
                        row.title = "\(video.name) · \(episode.name) · \(choice.name)"
                        row.kbps = outcome.kbps
                        row.height = outcome.height
                        row.ms = outcome.ms
                        row.peers = outcome.peers
                        row.attempts = attempts
                        return row
                    }
                    lastError = outcome.error ?? lastError
                }
            }
        }
        row.attempts = attempts
        if attempts == 0 {
            row.media = "none"
            row.error = lastError ?? "no episodes"
        } else if sawWeb {
            // 每条线路都是网页地址：接口没坏，字节要 App 的 WebView 才出得来。
            row.media = "web"
            row.error = lastError
        } else {
            row.media = "fail"
            row.error = "posters but nothing plays (\(attempts) tries): " + (lastError ?? "unknown")
        }
        return row
    }

    static func playProbe(_ args: [String]) async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        var address = ""
        var jobs = 6
        var deadline = 45.0
        var maxVideos = 4
        var maxEpisodes = 1
        var maxChoices = 2
        var filters: [String] = []
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--jobs": index += 1; jobs = max(1, Int(args[index]) ?? jobs)
            case "--deadline": index += 1; deadline = Double(args[index]) ?? deadline
            case "--videos": index += 1; maxVideos = max(1, Int(args[index]) ?? maxVideos)
            case "--episodes": index += 1; maxEpisodes = max(1, Int(args[index]) ?? maxEpisodes)
            case "--choices": index += 1; maxChoices = max(1, Int(args[index]) ?? maxChoices)
            default:
                if address.isEmpty { address = args[index] } else { filters.append(args[index]) }
            }
            index += 1
        }
        let (data, _) = try await HTTPClient().get(try WebAddress.resolve(address))
        let bundle = try JSONDecoder().decode(ConfigBundle.self, from: data)
        var work: [(String, Subscription, Site)] = []
        for item in bundle.subscriptions {
            guard let document = item.document, item.entry.enabled else { continue }
            for site in document.sites
            where filters.isEmpty || filters.contains(where: { site.name.contains($0) || site.key.contains($0) }) {
                work.append((item.entry.name, document, site))
            }
        }
        FileHandle.standardError.write(Data("probing \(work.count) sources, \(jobs) at a time\n".utf8))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let limit = deadline
        // 闭包要并发执行，参数先落成常量，免得 Swift 6 报「引用可变的捕获变量」。
        let videoBudget = maxVideos, episodeBudget = maxEpisodes, choiceBudget = maxChoices
        var counts: [String: Int] = [:]
        for start in stride(from: 0, to: work.count, by: jobs) {
            let slice = work[start..<min(start + jobs, work.count)]
            await withTaskGroup(of: ProbeRow.self) { group in
                for (sub, document, site) in slice {
                    group.addTask {
                        do {
                            return try await withDeadline(limit) {
                                try await runProbe(site: site, sub: sub, origin: document.origin, jar: document.spiderURL,
                                                   videos: videoBudget, episodes: episodeBudget, choices: choiceBudget)
                            }
                        } catch {
                            var row = ProbeRow(sub: sub, key: site.key, name: site.name, type: site.type, api: site.api)
                            row.stage = "timeout"; row.error = error.localizedDescription
                            return row
                        }
                    }
                }
                for await row in group {
                    counts[row.media, default: 0] += 1
                    print(String(decoding: try! encoder.encode(row), as: UTF8.self))
                }
            }
        }
        let summary = counts.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        FileHandle.standardError.write(Data("SUMMARY total=\(work.count) \(summary)\n".utf8))
    }

    // MARK: - 线路级审计

    /// 一条线路的读数。
    ///
    /// 与 `probeTick` 里那份「源级」读数的区别：这里一条线一行，**不给整个源一个笼统结论**。
    /// 用户报的「4K 源出来的不是 4K」「要切到第二集再切回来」都发生在**线**上，
    /// 源级一行只会把它们平均掉。
    struct LineReading: Encodable {
        var flag: String
        var episodes: Int
        /// 线路名自己声明的画质（4K / 1080 / 720 …），没写就是 nil。
        var claim: String?
        var claimHeight: Int?
        /// 解析出来是网页地址，要靠 App 的 WebView 嗅探；命令行测不了，单列一档，不算死。
        var needsWeb = false
        var ok = false
        /// 一共试了几次「取地址 → 解析」（1 = 一次就成）。
        var tries = 0
        /// 第一次是否成功。
        var firstOk = false
        /// 第一次失败、第二次成功 —— 正是「切到第二集再切回来就好了」的那一类。
        var retryHelped = false
        /// 解析出来的地址到底是不是媒体：`hls` / `mp4` / `ts` / `html` / `json` / `other`。
        ///
        /// 必须有这一项。`SourceProbeRunner` 只判「有没有字节回来」，
        /// 而**一个 HTML 网页也回 200 和几百 KB** —— 采集站把整套网页地址当播放地址返回
        /// 是常态（`xlyun` 这类「云播」线就是），只看 reachable 会把它们当成能播。
        var kind: String?
        var width: Int?
        var height: Int?
        var kbps: Int?
        var latency: Int?
        var elapsedMs: Int?
        var error: String?
        var address: String?
    }

    /// 一个源里挑一部「线路最多」的剧做的全线路读数。
    struct SourceReading: Encodable {
        var sub: String
        var key: String
        var name: String
        var type: Int
        var title: String?
        var flagCount = 0
        var elapsedMs: Int?
        var error: String?
        var lines: [LineReading] = []
    }

    /// 线路名里写的画质。只认**强声明**：`4K`/`2160`、`1080`/`蓝光`/`超清`、`720`、`480`。
    ///
    /// 不把「高清」「HD」「原画」算进来：这几个词在采集站里几乎等于「随便」，当不了证据。
    static func claimedQuality(_ flag: String) -> (label: String?, height: Int?) {
        let text = flag.lowercased()
        if text.contains("4k") || text.contains("2160") { return ("4K", 2160) }
        if text.contains("1080") || text.contains("蓝光") || text.contains("超清") { return ("1080", 1080) }
        if text.contains("720") { return ("720", 720) }
        if text.contains("480") { return ("480", 480) }
        return (nil, nil)
    }

    /// 这段字节是什么。
    ///
    /// 只看魔数与前缀，不做解码：判断「播放器能不能开」不需要知道编码，
    /// 需要的是分清**媒体**与**网页**。分不清就会出现「测出来 reachable、点开转圈」。
    /// 主清单里声明的画面尺寸。
    ///
    /// 只记高度会判错竖屏片：一条 720×1280 的竖屏短剧高度是 1280，
    /// 一条 1920×818 的电影高度只有 818 —— 按高度比较会把竖屏 720p 当成「比电影 1080p 更好」。
    /// 判画质必须拿**长边**，所以宽和高都得留。
    static func declaredSize(in text: String) -> (width: Int, height: Int)? {
        guard let range = text.range(of: "RESOLUTION=") else { return nil }
        let tail = text[range.upperBound...].prefix(20)
        let numbers = tail.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 2 else { return nil }
        return (numbers[0], numbers[1])
    }

    static func mediaKind(_ data: Data) -> String {
        let head = data.prefix(2_048)
        let text = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#EXTM3U") { return "hls" }
        if text.hasPrefix("<") { return "html" }
        if text.hasPrefix("{") || text.hasPrefix("[") { return "json" }
        if data.count >= 8, data[4..<8] == Data("ftyp".utf8) { return "mp4" }
        if data.count >= 376, data[0] == 0x47, data[188] == 0x47 { return "ts" }
        if head.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return "mkv" }
        return "other"
    }

    /// 一个源：首页 → 挑线路最多的那部 → 每条线各取第一集 → 解析 → 真读一段字节。
    ///
    /// 为什么挑「线路最多」而不是第一条：第一条常常是单线的短剧或预告，
    /// 拿它测出来的「这个源只有一条线」是选样造成的，不是源造成的。
    static func auditLines(site: Site, sub: String, origin: URL, jar: URL?, maxVideos: Int = 3) async -> SourceReading {
        let started = Date()
        var record = SourceReading(sub: sub, key: site.key, name: site.name, type: site.type)
        let client = CatalogClient(site: site, origin: origin, jarURL: jar)
        var pool: [Video] = []
        do {
            let home = try await client.home()
            pool = home.videos
            if pool.isEmpty, let category = home.categories.first {
                pool = try await client.list(category: category.id, query: "", page: 1).videos
            }
        } catch {
            record.error = error.localizedDescription
            record.elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            return record
        }
        guard !pool.isEmpty else {
            record.error = "no videos on the home page"
            record.elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            return record
        }
        var best: Video?
        var bestFlags: [String] = []
        for video in pool.prefix(maxVideos) {
            guard let full = try? await client.detail(video.id) else { continue }
            var seen = Set<String>()
            let flags = full.episodes.compactMap { seen.insert($0.flag).inserted ? $0.flag : nil }
            if flags.count > bestFlags.count { best = full; bestFlags = flags }
            // 已经三条线以上就不必再换样本了，够回答「哪条线是真 4K」。
            if bestFlags.count >= 3 { break }
        }
        guard let full = best, !bestFlags.isEmpty else {
            record.error = "no episodes in the first \(maxVideos) videos"
            record.elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            return record
        }
        record.title = full.name
        record.flagCount = bestFlags.count
        for flag in bestFlags {
            var line = LineReading(flag: flag, episodes: full.episodes.filter { $0.flag == flag }.count)
            let claim = claimedQuality(flag)
            line.claim = claim.label
            line.claimHeight = claim.height
            guard let episode = full.episodes.first(where: { $0.flag == flag }) else { continue }
            let lineStart = Date()
            var channel: Channel?
            var plan: PlaybackPlan?
            for attempt in 1...2 {
                line.tries = attempt
                do {
                    // 每次重试都重新取一次地址：签名地址可能带时间戳，复用旧地址测不出「重试为什么能好」。
                    let next = try await client.preparePlayback(episode)
                    plan = next
                    guard let choice = next.choices.first else { throw TVError.unsupported("no playback choice") }
                    channel = try await client.resolvePlayback(next, choice: choice)
                    if attempt == 1 { line.firstOk = true } else { line.retryHelped = true }
                    break
                } catch {
                    line.error = error.localizedDescription
                    if attempt == 1 { try? await Task.sleep(for: .milliseconds(300)) }
                }
            }
            if let channel {
                line.ok = true
                line.error = nil
                line.address = channel.url.absoluteString
                if plan?.requiresWebDetection == true { line.needsWeb = true }
                let scheme = channel.url.scheme?.lowercased() ?? ""
                if scheme == "http" || scheme == "https" {
                    let reading = await SourceProbeRunner.probe(url: channel.url, headers: channel.headers)
                    line.height = reading.resolutionHeight
                    line.kbps = reading.kilobytesPerSecond
                    line.latency = reading.latencyMilliseconds
                    // 解析成功但一个字节都读不到：这是「能出地址、播不出来」，仍算失败。
                    if !reading.isUsable {
                        line.ok = false
                        line.error = "resolved but no media bytes"
                    } else if let head = await fetchHead(channel.url, headers: channel.headers, bytes: 16_384) {
                        // 回字节 ≠ 是媒体。判一次真实内容类型，HTML 单列一档 —— 它在这条链路上
                        // 就是「播放器拿不到流、转圈到超时」的那个根因。
                        let kind = mediaKind(head.data)
                        line.kind = kind
                        if kind == "html" || kind == "json" {
                            line.ok = false
                            line.error = "address is a \(kind) page, not media — the player has nothing to open"
                        } else if let size = declaredSize(in: String(decoding: head.data.prefix(8_192), as: UTF8.self)) {
                            line.width = size.width
                            line.height = size.height
                        }
                    }
                } else {
                    // tvbox-cloud / tvbox-hongguo / tvbox-dash 由 App 内的加载器回答，命令行测不了。
                    line.needsWeb = true
                }
            }
            line.elapsedMs = Int(Date().timeIntervalSince(lineStart) * 1000)
            record.lines.append(line)
        }
        record.elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        return record
    }

    static func lineAudit(_ args: [String]) async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        var address = ""
        var jobs = 6
        var deadline = 150.0
        var maxVideos = 3
        var filters: [String] = []
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--jobs": index += 1; jobs = max(1, Int(args[index]) ?? jobs)
            case "--deadline": index += 1; deadline = Double(args[index]) ?? deadline
            case "--videos": index += 1; maxVideos = max(1, Int(args[index]) ?? maxVideos)
            default:
                if address.isEmpty { address = args[index] } else { filters.append(args[index]) }
            }
            index += 1
        }
        let data: Data
        if address.hasPrefix("http://") || address.hasPrefix("https://") {
            data = try await HTTPClient().get(try WebAddress.resolve(address)).0
        } else {
            data = try Data(contentsOf: URL(fileURLWithPath: address))
        }
        let bundle = try JSONDecoder().decode(ConfigBundle.self, from: data)
        var work: [(String, Subscription, Site)] = []
        for item in bundle.subscriptions {
            guard let document = item.document, item.entry.enabled else { continue }
            for site in document.sites
            where filters.isEmpty || filters.contains(where: { site.name.contains($0) || site.key.contains($0) || item.entry.name.contains($0) }) {
                work.append((item.entry.name, document, site))
            }
        }
        FileHandle.standardError.write(Data("auditing \(work.count) sources, \(jobs) at a time\n".utf8))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let limit = deadline, videos = maxVideos
        for start in stride(from: 0, to: work.count, by: jobs) {
            let slice = work[start..<min(start + jobs, work.count)]
            await withTaskGroup(of: SourceReading.self) { group in
                for (sub, document, site) in slice {
                    group.addTask {
                        do {
                            return try await withDeadline(limit) {
                                await auditLines(site: site, sub: sub, origin: document.origin,
                                                 jar: document.spiderURL, maxVideos: videos)
                            }
                        } catch {
                            var record = SourceReading(sub: sub, key: site.key, name: site.name, type: site.type)
                            record.error = "timeout: \(error.localizedDescription)"
                            return record
                        }
                    }
                }
                for await record in group {
                    print(String(decoding: (try? encoder.encode(record)) ?? Data(), as: UTF8.self))
                }
            }
        }
        FileHandle.standardError.write(Data("DONE\n".utf8))
    }

    static func main() async throws {
        let args = CommandLine.arguments
        // Yingxia's own sources and live platforms come from its subscription.
        // [mi3s] 二开：我方多一个 `--bench-download` 探针子命令。
        if args.count >= 2, args[1] == "--live" || args[1] == "--cloud-site" || args[1].hasPrefix("--bili") || args[1] == "--download" || args[1] == "--bench-download" {
            CloudSources.current = try await CloudSources.fetch(http: HTTPClient(), address: Self.sourcesAddress())
        }
        guard args.count >= 2 else {
            print("Usage: TVBoxProbe <jar path> [class descriptor] [static int method]")
            print("       TVBoxProbe --subscription-check <URL> [...]")
            return
        }
        if args[1] == "--webox", args.count >= 3 {
            // --webox <plugin .webox.js file or URL> [keyword]: the four calls the app makes on one plugin.
            setvbuf(stdout, nil, _IONBF, 0)
            try await webox(args[2], keyword: args.count > 3 ? args[3] : nil)
            return
        }
        if args[1] == "--torrent", args.count >= 3 {
            // --torrent <magnet>: join the swarm, then read a slice of the file it holds.
            setvbuf(stdout, nil, _IONBF, 0)
            let magnet = args[2]
            let seconds = args.count > 3 ? (Double(args[3]) ?? 60) : 60
            // 第四个参数写 remux：强制走重封装（用 MP4 验 MKV 那条链路）。
            let forceRemux = args.count > 4 && args[4] == "remux"
            do {
                let started = Date()
                let torrent = try await TorrentBridge.shared.open(magnet, wait: seconds)
                print("joined  \(torrent.name)  peers=\(torrent.peers)  file=\(torrent.fileName)  \(torrent.length) bytes  direct=\(torrent.direct)")
                if torrent.direct, !forceRemux {
                    let url = try await TorrentBridge.shared.streamURL(torrent)
                    print("stream  \(url.absoluteString)")
                    let reading = await SourceProbeRunner.probe(url: url)
                    print("probe   \(reading.reachability.rawValue)  \(reading.kilobytesPerSecond ?? -1) KB/s  \(reading.latencyMilliseconds ?? -1) ms")
                } else {
                    print("remux   (MKV/AVI, opening the repackager)")
                    let url = try await TorrentBridge.shared.remuxURL(torrent)
                    print("hls     \(url.absoluteString)")
                }
                let data = try await TorrentBridge.shared.read(torrent, at: 0, count: 262_144)
                print("read    \(data.count) bytes in \(String(format: "%.2f", Date().timeIntervalSince(started)))s  first4=\(data.prefix(4).map { String(format: "%02x", $0) }.joined())")
                // 和 --webox 一样：媒体口在本进程里，验地址要进程活着。
                if let hold = ProcessInfo.processInfo.environment["TVBOX_HOLD"], let seconds = Double(hold) {
                    print("holding \(Int(seconds))s …")
                    try? await Task.sleep(for: .seconds(seconds))
                }
            } catch {
                print("FAILED \(error.localizedDescription)")
            }
            return
        }
        if args[1] == "--play-probe", args.count >= 3 {
            // --play-probe <config package> [--jobs N] [--deadline S] [source filters]: every source's
            // home → detail → play, then a byte-level reading of the address it handed back.
            try await playProbe(Array(args.dropFirst(2)))
            return
        }
        if args[1] == "--line-audit", args.count >= 3 {
            // --line-audit <config package | 本地 json> [--jobs N] [--deadline S] [filters]:
            // 每个源挑线路最多的一部，逐条线取第一集、解析、真读一段字节。
            try await lineAudit(Array(args.dropFirst(2)))
            return
        }
        if args[1] == "--manga", args.count >= 3 {
            // --manga <source .js URL or file> [keyword]: a Venera comic source end to end.
            setvbuf(stdout, nil, _IONBF, 0)
            try await manga(args[2], keyword: args.count > 3 ? args[3] : nil)
            return
        }
        if args[1] == "--novel-check", args.count >= 3 {
            // --novel-check <Legado list URL or file> [keyword] [--limit N] [--offset N] [--jobs N]: every source searched,
            // and the keyword's book read through to its first chapter.
            setvbuf(stdout, nil, _IONBF, 0)
            try await novelCheck(Array(args[2...]))
            return
        }
        if args[1] == "--novel-bench", args.count >= 3 {
            // --novel-bench <list> [sessions]: runtime boot time, memory, and load() time over the list.
            setvbuf(stdout, nil, _IONBF, 0)
            novelProfiles()
            let sources = try await novelList(args[2])
            for line in try await NovelRuntime.benchmark(sources, sessions: args.count > 3 ? Int(args[3]) ?? 16 : 16) { print(line) }
            return
        }
        if args[1] == "--novel-read", args.count >= 5 {
            // --novel-read <list> <source key or name> <keyword>: one Legado source, verbosely.
            setvbuf(stdout, nil, _IONBF, 0)
            try await novelRead(args[2], args[3], keyword: args[4])
            return
        }
        if args[1] == "--download", args.count >= 4 {
            // --download <media URL | bili:<BV>[:part]> <folder> [pause after seconds]: the download queue end to end,
            // optionally paused and resumed partway, then the result played through AVPlayer.
            setvbuf(stdout, nil, _IONBF, 0)
            try await download(args[2], folder: URL(filePath: args[3]), pauseAfter: args.count > 4 ? Double(args[4]) : nil)
            return
        }
        if args[1] == "--bench-download", args.count >= 4 {
            // --bench-download <media URL> <folder> [connections] [chunkMB] [parallel]: the same file at
            // several connection counts, to show what the accelerator is worth on this link.
            setvbuf(stdout, nil, _IONBF, 0)
            try await benchmark(args[2], folder: URL(filePath: args[3]),
                                connections: args.count > 4 ? Int(args[4]) ?? 8 : 8,
                                chunkMB: args.count > 5 ? Int(args[5]) ?? 4 : 4)
            return
        }
        if args[1] == "--rewrap", args.count >= 4 {
            // --rewrap <mkv> <mp4>: what a finished download of that file would be saved as.
            setvbuf(stdout, nil, _IONBF, 0)
            let began = Date()
            let result = try await Rewrap.probe(URL(filePath: args[2]), to: URL(filePath: args[3])) { print(String(format: "%.0f%%", $0 * 100)) }
            print(result ?? "not rewrapped: plays as it is", String(format: "%.1fs", Date().timeIntervalSince(began)))
            return
        }
        if args[1] == "--cast-upgrade", args.count >= 4, let cid = Int(args[2]) {
            // --cast-upgrade <cid> <title>: finds the video a DLNA cast belongs to.
            print("aid", await Bilibili.castVideo(cid: cid, title: args[3]).map(String.init) ?? "not found")
            return
        }
        if args[1] == "--bili-chat", args.count >= 3, let room = Int(args[2]) {
            // --bili-chat <room> [seconds]: prints a live room's comments as they arrive.
            setvbuf(stdout, nil, _IONBF, 0)
            let chat = BilibiliLiveChat(room: room)
            chat.start { text, color, position in print("danmaku \(String(format: "%06x", color)) \(position) \(text)") }
            try await Task.sleep(for: .seconds(args.count > 3 ? Double(args[3]) ?? 20 : 20))
            chat.stop()
            return
        }
        if args[1] == "--live-chat", args.count >= 4, let chat = LiveChats.make(args[2], room: args[3]) {
            // --live-chat <bilibili|douyu|huya> <room> [seconds]: prints a live room's comments as they arrive.
            setvbuf(stdout, nil, _IONBF, 0)
            chat.start { text, color, position in print("danmaku \(String(format: "%06x", color)) \(position) \(text)") }
            try await Task.sleep(for: .seconds(args.count > 4 ? Double(args[4]) ?? 20 : 20))
            chat.stop()
            return
        }
        if args[1] == "--douyin-handoff" {
            // --douyin-handoff: a TV-side receiver and an iPhone-side send over the LAN address, plus a
            // forged send (wrong key) that must be refused.
            let receiver = DouyinHandoff.Receiver()
            let got = AsyncStream<DouyinAccount> { continuation in
                _ = Task { let link = try await receiver.start { continuation.yield($0); continuation.finish() }
                    print("link", link.url.absoluteString.replacingOccurrences(of: #"key=[^&]+"#, with: "key=…", options: .regularExpression))
                    var forged = URLComponents(url: link.url, resolvingAgainstBaseURL: false)!
                    forged.queryItems = forged.queryItems!.map { $0.name == "key" ? URLQueryItem(name: "key", value: String(repeating: "A", count: 43)) : $0 }
                    do { try await DouyinHandoff.send(DouyinAccount(cookie: "sessionid=forged"), to: DouyinHandoff.Link(forged.url!)!); print("forged send ACCEPTED (bad)") }
                    catch { print("forged send refused:", error.localizedDescription) }
                    try await DouyinHandoff.send(DouyinAccount(cookie: "sessionid=test; ttwid=x", name: "probe"), to: DouyinHandoff.Link(link.url)!)
                    print("sent")
                }
            }
            for await account in got { print("received", account.name, account.cookie) }
            receiver.stop()
            return
        }
        if args[1] == "--live", args.count >= 3, let platform = LivePlatform(rawValue: args[2]) {
            // --live <bilibili|douyu|huya|douyin> [keyword|room:<id>]: areas, the first area's rooms (or the
            // search results), then the first room's stream through AVPlayer for a few seconds.
            setvbuf(stdout, nil, _IONBF, 0)
            var rooms: [LiveRoom] = []
            if args.count > 3, args[3].hasPrefix("room:") {
                rooms = [] // played directly below
            } else if args.count > 3 {
                rooms = try await LiveCatalog.search(platform, keyword: args[3])
                print("search \(args[3]): \(rooms.count) rooms")
            } else {
                let areas = try await LiveCatalog.areas(platform)
                print("areas \(areas.map(\.name).joined(separator: " "))")
                let first = try await LiveCatalog.rooms(platform, area: areas[0], page: 1)
                let second = try await LiveCatalog.rooms(platform, area: areas[0], page: 2)
                print("\(areas[0].name): page 1 \(first.count) rooms, page 2 \(second.count)")
                if areas.count > 1 { print("\(areas[1].name): \(try await LiveCatalog.rooms(platform, area: areas[1], page: 1).count) rooms") }
                rooms = first
            }
            for room in rooms.prefix(4) { print("  \(room.roomID) | \(room.host) | \(room.title) | \(room.online) | \(room.area) | \(room.cover?.absoluteString.prefix(50) ?? "-")") }
            let address = args.count > 3 && args[3].hasPrefix("room:") ? URL(string: "\(platform.scheme)://room/\(args[3].dropFirst(5))")! : rooms.first?.url
            guard let address else { return }
            let live = try await LiveCatalog.resolve(Channel(name: "", url: address))
            print("resolved \(live.channel.name) \(live.channel.url.absoluteString.prefix(110))")
            print("qualities \(live.qualities.map { "\($0.id) \($0.label)" }) current \(live.current ?? -1)")
            if let folder = ProcessInfo.processInfo.environment["LIVE_DUMP"], live.channel.url.lastPathComponent == "master.m3u8" {
                // The local HLS files as the player gets them.
                let base = live.channel.url.deletingLastPathComponent()
                for name in ["master.m3u8", "0.m3u8", "0-0.mp4", "0-0.m4s", "0-1.m4s"] {
                    let (data, _) = try await URLSession.shared.data(from: base.appending(path: name))
                    try data.write(to: URL(fileURLWithPath: folder).appending(path: name))
                    print("dumped \(name) \(data.count)")
                }
            }
            let item = AVPlayerItem(asset: CENCStreams.asset(for: live.channel.url) ?? LiveRepair.asset(for: live.channel.url)
                ?? AVURLAsset(url: live.channel.url, options: ["AVURLAssetHTTPHeaderFieldsKey": live.channel.headers]))
            // As a player layer would: a video-only HLS item without any video output never starts.
            item.add(AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]))
            let player = AVPlayer(playerItem: item); player.isMuted = true; player.play()
            for second in 1...(Int(ProcessInfo.processInfo.environment["LIVE_SECONDS"] ?? "") ?? 10) {
                try await Task.sleep(for: .seconds(1))
                CENCStreams.updatePosition(for: live.channel.url, seconds: player.currentTime().seconds)
                if ProcessInfo.processInfo.environment["LIVE_DUMP"] != nil {
                    let buffered = item.loadedTimeRanges.map { String(format: "%.1f+%.1f", $0.timeRangeValue.start.seconds, $0.timeRangeValue.duration.seconds) }
                    print("  rate=\(player.rate) waiting=\(player.reasonForWaitingToPlay?.rawValue ?? "-") buffered=\(buffered) errors=\(item.errorLog()?.events.map { "\($0.errorStatusCode) \($0.errorComment ?? "")" } ?? [])")
                }
                print("t=\(second) status=\(item.status.rawValue) time=\(String(format: "%.1f", player.currentTime().seconds)) size=\(Int(item.presentationSize.width))x\(Int(item.presentationSize.height)) error=\(item.error.map { "\($0)" } ?? "-")")
            }
            // Recoverable problems too, such as a playlist contradicting an earlier reload (-12312).
            for event in item.errorLog()?.events ?? [] { print("errorlog \(event.errorStatusCode) \(event.errorComment ?? "-")") }
            // As the player does before it opens the room again: the next run reads this server through the loader.
            if (item.error as NSError?)?.code == -12312 { LiveRepair.noteContradiction(live.channel.url); print("noted contradiction") }
            return
        }
        if args[1] == "--plugin-call", args.count > 3 {
            // --plugin-call <pluginId> <method> [JSON payload]: one call into an installed live plugin, its reply as JSON.
            setvbuf(stdout, nil, _IONBF, 0)
            let payload = args.count > 4 ? try JSONDecoder().decode([String: JSONValue].self, from: Data(args[4].utf8)) : [:]
            do {
                let reply = try await LivePluginRuntime.shared.call(args[2], args[3], payload)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                print(String(decoding: try encoder.encode(reply), as: UTF8.self))
            } catch { print("error \(error)") }
            return
        }
        // --plugin-qr <plugin> [seconds]: a QR sign-in up to the code and a few polls (scan it to go all the way).
        if args[1] == "--plugin-qr", args.count > 2 {
            guard let plan = await LivePlugins.shared.qrLogin(args[2]) else { print("no QR sign-in"); return }
            print("plan poll=\(plan.pollInterval)s timeout=\(plan.timeout)s refreshes=\(plan.maxRefreshes) verifies=\(plan.verifies) hint=\(plan.hint)")
            let session = LivePluginQRSession(plugin: args[2], plan: plan)
            let challenge = try await session.start()
            print("code \(challenge.content.prefix(70))… (\(challenge.content.count) chars) expires=\(challenge.expires.map { Int($0.timeIntervalSinceNow) } ?? -1)s poll=\(challenge.pollInterval)s")
            if let folder = ProcessInfo.processInfo.environment["QR_SAVE"] { try challenge.content.write(toFile: folder + "/qr.txt", atomically: true, encoding: .utf8) }
            let end = Date().addingTimeInterval(args.count > 3 ? Double(args[3]) ?? 8 : 8)
            try await Task.sleep(for: .seconds(challenge.firstPollDelay))
            while Date() < end {
                try await Task.sleep(for: .seconds(challenge.pollInterval))
                let state = try await session.poll()
                print("state \(state)")
                if state == .confirmed || state == .expired { break }
                if case .failed = state { break }
            }
            await session.cancel()
            print("signed in: \(LivePluginAccounts.isSignedIn(args[2]))")
            return
        }
        // --plugin-device <plugin> [seconds]: a device-code sign-in up to the code and a few polls.
        if args[1] == "--plugin-device", args.count > 2 {
            guard await LivePlugins.shared.signsInByDeviceCode(args[2]) else { print("no device-code sign-in"); return }
            let session = LivePluginDeviceSession(plugin: args[2])
            let code = try await session.start()
            print("code length=\(code.code.count) page=\(code.page.host() ?? "-")\(code.page.path()) carriesCode=\(code.page.query()?.contains(code.code) ?? false) expires=\(Int(code.expires.timeIntervalSinceNow))s interval=\(code.interval)s")
            let end = Date().addingTimeInterval(args.count > 3 ? Double(args[3]) ?? 12 : 12)
            while Date() < end {
                try await Task.sleep(for: .seconds(code.interval))
                let state = try await session.poll()
                print("state \(state)")
                if state != .waiting { break }
            }
            await session.cancel()
            print("signed in: \(LivePluginAccounts.isSignedIn(args[2]))")
            return
        }
        if args[1] == "--plugin-danmaku", args.count > 2 {
            // --plugin-danmaku <pluginId> [roomId [userId]] [seconds]: listens to a room's chat through the plugin's danmaku
            // driver and prints each comment; without a room, the first room of the plugin's first area.
            setvbuf(stdout, nil, _IONBF, 0)
            guard let platform = LivePlatform(rawValue: "plugin." + args[2]) else { print("plugin \(args[2]) isn't installed"); return }
            var room = args.count > 3 ? args[3] : "", user = args.count > 4 ? args[4] : ""
            if room.isEmpty {
                guard let area = try await LiveCatalog.areas(platform).first else { print("no areas"); return }
                let first = try await LiveCatalog.rooms(platform, area: area, page: 1).first
                room = first?.roomID ?? ""; user = first?.userID ?? ""
                print("room \(room) user \(user) \(first?.host ?? "") \(first?.title ?? "")")
            }
            let seconds = args.count > 5 ? Int(args[5]) ?? 30 : 30
            let chat = LivePluginChat(plugin: args[2], room: room, user: user)
            let count = ManagedAtomicCounter()
            chat.start { text, color, _ in print(String(format: "  #%06X %@", color, text)); count.add() }
            try await Task.sleep(for: .seconds(seconds))
            chat.stop()
            print("comments \(count.value) in \(seconds) s")
            try await Task.sleep(for: .seconds(1))
            return
        }
        if args[1] == "--plugin-install", args.count > 2 {
            // --plugin-install <source address, angellive:// link or key> [pluginId ...]: installs live plugins
            // (all of the source's without ids); then `--live plugin.<id> [keyword|room:<id>]` tries one.
            setvbuf(stdout, nil, _IONBF, 0)
            guard let address = LivePlugins.sourceAddress(args[2]) else { throw LivePlugins.Failure.notASource }
            let (name, entries) = try await LivePlugins.shared.index(address)
            print("source \(name): \(entries.map { "\($0.pluginId) \($0.version)" }.joined(separator: ", "))")
            LivePlugins.shared.addSource(address, name: name)
            let wanted = Set(args.dropFirst(3))
            for entry in entries where wanted.isEmpty || wanted.contains(entry.pluginId) {
                do {
                    try await LivePlugins.shared.install(entry, from: address)
                    let record = LivePlugins.shared.installed(entry.pluginId)
                    print("installed \(entry.pluginId) \(record?.version ?? "-") tint=\(record?.tint ?? "-")")
                } catch {
                    print("failed \(entry.pluginId): \(error.localizedDescription)")
                }
            }
            print("platforms \(LivePlugins.shared.platforms.map { "\($0.id) \($0.scheme)" })")
            return
        }
        if args[1] == "--flv-live", args.count > 2 {
            // --flv-live <url> [Name: value ...]: plays a live FLV stream through FLVLive for 20 s.
            setvbuf(stdout, nil, _IONBF, 0)
            var headers: [String: String] = [:]
            for field in args.dropFirst(3) {
                let parts = field.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { headers[parts[0]] = parts[1] }
            }
            let began = Date()
            let address = try await FLVLive.open(URL(string: args[2])!, headers: headers)
            print("open ms=\(Int(Date().timeIntervalSince(began) * 1000)) \(address)")
            let master = try await URLSession.shared.data(from: address).0
            print(String(decoding: master, as: UTF8.self))
            let media = try await URLSession.shared.data(from: address.deletingLastPathComponent().appending(path: "0.m3u8")).0
            print(String(decoding: media, as: UTF8.self))
            let item = AVPlayerItem(url: address)
            let player = AVPlayer(playerItem: item); player.isMuted = true; player.play()
            for second in 1...20 {
                try await Task.sleep(for: .seconds(1))
                print("t=\(second) status=\(item.status.rawValue) time=\(String(format: "%.1f", player.currentTime().seconds)) rate=\(player.rate) size=\(Int(item.presentationSize.width))x\(Int(item.presentationSize.height)) error=\(item.error.map { "\($0)" } ?? "-")")
            }
            for event in item.errorLog()?.events ?? [] { print("errorlog \(event.errorStatusCode) \(event.errorComment ?? "-")") }
            for event in (item.accessLog()?.events ?? []).suffix(1) { print("access stalls=\(event.numberOfStalls) dropped=\(event.numberOfDroppedVideoFrames) indicated=\(Int(event.indicatedBitrate))") }
            return
        }
        if args[1] == "--cast-listen" {
            // --cast-listen [seconds]: runs the Bilibili cast receiver and prints what phones send.
            setvbuf(stdout, nil, _IONBF, 0)
            let receiver = BilibiliCastReceiver.shared
            receiver.name = "Yingxia Probe"
            receiver.onEvent = { event in print("event \(event)") }
            receiver.start()
            receiver.update(.init(playing: true, position: 12, duration: 300))
            print("listening")
            try await Task.sleep(for: .seconds(args.count > 2 ? Double(args[2]) ?? 60 : 60))
            return
        }
        if args[1] == "--drama-check", args.count > 2 {
            // --drama-check xifan|hema [keyword]: home, search, a detail and two seconds of its first episode.
            setvbuf(stdout, nil, _IONBF, 0)
            let site = try await cloudSite { $0.key == (args[2] == "hema" ? "builtin.hema" : "builtin.xifan") }
            let client = CatalogClient(site: site, origin: try CloudSources.address)
            let home = try await client.home()
            print("home categories=\(home.categories.count) videos=\(home.videos.count) first=\(home.categories.prefix(3).map(\.name))")
            let search = try await client.list(category: nil, query: args.count > 3 ? args[3] : "总裁", page: 1)
            print("search videos=\(search.videos.count) pages=\(search.pageCount)")
            guard let first = home.videos.first else { throw TVError.emptyPlaylist }
            let video = try await client.detail(first.id)
            print("detail \(video.name) episodes=\(video.episodes.count) remarks=\(video.remarks) poster=\(video.poster?.absoluteString ?? "-")")
            guard let episode = video.episodes.first else { throw TVError.emptyPlaylist }
            let channel = try await client.playback(episode)
            print("resolve host=\(channel.url.host ?? "-")")
            let item = AVPlayerItem(asset: AVURLAsset(url: channel.url, options: ["AVURLAssetHTTPHeaderFieldsKey": channel.headers]))
            let player = AVPlayer(playerItem: item)
            player.isMuted = true; player.play()
            for _ in 0..<75 where player.currentTime().seconds < 2 && item.status != .failed { try await Task.sleep(for: .milliseconds(200)) }
            print("play status=\(item.status.rawValue) time=\(player.currentTime().seconds) size=\(item.presentationSize) error=\(item.error?.localizedDescription ?? "-")")
            guard player.currentTime().seconds >= 2 else { throw TVError.emptyPlaylist }
            return
        }
        if args[1] == "--music-channel" {
            // --music-channel <channel> <platform> <song id> [lossless|high|standard] [subscription address]
            // asks one of the subscription's music channels for a song and probes what it answers. The address
            // is for a copy of the subscription served somewhere else (a local `wrangler dev`).
            guard args.count >= 5, let platform = MusicPlatform(rawValue: args[3]) else { throw TVError.invalidConfiguration }
            if args.count > 6, let address = URL(string: args[6]) {
                // Never a cached copy: it would name the script of an earlier build.
                let (data, _) = try await URLSession.shared.data(for: URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData))
                CloudSources.current = try Subscription.parse(data, origin: address)
            } else { CloudSources.current = try await CloudSources.fetch(http: HTTPClient(), address: Self.sourcesAddress()) }
            guard let listing = CloudMusic.current else { print("the subscription lists no music channels"); return }
            print("channels: " + listing.channels.map { "\($0.id.rawValue)[\($0.platforms.map(\.rawValue).sorted().joined(separator: ","))]" }.joined(separator: " "))
            print("order: " + listing.routes.order.map { "\($0.provider.rawValue)·\($0.platform.rawValue)" }.joined(separator: " ") + " primaries=\(listing.routes.primaries)")
            guard let channel = listing.channel(MusicProviderID(rawValue: args[2])) else { print("no such channel"); return }
            let quality = args.count > 5 ? MusicAudioQuality(rawValue: args[5]) ?? .lossless : .lossless
            let started = Date()
            do {
                let stream = try await CloudMusicProvider(channel: channel, api: listing.api, health: MusicHealth(file: nil)).resolve(args[4], platform: platform, quality: quality)
                print(String(format: "resolved in %.1fs host=%@ claimed=%@ upstream=%@", Date().timeIntervalSince(started), stream.url.host() ?? "-", stream.claimedQuality ?? "-", stream.upstream ?? "-"))
                let probe = try await MusicProber().probe(stream, expected: nil)
                print("probe: \(probe.format.label) \(probe.completeness.rawValue) duration=\(probe.duration.map { String(format: "%.1f", $0) } ?? "-")")
            } catch { print(String(format: "failed in %.1fs: ", Date().timeIntervalSince(started)) + MusicProviderError(error).detail) }
            return
        }
        if args[1] == "--account", args.count > 3 {
            // --account <site key> start | poll <token> | check: a recommended source's sign-in, as Settings runs it.
            // Never prints the sign-in itself.
            _ = try await cloudSite { $0.key == args[2] }
            guard let signIn = SourceSignIn.all.first(where: { $0.site.key == args[2] }) else { print("no sign-in for \(args[2])"); return }
            print("sign-in \(signIn.id) name=\(signIn.name) note=\(signIn.note ?? "-")")
            switch args[3] {
            case "start":
                let code = try await signIn.start()
                print("code=\(code.code)")
                for _ in 0..<(Int(ProcessInfo.processInfo.environment["POLLS"] ?? "") ?? 3) {
                    try await Task.sleep(for: .seconds(2))
                    let status = try await signIn.poll(code)
                    if case .signedIn(let account) = status { print("signedIn name=\(account.name) cookie=\(account.cookie.count) chars"); return }
                    print("status=\(status)")
                }
            default:
                let account = SourceAccount.load(signIn.id)
                guard account.signedIn else { print("not signed in"); return }
                print("check: \((await signIn.refreshed(account)).map { "valid name=\($0.name)" } ?? "no longer accepted")")
            }
            return
        }
        if args[1] == "--site-check" || args[1] == "--site-play", args.count > 2, case let key = args[2], case let args = Array(args[...1] + args[3...]) {
            // --site-play <site key> <series id> [episode number] isolates playback from catalog/search availability.
            // --site-check <site key> [series id] [episode number] also checks the catalog, search and rankings.
            setvbuf(stdout, nil, _IONBF, 0)
            let client = CatalogClient(site: try await cloudSite { $0.key == key }, origin: try CloudSources.address)
            var defaultID: String?
            if args[1] == "--site-check" {
                let home = try await client.home()
                defaultID = home.videos.first?.id
                print("home categories=\(home.categories.count) videos=\(home.videos.count)")
                let search = try await client.list(category: nil, query: "总裁", page: 1)
                print("search videos=\(search.videos.count) pages=\(search.pageCount)")
                let rank = try await client.list(category: "hot-drama", query: "", page: 1)
                print("ranking videos=\(rank.videos.count) pages=\(rank.pageCount)")
            }
            guard let id = args.count > 2 ? args[2] : defaultID else { throw TVError.emptyPlaylist }
            let video = try await client.detail(id)
            if args.count > 4 {
                // Several episodes in one process, as the app asks for them: resolve only.
                for number in args[3...].compactMap({ Int($0) }) where video.episodes.indices.contains(number - 1) {
                    do {
                        let channel = try await client.playback(video.episodes[number - 1])
                        print("episode \(number) streaming=\(channel.url.scheme == CENCStreams.scheme) host=\(channel.url.host ?? "-")")
                    } catch { print("episode \(number) failed: \(error)") }
                }
                return
            }
            let index = args.count > 3 ? (Int(args[3]) ?? 4) - 1 : 3
            guard video.episodes.indices.contains(index) else { throw TVError.emptyPlaylist }
            print("detail episodes=\(video.episodes.count) selected=\(index + 1)")
            let started = Date()
            let channel = try await client.playback(video.episodes[index])
            print("resolve seconds=\(Date().timeIntervalSince(started)) streaming=\(channel.url.scheme == CENCStreams.scheme)")
            let asset = CENCStreams.asset(for: channel.url) ?? AVURLAsset(url: channel.url, options: ["AVURLAssetHTTPHeaderFieldsKey": channel.headers])
            let item = AVPlayerItem(asset: asset), player = AVPlayer()
            item.preferredForwardBufferDuration = CENCStreams.forwardBufferDuration
            player.replaceCurrentItem(with: item); player.isMuted = true; player.play()
            let positionUpdates = Task {
                while !Task.isCancelled {
                    CENCStreams.updatePosition(for: channel.url, seconds: player.currentTime().seconds)
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { positionUpdates.cancel(); CENCStreams.stop(channel.url) }
            var firstFrame = false
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(200))
                if item.status == .failed { throw item.error ?? TVError.emptyPlaylist }
                if !firstFrame, player.currentTime().seconds > 0.05 {
                    firstFrame = true
                    let stats = await CENCStreams.statistics(for: channel.url)
                    print("first frame seconds=\(Date().timeIntervalSince(started)) bytes=\(stats?.received ?? 0)/\(stats?.total ?? 0)")
                }
                if player.currentTime().seconds > 2 { break }
            }
            let duration = try await asset.load(.duration).seconds
            print("play status=\(item.status.rawValue) time=\(player.currentTime().seconds) size=\(item.presentationSize) duration=\(duration)")
            if let stats = await CENCStreams.statistics(for: channel.url) {
                print("startup seconds=\(Date().timeIntervalSince(started)) bytes=\(stats.received)/\(stats.total) cache=\(stats.cached) requests=\(stats.requests)")
            }
            guard player.currentTime().seconds > 2 else { throw TVError.emptyPlaylist }
            player.pause()
            try await Task.sleep(for: .seconds(3))
            let beforePause = await CENCStreams.statistics(for: channel.url)
            try await Task.sleep(for: .seconds(3))
            let afterPause = await CENCStreams.statistics(for: channel.url)
            if let beforePause, let afterPause {
                print("paused bytes=\(afterPause.received)/\(afterPause.total) additional=\(afterPause.received - beforePause.received) cache=\(afterPause.cached) bufferedThrough=\(afterPause.bufferedThrough)s")
                guard afterPause.received == beforePause.received else { throw TVError.emptyPlaylist }
                guard afterPause.bufferedThrough <= player.currentTime().seconds + CENCStreams.forwardBufferDuration + 10 else { throw TVError.emptyPlaylist }
                if duration > 90 { guard afterPause.received < afterPause.total else { throw TVError.emptyPlaylist } }
            }
            player.play()
            await player.seek(to: CMTime(seconds: max(0, duration - 15), preferredTimescale: 600))
            try await Task.sleep(for: .seconds(3))
            print("seek time=\(player.currentTime().seconds) status=\(item.status.rawValue)")
            guard item.status == .readyToPlay, player.currentTime().seconds >= duration - 16 else { throw TVError.emptyPlaylist }
            await player.seek(to: CMTime(seconds: 5, preferredTimescale: 600))
            try await Task.sleep(for: .seconds(2))
            print("seek back time=\(player.currentTime().seconds) status=\(item.status.rawValue)")
            guard item.status == .readyToPlay, (5...10).contains(player.currentTime().seconds) else { throw TVError.emptyPlaylist }
            player.pause()
            CENCStreams.stop(channel.url)
            return
        }
        if args[1] == "--site-bench", args.count > 4, case let key = args[2], case let args = Array(args[...1] + args[3...]) {
            // --site-bench <site key> <stream|file> <seconds> [series id] [episode number]: this process's CPU time,
            // wakeups and network activity while an episode plays, streamed or from a prepared local file.
            setvbuf(stdout, nil, _IONBF, 0)
            let mode = args[2], seconds = Double(args[3]) ?? 60
            func usage() -> (cpu: Double, wakeups: UInt64) {
                var r = rusage(); getrusage(RUSAGE_SELF, &r)
                let cpu = Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
                var info = task_power_info(), count = mach_msg_type_number_t(MemoryLayout<task_power_info>.size / MemoryLayout<natural_t>.size)
                _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &count) } }
                return (cpu, info.task_interrupt_wakeups + info.task_platform_idle_wakeups)
            }
            let client = CatalogClient(site: try await cloudSite { $0.key == key }, origin: try CloudSources.address)
            let id: String
            if args.count > 4 { id = args[4] } else { guard let first = try await client.home().videos.first?.id else { throw TVError.emptyPlaylist }; id = first }
            let video = try await client.detail(id)
            let index = args.count > 5 ? (Int(args[5]) ?? 1) - 1 : 0
            let before = usage(), started = Date()
            let plan = try await client.preparePlayback(video.episodes[index], forDownload: mode == "file")
            guard let url = URL(string: plan.choices[0].address) else { throw TVError.emptyPlaylist }
            let prepared = usage()
            print("prepare seconds=\(String(format: "%.1f", Date().timeIntervalSince(started))) cpu=\(String(format: "%.3f", prepared.cpu - before.cpu)) series=\(id) episode=\(index + 1)")
            let asset = CENCStreams.asset(for: url) ?? AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset), player = AVPlayer()
            item.preferredForwardBufferDuration = CENCStreams.forwardBufferDuration
            player.replaceCurrentItem(with: item); player.isMuted = true; player.play()
            for _ in 0..<150 where player.currentTime().seconds < 0.5 && item.status != .failed { try await Task.sleep(for: .milliseconds(100)) }
            guard player.currentTime().seconds >= 0.5 else { throw item.error ?? TVError.emptyPlaylist }
            let duration = try await asset.load(.duration).seconds
            print("playing size=\(item.presentationSize) duration=\(Int(duration))s")
            let start = usage(), startStats = await CENCStreams.statistics(for: url)
            var last = startStats?.received ?? 0, active = 0
            for _ in 0..<Int(seconds) {
                try await Task.sleep(for: .seconds(1))
                CENCStreams.updatePosition(for: url, seconds: player.currentTime().seconds)
                if let stats = await CENCStreams.statistics(for: url) { if stats.received > last { active += 1 }; last = stats.received }
                if item.status == .failed { throw item.error ?? TVError.emptyPlaylist }
            }
            let end = usage(), endStats = await CENCStreams.statistics(for: url)
            let played = player.currentTime().seconds
            print("bench mode=\(mode) played=\(String(format: "%.1f", played))s cpu=\(String(format: "%.3f", end.cpu - start.cpu))s cpu%=\(String(format: "%.2f", (end.cpu - start.cpu) / seconds * 100)) wakeups/s=\((end.wakeups - start.wakeups) / UInt64(max(1, seconds))) requests=\((endStats?.requests ?? 0) - (startStats?.requests ?? 0)) bytes=\((endStats?.received ?? 0) - (startStats?.received ?? 0)) networkActiveSeconds=\(active) total=\(endStats?.total ?? 0)")
            print("whole run cpu=\(String(format: "%.3f", end.cpu - before.cpu))s fetched=\(endStats?.received ?? 0) requests=\(endStats?.requests ?? 0)")
            player.pause()
            CENCStreams.stop(url)
            return
        }
        if args[1] == "--cloud-site", args.count >= 3 {
            // --cloud-site <key> [keyword]: one of Yingxia's own sources end to end: home, a search (or the
            // home's first video), details, the first episode's stream through AVPlayer for a few seconds.
            setvbuf(stdout, nil, _IONBF, 0)
            let site = try await cloudSite { $0.key == args[2] }
            let client = CatalogClient(site: site, origin: try CloudSources.address)
            let home = try await client.home()
            print("home \(site.name) categories=\(home.categories.map(\.name).joined(separator: ",")) videos=\(home.videos.count)")
            var videos = home.videos
            if args.count > 3 { videos = try await client.list(category: nil, query: args[3], page: 1).videos; print("search \(args[3]): \(videos.count)") }
            if videos.isEmpty, let first = home.categories.first { videos = try await client.list(category: first.id, query: "", page: 1).videos }
            guard let first = videos.first else { print("no videos"); return }
            let video = try await client.detail(first.id)
            print("detail \(video.name) episodes=\(video.episodes.count)")
            guard let episode = video.episodes.first else { return }
            let channel = try await client.playback(episode)
            print("channel \(channel.url.absoluteString.prefix(120)) qualities=\(DashStreams.qualities(for: channel.url).map(\.label))")
            print("danmaku \(DanmakuSource.has(channel.url) ? (await DanmakuSource.comments(for: channel.url))?.count ?? 0 : -1)")
            let asset = DashStreams.asset(for: channel.url) ?? CENCStreams.asset(for: channel.url)
                ?? AVURLAsset(url: channel.url, options: ["AVURLAssetHTTPHeaderFieldsKey": channel.headers])
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item); player.isMuted = true; player.play()
            for second in 1...10 {
                try await Task.sleep(for: .seconds(1))
                print("t=\(second) status=\(item.status.rawValue) time=\(String(format: "%.1f", player.currentTime().seconds)) size=\(Int(item.presentationSize.width))x\(Int(item.presentationSize.height)) error=\(item.error.map { "\($0)" } ?? "-")")
            }
            return
        }
        if args[1] == "--bili-categories" {
            // --bili-categories [filter]: every category of the built-in Bilibili source with its first page's size.
            setvbuf(stdout, nil, _IONBF, 0)
            let client = CatalogClient(site: try await cloudSite(\.isBilibili), origin: try CloudSources.address)
            let home = try await client.home()
            print("home categories=\(home.categories.count) videos=\(home.videos.count)")
            for category in home.categories where args.count < 3 || category.id.contains(args[2]) || category.name.contains(args[2]) {
                do {
                    let page = try await client.list(category: category.id, query: "", page: 1)
                    print("\(page.videos.isEmpty ? "EMPTY" : "OK   ") \(category.id) \(category.name) videos=\(page.videos.count)")
                } catch {
                    print("FAIL  \(category.id) \(category.name) \(error.localizedDescription)")
                }
            }
            return
        }
        if args[1] == "--bili-play", args.count >= 3 {
            // --bili-play <BV id | season_N> [part index] [seconds]: the built-in Bilibili source end to end,
            // through its script port, playback resolution and AVPlayer.
            setvbuf(stdout, nil, _IONBF, 0)
            let client = CatalogClient(site: try await cloudSite(\.isBilibili), origin: try CloudSources.address)
            let video = try await client.detail(args[2])
            let episode = video.episodes[min(args.count > 3 ? Int(args[3]) ?? 0 : 0, video.episodes.count - 1)]
            print("detail \(video.name) parts=\(video.episodes.count) playing=\(episode.name) \(episode.address)")
            let channel = try await client.playback(episode)
            print("channel \(channel.url.absoluteString.prefix(120))")
            let comments = await DanmakuSource.comments(for: channel.url) ?? []
            print("danmaku \(comments.count) first=\(comments.prefix(3).map { "\(String(format: "%.1f", $0.time)) \($0.text)" })")
            let windows = Dictionary(grouping: comments) { Int($0.time / 10) * 10 }.mapValues(\.count)
            print("busiest 10s windows \(windows.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key)s:\($0.value)" })")
            print("per 10s \(windows.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))")
            let asset = DashStreams.asset(for: channel.url) ?? AVURLAsset(url: channel.url, options: ["AVURLAssetHTTPHeaderFieldsKey": channel.headers])
            if channel.url.scheme == DashStreams.scheme {
                for variant in try await asset.load(.variants) {
                    let video = variant.videoAttributes
                    print("variant peak=\(Int(variant.peakBitRate ?? 0)) size=\(video.map { "\(Int($0.presentationSize.width))x\(Int($0.presentationSize.height))" } ?? "-") codecs=\(video?.codecTypes.map { String(format: "%08x", $0) } ?? [])")
                }
            }
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.play()
            for second in 1...(args.count > 4 ? Int(args[4]) ?? 12 : 12) {
                try await Task.sleep(for: .seconds(1))
                let log = item.accessLog()?.events.last
                print("t=\(second) status=\(item.status.rawValue) time=\(String(format: "%.1f", player.currentTime().seconds)) size=\(Int(item.presentationSize.width))x\(Int(item.presentationSize.height)) indicated=\(Int(log?.indicatedBitrate ?? 0)) error=\(item.error.map { "\($0)" } ?? item.errorLog()?.events.last?.errorComment ?? "-")")
                if item.status == .failed { break }
            }
            // Seek near the end: fragments far from the start must resolve too.
            let duration = try await asset.load(.duration).seconds
            if duration.isFinite, duration > 30 {
                await player.seek(to: CMTime(seconds: duration - 20, preferredTimescale: 600))
                try await Task.sleep(for: .seconds(4))
                print("after seek duration=\(Int(duration)) time=\(String(format: "%.1f", player.currentTime().seconds)) status=\(item.status.rawValue)")
            }
            return
        }
        if args[1] == "--subscription-check" {
            struct Result: Encodable, Sendable {
                let address: String
                var origin: String? = nil
                var sites: Int? = nil
                var lives: Int? = nil
                var error: String? = nil
            }
            var results: [Result] = []
            let addresses = Array(args.dropFirst(2))
            for start in stride(from: 0, to: addresses.count, by: 6) {
                await withTaskGroup(of: Result.self) { group in
                    for address in addresses[start..<min(start + 6, addresses.count)] {
                        group.addTask {
                            do {
                                let config = try await HTTPClient().subscription(WebAddress.resolve(address))
                                return Result(address: address, origin: config.origin.absoluteString, sites: config.sites.count, lives: config.lives.count)
                            } catch { return Result(address: address, error: error.localizedDescription) }
                        }
                    }
                    for await result in group { results.append(result) }
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(results.sorted { $0.address < $1.address }), as: UTF8.self))
            return
        }
        if args[1] == "--drive-check", args.count >= 4 {
            // --drive-check <subscription> <source> [search]: each drive of a cloud-drive source's first
            // video, DIRECT (CDN, CloudStreams) or PROXY (every byte through the plugin runtime).
            setvbuf(stdout, nil, _IONBF, 0)
            do { try await driveCheck(subscription: args[2], source: args[3], query: args.count > 4 ? args[4] : nil) }
            catch { print("failed: \(error.localizedDescription)") }
            for entry in await Diagnostics.shared.snapshot().entries where entry.category.hasPrefix("jar") || entry.category.hasPrefix("plugin") {
                print("  \(entry.category): \(entry.message.prefix(240))")
            }
            return
        }
        if args[1] == "--catalog-check", args.count >= 3 {
            // Browses sources the way the app does (CatalogClient, so lite ports with their JAR
            // fallback): home, a category when home has no videos, detail, then playback.
            let config = try await cliSubscription(args[2])
            let filters = Array(args.dropFirst(3))
            let sites = config.sites.filter { site in filters.isEmpty || filters.contains { site.name.contains($0) || site.key.contains($0) } }
            var passed = 0
            for site in sites {
                let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL)
                var stage = "home"
                do {
                    let home = try await client.home()
                    var videos = home.videos
                    if videos.isEmpty, let category = home.categories.first {
                        stage = "category"
                        videos = try await client.list(category: category.id, query: "", page: 1).videos
                    }
                    guard let first = videos.first else { throw TVError.unsupported("no videos") }
                    stage = "detail"
                    let video = try await client.detail(first.id)
                    guard let episode = video.episodes.first else { throw TVError.unsupported("no episodes") }
                    stage = "play"
                    let plan = try await client.preparePlayback(episode)
                    passed += 1
                    // 首页的「条数 / 有封面的条数 / 总页数」是这一版最容易被悄悄破坏的三件事：
                    // 用错 `ac=` 时首页仍有 20 条但一张图都没有，分类页则只剩 1 条。
                    let posters = home.videos.filter { $0.poster != nil }.count
                    // 分类页单独再走一遍：这是「翻不动」最容易出问题的地方 —— 有些采集站不认
                    // `t=`，那时应当退回全量列表（条数会是满页），而不是只回一条。
                    var categoryNote = "cat[-]"
                    if let first = home.categories.first, let page = try? await client.list(category: first.id, query: "", page: 1) {
                        categoryNote = "cat[\(first.name)] \(page.videos.count)/\(page.pageCount)p"
                    }
                    print("OK   \(site.name)  [\(site.compatibility)]  \(home.videos.count) home / \(posters) posters / \(home.pageCount) pages, \(home.categories.count) categories, \(categoryNote), play \(plan.choices[0].address.prefix(60))")
                } catch {
                    print("FAIL \(site.name)  [\(site.compatibility)]  [\(stage)] \(error.localizedDescription)")
                }
            }
            for entry in await Diagnostics.shared.snapshot().entries where entry.category == "lite.fallback" { print("     fallback: \(entry.message)") }
            print("\(passed)/\(sites.count) sources reached playback")
            return
        }
        if args[1] == "--tmdb-sample", args.count >= 4, let perSource = Int(args[3]) {
            // --tmdb-sample <subscription> <videos per source> [source filters]: one JSON line per video with what
            // the app sends the TMDB matcher (TMDBMatch.Request), from home and the first categories, for
            // Scripts/tmdb-sample.py.
            setvbuf(stdout, nil, _IONBF, 0)
            let config = try await cliSubscription(args[2])
            let filters = Array(args.dropFirst(4))
            let sites = config.sites.filter { site in filters.isEmpty || filters.contains { site.name.contains($0) || site.key.contains($0) } }
            struct Sample: Encodable { let source: String; let sourceName: String; let id: String; let request: TMDBMatch.Request }
            func deadline<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
                try await withThrowingTaskGroup(of: T.self) { group in
                    group.addTask { try await work() }
                    group.addTask { try await Task.sleep(for: .seconds(seconds)); throw TVError.unsupported("timed out") }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            }
            for site in sites {
                let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL)
                do {
                    let home = try await deadline(40) { try await client.home() }
                    // Home often shows one kind only: mix in the first categories (movies, series, anime…).
                    var lists = [home.videos]
                    for category in home.categories.prefix(4) {
                        lists.append((try? await deadline(40) { try await client.list(category: category.id, query: "", page: 1).videos }) ?? [])
                    }
                    var videos: [Video] = [], seen = Set<String>()
                    for index in 0..<40 where videos.count < perSource {
                        for list in lists where index < list.count && videos.count < perSource && seen.insert(list[index].id).inserted { videos.append(list[index]) }
                    }
                    for video in videos {
                        guard let detail = try? await deadline(40, { try await client.detail(video.id) }) else { continue }
                        let line = Sample(source: site.key, sourceName: site.name, id: video.id,
                                          request: TMDBMatch.Request(video: detail.keepingPoster(video.poster), listVideo: video))
                        print(String(decoding: try JSONEncoder().encode(line), as: UTF8.self))
                    }
                } catch {
                    FileHandle.standardError.write(Data("FAIL \(site.key) \(site.name): \(error.localizedDescription)\n".utf8))
                }
            }
            return
        }
        if args[1] == "--tmdb-check", args.count >= 3 {
            // --tmdb-check <samples.jsonl> [parallel]: asks the TMDB matcher about each --tmdb-sample line through the app's
            // client (TMDBMatch), and prints one JSON line per video: the answer, its steps and time, and how the
            // source's episodes line up with TMDB's.
            setvbuf(stdout, nil, _IONBF, 0)
            struct Sample: Decodable { let source: String; let sourceName: String; let id: String; let request: TMDBMatch.Request }
            struct Line: Encodable {
                let source: String, title: String, year: String?, episodes: Int
                var status = "", seconds = 0.0, steps: [String] = [], error: String? = nil
                var work: String? = nil, season: Int? = nil, numbering: String? = nil, unmatched: String? = nil, candidates: [String] = []
                var tmdbEpisodes: Int? = nil, mapped: Int? = nil, mapping: [String] = []
            }
            let samples = try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n").compactMap {
                try? JSONDecoder().decode(Sample.self, from: Data($0.utf8))
            }
            let parallel = args.count > 3 ? max(Int(args[3]) ?? 2, 1) : 2
            final class Steps: @unchecked Sendable { var list: [String] = []; let lock = NSLock()
                func add(_ step: String) { lock.lock(); list.append(step); lock.unlock() } }
            func check(_ sample: Sample) async -> Line {
                var line = Line(source: sample.sourceName, title: sample.request.title, year: sample.request.year, episodes: sample.request.episodes.count)
                let started = Date(), steps = Steps()
                do {
                    let answer = try await TMDBMatch.lookup(sample.request) { step in
                        switch step {
                        case .searching(let query): steps.add("search:\(query)")
                        case .checking(let name, let year): steps.add("details:\(name ?? "?")(\(year.map(String.init) ?? "?"))")
                        case .season(let number): steps.add("season:\(number)")
                        default: break
                        }
                    }
                    line.status = answer.status.rawValue
                    line.unmatched = answer.unmatched.isEmpty ? nil : answer.unmatched
                    line.candidates = answer.candidates.map { "\($0.mediaType.rawValue):\($0.id) \($0.name) (\($0.year.map(String.init) ?? "?"))" }
                    if let details = answer.details, let match = answer.match {
                        line.work = "\(details.mediaType.rawValue):\(details.id) \(details.name) (\(details.year.map(String.init) ?? "?"))"
                        line.season = match.season; line.numbering = match.numbering.rawValue
                        if let season = details.season {
                            line.tmdbEpisodes = season.episodes.count
                            let mapped = details.episodes(for: sample.request.episodes, numbering: match.numbering, offset: match.offset ?? 0)
                            line.mapped = mapped.compactMap { $0 }.count
                            let picks = Array(Set([0, 1, sample.request.episodes.count / 2, sample.request.episodes.count - 1])).sorted()
                            line.mapping = picks.filter { $0 >= 0 && $0 < mapped.count }.map { index in
                                "\(sample.request.episodes[index]) → \(mapped[index].map { "E\($0.number) \($0.name)" } ?? "–")"
                            }
                        }
                    }
                } catch {
                    line.status = "error"; line.error = error.localizedDescription
                }
                line.seconds = (Date().timeIntervalSince(started) * 10).rounded() / 10
                line.steps = steps.list
                return line
            }
            await withTaskGroup(of: Line.self) { group in
                var next = 0
                func add() { if next < samples.count { let sample = samples[next]; next += 1; group.addTask { await check(sample) } } }
                for _ in 0..<parallel { add() }
                for await line in group {
                    print(String(decoding: (try? JSONEncoder().encode(line)) ?? Data(), as: UTF8.self))
                    add()
                }
            }
            return
        }
        if args[1] == "--search-check", args.count >= 4 {
            // Searches every source of a subscription the way global search does (same lanes and widths) and
            // prints each source's outcome: --search-check <subscription> <keyword>...
            actor Tally { var ok = 0, empty = 0, failed = 0; func add(_ videos: Int?) { if let videos { if videos > 0 { ok += 1 } else { empty += 1 } } else { failed += 1 } } }
            let config = try await cliSubscription(args[2])
            for keyword in args.dropFirst(3) {
                let started = Date(), tally = Tally()
                await GlobalSearch.search(sites: config.sites, origin: config.origin, jarURL: config.spiderURL, query: keyword) { result in
                    let at = String(format: "+%.1fs", Date().timeIntervalSince(started))
                    let videos = result.error == nil ? result.page?.videos.count ?? 0 : nil
                    await tally.add(videos)
                    let label = videos == nil ? "FAIL" : videos == 0 ? "NONE" : "OK  "
                    print("\(label) \(keyword) \(result.site.key) \(result.site.name) \(at) \(videos.map { "videos=\($0)" } ?? String((result.error ?? "").prefix(220)))")
                }
                print("SUMMARY \(keyword): ok=\(await tally.ok) empty=\(await tally.empty) failed=\(await tally.failed) seconds=\(Int(Date().timeIntervalSince(started)))")
            }
            return
        }
        if args[1] == "--home-check", args.count >= 3 {
            // Loads each source's home the way the app's source page does and reports what its
            // category bar would show.
            let config = try await cliSubscription(args[2])
            let filters = Array(args.dropFirst(3))
            let sites = config.sites.filter { site in filters.isEmpty || filters.contains { site.name.contains($0) || site.key.contains($0) } }
            // One at a time: the plugin runtime turns away interactive calls beyond a short queue.
            for site in sites {
                let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL)
                do {
                    let home = try await client.home()
                    print("\(home.categories.isEmpty ? "NONE" : "OK  ") \(site.key)  \(site.name)  [\(site.compatibility) \(site.preferredRuntime)]  categories=\(home.categories.count) videos=\(home.videos.count)")
                } catch {
                    print("FAIL \(site.key)  \(site.name)  [\(site.compatibility) \(site.preferredRuntime)]  \(error.localizedDescription)")
                }
            }
            for entry in await Diagnostics.shared.snapshot().entries where entry.category == "lite.fallback" { print("     fallback: \(entry.message)") }
            return
        }
        if args[1] == "--cold-play", args.count >= 3 {
            // What a viewer actually pays the first time: a cold script runtime, a detail request,
            // then play — and then the same play again, which shows what the source's caches save.
            // `--cold-play builtin://kanju` measures the pack that ships inside the app.
            let config = try await cliSubscription(args[2])
            let filters = Array(args.dropFirst(3))
            let sites = config.sites.filter { site in
                site.preferredRuntime == .javascript && (filters.isEmpty || filters.contains { site.name.contains($0) || site.key.contains($0) })
            }
            for site in sites {
                let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL)
                print("\(site.key)  \(site.name)")
                var began = Date()
                func stage(_ name: String) {
                    let ms = Date().timeIntervalSince(began) * 1000
                    began = Date()
                    print("   " + name.padding(toLength: 12, withPad: " ", startingAt: 0) + String(format: "%7.0f ms", ms))
                }
                do {
                    let home = try await client.home()
                    stage("home")
                    guard let video = home.videos.first else { throw TVError.unsupported("no videos") }
                    let detail = try await client.detail(video.id)
                    stage("detail")
                    guard let episode = detail.episodes.first else { throw TVError.unsupported("no episodes") }
                    // The detail page warms the line list while the viewer reads; play then only signs.
                    await client.prefetchPlayback(episode)
                    stage("warm")
                    let plan = try await client.preparePlayback(episode)
                    stage("play")
                    let channel = try await client.resolvePlayback(plan, choice: plan.choices[0])
                    stage("resolve")
                    print("   → \(channel.url.absoluteString)")
                    let again = try await client.preparePlayback(episode)
                    stage("play (warm)")
                    _ = try await client.resolvePlayback(again, choice: again.choices[0])
                    stage("resolve (warm)")
                } catch {
                    print("   FAILED: \(error.localizedDescription.prefix(200))")
                }
            }
            for entry in await Diagnostics.shared.snapshot().entries where entry.category == "script.log" {
                print("   log: \(entry.message.prefix(200))")
            }
            return
        }
        if args[1] == "--script-check", args.count >= 3 {
            // Runs a subscription's JavaScript sources on the in-process QuickJS runtime (as iOS and
            // tvOS do): home, a category when home has no videos, detail, then playback.
            let config = try await cliSubscription(args[2])
            let filters = Array(args.dropFirst(3))
            let sites = config.sites.filter { site in site.preferredRuntime == .javascript && (filters.isEmpty || filters.contains { site.name.contains($0) || site.key.contains($0) }) }
            var passed = 0
            for site in sites {
                func call(_ params: [String: String]) async throws -> [String: JSONValue] {
                    // Lite ports run alone here, without the JAR fallback, so the check measures the ports.
                    try await ScriptRuntime.shared.request(site: site, scriptURL: site.liteScript ?? site.scriptURL(origin: config.origin), params: params, http: HTTPClient(), origin: config.origin)
                }
                var stage = "home"
                do {
                    let home = CatalogPage(json: try await call(site.type == 4 ? ["filter": "true"] : [:]), origin: config.origin)
                    var videos = home.videos
                    if videos.isEmpty, let category = home.categories.first {
                        stage = "category"
                        videos = CatalogPage(json: try await call(["pg": "1", "ac": "detail", "t": category.id]), origin: config.origin).videos
                    }
                    guard let first = videos.first else { throw TVError.unsupported("no videos") }
                    stage = "detail"
                    let detail = CatalogPage(json: try await call(["ac": "detail", "ids": first.id]), origin: config.origin).videos.first
                    guard let episode = detail?.episodes.first else { throw TVError.unsupported("no episodes") }
                    stage = "play"
                    let play = try await call(["play": episode.address, "flag": episode.flag])
                    let address = play["url"]?.string ?? play["url"]?.array.map { "\($0.count / 2) choices" } ?? "none"
                    passed += 1
                    print("OK   \(site.name.prefix(24))  \(home.categories.count) categories, \(videos.count) videos, play \(address.prefix(80))")
                } catch {
                    print("FAIL \(site.name.prefix(24))  [\(stage)] \(error.localizedDescription.prefix(160))")
                }
            }
            print("\(passed)/\(sites.count) JavaScript sources reached playback on QuickJS")
            return
        }
        if args[1] == "--subscription-export", args.count == 3 {
            do {
                let config = try await cliSubscription(args[2])
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(config), as: UTF8.self))
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
            return
        }
        if args[1] == "--live-check" {
            let origin = URL(string: "https://raw.githubusercontent.com/qist/tvbox/master/fty.json")!
            let config = try await HTTPClient().subscription(origin)
            print("Subscription: \(config.sites.count) sites, \(config.lives.count) live lists")
            await withTaskGroup(of: String.self) { group in
                for source in config.lives {
                    group.addTask {
                        do {
                            let channels = try await HTTPClient().channels(source)
                            return "\(source.name): \(channels.count) parsed channels (playback not verified)"
                        } catch { return "\(source.name): \(error.localizedDescription)" }
                    }
                }
                for await result in group { print(result) }
            }
            return
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let runtime = JarRuntime()
        let report: JarReport
        if args.count >= 4 { report = await runtime.runStaticInt(data, className: args[2], method: args[3]) }
        else { report = await runtime.inspect(data) }
        let values: [String: Any] = ["status": report.status, "dexFiles": report.dexFiles, "classes": report.classes,
                                    "nativeLibraries": report.nativeLibraries, "instructions": report.instructions,
                                    "value": report.value, "message": report.message]
        let json = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
        if report.status != 0 { exit(1) }
    }
}


/// A counter the chat's handler bumps from any thread.
final class ManagedAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

// MARK: - Novels (Legado book sources)

extension Probe {
    static func novelList(_ target: String) async throws -> [NovelSource] {
        let data: Data
        if target.hasPrefix("http") {
            var request = URLRequest(url: URL(string: target)!)
            request.timeoutInterval = 60
            data = try await URLSession.shared.data(for: request).0
        } else { data = try Data(contentsOf: URL(filePath: target)) }
        guard let sources = NovelSource.list(from: data) else { throw TVError.unsupported("not a Legado book source list") }
        return sources
    }

    /// One source end to end: search → details → table of contents → the first chapter's text.
    static func novelRun(_ source: NovelSource, keyword: String, verbose: Bool) async -> (stage: String, line: String) {
        let runtime = NovelRuntime.shared
        let began = Date()
        func took() -> String { String(format: "%.1fs", Date().timeIntervalSince(began)) }
        func short(_ error: Error) -> String { error.localizedDescription.replacingOccurrences(of: "\n", with: " ").prefix(160).description }
        guard source.searchable else { return ("no-search", "no searchUrl") }
        var books: [NovelBook]
        do { books = try await runtime.search(source, keyword: keyword, page: 1) } catch { return ("search-error", "search: \(short(error)) \(took())") }
        // Niche sources don't have every book: then the source's own test word (ruleSearch.checkKeyWord).
        let object = (try? JSONSerialization.jsonObject(with: Data(source.json.utf8))) as? [String: Any]
        let rules = (object?["ruleSearch"] as? [String: Any]) ?? ((object?["ruleSearch"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any])
        if books.isEmpty, let check = (rules?["checkKeyWord"] as? String)?.trimmingCharacters(in: .whitespaces), !check.isEmpty, check != keyword {
            do { books = try await runtime.search(source, keyword: check, page: 1) } catch { return ("search-error", "search \(check): \(short(error)) \(took())") }
        }
        if verbose { for book in books.prefix(5) { print("  book: \(book.name) / \(book.author) | \(book.kind) | \(book.lastChapter) | \(book.url) | cover \(book.cover.prefix(80))") } }
        let wanted = novelKey(keyword)
        // The keyword's book, or else the first result (niche sources don't have every book).
        guard let picked = books.first(where: { novelKey($0.name) == wanted }) ?? books.first(where: { novelKey($0.name).contains(wanted) }) ?? books.first else {
            return ("search-empty", "search: no results \(took())")
        }
        var book = picked
        do { book = try await runtime.details(source, book: picked) } catch { return ("info-error", "search \(books.count) → info: \(short(error)) \(took())") }
        if verbose { print("  info: \(book.name) / \(book.author) | kind \(book.kind) | words \(book.wordCount) | last \(book.lastChapter) | toc \(book.tocURL) | cover \(book.cover.prefix(100))\n  intro: \(book.intro.prefix(160))") }
        let chapters: [NovelChapter]
        do { chapters = try await runtime.chapters(source, book: book) } catch { return ("toc-error", "search \(books.count) → toc: \(short(error)) \(took())") }
        if verbose { for chapter in chapters.prefix(4) + chapters.suffix(2) { print("  chapter \(chapter.index): \(chapter.title) \(chapter.isVolume ? "[volume] " : "")\(chapter.isVip ? "[vip] " : "")\(chapter.url.prefix(100))") } }
        let readable = chapters.filter { !$0.isVolume }
        guard let first = readable.first else { return ("toc-empty", "search \(books.count) → toc empty \(took())") }
        let next = readable.dropFirst().first
        do {
            let content = try await runtime.content(source, book: book, chapter: first, next: next)
            let characters = content.paragraphs.reduce(0) { $0 + $1.count }
            if verbose { print("  content \(content.title): \(content.paragraphs.count) paragraphs, \(characters) characters"); for line in content.paragraphs.prefix(5) { print("    " + line.prefix(120)) } }
            if characters < 200 { return ("content-short", "search \(books.count) → toc \(chapters.count) → content only \(characters) chars: \(content.paragraphs.joined(separator: " ").prefix(100)) \(took())") }
            return ("ok", "search \(books.count) → toc \(chapters.count) → content \(content.paragraphs.count)¶ \(characters) chars \(took())")
        } catch { return ("content-error", "search \(books.count) → toc \(chapters.count) → content: \(short(error)) \(took())") }
    }

    /// Whether the source's site answers from here: "up", "down" (no answer), or "blocked" (403/5xx, a bot check, a parked domain).
    static func novelReach(_ source: NovelSource) async -> String {
        let address = String(source.key.split(separator: "#").first ?? "").trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true else { return "up" }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else { return "down" }
        let text = String(decoding: data.prefix(6000), as: UTF8.self)
        if http.statusCode == 403 || http.statusCode == 451 || http.statusCode >= 500 || text.contains("Just a moment...") || text.contains("region has been denied") { return "blocked" }
        return "up"
    }

    static func novelKey(_ text: String) -> String { text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol } }

    static func novelProfiles() {
        NovelRuntime.profilesRoot = FileManager.default.temporaryDirectory.appendingPathComponent("novel-probe-profiles", isDirectory: true)
    }

    /// --novel-check <list URL or file> [keyword] [--limit N] [--offset N] [--jobs N]
    static func novelCheck(_ args: [String]) async throws {
        novelProfiles()
        func option(_ name: String) -> Int? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } }
        var plain: [String] = [], skip = false
        for value in args { if skip { skip = false } else if value.hasPrefix("--") { skip = true } else { plain.append(value) } }
        let keyword = plain.count > 1 ? plain[1] : "斗破苍穹"
        let all = try await novelList(plain[0])
        let offset = option("--offset") ?? 0, limit = option("--limit") ?? all.count, jobs = max(1, option("--jobs") ?? 6)
        var sources = Array(all.dropFirst(offset).prefix(limit))
        if let sample = option("--sample"), sample < sources.count {
            // The same sample every run: a fixed-seed shuffle.
            var seed: UInt64 = 0x9E3779B97F4A7C15
            var generator = AnyRandom { seed &+= 0x9E3779B97F4A7C15; var z = seed; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
            sources = Array(sources.filter { !$0.disabledByList }.shuffled(using: &generator).prefix(sample))
        }
        print("\(all.count) sources in the list; checking \(sources.count) with \(keyword), \(jobs) at a time")
        var stages: [String: Int] = [:]
        var index = 0
        await withTaskGroup(of: (Int, NovelSource, String, String).self) { group in
            func add() {
                guard index < sources.count else { return }
                let (n, source) = (index, sources[index]); index += 1
                group.addTask {
                    async let reach = novelReach(source)
                    let result = await novelRun(source, keyword: keyword, verbose: false)
                    await NovelRuntime.shared.reset(source.key)
                    let site = await reach
                    return (n, source, result.stage == "ok" || site == "up" ? result.stage : result.stage + "/" + site, result.line)
                }
            }
            for _ in 0..<jobs { add() }
            while let (n, source, stage, line) = await group.next() {
                stages[stage, default: 0] += 1
                print("[\(n + offset)] \(stage.padding(toLength: 14, withPad: " ", startingAt: 0)) \(source.name) <\(source.key.prefix(60))>\(source.disabledByList ? " (off in list)" : "") — \(line)")
                add()
            }
        }
        print("summary:", stages.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        // Sources whose site is down or refuses this network can't pass anywhere from here.
        let reachable = stages.filter { !$0.key.contains("/") }.values.reduce(0, +)
        print(String(format: "ok %d of %d (%.0f%%); of the %d whose site answers from here: %.0f%%", stages["ok"] ?? 0, sources.count, Double(stages["ok"] ?? 0) * 100 / Double(max(sources.count, 1)),
                     reachable, Double(stages["ok"] ?? 0) * 100 / Double(max(reachable, 1))))
    }

    /// --novel-read <list> <source key or name> <keyword>: one source, verbosely.
    static func novelRead(_ list: String, _ which: String, keyword: String) async throws {
        novelProfiles()
        let sources = try await novelList(list)
        guard let source = sources.first(where: { $0.key == which }) ?? sources.first(where: { $0.name == which }) ?? sources.first(where: { $0.name.contains(which) || $0.key.contains(which) }) else {
            throw TVError.unsupported("no source \(which)")
        }
        print("source \(source.name) <\(source.key)> searchable=\(source.searchable) explorable=\(source.explorable)")
        if source.explorable {
            do {
                let kinds = try await NovelRuntime.shared.exploreKinds(source)
                print("explore: \(kinds.count) kinds: \(kinds.prefix(8).map { $0.title + ($0.url.isEmpty ? "" : "→") }.joined(separator: ", "))")
                if let kind = kinds.first(where: { !$0.url.isEmpty }) {
                    let books = try await NovelRuntime.shared.explore(source, url: kind.url, page: 1)
                    print("explore \(kind.title): \(books.count) books: \(books.prefix(5).map(\.name).joined(separator: ", "))")
                }
            } catch { print("explore failed: \(error.localizedDescription)") }
        }
        let result = await novelRun(source, keyword: keyword, verbose: true)
        print(result.stage, result.line)
    }
}

struct AnyRandom: RandomNumberGenerator {
    let make: () -> UInt64
    init(_ make: @escaping () -> UInt64) { self.make = make }
    mutating func next() -> UInt64 { make() }
}
