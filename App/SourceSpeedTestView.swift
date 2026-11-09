import SwiftUI
import TVCore

/// Measures sources the way the phone will use them, and files them where the reading says they
/// belong: one shot for a whole group, one button to move the survivors into "可用" and the silent
/// ones into "不通", and a way to move any selection anywhere else.
///
/// What was already here
/// ---------------------
/// The probe engine (`SourceProbeRunner`), the reading cache (`SourceProbeStore`), the sweep
/// (`Store.startProbing`), the per-source route (`SourceRouting`), the viewer's order (`SourceOrder`)
/// and the move store behind "drag onto a group's header" (`SourceReassignment`) all existed with no
/// door. This page is the door: it reads and writes those stores and adds only one thing they lacked,
/// the viewer's own groups (`SourceGroupBook`).
///
/// Why a batch is just a drag
/// --------------------------
/// Filing many sources calls `reassignSource`, the same function a drag calls, once per source. So
/// "Put Every Source Back" on the Moved Sources page undoes a sweep's filing as easily as it undoes a
/// drag, and a subscription refresh cannot lose either.
///
/// What "route" means here
/// -----------------------
/// A route changes the address a source's *API* is fetched from: direct is its own `api` as imported,
/// proxy rewrites it through the relay. Media segments come from the source's own CDN and are not
/// rewritten, so a source whose API answers but whose segments are blocked needs hiding or filing,
/// not routing. The footer says so rather than implying more.
struct SourceSpeedTestView: View {
    @Environment(Store.self) private var store

    /// Bumped after a sweep so the rows re-read `SourceProbeStore`: it is a plain dictionary behind
    /// UserDefaults, not observable, and a page that only read it on appear would keep showing the
    /// numbers from before the sweep.
    @State private var readings = 0
    @State private var filter: Filter = .all
    /// "" is the whole list; otherwise a group id (`group:<uuid>`) or a subscription address.
    @State private var scopeID = ""
    @State private var picked: Set<String> = []
    @State private var notice: String?
    @State private var naming = false
    @State private var draftName = ""
    /// Set when the name sheet was opened from the move menu: the new group is filled straight away.
    @State private var fileAfterNaming = false

