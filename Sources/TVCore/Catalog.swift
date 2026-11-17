import Foundation

public struct Category: Identifiable, Sendable {
    public let id: String
    public let name: String
    /// The source's filters for this category (TVBox `filters`), such as 类型, 地区 or 年份, in its order.
    public let filters: [CategoryFilter]
    public init(id: String, name: String, filters: [CategoryFilter] = []) {
        self.id = id; self.name = name; self.filters = filters
    }
}

/// One of a category's filters: a group of values (TVBox `{key, name, init, value: [{n, v}]}`) of which the chosen one
/// goes to the source's category request in `extend`, under `key`.
public struct CategoryFilter: Identifiable, Hashable, Sendable {
    public struct Option: Hashable, Sendable {
        public let name: String
        public let value: String
        public init(name: String, value: String) { self.name = name; self.value = value }
    }
    public let key: String
    public let name: String
    public let options: [Option]
    /// The value chosen before the viewer picks one: the source's `init`, else its first option's.
    public let initial: String
    public var id: String { key }

    public init(key: String, name: String, options: [Option], initial: String? = nil) {
        self.key = key; self.name = name; self.options = options
        self.initial = initial ?? options.first?.value ?? ""
    }

    init?(json: [String: JSONValue]) {
        guard let key = json["key"]?.string, !key.isEmpty else { return nil }
        var seen = Set<String>()
        let options = (json["value"]?.array ?? []).compactMap { entry -> Option? in
            guard let fields = entry.object, let value = fields["v"]?.string ?? fields["value"]?.string else { return nil }
            let name = (fields["n"]?.string ?? fields["name"]?.string).map(HTMLText.name) ?? value
            return seen.insert(value).inserted ? Option(name: name.isEmpty ? value : name, value: value) : nil
        }
        guard options.count > 1 else { return nil }
        let name = json["name"]?.string.map(HTMLText.name) ?? key
        let initial = json["init"]?.string
        // Some sources (CatPaw's 玩偶) list only real values and let the filter's own name (全部剧情, 全部地区) stand for
        // "all". Opening on the first value then narrowed every page to 喜剧 + 中国大陆 + 2026 + A and showed nothing. As
        // in other TVBox clients, a filter without `init` sends nothing until the viewer picks; the empty choice is
        // offered under the filter's name.
        if initial == nil, !options.contains(where: { $0.value.isEmpty }) {
            self.init(key: key, name: name, options: [Option(name: name, value: "")] + options, initial: "")
        } else {
            self.init(key: key, name: name, options: options, initial: initial)
        }
    }

    /// A home answer's `filters`: an object of category id to filter list, sometimes sent as JSON text.
    static func all(_ value: JSONValue?) -> [String: [CategoryFilter]] {
        var value = value
        if let text = value?.string, let data = text.data(using: .utf8) { value = try? JSONDecoder().decode(JSONValue.self, from: data) }
        return (value?.object ?? [:]).compactMapValues { list in
            let filters = (list.array ?? []).compactMap { $0.object.flatMap(CategoryFilter.init(json:)) }
            return filters.isEmpty ? nil : filters
        }
    }

    /// The choices a category opens with: each filter's initial value, as other TVBox clients send them.
    public static func initialChoices(_ filters: [CategoryFilter]) -> [String: String] {
        Dictionary(filters.map { ($0.key, $0.initial) }, uniquingKeysWith: { first, _ in first })
    }
}
public struct Episode: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    public let address: String
    public let flag: String
    public let videoID: String?
    /// Optional per-episode metadata shown by skins that render a rich episode row
    /// (the bilibili drawer: published date / duration / view count / danmaku count).
    /// Source-dependent: the generic TVBox catalog parser does not populate these, so they are
    /// nil unless a source's detail response or a cross-source match (e.g. TMDB) fills them.
    /// Renderers must guard each field and never fabricate a value when it is nil.
    public let duration: TimeInterval?
    public let published: Date?
    public let views: Int?
    public let danmaku: Int?
    public init(id: String, name: String, address: String, flag: String, videoID: String? = nil,
                duration: TimeInterval? = nil, published: Date? = nil, views: Int? = nil, danmaku: Int? = nil) {
        self.id = id; self.name = name; self.address = address; self.flag = flag; self.videoID = videoID
        self.duration = duration; self.published = published; self.views = views; self.danmaku = danmaku
    }
}
/// A person a source credits for a video (`vod_director`, `vod_actor`). A TVBox credit link
/// (`[a=cr:{"id":"…","name":"…"}/]name[/a]`, FongMi's markup) also names a category of the source that lists their
/// works; the page opens it as a listing, as it opens a drive's folder.
public struct VideoCredit: Hashable, Sendable, Codable {
    public enum Role: String, Hashable, Sendable, Codable { case director, actor }
    public let name: String
    public let role: Role
    /// The category the link opens; nil for a plain name.
    public let category: String?
    public init(name: String, role: Role, category: String? = nil) { self.name = name; self.role = role; self.category = category }

    /// The names in a credit field, in order. Plain names are separated by commas, slashes or 、; a field of Chinese
    /// names may separate them with spaces only.
    static func parse(_ field: String, role: Role) -> [VideoCredit] {
        var credits: [VideoCredit] = [], seen = Set<String>()
        func add(_ name: String, _ category: String?) {
            let name = HTMLText.name(name)
            guard !name.isEmpty, seen.insert(name).inserted else { return }
            credits.append(VideoCredit(name: name, role: role, category: category))
        }
        func plain(_ text: Substring) {
            let text = HTMLText.plain(String(text))
            for part in text.split(whereSeparator: { ",，/、|｜;；\n".contains($0) }) {
                let words = part.split(separator: " ")
                // "张三 李四" lists two people; "Tom Hanks" is one.
                if words.count > 1, !part.contains(where: { $0.isASCII && $0.isLetter }) { words.forEach { add(String($0), nil) } } else { add(String(part), nil) }
            }
        }
        var rest = field[...]
        while let match = rest.firstMatch(of: /\[a=cr:(\{.*?\})\/\](.*?)\[\/a\]/) {
            plain(rest[..<match.range.lowerBound])
            let fields = (try? JSONDecoder().decode([String: JSONValue].self, from: Data(match.1.utf8))) ?? [:]
            let name = String(match.2).isEmpty ? fields["name"]?.string ?? "" : String(match.2)
            add(name, fields["id"]?.string.flatMap { $0.isEmpty ? nil : $0 })
            rest = rest[match.range.upperBound...]
        }
        plain(rest)
        return credits
    }
}

