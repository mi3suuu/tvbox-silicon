import Foundation
import Testing
@testable import TVCore

private final class MockProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let status: Int
        let body: String
        if path == "/failure" { status = 503; body = "Unavailable" }
        else if path == "/subscription" {
            status = 200
            body = request.value(forHTTPHeaderField: "User-Agent") == HTTPClient.subscriptionUserAgent
                ? #"{"sites":[{"key":"中文","type":4,"api":"./api"}]}"#
                : "<!doctype html><html>Landing page</html>"
        } else if path == "/short-links" {
            status = 200
            body = #"{"sites":[{"key":"py","type":3,"api":"https://example.com/s/py"},{"key":"jar","type":3,"api":"https://example.com/s/jar"},{"key":"gone","type":3,"api":"https://example.com/failure"},{"key":"csp","type":3,"api":"csp_Test"}]}"#
        } else if path == "/s/py" {
            status = 200; body = "# -*- coding: utf-8 -*-\nimport sys\nsys.path.append('..')\nfrom base.spider import Spider as BaseSpider\n"
        } else if path == "/s/jar" {
            status = 200; body = "PK\u{03}\u{04}from base.spider import Spider"
        } else if path == "/headers" {
            status = request.value(forHTTPHeaderField: "User-Agent") == "Custom" ? 200 : 403
            body = "#EXTM3U\n#EXTINF:-1,Channel\nhttps://example.com/live.m3u8"
        } else if path == "/missing-id" {
            status = 200; body = #"{"list":[{"vod_play_from":"自动","vod_play_url":"1$opaque-episode"}]}"#
        } else if path == "/x/player/playurl" {
            status = 200
            body = #"{"code":0,"data":{"format":"mp4","durl":[{"url":"https://cdn.example.com/video.mp4"}]}}"#
        } else if path == "/login" {
            status = 200; body = #"{"parse":0,"url":"","errMsg":"未扫码登录无法观看"}"#
        } else if path == "/qualities" {
            status = 200; body = #"{"parse":0,"url":["480P","https://example.com/480.mp4","360P","https://example.com/360.mp4"]}"#
        } else if path == "/subs" {
            status = 200
            body = #"{"parse":0,"url":"https://cdn.example.com/film.mkv","subs":[{"name":"film.chs.srt","url":"http://127.0.0.1:9978/proxy?do=quark&type=sub","lang":"chs","format":"application/x-subrip"}]}"#
        } else if path == "/paged" {
            // Three pages of search results; the last page repeats, as some sources do.
            let page = min(3, Int(query.first(where: { $0.name == "pg" })?.value ?? "1") ?? 1)
            status = 200; body = #"{"pagecount":4,"list":[{"vod_id":"p\#(page)a","vod_name":"A"},{"vod_id":"p\#(page)b","vod_name":"B"}]}"#
        } else if path == "/cms" || path == "/cms-old" {
            // A CMS API, in the two shapes real ones come in:
            //   · `/cms`     — `ac=videolist` gives everything in one answer (posters, play urls,
            //                  pagecount) but **no** `class`; `ac=list` is the cheap taxonomy call.
            //   · `/cms-old` — refuses `videolist` (empty list); home then has to be pieced together
            //                  from `ac=list` plus one `ac=detail` for the missing posters.
            status = 200
            let action = query.first(where: { $0.name == "ac" })?.value
            let modern = path == "/cms"
            switch action {
            case .some("detail"):
                let ids = query.first(where: { $0.name == "ids" })?.value ?? ""
                body = ids == "7,8"
                    ? #"{"list":[{"vod_id":8,"vod_name":"B","vod_pic":"https://img.example.com/b.jpg"},{"vod_id":7,"vod_name":"A","vod_pic":"https://img.example.com/a.jpg"}]}"#
                    : #"{"list":[]}"#
            case .some("videolist"):
                body = modern
                    ? #"{"pagecount":"3","list":[{"vod_id":7,"vod_name":"A","vod_remarks":"HD","vod_pic":"https://img.example.com/a.jpg","vod_play_url":"1$https://cdn.example.com/7.m3u8"},{"vod_id":8,"vod_name":"B","vod_pic":"https://img.example.com/b.jpg","vod_play_url":"1$https://cdn.example.com/8.m3u8"},{"vod_id":9,"vod_name":"C","vod_pic":"https://img.example.com/c.jpg","vod_play_url":"1$https://cdn.example.com/9.m3u8"}]}"#
                    : #"{"list":[]}"#
            default:
                // `ac=list` / no action: categories, names and remarks — but no posters.
                body = #"{"class":[{"type_id":1,"type_name":"Movie"}],"list":[{"vod_id":7,"vod_name":"A","vod_remarks":"HD"},{"vod_id":8,"vod_name":"B"},{"vod_id":9,"vod_name":"C","vod_pic":"https://img.example.com/c.jpg"}]}"#
            }
        } else if path == "/cms-cat" {
            // 分类页的两种真实形态：认 `t` 的站给一页 14 条；不认 `t` 的站把 `t` 当 id，
            // 只回一条（`pagecount=1 total=1`）—— 那正是「分类页只显示一部片」的观感。
            status = 200
            let action = query.first(where: { $0.name == "ac" })?.value
            let category = query.first(where: { $0.name == "t" })?.value
            if action == "videolist" {
                let rows = (1...14).map { #"{"vod_id":"c\#($0)","vod_name":"C\#($0)","vod_pic":"https://img.example.com/c\#($0).jpg"}"# }
                switch category {
                case "1": body = #"{"pagecount":1,"list":[\#(rows.joined(separator: ","))]}"#
                case "bad": body = #"{"pagecount":1,"total":1,"list":[{"vod_id":"c1","vod_name":"C1"}]}"#
                default: body = #"{"pagecount":5924,"total":118476,"list":[\#(rows.joined(separator: ","))]}"#
                }
            } else {
                body = #"{"class":[{"type_id":1,"type_name":"Movie"}],"pagecount":1,"list":[{"vod_id":"c1","vod_name":"C1"}]}"#
            }
        } else if path == "/cms-ref" {
            // 校验来源页的采集站：没有 `Referer: <源站>/` 一律 403 —— 与线上那批站同一行为。
            if request.value(forHTTPHeaderField: "Referer") == "https://example.com/" {
                status = 200; body = #"{"pagecount":2,"list":[{"vod_id":"r1","vod_name":"R"}]}"#
            } else {
                status = 403; body = "forbidden"
            }
        } else if path == "/bili" {
            status = 200; body = #"{"parse":0,"url":["480P","http://127.0.0.1:-1/proxy?do=bili&aid=123&cid=456&qn=32&type=mpd"]}"#
        } else if query.contains(where: { $0.name == "play" }) {
            status = 200
            body = path == "/parse" ? #"{"parse":1,"url":"https://example.com/watch/1"}"# : #"{"parse":0,"url":"https://example.com/video.m3u8","header":"{\"Referer\":\"https://example.com/\"}"}"#
        } else { status = 200; body = #"{"class":[{"type_id":1,"type_name":"Movie"}],"list":[{"vod_id":12,"vod_name":"Test"}],"pagecount":"3"}"# }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private func client() -> HTTPClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockProtocol.self]
    return HTTPClient(session: URLSession(configuration: config))
}
@Test func httpErrorsSurfaceStatus() async {
    await #expect(throws: (any Error).self) { try await client().get(URL(string: "https://example.com/failure")!) }
}
@Test func subscriptionUserAgentIsSentToPlaylist() async throws {
    let source = LiveSource(name: "Live", url: URL(string: "https://example.com/headers")!, headers: ["User-Agent": "Custom"])
    let channels = try await client().channels(source)
    #expect(channels.count == 1)
    #expect(channels[0].headers["User-Agent"] == "Custom")
}
@Test func standardCatalogAndPlaybackContract() async throws {
    let base = URL(string: "https://example.com/config.json")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/api","header":{"User-Agent":"SiteAgent"}},{"key":"b","type":4,"api":"/parse"}]}"#.utf8), origin: base)
    let api = CatalogClient(site: sub.sites[0], origin: base, http: client())
    let home = try await api.home()
    #expect(home.categories.first?.id == "1")
    #expect(home.videos.first?.id == "12")
    #expect(home.pageCount == 3)
    let episode = Episode(id: "1", name: "Episode", address: "opaque-value", flag: "A")
    let play = try await api.playback(episode)
    #expect(play.url.absoluteString == "https://example.com/video.m3u8")
    #expect(play.headers["Referer"] == "https://example.com/")
    #expect(play.headers["User-Agent"] == "SiteAgent")
    let parseAPI = CatalogClient(site: sub.sites[1], origin: base, http: client())
    await #expect(throws: (any Error).self) { try await parseAPI.playback(episode) }
}

/// 采集站的首页是 `ac=videolist`：**一条请求**就带齐封面、线路与页数。
///
/// 旧实现发的是不带 `ac` 的裸请求（等同 `ac=list`）：有名字、没封面、没线路，
/// 于是首页要再补一次 `ac=detail&ids=…` —— 那两个请求任何一个失败，首页就是一片灰。
/// `pagecount` 也只有 `videolist` 给，所以「共几页」在旧实现里永远是 1。
@Test func cmsHomeTakesEverythingFromOneVideolist() async throws {
    let base = URL(string: "https://example.com/config.json")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"cms","type":1,"api":"/cms"}]}"#.utf8), origin: base)
    let api = CatalogClient(site: sub.sites[0], origin: base, http: client())
    let home = try await api.home()
    #expect(home.videos.map(\.id) == ["7", "8", "9"])
    #expect(home.videos.map { $0.poster?.absoluteString } == ["https://img.example.com/a.jpg", "https://img.example.com/b.jpg", "https://img.example.com/c.jpg"])
    #expect(home.videos.first?.remarks == "HD")
    // 线路也一并到位：详情页不必再问一次。
    #expect(home.videos.first?.episodes.first?.address == "https://cdn.example.com/7.m3u8")
    #expect(home.pageCount == 3)
    // `videolist` 不带 `class`，分类栏靠并行的 `ac=list` 补上 —— 缺了它首页就是「有片没有分类」。
    #expect(home.categories.first?.id == "1")
    let recommended = try await api.recommendationPage().items
    #expect(recommended.map { $0.poster?.url.absoluteString } == ["https://img.example.com/a.jpg", "https://img.example.com/b.jpg", "https://img.example.com/c.jpg"])
}

