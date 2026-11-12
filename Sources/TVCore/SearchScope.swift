//
//  SearchScope.swift
//  TVCore
//
//  「谁参与搜索」—— 源、分组、订阅三层的开关。
//
//  为什么需要它
//  ------------
//  `SearchModel` 已经有 `excluding` 闭包（原本只用来排除「隐藏的源」与「保险库锁着的源」）。
//  用户这次要的是：**分组和源要支持管理是否参与搜索**。也就是说，除了「这条源被藏起来」
//  之外，还要能表达「这条源/这一组这次先别搜」—— 藏起来是为了看不见，不参与搜索是为了
//  **搜得准、搜得快**（一次全局搜索会把订阅里几百条源全问一遍，慢且噪声大）。
//
//  三层的层次关系（必须写清，否则会互相打架）
//  --------------------------------
//    订阅（SubscriptionEntry.address）
//      └ 分组（CustomSourceGroup.id，或 builtIn / pinned 这类系统组）
//          └ 源（Site，按 `sourceKey + origin` 识别）
//
//  一条源最终参不参与 = 它自己没被关 **且** 它所在的分组没被关 **且** 它所属订阅没被关。
//  也就是「从上往下任一关就排除」。这是包含式语义的自然读法，也和用户说的
//  「分组和源要支持管理」对得上：关掉一个分组就是整组不搜，不必逐条关。
//
//  与 `HiddenSources` 的分工
//  ------------------------
//  · `HiddenSources`：**看不见**它（列表里没有这张卡片），但仍然是可以搜到的来源吗？
//    不是 —— 它也不参与搜索，因为 `SearchModel.eligible` 会先按 hidden 过滤。
//  · 本类：**看得见**，但这次不搜。
//  两者是正交的开关，别把其中一个当成另一个用：把「不参与搜索」做成隐藏，用户就再也
//  找不到那条源了；把「隐藏」做成不参与搜索，用户会以为隐藏能提速，其实列表也空了。
//
//  存储
//  ----
//  三份集合，都是按环境分键的 `[String]`，与 `HiddenSources` 同一套做法（`EnvironmentScopedKey`）。
//  环境隔离不能漏：切环境后 A 的不参与集合如果还在，B 里那批同名源会被静默跳过 ——
//  表现是「切了个环境，搜索结果少了一半」。
//

import Foundation
import Observation

@MainActor @Observable public final class SearchScope {

    /// 不参与搜索的**源**。键格式 `origin|sourceKey`。
    private var excludedSources: [String]
    /// 不参与搜索的**分组**。放进 `CustomSourceGroup.id`、`builtIn`、`pinned` 这类组 id。
    private var excludedGroups: [String]
    /// 不参与搜索的**订阅**。放 `SubscriptionEntry.address`。
    private var excludedSubscriptions: [String]

    public private(set) var revision = 0
    private let defaults: UserDefaults

    private static let sourcesBaseKey = "searchScope.sources.v1"
    private static let groupsBaseKey = "searchScope.groups.v1"
    private static let subscriptionsBaseKey = "searchScope.subscriptions.v1"

    /// 这份开关属于哪个环境。与 `HiddenSources` 同一套分环境方式。
    public var environmentID: UUID?
    public var defaultEnvironmentID: UUID?

    private func scoped(_ base: String) -> String {
        EnvironmentScopedKey.key(base, environment: environmentID, default: defaultEnvironmentID)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        excludedSources = defaults.stringArray(forKey: Self.sourcesBaseKey) ?? []
        excludedGroups = defaults.stringArray(forKey: Self.groupsBaseKey) ?? []
        excludedSubscriptions = defaults.stringArray(forKey: Self.subscriptionsBaseKey) ?? []
    }

    /// 切环境后重新读三份集合，别把上一个环境的开关继续用在新环境上。
    public func reloadForEnvironment() {
        let sources = defaults.stringArray(forKey: scoped(Self.sourcesBaseKey)) ?? []
        let groups = defaults.stringArray(forKey: scoped(Self.groupsBaseKey)) ?? []
        let subscriptions = defaults.stringArray(forKey: scoped(Self.subscriptionsBaseKey)) ?? []
        guard sources != excludedSources || groups != excludedGroups || subscriptions != excludedSubscriptions else { return }
        excludedSources = sources
        excludedGroups = groups
        excludedSubscriptions = subscriptions
        revision += 1
    }

    /// 删掉一个环境时清掉它的三份集合，别让键活得比环境久。
    public static func delete(environment: UUID, defaults: UserDefaults = .standard, default defaultID: UUID?) {
        guard let defaultID, environment != defaultID else { return }
        for base in [sourcesBaseKey, groupsBaseKey, subscriptionsBaseKey] {
            defaults.removeObject(forKey: EnvironmentScopedKey.key(base, environment: environment, default: defaultID))
        }
    }

