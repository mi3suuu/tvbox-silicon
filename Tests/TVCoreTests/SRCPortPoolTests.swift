import Foundation
import Testing
@testable import TVCore

/// 源端口池：决定「这个请求走 Loon 当前线路」的那一半纸面逻辑。
///
/// 判据来自实测：同一个源端口不能同时承载两条连接（第二次 bind 直接 EADDRINUSE），所以必须是
/// 池 + 借还，而不是一个固定端口。
@Suite struct SRCPortPoolTests {

    @Test func aLeaseIsNeverHandedOutTwice() {
        let pool = SRCPortPool(proxy: 41_500...41_502, direct: 41_600...41_601)
        let first = try! #require(pool.acquire())
        let second = try! #require(pool.acquire())
        let third = try! #require(pool.acquire())
        #expect(Set([first, second, third]).count == 3)
        // 代理段三个都借出后为空；再要必须拿 nil，而不是复用某个已借出的端口。
        #expect(pool.acquire(.proxy) == nil)
        #expect(pool.inUse == 3)
    }

    @Test func returningAPortMakesItAvailableAgain() {
        let pool = SRCPortPool(proxy: 41_500...41_501, direct: 41_600...41_601)
        let port = try! #require(pool.acquire(.proxy))
        _ = pool.acquire(.proxy)
        #expect(pool.acquire(.proxy) == nil)
        pool.release(port)
        #expect(pool.acquire(.proxy) != nil)
        #expect(pool.inUse == 2)
    }

    @Test func doubleReleaseDoesNotDuplicateThePort() {
        // 双重归还会让同一个端口出现两次 → 两条连接抢一个端口，第二条必然 EADDRINUSE。
        let pool = SRCPortPool(proxy: 41_500...41_500, direct: 41_600...41_600)
        let port = try! #require(pool.acquire(.proxy))
        pool.release(port)
        pool.release(port)
        // 双重归还后代理段仍只有 1 个可用，不多出第二个。
        #expect(pool.acquire(.proxy) != nil)
        #expect(pool.acquire(.proxy) == nil)
    }

    @Test func releasingAPortThatWasNeverLeasedIsIgnored() {
        // 归还一个不属于本池的端口不能把池撑大。
        let pool = SRCPortPool(proxy: 41_500...41_500, direct: 41_600...41_600)
        pool.release(49_999)
        #expect(pool.inUse == 0)
        #expect(pool.acquire(.proxy) != nil)
    }

    @Test func aReturnedPortDoesNotJumpTheQueue() {
        // 刚归还的端口连接才断，可能还在 TIME_WAIT。池子必须先把「最久没用」的发出去，
        // 否则一条脏端口会被同一个请求反复拿到（真机 3 分钟 558 次 NWError 48）。
        let pool = SRCPortPool(proxy: 41_500...41_502, direct: 41_600...41_600)
        let first = try! #require(pool.acquire(.proxy))
        _ = try! #require(pool.acquire(.proxy))
        pool.release(first)
        let next = try! #require(pool.acquire(.proxy))
        #expect(next != first, "刚归还的端口被立刻发回去了")
        #expect(next == 41_502, "应当先发池子里最冷的那个，实际 \(next)")
    }

    @Test func everyPortInTheRangeIsCovered() {
        let pool = SRCPortPool(proxy: 41_500...41_599, direct: 41_600...41_699)
        #expect(pool.allPorts.count == 200)
        #expect(pool.allPorts.first == 41_500)
        #expect(pool.allPorts.last == 41_699)
    }

    @Test func theTwoLanesNeverOverlap() {
        // 两段一旦交叠，「直连」的端口会被 Proxy 规则先命中，决策就反了。
        let pool = SRCPortPool()
        #expect(SRCPortPool.proxyRange.overlaps(SRCPortPool.directRange) == false)
        // 借满代理段，直连段不受影响。
        var got: [UInt16] = []
        while let p = pool.acquire(.proxy) { got.append(p) }
        #expect(got.count == SRCPortPool.proxyRange.count)
        #expect(got.allSatisfy { SRCPortPool.proxyRange.contains(Int($0)) })
        #expect(pool.acquire(.direct) != nil)
    }