/// 不认 `videolist` 的老站：退回「`ac=list` + 一次 `ac=detail` 补图」，行为与旧版一致。
///
/// 这条路径必须留着：采集站里老实现占多数，而 `videolist` 被拒时如果直接报错，
/// 一批本来好好的源会整片变黑。
@Test func cmsHomeFallsBackWhenVideolistIsRefused() async throws {
    let base = URL(string: "https://example.com/config.json")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"old","type":1,"api":"/cms-old"}]}"#.utf8), origin: base)
    let api = CatalogClient(site: sub.sites[0], origin: base, http: client())
    let home = try await api.home()
    #expect(home.videos.map(\.id) == ["7", "8", "9"])
    #expect(home.videos.map { $0.poster?.absoluteString }
            == ["https://img.example.com/a.jpg", "https://img.example.com/b.jpg", "https://img.example.com/c.jpg"])
    #expect(home.categories.first?.id == "1")
}

@Test func pluginStyleDetailMayOmitRequestedID() async throws {
    let base = URL(string: "https://example.com/config.json")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/missing-id"}]}"#.utf8), origin: base)
    let api = CatalogClient(site: sub.sites[0], origin: base, http: client())
    let detail = try await api.detail("requested-id")
    #expect(detail.id == "requested-id")
    #expect(detail.episodes.first?.address == "opaque-episode")
    #expect(detail.episodes.first?.videoID == "requested-id")
}