    // MARK: - 源

    /// 一条源的身份键。
    ///
    /// 用 `origin|sourceKey` 而不是 `Site.key`：合并订阅会给冲突的 key 改名，
    /// 而「这条源我关掉过」应当跟着源本身走，不跟着某次合并里的临时名字走。
    /// 与 `HiddenSources` 用 `EpisodeSkipSettings.scope` 是同一个理由。
    private func sourceKey(_ site: Site, origin: URL) -> String {
        "\(site.origin(or: origin).absoluteString)|\(site.sourceKey)"
    }

    public func isSourceExcluded(_ site: Site, origin: URL) -> Bool {
        excludedSources.contains(sourceKey(site, origin: origin))
    }

    public func setSourceExcluded(_ site: Site, origin: URL, excluded: Bool) {
        let key = sourceKey(site, origin: origin)
        var next = excludedSources
        if excluded { if !next.contains(key) { next.append(key) } } else { next.removeAll { $0 == key } }
        guard next != excludedSources else { return }
        excludedSources = next
        defaults.set(next, forKey: scoped(Self.sourcesBaseKey))
        revision += 1
    }

    /// 一批源一起开关：一次保存、一次 revision。
    public func setSourcesExcluded(_ sites: [Site], origin: URL, excluded: Bool) {
        let keys = Set(sites.map { sourceKey($0, origin: origin) })
        var next = excludedSources
        if excluded {
            for key in keys where !next.contains(key) { next.append(key) }
        } else {
            next.removeAll { keys.contains($0) }
        }
        guard next != excludedSources else { return }
        excludedSources = next
        defaults.set(next, forKey: scoped(Self.sourcesBaseKey))
        revision += 1
    }

    // MARK: - 分组

    public func isGroupExcluded(_ id: String) -> Bool { excludedGroups.contains(id) }

    public func setGroupExcluded(_ id: String, excluded: Bool) {
        var next = excludedGroups
        if excluded { if !next.contains(id) { next.append(id) } } else { next.removeAll { $0 == id } }
        guard next != excludedGroups else { return }
        excludedGroups = next
        defaults.set(next, forKey: scoped(Self.groupsBaseKey))
        revision += 1
    }

    // MARK: - 订阅

    public func isSubscriptionExcluded(_ address: String) -> Bool {
        excludedSubscriptions.contains(address)
    }

    public func setSubscriptionExcluded(_ address: String, excluded: Bool) {
        var next = excludedSubscriptions
        if excluded { if !next.contains(address) { next.append(address) } } else { next.removeAll { $0 == address } }
        guard next != excludedSubscriptions else { return }
        excludedSubscriptions = next
        defaults.set(next, forKey: scoped(Self.subscriptionsBaseKey))
        revision += 1
    }

    // MARK: - 汇总

    /// 这条源最终参不参与搜索 —— **只看本类管的三个开关**。
    ///
    /// 调用方还要再叠「隐藏的源」与「保险库」两道，那两道在 `Store.searchVideos` 里。
    ///
    /// - Parameters:
    ///   - groupID: 它所在分组的 id（`SourceGroup.id`）。调用方从已算好的分组里取，
    ///     不要在这里反查 —— 反查要重算整张分组表，而搜索一次要问几百条源。
    ///   - subscriptionAddress: 它所属订阅的地址（`SubscriptionEntry.address`）。
    public func permits(_ site: Site, origin: URL, groupID: String?, subscriptionAddress: String?) -> Bool {
        if let subscriptionAddress, isSubscriptionExcluded(subscriptionAddress) { return false }
        if let groupID, isGroupExcluded(groupID) { return false }
        return !isSourceExcluded(site, origin: origin)
    }

    // MARK: - iCloud 同步（与 HiddenSources 同一形态）

    public var savedSourceKeys: [String] { excludedSources }
    public var savedGroupKeys: [String] { excludedGroups }
    public var savedSubscriptionKeys: [String] { excludedSubscriptions }

    public func adoptSources(_ keys: [String]) {
        guard keys != excludedSources else { return }
        excludedSources = keys
        defaults.set(keys, forKey: scoped(Self.sourcesBaseKey))
        revision += 1
    }

    public func adoptGroups(_ keys: [String]) {
        guard keys != excludedGroups else { return }
        excludedGroups = keys
        defaults.set(keys, forKey: scoped(Self.groupsBaseKey))
        revision += 1
    }

    public func adoptSubscriptions(_ keys: [String]) {
        guard keys != excludedSubscriptions else { return }
        excludedSubscriptions = keys
        defaults.set(keys, forKey: scoped(Self.subscriptionsBaseKey))
        revision += 1
    }
}
