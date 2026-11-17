import Foundation

/// Where a merged source came from. Its relative addresses, `ext` and default spider resolve
/// against its own subscription, never against the first one in the list.
public struct SourceProvenance: Codable, Hashable, Sendable {
    public let origin: URL
    public let spider: URL?
    public init(origin: URL, spider: URL?) { self.origin = origin; self.spider = spider }
}

extension Site {
    /// The key the subscription gave this source. `key` differs only when a merge renamed a clash;
    /// plugins, history and per-source settings keep using this one.
    public var sourceKey: String { raw["key"]?.string ?? key }
    /// The address this source resolves against: its own subscription's, else `fallback`.
    public func origin(or fallback: URL) -> URL { provenance?.origin ?? fallback }
    /// The spider archive a JAR source without its own `jar` runs from.
    public func spider(or fallback: URL?) -> URL? { provenance.map(\.spider) ?? fallback }

    /// Two entries are one source when they run the same way once their addresses are resolved.
    /// An archive whose MD5 the subscription declares is known by it: mirrors of one subscription
    /// host the same spider at different addresses.
    func fingerprint(origin: URL, spider: URL?, spiderChecksum: String?) -> String {
        let resolved = runtime == .jar ? self.api : ((try? WebAddress.resolve(self.api, relativeTo: origin).absoluteString) ?? self.api)
        let api = Self.normalizedAddress(resolved)
        let archive: String
        if runtime != .jar {
            archive = ""
        } else if let jar = raw["jar"]?.string, !jar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            archive = Self.declaredChecksum(jar) ?? (try? pluginURL(origin: origin, fallback: spider))?.absoluteString ?? ""
        } else {
            archive = spiderChecksum ?? spider?.absoluteString ?? ""
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let ext = (try? pluginExtension(origin: origin)).flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        return [String(type), api, archive, ext].joined(separator: "\n")
    }

    /// The address bare of the differences that never change what a source offers.
    ///
    /// Collections publish the same CMS with and without its serialisation suffix — `…/provide/vod`,
    /// `…/provide/vod/`, `…/provide/vod/at/json/` — and the same is true of a trailing slash or the
    /// letter case of a scheme and host. Comparing those verbatim made one provider look like three,
    /// which is why importing overlapping bundles used to ask the same site three times. `/from/…`
    /// and the query string are kept: those do select a different library. Anything that is not an
    /// http(s) address (`csp_X`, `./api/x.py`) is already an identity and is left alone.
    static func normalizedAddress(_ address: String) -> String {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return text }
        parts.scheme = scheme
        parts.host = parts.host?.lowercased()
        if let port = parts.port, (scheme == "http" && port == 80) || (scheme == "https" && port == 443) { parts.port = nil }
        var path = parts.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        // Only a suffix: `/at/json` selects the serialisation, `/at/…/more` would be another path.
        if let mark = path.range(of: "/at/", options: .backwards), !path[mark.upperBound...].contains("/") {
            path = String(path[..<mark.lowerBound])
        }
        parts.percentEncodedPath = path.isEmpty ? "" : path
        return parts.string ?? text
    }

    /// The MD5 an archive address declares after `;md5;`, when it is a well-formed one.
    static func declaredChecksum(_ address: String) -> String? {
        let fields = address.components(separatedBy: ";md5;")
        guard fields.count > 1 else { return nil }
        let checksum = fields[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return checksum.count == 32 && checksum.allSatisfy(\.isHexDigit) ? "md5:" + checksum : nil
    }
}