@Test func playbackSurfacesProviderLoginReason() async throws {
    let base = URL(string: "https://example.com/config.json")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/login"}]}"#.utf8), origin: base)
    let api = CatalogClient(site: sub.sites[0], origin: base, http: client())
    do {
        _ = try await api.playback(Episode(id: "a", name: "Episode", address: "id", flag: ""))
        Issue.record("Expected the provider's login error")
    } catch { #expect(error.localizedDescription == "未扫码登录无法观看") }
}

@Test func qualitySelectionResolvesTheChosenEntry() async throws {
    let base = URL(string: "https://example.com/config.json")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/qualities"}]}"#.utf8), origin: base)
    let api = CatalogClient(site: sub.sites[0], origin: base, http: client())
    let plan = try await api.preparePlayback(Episode(id: "a", name: "Episode", address: "id", flag: ""))
    #expect(plan.choices.map(\.name) == ["480P", "360P"])
    let channel = try await api.resolvePlayback(plan, choice: plan.choices[1])
    #expect(channel.url.absoluteString == "https://example.com/360.mp4")
}

@Test func playResultSubtitleFilesReachThePlayer() async throws {
    let base = URL(string: "https://example.com/config.json")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/subs"}]}"#.utf8), origin: base)
    let api = CatalogClient(site: sub.sites[0], origin: base, http: client())
    let channel = try await api.playback(Episode(id: "a", name: "Episode", address: "id", flag: ""))
    #expect(channel.url.absoluteString == "https://cdn.example.com/film.mkv")
    #expect(channel.subtitles == [ExternalSubtitle(name: "film.chs.srt", url: URL(string: "http://127.0.0.1:9978/proxy?do=quark&type=sub")!,
                                                   language: "chs", format: "application/x-subrip")])
    // Saved channels leave them out: a plugin's addresses last one session.
    let saved = try JSONDecoder().decode(Channel.self, from: JSONEncoder().encode(channel))
    #expect(saved.subtitles.isEmpty && saved.url == channel.url)
}

