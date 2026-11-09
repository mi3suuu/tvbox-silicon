import CoreImage
import SwiftUI
import TVCore

// [融合恢复] 批量删重复类型时误删，从 backup 分支取回。
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
    /// Seeds the fold before the first frame, so the page never draws every group open and then
    /// fold: restoring in `.task` runs after the first render, which reads as the page flickering.
    /// Picking starts open (see `applyDefaultFold`).
    // [mi3s] 二开：首帧前就种下折叠状态，避免每次进页面先全展开再折起（上游无此 init）
    init(pick: ((Site) -> Void)? = nil, pickable: [Site] = [], picked: String? = nil) {
        self.pick = pick
        self.pickable = pickable
        self.picked = picked
        _collapsed = State(initialValue: pick == nil ? (SourceFoldState().collapsed ?? []) : [])
    }
    var body: some View {
        Group {
            if let config = store.subscription {
                let all = store.sourceGroups(includeHidden: false)
                let hiddenCount = all.first { $0.kind == .hidden }?.sites.count ?? 0
                let groups = all.filtered(by: query).limited(to: pick == nil ? nil : Set(pickable.map(\.key)))
                let sites = store.orderedSites(config)
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Layout.cardSpacing) {
                        if pick == nil, query.isEmpty && sites.count > 1 {
                            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                                SourceOrderCard(sites: sites) { arranging = true }
                                HideSourcesCard(hidden: hiddenCount) { choosingHidden = true }
                            }.tvFocusSection()
                        }
                        ForEach(groups) { group in
                            groupHeader(group)
                            if !collapsed.contains(group.id) {
                                LazyVGrid(columns: Layout.cardColumns, spacing: Layout.cardSpacing) {
                                    ForEach(group.sites) { site in
                                    siteRow(site, group: group, config: config, sites: sites)
                                    }
                                }
                                // Unfolds from under its header; folding only fades, as the groups below slide up.
                                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -16)), removal: .opacity))
                            }
                        }
                        // Picking leaves hidden sources out; the way to show them again is at the end, where the
                        // list runs out (#704). Not on Apple TV, where a sheet over a pushed page never settles (#272).
                        #if !os(tvOS)
                        if pick != nil, query.isEmpty, hiddenCount > 0 {
                            HideSourcesCard(hidden: hiddenCount) { choosingHidden = true }
                        }
                        #endif
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
        #if !os(tvOS)
        .toolbar {
            // Edit, where people look first to remove a source that stopped working or to bring back one they hid
            // (#669, #704). It opens the same list as the Hide or Show Sources card.
            if pick == nil, store.subscription != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button(L10n.text("Edit")) { choosingHidden = true }.accessibilityIdentifier("sources.edit")
                }
            }
        }
        #endif
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
                // A picking visit folds for its own convenience and leaves the Sources page's saved
                // fold alone: borrowing a page to choose from must not rearrange it.
                // [mi3s] 二开：借用选择页时不动 Sources 页自己的折叠记忆
                if pick == nil { foldState.save(collapsed) }
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
                    // A group's title dragged onto a subscription header: the viewer's own groups always
                    // sit above the feeds, so there is no place for it here.
                    guard CustomSourceGroup.id(inTarget: address) == nil else { return false }
                    store.moveSourceGroup(address, onto: group.id, includeHidden: false)
                    return true
                }
                // A dropped card is a source, not a group: it files that one source here.
                .dropDestination(for: SourceDrag.self) { (items: [SourceDrag], _: CGPoint) -> Bool in
                    guard query.isEmpty, let drag = items.first else { return false }
                    store.reassignSourceByKey(drag.key, origin: drag.origin, to: address)
                    return true
                }
        } else if case .custom(let id) = group.kind, query.isEmpty {
            // Dropping onto one of the viewer's own groups files the source there — the same move the
            // speed page's "移动到…" makes, done one card at a time. Dropping another group's *title*
            // here changes the order the groups are listed in: they are the viewer's, so their order is
            // theirs to set. The menu carries the same two moves for places a drag is awkward.
            header
                .draggable(group.id)
                .dropDestination(for: String.self) { items, _ in
                    guard query.isEmpty, let payload = items.first else { return false }
                    // Only a group's title reorders groups; a subscription dragged here has no business
                    // moving above the feeds, so it is refused rather than half-applied.
                    guard CustomSourceGroup.id(inTarget: payload) != nil else { return false }
                    store.moveCustomGroup(id, onto: payload)
                    return true
                }
                .dropDestination(for: SourceDrag.self) { (items: [SourceDrag], _: CGPoint) -> Bool in
                    guard query.isEmpty, let drag = items.first else { return false }
                    store.reassignSourceByKey(drag.key, origin: drag.origin, to: group.id)
                    return true
                }
                .contextMenu {
                    Button { store.moveCustomGroup(id, by: -1) } label: {
                        Label(L10n.text("Move Group Up"), systemImage: "arrow.up")
                    }
                    .disabled(!store.canMoveCustomGroup(id, by: -1))
                    Button { store.moveCustomGroup(id, by: 1) } label: {
                        Label(L10n.text("Move Group Down"), systemImage: "arrow.down")
                    }
                    .disabled(!store.canMoveCustomGroup(id, by: 1))
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
        // Same rule as a single header: only the Sources page owns the saved fold.
        // [mi3s] 二开：展开/折叠全部后也只由 Sources 页写折叠记忆
        if pick == nil { foldState.save(collapsed) }
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
    ///
    /// Only the page's own fold is restored. Picked-for-something-else (Watch Now's recommendations)
    /// is a different visit with a different job: it must open every group, or a source the viewer
    /// folded away on the Sources page is absent from the list they were asked to choose from.
    private func applyDefaultFold() {
        collapsed = pick == nil ? (foldState.collapsed ?? []) : []
        foldBeforeSearch = nil
    }

    /// 一张源卡片（可选态 / 路由 / 拖拽 / 右键菜单）。
    /// 原来这一整块内联在 ForEach 里，嵌套四层，编译器报
    /// 「unable to type-check this expression in reasonable time」——抽出来只为降复杂度，行为不变。
    @ViewBuilder private func siteRow(_ site: Site, group: SourceGroup, config: Subscription, sites: [Site]) -> some View {
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

/// Over a hidden source's own page: it says so, and Unhide Source brings it back. Hiding is a single tap in the page's
/// toolbar or a source's menu, so a mistaken one is undone where it happened rather than on another page (#704).
struct HiddenSourceBanner: View {
    @Environment(Store.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    let site: Site
    let origin: URL
    var body: some View {
        let text = VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("This Source Is Hidden")).font(.headline)
            Text(L10n.text("It stays out of Watch Now and search. Hidden sources are listed at the end of the Sources page."))
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        let button = Button { withAnimation(.smooth) { store.hiddenSources.toggle(site, origin: origin) } } label: { Text(L10n.text("Unhide Source")) }
            .controlButton(prominent: true)
            .accessibilityIdentifier("source.unhide." + site.key)
        Group {
            if sizeClass == .compact {
                // An iPhone's width: the button under the words, which beside it wrapped to five short lines.
                VStack(alignment: .trailing, spacing: 12) {
                    HStack(alignment: .top, spacing: 14) {
                        IconTile(symbol: "eye.slash", tint: Brand.teal, size: 44)
                        text.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    button
                }
            } else {
                HStack(spacing: 16) {
                    IconTile(symbol: "eye.slash", tint: Brand.teal, size: 44)
                    text
                    Spacer(minLength: 12)
                    button
                }
            }
        }
        .padding(16)
        .contentPanel()
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


/// The viewer's source order as a list to drag into place. tvOS has no dragging: there, choose a
/// source, then where it goes; each move is saved at once.

#if !os(tvOS)
#endif




/// A plugin setting listed among a source's titles (aowu's 配置中心, FTY's 我的云盘┃配置). It runs in the plugin, as
/// in TVBox; the window the plugin opens for it is drawn here (`PluginScreen`), and the viewer's taps and typing go
/// back to the plugin's own code.
struct PluginActionPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let video: Video
    let client: CatalogClient
    let action: String
    private enum Phase: Equatable { case running, showing, finished(String?), failed(String) }
    @State private var phase = Phase.running
    @State private var screen = PluginScreen()
    /// What the viewer typed, by field, until it goes to the plugin with the next tap.
    @State private var typed: [Int: String] = [:]
    @State private var sending = false
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            switch phase {
            case .running:
                ProgressView().padding(.vertical, 80).frame(maxWidth: .infinity)
            case .showing:
                if let window = screen.windows.last {
                    PluginWindowView(window: window, typed: $typed, layers: screen.windows.count, send: send)
                        .id(window.id)
                        .disabled(sending)
                }
            case .finished(let message):
                // Back is focusable, so the remote has somewhere to land on Apple TV.
                EmptyResults(symbol: message == nil ? "checkmark.circle" : "info.circle", title: video.name,
                             message: message ?? L10n.text("The plugin finished without a message."),
                             action: L10n.text("Back"), actionSymbol: "chevron.backward") { dismiss() }
                // Each tap runs the setting once more, as a tap on its row does in TVBox: settings that ask for a
                // double tap to confirm (a reset) take two quick taps here. Never disabled, so the second tap counts.
                Button { runAgain() } label: { Label(L10n.text("Run Again"), systemImage: "hand.tap").padding(.horizontal, 8) }
                    .controlButton()
                    .accessibilityIdentifier("pluginSetting.runAgain")
            case .failed(let message):
                EmptyResults(symbol: "exclamationmark.triangle", title: video.name, message: message,
                             action: L10n.text("Try Again")) { Task { await run() } }
            }
        }
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .glassPanel(cornerRadius: 22)
                    .padding(.bottom, 24).padding(.horizontal, 24)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: notice)
        .navigationTitle(video.name)
        .task { await run() }
        .task(id: phase == .showing) {
            // Plugins change their windows on their own (a QR code arriving, a sign-in confirmed): look again.
            guard phase == .showing else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, !sending, let window = screen.windows.last else { continue }
                await deliver(PluginEvent(window: window.id, kind: .poll), quietly: true)
            }
        }
        .onDisappear {
            noticeTask?.cancel()
            guard let window = screen.windows.last else { return }
            let client = client
            Task { _ = try? await client.pluginWindow(PluginEvent(window: window.id, kind: .closeAll)) }
        }
    }

    private func run() async {
        phase = .running
        typed = [:]
        do { show(try await client.runAction(action), first: true) }
        catch is CancellationError { }
        catch { phase = .failed(error.localizedDescription) }
    }

    private func runAgain() {
        Task {
            do { show(try await client.runAction(action), first: true) }
            catch is CancellationError { }
            catch { phase = .failed(error.localizedDescription) }
        }
    }

    /// A page the plugin opens. A sign-in page that only works in its service's app (Bilibili's confirmation page)
    /// goes there when the app is on this device; anything else, or no app, opens as it is.
    private func open(_ link: URL) {
        #if os(iOS)
        let tries = (DriveAppLink.app(opening: link)?.urls ?? []) + [link]
        #else
        let tries = [link]
        #endif
        func attempt(_ index: Int) {
            guard index < tries.count else { return }
            openURL(tries[index]) { opened in if !opened { attempt(index + 1) } }
        }
        attempt(0)
    }

    #if DEBUG
    private static func find(_ text: String, in node: PluginNode) -> PluginNode? {
        if node.tappable, node.spokenText.contains(text) { return node.children.lazy.compactMap { find(text, in: $0) }.first ?? node }
        return node.children.lazy.compactMap { find(text, in: $0) }.first
    }
    #endif

    private func send(_ event: PluginEvent) {
        var event = event
        // Typed text reaches the plugin's fields before the tap runs, as on Android.
        for (field, text) in typed where event.values[field] == nil { event.values[field] = .text(text) }
        Task { await deliver(event, quietly: false) }
    }

    private func deliver(_ event: PluginEvent, quietly: Bool) async {
        if !quietly { sending = true }
        defer { if !quietly { sending = false } }
        do { show(try await client.pluginWindow(event), first: false) }
        catch is CancellationError { }
        catch { if !quietly { phase = .failed(error.localizedDescription) } }
    }

    private func show(_ next: PluginScreen, first: Bool) {
        if screen.windows.last?.id != next.windows.last?.id { typed = [:] }
        screen = next
        for link in next.links { open(link) }
        var said = next.notices.joined(separator: "\n")
        if let copied = next.clipboard {
            // What the plugin copied goes on the pasteboard (Apple TV has none, so it is shown instead).
            #if os(iOS)
            UIPasteboard.general.string = copied
            if said.isEmpty { said = L10n.text("Copied to the clipboard.") }
            #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copied, forType: .string)
            if said.isEmpty { said = L10n.text("Copied to the clipboard.") }
            #else
            said = said.isEmpty ? copied : said + "\n" + copied
            #endif
        }
        if next.windows.isEmpty {
            // The setting is done: what it said stays on the page; with nothing to say the page goes.
            let failure = next.error.map { L10n.text("The plugin stopped with an error: %@", $0) }
            let message = [first ? next.message : nil, said.isEmpty ? nil : said, failure].compactMap { $0 }.joined(separator: "\n")
            if message.isEmpty && !first { dismiss() } else { phase = .finished(message.isEmpty ? nil : message) }
            return
        }
        phase = .showing
        #if DEBUG
        // `-qaPluginTap <text>` taps the first view showing that text in the plugin's first window, for screenshots.
        if first, let wanted = UserDefaults.standard.string(forKey: "qaPluginTap"), let window = next.windows.last,
           let target = window.root.flatMap({ Self.find(wanted, in: $0) }) {
            Task { try? await Task.sleep(for: .seconds(1)); send(PluginEvent(window: window.id, kind: .click, view: target.id)) }
        }
        #endif
        guard !said.isEmpty else { return }
        notice = said
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { notice = nil }
        }
    }
}

