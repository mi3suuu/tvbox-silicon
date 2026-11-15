import Foundation
import Testing
@testable import TVCore

/// A feed the app carries itself must answer without a host: no DNS, no refresh error, and the
/// plugin it names has to be the one bundled in `ScriptAssets`.
@Test func bundledKanjuNeedsNoAddress() throws {
    let document = try #require(BundledSubscriptions.document(for: BundledSubscriptions.kanjuAddress))
    #expect(document.sites.count == 3)
    #expect(document.origin.absoluteString == "builtin://kanju")
    #expect(document.lives.isEmpty)
    // Every entry runs the bundled plugin, and nothing points at a host.
    for site in document.sites {
        #expect(site.type == 3)
        #expect(site.api == "assets://js/kanju.js")
        #expect(site.raw["api"]?.string == "assets://js/kanju.js")
    }
    #expect(document.sites.map(\.key) == ["kanju_o", "kanju_4k", "kanju_s"])
    // The default spends tokens (official first); the third entry is the one that does not.
    #expect(document.sites[0].raw["ext"] == nil)
    #expect(document.sites[1].raw["ext"]?.string == #"{"prefer":"4k"}"#)
    #expect(document.sites[2].raw["ext"]?.string == #"{"prefer":"ordinary"}"#)
    // The script resolves to the bundle, not to anything relative to the pseudo-origin.
    #expect(try document.sites[0].scriptURL(origin: document.origin).absoluteString == "assets://js/kanju.js")
}

@Test func ordinaryAddressesAreNotBundled() {
    #expect(BundledSubscriptions.isBundled(BundledSubscriptions.kanjuAddress))
    #expect(BundledSubscriptions.isBundled("BUILTIN://kanju"))
    #expect(!BundledSubscriptions.isBundled("https://example.com/a.json"))
    #expect(BundledSubscriptions.document(for: "https://example.com/a.json") == nil)
    // An unknown builtin name is a miss, not a crash: the old address just shows as a failed refresh.
    #expect(BundledSubscriptions.document(for: "builtin://nothing") == nil)
}

/// The route pack rides in `ScriptAssets/builtin/route.json`; it must decode into the same groups
/// the exporter wrote, with each group keeping its own default routing and on/off state.
@Test func bundledRoutePackKeepsItsGroups() throws {
    let addresses = BundledSubscriptions.addresses
    #expect(addresses.first == BundledSubscriptions.kanjuAddress)
    // 22 组并成 7 组：影视 可播/待测、成人 可播、直播、4K·网盘、工具·插件、失效（默认关闭）。
    #expect(addresses.count == 8)

    let direct = try #require(BundledSubscriptions.document(for: "builtin://yingxia-route-00"))
    #expect(direct.origin.absoluteString == "builtin://yingxia-route-00")
    #expect(!direct.sites.isEmpty)
    // Verdicts travel with the sources, so the source list can still show why a line is routed.
    #expect(direct.sites.contains { $0.raw["_probe"] != nil })

    let playable = try #require(BundledSubscriptions.entry(for: "builtin://yingxia-route-00"))
    #expect(playable.routing == .direct)
    #expect(playable.name.contains("可播"))

    // The dead bucket ships switched off.
    let dead = try #require(BundledSubscriptions.entry(for: "builtin://yingxia-route-06"))
    #expect(dead.enabled == false)
}

/// 中转只在映匣里：包里不能再有任何一台外部中继的地址。
///
/// 这条是回归闸门 —— 上一版有 31 个源把 `149.104.28.149:8100/cms/<token>/…` 写死在 `api` 里，
/// 那台机器一关（或换了 token），所有「中转」源一起变黑，而映匣自己一点办法都没有。
/// 新的中转是 `LocalProxyServer` 回环 + 观众自己的出口代理，随包数据里一个外部中继地址都不该有。
@Test func routePackCarriesNoExternalRelay() throws {
    for address in BundledSubscriptions.addresses {
        guard let document = BundledSubscriptions.document(for: address) else { continue }
        for site in document.sites {
            #expect(!site.api.contains("149.104.28.149"), "\(site.key) 还指着外部中继")
            #expect(!String(describing: site.raw).contains("149.104.28.149"), "\(site.key) 的附加信息里还留着外部中继")
        }
        for live in document.lives {
            #expect(!live.url.absoluteString.contains("149.104.28.149"), "\(live.name) 还指着外部中继")
        }
    }
}

/// The pack that ships to users says `builtin://kanju`, so importing it lands on the same entry the
/// fresh-install seed uses instead of creating a second, unreachable one.
@Test func kanjuConfigUsesTheBundledAddress() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/TVCore/ScriptAssets/js/kanju.js")
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(BundledSubscriptions.kanju().sites.count == 3)
}

/// 看剧AI 的官方线路是服务端现签、按集扣词元的，所以这三条源必须声明「只预热线路表」。
///
/// 少了这个标记，详情页会退回老路：把三条线路各解析一遍（官方 1080 与官方 4K 各扣一次额度），
/// 而脚本线程是串行的，用户点播放就排在这三次签名后面 —— 「首次播放要等很久」正是这么来的。
@Test func kanjuOnlyPrefetchesTheLineList() throws {
    let document = try #require(BundledSubscriptions.document(for: BundledSubscriptions.kanjuAddress))
    for site in document.sites {
        #expect(site.prefetchesLineList)
    }
    // 普通源没有这个声明：预热要过一次脚本运行时，不能顺手给所有源都加上。
    let plain = try JSONDecoder().decode(Site.self, from: Data(#"{"key":"x","name":"X","type":1,"api":"https://example.com/api.php/provide/vod","raw":{}}"#.utf8))
    #expect(!plain.prefetchesLineList)
}