@Test func resolvedMediaWithStaleParseFlagCanPlay() async throws {
    let base = URL(string: "https://example.com/config.json")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/api"}]}"#.utf8), origin: base)
    let api = CatalogClient(site: sub.sites[0], origin: base, http: client())
    let choice = PlaybackChoice(id: 0, name: "Video", address: "https://cdn.example.com/video.mp4?token=1")
    let plan = PlaybackPlan(choices: [choice], headers: [:], group: "", requiresWebDetection: true)
    let channel = try await api.resolvePlayback(plan, choice: choice)
    #expect(channel.url.absoluteString == choice.address)
    #expect(!CatalogClient.isDirectMedia("https://example.com/watch?url=video.mp4"))
}

@Test func screenplayActionMetadataDoesNotHideVideoDetails() throws {
    let origin = URL(string: "https://example.com/")!
    let data = Data(#"{"vod_id":"play/ch4lua32z","vod_name":"我不是大师","action":"编剧姓名","vod_play_from":"默认","vod_play_url":"第1集$https://example.com/1.mp4"}"#.utf8)
    let json = try JSONDecoder().decode([String: JSONValue].self, from: data)
    let video = try #require(Video(json: json, origin: origin))
    #expect(video.name == "我不是大师")
    #expect(video.episodes.count == 1)
}

private actor SearchCollector {
    var results: [SearchSourceResult] = []
    func append(_ result: SearchSourceResult) { results.append(result) }
}

@Test func globalSearchPreservesSourceIdentityAndIsolatesFailure() async throws {
    let base = URL(string: "https://example.com/config")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"first","type":1,"api":"/api"},{"key":"second","type":4,"api":"/api"},{"key":"broken","type":4,"api":"/failure"},{"key":"disabled","type":1,"api":"/api","searchable":0},{"key":"excluded","type":1,"api":"/api","searchable":2},{"key":"unsupported","type":0,"api":"/api"}]}"#.utf8), origin: base)
    let collector = SearchCollector()
    await GlobalSearch.search(sites: sub.sites, origin: base, jarURL: nil, query: "  movie  ", http: client(), concurrency: 2) {
        await collector.append($0)
    }
    let results = await collector.results
    #expect(Set(results.map(\.id)) == ["first", "second", "broken"])
    #expect(results.filter { $0.page?.videos.first?.id == "12" }.count == 2)
    #expect(results.first { $0.id == "broken" }?.error != nil)
    #expect(results.first { $0.id == "first" }?.page?.pageCount == 3)
}

@Test func blankAndCancelledSearchDoNotPublishResults() async throws {
    let base = URL(string: "https://example.com/config")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/api"}]}"#.utf8), origin: base)
    let collector = SearchCollector()
    await GlobalSearch.search(sites: sub.sites, origin: base, jarURL: nil, query: " \n ", http: client()) { await collector.append($0) }
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        await GlobalSearch.search(sites: sub.sites, origin: base, jarURL: nil, query: "movie", http: client()) { await collector.append($0) }
    }
    await task.value
    #expect(await collector.results.isEmpty)
}

