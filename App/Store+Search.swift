import Foundation
import TVCore

// MARK: - 搜索

extension Store {

    /// Sources a search or a recommendation may fan out to.
    func searchableSites(_ sites: [Site], origin: URL) -> [Site] {
        sites.filter { maySee($0, origin: origin) }
    }

    /// 搜索历史的 UserDefaults key，按环境分键。
    ///
    /// 默认环境继续用历史 key `videoSearchHistory`（兼容 environments 出现之前的旧记录）；
    /// 其余环境用 `videoSearchHistory.<uuid>`，各自独立、互不串台。
    /// 与 `DiscoveryView` 读历史时用同一个 key（见 `store.searchHistory`），不能两处各写一套。
    var searchHistoryKey: String {
        let active = environments.activeID
        let isDefault = active == environments.all.first?.id
        return isDefault ? "videoSearchHistory" : "videoSearchHistory.\(active.uuidString)"
    }

    /// 当前环境的搜索历史（[String]，最多 20 条）。
    var searchHistory: [String] {
        defaults.data(forKey: searchHistoryKey)
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }

    /// 写当前环境的搜索历史。`DiscoveryView` 的增/删/清空都走这里，
    /// 保证读（`searchHistory`）和写（`setSearchHistory`）用同一个按环境分键的 key。
    func setSearchHistory(_ history: [String]) {
        defaults.set(try? JSONEncoder().encode(history), forKey: searchHistoryKey)
        persistKeychainBackup()
    }

    func searchVideos(_ title: String) {
        guard let config = subscription else { return }
        let keyword = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        let old = searchHistory
        defaults.set(try? JSONEncoder().encode(Array(([keyword] + old.filter { $0 != keyword }).prefix(20))), forKey: searchHistoryKey)
        persistKeychainBackup()
        // 把「哪些源该被跳过」的三层开关合成一张表，闭包只查表 —— 不查表就要为
        // 每次判定反算分组（一次搜索几百条源，那等于把分组表重算几百遍）。
        let scopeIndex = searchScopeIndex()
        searchModel.search(keyword, config: config) { [hiddenSources, vault, searchScope] site in
            // ① 看不见的源不搜（`HiddenSources` 与隐私保险库）—— 与上游同义，别删。
            if hiddenSources.contains(site, origin: config.origin) { return true }
            if !vault.permits(site: site, fallback: config.origin) { return true }
            // ② 用户显式关掉「参与搜索」的源 / 分组 / 订阅。
            let group = scopeIndex.groupOf(site)
            let address = scopeIndex.addressOf(site)
            return !searchScope.permits(site, origin: config.origin, groupID: group, subscriptionAddress: address)
        }
        section = .search
    }

    /// 把「源 → 所在分组 / 所属订阅」预先算成两张表。
    ///
    /// 为什么不在闭包里现算：`excluding` 是**每条源调一次**的谓词，而反查分组要遍历
    /// `sourceGroups()`（它对几百条源做一次完整分组，本身是重活）。搜索一次几百条源，
    /// 现算就是几百次全量分组。这里建两张字典，闭包变成 O(1) 查表。
    ///
    /// 键用 `origin|sourceKey`（与 `SearchScope` 内部一致），不用 `Site.key`：
    /// 合并订阅会重命名冲突的 key，「这条源属于哪一组」必须跟着源本身走。
    /// 放宽到 internal：`DiscoveryView.submit`（搜索页主入口）也要用它。
    /// 两个入口各算一张表，比让其中一个漏掉开关安全 —— 见那里的注释。
    func searchScopeIndex() -> (groupOf: (Site) -> String?, addressOf: (Site) -> String?) {
        guard let config = subscription else { return ({ _ in nil }, { _ in nil }) }
        var group: [String: String] = [:]
        var address: [String: String] = [:]
        for g in sourceGroups(includeHidden: true) {
            for site in g.sites {
                let key = "\(site.origin(or: config.origin).absoluteString)|\(site.sourceKey)"
                if group[key] == nil { group[key] = g.id }
            }
        }
        for entry in environmentSubscriptions {
            guard let document = documents[entry.address] else { continue }
            for site in document.sites {
                let key = "\(site.origin(or: document.origin).absoluteString)|\(site.sourceKey)"
                if address[key] == nil { address[key] = entry.address }
            }
        }
        let origin = config.origin
        return ({ site in group["\(site.origin(or: origin).absoluteString)|\(site.sourceKey)"] },
                { site in address["\(site.origin(or: origin).absoluteString)|\(site.sourceKey)"] })
    }
}
