import SwiftUI
import TVCore

struct SitesView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Choosing a source for something else (Watch Now's recommendations): only `pickable` sources are listed, the
    /// `picked` one is checked, and Select hands the source back and returns instead of opening it.
    var pick: ((Site) -> Void)? = nil
    var pickable: [Site] = []
    var picked: String? = nil
    @FocusState private var focusedSite: String?
    @State private var query = ""
    /// Groups the viewer folded. Every group starts open, subscriptions and hidden sources included,
    /// so nothing on the page needs finding; after that the fold is what the viewer left it as, kept
    /// by `foldState`. Restored with the page, not with a pushed source: the state lives here and
    /// `prepared` keeps the restore to once per visit.
    @State private var collapsed: Set<String> = []
    /// Where the fold survives leaving the page.
    private let foldState = SourceFoldState()
    @State private var prepared = false
    @State private var editingSource: Site?
    /// The fold as it was when a search began; restored when the search is cleared.
    @State private var foldBeforeSearch: Set<String>?
    @State private var arranging = false
    @State private var choosingHidden = false
    var body: some View {
        Group {
            if let config = store.subscription {
                let groups = store.sourceGroups(includeHidden: false).filtered(by: query).limited(to: pick == nil ? nil : Set(pickable.map(\.key)))
                let sites = store.orderedSites(config)
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Layout.cardSpacing) {
                        if pick == nil, query.isEmpty && sites.count > 1 {
                            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                                SourceOrderCard(sites: sites) { arranging = true }
                                HideSourcesCard(hidden: groups.first { $0.kind == .hidden }?.sites.count ?? 0) { choosingHidden = true }
                            }.tvFocusSection()
                        }
                        ForEach(groups) { group in
                            groupHeader(group)
                            if !collapsed.contains(group.id) {
                                LazyVGrid(columns: Layout.cardColumns, spacing: Layout.cardSpacing) {
                                    ForEach(group.sites) { site in
                                        if let pick {
                                            Button { pick(site); dismiss() } label: { SiteCard(site: site, chosen: site.key == picked) }.tileButton()
                                                .accessibilityAddTraits(site.key == picked ? .isSelected : [])
                                                .focused($focusedSite, equals: site.key)
                                                .id(site.key)
                                        } else {
                                        RouteLink { SiteView(site: site, origin: config.origin, jarURL: config.spiderURL) } label: { SiteCard(site: site, dimmed: group.kind == .hidden) }.tileButton()
                                            // Dragging a card onto another subscription's header files it
                                            // there; the move outlives a refresh (see SourceReassignment).
                                            // The TV has no drag gesture, so it files sources from the menu.
                                            #if !os(tvOS)
                                            .draggable(SourceDrag(key: site.sourceKey, origin: site.origin(or: config.origin).absoluteString))
                                            #endif
                                            .contextMenu {
                                                PinSourceButton(site: site, origin: config.origin)
                                                HideSourceButton(site: site, origin: config.origin)
                                                SourceMoveMenu(site: site)
                                                SourceRouteMenu(site: site)
                                                Button { editingSource = site } label: {
                                                    Label(L10n.text("Edit Source"), systemImage: "pencil")
                                                }
                                                if store.sourceOrder.enabled { MoveSourceButtons(site: site, sites: sites) }
                                            }
                                        }
                                    }
                                }
                                // Unfolds from under its header; folding only fades, as the groups below slide up.
                                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -16)), removal: .opacity))
                            }
                        }
                    }.pageContainer()
                }
                .reportsScrollingToPosterLoader()
                // Picking opens on the current choice rather than the top of a long page.
                .defaultFocus($focusedSite, picked)
                .onAppear { if pick != nil, let picked { proxy.scrollTo(picked, anchor: .center) } }
                }
                .sheet(isPresented: $arranging) { SourceOrderEditor(sites: sites, automatic: store.automaticSites(config)) }
                .sheet(isPresented: $choosingHidden) { HiddenSourcesEditor() }
                #if DEBUG
                // `-qaArrangeSources 1` opens the editor for screenshots.
                .task {
                    guard UserDefaults.standard.bool(forKey: "qaArrangeSources") else { return }
                    store.setCustomSourceOrder(true)
                    // Let launch settle first: on tvOS a sheet asked for straight away never appeared.
                    try? await Task.sleep(for: .seconds(2))
                    arranging = true
                }
                #endif
            } else { ContentUnavailableView(L10n.text("No Sources Yet"), systemImage: "square.grid.2x2", description: Text(L10n.text("Add a TVBox subscription in Settings."))) }
        }
        .screenBackdrop()
        .catalogSearchable(text: $query, prompt: L10n.text("Find a source"))
        .modifier(SitesTitle(picking: pick != nil))
        .sheet(item: $editingSource) { site in
            if let origin = store.subscription?.origin {
                SourceEditorSheet(site: site, origin: origin)
            }
        }
        .toolbar {
            if pick == nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        // One button, two jobs: start the sweep, or stop the one running. A sweep
                        // that cannot be stopped is how the app got stuck in the first place.
                        if store.probeRun == nil { store.startProbingAllSources() }
                        else { store.cancelProbingAllSources() }
                    } label: {
                        if let run = store.probeRun {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("\(run.done)/\(run.total)").monospacedDigit()
                            }
                        } else {
                            Label(L10n.text("Probe All"), systemImage: "speedometer")
                        }
                    }
                    .help(store.probeRun == nil ? L10n.text("Probe All") : L10n.text("Stop Probing"))
                    .accessibilityIdentifier("sources.probeAll")
                    Menu {
                        Button { Task { await store.batchFixUnreachableLines(.proxy) } } label: {
                            Label(L10n.text("Route Unreachable Lines Through Proxy"), systemImage: "network")
                        }
                        Button { Task { await store.batchFixUnreachableLines(.direct) } } label: {
                            Label(L10n.text("Force Unreachable Lines Direct"), systemImage: "bolt")
                        }
                        Button(role: .destructive) { Task { await store.batchFixUnreachableLines(.hide) } } label: {
                            Label(L10n.text("Hide Unreachable Lines"), systemImage: "eye.slash")
                        }
                    } label: {
                        Label(L10n.text("Fix Dead Lines"), systemImage: "wrench.and.screwdriver")
                    }
                    .accessibilityIdentifier("sources.fixDeadLines")
                    Menu {
                        // Ten questions about a long source list — "which of these is worth opening" —
                        // answered by the sweep, so the answer should be able to reorder the list.
                        Button { withAnimation(.snappy(duration: 0.3)) { store.rankSourcesByMeasuredQuality() } } label: {
                            Label(L10n.text("Sort by Measured Quality"), systemImage: "arrow.up.arrow.down")
                        }
                        .disabled(store.probeRun != nil)
                    } label: {
                        Label(L10n.text("Sort"), systemImage: "arrow.up.arrow.down")
                    }
                    .accessibilityIdentifier("sources.sortByProbe")
                    // The record of what was dragged where, and the way to undo it. Only while there
                    // is something to undo: an always-present button would be a second Settings page.
                    movedSourcesButton
                    foldButtons
                }
            }
        }
        .task(id: store.section) {
            if store.section == .sites && !prepared {
                applyDefaultFold()
                prepared = true
            }
        }
        .onChange(of: store.section) { _, new in
            if new != .sites { prepared = false }
        }
        .onChange(of: query) { old, new in
            if old.isEmpty && !new.isEmpty {
                foldBeforeSearch = collapsed
                collapsed = []
            } else if !old.isEmpty && new.isEmpty, let saved = foldBeforeSearch {
                collapsed = saved
                foldBeforeSearch = nil
            }
        }
    }

    @ViewBuilder
    private func groupHeader(_ group: SourceGroup) -> some View {
        let open = !collapsed.contains(group.id)
        let header = Button {
            withAnimation(.snappy(duration: 0.3)) {
                if open { collapsed.insert(group.id) } else { collapsed.remove(group.id) }
                foldState.save(collapsed)
            }
        } label: {
            HStack(spacing: 8) {
                Text(L10n.text(group.title)).font(.headline).lineLimit(1)
                Text("\(group.sites.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                Spacer(minLength: 8)
                // One chevron that turns, rather than two symbols swapped.
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("sources.group." + group.id)
        #if !os(tvOS)
        if case .subscription(let address) = group.kind, query.isEmpty {
            header
                .draggable(group.id)
                .dropDestination(for: String.self) { items, _ in
                    guard query.isEmpty, let address = items.first else { return false }
                    store.moveSourceGroup(address, onto: group.id, includeHidden: false)
                    return true
                }
                // A dropped card is a source, not a group: it files that one source here.
                .dropDestination(for: SourceDrag.self) { (items: [SourceDrag], _: CGPoint) -> Bool in
                    guard query.isEmpty, let drag = items.first else { return false }
                    store.reassignSourceByKey(drag.key, origin: drag.origin, to: address)
                    return true
                }
        } else if group.kind == .other, query.isEmpty {
            // Dropping into "Other Sources" is the way back: the source returns to its own subscription.
            header.dropDestination(for: SourceDrag.self) { (items: [SourceDrag], _: CGPoint) -> Bool in
                guard query.isEmpty, let drag = items.first else { return false }
                store.reassignSourceByKey(drag.key, origin: drag.origin, to: nil)
                return true
            }
        } else {
            header
        }
        #else
        header
        #endif
    }

    /// Every group folded, or every group open, in one press.
    private var foldButtons: some View {
        let allCollapsed = !collapsed.isEmpty && store.sourceGroups(includeHidden: false).allSatisfy { collapsed.contains($0.id) }
        return Button {
            setAllCollapsed(!allCollapsed)
        } label: {
            Label(allCollapsed ? L10n.text("Expand All") : L10n.text("Collapse All"),
                  systemImage: allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
        }
        .disabled(!query.isEmpty)
        .help(allCollapsed ? L10n.text("Expand All") : L10n.text("Collapse All"))
    }

    /// Every group open, or every group folded, at once.
    private func setAllCollapsed(_ all: Bool) {
        let ids = store.sourceGroups(includeHidden: false).map(\.id)
        withAnimation(.snappy(duration: 0.3)) { collapsed = all ? Set(ids) : [] }
        foldState.save(collapsed)
    }

    /// Entry to the record of moved sources, shown only while a move is in effect.
    @ViewBuilder
    private var movedSourcesButton: some View {
        if store.sourceReassignment.moveCount > 0 {
            RouteLink { SourceMovesView() } label: {
                Label(L10n.text("Moved Sources"), systemImage: "arrow.triangle.branch")
            }
            .accessibilityIdentifier("sources.movedSources")
        }
    }

    /// The page as the viewer left it: the fold they saved, else every group open.
    private func applyDefaultFold() {
        collapsed = foldState.collapsed ?? []
        foldBeforeSearch = nil
    }
}

/// The Sources tab names itself in the sidebar; a page pushed to pick a source says what is being chosen.
private struct SitesTitle: ViewModifier {
    let picking: Bool
    func body(content: Content) -> some View {
        if picking { content.screenTitle(L10n.text("Recommendation Source")) } else { content.tabTitle(L10n.text("Sources")) }
    }
}

private extension Array where Element == SourceGroup {
    /// Only these sources, when given; groups left empty drop out.
    func limited(to keys: Set<String>?) -> [SourceGroup] {
        guard let keys else { return self }
        return compactMap { group in
            var kept = group
            kept.sites = group.sites.filter { keys.contains($0.key) }
            return kept.sites.isEmpty ? nil : kept
        }
    }

    /// Sites whose name contains the query, ignoring case; groups left empty drop out.
    func filtered(by query: String) -> [SourceGroup] {
        guard !query.isEmpty else { return self }
        return compactMap { group in
            var kept = group
            kept.sites = group.sites.filter { $0.name.localizedCaseInsensitiveContains(query) }
            return kept.sites.isEmpty ? nil : kept
        }
    }
}

extension Store {
    /// How a source has been answering lately; see `SourceHealth`.
    func health(of site: Site) -> SourceHealth.Status {
        subscription.map { SourceHealth.shared.status(site, origin: $0.origin) } ?? .unknown
    }
}

extension SourceHealth.Status {
    /// The dot that marks it; none until the source has been asked.
    var tint: Color? {
        switch self {
        case .unknown: nil
        case .healthy: .green
        case .unstable: Brand.amber
        case .failing: Brand.rose
        }
    }
    /// Only trouble: in search results every listed source has just answered.
    var warning: Color? { self == .unstable || self == .failing ? tint : nil }
    var summary: String {
        switch self {
        case .unknown: ""
        case .healthy: L10n.text("Responding normally")
        case .unstable: L10n.text("Slow or unreliable lately")
        case .failing: L10n.text("Failing; skipped in search for now")
        }
    }
}

/// A source's health as a dot beside its name. Trouble states get a distinct symbol — not just a
/// color — so the three states stay tellable apart without relying on hue alone.
struct SourceHealthDot: View {
    let status: SourceHealth.Status
    #if os(tvOS)
    private let size: CGFloat = 14
    #else
    private let size: CGFloat = 8
    #endif
    var body: some View {
        if let tint = status.tint {
            switch status {
            case .healthy, .unknown:
                Image(systemName: "circle.fill").font(.system(size: size)).foregroundStyle(tint).accessibilityLabel(status.summary)
            case .unstable:
                // A hollow circle with an exclamation reads "slow" even in grayscale.
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: size * 1.6)).foregroundStyle(tint).accessibilityLabel(status.summary)
            case .failing:
                Image(systemName: "xmark.circle.fill").font(.system(size: size * 1.6)).foregroundStyle(tint).accessibilityLabel(status.summary)
            }
        }
    }
}

/// A source as an app-icon tile plus its name: the name's emoji becomes the icon, its taglines
/// ("不卡", "秒播") and engine a quiet second line, so a page of sources reads like a launcher
/// rather than a wall of identical badges. Use with `tileButton()`: on tvOS the card lights up itself.
struct SiteCard: View {
    @Environment(Store.self) private var store
    @Environment(\.isFocused) private var isFocused
    let site: Site
    /// A source the viewer hid, shown only while hidden sources are revealed.
    var dimmed = false
    /// The pin badge on the icon; off in Watch Now's Pinned Sources, where every card is pinned.
    var marksPinned = true
    /// Whether this is the source currently chosen, when picking one (`SitesView.pick`); nil when not picking.
    var chosen: Bool? = nil
    #if os(tvOS)
    private var focused: Bool { isFocused }
    private let icon: CGFloat = 88, padding: CGFloat = 20, radius: CGFloat = 28
    #else
    private let icon: CGFloat = 48, padding: CGFloat = 12, radius: CGFloat = 16
    // Keyboard focus on the Mac must not turn the text black on a dark panel.
    private let focused = false
    #endif
    var body: some View {
        let label = SourceLabel(site.name)
        let pinned = marksPinned && (store.subscription.map { store.pinnedSources.contains(site, origin: $0.origin) } ?? false)
        let runs = site.isBuiltIn || site.canBrowse(jarURL: store.subscription?.spiderURL)
        let detail = runs ? (label.parts.dropFirst() + [engine].compactMap { $0 }).joined(separator: " · ") : site.compatibility
        // The viewer renamed it, changed its API, or forced a route: the card says so, since none of
        // those edits are visible on the tile itself and a quietly-overridden source confuses later.
        let customized = store.subscription.map { sub in
            store.sourceOverrides.override(for: site, origin: sub.origin) != nil
                || store.sourceRouting.route(site, origin: sub.origin) != nil
        } ?? false
        HStack(spacing: padding) {
            SourceIcon(site: site, label: label, size: icon)
                .opacity(runs ? 1 : 0.45)
                // A badge on the icon, not another line, so pinned cards keep the grid's height.
                .overlay(alignment: .bottomTrailing) {
                    if pinned {
                        Image(systemName: "pin.fill").font(.system(size: icon * 0.18, weight: .bold)).foregroundStyle(Brand.onAccent)
                            .frame(width: icon * 0.36, height: icon * 0.36).background(Brand.accent, in: Circle())
                            .overlay { Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1) }
                            .offset(x: icon * 0.1, y: icon * 0.1)
                            .accessibilityLabel(L10n.text("Pinned"))
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(label.parts[0]).font(.headline).lineLimit(1)
                        .foregroundStyle(focused ? Color.black : runs ? Color.primary : Color.secondary)
                    if runs { SourceHealthDot(status: store.health(of: site)) }
                    if dimmed { Text(L10n.text("Hidden")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    if customized { Text(L10n.text("Customized")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                if !detail.isEmpty {
                    Text(detail).font(.subheadline).lineLimit(1)
                        .foregroundStyle(focused ? Color.black.opacity(0.6) : runs ? Color.secondary : Brand.amber)
                }
            }
            Spacer(minLength: 0)
            if chosen == true {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(focused ? Color.black : Brand.accent)
                    .accessibilityHidden(true)
            }
            #if !os(tvOS)
            if chosen == nil { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
            #endif
        }
        .padding(padding).frame(maxWidth: .infinity, alignment: .leading)
        .background { TileSurface(focused: focused, radius: radius) }
        .accessibilityElement(children: .combine)
        .opacity(dimmed ? 0.45 : 1)
    }

    /// Which engine runs a source is an implementation detail; only built-in sources say so.
    private var engine: String? { site.isBuiltIn ? L10n.text("Built-in") : nil }
}

/// A launcher tile's own surface (source cards, live playlists).
struct TileSurface: View {
    var focused: Bool
    var radius: CGFloat
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        #if os(tvOS)
        // Like the system's focused buttons: a quiet tile at rest, a bright plate under focus.
        shape.fill(focused ? Color.white : Color.white.opacity(0.07))
            .overlay { shape.strokeBorder(.white.opacity(focused ? 0 : 0.06), lineWidth: 1) }
        #else
        Color.clear.contentPanel(cornerRadius: radius)
        #endif
    }
}

/// A source's icon: Bilibili's own mark, otherwise a `MonogramIcon`.
struct SourceIcon: View {
    let site: Site
    let label: SourceLabel
    var size: CGFloat
    var body: some View {
        if site.isBilibili { BilibiliMark(size: size) } else {
            MonogramIcon(seed: site.name, label: label, size: size, systemImage: site.symbol)
        }
    }
}

/// The emoji a name starts with (or its first character, or a symbol) on a tile whose colour is
/// derived from the name, so neighbours differ.
struct MonogramIcon: View {
    let seed: String
    let label: SourceLabel
    var size: CGFloat
    var systemImage: String?
    private static let tints: [Color] = [
        Brand.indigo, Brand.amber, Brand.rose,
        Color(red: 0.30, green: 0.66, blue: 0.60), Color(red: 0.42, green: 0.56, blue: 0.92),
        Color(red: 0.62, green: 0.48, blue: 0.88), Color(red: 0.52, green: 0.72, blue: 0.38),
    ]
    var body: some View {
        // A stable hash: `hashValue` changes every launch.
        let tint = Self.tints[seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % Self.tints.count]
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Group {
            if let systemImage {
                // Sized by frame rather than font: font-sized symbols sit off-center (baseline/ascent padding) before macOS 26.
                Image(systemName: systemImage).resizable().scaledToFit().fontWeight(.semibold)
                    .frame(width: size * 0.46, height: size * 0.46).foregroundStyle(.white)
            } else if let symbol = label.symbol {
                Text(symbol).font(.system(size: size * 0.5))
            } else {
                Text(String(label.parts[0].prefix(1)).uppercased()).font(.system(size: size * 0.44, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size, alignment: .center)
        .background(LinearGradient(colors: [tint.opacity(0.85), tint.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing), in: shape)
        .overlay { shape.strokeBorder(.white.opacity(0.12), lineWidth: 1) }
        .accessibilityHidden(true)
    }
}

struct PinSourceButton: View {
    @Environment(Store.self) private var store
    let site: Site
    let origin: URL
    var body: some View {
        let pinned = store.pinnedSources.contains(site, origin: origin)
        Button { store.pinnedSources.toggle(site, origin: origin) } label: {
            Label(L10n.text(pinned ? "Unpin source" : "Pin source"), systemImage: pinned ? "pin.slash" : "pin")
        }.accessibilityIdentifier("source.pin." + site.key)
    }
}

struct HideSourceButton: View {
    @Environment(Store.self) private var store
    let site: Site
    let origin: URL
    var body: some View {
        let hidden = store.hiddenSources.contains(site, origin: origin)
        Button { store.hiddenSources.toggle(site, origin: origin) } label: {
            Label(L10n.text(hidden ? "Unhide Source" : "Hide Source"), systemImage: hidden ? "eye" : "eye.slash")
        }.accessibilityIdentifier("source.hide." + site.key)
    }
}

/// What a dragged source card carries: the key its own feed gave it, and the origin it came from, so
/// the header it lands on can find it again in the merged list whatever its name is now.
struct SourceDrag: Codable, Transferable, Hashable {
    var key: String
    var origin: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
        ProxyRepresentation(exporting: \.key)
    }
}

/// Files one source under another subscription without dragging: the same move the Sources page's
/// drop targets make, reachable where dragging is awkward (a phone in one hand, tvOS, VoiceOver).
struct SourceMoveMenu: View {
    @Environment(Store.self) private var store
    let site: Site
    var body: some View {
        // A built-in source belongs to no subscription, so there is nothing to file it away from.
        if !site.isBuiltIn {
            let own = store.entryAddress(of: site)
            let moved = store.reassignedAddress(site)
            let targets = store.environmentSubscriptions.filter { $0.enabled && $0.address != own && $0.address != moved }
            Menu {
                ForEach(targets) { entry in
                    Button(entry.title) { store.reassignSource(site, to: entry.address) }
                }
                if moved != nil {
                    Divider()
                    Button { store.reassignSource(site, to: nil) } label: {
                        Label(L10n.text("Move Back"), systemImage: "arrow.uturn.backward")
                    }
                }
            } label: {
                Label(L10n.text("Move to Another Subscription"), systemImage: "arrow.triangle.branch")
            }
            .disabled(targets.isEmpty && moved == nil)
            .accessibilityIdentifier("source.move." + site.key)
        }
    }
}

/// Context-menu routing: force this source direct or proxied, or let it follow connectivity. Shown
/// only for native (type 1/4) sources whose address the relay can front.
struct SourceRouteMenu: View {
    @Environment(Store.self) private var store
    let site: Site
    var body: some View {
        if site.native, !site.api.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let origin = store.subscription?.origin ?? site.origin(or: URL(fileURLWithPath: "/"))
            let current = store.effectiveRoute(site)
            Menu {
                ForEach(SourceRoute.allCases, id: \.self) { route in
                    Button { store.setRoute(route, for: site) } label: {
                        Label(route.title, systemImage: current == route ? "checkmark" : symbol(route))
                    }
                }
                if store.sourceRouting.route(site, origin: origin) != nil {
                    Divider()
                    Button { store.setRoute(.auto, for: site) } label: {
                        Label(L10n.text("Follow Subscription"), systemImage: "arrow.uturn.backward")
                    }
                }
            } label: {
                Label(L10n.text("Connection"), systemImage: "network")
            }
            .accessibilityIdentifier("source.route." + site.key)
        }
    }

    private func symbol(_ route: SourceRoute) -> String {
        switch route {
        case .auto: "arrow.triangle.2.circlepath"
        case .direct: "bolt"
        case .proxy: "network.badge.shield.half.filled"
        }
    }
}

/// Context-menu moves within the viewer's own source order.
struct MoveSourceButtons: View {
    @Environment(Store.self) private var store
    let site: Site
    let sites: [Site]
    var body: some View {
        if let index = sites.firstIndex(where: { $0.id == site.id }) {
            if index > 0 {
                Button { store.moveSource(site, to: 0) } label: { Label(L10n.text("Move to Top"), systemImage: "arrow.up.to.line") }
            }
            if index < sites.count - 1 {
                Button { store.moveSource(site, to: sites.count) } label: { Label(L10n.text("Move to Bottom"), systemImage: "arrow.down.to.line") }
            }
        }
    }
}

/// The Sources page's header: the switch for the viewer's own order (`SourceOrder`), the top of
/// that order at a glance, and the way into arranging it.
struct SourceOrderCard: View {
    @Environment(Store.self) private var store
    let sites: [Site]
    let arrange: () -> Void
    private var enabled: Binding<Bool> {
        Binding { store.sourceOrder.enabled } set: { on in withAnimation(.smooth) { store.setCustomSourceOrder(on) } }
    }
    private var detail: String {
        L10n.text(store.sourceOrder.enabled ? "Sources at the top are searched first, and their results are listed first."
                                            : "Mi3s searches quick, reliable sources first.")
    }
    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 8) {
            TVSettingsToggle(title: L10n.text("Custom Search Order"), detail: detail, isOn: enabled)
                .accessibilityIdentifier("sources.order.toggle")
            if store.sourceOrder.enabled {
                Button(action: arrange) {
                    TVSettingsRowLabel(title: L10n.text("Arrange Sources"), chevron: true) { SourceOrderPreview(sites: sites) }
                }
                .glassRow()
                .accessibilityIdentifier("sources.order.arrange")
            }
        }
        #else
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                IconTile(symbol: "arrow.up.arrow.down", tint: Brand.indigo, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Custom Search Order")).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle(L10n.text("Custom Search Order"), isOn: enabled).labelsHidden().toggleStyle(.switch).settingsSwitch()
                    .accessibilityIdentifier("sources.order.toggle")
            }
            if store.sourceOrder.enabled {
                Divider()
                HStack(spacing: 12) {
                    // As many icons as fit beside the button.
                    ViewThatFits(in: .horizontal) {
                        SourceOrderPreview(sites: sites, limit: 5)
                        SourceOrderPreview(sites: sites, limit: 4)
                        SourceOrderPreview(sites: sites, limit: 3)
                    }
                    Spacer(minLength: 8)
                    Button(action: arrange) {
                        Label(L10n.text("Arrange"), systemImage: "arrow.up.arrow.down")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.onAccent)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(Brand.accent, in: Capsule())
                    }
                    .buttonStyle(LiftButtonStyle())
                    .accessibilityIdentifier("sources.order.arrange")
                }
            }
        }
        .padding(16)
        .contentPanel(cornerRadius: 22)
        #endif
    }
}

/// The first sources of an order, as numbered icons.
struct SourceOrderPreview: View {
    let sites: [Site]
    var limit = 5
    #if os(tvOS)
    private let size: CGFloat = 44
    #else
    private let size: CGFloat = 30
    #endif
    var body: some View {
        let shown = Array(sites.prefix(limit))
        HStack(spacing: size * 0.32) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, site in
                SourceIcon(site: site, label: SourceLabel(site.name), size: size)
                    .overlay(alignment: .topLeading) {
                        SourceRankBadge(rank: index + 1, size: size * 0.52).offset(x: -size * 0.18, y: -size * 0.18)
                    }
            }
            if sites.count > shown.count {
                Text(verbatim: "+\(sites.count - shown.count)").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        // Room for the badges that stick out.
        .padding(.top, size * 0.18).padding(.leading, size * 0.18)
        .accessibilityHidden(true)
    }
}

struct SourceRankBadge: View {
    let rank: Int
    var size: CGFloat
    var body: some View {
        Text(rank, format: .number).font(.system(size: size * 0.62, weight: .bold, design: .rounded)).monospacedDigit()
            .foregroundStyle(Brand.onAccent)
            .padding(.horizontal, size * 0.2)
            .frame(minWidth: size, minHeight: size)
            .background(Brand.accent, in: Capsule())
            .overlay { Capsule().strokeBorder(.black.opacity(0.25), lineWidth: 1) }
    }
}
