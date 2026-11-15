import Foundation

/// Feeds that live inside the app rather than behind an address.
///
/// The kanju pack used to point at a machine on the developer's LAN
/// (`macdeMacBook-Pro.local:8081/...`): on that Mac it worked, everywhere else every refresh was a
/// DNS failure, and the sources only survived because the import had already inlined them. A feed
/// that is really the app's own capability should not need a host at all — the plugin ships in
/// `ScriptAssets/js`, so the subscription comes from the bundle too.
///
/// `builtin://` is deliberately not a scheme `WebAddress.resolve` accepts: nothing here is fetched,
/// so an offline install and a phone on a foreign network behave exactly like the Mac.
public enum BundledSubscriptions {
    /// The address that names the bundled 看剧AI pack. Stored in the subscription list like any
    /// other, so the viewer can disable or delete it and the choice sticks.
    public static let kanjuAddress = "builtin://kanju"
    /// The 映匣 route pack: its sources are in `ScriptAssets/builtin/route.json`, one feed per group
    /// (direct / proxy / untested / dead / live …), each carrying the probe verdict it was built from.
    public static let routePrefix = "builtin://yingxia-route-"

    public static func isBundled(_ address: String) -> Bool {
        address.lowercased().hasPrefix("builtin://")
    }

    /// 包里装成人内容的两组。分组把它们和影视分开了，**搜索**是另一条通道 —— 它按源问过去，
    /// 谁参与谁出声。这两组默认退出搜索（见 `Store.excludeAdultFeedsFromSearch`），
    /// 想看的时候在分组头的菜单里勾回来即可。
    public static let adultAddresses = [
        routePrefix + "02",   // 成人 · 可播
        routePrefix + "07",   // 成人 · 待测/失效
    ]

    public static func isAdult(_ address: String) -> Bool {
        adultAddresses.contains(address)
    }

    /// Every bundled feed, in the order `route.json` lists them. Seeded on a fresh install.
    public static var addresses: [String] {
        [kanjuAddress] + feeds.keys.sorted { $0 < $1 }
    }

    /// The document for a bundled address, or `nil` when the address is an ordinary one.
    public static func document(for address: String) -> Subscription? {
        if address.lowercased() == kanjuAddress { return kanju() }
        return feeds[address]?.document
    }

    /// What the subscription list should call a bundled feed. Without it the row would show the
    /// address, and `builtin://kanju` reads like something a viewer typed by mistake.
    ///
    /// 名字末尾的「(46)」是打包脚本写死的源数，而分组头上本来就有实时计数 ——
    /// 两个数字并排出现（「影视 · 可播(46) 35」）时，读者没法知道该信哪个，而写死的那个
    /// 只要有一版没重新打包就是错的。所以显示名一律去掉它：**数量只由实时计数提供**。
    public static func name(for address: String) -> String? {
        if address.lowercased() == kanjuAddress { return "看剧AI" }
        return feeds[address].map { trimmed($0.name) }
    }

