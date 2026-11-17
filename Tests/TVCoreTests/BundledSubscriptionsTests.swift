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
    // 三档**全部只走官方线路**，区别只在优先 1080 还是 4K。
    //
    // ⛔ 这里曾经断言第三档是 `{"prefer":"ordinary"}`（「省额度」= 走普通采集线）。
    //    用户要求「只取官方源，其他的不做收录」后，那一档已改为官方 1080，
    //    所以判据同步更新 —— 否则测的是旧行为，改对了反而红。
    #expect(document.sites[0].raw["ext"] == nil)
    #expect(document.sites[1].raw["ext"]?.string == #"{"prefer":"4k"}"#)
    #expect(document.sites[2].raw["ext"] == nil)
    // 不变式：任何一档都不得显式要求走普通（非官方）线路。
    //
    // ⛔ 不要在这里用 `#expect(cond, "\(site.key) ...")` 的形式：
    //    Swift Testing 会把消息参数里的插值一并纳入表达式求值，
    //    而 `site` 是循环变量 —— 实测会得到 3 条无法定位的失败，
    //    且失败原因与真实条件无关（探针证明 ext 实际是 nil / "4k" / nil）。
    //    改成先把条件算成 Bool，再单独断言，行为才可预期。
    let ordinaryFree = document.sites.allSatisfy { site in
        let ext = site.raw["ext"]?.string ?? ""
        return !ext.contains("ordinary")
    }
    #expect(ordinaryFree)
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
    // 22 组并成 7 组，再按内容把失效拆成「影视 / 成人」两组 —— 8 组 + 看剧AI。
    #expect(addresses.count == 9)

    let direct = try #require(BundledSubscriptions.document(for: "builtin://yingxia-route-00"))
    #expect(direct.origin.absoluteString == "builtin://yingxia-route-00")
    #expect(!direct.sites.isEmpty)
    // Verdicts travel with the sources, so the source list can still show why a line is routed.
    #expect(direct.sites.contains { $0.raw["_probe"] != nil })

    let playable = try #require(BundledSubscriptions.entry(for: "builtin://yingxia-route-00"))
    #expect(playable.routing == .direct)
    #expect(playable.name.contains("可播"))

    // The dead buckets ship switched off — both of them, the adult one included.
    for dead in ["builtin://yingxia-route-06", "builtin://yingxia-route-07"] {
        let entry = try #require(BundledSubscriptions.entry(for: dead))
        #expect(entry.enabled == false)
    }
}

/// 影视和成人不许混在一组里。
///
/// 这不是排版偏好：`成人 · 可播` 里混进两个 🔞AV 源的时候，源列表第一屏就是它们；
/// 反过来，搜「流浪地球」时若成人组也参与搜索，结果里会混进一堆不相干的条目。
/// 判据只认明确的成人标记（🔞、成人、麻豆、4k-av、missav 这类），`WebDav`、`奶酪`
/// 这种名字里带 `av` / `奶` 的正常源不会被误判 —— 误判会把好源从影视组里赶走。
@Test func routePackKeepsAdultSeparate() throws {
    let strong = try NSRegularExpression(pattern:
        "🔞|成人|伦理|无码|有码|女优|探花|黑料|性吧|杏吧|色情|情色|淫|麻豆|番号|里番|约啪|桃色|黄片|裸",
        options: [.caseInsensitive])
    let token = try NSRegularExpression(pattern:
        #"4k-?av|\bjav\b|\bporn\b|\bxxx\b|\bhentai\b|\bnsfw\b|missav|supjav|hstream"#,
        options: [.caseInsensitive])

    func looksAdult(_ site: Site) -> Bool {
        let group = site.raw["group"]?.string ?? ""
        if group.contains("成人") { return true }
        let text = [site.name, site.key, group].joined(separator: " ")
        let range = NSRange(text.startIndex..., in: text)
        return strong.firstMatch(in: text, range: range) != nil
            || token.firstMatch(in: text, range: range) != nil
    }

    for address in BundledSubscriptions.addresses {
        guard let document = BundledSubscriptions.document(for: address) else { continue }
        let adultFeed = BundledSubscriptions.isAdult(address)
        for site in document.sites {
            if adultFeed {
                #expect(site.raw["_content"]?.string == "adult", "\(site.key) 在成人组里却没有成人标记")
            } else {
                #expect(!looksAdult(site), "\(site.key)（\(site.name)）是成人源，却混在 \(address) 里")
            }
        }
    }
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

/// 组名里不再带打包时写死的源数。
///
/// 「影视 · 可播(46)」在源变少之后就是错的，而分组头上本来就有实时计数 ——
/// 两个数字并排（「影视 · 可播(46) 35」）时读者没法知道该信哪个。
@Test func bundledNamesCarryNoStaleCount() throws {
    // 包本身还在写，这一层出口剥掉：读的地方只有一个口径。
    for address in BundledSubscriptions.addresses.dropFirst() {
        let name = try #require(BundledSubscriptions.name(for: address))
        #expect(name.range(of: #"\(\d+\)$"#, options: .regularExpression) == nil, "\(name)")
        #expect(!name.isEmpty)
        // 订阅列表种下的那条与显示名一致，否则升级后第一次启动会「改名」一次。
        #expect(BundledSubscriptions.entry(for: address)?.name == name)
    }
    #expect(BundledSubscriptions.trimmed("影视 · 可播(46)") == "影视 · 可播")
    // 观众自己起的名字里有括号数字，不该被改写（这一层只管包给的名字）。
    #expect(BundledSubscriptions.trimmed("我的4K(1)") == "我的4K")
}

/// 看剧AI 的 `importedAt` 取**构建时间**，不是「现在」。
///
/// 取「现在」的话，每次冷启动它都比缓存「新」→ 每次都重写缓存、重建合并列表，
/// 于是 `refreshBundledDocuments` 注释里「同一版包里这是幂等的」根本不成立。
@Test func theBundledPluginIsStampedWithTheBuildDate() {
    let first = BundledSubscriptions.kanju()
    let second = BundledSubscriptions.kanju()
    #expect(first.importedAt == second.importedAt)
    #expect(first.importedAt == BundledSubscriptions.buildDate)
}

/// 包读不出来时，调用方必须能看出来 —— 否则「这一版包里没有这个地址」这条判据
/// 会把观众列表里的内置组连同缓存一起删光。
@Test func anEmptyPackIsDistinguishable() {
    #expect(!BundledSubscriptions.feedsIsEmpty)
}
