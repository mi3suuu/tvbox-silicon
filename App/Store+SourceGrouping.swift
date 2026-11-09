import Foundation
import TVCore

/// Filing many sources at once.
///
/// Every one of these ends in `reassignSource`, the same call a drag onto another group's header
/// makes, so a batch is exactly a drag repeated — nothing here is a second way to store a move. That
/// matters for the safety net: "Put Every Source Back" on the Moved Sources page undoes a batch as
/// readily as it undoes a drag, and a subscription refresh cannot lose either.
extension Store {

    /// The sources this group shows, in the order the page shows them.
    func sources(inGroup id: String, includeHidden: Bool = false) -> [Site] {
        sourceGroups(includeHidden: includeHidden).first { $0.id == id }?.sites ?? []
    }

    /// Adds a group, or hands back the one that already has that name.
    @discardableResult
    func createSourceGroup(named name: String) -> CustomSourceGroup? {
        sourceGroupBook.add(name: name)
    }

    /// Files `sites` under one of the viewer's groups.
    @discardableResult
    func fileSources(_ sites: [Site], intoGroup id: String) -> Int {
        guard let group = sourceGroupBook.group(id) else { return 0 }
        for site in sites { reassignSource(site, to: group.target) }
        return sites.count
    }

    /// Files `sites` under another subscription — the batch form of dragging them onto its header.
    @discardableResult
    func fileSources(_ sites: [Site], underSubscription address: String) -> Int {
        for site in sites { reassignSource(site, to: address) }
        return sites.count
    }

    /// Sends `sites` back to the subscription they came from — the move is deleted, not rewritten.
    @discardableResult
    func returnSourcesToTheirSubscription(_ sites: [Site]) -> Int {
        for site in sites { reassignSource(site, to: nil) }
        return sites.count
    }

    /// Writes down what the sweep found: the sources that answered go under `reachableName`, the ones
    /// that did not under `unreachableName`, each group created when it is missing.
    ///
    /// Sources with no reading are left where they are. Filing an unmeasured source as dead would be a
    /// guess, and the one thing worse than a slow source is a working one hidden in "不通".
    @discardableResult
    func fileByReachability(_ sites: [Site], reachableName: String, unreachableName: String) -> (reachable: Int, unreachable: Int) {
        let probes = SourceProbeStore.shared
        var answered: [Site] = []
        var silent: [Site] = []
        for site in sites {
            guard let probe = probes.latest(sourceKey: site.sourceKey) else { continue }
            if probe.reachability == .unreachable { silent.append(site) } else { answered.append(site) }
        }
        var result = (reachable: 0, unreachable: 0)
        if !answered.isEmpty, let group = sourceGroupBook.add(name: reachableName) {
            result.reachable = fileSources(answered, intoGroup: group.id)
        }
        if !silent.isEmpty, let group = sourceGroupBook.add(name: unreachableName) {
            result.unreachable = fileSources(silent, intoGroup: group.id)
        }
        return result
    }
}
