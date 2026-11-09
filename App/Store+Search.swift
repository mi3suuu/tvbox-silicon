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
        searchModel.search(keyword, config: config) { [hiddenSources, vault] site in
            hiddenSources.contains(site, origin: config.origin) || !vault.permits(site: site, fallback: config.origin)
        }
        section = .search
    }
}
