import Foundation
import Testing
@testable import TVCore

/// 自定义代理：凭据混淆编解码、路由的按源解析与持久化。
/// 隧道握手（HTTP CONNECT / SOCKS5）本身要真网络，不在这里测；这里锁定的是纯逻辑：
/// 凭据别明文落盘、旧版无标记值能读回、按源路由的读写与删除联动。
@Suite struct CustomProxyTests {

    private func clean(_ name: String) -> UserDefaults {
        let suite = "TVCoreTests.CustomProxy." + name
        let box = UserDefaults(suiteName: suite)!
        box.removePersistentDomain(forName: suite)
        return box
    }

    private let origin = URL(string: "https://sub.example/list.json")!
    private let sourceKey = "source-a"

    // MARK: - 凭据混淆

    @Test func credentialsRoundTripThroughTheObfuscationLayer() throws {
        let endpoint = CustomProxyEndpoint(name: "my proxy", scheme: .socks5, host: "1.2.3.4", port: 1080,
                                           username: "alice", password: "s3cret")
        let data = try JSONEncoder().encode([endpoint])
        let raw = String(decoding: data, as: UTF8.self)
        // 明文口令绝不落盘。
        #expect(!raw.contains("alice"))
        #expect(!raw.contains("s3cret"))

        let decoded = try JSONDecoder().decode([CustomProxyEndpoint].self, from: data)
        #expect(decoded.first?.username == "alice")
        #expect(decoded.first?.password == "s3cret")
    }

    @Test func legacyPlaintextCredentialsStillDecode() throws {
        // 旧版无 "v1:" 标记的值是明文，反混淆要原样返回而不是解出乱码。
        let json = #"[{"id":"x","name":"p","scheme":"http","host":"1.2.3.4","port":8080,"username":"bob","password":"pw"}]"#
        let decoded = try JSONDecoder().decode([CustomProxyEndpoint].self, from: Data(json.utf8))
        #expect(decoded.first?.username == "bob")
        #expect(decoded.first?.password == "pw")
    }

    @Test func anInvalidHostOrPortHasNoAddress() {
        #expect(CustomProxyEndpoint(name: "e", scheme: .http, host: "", port: 80).address == nil)
        #expect(CustomProxyEndpoint(name: "e", scheme: .http, host: "1.2.3.4", port: 0).address == nil)
        #expect(CustomProxyEndpoint(name: "e", scheme: .http, host: "1.2.3.4", port: 70000).address == nil)
        #expect(CustomProxyEndpoint(name: "e", scheme: .http, host: "1.2.3.4", port: 8080).address == "1.2.3.4")
    }

    // MARK: - 路由的按源读写