public struct Video: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    public let poster: URL?
    public let posterHeaders: [String: String]
    public let year: String?
    public let remarks: String
    public let synopsis: String
    public let episodes: [Episode]
    /// The source's category and genre tags (type_name, vod_class, vod_tag), comma-separated; nil when it gave none.
    public let category: String?
    /// A plugin setting listed among titles (`action`, e.g. FTY's "LoginShow" or "quarkClean"): TVBox runs
    /// `Spider.action` for it instead of opening details, which the plugin can't answer for such an item.
    public let action: String?
    /// Directors, then actors, as the source credits them; nil when it gave none.
    public let credits: [VideoCredit]?
    public init(id: String, name: String, poster: URL? = nil, posterHeaders: [String: String] = [:], year: String? = nil,
                remarks: String = "", synopsis: String = "", episodes: [Episode] = [], category: String? = nil, action: String? = nil,
                credits: [VideoCredit]? = nil) {
        self.id = id; self.name = name; self.poster = poster; self.posterHeaders = posterHeaders
        self.year = year; self.remarks = remarks; self.synopsis = synopsis; self.episodes = episodes; self.category = category
        self.action = action; self.credits = credits
    }
    /// A folder of a drive source (AList, 小雅 and other cloud-drive spiders tag it `vod_tag: "folder"`). As in
    /// TVBox it opens as a listing of its own (the category request with the folder's id), not as details.
    public var isFolder: Bool { category?.split(separator: ",").contains("folder") ?? false }
    /// This video with `poster` when it has none of its own. Many sources leave `vod_pic` out of the detail
    /// answer although their list or search answer had it, and history, favorites and Now Playing keep what plays.
    public func keepingPoster(_ poster: URL?, headers: [String: String]? = nil) -> Video {
        guard self.poster == nil, let poster else { return self }
        return Video(id: id, name: name, poster: poster, posterHeaders: headers ?? [:], year: year,
                     remarks: remarks, synopsis: synopsis, episodes: episodes, category: category, action: action, credits: credits)
    }
    public init?(json: [String: JSONValue], origin: URL) {
        guard let id = json["vod_id"]?.string, !id.isEmpty else { return nil }
        self.id = id; name = json["vod_name"]?.string.map(HTMLText.name).flatMap { $0.isEmpty ? nil : $0 } ?? id
        year = json["vod_year"]?.string.flatMap { $0.count == 4 && $0.allSatisfy(\.isNumber) ? $0 : nil }
        let artwork = json["vod_pic"]?.string.flatMap { PosterResource(address: $0, origin: origin) }
        poster = artwork?.url; posterHeaders = artwork?.headers ?? [:]
        remarks = HTMLText.plain(json["vod_remarks"]?.string ?? "")
        synopsis = HTMLText.synopsis(json["vod_content"]?.string ?? "")
        let labels = ["type_name", "vod_class", "vod_tag"].compactMap { json[$0]?.string.map(HTMLText.name) }.filter { !$0.isEmpty }
        category = labels.isEmpty ? nil : labels.joined(separator: ",")
        action = json["action"]?.string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let credited = VideoCredit.parse(json["vod_director"]?.string ?? "", role: .director) + VideoCredit.parse(json["vod_actor"]?.string ?? "", role: .actor)
        credits = credited.isEmpty ? nil : credited
        let flags = (json["vod_play_from"]?.string ?? "").components(separatedBy: "$$$")
        var groups: [[Episode]] = []
        for (groupIndex, group) in (json["vod_play_url"]?.string ?? "").components(separatedBy: "$$$").enumerated() {
            let flag = groupIndex < flags.count ? flags[groupIndex] : ""
            var episodes: [Episode] = []
            for (index, item) in group.components(separatedBy: "#").enumerated() where !item.isEmpty {
                let parts = item.split(separator: "$", maxSplits: 1).map(String.init)
                episodes.append(Episode(id: "\(groupIndex)-\(index)", name: parts.count == 2 ? HTMLText.name(parts[0]) : L10n.text("Play"), address: parts.last ?? item, flag: flag, videoID: id))
            }
            groups.append(episodes)
        }
        // Collection APIs often list a web player group (".../share/<id>") before the m3u8 group of the
        // same episodes, so groups of direct media come first and are what playback starts with.
        let playable = groups.map { $0.first.map { CatalogClient.isDirectMedia($0.address) } ?? false }
        self.episodes = groups.indices.sorted { playable[$0] != playable[$1] ? playable[$0] : $0 < $1 }.flatMap { groups[$0] }
    }
}
/// Plugins pass through site HTML, often entity-escaped twice ("&amp;nbsp;"), so decode until stable before stripping tags.
enum HTMLText {
    private static let entity = try! NSRegularExpression(pattern: "&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});?")
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "hellip": "\u{2026}", "mdash": "\u{2014}", "ndash": "\u{2013}", "middot": "\u{00B7}",
    ]

    static func plain(_ html: String) -> String {
        var text = html
        for _ in 0..<3 {
            let decoded = decodeEntities(text)
            if decoded == text { break }
            text = decoded
        }
        return text
            .replacingOccurrences(of: "<br\\s*/?>|</p>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t\u{00A0}\u{3000}]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\n\\s*", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A synopsis (`vod_content`): `plain`, minus the lines that hold nothing but a 线路 label ("线路1", "播放线路")
    /// or a quality word ("蓝光", "1080P"), which aggregator pages leave behind as layout. Everything else is the
    /// provider's own text and stays as written, links and promotion included: a plugin's synopsis can carry the
    /// address the app opens (the Wex config center, #360), and a plot can mention 地址 or 弹幕.
    static func synopsis(_ html: String) -> String {
        let text = plain(html)
        return text.split(separator: "\n").filter { line in
            line.count > 12 || layoutLabel.firstMatch(in: String(line), range: NSRange(line.startIndex..., in: line)) == nil
        }.joined(separator: "\n")
    }
    /// A whole line that is only a 线路 label or a quality word. Anchored at both ends, so plot text never matches.
    private static let layoutLabel = try! NSRegularExpression(
        pattern: "^\\s*(?:(?:播放|高清|蓝光|超清|备用|高速)?\\s*线路[一二三四五六七八九十0-9]*[:：]?|超清|高清|蓝光|标清|流畅|4k|1080p|720p|2160p)\\s*$",
        options: [.caseInsensitive])

    /// A title or name: entities decoded ("太阳&amp;月亮" is "太阳&月亮"), spaces tidied, and nothing else touched,
    /// so a name that reads like markup after decoding ("&lt;3") keeps its text.
    static func name(_ text: String) -> String {
        var text = text
        for _ in 0..<3 {
            let decoded = decodeEntities(text)
            if decoded == text { break }
            text = decoded
        }
        return text.replacingOccurrences(of: "[\\s\u{00A0}\u{3000}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let source = text as NSString
        var output = "", cursor = 0
        for match in entity.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let body = source.substring(with: match.range(at: 1))
            let scalar: UInt32? = body.hasPrefix("#x") || body.hasPrefix("#X") ? UInt32(body.dropFirst(2), radix: 16)
                : body.hasPrefix("#") ? UInt32(body.dropFirst()) : nil
            guard let replacement = scalar.flatMap(Unicode.Scalar.init).map({ String(Character($0)) }) ?? named[body.lowercased()]
            else { continue }
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)) + replacement
            cursor = match.range.location + match.range.length
        }
        return output + source.substring(from: cursor)
    }
}

