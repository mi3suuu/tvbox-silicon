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
    public static func name(for address: String) -> String? {
        if address.lowercased() == kanjuAddress { return "看剧AI" }
        return feeds[address]?.name
    }

    /// The entry a fresh install seeds: the bundled pack knows its own default routing and whether
    /// it starts switched on (the dead group and the unimplemented group start off).
    public static func entry(for address: String) -> SubscriptionEntry? {
        if address.lowercased() == kanjuAddress {
            return SubscriptionEntry(address: kanjuAddress, name: "看剧AI", routing: .auto)
        }
        guard let feed = feeds[address] else { return nil }
        return SubscriptionEntry(address: feed.address, name: feed.name, enabled: feed.enabled, routing: feed.routing)
    }

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
        return Subscription(origin: origin, importedAt: Date(), sites: sites, lives: [], raw: raw)
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