/// A QR code in a plugin window (a sign-in page, TVBox's "remote input" page) can't be scanned by the device showing
/// it, so its link opens here. A page the plugin serves from this device (its network address) opens in the app, which
/// has to keep running to answer it; other links open as links do. Apple TV has no browser: its codes are scanned.
private struct PluginCodeLink: View {
    let image: Data
    @State private var link: URL?
    @State private var showsPage = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        #if os(tvOS)
        EmptyView()
        #else
        Group {
            if let link {
                Button { open(link) } label: { Label(L10n.text("Open Link"), systemImage: "link").padding(.horizontal, 8) }
                    .controlButton()
                    .accessibilityIdentifier("pluginSetting.openCode")
            }
        }
        .task(id: image) { link = await Self.decode(image) }
        #if os(iOS)
        .sheet(isPresented: $showsPage) {
            if let link { ConfigCenterView { ConfigCenter.local(link) ?? link } }
        }
        #endif
        #endif
    }

    private func open(_ url: URL) {
        #if os(iOS)
        if ConfigCenter.local(url) != nil { showsPage = true } else { openURL(url) }
        #else
        openURL(ConfigCenter.local(url) ?? url)
        #endif
    }

    /// The web address a QR code in the picture holds, if any.
    nonisolated static func decode(_ data: Data) async -> URL? {
        guard let picture = CIImage(data: data),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        else { return nil }
        for case let code as CIQRCodeFeature in detector.features(in: picture) {
            guard let text = code.messageString?.trimmingCharacters(in: .whitespacesAndNewlines), let url = URL(string: text),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            return url
        }
        return nil
    }
}