public struct CatalogPage: Sendable {
    public let categories: [Category]
    public let videos: [Video]
    public let pageCount: Int
    public init(json: [String: JSONValue], origin: URL) {
        let filters = CategoryFilter.all(json["filters"])
        categories = (json["class"]?.array ?? []).compactMap {
            guard let v = $0.object, let id = v["type_id"]?.string else { return nil }
            return Category(id: id, name: v["type_name"]?.string.map(HTMLText.name) ?? id, filters: filters[id] ?? [])
        }
        videos = (json["list"]?.array ?? []).compactMap { $0.object.flatMap { Video(json: $0, origin: origin) } }
        pageCount = max(1, json["pagecount"]?.int ?? 1)
    }
}

public struct CatalogClient: Sendable {
    public let site: Site
    public let origin: URL
    public let http: HTTPClient
    public let jarURL: URL?
    /// The subscription's parse services, used when a source hands back a web player page.
    public private(set) var parses: [ParseService] = []
    public private(set) var sniffAds: [String] = []
    public private(set) var sniffRules: [SniffRule] = []
    public private(set) var sniffer: (any WebSniffing)?
    /// A merged source runs against its own subscription, whatever `origin` and `jarURL` the caller has.
    public init(site: Site, origin: URL, http: HTTPClient = HTTPClient(), jarURL: URL? = nil) {
        self.site = site; self.origin = site.origin(or: origin); self.http = http; self.jarURL = site.spider(or: jarURL)
    }
    /// Names the source in an error report: its key, its spider or API, and its type.
    public var reportContext: String { "source=\(site.key) api=\(site.api) type=\(site.type)" }
    public func with(parses: [ParseService]) -> CatalogClient {
        var client = self; client.parses = parses; return client
    }
    public func applying(_ subscription: Subscription) -> CatalogClient {
        var client = with(parses: subscription.parseServices)
        client.sniffAds = subscription.sniffAds
        client.sniffRules = subscription.sniffRules
        return client
    }
    public func with(sniffer: any WebSniffing) -> CatalogClient {
        var client = self
        client.sniffer = sniffer
        return client
    }
    public func requestURL(_ params: [String: String]) throws -> URL {
        guard site.native else { throw TVError.unsupported(L10n.text("%@: this source cannot run in this version.", site.compatibility)) }
        let endpoint = try WebAddress.resolve(site.api, relativeTo: origin)
        guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: true) else { throw TVError.invalidURL }
        var values = params
        if let ext = site.raw["ext"] {
            if let text = ext.string { values["extend"] = text }
            else if let data = try? JSONEncoder().encode(ext) { values["extend"] = String(data: data, encoding: .utf8) }
        }
        parts.queryItems = (parts.queryItems ?? []).filter { values[$0.name] == nil } + values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // A query item keeps `+`, which servers read as a space: escape it in the filters (base64 has `+`).
        parts.percentEncodedQueryItems = parts.percentEncodedQueryItems?.map { item in
            params[item.name] == nil || !["ext", "f"].contains(item.name) ? item
                : URLQueryItem(name: item.name, value: item.value?.replacingOccurrences(of: "+", with: "%2B"))
        }
        guard let url = parts.url else { throw TVError.invalidURL }
        return url
    }
    /// Every answer, or failure, feeds the source's `SourceHealth`.
    private func request(_ params: [String: String]) async throws -> [String: JSONValue] {
        let started = ContinuousClock.now
        do {
            let json = try await perform(params)
            await SourceHealth.shared.record(site, origin: origin, seconds: started.duration(to: .now).seconds, error: nil)
            return json
        } catch {
            if !Task.isCancelled {
                await SourceHealth.shared.record(site, origin: origin, seconds: started.duration(to: .now).seconds, error: error)
            }
            throw error
        }
    }
    private func perform(_ params: [String: String]) async throws -> [String: JSONValue] {
        if site.isCloudFiles { return try await CloudFilesSource.request(site, params: params) }
        // Yingxia's own sources run in-process on every platform, the Mac's included.
        if site.runsInProcess {
            return try await ScriptRuntime.shared.request(site: site, scriptURL: site.scriptURL(origin: origin), params: params, http: http, origin: origin)
        }
        // A WeBox plugin only runs with the WeBox prelude, which the in-process QuickJS runtime installs
        // and the Mac's Node script host does not. Without this, every `.webox.js` source works on
        // iPhone, iPad and Apple TV and fails on the Mac with "WeBox is not defined".
        if ScriptRuntime.available, let script = try? site.scriptURL(origin: origin),
           ScriptRuntime.runsWebBox(site, script) {
            return try await ScriptRuntime.shared.request(site: site, scriptURL: script, params: params, http: http, origin: origin)
        }
        // A script that ships inside the app (`assets://…`) has no HTTP address for the Mac's Node host
        // to fetch, and the in-process runtime reads the bundle directly — same reason as WeBox above.
        if site.api.hasPrefix("assets://"), ScriptRuntime.available,
           let script = try? site.scriptURL(origin: origin) {
            return try await ScriptRuntime.shared.request(site: site, scriptURL: script, params: params, http: http, origin: origin)
        }
        // A bundled lite port runs first, in-process on QuickJS everywhere; when it fails or answers
        // with nothing usable, the source's JAR spider answers instead.
        if let script = site.liteScript, ScriptRuntime.available, await LiteFallback.shared.prefersPort(site.key) {
            let jarReady = !site.isBuiltIn && EmbeddedJarHost.available && (try? site.pluginURL(origin: origin, fallback: jarURL)) != nil
            let reason: String
            do {
                #if DEBUG
                // TVBOX_LITE_FAIL=<source key> fails that source's port, to exercise the JAR fallback.
                if ProcessInfo.processInfo.environment["TVBOX_LITE_FAIL"] == site.key { throw TVError.unsupported("forced port failure") }
                #endif
                let json = try await ScriptRuntime.shared.request(site: site, scriptURL: script, params: params, http: http, origin: origin)
                guard jarReady, let problem = LiteSites.unusable(json, params: params) else { return json }
                reason = problem
            } catch {
                if !jarReady || error is CancellationError { throw error }
                reason = error.localizedDescription
            }
            await LiteFallback.shared.record(site.key)
            Diagnostics.shared.record(.warning, "lite.fallback", "\(site.key) \(site.api): port failed (\(reason)); using the JAR")
        }
        #if os(macOS)
        if site.runtime == .javascript || site.runtime == .python {
            return try await LocalJarHost.shared.request(site: site, jarURL: site.scriptURL(origin: origin), params: params, http: http, scriptOrigin: origin)
        }
        #else
        #if os(iOS) || os(tvOS)
        if site.raw["catPawOpen"] != nil, site.runtime == .javascript {
            return try await EmbeddedNodeHost.shared.request(site: site, bundleURL: site.scriptURL(origin: origin), params: params, http: http, origin: origin)
        }
        #endif
        if site.runtime == .javascript {
            return try await ScriptRuntime.shared.request(site: site, scriptURL: site.scriptURL(origin: origin), params: params, http: http, origin: origin)
        }
        #if os(iOS) || os(tvOS)
        if site.runtime == .python {
            return try await EmbeddedPythonHost.shared.request(site: site, scriptURL: site.scriptURL(origin: origin), params: params, http: http, origin: origin)
        }
        #endif
        #endif
        if site.runtime == .jar, var plugin = try site.pluginURL(origin: origin, fallback: jarURL) {
            func run(_ archive: URL) async throws -> [String: JSONValue] {
                let progress = PluginPreparation(site: site, origin: origin)
                defer { progress.finish() }
                return try await EmbeddedJarHost.shared.request(site: site, jarURL: archive, params: params, http: http, configurationOrigin: origin, progress: progress)
            }
            // Only sources on the shared spider borrow; a source's own archive keeps its class version.
            let ownArchive = site.raw["jar"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let className = String(site.api.dropFirst("csp_".count))
            let locator = PluginLocator.shared
            if !ownArchive {
                if let known = await locator.known(source: site.key) { plugin = known }
                else if let known = await locator.known(className) { plugin = known }
            }
            do { return try await run(plugin) }
            catch let missing as PluginClassMissing {
                // Another archive in the subscription may define the class this one lacks.
                guard let other = await locator.archive(containing: missing.className, excluding: plugin, http: http) else { throw missing }
                return try await run(other)
            } catch let crashed as PluginIncompatible where !ownArchive {
                // A merged subscription can pair a source's configuration with the wrong version of
                // its spider; another archive's version may be the one the source was written for.
                for other in await locator.alternatives(containing: className, excluding: [plugin], limit: 3, http: http) {
                    if let result = try? await run(other) {
                        await locator.remember(source: site.key, archive: other)
                        return result
                    }
                }
                throw crashed
            }
        }
        let data = try await fetchCMS(requestURL(params))
        do { return try JSONDecoder().decode([String: JSONValue].self, from: data) }
        catch {
            // Dead or bot-protected sites answer with a web page; say that rather than a decoding error.
            let start = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
            if start.contains("<html") || start.contains("<!doctype") || start.contains("<head") {
                throw TVError.unsupported(L10n.text("The source returned a web page instead of data. It may be offline or blocking apps."))
            }
            throw error
        }
    }

    /// 采集站的一次 GET：带来源页与 Accept，https 不通时退 http。
    ///
    /// 这两件事此前只在已经拆掉的公共中继里做（`/opt/cmsrelay/cmsrelay.py` 的 `_fetch`），
    /// 映匣本体直接发裸请求，于是：
    ///   · **少一个 Referer** —— 采集站普遍校验来源页，缺了它一批站回 403 或空列表，
    ///     而同一个站在浏览器里是好的，看上去就像「源坏了」；
    ///   · **https 失败不回落** —— 有的站只在一侧证书完整，https 握手被中间设备打断、
    ///     http 却正常，于是这台设备上永远是 TLS 错误。
    ///
    /// 退到 http 是明文：采集站不带账号与凭证，这里换的是「能不能拿到公开的片单」，
    /// 不是隐私。源自己定义的 `header` 一律优先，自带的 Referer/Accept 不会被覆盖。
    private func fetchCMS(_ url: URL) async throws -> Data {
        let headers = cmsRequestHeaders()
        do {
            return try await http.get(url, headers: headers).0
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            // 服务器已经明确回过一个状态码（403/404/5xx）时不再换协议：那不会因为 http 而变好，
            // 只是白花一次请求。要回退的是「连接都没建立」的那些。
            if let tv = error as? TVError, case .http = tv { throw error }
            guard url.scheme?.lowercased() == "https",
                  var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw error }
            parts.scheme = "http"
            guard let fallback = parts.url else { throw error }
            Diagnostics.shared.record(.info, "catalog",
                "\(reportContext) https refused (\(error.localizedDescription)); retrying over http")
            return try await http.get(fallback, headers: headers).0
        }
    }

    /// 采集站请求的头：源自己的优先，缺的补 Referer / Accept。
    private func cmsRequestHeaders() -> [String: String] {
        var headers = site.raw["header"]?.object?.compactMapValues(\.string) ?? [:]
        func has(_ name: String) -> Bool {
            headers.keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        if !has("Referer") {
            // 与 `_fetch` 同一个取值：源站自身的根地址。`api` 是合并后的绝对地址时优先用它，
            // 因为 `origin` 可能是另一个 feed 的（`Subscription.merge` 只保留第一份）。
            if let api = URL(string: site.api), let scheme = api.scheme, let host = api.host() {
                headers["Referer"] = "\(scheme)://\(host)/"
            } else if let scheme = origin.scheme, let host = origin.host() {
                headers["Referer"] = "\(scheme)://\(host)/"
            }
        }
        if !has("Accept") { headers["Accept"] = "application/json, text/plain, */*" }
        return headers
    }
    public func home() async throws -> CatalogPage {
        CatalogPage(json: try await homeJSON(), origin: origin)
    }
    /// The source's home answer.
    ///
    /// **采集站要 `ac=videolist`。** 不带 `ac` 时（旧实现的写法）服务器按 `ac=list` 回答：
    /// 有名字和备注，但**没有 `vod_pic`、没有 `vod_play_url`** —— 海报于是要再补一次
    /// `ac=detail&ids=…`，而那次补图只要有一台站不支持批量 ids 就整页没图。
    /// `ac=videolist` 一条请求就把封面、线路、`pagecount`、`total` 全带回来
    /// （实测 `ffzy1.tv`：`ac=list` 20 条 0 张图 / `ac=videolist` 20 条 20 张图）。
    ///
    /// 老站不认 `videolist` 时回落到原来的两步走，行为不变。
    private func homeJSON() async throws -> [String: JSONValue] {
        if site.type == 1 {
            // 两条并行：`videolist` 给内容和封面，`list` 给分类栏（`class`）。
            // 采集站的 `videolist` 常常不带 `class` —— 只发它，首页就变成「有片没有分类」。
            // 并行发是划算的：`list` 的响应只有名字，体量是 `videolist` 的几十分之一。
            async let library = try? request(["ac": "videolist", "pg": "1"])
            async let taxonomy = try? request(["ac": "list", "pg": "1"])
            let (primary, meta) = await (library, taxonomy)
            if var json = primary, json["list"]?.array?.isEmpty == false {
                if json["class"]?.array?.isEmpty != false,
                   let classes = meta?["class"], classes.array?.isEmpty == false {
                    json["class"] = classes
                }
                return json
            }
            if Task.isCancelled { throw CancellationError() }
        }
        let json = try await request(site.type == 4 ? ["filter": "true"] : [:])
        guard site.type == 1, let list = json["list"]?.array else { return json }
        let ids = Self.idsMissingPosters(list)
        guard !ids.isEmpty else { return json }
        let details: [String: JSONValue]
        do { details = try await request(["ac": "detail", "ids": ids.joined(separator: ",")]) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            Diagnostics.shared.record(.warning, "catalog", "\(reportContext) home posters: \(error.localizedDescription)")
            return json
        }
        var result = json
        result["list"] = .array(Self.fillingPosters(list, from: details["list"]?.array ?? []))
        return result
    }
    static func idsMissingPosters(_ list: [JSONValue]) -> [String] {
        list.compactMap { entry in
            guard let fields = entry.object, (fields["vod_pic"]?.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return fields["vod_id"]?.string
        }
    }
    /// `list` with each entry's missing `vod_pic` taken from the detail entry with the same `vod_id`.
    static func fillingPosters(_ list: [JSONValue], from details: [JSONValue]) -> [JSONValue] {
        var posters: [String: JSONValue] = [:]
        for entry in details {
            guard let fields = entry.object, let id = fields["vod_id"]?.string,
                  let pic = fields["vod_pic"], !(pic.string ?? "").isEmpty else { continue }
            posters[id] = pic
        }
        return list.map { entry in
            guard var fields = entry.object, (fields["vod_pic"]?.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
                  let id = fields["vod_id"]?.string, let pic = posters[id] else { return entry }
            fields["vod_pic"] = pic
            return .object(fields)
        }
    }
    public func recommendations() async throws -> [Recommendation] { try await recommendationPage().items }
    /// The home answer as recommendations plus the source's categories, from one plugin call.
    public func recommendationPage() async throws -> (items: [Recommendation], categories: [Category]) {
        let json = try await homeJSON()
        var seen = Set<String>()
        let items = (json["list"]?.array ?? []).compactMap { entry in
            entry.object.flatMap { Recommendation(json: $0, origin: origin, isIndex: (site.raw["indexs"]?.int ?? 0) == 1) }
        }.filter { seen.insert($0.id).inserted }
        return (items, CatalogPage(json: json, origin: origin).categories)
    }
    /// A search (`query`) or one page of a category, narrowed by the category's filter `choices` (key to value).
    ///
    /// ⛔ **分类列表不能用 `ac=detail&t=…`。** 那是「按 id 取详情」的写法：新一代采集站照字面
    /// 执行，把 `t` 当 `vod_id`，于是分类页只剩 **1 条**（实测 `pagecount=1 total=1`），
    /// 翻页无从谈起、海报与线路也一起没了 —— 观感就是「这个源只有一部片」。
    /// 分类页的正确写法是 `ac=videolist&t=<type_id>&pg=<n>`（与 TVBox 一致）。
    ///
    /// 遇到不认 `t` 的站（返回「按 id 查到的那一条」）时**退回全量列表**：分类不精确，
    /// 总好过一页一条。判定看的是「有效」，不是「空」—— 空列表也可能是一个真的空分类。
    public func list(category: String?, query: String, page: Int, filters choices: [String: String] = [:]) async throws -> CatalogPage {
        var params = ["pg": String(page)]
        if !query.isEmpty { params["wd"] = query; params["quick"] = "false" }
        else if site.type == 1 {
            var strict = params
            strict["ac"] = "videolist"
            if let category { strict["t"] = category }
            strict.merge(Self.filterParameters(choices, siteType: 1)) { _, new in new }
            if let asked = try? await cmsPage(strict), Self.looksLikeACategory(asked) { return asked }
            // `try?` 会把取消一起吞掉：被取消时不该继续发第二条请求。
            if Task.isCancelled { throw CancellationError() }
            var loose = params
            loose["ac"] = "videolist"
            loose.merge(Self.filterParameters(choices, siteType: 1)) { _, new in new }
            do { return try await cmsPage(loose) }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                // `videolist` 整个不认的老站：退回原来的 `ac=detail&t=`，它在那类站上是列表。
                var legacy = params
                legacy["ac"] = "detail"
                if let category { legacy["t"] = category }
                legacy.merge(Self.filterParameters(choices, siteType: 1)) { _, new in new }
                return try await cmsPage(legacy)
            }
        } else {
            params["ac"] = "detail"; params["t"] = category
            params.merge(Self.filterParameters(choices, siteType: site.type)) { _, new in new }
        }
        return try await cmsPage(params)
    }

    private func cmsPage(_ params: [String: String]) async throws -> CatalogPage {
        CatalogPage(json: try await request(params), origin: origin)
    }

    /// 这一页像是「某一分类的一页」，而不是「按 id 查到的一条」。
    ///
    /// 采集站把 `t` 当 id 时会同时给出 `pagecount=1 / total=1 / list.count=1` —— 三个一起成立
    /// 才判失败。只判 `count == 1` 会误伤真的只有一个条目的分类。
    static func looksLikeACategory(_ page: CatalogPage) -> Bool {
        page.pageCount > 1 || page.videos.count > 1
    }

    /// A category's filter choices as the source reads them, leaving out empty ("全部") values: as other TVBox clients
    /// send them, base64 JSON in `ext` for an HTTP spider (type 4) and JSON in `f` for a CMS API; a plugin host gets the
    /// JSON in `filters` and hands the spider its `extend` map.
    static func filterParameters(_ choices: [String: String], siteType: Int) -> [String: String] {
        let extend = choices.filter { !$0.value.isEmpty }
        guard !extend.isEmpty, let data = try? JSONSerialization.data(withJSONObject: extend, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return [:] }
        switch siteType {
        case 4: return ["ext": data.base64EncodedString()]
        case 0, 1: return ["f": String(decoding: data, as: UTF8.self)]
        default: return ["filters": String(decoding: data, as: UTF8.self)]
        }
    }
    public func detail(_ id: String, cached: Bool = false) async throws -> Video {
        let scope = EpisodeSkipSettings.scope(origin: origin, source: site.sourceKey, video: id)
        if cached, let data = MediaCache.shared.data(for: "detail", kind: .catalog, scope: scope),
           let video = try? JSONDecoder().decode(Video.self, from: data), video.id == id { return video }
        var json = try await request(["ac": "detail", "ids": id])
        if let list = json["list"]?.array {
            json["list"] = .array(list.map { item in
                guard var fields = item.object else { return item }
                if fields["vod_id"] == nil { fields["vod_id"] = .string(id) }
                return .object(fields)
            })
        }
        let result = CatalogPage(json: json, origin: origin)
        guard let video = result.videos.first else { throw TVError.unsupported(L10n.text("The API did not return video details.")) }
        return video
    }
    /// Runs a listed plugin setting (`Video.action`) with the source's JAR spider, as TVBox does with
    /// `Spider.action`: what the plugin then shows (its own window, its toasts, the pages it opens).
    public func runAction(_ action: String) async throws -> PluginScreen {
        guard site.type == 3, site.runtime == .jar else { throw TVError.unsupported(L10n.text("This plugin setting only works in Android TVBox.")) }
        // Settings are not browsing: they stay out of the source's health (`request`).
        let result = try await perform(["spiderAction": action])
        if let failure = result["errMsg"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !failure.isEmpty {
            throw TVError.unsupported(failure)
        }
        return PluginScreen(json: result)
    }
    /// Sends the viewer's input to the plugin window a setting opened, and returns what it shows then.
    public func pluginWindow(_ event: PluginEvent) async throws -> PluginScreen {
        PluginScreen(json: try await perform(["spiderUI": event.json]))
    }
    /// Asks a source to resolve the cheap half of an episode's playback ahead of the tap.
    ///
    /// For 看剧AI that is the episode's line list: one request, no allowance spent, and it is what
    /// `play` needs before it can even name a signed address. Doing it while the viewer reads the
    /// detail page takes that round-trip off the moment they press play.
    ///
    /// Only for sources that declare `prefetch` (`Site.prefetchesLineList`); any other script would
    /// just spend a script round-trip answering "not implemented". A prefetch that fails is not an
    /// error: the play request then does the work itself.
    public func prefetchPlayback(_ episode: Episode) async {
        guard site.prefetchesLineList else { return }
        _ = try? await perform(["warm": episode.address, "flag": episode.flag])
    }

    public func playback(_ episode: Episode) async throws -> Channel {
        let plan = try await preparePlayback(episode)
        return try await resolvePlayback(plan, choice: plan.choices[0])
    }

    static func playbackClick(site: Site, result: [String: JSONValue]?) -> String {
        let siteClick = site.raw["click"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !siteClick.isEmpty { return siteClick }
        return result?["click"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public func preparePlayback(_ episode: Episode, forDownload: Bool = false) async throws -> PlaybackPlan {
        var headers = site.raw["header"]?.object?.compactMapValues(\.string) ?? [:]
        if site.type == 4 || site.type == 3 {
            if !forDownload { CatPawDanmaku.remember(self) }
            var params = ["play": episode.address, "flag": episode.flag]
            if site.type == 3 { params["detailID"] = episode.videoID }
            let result = try await request(params)
            if let message = Self.providerError(result) { throw TVError.unsupported(message) }
            if let fields = result["header"]?.object { headers.merge(fields.compactMapValues(\.string)) { _, new in new } }
            else if let text = result["header"]?.string, let data = text.data(using: .utf8),
                    let fields = try? JSONDecoder().decode([String: String].self, from: data) { headers.merge(fields) { _, new in new } }
            if let ua = result["UA"]?.string ?? result["ua"]?.string, !ua.isEmpty { headers["User-Agent"] = ua }
            let prefix = result["playUrl"]?.string ?? ""
            let click = Self.playbackClick(site: site, result: result)
            if prefix.hasPrefix("json:") || prefix.hasPrefix("parse:") {
                let choices = PlaybackChoice.parse(result["url"], prefix: "", fallbackName: episode.name)
                guard !choices.isEmpty else { throw TVError.unsupported(L10n.text("The API did not return a single playback URL.")) }
                return PlaybackPlan(choices: choices, headers: headers, group: episode.flag, requiresWebDetection: true, click: click, webPlayURL: prefix)
            }
            var choices = PlaybackChoice.parse(result["url"], prefix: prefix, fallbackName: episode.name)
            guard !choices.isEmpty else { throw TVError.unsupported(L10n.text("The API did not return a single playback URL.")) }
            let duration = result["duration"]?.double.flatMap { $0 > 0 ? $0 : nil }
            let danmaku = result["danmaku"]?.string
            // Separate video and audio files (DASH), which the app describes as HLS for the player.
            if let dash = result["dash"]?.object {
                do {
                    guard let master = try await DashStreams.stream(dash, headers: headers, danmaku: danmaku, session: http.session) else {
                        throw TVError.unsupported(L10n.text("The API did not return a single playback URL."))
                    }
                    return PlaybackPlan(choices: [PlaybackChoice(id: 0, name: episode.name, address: master.absoluteString)], headers: headers,
                                        group: episode.flag, requiresWebDetection: false, subtitles: ExternalSubtitle.parse(result["subs"]),
                                        skips: PlaybackSkip.parse(result["skips"]))
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    throw error
                }
            }
            // An encrypted MP4 with its key, which the app decrypts as it plays.
            if let key = result["decryptKey"]?.string, !key.isEmpty {
                do {
                    let remote = try WebAddress.resolve(choices[0].address)
                    let backups = (result["backupUrls"]?.array ?? []).compactMap { $0.string.flatMap { try? WebAddress.resolve($0) } }
                    let address: URL
                    if forDownload {
                        address = try await HongguoMedia.shared.prepare(url: remote, backups: backups, key: key, headers: headers, http: http)
                    } else {
                        address = try HongguoStreams.register(url: remote, backups: backups, key: key, headers: headers, http: http)
                    }
                    choices = [PlaybackChoice(id: 0, name: episode.name, address: address.absoluteString)]
                    headers = [:]
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    throw TVError.unsupported(L10n.text("This Hongguo video could not be prepared for playback. Please try again."))
                }
            } else if danmaku != nil, let url = try? WebAddress.resolve(choices[0].address) {
                DanmakuSource.register(url, feed: danmaku, duration: duration)
            }
            return PlaybackPlan(choices: choices, headers: headers, group: episode.flag,
                                requiresWebDetection: (result["parse"]?.int ?? 0) != 0 || (result["jx"]?.int ?? 0) != 0 || !prefix.isEmpty, click: click, webPlayURL: "",
                                subtitles: ExternalSubtitle.parse(result["subs"]), skips: PlaybackSkip.parse(result["skips"]))
        }
        let prefix = site.raw["playUrl"]?.string ?? ""
        let click = Self.playbackClick(site: site, result: nil)
        if prefix.hasPrefix("json:") || prefix.hasPrefix("parse:") {
            return PlaybackPlan(choices: [PlaybackChoice(id: 0, name: episode.name, address: episode.address)], headers: headers, group: episode.flag, requiresWebDetection: true, click: click, webPlayURL: prefix)
        }
        return PlaybackPlan(choices: [PlaybackChoice(id: 0, name: episode.name, address: prefix + episode.address)], headers: headers, group: episode.flag, requiresWebDetection: !prefix.isEmpty, click: click, webPlayURL: "")
    }

    /// Playback routing, in TVBox order, with one extra step Yingxia already had.
    ///
    /// A direct media address plays immediately. `json:` asks that one JSON service and
    /// stops, even when the answer is empty. `parse:` runs the named parser: type 0 sniffs
    /// `parser + page`, type 1 asks that JSON service, type 2 and 3 fail, and type 4 races
    /// every type 0 and type 1 parser. A flag list on a parser limits that type to the
    /// parsers that contain the episode flag; if none contain it, that type uses them all.
    /// Any other page runs the HTML and JSON fast path first, then sniffs the page.
    /// The 15 second clock belongs to the sniffer, not to this function.
    ///
    /// A client sniffer wins. Otherwise the process-wide `WebSniff.current` is used.
    /// Neither exists on Apple TV, which throws the existing web-detection error.
    /// This does not call a spider `isVideoFormat`.
    public func resolvePlayback(_ plan: PlaybackPlan, choice: PlaybackChoice) async throws -> Channel {
        // Addresses the app made itself from the play result: a keyed MP4 or DASH described as HLS.
        if let url = URL(string: choice.address), url.scheme == HongguoStreams.scheme || url.scheme == DashStreams.scheme {
            return Channel(name: choice.name, group: plan.group, url: url, headers: url.scheme == DashStreams.scheme ? plan.headers : [:],
                           subtitles: plan.subtitles, skips: plan.skips)
        }
        // A drive in Cloud Files hands over its stream, which carries the CDN's headers itself.
        if site.isCloudFiles, let url = URL(string: choice.address), url.scheme == CloudStreams.scheme {
            return Channel(name: choice.name, group: plan.group, url: url, headers: [:])
        }
        // 一条线**自己**像是网页时也要走嗅探，即使这个源整体没声明 `playUrl`。
        //
        // 内置包 `parses` 与 `playUrl` 都是 0 条，而 26 条线的地址就是云播页/平台页
        // （`feifan` / `xlyun` / `youku` / `qiyi` …）。以前它们被当成直链交给 AVPlayer，
        // 结果是「转圈到超时」；现在它们走同一条网页嗅探链路 —— 那是这些页面本来的打开方式。
        if !(plan.requiresWebDetection || choice.looksLikePage) || Self.isDirectMedia(choice.address) {
            return try await playResolved(plan, choice: choice)
        }
        let playURL = plan.webPlayURL
        if playURL.hasPrefix("json:") {
            let service = String(playURL.dropFirst("json:".count))
            if let found = await WebPlayback.askJSON(service: service, page: choice.address, headers: plan.headers, http: http) {
                return Channel(name: choice.name, group: plan.group, url: found.url, headers: found.headers)
            }
            throw Self.webDetectionError
        }
        if playURL.hasPrefix("parse:") {
            let name = String(playURL.dropFirst("parse:".count))
            guard let item = parses.first(where: { $0.name == name }) else { throw Self.webDetectionError }
            switch item.type {
            case 0:
                return try await sniff(plan, choice: choice, target: item.url + choice.address, headers: item.headers.isEmpty ? plan.headers : item.headers, click: plan.click)
            case 1:
                let headers = item.headers.isEmpty ? plan.headers : item.headers
                if let found = await WebPlayback.askJSON(service: item.url, page: choice.address, headers: headers, http: http) {
                    return Channel(name: choice.name, group: plan.group, url: found.url, headers: found.headers)
                }
                throw Self.webDetectionError
            case 4:
                if let found = await superParse(plan, page: choice.address) {
                    return Channel(name: choice.name, group: plan.group, url: found.url, headers: found.headers)
                }
                throw Self.webDetectionError
            default:
                throw Self.webDetectionError
            }
        }
        if let found = await WebPlayback.resolve(page: choice.address, headers: plan.headers, parses: parses, http: http) {
            return Channel(name: choice.name, group: plan.group, url: found.url, headers: found.headers)
        }
        return try await sniff(plan, choice: choice, target: choice.address, headers: plan.headers, click: plan.click)
    }

    /// A magnet is not an address: join the swarm, then play what it holds.
    ///
    /// An MP4 plays from the bridge's Range endpoint as it streams; anything else (MKV, AVI, TS…) goes
    /// through the repackager on a source that reads arbitrary slices from the same bridge, exactly as a
    /// downloaded file of that kind would. BitTorrent is not available on iPhone, iPad or Apple TV, where
    /// `TorrentBridge.available` is false and this throws a message that says so.
    private func playTorrent(_ magnet: String, name: String, group: String) async throws -> Channel {
        guard TorrentBridge.available else {
            throw TVError.unsupported(L10n.text("Torrent playback needs the Mac app: iPhone, iPad and Apple TV have no Node process to spare."))
        }
        let torrent = try await TorrentBridge.shared.open(magnet)
        if torrent.direct {
            let url = try await TorrentBridge.shared.streamURL(torrent)
            return Channel(name: name, group: group, url: url)
        }
        guard torrent.isVideo else {
            throw TVError.unsupported(L10n.text("This torrent holds no video file."))
        }
        let url = try await TorrentBridge.shared.remuxURL(torrent)
        return Channel(name: name, group: group, url: url)
    }

    private static let webDetectionError = TVError.unsupported(L10n.text("This source requires web video detection or additional parsing. Only resolved media URLs are supported."))
    /// The sniffer ran and the 15 second clock ended with no playable address.
    private static let sniffTimeoutError = TVError.unsupported(L10n.text("Video detection timed out before a playable address appeared."))

    private func playResolved(_ plan: PlaybackPlan, choice: PlaybackChoice) async throws -> Channel {
        let address = Self.unwrapPluginProxy(choice.address)
        if address.lowercased().hasPrefix("magnet:") {
            return try await playTorrent(address, name: choice.name, group: plan.group)
        }
        if Self.isPluginProxy(address) {
            // A Bili JAR spider's proxy id: Yingxia's own Bilibili source plays the same video.
            if let id = Self.bilibiliProxyID(address), let bilibili = CloudSources.site(where: \.isBilibili) {
                let channel = try await CatalogClient(site: bilibili, origin: CloudSources.address, http: http)
                    .playback(Episode(id: id, name: choice.name, address: id, flag: plan.group))
                return Channel(name: choice.name, group: plan.group, url: channel.url, headers: channel.headers, subtitles: channel.subtitles, skips: plan.skips)
            }
            throw TVError.unsupported(L10n.text("This source needs a playback proxy that is not supported yet."))
        }
        return Channel(name: choice.name, group: plan.group, url: try WebAddress.resolve(address), headers: plan.headers, subtitles: plan.subtitles, skips: plan.skips)
    }

    /// `aid_cid[_ep]` from a Bili spider's proxy address (`…/proxy?do=bili&aid=…&cid=…&ep=…`).
    static func bilibiliProxyID(_ address: String) -> String? {
        let items = pluginProxyQuery(address)
        func parameter(_ name: String) -> String? { items.first(where: { $0.name == name })?.value.flatMap { UInt64($0) != nil ? $0 : nil } }
        guard items.first(where: { $0.name == "do" })?.value == "bili", let aid = parameter("aid"), let cid = parameter("cid") else { return nil }
        return [aid, cid, parameter("ep")].compactMap { $0 }.joined(separator: "_")
    }

    private func sniff(_ plan: PlaybackPlan, choice: PlaybackChoice, target: String, headers: [String: String], click: String) async throws -> Channel {
        let detect = !target.contains("player/?url=")
        guard let sniffer = sniffer ?? WebSniff.current else { throw Self.webDetectionError }
        guard let found = await sniffer.sniff(url: target, headers: headers, click: click, detect: detect, ads: sniffAds, rules: sniffRules) else {
            throw Self.sniffTimeoutError
        }
        if found.url.absoluteString.lowercased().hasPrefix("magnet:") {
            return try await playTorrent(found.url.absoluteString, name: choice.name, group: plan.group)
        }
        return Channel(name: choice.name, group: plan.group, url: found.url, headers: found.headers)
    }

    /// Every type 0 and type 1 parser races, a few at a time: a web parser is a hidden page and window,
    /// and a dead JSON service holds its slot until the HTTP timeout.
    private func superParse(_ plan: PlaybackPlan, page: String) async -> (url: URL, headers: [String: String])? {
        let json = Self.parsers(parses, type: 1, flag: plan.group)
        let webs = Self.parsers(parses, type: 0, flag: plan.group)
        let active = sniffer ?? WebSniff.current
        let http = self.http, ads = sniffAds, rules = sniffRules
        return await withTaskGroup(of: (web: Bool, found: (url: URL, headers: [String: String])?).self) { group in
            var pendingJSON = json.makeIterator(), pendingWebs = webs.makeIterator()
            func askNextJSON() {
                guard let item = pendingJSON.next() else { return }
                group.addTask { (false, await WebPlayback.askJSON(service: item.url, page: page, headers: item.headers, http: http)) }
            }
            func sniffNextWeb() {
                guard let active, let item = pendingWebs.next() else { return }
                let target = item.url + page
                group.addTask {
                    (true, await active.sniff(url: target, headers: item.headers, click: item.click, detect: !target.contains("player/?url="), ads: ads, rules: rules))
                }
            }
            for _ in 0..<Self.superParseJSONWidth { askNextJSON() }
            for _ in 0..<Self.superParseWebWidth { sniffNextWeb() }
            while let next = await group.next() {
                if let found = next.found { group.cancelAll(); return found }
                if next.web { sniffNextWeb() } else { askNextJSON() }
            }
            return nil
        }
    }
    static let superParseJSONWidth = 4
    static let superParseWebWidth = 2

    private static func parsers(_ items: [ParseService], type: Int, flag: String) -> [ParseService] {
        let typed = items.filter { $0.type == type }
        let flagged = typed.filter { $0.flags.contains(flag) }
        return flagged.isEmpty ? typed : flagged
    }
    static func isDirectMedia(_ address: String) -> Bool {
        guard let url = try? WebAddress.resolve(address) else { return false }
        return ["mp4", "m4v", "m3u8", "mp3", "m4a", "aac"].contains(url.pathExtension.lowercased())
    }
    static func providerError(_ result: [String: JSONValue]) -> String? {
        // Providers often supply the useful login/authorization reason beside an empty URL.
        guard result["url"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              result["url"]?.array?.isEmpty != false else { return nil }
        for key in ["errMsg", "msg", "message"] {
            if let message = result[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty { return message }
        }
        return nil
    }
    static func isPluginProxy(_ address: String) -> Bool {
        guard let marker = address.range(of: "/proxy?") else { return false }
        let authority = String(address[..<marker.lowerBound])
        for host in ["http://127.0.0.1", "http://localhost"] {
            if authority == host { return true }
            if authority.hasPrefix(host + ":"), let port = Int(authority.dropFirst(host.count + 1)), (-1...65535).contains(port) { return true }
        }
        return false
    }
    /// The query of a plugin proxy address, split by hand. Plugins don't always percent-encode the wrapped
    /// address (spaces, CJK, `|` headers, a bare `%`), and `URLComponents.percentEncodedQuery` traps on those.
    static func pluginProxyQuery(_ address: String) -> [URLQueryItem] {
        guard isPluginProxy(address), let marker = address.range(of: "/proxy?") else { return [] }
        func decode(_ text: Substring) -> String { String(text).removingPercentEncoding ?? String(text) }
        return address[marker.upperBound...].split(separator: "&", omittingEmptySubsequences: false).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return URLQueryItem(name: decode(parts[0]), value: parts.count > 1 ? decode(parts[1]) : nil)
        }
    }
    /// Plugins wrap HLS addresses in their own loopback proxy (`http://127.0.0.1:<port>/proxy?do=m3u8&url=...`).
    /// This app hosts no such proxy, and in `m3u8` mode the wrapped address is the real playlist.
    static func unwrapPluginProxy(_ address: String) -> String {
        let items = pluginProxyQuery(address)
        guard items.first(where: { $0.name == "do" })?.value == "m3u8",
              let inner = items.first(where: { $0.name == "url" })?.value, !inner.isEmpty else { return address }
        return inner
    }
}
