import Foundation
import TVCore

// MARK: - 源改派（拖到别的订阅 / 维护清单）

extension Store {

    /// The subscription a source currently files under, after any move.
    func reassignedAddress(_ site: Site) -> String? {
        guard let config = subscription else { return nil }
        let origin = site.origin(or: config.origin)
        return sourceReassignment.destination(address: entryAddress(of: site) ?? origin.absoluteString,
                                              sourceKey: site.sourceKey, origin: origin)
    }

    /// Drag-and-drop entry point: finds the source by its key + origin and files it under `address`.
    func reassignSourceByKey(_ key: String, origin: String, to address: String?) {
        guard let config = subscription else { return }
        let site = config.sites.first { $0.sourceKey == key && $0.origin(or: config.origin).absoluteString == origin }
        guard let site else { return }
        reassignSource(site, to: address)
    }

    /// The address of the subscription a source came from: the entry whose copy has this origin.
    func entryAddress(of site: Site) -> String? {
        guard let origin = site.provenance?.origin else { return nil }
        return subscriptions.first { documents[$0.address]?.origin == origin }?.address
    }

    /// The route a source is using right now (explicit choice, then its subscription's).
    func effectiveRoute(_ site: Site) -> SourceRoute {
        guard let config = subscription else { return .auto }
        let origin = site.origin(or: config.origin)
        let sub: SubscriptionEntry? = {
            if let po = site.provenance?.origin, let entry = subscriptions.first(where: { $0.address == po.absoluteString }) { return entry }
            return subscriptions.first { $0.address == origin.absoluteString }
        }()
        return sourceRouting.effectiveRoute(site, origin: origin, subscription: sub?.routing)
    }

    /// Whether a source's direct line is what is failing right now (drives the automatic switch).
    func directLineFailing(_ site: Site) -> Bool {
        guard let config = subscription else { return false }
        return SourceHealth.shared.failedRepeatedly(site, origin: site.origin(or: config.origin))
    }

    /// One row of the maintenance list: a move, where it came from, where it went, and whether it
    /// still describes anything.
    struct SourceMoveEntry: Identifiable {
        enum State: Equatable {
            /// The source is in its target's group now.
            case applied
            /// The target subscription was removed; the move waits for it to come back.
            case missingTarget
            /// The target subscription is switched off, so the source waits in "Other Sources".
            case targetOff
            /// The source is no longer in the feed (renamed or dropped); the move no longer applies.
            case missingSource
        }
        let move: SourceMove
        let state: State
        let ownTitle: String
        let targetTitle: String
        var id: String { move.id }
        var title: String { move.title }
    }

    /// Every recorded move, newest first, with the names as they are now.
    func sourceMoveEntries() -> [SourceMoveEntry] {
        let sites = subscription?.sites ?? []
        return sourceReassignment.moves.map { move in
            let own = subscriptions.first { $0.address == move.address }
            let target = subscriptions.first { $0.address == move.target }
            let sourceStillThere = sites.contains { $0.sourceKey == move.sourceKey && entryAddress(of: $0) == move.address }
            let state: SourceMoveEntry.State
            if own == nil || !sourceStillThere { state = .missingSource }
            else if target == nil { state = .missingTarget }
            else if target?.enabled == false { state = .targetOff }
            else { state = .applied }
            return SourceMoveEntry(move: move,
                                   state: state,
                                   ownTitle: own?.title ?? (move.address.isEmpty ? move.origin : move.address),
                                   targetTitle: target?.title ?? (move.targetName.isEmpty ? move.target : move.targetName))
        }
    }

    /// Files a moved source under another subscription, from the maintenance list.
    func moveMovedSource(_ entry: SourceMoveEntry, to target: SubscriptionEntry?) {
        guard let target else {
            undoSourceMove(entry)
            return
        }
        guard let site = subscription?.sites.first(where: { $0.sourceKey == entry.move.sourceKey && entryAddress(of: $0) == entry.move.address }) else { return }
        reassignSource(site, to: target.address)
    }

    // MARK: - 源排序

    /// Reorders the sources by what the last sweep measured: the sharpest picture first, and a source
    /// that has never been probed after every one that has. The result is saved as the viewer's own
    /// order, which is what makes it survive a subscription refreshing and a relaunch.
    ///
    /// Built-in sources keep the top of the page. They are not a subscription's rows, a probe never
    /// compares them with one, and burying Bilibili under a 480p source would read as a bug.
    func rankSourcesByMeasuredQuality() {
        guard let config = subscription else { return }
        let sites = orderedSites(config)
        let probes = SourceProbeStore.shared
        // The viewer's own order of attributes, not a preset: a list they composed and can reorder
        // is the whole point of having a ranking page.
        let ranking = resourceRanking.keys.isEmpty ? ResourceRanking.standard : resourceRanking
        let ranked = ranking.sort(sites.filter { !$0.isBuiltIn }) { site in
            guard let reading = probes.latest(sourceKey: site.sourceKey) else { return ResourceRanking.Candidate() }
            return ResourceRanking.Candidate(reading)
        }
        sourceOrder.save(sites.filter(\.isBuiltIn) + ranked, origin: config.origin)
        sourceOrder.enabled = true
        // Say what turned on: the sort reorders the sources and puts the list into the viewer's own
        // order, so a source added later stays at the end until it is probed and sorted again.
        notice = L10n.text("Sorted by measured picture quality. Custom source order is now on — new sources stay at the end until you sort again or turn the custom order off.")
    }

    /// Turns the viewer's own source order on or off. The first time, it starts from the order on
    /// screen, so nothing jumps.
    func setCustomSourceOrder(_ enabled: Bool) {
        if enabled, sourceOrder.isEmpty, let config = subscription { sourceOrder.save(automaticSites(config), origin: config.origin) }
        sourceOrder.enabled = enabled
    }

    /// Moves a source within the viewer's order; `offset` is a position in `orderedSites`, as `move(fromOffsets:toOffset:)` takes it.
    func moveSource(_ site: Site, to offset: Int) {
        guard let config = subscription else { return }
        var sites = orderedSites(config)
        guard let index = sites.firstIndex(where: { $0.id == site.id }) else { return }
        sites.move(fromOffsets: [index], toOffset: max(0, min(offset, sites.count)))
        sourceOrder.save(sites, origin: config.origin)
    }
}