    @Test func aDirectPortGoesBackToTheDirectLane() {
        // 归还到错误的段，后续连接就可能拿到「本该直连却写了代理规则」的端口。
        let pool = SRCPortPool(proxy: 41_500...41_500, direct: 41_600...41_600)
        let d = try! #require(pool.acquire(.direct))
        #expect(SRCPortPool.directRange.contains(Int(d)))
        pool.release(d)
        // 代理段仍是满的（未被这条归还污染），直连段也回到可用。
        #expect(pool.acquire(.proxy) != nil)
        #expect(pool.acquire(.direct) != nil)
    }

    // MARK: - 给 Loon 的那段规则

    @Test func theFragmentNamesTheSameRangeThePoolUses() {
        // 两边一旦漂移，规则就永远不会命中——这条锁死它们必须一致。
        #expect(LoonSRCPortRule.range == "41500-41599")
        #expect(LoonSRCPortRule.directRange == "41600-41699")
        let fragment = LoonSRCPortRule.fragment
        #expect(fragment.contains("SRC-PORT,41500-41599,Proxy"))
        #expect(fragment.contains("SRC-PORT,41600-41699,DIRECT"))
    }

    @Test func theFragmentGoesAtTheTopAndSaysSo() {
        let fragment = LoonSRCPortRule.fragment
        #expect(fragment.contains("最前面"))
    }

    @Test func anInstalledRuleIsDetected() {
        let conf = """
        [General]
        allow-wifi-access = true
        [Rule]
        SRC-PORT,41500-41599,Proxy
        GEOIP,CN,DIRECT,no-resolve
        FINAL,Final
        """
        #expect(LoonSRCPortRule.isInstalled(inConfig: conf))
    }

    @Test func aMissingRuleIsNotReportedAsInstalled() {
        let conf = """
        [Rule]
        GEOIP,CN,DIRECT,no-resolve
        FINAL,Final
        """
        #expect(!LoonSRCPortRule.isInstalled(inConfig: conf))
    }

    @Test func aCommentedOutRuleDoesNotCount() {
        // 用户把规则注释掉了却仍被判定「已装」，会让他以为生效实则没有——必须按行首判断。
        let conf = """
        [Rule]
        # SRC-PORT,41500-41599,Proxy
        FINAL,Final
        """
        #expect(!LoonSRCPortRule.isInstalled(inConfig: conf))
    }

    @Test func aRuleBuriedBelowOtherRulesIsNotEffective() {
        // 同一行贴到 [Rule] 末尾永远不会命中：Loon 按文件顺序匹配。必须能识别出这个区别，
        // 否则会告诉用户「已装」而实际毫无变化。
        let conf = """
        [Rule]
        DOMAIN-KEYWORD,snssdk,DIRECT
        GEOIP,CN,DIRECT,no-resolve
        SRC-PORT,41500-41599,Proxy
        FINAL,Final
        """
        let placement = LoonSRCPortRule.placement(inConfig: conf)
        #expect(!placement.isEffective)
        guard case .tooLow(let before) = placement else {
            Issue.record("expected .tooLow, got \(placement)")
            return
        }
        #expect(before.contains("snssdk"))
        // 存在性判断仍为真——但「存在」不等于「生效」，两个 API 分别回答两个问题。
        #expect(LoonSRCPortRule.isInstalled(inConfig: conf))
    }

    @Test func aRuleAtTheVeryTopIsEffective() {
        let conf = """
        [Rule]
        SRC-PORT,41500-41599,Proxy
        GEOIP,CN,DIRECT,no-resolve
        FINAL,Final
        """
        #expect(LoonSRCPortRule.placement(inConfig: conf) == .atTop)
        #expect(LoonSRCPortRule.placement(inConfig: conf).isEffective)
    }

