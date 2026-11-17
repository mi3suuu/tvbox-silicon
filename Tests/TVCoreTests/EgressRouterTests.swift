import Foundation
import Network
import Testing
@testable import TVCore

/// 出口决策的回归：这套逻辑决定「直连还是代理」，错了就是整页内容播不了，
/// 所以每一条规则都要有断言压着。
@Suite(.serialized) struct EgressRouterTests {

    // MARK: 按 host 记账

    @Test func aDirectSuccessIsRememberedSoTheNextRequestCostsNothing() {
        let table = HostEgressTable()
        let key = "cdn.example.com|media"
        #expect(table.leg(key) == .direct)
        #expect(!table.isProven(key), "没试过不能当成「已知直连」")

        table.record(key, leg: .direct)
        #expect(table.leg(key) == .direct)
        #expect(table.isProven(key))
    }

    @Test func aProxySuccessIsRememberedWithItsProxy() {
        let table = HostEgressTable()
        let key = "blocked.example.com|media"
        table.record(key, leg: .proxy("loon"))
        #expect(table.leg(key) == .proxy("loon"))
        #expect(table.isProven(key))
    }

    @Test func twoProxyFailuresSendTheHostBackToDirect() {
        let table = HostEgressTable()
        let key = "flaky.example.com|media"
        table.record(key, leg: .proxy("loon"))
        #expect(table.recordFailure(key, leg: .proxy("loon")) == nil)
        // 第二次连续失败：节点多半真的不通，退回直连，别把整页内容赔进去。
        #expect(table.recordFailure(key, leg: .proxy("loon")) == .direct)
        #expect(!table.isProven(key))
    }

    @Test func aDirectFailureInvalidatesTheConclusion() {
        let table = HostEgressTable()
        let key = "move.example.com|image"
        table.record(key, leg: .direct)
        #expect(table.recordFailure(key, leg: .direct) == nil)
        #expect(!table.isProven(key), "直连刚失败过，不能继续声称「已知直连」")
    }

    @Test func forgettingAClearsOnlyThatHost() {
        let table = HostEgressTable()
        table.record("a.example.com|media", leg: .proxy("p"))
        table.record("b.example.com|media", leg: .proxy("p"))
        table.forget(host: "a.example.com")
        #expect(!table.isProven("a.example.com|media"))
        #expect(table.isProven("b.example.com|media"))
    }

    @Test func purposesOnTheSameHostAreTrackedApart() {
        let table = HostEgressTable()
        table.record("mixed.example.com|catalog", leg: .direct)
        table.record("mixed.example.com|media", leg: .proxy("p"))
        #expect(table.leg("mixed.example.com|catalog") == .direct)
        #expect(table.leg("mixed.example.com|media") == .proxy("p"))
    }

    // MARK: 中继地址

    /// 签名地址里的 `%2F` 必须原样带过去。
    ///
    /// `url.path` 是解码过的：`/a%2Fb/c` 会变成 `/a/b/c`，中继再按斜杠切分，路径就多一层、
    /// 签名失效 —— 源站回 403，播放器只看到「连上了但没内容」。
    @Test func aPercentEncodedPathSurvivesTheRelayAddress() {
        let base = URL(string: "http://127.0.0.1:9999/")!
        let target = URL(string: "https://cdn.example.com/hls/a%2Fb/index.m3u8?sign=ab%2Bcd&t=1")!
        let relayed = LocalProxyServer.proxyURL(base: base, url: target, proxyID: "p1")
        #expect(relayed.absoluteString.contains("a%2Fb"), "路径里的 %2F 被解码了：\(relayed.absoluteString)")
        #expect(!relayed.absoluteString.contains("a/b/index"), "路径被多切了一层：\(relayed.absoluteString)")
        #expect(relayed.absoluteString.contains("sign=ab%2Bcd"), "查询串被改写：\(relayed.absoluteString)")
    }

