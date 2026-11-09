import SwiftUI
import TVCore

/// Measures every listed source the way the phone will use it, shows what each one actually delivers,
/// and lets the viewer act on the reading: switch one source between direct and proxy, or drag the
/// list into the order they want to keep.
///
/// Why this page exists
/// -------------------
/// The probe engine (`SourceProbeRunner`), the reading cache (`SourceProbeStore`), the sweep
/// (`Store.startProbingAllSources`), the per-source route (`SourceRouting`) and the viewer's own
/// order (`SourceOrder`) were all already here, and none of them had a door: a sweep could only be
/// started from code, a route could only be set from a test, and the drag order lived on a page
/// about ranking attributes. This page is that door, and nothing more — it reads and writes those
/// stores rather than inventing a parallel set.
///
/// What "route" means here
/// -----------------------
/// A route changes the address the app fetches a source's *API* from: direct is its own `api` as
/// imported, proxy rewrites it through the built-in relay. Media segments come from whatever CDN the
/// source hands back and are not rewritten, so a source whose API answers but whose segments are
/// blocked still needs hiding, not routing. The footer says so rather than implying more.
struct SourceSpeedTestView: View {
    @Environment(Store.self) private var store

    /// Bumped after a sweep so the rows re-read `SourceProbeStore`: it is a plain dictionary behind
    /// UserDefaults, not observable, and a page that only read it on appear would keep showing the
    /// numbers from before the sweep.
    @State private var readings = 0
    @State private var filter: Filter = .all
    @State private var detail: Row?

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

    /// One line on the page. The id is subscription-qualified: two feeds may carry the same key, and
    /// `Site.id` alone would make SwiftUI draw one of them twice.
    private struct Row: Identifiable {
        let site: Site
        let feed: String
        let address: String
        let probe: SourceProbeResult?
        let route: SourceRoute
        var id: String { address + "|" + site.sourceKey }
    }

    var body: some View {
        Form {
            Section {
                sweep
            } header: {
                Text(L10n.text("Measurement"))
            } footer: {
                Text(L10n.text("Each source is asked for its newest video, then its first playable line is read through for a few hundred kilobytes: that gives the speed and the resolution shown below. A sweep costs one request per source, so run it when the network is the one you care about. Opening a video in a source counts as a measurement too, and every reading is kept until the source is measured again."))
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
                .onMove(perform: move)
            } header: {
                Text(L10n.text("Sources"))
            } footer: {
                Text(L10n.text("Drag to set your own order — it is saved and survives a refresh. The route menu pins one source to Direct or Proxy; Auto follows what the last requests managed to reach."))
            }
        }
        .settingsPage()
        .settingsForm(L10n.text("Source Speed Test"))
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        #endif
        // `probeRun` is observable; the readings behind it are not. Re-reading on every progress tick
        // keeps the rows in step with the sweep instead of jumping only when it finishes.
        .onChange(of: store.probeRun) { _, _ in readings += 1 }
        // A reading can also land without a sweep — the episode picker probes a line the moment the
        // viewer opens it — and that must refresh these rows too, not wait for a full probe.
        .onChange(of: SourceProbeStore.shared.revision) { _, _ in readings += 1 }
        .sheet(item: $detail) { row in probeDetail(row) }
    }

    // MARK: - Sweep