    @Test func aRuleInTheWrongSectionIsMissing() {
        // 贴到 [Remote Rule] 或 [General] 里不算数。
        let conf = """
        [General]
        SRC-PORT,41500-41599,Proxy
        [Rule]
        FINAL,Final
        """
        #expect(LoonSRCPortRule.placement(inConfig: conf) == .missing)
    }

    @Test func placementSurvivesALaterRuleSection() {
        // 有些配置有多个 [Rule] 段；只要我们的行在第一个 [Rule] 里且排首位就算生效。
        let conf = """
        [Rule]
        SRC-PORT,41500-41599,Proxy
        FINAL,Final
        [Remote Rule]
        https://example.com/a.lsr, policy=Proxy, enabled=true
        """
        #expect(LoonSRCPortRule.placement(inConfig: conf) == .atTop)
    }

    @Test func aDifferentPortRangeDoesNotCount() {
        // 端口段不一致等于没有规则命中。
        let conf = """
        [Rule]
        SRC-PORT,30000-30099,Proxy
        FINAL,Final
        """
        #expect(!LoonSRCPortRule.isInstalled(inConfig: conf))
    }

    @Test func theOlderWideRangeIsFlaggedBecauseItCoversBothLanes() {
        // 这就是用户当前配置的状态：单段 41500-41799。它把直连段也包进去了，
        // 于是「设成直连」的源反被送去节点——决策反了，必须报警而不是当成「已装」。
        // 必须带 [General] allow-wifi-access，否则会先命中「未开共享」那条提示。
        let legacy = """
        [General]
        allow-wifi-access = true
        [Rule]
        SRC-PORT,41500-41799,Proxy
        FINAL,Final
        """
        #expect(LoonSRCPortRule.hasLegacyWideRange(inConfig: legacy))
        #expect(!LoonSRCPortRule.hasDirectRule(inConfig: legacy))
        let url = URL(string: "http://x:7222/loonapi/v1/config/file.conf")!
        let caveat = try! #require(LoonPreset.parse(legacy, host: "x", source: url).caveat)
        #expect(caveat.contains("41799"))
    }

    @Test func theSplitTwoRangeConfigIsAccepted() {
        let conf = """
        [Rule]
        SRC-PORT,41500-41599,Proxy
        SRC-PORT,41600-41699,DIRECT
        FINAL,Final
        """
        #expect(!LoonSRCPortRule.hasLegacyWideRange(inConfig: conf))
        #expect(LoonSRCPortRule.hasDirectRule(inConfig: conf))
        #expect(LoonSRCPortRule.placement(inConfig: conf) == .atTop)
        let url = URL(string: "http://x:7222/loonapi/v1/config/file.conf")!
        let preset = LoonPreset.parse(conf, host: "x", source: url)
        #expect(preset.hasDirectLine)
        #expect(preset.caveat?.contains("41799") != true)
    }

    @Test func theProxyRangeWithoutTheDirectLineSaysSo() {
        // 只有代理段：直连的源仍会被 Loon 按自己的规则处理，这一半也不能假装完成。
        let conf = """
        [General]
        allow-wifi-access = true
        [Rule]
        SRC-PORT,41500-41599,Proxy
        FINAL,Final
        """
        let url = URL(string: "http://x:7222/loonapi/v1/config/file.conf")!
        let preset = LoonPreset.parse(conf, host: "x", source: url)
        #expect(preset.portRule == .atTop)
        #expect(!preset.hasDirectLine)
        #expect(preset.caveat?.contains("second line") == true)
    }

    // MARK: - 生效性自检

    @Test func twoLanesWithDifferentEgressMeansTheRuleWorks() {
        // 实测原型：境外裸 IP 从 Proxy 段走节点、从 DIRECT 段直连被墙。
        let probe = LoonSRCPortRule.evaluate(proxyResult: "45.207.157.52", directResult: "timeout")
        #expect(probe.outcome == .effective)
        #expect(probe.outcome.isEffective)
    }

