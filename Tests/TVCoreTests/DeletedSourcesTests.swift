import Foundation
import Testing
@testable import TVCore

private let origin = URL(string: "https://one.example/a.json")!
private func source(_ key: String) -> Site {
    Site(key: key, name: key, type: 1, api: "https://api.example/" + key, raw: ["key": .string(key)])
}
private func suite(_ tag: String) -> String { "deleted.\(tag)." + UUID().uuidString }

@Test @MainActor func deletedSourcesPersistAndStayQualifiedBySubscription() throws {
    let name = suite("basic")
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let site = source("a")

    let deleted = DeletedSources(defaults: defaults)
    #expect(!deleted.contains(site, origin: origin))
    deleted.insert(site, origin: origin)
    #expect(deleted.contains(site, origin: origin))
    // 换一个订阅（origin 不同）同名 key 不算删过 —— 这正是 `origin|sourceKey` 键的意义。
    #expect(!deleted.contains(site, origin: URL(string: "https://other.example/a.json")!))
    // 落盘：新实例从 defaults 读回来仍然记着。
    #expect(DeletedSources(defaults: defaults).contains(site, origin: origin))
}

@Test @MainActor func insertingTwiceIsIdempotentAndBumpsOncePerChange() throws {
    let name = suite("idempotent")
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let site = source("a")
    let deleted = DeletedSources(defaults: defaults)

    deleted.insert(site, origin: origin)
    let after = deleted.revision
    deleted.insert(site, origin: origin)
    // 重复插入不该再涨 revision —— 否则每次重建列表都会误判「有变化」。
    #expect(deleted.revision == after)
    #expect(deleted.savedKeys.count == 1)
}

/// `forget` 撤销删除记账：删订阅后重加同一地址，那批源必须能回来。
///
/// 键里存的是 `site.origin(or:)`（重定向后的落地地址），而调用方手里可能只有用户输入的地址，
/// 所以 `forget(origins:)` 接受一组地址。这里锁住两条：
/// 传落地地址能清掉；传不相干的地址不会误删。
@Test @MainActor func forgetClearsOnlyTheNamedOrigins() throws {
    let name = suite("forget")
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let a = source("a"), b = source("b")
    let other = URL(string: "https://other.example/a.json")!
    let deleted = DeletedSources(defaults: defaults)

    deleted.insert(a, origin: origin)
    deleted.insert(b, origin: other)
    #expect(deleted.savedKeys.count == 2)

    // 只清 origin 那一批；other 的记账必须留着。
    deleted.forget(origins: [origin])
    #expect(!deleted.contains(a, origin: origin))
    #expect(deleted.contains(b, origin: other))

    // 空集合不能把全部清光（那是「删订阅时没拿到地址」的退化情形，宁可不删）。
    deleted.forget(origins: [])
    #expect(deleted.contains(b, origin: other))
}

/// 删订阅时，`entry.address` 与「解析后落地地址」可能不同（重定向 / 镜像 / http→https）。
/// `forget` 必须两个都试，否则重定向类订阅的真删记账永远清不掉 —— 源永久隐形且无入口可救。
@Test @MainActor func forgetAcceptsBothTypedAndLandedAddresses() throws {
    let name = suite("forget.both")
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let typed = URL(string: "http://mirror.example/sub.json")!
    let landed = URL(string: "https://cdn.example/sub.json")!
    let site = source("a")
    let deleted = DeletedSources(defaults: defaults)

    // 源实际记在落地地址下。
    deleted.insert(site, origin: landed)
    // 恢复时同时给出两个地址 —— 能命中。
    deleted.forget(origins: [typed, landed])
    #expect(!deleted.contains(site, origin: landed))
}

