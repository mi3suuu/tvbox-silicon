import Foundation
import TVCore

// MARK: - 搜索

extension Store {

    /// Sources a search or a recommendation may fan out to.
    func searchableSites(_ sites: [Site], origin: URL) -> [Site] {
        sites.filter { maySee($0, origin: origin) }
    }

    func searchVideos(_ title: String) {
        guard let config = subscription else { return }
        let keyword = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        let old = defaults.data(forKey: "videoSearchHistory").flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        defaults.set(try? JSONEncoder().encode(Array(([keyword] + old.filter { $0 != keyword }).prefix(20))), forKey: "videoSearchHistory")
        persistKeychainBackup()
        searchModel.search(keyword, config: config) { [hiddenSources, vault] site in
            hiddenSources.contains(site, origin: config.origin) || !vault.permits(site: site, fallback: config.origin)
        }
        section = .search
    }
}