@Test @MainActor func searchSessionRetainsResultsAndReusesRecentSearch() async throws {
    let base = URL(string: "https://example.com/config")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/api"}]}"#.utf8), origin: base)
    let model = SearchModel(http: client())
    model.search("first", config: sub)
    await model.task?.value
    #expect(model.videoCount == 1)
    #expect(!model.busy)
    #expect(model.activeSources.isEmpty)
    model.search("second", config: sub)
    await model.task?.value
    model.search("first", config: sub)
    #expect(!model.busy) // Cached results are available synchronously.
    #expect(model.keyword == "first")
    #expect(model.videoCount == 1)
    #expect(model.completed == model.total)
    model.reset()
    #expect(model.results.isEmpty)
    #expect(model.keyword.isEmpty)
}

@Test @MainActor func searchDoesNotAskBuiltInsTheViewerHid() async throws {
    let base = URL(string: "https://example.com/config")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/api"}]}"#.utf8), origin: base).withCloudFiles()
    let model = SearchModel(http: client())
    model.search("movie", config: sub) { $0.isBuiltIn }
    // The search page shows a chip for each built-in it is still asking; hidden ones get none.
    #expect(model.busy)
    #expect(model.asking == ["a"])
    await model.task?.value
    #expect(model.results.map(\.id) == ["a"])
    model.reset()
    #expect(model.asking.isEmpty)
}

@Test @MainActor func replacingSearchDiscardsOldCompletion() async throws {
    let base = URL(string: "https://example.com/config")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/api"},{"key":"b","type":4,"api":"/api"}]}"#.utf8), origin: base)
    let model = SearchModel(http: client())
    model.search("old", config: sub)
    let old = model.task
    model.search("new", config: sub)
    #expect(old?.isCancelled == true)
    await old?.value
    await model.task?.value
    #expect(model.keyword == "new")
    #expect(model.results.count == 2)
    #expect(model.completed == 2)
    #expect(!model.busy)
}