/// 真删与隐藏是两份账：删源必须同时写两边，而 `forget` 只动真删那一份。
/// 锁住「只清隐藏会留下真删标记、只清真删会留下隐藏标记」这两个方向。
@Test @MainActor func deletingWritesBothRecordsAndForgetOnlyClearsTheDeletedOne() throws {
    let name = suite("both.records")
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let site = source("a")
    let hidden = HiddenSources(defaults: defaults)
    let deleted = DeletedSources(defaults: defaults)

    // 模拟 `Store.deleteSite` 的写入顺序。
    deleted.insert(site, origin: origin)
    hidden.insert(site, origin: origin)
    #expect(deleted.contains(site, origin: origin))
    #expect(hidden.contains(site, origin: origin))

    // `forget` 只清真删记账，隐藏标记仍在 —— 这是有意的：撤销删除后源应回到「已隐藏」，
    // 由用户在「已隐藏」里自己决定要不要显示，不该凭空出现在主列表。
    deleted.forget(origins: [origin])
    #expect(!deleted.contains(site, origin: origin))
    #expect(hidden.contains(site, origin: origin))
}

/// 多环境隔离：同一个 `origin|sourceKey` 在两个环境下必中同一把键，
/// 所以每个环境必须读自己那一份，否则在 A 删的源会在 B 也消失。
@Test @MainActor func environmentsDoNotShareDeletions() throws {
    let name = suite("env")
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let site = source("a")
    let envA = UUID(), envB = UUID()
    let deleted = DeletedSources(defaults: defaults)

    deleted.defaultEnvironmentID = envA
    deleted.environmentID = envA
    deleted.reloadForEnvironment()
    deleted.insert(site, origin: origin)
    #expect(deleted.contains(site, origin: origin))

    // 切到 B：B 里这条源没被删过。
    deleted.environmentID = envB
    deleted.reloadForEnvironment()
    #expect(!deleted.contains(site, origin: origin))

    // 切回 A：记录还在。
    deleted.environmentID = envA
    deleted.reloadForEnvironment()
    #expect(deleted.contains(site, origin: origin))

    // 删环境要把它的记账清掉，否则孤儿 key 永久残留。
    DeletedSources.delete(environment: envA, defaults: defaults, default: envB)
    let fresh = DeletedSources(defaults: defaults)
    fresh.defaultEnvironmentID = envB
    fresh.environmentID = envA
    fresh.reloadForEnvironment()
    #expect(!fresh.contains(site, origin: origin))
}

/// 备份通道：`deletedSources.v1` 必须走 **scalarKeys**，不能走 `dataKeys`。
///
/// `dataKeys` 用 `defaults.data(forKey:)` 读写，而对 `set([String], forKey:)` 存进去的数组
/// 该调用**恒返回 nil**（本测试第二段就是实测这条前提）。放错通道 = 整机备份静默丢删除标记，
/// 换机恢复后用户删掉的源以「已隐藏」形式回来。
@Test func deletedSourcesKeyIsOnTheScalarChannelNotTheDataChannel() {
    #expect(FullBackupDefaults.scalarKeys.contains("deletedSources.v1"))
    #expect(!FullBackupDefaults.dataKeys.contains("deletedSources.v1"))
}

/// 锁住 `dataKeys` 通道的先天限制，防止有人再把数组类键塞回去。
@Test @MainActor func arrayValuesAreInvisibleToTheDataChannel() throws {
    let name = suite("channel")
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(["a", "b"], forKey: "probe")
    // 这就是 `dataKeys` 那条路读不到数组的原因。
    #expect(defaults.data(forKey: "probe") == nil)
    #expect(defaults.stringArray(forKey: "probe") == ["a", "b"])
}

/// 裁剪：订阅不再存在时，它名下那批真删记账要能被回收，否则只增不减。
@Test @MainActor func pruneDropsKeysForVanishedSubscriptions() throws {
    let name = suite("prune")
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let kept = source("a"), gone = source("b")
    let goneOrigin = URL(string: "https://gone.example/a.json")!
    let deleted = DeletedSources(defaults: defaults)

    deleted.insert(kept, origin: origin)
    deleted.insert(gone, origin: goneOrigin)
    #expect(deleted.savedKeys.count == 2)

    deleted.prune(live: [origin.absoluteString])
    #expect(deleted.contains(kept, origin: origin))
    #expect(!deleted.contains(gone, origin: goneOrigin))

    // 空集合是「还没算出来」，不能把全部清光。
    deleted.prune(live: [])
    #expect(deleted.contains(kept, origin: origin))
}