extension Subscription {
    /// Several subscriptions shown as one, in the order given.
    ///
    /// Each source keeps its own subscription (`provenance`), so it resolves and runs as it did
    /// alone. A source an earlier subscription already offers, the same once resolved, appears
    /// once; repeats inside one subscription stay, as they always have. Unrelated sources often
    /// share a key across subscriptions, so a later one gets its subscription's tag on the key and
    /// keeps the original as `sourceKey`. Live playlists and parse services are joined without repeats.
    public static func merge(_ parts: [Subscription]) -> Subscription? {
        guard let first = parts.first else { return nil }
        var sites: [Site] = [], keys = Set<String>(), offered = Set<String>()
        var lives: [LiveSource] = [], liveURLs = Set<URL>()
        var parses: [JSONValue] = [], parseURLs = Set<String>()
        for part in parts {
            let provenance = SourceProvenance(origin: part.origin, spider: part.spiderURL)
            var own = Set<String>()
            for var site in part.sites {
                let fingerprint = site.fingerprint(origin: part.origin, spider: part.spiderURL, spiderChecksum: part.spiderChecksum)
                guard !offered.contains(fingerprint) else { continue }
                own.insert(fingerprint)
                if !keys.insert(site.key).inserted {
                    let renamed = site.key + "@" + part.tag
                    guard keys.insert(renamed).inserted else { continue }
                    site = Site(key: renamed, name: site.name, type: site.type, api: site.api, raw: site.raw, detectedRuntime: site.detectedRuntime)
                }
                site.provenance = provenance
                sites.append(site)
            }
            offered.formUnion(own)
            for live in part.lives where liveURLs.insert(live.url).inserted { lives.append(live) }
            for parse in part.raw["parses"]?.array ?? [] {
                guard let url = parse.object?["url"]?.string, parseURLs.insert(url).inserted else { continue }
                parses.append(parse)
            }
        }
        var raw = first.raw
        if !parses.isEmpty { raw["parses"] = .array(parses) }
        return Subscription(origin: first.origin, importedAt: parts.map(\.importedAt).max() ?? first.importedAt,
                            sites: sites, lives: lives, raw: raw)
    }

    /// The MD5 the subscription declares for its spider archive.
    var spiderChecksum: String? { raw["spider"]?.string.flatMap(Site.declaredChecksum) }

    /// Every source identity this subscription offers, resolved against its own origin. Import uses
    /// it to tell whether a file would add anything to what is already on screen.
    public var fingerprints: Set<String> {
        Set(sites.map { $0.fingerprint(origin: origin, spider: spiderURL, spiderChecksum: spiderChecksum) })
    }

    /// A short, stable tag for this subscription's address.
    var tag: String { String(PluginChecksum.sha256(Data(origin.absoluteString.utf8)).prefix(6)) }

    /// The subscriptions a directory (多仓) lists: `urls` as [{name, url}], or `storeHouse` as
    /// [{sourceName, sourceUrl}]. Nil when the document is not a directory.
    public static func directory(_ data: Data, origin: URL) -> [SubscriptionEntry]? {
        guard let raw = try? SubscriptionDocument.decode(data), raw["sites"] == nil, raw["lives"] == nil else { return nil }
        var seen = Set<String>()
        let entries = ((raw["urls"]?.array ?? []) + (raw["storeHouse"]?.array ?? [])).compactMap { item -> SubscriptionEntry? in
            guard let fields = item.object, let text = (fields["url"] ?? fields["sourceUrl"])?.string,
                  let url = try? WebAddress.resolve(text, relativeTo: origin), seen.insert(url.absoluteString).inserted else { return nil }
            return SubscriptionEntry(address: url.absoluteString, name: (fields["name"] ?? fields["sourceName"])?.string ?? "", enabled: false)
        }
        return entries.isEmpty ? nil : entries
    }
}

/// A subscription the viewer added. Any number can be on; the app shows them merged, in list order.
public struct SubscriptionEntry: Codable, Hashable, Identifiable, Sendable {
    public var address: String
    public var name: String
    public var enabled: Bool
    // [mi3s] 二开：线路默认路由 + 所属观看环境。两处均为新增存储属性，Swift 无法用 extension 加存储属性，
    // 因此这是本文件唯一的二开侵入点；解码全部走 decodeIfPresent，上游旧数据一律回落默认值。
    /// How this subscription's sources reach their upstream by default. Individual sources may
    /// override it; `.auto` lets the app follow connectivity.
    public var routing: SourceRoute
    /// The environment (sandbox) this subscription belongs to. `nil` means it predates environments
    /// and therefore belongs to the default environment, so an upgrade never hides a viewer's feeds.
    public var environmentID: UUID?
    public var id: String { address }
    public init(address: String, name: String = "", enabled: Bool = true, routing: SourceRoute = .auto,
                environmentID: UUID? = nil) {
        self.address = address; self.name = name; self.enabled = enabled; self.routing = routing
        self.environmentID = environmentID
    }