    @Test func aRouteIsReadBackPerOriginAndSource() {
        let box = clean(#function)
        let store = CustomProxyStore(defaults: box)
        let proxy = CustomProxyEndpoint(name: "p", scheme: .http, host: "1.2.3.4", port: 8080)
        store.upsert(proxy)
        store.setRoute(.proxy(proxy.id), origin: origin, sourceKey: sourceKey)
        #expect(store.route(origin: origin, sourceKey: sourceKey).proxyID == proxy.id)
        // 不同 origin 或 source 不受影响。
        #expect(store.route(origin: URL(string: "https://other.example/x.json")!, sourceKey: sourceKey) == .direct)
        #expect(store.route(origin: origin, sourceKey: "source-b") == .direct)
    }

    @Test func removingAnEndpointResetsRoutesThatUsedIt() {
        let box = clean(#function)
        let store = CustomProxyStore(defaults: box)
        let proxy = CustomProxyEndpoint(name: "p", scheme: .http, host: "1.2.3.4", port: 8080)
        store.upsert(proxy)
        store.setRoute(.proxy(proxy.id), origin: origin, sourceKey: sourceKey)
        store.removeEndpoint(id: proxy.id)
        #expect(store.route(origin: origin, sourceKey: sourceKey) == .direct)
    }

    @Test func endpointsAndRoutesSurviveRelaunch() {
        let box = clean(#function)
        let proxy = CustomProxyEndpoint(name: "p", scheme: .http, host: "1.2.3.4", port: 8080)
        let first = CustomProxyStore(defaults: box)
        first.upsert(proxy)
        first.setRoute(.proxy(proxy.id), origin: origin, sourceKey: sourceKey)

        let second = CustomProxyStore(defaults: box)
        #expect(second.endpoints.count == 1)
        #expect(second.route(origin: origin, sourceKey: sourceKey).proxyID == proxy.id)
    }

    // MARK: - 出口端点解析（纯逻辑，不连网）

    @Test func aSourceWithNoRouteHasNoEndpoint() {
        let box = clean(#function)
        let store = CustomProxyStore(defaults: box)
        #expect(store.endpoint(origin: origin, sourceKey: sourceKey) == nil)
        // 指到不存在的 proxy id 也返回 nil（路由失效回落到直连）。
        store.setRoute(.proxy("missing"), origin: origin, sourceKey: sourceKey)
        #expect(store.endpoint(origin: origin, sourceKey: sourceKey) == nil)
    }

    @Test func anAssignedRouteResolvesToItsEndpoint() {
        let box = clean(#function)
        let store = CustomProxyStore(defaults: box)
        let proxy = CustomProxyEndpoint(name: "p", scheme: .http, host: "1.2.3.4", port: 8080)
        store.upsert(proxy)
        store.setRoute(.proxy(proxy.id), origin: origin, sourceKey: sourceKey)
        #expect(store.endpoint(origin: origin, sourceKey: sourceKey)?.id == proxy.id)
    }

    // MARK: - 整表读写（整机备份 / iCloud 快照用）

    @Test func routesRoundTripThroughTheWholeTableAccessors() {
        let box = clean(#function)
        let store = CustomProxyStore(defaults: box)
        let proxy = CustomProxyEndpoint(name: "p", scheme: .socks5, host: "1.2.3.4", port: 1080)
        store.upsert(proxy)
        store.setRoute(.proxy(proxy.id), origin: origin, sourceKey: sourceKey)
        let table = store.routes
        #expect(table.count == 1)

        // 换一个实例整表写回，读到的还是同一条。
        let other = CustomProxyStore(defaults: box)
        other.replaceRoutes(table)
        #expect(other.route(origin: origin, sourceKey: sourceKey).proxyID == proxy.id)
    }

    // MARK: - 同一台代理只能有一条（2026-11-17）

    /// 点两次「添加 Loon」→ 两条 `127.0.0.1:7221`。
    ///
    /// ⛔ 这不是「列表里多一行」的小事：`fallbackEndpoint` 的规则是「只配了一台 → 它就是出口」，
    ///    两条重复记录让它变成「配了多台又没指定」→ 返回 nil → **全站直连**。
    ///    真机日志里就是这个形状：`relay listening` 出现 50+ 次，`upstream ready proxy=` 一次都没有。
    @Test func addingTheSameProxyTwiceKeepsOneEntry() {
        let store = CustomProxyStore(defaults: clean("dedupe-1"))
        store.upsert(CustomProxyEndpoint(name: "Loon", scheme: .socks5, host: "127.0.0.1", port: 7221))
        store.upsert(CustomProxyEndpoint(name: "Loon", scheme: .socks5, host: "127.0.0.1", port: 7221))

        #expect(store.endpoints.count == 1)
        // 去重之后「只配了一台」成立，默认出口才回得到它。
        #expect(store.fallbackEndpoint?.port == 7221)
    }

    /// 去重保留**原来的 id**，并把指向被删那条的路由改指过来 —— 否则源路由会一起作废。
    @Test func dedupeKeepsTheSurvivingIDAndRemapsRoutes() {
        let store = CustomProxyStore(defaults: clean("dedupe-2"))
        let first = CustomProxyEndpoint(name: "Loon", scheme: .socks5, host: "127.0.0.1", port: 7221)
        store.upsert(first)
        store.setRoute(.proxy(first.id), origin: origin, sourceKey: sourceKey)

        let duplicate = CustomProxyEndpoint(name: "Loon", scheme: .socks5, host: "127.0.0.1", port: 7221)
        store.upsert(duplicate)

        #expect(store.endpoints.count == 1)
        #expect(store.endpoints.first?.id == first.id)
        #expect(store.endpoint(origin: origin, sourceKey: sourceKey)?.id == first.id)
    }

    /// 名字不同、但协议/主机/端口相同 → 仍是同一台（引号里的名字不该造出第二台机器）。
    @Test func sameAddressUnderAnotherNameIsStillOneEntry() {
        let store = CustomProxyStore(defaults: clean("dedupe-3"))
        store.upsert(CustomProxyEndpoint(name: "Loon", scheme: .socks5, host: "127.0.0.1", port: 7221))
        store.upsert(CustomProxyEndpoint(name: "Loon (家里)", scheme: .socks5, host: "127.0.0.1", port: 7221))
        #expect(store.endpoints.count == 1)
        #expect(store.endpoints.first?.name == "Loon (家里)")
    }

    /// 不同端口的代理是两台，不能并掉。
    @Test func differentPortsStaySeparate() {
        let store = CustomProxyStore(defaults: clean("dedupe-4"))
        store.upsert(CustomProxyEndpoint(name: "A", scheme: .socks5, host: "127.0.0.1", port: 7221))
        store.upsert(CustomProxyEndpoint(name: "B", scheme: .http, host: "127.0.0.1", port: 7222))
        #expect(store.endpoints.count == 2)
        // 两台又没指定默认出口 → 不替观众挑。
        #expect(store.fallbackEndpoint == nil)
    }
}