    /// 解析回来要能和原地址对上，否则中继会拨错目标。
    @Test func theRelayAddressRoundTripsThroughParse() throws {
        let base = URL(string: "http://127.0.0.1:9999/")!
        let target = URL(string: "https://api.example.com:8443/vod/api.php?ac=videolist&pg=1")!
        let relayed = LocalProxyServer.directURL(base: base, url: target)
        let path = try #require(relayed.absoluteString.components(separatedBy: "9999").last)
        let parsed = try #require(LocalProxyServer.parse(String(path.dropFirst())))
        #expect(parsed.host == "api.example.com")
        #expect(parsed.port == 8443)
        #expect(parsed.scheme == "https")
        #expect(parsed.path == "/vod/api.php?ac=videolist&pg=1")
        #expect(parsed.proxyID == nil)
    }

    /// 回环地址不许再进中继：remux / 插件代理都在本机监听，
    /// 包一层就是「中继把请求发给它自己」，而且 `127.0.0.1|media` 是所有源共用的键。
    @Test func aLoopbackAddressIsNeverWrappedAgain() {
        let base = URL(string: "http://127.0.0.1:9999/")!
        for address in ["http://127.0.0.1:8080/hls/index.m3u8",
                        "http://localhost:8080/proxy?do=play",
                        "http://127.0.0.55:9000/x"] {
            let url = URL(string: address)!
            #expect(EgressRouter.isLoopback(url))
            #expect(EgressRouter.shared.routed(url, leg: .proxy("p1")) == url,
                    "回环地址被包进了中继：\(address)")
        }
        #expect(!EgressRouter.isLoopback(URL(string: "https://cdn.example.com/a.m3u8")!))
    }

    /// 回环判定只认**地址**，不认前缀。
    ///
    /// `127.net` 是真实 CDN 域；`127.0.0.1.cdn.example.com` 由源站控制、可指向任何服务器。
    /// 前缀匹配会让这些 host 的代理腿被静默抹掉（日志里连一行都没有）。
    @Test func aHostnameStartingWith127IsNotLoopback() {
        #expect(!EgressRouter.isLoopbackHost("127.net"))
        #expect(!EgressRouter.isLoopbackHost("127.0.0.1.cdn.example.com"))
        #expect(!EgressRouter.isLoopbackHost("example.com"))
        #expect(EgressRouter.isLoopbackHost("127.0.0.55"))
        #expect(EgressRouter.isLoopbackHost("127.1"))
        #expect(EgressRouter.isLoopbackHost("[::1]"))
        #expect(EgressRouter.isLoopbackHost("LOCALHOST"))
        #expect(EgressRouter.isLoopbackHost("[::ffff:127.0.0.1]"))
        // 下面三条是**刻意不覆盖**，写进测试是为了别让后人来「补 bug」：
        // 通配 DNS（解析到 127.0.0.1）与整数/十六进制写法必须靠「解析后判 127/8」才挡得住，
        // 那是拨号层的职责。把字符串判据当成安全边界，越补越像安全边界。
        // 本方法的定位是「避免误判 127.net 这类真域名 + 避免中继自连」。
        #expect(!EgressRouter.isLoopbackHost("127.0.0.1.nip.io"))
        #expect(!EgressRouter.isLoopbackHost("127.0.0.1."))
        #expect(!EgressRouter.isLoopbackHost("0x7f000001"))
        // 末尾一个点会让 split 多出一个空段 —— 这条断言压住
        // `omittingEmptySubsequences` 被谁顺手改掉（那会把 `127.0.0.1.` 判成回环）。
        #expect(!EgressRouter.isLoopbackHost("127.0.0."))
    }

    // MARK: 端点解析

    /// 标了「代理」但解析不出端点时，绝不能静默当成直连。
    ///
    /// 观众在两台代理、又没指定「默认出口」时点「代理」，`fallbackEndpoint` 会返回 nil
    /// （它刻意「不替观众选」）。若出口逻辑照搬这个 nil，界面显示代理、实际一条代理请求
    /// 都不发 —— 界面对、日志空、行为错，是最难查的一类。
    @Test func aMarkedProxySourceStillFindsAnEndpointWhenNoDefaultIsChosen() {
        let defaults = UserDefaults(suiteName: "egress-tests-\(UUID().uuidString)")!
        let store = CustomProxyStore(defaults: defaults)
        let a = CustomProxyEndpoint(name: "loon", scheme: .http, host: "127.0.0.1", port: 7221)
        let b = CustomProxyEndpoint(name: "other", scheme: .socks5, host: "127.0.0.1", port: 7891)
        store.upsert(a); store.upsert(b)

        // 两台且没指定：这里刻意返回 nil。
        #expect(store.fallbackEndpoint == nil)
        // 但「已经决定要走代理」时必须还能选出一台。
        #expect(store.bestEndpointID() != nil)
        #expect([a.id, b.id].contains(store.bestEndpointID()!))

        store.defaultProxyID = b.id
        #expect(store.bestEndpointID() == b.id)
    }

    // MARK: 语义

    @Test func directOnlyNeverAsksForAProxyLeg() {
        // 没有端点可用的「直连」才是真的不过代理。
        let policy = EgressPolicy.directOnly
        #expect(policy.proxyID == nil)
        #expect(!policy.allowsProxy)
    }

    /// 「直连」= 直连先跑、失败由代理救一次，**不是**永不允许代理。
    ///
    /// 源列表里一百多条 `direct` 大多是测速/自动分流批量写进去的；把它们当成硬约束，
    /// 直连一被掐就是上百个源同时「暂时无法加载此来源」，而代理腿明明还在。
    @Test func aDirectChoiceStillLetsTheProxyRescueAFailure() {
        let policy = EgressPolicy.preferDirect(proxyID: "loon")
        #expect(policy.allowsProxy)
        #expect(policy.proxyID == "loon")
        // 没有可用端点时退回纯直连，不假装有代理。
        #expect(!EgressPolicy.preferDirect(proxyID: nil).allowsProxy)
    }

    @Test func automaticWithAnEndpointAllowsTheFallback() {
        #expect(EgressPolicy.automatic(proxyID: "p1").allowsProxy)
        #expect(EgressPolicy.automatic(proxyID: nil).allowsProxy == false)
        #expect(EgressPolicy.preferProxy(proxyID: "p1").proxyID == "p1")
    }

    @Test func onlyConnectionLevelFailuresSwitchLegs() {
        // 连接没建立 / 会话被关：换腿有意义。
        #expect(EgressRouter.isEgressFailure(URLError(.cannotConnectToHost)))
        #expect(EgressRouter.isEgressFailure(URLError(.secureConnectionFailed)))
        #expect(EgressRouter.isEgressFailure(URLError(.networkConnectionLost)))
        #expect(EgressRouter.isEgressFailure(URLError(.timedOut)))
        #expect(EgressRouter.isEgressFailure(TVError.http(403)))
        #expect(EgressRouter.isEgressFailure(TVError.http(503)))
        // 源站明确回答的内容类错误：换腿只会白花一次请求。
        #expect(!EgressRouter.isEgressFailure(TVError.http(404)))
        #expect(!EgressRouter.isEgressFailure(TVError.invalidURL))
        #expect(!EgressRouter.isEgressFailure(CancellationError()))
    }
}