    private enum Filter: String, CaseIterable, Identifiable {
        case all, measured, unreachable
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return L10n.text("All")
            case .measured: return L10n.text("Measured")
            case .unreachable: return L10n.text("Unreachable")
            }
        }
    }

    /// One scope the sweep and the filing act on.
    private struct Scope: Identifiable {
        let id: String
        let title: String
        let sites: [Site]
    }

    /// One line on the page. The id is subscription-qualified: two feeds may carry the same key, and
    /// `Site.id` alone would make SwiftUI draw one of them twice.
    private struct Row: Identifiable {
        let site: Site
        let feed: String
        let group: String?
        let address: String
        let probe: SourceProbeResult?
        let route: SourceRoute
        var id: String { address + "|" + site.sourceKey }
    }

    var body: some View {
        Form {
            Section {
                scopePicker
                measureButton
                partitionButton
                newGroupButton
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text(L10n.text("Group"))
            } footer: {
                Text(L10n.text("A sweep asks each source for its newest video and reads a few hundred kilobytes of its first playable line; that is where the speed and the resolution come from. One request per source, so run it on the network you care about. Filing keeps what the sweep found: answered sources into one group, silent ones into another, unmeasured ones left alone."))
            }

            Section {
                moveControls
            } header: {
                Text(L10n.text("Move"))
            } footer: {
                Text(L10n.text("Tick sources to move just those; with nothing ticked the move applies to everything in the scope above. A move only changes which group lists a source — it still plays through its own subscription, and it survives a refresh."))
            }

            Section {
                Picker(L10n.text("Show"), selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                #if os(iOS)
                .pickerStyle(.segmented)
                #endif
            }

            Section {
                ForEach(rows) { row in
                    line(row)
                }
            } header: {
                Text(L10n.text("Sources"))
            } footer: {
                Text(L10n.text("The route menu pins one source to Direct or Proxy; Auto follows what the last requests managed to reach. Ordering by measured speed bakes the sweep into your own order, which the Sources page then follows."))
            }
        }
        .settingsPage()
        .settingsForm(L10n.text("Source Speed Test"))
        // `probeRun` is observable; the readings behind it are not. Re-reading on every progress tick
        // keeps the rows in step with the sweep instead of jumping only when it finishes.
        .onChange(of: store.probeRun) { _, _ in readings += 1 }
        .onChange(of: scopeID) { _, _ in picked.removeAll() }
        .sheet(isPresented: $naming) { namingSheet }
    }

    // MARK: - Scope

    /// Every listed source once, in the viewer's order — the scope the "全部源" row stands for.
    private var allSites: [Site] {
        guard let config = store.subscription else { return [] }
        return store.orderedSites(config)
    }

    private var scopes: [Scope] {
        var list = [Scope(id: "", title: L10n.text("All Sources"), sites: allSites)]
        for group in store.sourceGroups(includeHidden: false) where group.kind != .hidden {
            switch group.kind {
            case .custom, .subscription:
                list.append(Scope(id: group.id, title: group.title, sites: group.sites))
            case .pinned, .builtIn, .other, .hidden:
                continue
            }
        }
        return list
    }

    private var scope: Scope {
        scopes.first { $0.id == scopeID } ?? scopes[0]
    }

    private var scopePicker: some View {
        Picker(L10n.text("Measure and file"), selection: $scopeID) {
            ForEach(scopes) { scope in
                Text(scope.title + " · " + String(scope.sites.count)).tag(scope.id)
            }
        }
    }

    /// What a move or a filing acts on: the ticked sources, or the whole scope when nothing is ticked.
    private var targets: [Site] {
        picked.isEmpty ? scope.sites : scope.sites.filter { picked.contains($0.id) }
    }

    private var scopeSummary: String {
        picked.isEmpty
            ? L10n.text("%lld sources in scope", scope.sites.count)
            : L10n.text("%lld of %lld ticked", picked.count, scope.sites.count)
    }

    // MARK: - Actions

    @ViewBuilder
    private var measureButton: some View {
        if let run = store.probeRun {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(run.done), total: Double(max(run.total, 1)))
                HStack {
                    Text(L10n.text("%lld of %lld measured", run.done, run.total))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("Stop")) { store.cancelProbingAllSources() }
                        .buttonStyle(.plain)
                }
            }
        } else {
            Button {
                store.startProbing(targets)
            } label: {
                Label(picked.isEmpty ? L10n.text("Probe This Group") : L10n.text("Probe the Ticked Sources"),
                      systemImage: "speedometer")
            }
            .disabled(targets.isEmpty)

            Button {
                sortByMeasurement()
            } label: {
                Label(L10n.text("Order by Measured Speed"), systemImage: "arrow.up.arrow.down")
            }
            .disabled(measuredCount == 0)

            if !allSites.isEmpty {
                Text(tally).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var partitionButton: some View {
        Button {
            let result = store.fileByReachability(targets,
                                                  reachableName: L10n.text("Reachable Group"),
                                                  unreachableName: L10n.text("Unreachable Group"))
            notice = L10n.text("Filed %lld answered and %lld silent sources; unmeasured ones were left where they were.",
                               result.reachable, result.unreachable)
        } label: {
            Label(L10n.text("File by Reachability"), systemImage: "square.split.2x1")
        }
        .disabled(measuredCount == 0)
    }

    private var newGroupButton: some View {
        Button {
            fileAfterNaming = false
            draftName = ""
            naming = true
        } label: {
            Label(L10n.text("New Group"), systemImage: "folder.badge.plus")
        }
    }

    @ViewBuilder
    private var moveControls: some View {
        Text(scopeSummary).font(.caption).foregroundStyle(.secondary)

        Menu {
            if !store.sourceGroupBook.groups.isEmpty {
                Section(L10n.text("Your Groups")) {
                    ForEach(store.sourceGroupBook.groups) { group in
                        Button(group.name) {
                            let count = store.fileSources(targets, intoGroup: group.id)
                            notice = L10n.text("Moved %lld sources into %@.", count, group.name)
                        }
                    }
                }
            }
            Section(L10n.text("Subscriptions")) {
                ForEach(store.environmentSubscriptions.filter(\.enabled)) { entry in
                    Button(entry.title) {
                        let count = store.fileSources(targets, underSubscription: entry.address)
                        notice = L10n.text("Moved %lld sources into %@.", count, entry.title)
                    }
                }
            }
            Section {
                Button {
                    fileAfterNaming = true
                    draftName = ""
                    naming = true
                } label: {
                    Label(L10n.text("New Group…"), systemImage: "folder.badge.plus")
                }
                Button {
                    let count = store.returnSourcesToTheirSubscription(targets)
                    notice = L10n.text("Sent %lld sources back to their own subscription.", count)
                } label: {
                    Label(L10n.text("Back to Their Subscription"), systemImage: "arrow.uturn.backward")
                }
            }
        } label: {
            Label(L10n.text("Move to…"), systemImage: "arrow.right.square")
        }
        .disabled(targets.isEmpty)

        HStack {
            Button(picked.isEmpty ? L10n.text("Tick All in Scope") : L10n.text("Clear Ticks")) {
                if picked.isEmpty { picked = Set(scope.sites.map(\.id)) } else { picked.removeAll() }
            }
            .buttonStyle(.plain)
            .font(.caption)
            Spacer()
        }
    }

    private var namingSheet: some View {
        Form {
            Section {
                TextField(L10n.text("Group name"), text: $draftName)
            } header: {
                Text(L10n.text("New Group"))
            } footer: {
                Text(L10n.text("A group of your own sits above the subscriptions. Sources filed into it stay playable through their own feed."))
            }
            Section {
                Button(L10n.text("Create")) {
                    guard let group = store.createSourceGroup(named: draftName) else { naming = false; return }
                    if fileAfterNaming {
                        let count = store.fileSources(targets, intoGroup: group.id)
                        notice = L10n.text("Moved %lld sources into %@.", count, group.name)
                    } else {
                        notice = L10n.text("%@ is ready — move sources into it below.", group.name)
                    }
                    naming = false
                }
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(L10n.text("Cancel"), role: .cancel) { naming = false }
            }
        }
        .settingsPage()
        .settingsForm(L10n.text("New Group"))
    }

    // MARK: - Tally

    /// "28 of 353 measured · 6 unreachable · fastest 676 KB/s" — the one line that says whether the
    /// list below is worth reading.
    private var tally: String {
        let rows = allRows
        let measured = rows.filter { $0.probe != nil }
        let dead = measured.filter { $0.probe?.reachability == .unreachable }
        let fastest = measured.compactMap(\.probe?.kilobytesPerSecond).max() ?? 0
        return L10n.text("%lld of %lld measured · %lld unreachable · fastest %lld KB/s",
                         measured.count, rows.count, dead.count, fastest)
    }

    private var measuredCount: Int { allRows.filter { $0.probe != nil }.count }

    // MARK: - Rows

    private var rows: [Row] {
        _ = readings  // re-read the probe cache whenever it may have changed
        let list = allRows
        switch filter {
        case .all: return list
        case .measured: return list.filter { $0.probe != nil }
        case .unreachable: return list.filter { $0.probe?.reachability == .unreachable }
        }
    }

    private var allRows: [Row] {
        guard let config = store.subscription else { return [] }
        let probes = SourceProbeStore.shared
        // Which of the viewer's groups each source is filed under, so a row says where it now lives.
        let filedByTarget = store.sourceGroups(includeHidden: false).reduce(into: [String: String]()) { table, group in
            for site in group.sites where !site.isBuiltIn { table[site.id] = group.title }
        }
        return scope.sites.map { site in
            let origin = site.origin(or: config.origin)
            let address = origin.absoluteString
            let entry = store.environmentSubscriptions.first { $0.address == address }
            let explicit = store.sourceRouting.route(site, origin: origin)
            return Row(site: site,
                       feed: site.isBuiltIn ? L10n.text("Built-in") : (entry?.title ?? address),
                       group: filedByTarget[site.id],
                       address: address,
                       probe: probes.latest(sourceKey: site.sourceKey),
                       route: explicit ?? entry?.routing ?? .auto)
        }
    }

    private func line(_ row: Row) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                if picked.contains(row.id) { picked.remove(row.id) } else { picked.insert(row.id) }
            } label: {
                Image(systemName: picked.contains(row.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(picked.contains(row.id) ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Tick %@", row.site.name))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.site.name)
                        .lineLimit(1)
                    routeChip(row.route)
                }
                Text(subtitle(row))
                    .font(.caption2)
                    .foregroundStyle(row.probe?.reachability == .unreachable ? AnyShapeStyle(Brand.rose) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            routeMenu(row)
        }
    }

    /// The reading in the viewer's words: "1080P · 320 ms · 2.4 MB/s · feed".
    private func subtitle(_ row: Row) -> String {
        var parts: [String] = []
        if let probe = row.probe {
            parts.append(probe.summary())
        } else {
            parts.append(L10n.text("Not measured"))
        }
        if let group = row.group, group != row.feed { parts.append(group) }
        if !row.feed.isEmpty { parts.append(row.feed) }
        return parts.joined(separator: " · ")
    }

    private func routeChip(_ route: SourceRoute) -> some View {
        Text(route.title)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(routeTint(route).opacity(0.16), in: Capsule())
            .foregroundStyle(routeTint(route))
    }

    private func routeTint(_ route: SourceRoute) -> Color {
        switch route {
        case .auto: return .secondary
        case .direct: return Brand.teal
        case .proxy: return Brand.amber
        }
    }

    /// Pinning one source. Every choice is written explicitly, `Auto` included: a viewer who wants
    /// this one source to stop being pinned has to be able to say so, and `.auto` is a route too.
    private func routeMenu(_ row: Row) -> some View {
        Menu {
            ForEach(SourceRoute.allCases, id: \.self) { route in
                Button {
                    store.setRoute(route, for: row.site)
                } label: {
                    if row.route == route {
                        Label(route.title, systemImage: "checkmark")
                    } else {
                        Text(route.title)
                    }
                }
            }
            Divider()
            Section(L10n.text("Move")) {
                ForEach(store.sourceGroupBook.groups) { group in
                    Button(group.name) {
                        store.fileSources([row.site], intoGroup: group.id)
                        notice = L10n.text("Moved %lld sources into %@.", 1, group.name)
                    }
                }
                Button {
                    store.returnSourcesToTheirSubscription([row.site])
                    notice = L10n.text("Sent %lld sources back to their own subscription.", 1)
                } label: {
                    Label(L10n.text("Back to Their Subscription"), systemImage: "arrow.uturn.backward")
                }
            }
        } label: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        #if os(iOS)
        .menuIndicator(.hidden)
        #endif
        .accessibilityLabel(L10n.text("Route for %@", row.site.name))
    }

    // MARK: - Order

    /// Bakes the readings into the viewer's order: sharpest and fastest first, built-in sources left
    /// where they are, sources never measured after every one that was.
    private func sortByMeasurement() {
        guard let config = store.subscription else { return }
        let probes = SourceProbeStore.shared
        let sites = store.orderedSites(config)
        let builtIn = sites.filter(\.isBuiltIn)
        let ranked = sites.filter { !$0.isBuiltIn }
            .enumerated()
            .sorted { lhs, rhs in
                let a = probes.latest(sourceKey: lhs.element.sourceKey)?.sortScore ?? -1
                let b = probes.latest(sourceKey: rhs.element.sourceKey)?.sortScore ?? -1
                return a == b ? lhs.offset < rhs.offset : a > b
            }
            .map(\.element)
        store.sourceOrder.save(builtIn + ranked, origin: config.origin)
        store.sourceOrder.enabled = true
        notice = L10n.text("The order is now the measured one; the Sources page follows it.")
    }
}