/// One plugin window, drawn from the plugin's own views. When the plugin paints its window (most do: white
/// cards), its colors are kept on that surface; a plain Android alert takes the app's look instead.
private struct PluginWindowView: View {
    let window: PluginWindow
    @Binding var typed: [Int: String]
    /// Windows open, this one included: under another one, Back returns to it.
    let layers: Int
    let send: (PluginEvent) -> Void
    #if os(tvOS)
    static let scale = 1.7
    private let width: CGFloat = 1100
    #else
    static let scale = 1.0
    private let width: CGFloat = 620
    #endif

    var body: some View {
        let painted = window.surface.map { $0.alpha > 0.5 } ?? false
        VStack(alignment: .leading, spacing: 14 * Self.scale) {
            if layers > 1 {
                Button { send(PluginEvent(window: window.id, kind: .back)) } label: {
                    Label(L10n.text("Back"), systemImage: "chevron.backward")
                }
                .buttonStyle(.bordered)
            }
            if let title = window.title { Text(title).font(.headline) }
            if let message = window.message { Text(message).font(.body).fixedSize(horizontal: false, vertical: true) }
            if let header = window.header { PluginNodeView(node: header, context: context(painted)) }
            if let root = window.root { PluginNodeView(node: root, context: context(painted)) }
            if !window.items.isEmpty { items }
            if let progress = window.progress { PluginNodeView(node: progress, context: context(painted)) }
            if !window.buttons.isEmpty { buttons }
        }
        .padding(painted ? 0 : 20 * Self.scale)
        .frame(maxWidth: width, alignment: .leading)
        .background {
            if let surface = window.surface, painted {
                RoundedRectangle(cornerRadius: 18 * Self.scale, style: .continuous).fill(surface.color)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18 * Self.scale, style: .continuous))
        .environment(\.colorScheme, painted ? ((window.surface?.luminance ?? 0) > 0.5 ? .light : .dark) : colorSchemeFallback)
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    @Environment(\.colorScheme) private var colorSchemeFallback

    private func context(_ painted: Bool) -> PluginNodeView.Context {
        PluginNodeView.Context(window: window.id, painted: painted, typed: $typed, send: send)
    }

    private var items: some View {
        VStack(spacing: 8) {
            ForEach(Array(window.items.enumerated()), id: \.offset) { index, item in
                Button { send(PluginEvent(window: window.id, kind: .item, index: index)) } label: {
                    HStack {
                        Text(item.text).frame(maxWidth: .infinity, alignment: .leading)
                        if window.choice == .multi {
                            Image(systemName: item.checked == true ? "checkmark.square.fill" : "square").foregroundStyle(.tint)
                        } else if item.checked == true {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PluginTapStyle())
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            ForEach(window.buttons.sorted { order($0.role) < order($1.role) }) { button in
                if button.role == .positive {
                    Button(button.text) { send(PluginEvent(window: window.id, kind: .click, view: button.id)) }
                        .buttonStyle(.borderedProminent).disabled(!button.enabled)
                } else {
                    Button(button.text) { send(PluginEvent(window: window.id, kind: .click, view: button.id)) }
                        .buttonStyle(.bordered).disabled(!button.enabled)
                }
            }
        }
    }

    /// Android's order: neutral first, then negative, positive last.
    private func order(_ role: PluginWindow.Button.Role) -> Int {
        switch role { case .neutral: 0; case .negative: 1; case .positive: 2 }
    }
}

private struct PluginNodeView: View {
    struct Context {
        let window: Int
        /// The window has the plugin's own background, so its colors are kept.
        let painted: Bool
        let typed: Binding<[Int: String]>
        let send: (PluginEvent) -> Void
        func tap(_ node: PluginNode) { send(PluginEvent(window: window, kind: .click, view: node.id)) }
        func change(_ node: PluginNode, _ value: PluginEvent.Value) { send(PluginEvent(window: window, kind: .change, values: [node.id: value])) }
    }
    let node: PluginNode
    let context: Context
    private var scale: Double { PluginWindowView.scale }

    var body: some View {
        content
            .opacity(node.enabled ? (node.alpha ?? 1) : 0.45)
    }

    @ViewBuilder private var content: some View {
        switch node.kind {
        case .stack, .scroll, .radios: tappable(container)
        case .text: tappable(label(node))
        case .button:
            Button { context.tap(node) } label: { label(node).frame(maxWidth: node.fillWidth ? .infinity : nil) }
                .buttonStyle(.bordered).disabled(!node.enabled)
        case .input: field
        case .check, .switch:
            Toggle(isOn: Binding(get: { node.checked }, set: { context.change(node, .on($0)) })) { label(node) }
                .disabled(!node.enabled)
        case .radio:
            Button { if !node.checked { context.change(node, .on(true)) } } label: {
                HStack(spacing: 10) {
                    Image(systemName: node.checked ? "largecircle.fill.circle" : "circle").foregroundStyle(.tint)
                    label(node)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PluginTapStyle())
        case .progress:
            if node.indeterminate { ProgressView().frame(maxWidth: .infinity) }
            else { ProgressView(value: Double(node.progress - node.minimum), total: Double(max(1, node.maximum - node.minimum))) }
        case .slider: slider
        case .image: tappable(picture)
        case .view: spacer
        }
    }

    // Containers: Android's LinearLayout and FrameLayout, each child with its share of the line.
    @ViewBuilder private var container: some View {
        let spacing = 8 * scale
        switch node.axis {
        case .h:
            let row = HStack(alignment: .center, spacing: spacing) { children }
            if node.kind == .scroll { ScrollView(.horizontal, showsIndicators: false) { row } }
            else { ViewThatFits(in: .horizontal) { row; ScrollView(.horizontal, showsIndicators: false) { row } } }
        case .z:
            ZStack(alignment: .topLeading) { children }
        case .v:
            VStack(alignment: node.centered ? .center : .leading, spacing: spacing) { children }
        }
    }

    @ViewBuilder private var children: some View {
        ForEach(node.children) { child in
            let view = PluginNodeView(node: child, context: context)
            if node.axis == .h, child.weight != nil { view.frame(maxWidth: .infinity, alignment: child.trailing ? .trailing : .leading) }
            else if node.axis == .v, child.fillWidth { view.frame(maxWidth: .infinity, alignment: child.centered ? .center : child.trailing ? .trailing : .leading) }
            else { view }
        }
    }

    /// A view with a listener is a button; one the plugin paints gets its color and rounded plate.
    @ViewBuilder private func tappable(_ inner: some View) -> some View {
        let plated = inner
            .padding(insets)
            .background { if let plate { RoundedRectangle(cornerRadius: 10 * scale, style: .continuous).fill(plate) } }
        if node.tappable {
            Button { context.tap(node) } label: { plated.contentShape(Rectangle()) }
                .buttonStyle(PluginTapStyle())
                .disabled(!node.enabled)
                .accessibilityLabel(node.spokenText)
        } else {
            plated
        }
    }

    /// The plugin's own padding; a painted plate without one still gets room around its content.
    private var insets: EdgeInsets {
        if let p = node.padding { return EdgeInsets(top: p[1] * scale, leading: p[0] * scale, bottom: p[3] * scale, trailing: p[2] * scale) }
        let room = plate == nil ? 0 : 10 * scale
        return EdgeInsets(top: room, leading: room, bottom: room, trailing: room)
    }

    private var plate: Color? {
        guard let background = node.background, background.alpha > 0.05 else { return nil }
        if context.painted { return background.color }
        return node.selected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15)
    }

    private func label(_ node: PluginNode) -> some View {
        Text(node.text ?? "")
            .font(.system(size: (node.size ?? 15) * scale, weight: node.bold ? .semibold : .regular))
            .foregroundStyle(textColor(node))
            .lineLimit(node.lines)
            .multilineTextAlignment(node.centered ? .center : node.trailing ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func textColor(_ node: PluginNode) -> Color {
        guard context.painted, let color = node.color else { return node.selected ? .accentColor : .primary }
        return color.color
    }

    @ViewBuilder private var field: some View {
        let text = Binding(get: { context.typed.wrappedValue[node.id] ?? node.text ?? "" },
                           set: { context.typed.wrappedValue[node.id] = $0 })
        let prompt = Text(node.hint ?? "")
        Group {
            if node.secure { SecureField(node.hint ?? "", text: text, prompt: prompt) }
            else if node.multiline { TextField(node.hint ?? "", text: text, prompt: prompt, axis: .vertical).lineLimit(3...8) }
            else { TextField(node.hint ?? "", text: text, prompt: prompt) }
        }
        #if !os(tvOS)
        .textFieldStyle(.roundedBorder)
        #endif
        #if os(iOS)
        .keyboardType(node.keyboard == "number" ? .numberPad : node.keyboard == "url" ? .URL : node.keyboard == "email" ? .emailAddress : .default)
        .textInputAutocapitalization(.never)
        #endif
        .autocorrectionDisabled()
        .onSubmit { context.send(PluginEvent(window: context.window, kind: .submit, view: node.id, values: [node.id: .text(text.wrappedValue)])) }
        .disabled(!node.enabled)
    }

    @ViewBuilder private var slider: some View {
        #if os(tvOS)
        HStack(spacing: 20) {
            Button { context.change(node, .number(max(node.minimum, node.progress - node.step))) } label: { Image(systemName: "minus") }
            Text("\(node.progress)").monospacedDigit().frame(minWidth: 80)
            Button { context.change(node, .number(min(node.maximum, node.progress + node.step))) } label: { Image(systemName: "plus") }
        }
        #else
        PluginSlider(node: node) { context.change(node, .number($0)) }
        #endif
    }

    @ViewBuilder private var picture: some View {
        if let data = node.image, let image = PlatformImage(data: data) {
            let width = (node.width ?? Double(image.size.width) / 2) * scale, height = (node.height ?? Double(image.size.height) / 2) * scale
            #if os(macOS)
            let drawn = Image(nsImage: image)
            #else
            let drawn = Image(uiImage: image)
            #endif
            // Plugins' pictures are mostly QR codes: keep their pixels sharp.
            VStack(spacing: 10 * scale) {
                drawn.resizable().interpolation(.none)
                    .aspectRatio(contentMode: node.fill ? .fill : .fit)
                    .overlay { touchArea }
                    .frame(maxWidth: width, maxHeight: height)
                    .clipped()
                if !node.touch { PluginCodeLink(image: data) }
            }
            .frame(maxWidth: .infinity)
        } else {
            spacer
        }
    }

    /// On a picture the plugin reads touches on (a color wheel), a tap or the end of a drag sends where it landed.
    @ViewBuilder private var touchArea: some View {
        #if os(tvOS)
        EmptyView()
        #else
        if node.touch, node.enabled {
            GeometryReader { frame in
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { drag in
                        guard frame.size.width > 0, frame.size.height > 0 else { return }
                        context.send(PluginEvent(window: context.window, kind: .touch, view: node.id,
                                                 x: drag.location.x / frame.size.width, y: drag.location.y / frame.size.height))
                    })
            }
        }
        #endif
    }

    /// An empty view: a gap, or a line or block when the plugin colors it.
    @ViewBuilder private var spacer: some View {
        if let plate, let height = node.height {
            Rectangle().fill(plate).frame(height: CGFloat(height * scale))
                .frame(maxWidth: node.fillWidth ? .infinity : node.width.map { CGFloat($0 * scale) } ?? .infinity)
        } else if node.weight != nil {
            Spacer(minLength: 0)
        } else if let height = node.height {
            Color.clear.frame(height: CGFloat(height * scale))
        }
    }
}

#if !os(tvOS)
/// A plugin's SeekBar: the plugin hears the value once the drag ends, as Android's onStopTrackingTouch.
private struct PluginSlider: View {
    let node: PluginNode
    let commit: (Int) -> Void
    @State private var value: Double?
    var body: some View {
        HStack {
            Slider(value: Binding(get: { value ?? Double(node.progress) }, set: { value = $0 }),
                   in: Double(node.minimum)...Double(max(node.minimum + 1, node.maximum)), step: Double(node.step)) { editing in
                if !editing, let value { commit(Int(value)); self.value = nil }
            }
            Text("\(Int(value ?? Double(node.progress)))").monospacedDigit().frame(minWidth: 40)
        }
    }
}
#endif

/// Taps on a plugin's own rows: no extra chrome (the plugin paints them), a lift on Apple TV focus.
private struct PluginTapStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        #if os(tvOS)
        PluginFocusLift(label: configuration.label, pressed: configuration.isPressed)
        #else
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
        #endif
    }
}

#if os(tvOS)
private struct PluginFocusLift<Label: View>: View {
    @Environment(\.isFocused) private var focused
    let label: Label
    let pressed: Bool
    var body: some View {
        label
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor, lineWidth: focused ? 4 : 0) }
            .scaleEffect(pressed ? 0.98 : focused ? 1.03 : 1)
            .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 12, y: 6)
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}
#endif

private extension PluginColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

#if os(macOS)
private typealias PlatformImage = NSImage
#else
private typealias PlatformImage = UIImage
#endif










extension View {
    /// The page's title bar, or none where the page sets its title itself.
    @ViewBuilder func screenTitle(_ title: String, shown: Bool) -> some View {
        #if os(tvOS)
        if shown { screenTitle(title) } else { toolbar(.hidden, for: .navigationBar) }
        #elseif os(macOS)
        // The Mac's pages that set their own title name the window themselves (the video page once past its hero).
        if shown { screenTitle(title) } else { self }
        #else
        screenTitle(title)
        #endif
    }
}

#if os(tvOS)
extension VideoDetailView {
    /// Apple TV's page for a Bilibili video (#256): the page's own Play, parts and notices inside BilibiliTVVideoPage.
    var bilibiliTVPage: some View {
        let current = currentVideo()
        return BilibiliTVVideoPage(
            bvid: video.id, title: detail?.name ?? video.name, cover: current.poster, coverHeaders: current.posterHeaders,
            synopsis: detail.map(synopsisText) ?? "", creator: bilibiliCreator, client: client,
            saved: store.favorites.contains(videoFavorite()), toggleSaved: { store.favorites.toggle(videoFavorite()) },
            download: { choosingDownloads = true }, hasParts: activeEpisodes.count > 1
        ) {
            bilibiliTVPlay
        } parts: {
            episodePanel
        } status: {
            playbackBanner
        }
    }