@Test @MainActor func stoppedSearchResumesAndSubscriptionChangeInvalidatesCache() async throws {
    let base = URL(string: "https://example.com/config")!
    let json = Data(#"{"sites":[{"key":"a","type":4,"api":"/api"}]}"#.utf8)
    let sub = try Subscription.parse(json, origin: base)
    let model = SearchModel(http: client())
    model.search("first", config: sub)
    let stopped = model.task
    model.stop()
    await stopped?.value
    #expect(model.stopped)
    #expect(model.results.isEmpty)
    model.resume(config: sub)
    await model.task?.value
    #expect(model.videoCount == 1)
    let changed = try Subscription.parse(json, origin: URL(string: "https://other.example/config")!)
    model.search("first", config: changed)
    #expect(model.busy)
    await model.task?.value
    #expect(model.videoCount == 1)
}

@Test @MainActor func recommendationCacheSurvivesNavigationAndFailedRefresh() async throws {
    let base = URL(string: "https://example.com/config")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/api","indexs":1}]}"#.utf8), origin: base)
    let http = client()
    let api = CatalogClient(site: sub.sites[0], origin: base, http: http)
    let model = RecommendationModel()
    await model.load(client: api, subscriptionDate: sub.importedAt)
    #expect(model.items.count == 1)
    #expect(model.items[0].destination == .search("Test"))
    let offlineConfig = URLSessionConfiguration.ephemeral
    offlineConfig.protocolClasses = [OfflineProtocol.self]
    let offline = CatalogClient(site: sub.sites[0], origin: base, http: HTTPClient(session: URLSession(configuration: offlineConfig)))
    await model.load(client: offline, subscriptionDate: sub.importedAt)
    #expect(model.items.count == 1)
    #expect(model.error == nil)
    #expect(!model.busy)
    await model.load(client: offline, subscriptionDate: sub.importedAt, force: true)
    #expect(model.error != nil)
    #expect(model.items.count == 1)
    #expect(!model.busy)
    model.reset()
    #expect(model.items.isEmpty)
}

/// #810: the store rebuilds the subscription (and resets this model) when the built-in sources arrive after launch. The
/// load in flight is dropped, so the count the view keys its load on must move, or Watch Now stays blank.
@Test @MainActor func recommendationResetDroppingALoadAsksForAnotherLoad() async throws {
    let base = URL(string: "https://example.com/config")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/api","indexs":1}]}"#.utf8), origin: base)
    let api = CatalogClient(site: sub.sites[0], origin: base, http: client())
    let model = RecommendationModel()
    // Nothing to drop: a view that resets an empty model for want of a source doesn't load again.
    model.reset()
    #expect(model.resets == 0)
    let load = Task { await model.load(client: api, subscriptionDate: sub.importedAt) }
    for _ in 0..<100 where !model.busy { await Task.yield() }
    #expect(model.busy)
    model.reset()
    await load.value
    #expect(model.resets == 1)
    #expect(model.items.isEmpty && model.site == nil && !model.busy)
    // A shown home dropped by a reset counts too.
    await model.load(client: api, subscriptionDate: sub.importedAt)
    #expect(model.items.count == 1)
    model.reset()
    #expect(model.resets == 2)
    model.reset()
    #expect(model.resets == 2)
}

private final class OfflineProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

@Test func subscriptionUsesTVBoxIdentityWithChineseDomain() async throws {
    let url = try WebAddress.resolve("http://肥猫.net/subscription")
    let config = try await client().subscription(url)
    #expect(config.sites.first?.key == "中文")
    #expect(config.origin.host == "xn--z7x900a.net")
    let (browserData, _) = try await client().get(url)
    #expect(String(decoding: browserData, as: UTF8.self).contains("Landing page"))
}
@Test func pythonSpidersBehindShortLinksRunAsPython() async throws {
    guard case .subscription(let config) = try await client().subscriptionImport(URL(string: "https://example.com/short-links")!) else {
        Issue.record("not a subscription"); return
    }
    let runtimes = Dictionary(uniqueKeysWithValues: config.sites.map { ($0.key, $0.runtime) })
    #expect(runtimes == ["py": .python, "jar": .jar, "gone": .jar, "csp": .jar])
    // What was learned survives the saved copy, and a merge that renames a clashing key.
    let saved = try JSONDecoder().decode(Subscription.self, from: JSONEncoder().encode(config))
    #expect(saved.sites[0].runtime == .python)
    var other = Site(key: "py", name: "py", type: 3, api: "https://example.org/s/py", raw: [:])
    other.detectedRuntime = .python
    let merged = try #require(Subscription.merge([saved, Subscription(origin: URL(string: "https://example.org/tv.json")!, importedAt: Date(), sites: [other], lives: [], raw: [:])]))
    #expect(merged.sites.filter { $0.runtime == .python }.count == 2)
}
@Test func onlyBaseSpiderScriptsSniffAsPython() {
    #expect(Site.sniffedRuntime(Data("from base.spider import Spider\n".utf8)) == .python)
    #expect(Site.sniffedRuntime(Data("\t from base import spider\n".utf8)) == .python)
    #expect(Site.sniffedRuntime(Data("# from base.spider import Spider\n".utf8)) == nil)
    #expect(Site.sniffedRuntime(Data("var rule = {}; // from base.spider import".utf8)) == nil)
    #expect(Site.sniffedRuntime(Data("<html>from base.spider import Spider</html>".utf8)) == nil)
}

@MainActor @Test func searchResultsLoadLaterPagesUntilASourceRunsDry() async throws {
    let base = URL(string: "https://example.com/config.json")!
    let config = try Subscription.parse(Data(#"{"sites":[{"key":"p","type":4,"api":"/paged"}]}"#.utf8), origin: base)
    let model = SearchModel(http: client())
    func settle() async throws { for _ in 0..<200 where model.busy || model.loadingMore { try await Task.sleep(for: .milliseconds(20)) } }
    model.search("x", config: config)
    try await settle()
    #expect(model.videos(for: "p").map(\.id) == ["p1a", "p1b"])
    #expect(model.canLoadMore(nil))
    model.loadMore(nil, config: config); try await settle()
    model.loadMore("p", config: config); try await settle()
    #expect(model.videos(for: "p").map(\.id) == ["p1a", "p1b", "p2a", "p2b", "p3a", "p3b"])
    // Page 4 repeats page 3: nothing new, so the source is done although it claimed four pages.
    model.loadMore("p", config: config); try await settle()
    #expect(!model.canLoadMore("p") && model.batches.count == 2)
}

@Test @MainActor func leavingCompletedSearchCancelsPaginationWithoutLosingItsCursor() async throws {
    let base = URL(string: "https://example.com/config")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"p","type":4,"api":"/paged"}]}"#.utf8), origin: base)
    let model = SearchModel(http: client())
    model.search("x", config: sub)
    await model.task?.value
    model.loadMore(nil, config: sub)
    let oldPage = model.moreTask
    model.suspend()
    await oldPage?.value
    #expect(!model.loadingMore)
    #expect(model.batches.isEmpty)
    #expect(model.canLoadMore(nil))
    model.loadMore(nil, config: sub)
    #expect(model.moreTask == nil) // A hidden scroll sentinel cannot restart pagination.
    model.resumeSuspended(config: sub)
    model.loadMore(nil, config: sub)
    await model.moreTask?.value
    #expect(model.batches.map(\.page) == [2])
}