/// 端点地址不能是「上一次网络的快照」。
///
/// 真机踩过：端点记着 `192.168.124.55`（家里 Wi-Fi），设备切到热点 `172.20.10.x`，
/// 中继拨这个地址必然失败 —— 代理腿和直连腿一起挂，界面只剩「暂时无法加载此来源」。
@Suite struct ProxyDialPlanTests {
    @Test func aStalePrivateAddressFollowsTheCurrentNetwork() {
        let plan = LocalNetwork.plan(stored: "192.168.124.55", currentIPv4: "172.20.10.2")
        #expect(plan.primary == "127.0.0.1")
        #expect(plan.fallback == "172.20.10.2")
    }

    @Test func anAddressThatStillExistsIsLeftAlone() {
        let plan = LocalNetwork.plan(stored: "192.168.124.55", currentIPv4: "192.168.124.55")
        #expect(plan.primary == "192.168.124.55")
        #expect(plan.fallback == nil)
    }

    @Test func loopbackBecomesTheCurrentLANAddress() {
        let plan = LocalNetwork.plan(stored: "127.0.0.1", currentIPv4: "10.0.0.7")
        #expect(plan.primary == "10.0.0.7")
        #expect(plan.fallback == "127.0.0.1")
    }

    @Test func aPublicProxyIsNeverRewritten() {
        let plan = LocalNetwork.plan(stored: "203.0.113.9", currentIPv4: "172.20.10.2")
        #expect(plan.primary == "203.0.113.9")
        #expect(plan.fallback == nil)
    }