    /// Apple TV's page for every other video, in the Bilibili page's language (Discover's title page): TMDB's backdrop, or
    /// the cover, across the whole screen; over it the logo or title, the facts, Play with Download and Favorite under it
    /// and the synopsis beside them; then the episodes, the people, facts and related titles over the frosted picture.
    var tvDetailPage: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 60) {
                    tvDetailHero.id("hero")
                    VStack(alignment: .leading, spacing: 44) {
                        sourceExtras
                        episodePanel
                        sourceRelated
                        tmdbExtras
                    }
                    .padding(.horizontal, TVDetailMetrics.gutter)
                }
                .padding(.bottom, 90)
            }
            .scrollClipDisabled()
            .modifier(DiscoverTVScrolled(scrolled: $tvScrolled))
            .background {
                if let backdrop = tmdb.details?.backdrop {
                    TVCoverBackdrop(url: backdrop, headers: [:], frosted: tvScrolled)
                } else {
                    TVCoverBackdrop(url: video.poster, headers: video.posterHeaders, frosted: tvScrolled)
                }
            }
            .ignoresSafeArea()
            .foregroundStyle(.white).preferredColorScheme(.dark)
            .animation(.smooth(duration: 0.45), value: tmdb.details)
            .animation(.smooth(duration: 0.3), value: tmdb.phase)
            // Coming back up from the rows, the hero comes back whole, not just as far as the focused button.
            .onChange(of: playFocused || tvHeroFocus != nil) { _, inHero in
                if inHero { withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo("hero", anchor: .top) } }
            }
            .fullScreenCover(isPresented: $showsTVSynopsis) { tvSynopsisScreen }
        }
    }

    private var tvDetailHero: some View {
        let text = detail.map(synopsisText)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                playbackBanner
                tmdbStatus
            }
            .frame(maxWidth: 1200, alignment: .leading)
            VStack(alignment: .leading, spacing: 12) {
                HeroTitleArt(logo: tmdb.details?.logo, name: tmdb.details?.name ?? currentVideo().name)
                Text(heroFacts.isEmpty ? " " : heroFacts).font(.system(size: 28, weight: .medium)).lineLimit(1).opacity(0.7)
                if let tagline = tmdb.details?.tagline, !tagline.isEmpty {
                    Text(tagline).font(.system(size: 26).italic()).lineLimit(1).opacity(0.6)
                }
            }
            HStack(alignment: .top, spacing: 72) {
                VStack(alignment: .leading, spacing: 22) {
                    bilibiliTVPlay
                    HStack(alignment: .top, spacing: 16) {
                        tvPlate("arrow.down.circle", caption: L10n.text("Download"), id: "detail.download", focus: .download) {
                            choosingDownloads = true
                        }
                        let saved = store.favorites.contains(videoFavorite())
                        tvPlate(saved ? "heart.fill" : "heart", tint: saved ? Brand.rose : nil, caption: L10n.text(saved ? "Saved" : "Favorite"),
                                id: "detail.favorite", focus: .favorite) {
                            store.favorites.toggle(videoFavorite())
                        }
                    }
                    .disabled(detail?.episodes.isEmpty ?? true)
                }
                .frame(width: TVDetailMetrics.actionsWidth)
                .focusSection()
                if !text.isEmpty {
                    Button { showsTVSynopsis = true } label: {
                        Text(text).font(.system(size: 26)).lineSpacing(4).lineLimit(4).multilineTextAlignment(.leading)
                            .frame(maxWidth: 1000, alignment: .leading)
                    }
                    .buttonStyle(BilibiliTVPlateStyle())
                    .focused($tvHeroFocus, equals: .synopsis)
                    // The plate's padding outside the column, so the text lines up with Play's top.
                    .padding(.leading, -BilibiliTVPlateStyle.inset).padding(.top, -BilibiliTVPlateStyle.inset)
                    .accessibilityIdentifier("detail.synopsis")
                    .focusSection()
                }
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, TVDetailMetrics.gutter)
        .frame(maxWidth: .infinity, minHeight: 940, alignment: .bottomLeading)
    }

    /// One of the hero's square glass plates under Play, with its caption under it.
    private func tvPlate(_ symbol: String, tint: Color? = nil, caption: String, id: String, focus: TVHeroItem,
                         action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Button(action: action) { Image(systemName: symbol).foregroundStyle(tint ?? .primary).frame(maxWidth: .infinity) }
                .buttonStyle(DiscoverTVActionStyle(height: 76, font: 30, corner: 24))
                .focused($tvHeroFocus, equals: focus)
                .accessibilityLabel(caption).accessibilityIdentifier(id)
            Text(caption).font(.system(size: 22, weight: .medium)).lineLimit(1).opacity(0.6)
        }
        .frame(width: TVDetailMetrics.plateWidth)
    }

    /// The whole synopsis over the frosted picture: the hero shows four lines of it.
    private var tvSynopsisScreen: some View {
        ZStack(alignment: .bottomLeading) {
            TVCoverBackdrop(url: tmdb.details?.backdrop ?? video.poster, headers: tmdb.details?.backdrop == nil ? video.posterHeaders : [:],
                            frosted: true)
            VStack(alignment: .leading, spacing: 24) {
                Text(tmdb.details?.name ?? currentVideo().name).font(.system(size: 52, weight: .bold)).lineLimit(2)
                if !heroFacts.isEmpty { Text(heroFacts).font(.system(size: 26)).opacity(0.6) }
                Text(detail.map(synopsisText) ?? "").font(.system(size: 30)).lineSpacing(6).lineLimit(16)
            }
            .frame(maxWidth: 1300, alignment: .leading)
            .padding(TVDetailMetrics.gutter)
            // Something must hold focus for Menu to close the page.
            .focusable()
        }
        .ignoresSafeArea().foregroundStyle(.white).preferredColorScheme(.dark)
    }

    /// Play, or Continue the part watched last, as wide as the actions under it.
    @ViewBuilder private var bilibiliTVPlay: some View {
        let continuation = detail.flatMap { watchHistory?.continuation(in: $0.episodes) }
        if let detail, let first = continuation ?? activeEpisodes.first ?? detail.episodes.first {
            Button { startRequest { await play(first) } } label: {
                HStack(spacing: 12) {
                    if loadingEpisode == first.id { ProgressView() } else { Image(systemName: "play.fill") }
                    Text(L10n.text(first.id == continuation?.id ? "Continue" : "Play"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(DiscoverTVActionStyle(height: 82, font: 30))
            .focused($playFocused)
            .accessibilityIdentifier("detail.play")
        } else if detail == nil, error == nil {
            // Holds focus while the details load, so Back leaves the page.
            SkeletonBlock(cornerRadius: 41).frame(height: 82).loadingFocus(takeFocus: true) { dismiss() }
        } else {
            playControl
        }
    }
}
#endif

extension SiteView {
    /// An UP主's space (`up_<mid>` and its other listings).
    var isBilibiliSpace: Bool { site.isBilibili && folder.flatMap { BilibiliAPI.creator(category: $0.id) } != nil }

    /// Bilibili's videos as its own apps show them on iPhone, iPad and the Mac: 16:9 covers, two or more across, rather
    /// than cropped into posters. Anime and films (whose covers are posters) keep the posters.
    var showsBilibiliTiles: Bool {
        #if os(tvOS)
        false
        #else
        site.isBilibili && browser.videos.first.map { BilibiliAPI.isVideo($0.id) } == true
        #endif
    }

    static var bilibiliColumns: [GridItem] {
        #if os(macOS)
        [GridItem(.adaptive(minimum: 220), spacing: 18, alignment: .top)]
        #else
        [GridItem(.adaptive(minimum: 160), spacing: DiscoverLayout.spacing, alignment: .top)]
        #endif
    }

    /// An UP主's space on Apple TV: its own page (`BilibiliTVSpacePage`), without the source's search field and banner.
    var showsBilibiliTVSpace: Bool {
        #if os(tvOS)
        site.isBilibili && folder.flatMap { BilibiliAPI.creator(category: $0.id) } != nil
        #else
        false
        #endif
    }
}

#if os(tvOS)
extension SiteView {
    @ViewBuilder var bilibiliTVSpace: some View {
        if let folder, let mid = BilibiliAPI.creator(category: folder.id) {
            BilibiliTVSpacePage(mid: mid, name: folder.name, tabs: BilibiliSpaceHeader.tabs(mid),
                                category: browser.category.isEmpty ? folder.id : browser.category, latest: browser.videos.first,
                                open: { id in startRequest { await browser.load(.list(category: id, query: "", page: 1), client: client) } }) {
                spaceGrid
            }
        }
    }

    /// The space's listing as Bilibili's 16:9 tiles, four across, with the page's loading, error and Load More states.
    @ViewBuilder private var spaceGrid: some View {
        if let error = browser.error {
            ErrorStateCard(
                title: L10n.text("Unable to load this source"),
                message: L10n.text("Try again, or choose another source to keep watching."),
                details: error,
                retry: { startRequest { await browser.load(browser.request, client: client) } },
                goBack: { dismiss() },
                busy: browser.busy
            )
        } else if browser.videos.isEmpty && browser.loaded && !browser.busy {
            EmptyResults(symbol: "film", title: L10n.text("No Videos"))
        }
        LazyVGrid(columns: BilibiliTVSpacePage<EmptyView>.columns, alignment: .leading, spacing: 56) {
            if browser.videos.isEmpty && browser.error == nil && (browser.busy || !browser.loaded) {
                ForEach(0..<8, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)).aspectRatio(16.0 / 9.0, contentMode: .fit)
                }
            }
            ForEach(browser.videos) { video in
                RouteLink { CatalogDestination(video: video, client: client) } label: { BilibiliVideoTile(video: video) }
                    .cardButton()
                    .onAppear {
                        guard browser.moreError == nil, video.id == browser.videos.last?.id else { return }
                        Task { await loadMore() }
                    }
            }
        }
        .opacity(browser.busy && !browser.videos.isEmpty ? 0.55 : 1).animation(.smooth, value: browser.busy)
        if !browser.videos.isEmpty && (browser.hasMore || browser.loadingMore || browser.moreError != nil) {
            loadMoreFooter.tvFocusSection()
        }
    }
}
#else
extension SiteView {
    var bilibiliTVSpace: some View { EmptyView() }
}
#endif

#if os(tvOS) || os(macOS)
/// The title as TMDB's logo when it has one (the name until the logo is in, and instead of one that fails), else the
/// name. Apple TV's size by default; the Mac's hero passes its own.
struct HeroTitleArt: View {
    let logo: URL?
    let name: String
    var fontSize: CGFloat = 64
    var logoHeight: CGFloat = 170
    var logoMaxWidth: CGFloat = 720
    var textMaxWidth: CGFloat = 1300
    @State private var aspect: CGFloat?
    private var nameText: some View {
        Text(name).font(.system(size: fontSize, weight: .bold)).lineLimit(2).minimumScaleFactor(0.7)
            .frame(maxWidth: textMaxWidth, alignment: .leading)
            .shadow(color: .black.opacity(0.45), radius: fontSize / 5)
    }
    var body: some View {
        if let logo {
            // Wide logos get a width limit, tall ones a height limit.
            let ratio = max(aspect ?? 3, 0.5)
            let width = min(logoMaxWidth, logoHeight * ratio)
            TMDBArtwork(url: logo, maxPixels: 1000, fill: false, aspect: $aspect)
                .frame(width: aspect == nil ? nil : width, height: aspect == nil ? nil : width / ratio, alignment: .leading)
                .shadow(color: .black.opacity(0.35), radius: 16)
                .overlay(alignment: .leading) { if aspect == nil { nameText } }
                .accessibilityLabel(name)
        } else {
            nameText
        }
    }
}
#endif

#if os(tvOS)
/// The cover behind Apple TV's loading page, as the Bilibili page's: a landscape cover across the screen, sharp; a
/// poster, which would crop to a few enlarged pixels, as a soft blur of its colours. Darker toward the text.
enum TVHeroItem: Hashable { case download, favorite, synopsis }

private enum TVDetailMetrics {
    static let gutter: CGFloat = 96
    /// Play, and the plates under it.
    static let actionsWidth: CGFloat = 540
    static let plateWidth: CGFloat = 123
}

private struct TVCoverBackdrop: View {
    let url: URL?
    let headers: [String: String]
    /// Past the hero: frosted, so the rows read over it.
    var frosted = false
    @State private var image: CGImage?
    var body: some View {
        ZStack {
            Color.black
            if let image {
                let landscape = CGFloat(image.width) / CGFloat(max(1, image.height)) >= 1.3
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).clipped()
                    .blur(radius: landscape ? 0 : 60, opaque: true)
                    .saturation(landscape ? 1 : 1.25)
                    .transition(.opacity)
            }
            LinearGradient(stops: [.init(color: .black.opacity(0.85), location: 0), .init(color: .black.opacity(0.55), location: 0.5),
                                   .init(color: .clear, location: 0.85)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.2), .init(color: .black.opacity(0.92), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            Rectangle().fill(.regularMaterial).opacity(frosted ? 1 : 0)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.35), value: frosted)
        .animation(.easeInOut(duration: 0.4), value: image != nil)
        .task(id: url) { if let url { image = await TMDBArtwork.load(url, maxPixels: 1600, headers: headers) } }
    }
}
#endif

extension VideoDetailView {
    /// TMDB's facts (2026 · Drama · ★ 7.0), else the source's note, year and name: the line under the hero's title.
    private var heroFacts: String {
        if !tmdb.facts.isEmpty { return tmdb.facts }
        let current = currentVideo()
        return [current.remarks, current.year ?? "", client.site.name].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

#if os(macOS)
// MARK: The Mac's video page

/// The Mac's video page in Apple TV's language: the backdrop across the window, under the toolbar and the sidebar; over
/// its foot the title once, one line of facts, Play with the actions as glass plates under it, and the synopsis (for
/// Bilibili, the UP主 and the description) beside them; then the episodes and the rest on the page. The toolbar takes
/// the title once the hero has scrolled away.
extension VideoDetailView {
    var macPage: some View {
        Group {
            if client.site.isBilibili && BilibiliAPI.isVideo(video.id) { bilibiliMacPage } else { macDetailPage }
        }
        .navigationTitle(macPastHero ? (detail?.name ?? video.name) : "")
        .artUnderToolbar()
    }

    private var bilibiliMacPage: some View {
        let current = currentVideo()
        return BilibiliMacVideoPage(
            bvid: video.id, title: detail?.name ?? video.name, cover: current.poster, coverHeaders: current.posterHeaders,
            synopsis: detail.map(synopsisText) ?? "", creator: bilibiliCreator, client: client,
            saved: store.favorites.contains(videoFavorite()), toggleSaved: { store.favorites.toggle(videoFavorite()) },
            download: { choosingDownloads = true }, hasParts: activeEpisodes.count > 1, pastHero: $macPastHero
        ) {
            macPlay
        } parts: {
            episodePanel
        } status: {
            playbackBanner
            if detail == nil, let error { errorCard(error) }
        }
    }

    private var macDetailPage: some View {
        GeometryReader { geometry in
            let height = MacHeroMetrics.height(for: geometry.size)
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    macHero(height: height, width: geometry.size.width)
                    VStack(alignment: .leading, spacing: 26) {
                        playbackBanner
                        tmdbStatus
                        if detail != nil {
                            sourceExtras
                            episodePanel
                            sourceRelated
                            tmdbExtras
                        } else if let error {
                            errorCard(error)
                        }
                    }
                    .padding(.horizontal, MacHeroMetrics.gutter)
                }
                .padding(.bottom, 40)
            }
            // From the window's top edge: the picture runs on under the toolbar, as Discover's title page.
            .ignoresSafeArea(edges: .top)
            .macHeroScroll(heroHeight: height, past: $macPastHero)
        }
        .animation(.smooth(duration: 0.45), value: tmdb.details)
        .animation(.smooth(duration: 0.3), value: tmdb.phase)
    }

    private func macHero(height: CGFloat, width: CGFloat) -> some View {
        let text = detail.map(synopsisText)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let backdrop = tmdb.details?.backdrop
        return MacVideoHero(height: height, width: width, backdrop: backdrop ?? video.poster,
                            backdropHeaders: backdrop == nil ? video.posterHeaders : [:]) {
            VStack(alignment: .leading, spacing: 8) {
                HeroTitleArt(logo: tmdb.details?.logo, name: tmdb.details?.name ?? currentVideo().name,
                             fontSize: 40, logoHeight: 96, logoMaxWidth: 420, textMaxWidth: 760)
                // A line kept while the facts load, so the hero doesn't move when they come in.
                Text(heroFacts.isEmpty ? " " : heroFacts).font(.system(size: 14, weight: .medium)).lineLimit(1).opacity(0.75)
                if let tagline = tmdb.details?.tagline, !tagline.isEmpty {
                    Text(tagline).font(.system(size: 14).italic()).lineLimit(1).opacity(0.6)
                }
            }
        } actions: {
            VStack(alignment: .leading, spacing: 18) {
                macPlay
                HStack(alignment: .top, spacing: 6) {
                    MacPlate(symbol: "arrow.down.circle", caption: L10n.text("Download"), id: "detail.download") { choosingDownloads = true }
                    let saved = store.favorites.contains(videoFavorite())
                    MacPlate(symbol: "heart", caption: L10n.text(saved ? "Saved" : "Favorite"), on: saved, id: "detail.favorite") {
                        store.favorites.toggle(videoFavorite())
                    }
                }
                .disabled(detail?.episodes.isEmpty ?? true)
            }
        } side: {
            if !text.isEmpty { MacHeroSynopsis(text: text) }
        }
    }

    /// Play, or Continue the episode watched last, as wide as the plates under it; Retry when the details failed.
    @ViewBuilder private var macPlay: some View {
        let continuation = detail.flatMap { watchHistory?.continuation(in: $0.episodes) }
        if let detail, let first = continuation ?? activeEpisodes.first ?? detail.episodes.first {
            Button { startRequest { await play(first) } } label: {
                HStack(spacing: 8) {
                    if loadingEpisode == first.id { ProgressView().appControlSize(.small) } else { Image(systemName: "play.fill") }
                    Text(L10n.text(first.id == continuation?.id ? "Continue" : "Play"))
                }
                .font(.headline).lineLimit(1).frame(maxWidth: .infinity)
            }
            .controlButton(prominent: true).tint(Brand.accent).appControlSize(.large)
            .accessibilityIdentifier("detail.play")
        } else if detail == nil, error == nil {
            SkeletonBlock(cornerRadius: 20).frame(height: 40)
        } else if detail == nil {
            Button { startRequest { await loadDetail() } } label: {
                Label(L10n.text("Retry"), systemImage: "arrow.clockwise").font(.headline).frame(maxWidth: .infinity)
            }
            .controlButton(prominent: true).tint(Brand.accent).appControlSize(.large)
            .disabled(busy)
            .accessibilityIdentifier("detail.retry")
        }
    }
}

enum MacHeroMetrics {
    static let gutter: CGFloat = 40
    /// Play, and the plates under it: room for five.
    static let actionsWidth: CGFloat = 344
    /// Below this width the synopsis goes under the actions.
    static let compactWidth: CGFloat = 820
    /// Most of the window, as Apple TV's hero fills the screen, with the first row peeking in under it.
    static func height(for size: CGSize) -> CGFloat { max(420, min(size.height * 0.8, size.width * 0.6, 760)) }
}

/// The hero of the Mac's video pages: the backdrop behind it all, and at its foot the heading, then the actions with the
/// side column (the synopsis, the UP主) beside them, or under them in a narrow window.
struct MacVideoHero<Heading: View, Actions: View, Side: View>: View {
    let height: CGFloat
    let width: CGFloat
    let backdrop: URL?
    var backdropHeaders: [String: String] = [:]
    /// A picture already loaded (a comic's cover, which its source fetches), in place of `backdrop`.
    var backdropImage: CGImage? = nil
    /// A portrait cover shown large in the top trailing corner over the blur (a comic's), as Apple TV's Bilibili page.
    var art: CGImage? = nil
    @ViewBuilder let heading: Heading
    @ViewBuilder let actions: Actions
    @ViewBuilder let side: Side

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading
            if width < MacHeroMetrics.compactWidth {
                VStack(alignment: .leading, spacing: 22) {
                    actions.frame(width: MacHeroMetrics.actionsWidth, alignment: .leading)
                    side.frame(maxWidth: 560, alignment: .leading)
                }
            } else {
                HStack(alignment: .top, spacing: 48) {
                    actions.frame(width: MacHeroMetrics.actionsWidth, alignment: .leading)
                    side.frame(maxWidth: 560, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, MacHeroMetrics.gutter).padding(.bottom, 44)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .bottomLeading)
        .background { MacHeroBackdrop(url: backdrop, headers: backdropHeaders, picture: backdropImage, art: art).discoverFullBleed() }
        .foregroundStyle(.white)
    }
}

/// The picture behind the Mac's hero, as Apple TV's: a landscape cover sharp across it; a poster, which would crop to a
/// few enlarged pixels, as a soft blur of its colours. Darker toward the text, and its foot fades into the page.
struct MacHeroBackdrop: View {
    let url: URL?
    let headers: [String: String]
    var picture: CGImage? = nil
    var art: CGImage? = nil
    @State private var image: CGImage?

    /// The picture shown sharp in the corner: the art handed in, else a portrait poster, which the blur alone would hide
    /// (a title without TMDB's backdrop has only the source's poster).
    private var shownArt: CGImage? {
        if let art { return art }
        guard let poster = picture ?? image, CGFloat(poster.width) / CGFloat(max(1, poster.height)) < 1.3 else { return nil }
        return poster
    }
    var body: some View {
        ZStack {
            Color.black
            if let image = picture ?? image {
                let landscape = CGFloat(image.width) / CGFloat(max(1, image.height)) >= 1.3
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).clipped()
                    .blur(radius: landscape ? 0 : 50, opaque: true)
                    .saturation(landscape ? 1 : 1.25)
                    .transition(.opacity)
            }
            if let art = shownArt {
                // Sharp, at about its own size from the top trailing corner, its leading edge and foot fading into the blur.
                GeometryReader { proxy in
                    Image(decorative: art, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: proxy.size.width * 0.55, maxHeight: proxy.size.height * 0.86)
                        .mask {
                            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.4)],
                                           startPoint: .leading, endPoint: .trailing)
                        }
                        .mask {
                            LinearGradient(stops: [.init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                .transition(.opacity)
            }
            LinearGradient(stops: [.init(color: .black.opacity(0.8), location: 0), .init(color: .black.opacity(0.45), location: 0.45),
                                   .init(color: .clear, location: 0.8)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: .black.opacity(0.85), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .mask {
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.93), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 0.4), value: (picture ?? image) != nil)
        // A new picture (TMDB's backdrop after the cover) replaces the old one once it is in.
        .task(id: url) { if let url, let loaded = await TMDBArtwork.load(url, maxPixels: 2000, headers: headers) { image = loaded } }
    }
}

/// One of the hero's round glass plates with its word or count under it.
struct MacPlate: View {
    let symbol: String
    let caption: String
    var on = false
    var tint: Color = Brand.rose
    let id: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { WatchPlateLabel(symbol: symbol, caption: caption, on: on, tint: tint) }
            .buttonStyle(.plain)
            .accessibilityLabel(caption).accessibilityIdentifier(id).help(caption)
    }
}

/// A plate that opens a menu (Bilibili's coins, More).
struct MacPlateMenu<Content: View>: View {
    let symbol: String
    let caption: String
    var on = false
    var tint: Color = Brand.rose
    let title: String
    let id: String
    @ViewBuilder let content: Content
    var body: some View {
        Menu { content } label: { WatchPlateLabel(symbol: symbol, caption: caption, on: on, tint: tint) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(title).accessibilityIdentifier(id).help(title)
    }
}

/// A few lines of the synopsis beside the actions; a click shows all of it.
struct MacHeroSynopsis: View {
    let text: String
    var lines = 4
    @State private var shown = false
    var body: some View {
        Button { shown = true } label: {
            Text(text).font(.system(size: 14)).lineSpacing(3).lineLimit(lines).multilineTextAlignment(.leading)
                .opacity(0.85).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("detail.synopsis")
        .popover(isPresented: $shown, arrowEdge: .top) {
            let full = Text(text).font(.body).lineSpacing(3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(20)
            if text.count > 500 {
                ScrollView { full }.frame(width: 460, height: 440)
            } else {
                full.frame(width: 460)
            }
        }
    }
}

extension View {
    /// Tells the page when its hero has scrolled away, so the toolbar can take the title.
    func macHeroScroll(heroHeight: CGFloat, past: Binding<Bool>) -> some View {
        onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > heroHeight - 140 } action: { _, value in
            past.wrappedValue = value
        }
    }
}
#endif
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