@Test @MainActor func repeatedPageCancellationPreservesSearchForReturn() async throws {
    let base = URL(string: "https://example.com/config")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/api"},{"key":"b","type":4,"api":"/api"}]}"#.utf8), origin: base)
    let model = SearchModel(http: client())
    model.search("x", config: sub)
    let old = model.task
    model.suspend() // Search page disappears.
    model.suspend() // New page starts its request.
    await old?.value
    #expect(model.suspended && !model.busy)
    model.resumeSuspended(config: sub)
    await model.task?.value
    #expect(model.completed == 2 && model.results.count == 2)
}

@Test @MainActor func explicitStopDoesNotResumeWhenEnteringDetail() async throws {
    let base = URL(string: "https://example.com/config")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/api"}]}"#.utf8), origin: base)
    let model = SearchModel(http: client())
    model.search("x", config: sub)
    let old = model.task
    model.stop()
    await old?.value
    model.suspend()
    model.resumeSuspended(config: sub)
    #expect(!model.busy && model.results.isEmpty)
}

@Test @MainActor func confirmedNewSearchCancelsOldPaginationAndKeepsNewPageState() async throws {
    let base = URL(string: "https://example.com/config")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"p","type":4,"api":"/paged"}]}"#.utf8), origin: base)
    let model = SearchModel(http: client())
    model.search("old", config: sub)
    await model.task?.value
    model.loadMore(nil, config: sub)
    let oldPage = model.moreTask
    // Draft edits leave the confirmed search alone until the user submits.
    model.draft = "new"
    #expect(model.keyword == "old" && oldPage?.isCancelled == false)
    model.search(model.draft, config: sub)
    #expect(oldPage?.isCancelled == true)
    #expect(!model.loadingMore && model.batches.isEmpty)
    await model.task?.value
    model.loadMore(nil, config: sub)
    let newPage = model.moreTask
    await oldPage?.value
    await newPage?.value
    #expect(model.keyword == "new")
    #expect(model.batches.map(\.page) == [2])
    #expect(model.videos(for: "p").map(\.id) == ["p1a", "p1b", "p2a", "p2b"])
    #expect(!model.loadingMore)
}

@Test @MainActor func searchFollowsTheViewersSourceOrderWhileItIsOn() async throws {
    let suite = "order." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let base = URL(string: "https://example.com/config")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/api"},{"key":"b","type":4,"api":"/api"},{"key":"c","type":4,"api":"/api"}]}"#.utf8), origin: base)
    let order = SourceOrder(defaults: defaults)
    order.save([sub.sites[2], sub.sites[0]], origin: base)
    let model = SearchModel(http: client())
    model.order = order
    model.search("movie", config: sub)
    await model.task?.value
    #expect(model.matches.map(\.site.key) == ["a", "b", "c"]) // Off: the automatic order.
    order.enabled = true
    model.search("film", config: sub)
    await model.task?.value
    #expect(model.matches.map(\.site.key) == ["c", "a", "b"]) // Sources the order doesn't list yet follow.
    order.enabled = false
    model.search("film", config: sub)
    #expect(model.matches.map(\.site.key) == ["a", "b", "c"]) // Cached results are listed in the current order.
}

/// 分类页必须是一整页，不能是一条。
///
/// ⛔ 旧实现发 `ac=detail&t=<type_id>` —— 那是「按 id 取详情」的写法。新一代采集站照字面执行，
/// 于是分类页永远只剩那一条、`pagecount` 永远 1，「翻不动」就是这么来的。
/// 正确写法是 `ac=videolist&t=…&pg=…`。
@Test func aCategoryPageIsAPageNotASingleTitle() async throws {
    let base = URL(string: "https://example.com/config.json")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"cat","type":1,"api":"/cms-cat"}]}"#.utf8), origin: base)
    let api = CatalogClient(site: sub.sites[0], origin: base, http: client())
    let page = try await api.list(category: "1", query: "", page: 1)
    #expect(page.videos.count == 14)
    #expect(page.pageCount == 1)
}