    @Test func identicalEgressMeansSomethingElseDecided() {
        // 域名规则抢先的形态：三组端口出口完全一致。
        let probe = LoonSRCPortRule.evaluate(proxyResult: "45.207.157.52", directResult: "45.207.157.52")
        #expect(probe.outcome == .overridden)
        #expect(!probe.outcome.isEffective)
    }

    @Test func bothLanesFailingIsInconclusiveNotAFailure() {
        // 两段都连不出去时不能诬告规则没生效——那可能是节点或网络的问题。
        let probe = LoonSRCPortRule.evaluate(proxyResult: "timeout", directResult: "timeout")
        #expect(probe.outcome == .inconclusive)
        let mixed = LoonSRCPortRule.evaluate(proxyResult: "fail", directResult: "timeout")
        #expect(mixed.outcome == .inconclusive)
    }

    @Test func oneLaneFailingAndTheOtherNotCountsAsEffective() {
        let probe = LoonSRCPortRule.evaluate(proxyResult: "45.207.157.52", directResult: "timeout")
        #expect(probe.outcome == .effective)
    }

    @Test func theProbeHostIsABareIPSoDomainRulesCannotMatch() {
        // 判据成立的前提之一：目标必须是 IP 字面量，否则测到的只是域名规则的优先级。
        let host = LoonSRCPortRule.probeHost
        #expect(host.split(separator: ".").count == 4)
        #expect(host.allSatisfy { $0.isNumber || $0 == "." })
        #expect(!host.contains(".com") && !host.contains(".net"))
    }

    @Test func theProbeHostMustNotBeReachableDirectly() {
        // 前提之二：直连也要不可达，否则两段都能连上、结果一致，会被误判成 overridden。
        // 1.1.1.1 直连可通（实测 301），因此不能用它——这条锁死这个坑。
        #expect(LoonSRCPortRule.probeHost != "1.1.1.1")
        #expect(LoonSRCPortRule.probeHost == "104.26.13.205")
    }

    // MARK: - 预设里读出来

    @Test func thePresetReportsWhetherTheRuleIsAlreadyThere() {
        let base = "[General]\nallow-wifi-access = true\nwifi-access-http-port = 7222\n"
        let withRule = base + "[Rule]\nSRC-PORT,41500-41599,Proxy\nFINAL,Final\n"
        let without = base + "[Rule]\nFINAL,Final\n"
        let url = URL(string: "http://192.168.124.55:7222/loonapi/v1/config/file.conf")!
        #expect(LoonPreset.parse(withRule, host: "192.168.124.55", source: url).portRule == .atTop)
        #expect(LoonPreset.parse(without, host: "192.168.124.55", source: url).portRule == .missing)
    }

    @Test func aConfigWithoutTheRuleExplainsWhySomeSourcesGoDirect() {
        // 没有端口规则时，用户的症状是「配了代理，国内源还是直连」。提示必须说清这一点，
        // 而不是笼统地说「Loon 会按自己的规则走」。
        let conf = "[General]\nallow-wifi-access = true\n[Rule]\nFINAL,Final\n"
        let url = URL(string: "http://x:7222/loonapi/v1/config/file.conf")!
        let preset = LoonPreset.parse(conf, host: "x", source: url)
        let caveat = try! #require(preset.caveat)
        #expect(caveat.contains("SRC-PORT"))
    }

    @Test func aConfigWithTheRuleDoesNotWarnAboutItAnyMore() {
        let conf = "[General]\nallow-wifi-access = true\n[Rule]\nSRC-PORT,41500-41599,Proxy\nFINAL,Final\n"
        let url = URL(string: "http://x:7222/loonapi/v1/config/file.conf")!
        let preset = LoonPreset.parse(conf, host: "x", source: url)
        #expect(preset.caveat?.contains("SRC-PORT") != true)
    }
}