    private enum CodingKeys: String, CodingKey { case address, name, enabled, routing, environmentID }

    /// A list saved by a build without per-subscription routing decodes as `.auto`, so an upgrade
    /// keeps every subscription exactly as it behaved before.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        address = try c.decode(String.self, forKey: .address)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        routing = try c.decodeIfPresent(SourceRoute.self, forKey: .routing) ?? .auto
        environmentID = try c.decodeIfPresent(UUID.self, forKey: .environmentID)
    }
    /// Its name, else where it lives and its file: many subscriptions share a host such as
    /// raw.githubusercontent.com, so a GitHub address reads as its repository.
    public var title: String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty else { return name }
        guard let url = URL(string: address), let host = url.host() else { return address }
        if ImportedFiles.isImported(address) { return url.lastPathComponent }
        let parts = url.pathComponents.filter { $0 != "/" }
        let place = host == "raw.githubusercontent.com" && parts.count > 2 ? parts[0] + "/" + parts[1]
            : host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return parts.last.map { place + " · " + $0 } ?? place
    }
    /// The file name its last good copy is kept under.
    public var cacheName: String { PluginChecksum.sha256(Data(address.utf8)) + ".json" }
}

/// What an added address holds: one subscription, a directory that lists several, or AList servers
/// (the server itself, or a TVBox AList configuration that lists them) for Cloud Files.
public enum SubscriptionImport: Sendable {
    case subscription(Subscription)
    case directory([SubscriptionEntry])
    case alist([AListServer])
    /// A Venera comic source list (`index.json` of venera-configs or a copy), with how many sources it lists:
    /// it feeds the Manga section, not Watch Now.
    case comicSources(Int)
    /// A Legado book source list (one JSON array of `bookSourceUrl` sources), with the data downloaded:
    /// it feeds the Novels section.
    case novelSources(Int, Data)
    /// A page of Legado book source lists, or a Legado subscription source (订阅源) that opens one: the lists it links
    /// to, for the viewer to choose from in Book Sources.
    case novelIndex([NovelSourceOffer])
    /// An LX Music custom source (洛雪音源), the script's text: people add these here too (#1177). It goes to Music's
    /// LX Music Sources, not Watch Now. Only content that is no subscription reads as one.
    case lxMusicSource(String)
}

extension HTTPClient {
    public func subscriptionImport(_ url: URL) async throws -> SubscriptionImport {
        let (data, finalURL) = try await get(url, headers: ["User-Agent": Self.subscriptionUserAgent], limit: Self.subscriptionLimit)
        if let bundle = CatPawOpen.bundle(data, at: finalURL) { return .subscription(try await CatPawOpen.subscription(bundle: bundle, origin: finalURL, http: self)) }
        if let count = MangaSources.listedCount(data) { return .comicSources(count) }
        if let sources = NovelSource.list(from: data) { return .novelSources(sources.count, data) }
        if let pages = NovelSourceIndex.pages(from: data) { return .novelIndex(try await NovelSourceIndex.offers(pages: pages, http: self)) }
        if let servers = AListServer.list(from: data) { return .alist(servers) }
        if let entries = Subscription.directory(data, origin: finalURL) { return .directory(entries) }
        let offers = NovelSourceIndex.offers(inPage: data, origin: finalURL)
        if !offers.isEmpty { return .novelIndex(offers) }
        do { return .subscription(try await Subscription.parse(data, origin: finalURL).sniffingScripts(http: self)) }
        catch {
            // An LX Music source isn't a subscription, but people add one here to play music (#1177).
            if let script = LXSourceLibrary.script(in: data) { return .lxMusicSource(script) }
            // An AList server answers its address with its web page.
            if let server = await AList.probe(url, session: session) { return .alist([server]) }
            throw error
        }
    }
}