    /// 去掉名字末尾的「(46)」。包里的数据不动 —— 打包脚本与旧缓存都还写着它，
    /// 只在这一层出口处剥掉，读的地方就只有一个口径。
    static func trimmed(_ name: String) -> String {
        name.replacingOccurrences(of: #"\(\d+\)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The entry a fresh install seeds: the bundled pack knows its own default routing and whether
    /// it starts switched on (the dead group and the unimplemented group start off).
    public static func entry(for address: String) -> SubscriptionEntry? {
        if address.lowercased() == kanjuAddress {
            return SubscriptionEntry(address: kanjuAddress, name: "看剧AI", routing: .auto)
        }
        guard let feed = feeds[address] else { return nil }
        return SubscriptionEntry(address: feed.address, name: trimmed(feed.name),
                                 enabled: feed.enabled, routing: feed.routing)
    }

    /// 包读不出来时是空的。
    ///
    /// 调用方（`Store.dropRetiredBundledFeeds`）必须据此**放弃清理**：把「这一版包里没有这个地址」
    /// 用在空名单上，会把观众订阅列表里的内置组连同缓存一起删光，而 `seedAggregatedSubscriptions`
    /// 也补不回来（它按同一份空名单算「还没装过谁」）。一次打包错误不该变成数据丢失。
    public static var feedsIsEmpty: Bool { feeds.isEmpty }

    /// The app's build time, standing in for "when this bundled document was written".
    ///
    /// 代码生成的内置订阅（看剧AI）没有打包时间可用。取「现在」会让它每次启动都比缓存「新」，
    /// 于是每次冷启动都重写缓存、重建一次合并列表 —— 幂等性就没了。取可执行文件的修改时间
    /// 是同一个问题的正确答案：同一版 App 内恒定（一次都不重写），换了新版本必然更新
    /// （新二进制的时间一定晚于任何一次旧启动写下的时间戳）。
    public static let buildDate: Date = {
        if let url = Bundle.main.executableURL,
           let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
           let date = values.contentModificationDate {
            return date
        }
        return .distantPast
    }()

    // MARK: - Route pack

    private struct FeedFile: Decodable {
        let feeds: [Feed]
    }

    private struct Feed: Decodable {
        let address: String
        let name: String
        let enabled: Bool
        let routing: SourceRoute
        let document: Subscription
    }

    /// Parsed once. A missing or malformed resource yields an empty pack rather than crashing: the
    /// rest of the app (and the 看剧AI feed above, which needs no file) keeps working.
    private static let feeds: [String: Feed] = {
        guard let text = ScriptAssets.bundled("assets://builtin/route.json"),
              let data = text.data(using: .utf8) else { return [:] }
        let decoder = JSONDecoder()
        // The pack is written by our own exporter, which stamps `importedAt` in Unix seconds.
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let file = try? decoder.decode(FeedFile.self, from: data) else { return [:] }
        return Dictionary(file.feeds.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
    }()

    /// One plugin, three entries: they differ only in `ext`, which decides which line group the
    /// plugin puts first (`official` by default, `4k`, or `ordinary` to spend no tokens).
    public static func kanju() -> Subscription {
        let sites = [
            kanjuSite(key: "kanju_o", name: "看剧AI · 官方优先", ext: "", sort: 1),
            kanjuSite(key: "kanju_4k", name: "看剧AI · 官方4K", ext: #"{"prefer":"4k"}"#, sort: 2),
            kanjuSite(key: "kanju_s", name: "看剧AI · 省额度", ext: #"{"prefer":"ordinary"}"#, sort: 3)
        ]
        let raw: [String: JSONValue] = [
            "sites": .array(sites.map { .object($0.raw) }),
            "lives": .array([]),
            "parses": .array([]),
            "flags": .array([]),
            "ijk": .array([])
        ]
        return Subscription(origin: origin, importedAt: buildDate, sites: sites, lives: [], raw: raw)
    }

    /// A stable pseudo-origin: sources reach their script through `assets://`, so nothing is
    /// resolved against this. It only has to survive being printed in history and diagnostics.
    private static var origin: URL {
        if let url = URL(string: kanjuAddress) { return url }
        return URL(fileURLWithPath: "/")
    }

    private static func kanjuSite(key: String, name: String, ext: String, sort: Int) -> Site {
        var raw: [String: JSONValue] = [
            "key": .string(key),
            "name": .string(name),
            "type": .number(3),
            "api": .string(script),
            "searchable": .number(1),
            "quickSearch": .number(1),
            "filterable": .number(0),
            "group": .string("看剧AI"),
            "sort": .number(Double(sort)),
            // 官方线路是服务端现签、按集扣词元的：每解一条就是一次花销。别在详情页替用户
            // 把三档都解了 —— 只预热不花钱的线路表，签名留到他点播放那一刻（见 CatalogClient）。
            "prefetch": .string("lines")
        ]
        if !ext.isEmpty { raw["ext"] = .string(ext) }
        return Site(key: key, name: name, type: 3, api: script, raw: raw)
    }

    /// The plugin bundled with the app; `Site.scriptURL` maps `assets://` straight to it.
    static let script = "assets://js/kanju.js"
}