/// 站不认 `t` 时退回全量列表：分类不精确，也强过一页一条。
@Test func anUnknownCategoryFallsBackToTheFullList() async throws {
    let base = URL(string: "https://example.com/config.json")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"cat","type":1,"api":"/cms-cat"}]}"#.utf8), origin: base)
    let api = CatalogClient(site: sub.sites[0], origin: base, http: client())
    let page = try await api.list(category: "bad", query: "", page: 1)
    // 「按 id 查到一条」被识别出来 → 换成全量：条数与页数都回到真实规模。
    #expect(page.videos.count == 14)
    #expect(page.pageCount == 5924)
}

/// 采集站请求要带来源页：一批站校验 Referer，缺了它回 403 或空列表。
///
/// 这不是「多加一个头」的洁癖：公共中继时代一直带着 `Referer: <源站>/`，
/// 拆掉之后映匣发的是裸请求，于是同一批站在浏览器里好好的、在 App 里 403。
@Test func cmsRequestsCarryARefererFromTheSourceItself() async throws {
    let base = URL(string: "https://example.com/config.json")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"ref","type":1,"api":"/cms-ref"}]}"#.utf8), origin: base)
    let api = CatalogClient(site: sub.sites[0], origin: base, http: client())
    let home = try await api.home()
    #expect(home.videos.map(\.id) == ["r1"])
    #expect(home.pageCount == 2)
}

/// 源自己写的 `header` 优先：自带了 Referer 时不能再被改写。
@Test func aSourcesOwnRefererIsNotOverridden() async throws {
    let base = URL(string: "https://example.com/config.json")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"ref","type":1,"api":"/cms-ref","header":{"Referer":"https://other.example/"}}]}"#.utf8), origin: base)
    let api = CatalogClient(site: sub.sites[0], origin: base, http: client())
    // 带上的是源自己的 Referer，所以这个 mock（只认 example.com）应当拒绝它。
    await #expect(throws: (any Error).self) { _ = try await api.home() }
}

/// Holds requests open so activity can be inspected independently of response timing.
private final class SearchActivityProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

@Test @MainActor func searchActivityIncludesNonPluginSourcesFromEverySubscriptionAndClearsOnStop() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SearchActivityProtocol.self]
    let model = SearchModel(http: HTTPClient(session: URLSession(configuration: configuration)))
    let first = try Subscription.parse(Data(#"{"sites":[{"key":"activity-first","type":4,"api":"/api"}]}"#.utf8),
                                       origin: URL(string: "https://activity-first.example/sub.json")!)
    let second = try Subscription.parse(Data(#"{"sites":[{"key":"activity-second","type":4,"api":"/api"}]}"#.utf8),
                                        origin: URL(string: "https://activity-second.example/sub.json")!)
    let merged = try #require(Subscription.merge([first, second]))
    model.search("activity", config: merged)
    let task = model.task
    for _ in 0..<100 where model.activeSources.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(Set(model.activeSources.map(\.id)) == ["activity-first", "activity-second"])
    #expect(Set(model.activeSources.map { $0.site.origin(or: merged.origin) }) == [first.origin, second.origin])
    #expect(model.completed == 0)
    model.stop()
    #expect(model.activeSources.isEmpty)
    await task?.value
    #expect(model.activeSources.isEmpty && model.results.isEmpty)
}

@Test @MainActor func searchListsTheSourcesStillWaitingUntilTheyStart() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SearchActivityProtocol.self]
    let model = SearchModel(http: HTTPClient(session: URLSession(configuration: configuration)))
    let sites = (1...6).map { #"{"key":"waiting-\#($0)","type":4,"api":"/api"}"# }.joined(separator: ",")
    let config = try Subscription.parse(Data(#"{"sites":[\#(sites)]}"#.utf8), origin: URL(string: "https://waiting.example/sub.json")!)
    model.search("waiting", config: config)
    let task = model.task
    for _ in 0..<100 where model.activeSources.count < 4 { try await Task.sleep(for: .milliseconds(20)) }
    // Four at a time; the other two wait in line, and none is in both lists.
    #expect(model.activeSources.count == 4)
    #expect(model.waitingSources.count == 2)
    #expect(Set(model.activeSources.map(\.id)).union(model.waitingSources.map(\.id)) == Set(config.sites.map(\.id)))
    model.stop()
    #expect(model.waitingSources.isEmpty && model.activeSources.isEmpty)
    await task?.value
}
