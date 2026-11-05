import Foundation
import TVCore

// MARK: - 订阅配置（导出 / 文件导入）

extension Store {

    /// Adds a subscription, or one spider script, from a file the viewer picked. The file is copied
    /// into the app (see `ImportedFiles`) and then added like an address.
    func importSubscriptionFile(_ file: URL) async {
        let scoped = file.startAccessingSecurityScopedResource()
        let copied = Result { try ImportedFiles.add(file) }
        if scoped { file.stopAccessingSecurityScopedResource() }
        guard case .success(let url) = copied else {
            if case .failure(let error) = copied { importError = L10n.text("Import failed: %@", error.localizedDescription) }
            return
        }
        let address = url.absoluteString, known = subscriptions.contains { $0.address == address }
        await importSubscription(address: address)
        // A file that added no subscription of its own leaves no copy behind.
        if !known, !subscriptions.contains(where: { $0.address == address }) { ImportedFiles.remove(address) }
    }

    /// A portable copy of every subscription of the active environment and its parsed content, for a
    /// file or a share. Each environment is independent, so exporting one never drags in another's
    /// subscriptions.
    func exportConfig() -> SubscriptionConfig {
        SubscriptionConfig(subscriptions: environmentSubscriptions.enumerated().map { index, entry in
            SyncedSubscription(entry: entry, rank: index, document: documents[entry.address])
        })
    }
}