    @ViewBuilder
    private var sweep: some View {
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
                store.startProbingAllSources()
            } label: {
                Label(L10n.text("Probe Every Source"), systemImage: "speedometer")
            }
            .disabled(sweepIsEmpty)
        }

        Button {
            sortByMeasurement()
        } label: {
            Label(L10n.text("Order by Measured Speed"), systemImage: "arrow.up.arrow.down")
        }
        .disabled(measuredCount == 0)

        // 融合期把本页从「源测速与线路」升级成「源测速与分组」：底层 `fileByReachability`
        // 已在（Store+SourceGrouping.swift），把测过且能连的源归进「可连」组、连不上的归进
        // 「不通」组，未测的原地不动。这里补上那个「门」——入口注释承诺过「按结果批量归组」，
        // 但旧页面只有测速/路由/按速度排序，归组一直没接。
        Button {
            groupByReachability()
        } label: {
            Label(L10n.text("Group by Reachability"), systemImage: "square.grid.2x2")
        }
        .disabled(measuredCount == 0)

        // 分组建好之后，顺序是用户自己的事：源页面上把标题拖到另一个标题上即可，标题菜单里也有
        // 同样的上移／下移。置顶与内置分组固定在最前，不参与这个顺序。
        if !store.sourceGroupBook.isEmpty {
            Text(L10n.text("Drag a group's title onto another to change the order they are listed in; the menu on a title does the same two moves. Pinned and built-in groups keep the top."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if !sweepIsEmpty {
            Text(tally)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if !measuredSources.isEmpty {
            HStack {
                Text(lastSwept)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("Forget Readings")) {
                    SourceProbeStore.shared.forgetEverything()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.rose)
            }
        }
    }

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
    private var sweepIsEmpty: Bool { allRows.isEmpty }

    /// How many of the library's current sources have a reading, and when they were last measured.
    private var measuredSources: [(sourceKey: String, reading: SourceProbeResult)] {
        SourceProbeStore.shared.measuredSources()
    }

    private var lastSwept: String {
        guard let newest = SourceProbeStore.shared.measurementWindow?.newest else {
            return L10n.text("Not measured")
        }
        return L10n.text("Last measured %@", measuredText(newest))
    }

    // MARK: - Rows

    /// The page's list: the viewer's order, filtered, with the reading and the route attached.
    private var rows: [Row] {
        _ = readings  // re-read the probe cache whenever it may have changed
        switch filter {
        case .all: return allRows
        case .measured: return allRows.filter { $0.probe != nil }
        case .unreachable: return allRows.filter { $0.probe?.reachability == .unreachable }
        }
    }

    private var allRows: [Row] {
        guard let config = store.subscription else { return [] }
        let probes = SourceProbeStore.shared
        return store.orderedSites(config).map { site in
            let origin = site.origin(or: config.origin)
            let address = origin.absoluteString
            let entry = store.environmentSubscriptions.first { $0.address == address }
            let explicit = store.sourceRouting.route(site, origin: origin)
            return Row(site: site,
                       feed: site.isBuiltIn ? L10n.text("Built-in") : (entry?.title ?? address),
                       address: address,
                       probe: probes.latest(sourceKey: site.sourceKey),
                       route: explicit ?? entry?.routing ?? .auto)
        }
    }

    private func line(_ row: Row) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button { detail = row } label: {
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            if row.probe != nil {
                Button { detail = row } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                #if os(iOS)
                .accessibilityLabel(L10n.text("Details for %@", row.site.name))
                #endif
            }
            routeMenu(row)
            #if os(macOS)
            // A Mac has no edit mode, so the arrows are the reorder here — the same arrangement as
            // the other drag pages in Settings.
            HStack(spacing: 2) {
                Button { nudge(row, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.text("Move %@ up", row.site.name))
                Button { nudge(row, by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.text("Move %@ down", row.site.name))
            }
            #endif
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

    /// Drag. Offsets are positions in the drawn list; saving the drawn list is only correct while it
    /// is the whole list, so a filtered view is not draggable and says why.
    private func move(from source: IndexSet, to destination: Int) {
        guard filter == .all, let config = store.subscription else { return }
        var sites = store.orderedSites(config)
        sites.move(fromOffsets: source, toOffset: destination)
        store.sourceOrder.save(sites, origin: config.origin)
        store.sourceOrder.enabled = true
    }

    #if os(macOS)
    private func nudge(_ row: Row, by offset: Int) {
        guard let config = store.subscription else { return }
        let sites = store.orderedSites(config)
        guard let index = sites.firstIndex(where: { $0.sourceKey == row.site.sourceKey && $0.origin(or: config.origin) == row.site.origin(or: config.origin) }) else { return }
        let target = index + offset
        guard sites.indices.contains(target) else { return }
        store.moveSource(row.site, to: offset > 0 ? target + 1 : target)
    }
    #endif

    /// Bakes the readings into the viewer's order: sharpest and fastest first, built-in sources left
    /// where they are, sources never measured after every one that was.
    ///
    /// Sorted on `sortScore` rather than on `ResourceRanking`: that page ranks by declared picture
    /// height, and "which of these answers fastest" is a different question from "which looks best".
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
    }

    /// 把测过的源按可达性批量归进两个组：能连的进「可连」，连不上的进「不通」。
    /// 未测的源原地不动（把没读数的源当成死的归档是猜，比慢源更糟的是把能用的藏进「不通」）。
    /// 复用融合期已就位的 `Store.fileByReachability`（Store+SourceGrouping.swift）。
    private func groupByReachability() {
        guard let config = store.subscription else { return }
        let sites = store.orderedSites(config)
        let (reachable, unreachable) = store.fileByReachability(
            sites,
            reachableName: L10n.text("Reachable"),
            unreachableName: L10n.text("Unreachable")
        )
        store.notice = L10n.text("Filed %lld reachable and %lld unreachable sources into groups.", reachable, unreachable)
    }

    // MARK: - Detail

    /// Everything one reading recorded, laid out as rows rather than the one-line summary on the
    /// list. A "detail" that only repeats the subtitle is not a detail, so it also says *how* the
    /// number was taken: a ranged read of the first 256 KB of the line, which is the same thing the
    /// player's picker does when it decides whether a line is worth trying.
    @ViewBuilder
    private func probeDetail(_ row: Row) -> some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(row.site.name).font(.headline)
                        Spacer()
                        routeChip(row.route)
                    }
                    if !row.feed.isEmpty {
                        Text(row.feed).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    if let probe = row.probe {
                        detailRow(L10n.text("Status"), value: status(probe), tint: statusTint(probe))
                        if let latency = probe.latencyMilliseconds, probe.reachability != .unreachable {
                            detailRow(L10n.text("Latency"), value: String(format: "%d ms", latency))
                        }
                        if let speed = probe.kilobytesPerSecond, probe.reachability != .unreachable {
                            detailRow(L10n.text("Speed"), value: String(format: "%.1f MB/s", Double(speed) / 1024))
                        }
                        if let height = probe.resolutionHeight {
                            detailRow(L10n.text("Resolution"), value: "\(height)P")
                        }
                        detailRow(L10n.text("Measured"), value: measuredText(probe.measuredAt))
                    } else {
                        Text(L10n.text("Not measured yet. Open a video in this source, or run a sweep, and its reading shows here."))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(L10n.text("Reading"))
                } footer: {
                    Text(L10n.text("A reading is one ranged request for the first 256 KB of the line — the same thing the player does before it commits. The result is kept and reused until the source is measured again."))
                }
            }
            .navigationTitle(L10n.text("Measurement Details"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Done")) { detail = nil }
                }
            }
            #endif
        }
    }

    private func detailRow(_ label: String, value: String, tint: Color = .primary) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(tint)
        }
    }

    private func status(_ probe: SourceProbeResult) -> String {
        switch probe.reachability {
        case .reachable: return L10n.text("Reachable")
        case .slow: return L10n.text("Slow")
        case .unreachable: return L10n.text("Unreachable")
        case .unknown: return L10n.text("Not checked")
        }
    }

    private func statusTint(_ probe: SourceProbeResult) -> Color {
        switch probe.reachability {
        case .reachable: return Brand.teal
        case .slow: return Brand.amber
        case .unreachable: return Brand.rose
        case .unknown: return .secondary
        }
    }

    /// "Just now", "5 minutes ago", or a clock time for readings older than an hour.
    private func measuredText(_ date: Date) -> String {
        let ago = Date().timeIntervalSince(date)
        if ago < 60 { return L10n.text("Just now") }
        if ago < 3600 { return L10n.text("%lld minutes ago", Int(ago / 60)) }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