    @Test func privateRangesAreRecognised() {
        #expect(LocalNetwork.isPrivate("10.1.2.3"))
        #expect(LocalNetwork.isPrivate("172.16.0.1"))
        #expect(LocalNetwork.isPrivate("172.31.255.254"))
        #expect(!LocalNetwork.isPrivate("172.32.0.1"))
        #expect(!LocalNetwork.isPrivate("192.169.1.1"))
        #expect(!LocalNetwork.isPrivate("8.8.8.8"))
    }
}

/// 生成的 Loon 插件必须满足三件事，否则真机上会静默失效：
///   1. 规则行只写 `PROXY`（插件规则只允许 DIRECT/REJECT/PROXY，写组名会被判非法）；
///   2. 不能出现空规则（Loon 会报「无法找到任何有效规则」）；
///   3. 域名去重、忽略空项，否则同一域名重复出现会浪费匹配且不好排查。
@Suite struct LoonPluginTests {
    @Test func rulesUseTheProxyKeywordBecauseTheGroupNameMoves() {
        let text = LoonPlugin.text(hosts: ["aosikazy.com"])
        #expect(text.contains("DOMAIN-SUFFIX,aosikazy.com,PROXY"))
        // 写成具体组名在插件里是非法的，也是脆的：观众改组名就失效。
        #expect(!text.contains("节点选择"))
    }

    @Test func hostsAreNormalisedAndDeduplicated() {
        let text = LoonPlugin.text(hosts: ["  AoSikazy.COM ", "aosikazy.com", "", "no-dot", "xingba111.com"])
        #expect(text.contains("DOMAIN-SUFFIX,aosikazy.com,PROXY"))
        #expect(text.contains("DOMAIN-SUFFIX,xingba111.com,PROXY"))
        #expect(text.components(separatedBy: "aosikazy.com").count == 2)  // 只出现一次
        #expect(!text.contains("no-dot"))
        #expect(LoonPlugin.ruleCount(hosts: ["a.com", "A.com", " b.com "]) == 2)
    }

    @Test func anEmptyListNeverProducesAnEmptyRuleSection() {
        let text = LoonPlugin.text(hosts: [])
        #expect(text.contains("[Rule]"))
        // 只有注释，没有半条规则 —— 这种文件不该被导进 Loon，但也不能产出一行空的 "DOMAIN-SUFFIX,,"。
        #expect(!text.contains("DOMAIN-SUFFIX,"))
        #expect(LoonPlugin.ruleCount(hosts: []) == 0)
    }

    @Test func theHeaderCarriesWhatLoonNeedsToAcceptIt() {
        let text = LoonPlugin.text(hosts: ["a.com"])
        for field in ["#!name =", "#!desc =", "#!author =", "#!system =", "#!date =", "#!type = normal"] {
            #expect(text.contains(field), "缺少 \(field)")
        }
    }
}
