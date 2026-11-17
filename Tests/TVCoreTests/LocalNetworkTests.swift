import Foundation
import Testing
@testable import TVCore

/// 「拨代理该用哪个地址」的判定。
///
/// 这一组锁的是 2026-11-17 实测出来的那条结论：Loon 的 `SRC-PORT` 规则只对**局域网**
/// 来的连接生效。同一台 iPhone、同一个 Loon、同一个目标：
///
/// ```
/// 本机直连                    → 112.47.166.102
/// LAN 地址 + 源端口 41521     → 50.7.250.106   （节点）
/// LAN 地址 + 源端口 41621     → 112.47.166.102 （直连）
/// ```
///
/// 端点写 `127.0.0.1` 时连接照样成功（Loon 监听所有接口），所以日志里一片
/// `proxy=Loon src=:415xx` 看起来没问题 —— 但请求从回环进来，规则不参与，原样透传。
@Suite struct LocalNetworkTests {

    /// 回环的几种写法都要认出来，否则端点照旧用回环拨。
    @Test func loopbackIsRecognised() {
        for host in ["127.0.0.1", "localhost", "LOCALHOST", "::1", "[::1]", " 127.0.0.1 "] {
            #expect(LocalNetwork.isLoopback(host), "\(host) 应被认成回环")
        }
        for host in ["192.168.1.2", "10.0.0.5", "proxy.local", "127.0.0.2"] {
            #expect(!LocalNetwork.isLoopback(host), "\(host) 不是回环")
        }
    }

    /// 非回环的原样返回 —— 观众在别的机器上跑代理就是这种情况，不该被改写。
    ///
    /// ⛔ 这条曾经红着：上一版 `plan` 把「私有网段但不是本机地址」一律改写成 `127.0.0.1`，
    ///    于是「NAS 在 192.168.1.9、手机在 192.168.124.x」这种配置被无声打死，
    ///    日志只写「连不上」。现在改为**先按存的地址拨**，拨不通才退（见下一条）。
    @Test func aRemoteProxyHostIsLeftAlone() {
        #expect(LocalNetwork.dialHost(forProxyHost: "192.168.1.9") == "192.168.1.9")
        #expect(LocalNetwork.dialHost(forProxyHost: "203.0.113.9") == "203.0.113.9")
    }

    /// 回环端点：主选就是回环（Loon 的端口默认只接受本机），局域网地址只做退路。
    ///
    /// ⛔ 反过来试过一次，真机日志点名：`Loon unreachable at 192.168.124.55:7221;
    ///    dialling 127.0.0.1 instead` —— 把局域网放前面等于每次冷启动先白等一个超时。
    @Test func aLoopbackProxyDialsLoopbackFirstAndKeepsTheLANAsFallback() {
        let planned = LocalNetwork.plan(stored: "127.0.0.1", currentIPv4: "192.168.124.6")
        #expect(planned.primary == "127.0.0.1")
        #expect(planned.fallback == "192.168.124.6")
        // 没有局域网地址时没有退路。
        #expect(LocalNetwork.plan(stored: "127.0.0.1", currentIPv4: nil).fallback == nil)
    }

    // MARK: 网卡打分

    /// Wi-Fi 的私有地址优先于别的接口。
    @Test func wifiPrivateAddressWins() {
        let wifi = LocalNetwork.rank(name: "en0", address: "192.168.124.6")
        let vm = LocalNetwork.rank(name: "vmenet0", address: "10.211.55.2")
        #expect(wifi != nil && vm != nil)
        #expect(wifi! > vm!)
    }

    /// TUN 的假地址（198.18/198.19）不能被选中 —— 拨它等于把请求塞回隧道口。
    @Test func tunAddressesAreRejected() {
        #expect(LocalNetwork.rank(name: "utun4", address: "198.18.0.1") == nil)
        #expect(LocalNetwork.rank(name: "utun5", address: "198.19.3.2") == nil)
    }

    /// 回环、自分配、非法串都不选。
    @Test func impossibleAddressesAreRejected() {
        #expect(LocalNetwork.rank(name: "lo0", address: "127.0.0.1") == nil)
        #expect(LocalNetwork.rank(name: "en0", address: "169.254.3.4") == nil)
        #expect(LocalNetwork.rank(name: "en0", address: "") == nil)
        #expect(LocalNetwork.rank(name: "en0", address: "not-an-ip") == nil)
        #expect(LocalNetwork.rank(name: "en0", address: "192.168.1.999") == nil)
    }

    // MARK: 失败回落

    /// 换网段后的端点：**先按存的地址拨**，拨不通才改拨回环，而且记住。
    ///
    /// 判据用 `plan` 的纯函数（不依赖本机当前网卡），所以断言与网络环境无关。
    @Test func aStalePrivateAddressKeepsItsTruthUntilItFails() {
        let planned = LocalNetwork.plan(stored: "192.168.124.55", currentIPv4: "172.20.10.2")
        #expect(planned.primary == "192.168.124.55", "用户填的地址不该被我们擅自改写")
        #expect(planned.fallback == "127.0.0.1", "拨不通时才退到回环")

        // 已经是本机地址：没有可退的。
        #expect(LocalNetwork.plan(stored: "172.20.10.2", currentIPv4: "172.20.10.2").fallback == nil)
        // 公网地址不动。
        let publicHost = LocalNetwork.plan(stored: "203.0.113.9", currentIPv4: "172.20.10.2")
        #expect(publicHost.primary == "203.0.113.9")
        #expect(publicHost.fallback == nil)
    }

    /// 「记下来」之后：主选直接是回环，且不再有第二层退路。
    @Test func aFailedPrimaryIsRemembered() {
        let endpoint = CustomProxyEndpoint(name: "Loon", scheme: .http, host: "192.168.199.254", port: 7221)
        defer { ProxyDialHost.forget(endpoint) }
        guard LocalNetwork.currentIPv4 != nil, LocalNetwork.currentIPv4 != endpoint.host else { return }

        #expect(ProxyDialHost.primary(for: endpoint) == endpoint.host,
                "没有失败过之前，拨的就是端点写的地址")
        #expect(ProxyDialHost.fallback(for: endpoint) == "127.0.0.1")

        ProxyDialHost.notePrimaryFailed(endpoint)
        #expect(ProxyDialHost.primary(for: endpoint) == "127.0.0.1",
                "已判定主选不通时，后续请求应直接拨回环")
        #expect(ProxyDialHost.fallback(for: endpoint) == nil, "已经在退路上，没有第二层退路")
    }

    /// 非私有、非回环的端点没有可退的。
    @Test func aPublicEndpointHasNoFallback() {
        let endpoint = CustomProxyEndpoint(name: "VPS", scheme: .http, host: "203.0.113.9", port: 7890)
        #expect(ProxyDialHost.primary(for: endpoint) == "203.0.113.9")
        #expect(ProxyDialHost.fallback(for: endpoint) == nil)
    }
}
