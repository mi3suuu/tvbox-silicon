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
    @Test func aRemoteProxyHostIsLeftAlone() {
        #expect(LocalNetwork.dialHost(forProxyHost: "192.168.1.9") == "192.168.1.9")
    }

    /// 回环且拿得到局域网地址 → 换成局域网地址。
    @Test func aLoopbackProxyIsDialledOverTheLAN() {
        guard LocalNetwork.currentIPv4 != nil else { return }   // 只跑在真的连着网的机器上
        let dialled = LocalNetwork.dialHost(forProxyHost: "127.0.0.1")
        #expect(dialled != "127.0.0.1")
        #expect(!LocalNetwork.isLoopback(dialled))
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

    /// 局域网地址连不通时退回回环，并且**记住**，后面的请求不再先失败一次。
    @Test func aFailedLANAttemptFallsBackAndStaysThere() {
        let endpoint = CustomProxyEndpoint(name: "Loon", scheme: .socks5, host: "127.0.0.1", port: 7221)
        defer { ProxyDialHost.forget(endpoint) }
        guard LocalNetwork.currentIPv4 != nil else { return }

        #expect(ProxyDialHost.primary(for: endpoint) != "127.0.0.1")
        #expect(ProxyDialHost.fallback(for: endpoint) == "127.0.0.1")

        ProxyDialHost.notePrimaryFailed(endpoint)
        #expect(ProxyDialHost.primary(for: endpoint) == "127.0.0.1",
                "已判定局域网地址不通时，后续请求应直接拨回环")
        #expect(ProxyDialHost.fallback(for: endpoint) == nil)
    }

    /// 非回环端点没有「另一条腿」可退。
    @Test func aRemoteEndpointHasNoFallback() {
        let endpoint = CustomProxyEndpoint(name: "NAS", scheme: .http, host: "192.168.1.9", port: 7890)
        #expect(ProxyDialHost.primary(for: endpoint) == "192.168.1.9")
        #expect(ProxyDialHost.fallback(for: endpoint) == nil)
    }
}
