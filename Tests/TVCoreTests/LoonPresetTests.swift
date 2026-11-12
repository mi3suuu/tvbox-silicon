import Foundation
import Testing
@testable import TVCore

/// Loon 预设解析：从 Loon 自己的配置文件里读出 LAN 代理端口与共享开关。
///
/// 判据来自对实机 LoonKit v8.0 的抓取（`wifi-access-http-port = 7222`、
/// `wifi-access-socks5-port = 7221`、`allow-wifi-access = true`），下面第一段 fixture
/// 就是那次响应的 `[General]` 部分原文。
@Suite struct LoonPresetTests {

    private let sourceURL = URL(string: "http://192.168.124.55:7222/loonapi/v1/config/file.conf")!

    private let liveGeneral = """
    # ============================================================
    # LoonKit · 融合版 v8.0
    # ============================================================

    [General]
    dns-server = 223.5.5.5,223.6.6.6
    interface-mode = auto
    allow-wifi-access = true
    wifi-access-http-port = 7222
    wifi-access-socks5-port = 7221
    test-timeout = 5

    [Proxy]
    M- 日本-优化 = VMess,p4.cnt.linuxlh.xin,16617,auto,"uuid",transport=ws

    [Proxy Group]
    Proxy = select,Auto,Fallback

    [Rule]
    DOMAIN-KEYWORD,snssdk,DIRECT
    GEOIP,CN,DIRECT,no-resolve
    FINAL,Final
    """

    @Test func readsBothPortsFromALiveConfig() {
        let preset = LoonPreset.parse(liveGeneral, host: "192.168.124.55", source: sourceURL)
        #expect(preset.host == "192.168.124.55")
        #expect(preset.httpPort == 7222)
        #expect(preset.socksPort == 7221)
        #expect(preset.sharesOnLAN)
    }

    @Test func prefersSocks5WhenItIsShared() {
        let preset = LoonPreset.parse(liveGeneral, host: "192.168.124.55", source: sourceURL)
        // SOCKS5 不重写请求行、且能带 UDP，是更干净的一条。
        #expect(preset.endpoint.scheme == .socks5)
        #expect(preset.endpoint.port == 7221)
        #expect(preset.endpoint.name == "Loon")
    }

    @Test func fallsBackToTheHTTPPortWhenSocks5IsNotShared() {
        let text = "[General]\nallow-wifi-access = true\nwifi-access-http-port = 8899\n[Rule]\nFINAL,Final\n"
        let preset = LoonPreset.parse(text, host: "10.0.0.2", source: sourceURL)
        #expect(preset.endpoint.scheme == .http)
        #expect(preset.endpoint.port == 8899)
        #expect(preset.socksPort == 0)
    }

    @Test func defaultsToLoonsOwnPortWhenTheConfigOmitsIt() {
        // 配置里不写端口时 Loon 仍按自己的默认监听；读不到不能当成 0。
        let text = "[General]\nallow-wifi-access = true\n"
        let preset = LoonPreset.parse(text, host: "10.0.0.2", source: sourceURL)
        #expect(preset.httpPort == 7222)
    }

    @Test func sharingOffIsReportedRatherThanSilentlyIgnored() {
        let text = "[General]\nallow-wifi-access = false\nwifi-access-http-port = 7222\n"
        let preset = LoonPreset.parse(text, host: "10.0.0.2", source: sourceURL)
        #expect(!preset.sharesOnLAN)
        // 没开共享时端口根本没监听，必须说出来。
        #expect(preset.caveat != nil)
    }

    @Test func theRulesCaveatIsAlwaysSaidWhenSharingIsOn() {
        let preset = LoonPreset.parse(liveGeneral, host: "192.168.124.55", source: sourceURL)
        // 实测：LAN 代理口会应用分流规则，CN 目标走直连。这是用户无法从我们界面看出来的，
        // 而它的每个症状都像是「我们的代理坏了」，所以必须写明。
        let caveat = try! #require(preset.caveat)
        #expect(!caveat.isEmpty)
    }

    @Test func aSectionHeaderIsNotMistakenForAKey() {
        // `[General]` 之后 `[Proxy]` 的键值不能被当成 general 配置读进来。
        let text = "[General]\nallow-wifi-access = true\n[Proxy]\nwifi-access-http-port = 1\n"
        let preset = LoonPreset.parse(text, host: "10.0.0.2", source: sourceURL)
        #expect(preset.httpPort == 7222)
    }

    @Test func commentsAndBlankLinesAreSkipped() {
        let text = "# allow-wifi-access = false\n\n   \n[General]\n  allow-wifi-access = true  \nwifi-access-http-port=7223\n"
        let preset = LoonPreset.parse(text, host: "10.0.0.2", source: sourceURL)
        #expect(preset.sharesOnLAN)
        #expect(preset.httpPort == 7223)
    }
}
