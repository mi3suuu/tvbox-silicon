import SwiftUI
import TVCore

/// One source in the order editor: its place, icon, name and health.
private struct SourceOrderRow: View {
    @Environment(Store.self) private var store
    let site: Site
    let rank: Int
    #if os(tvOS)
    private let icon: CGFloat = 56, rankWidth: CGFloat = 44
    private let title = Font.system(size: 29, weight: .medium), caption = Font.system(size: 22)
    #else
    private let icon: CGFloat = 32, rankWidth: CGFloat = 26
    private let title = Font.body.weight(.medium), caption = Font.caption
    #endif
    var body: some View {
        let label = SourceLabel(site.name)
        let detail = (label.parts.dropFirst() + [site.isBuiltIn ? L10n.text("Built-in") : nil].compactMap { $0 }).joined(separator: " · ")
        HStack(spacing: 12) {
            Text(rank, format: .number).font(caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(rank <= 3 ? Color.primary : Color.secondary)
                .frame(minWidth: rankWidth, alignment: .trailing)
            SourceIcon(site: site, label: label, size: icon)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(label.parts[0]).font(title).lineLimit(1)
                    SourceHealthDot(status: store.health(of: site))
                }
                if !detail.isEmpty { Text(detail).font(caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            #if os(macOS)
            // macOS lists draw no handle of their own; any part of the row drags.
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            #endif
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// The viewer's source order as a list to drag into place. tvOS has no dragging: there, choose a
/// source, then where it goes; each move is saved at once.
struct SourceOrderEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var sites: [Site]
    /// What Reset goes back to.
    private let automatic: [Site]
    #if os(tvOS)
    @State private var moving: Site?
    #endif

    init(sites: [Site], automatic: [Site]) {
        _sites = State(initialValue: sites)
        self.automatic = automatic
    }

    private var isAutomatic: Bool { sites.map(\.id) == automatic.map(\.id) }

    private func save() {
        if let config = store.subscription { store.sourceOrder.save(sites, origin: config.origin) }
    }

    var body: some View {
        #if os(tvOS)
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Choose a source to move it. Sources at the top are searched first, and their results are listed first."))
                        .font(.system(size: 24)).foregroundStyle(.secondary).padding(.bottom, 12)
                    ForEach(Array(sites.enumerated()), id: \.element.id) { index, site in
                        Button { moving = site } label: { SourceOrderRow(site: site, rank: index + 1).frame(maxWidth: .infinity) }
                            .glassRow()
                            .accessibilityIdentifier("sources.order.row." + site.key)
                    }
                    TVSettingsAction(title: L10n.text("Reset"), destructive: true) {
                        withAnimation(.smooth) { sites = automatic }
                        save()
                    }
                    .disabled(isAutomatic)
                    .padding(.top, 16)
                }
                .glassRowInsets()
            }
            .screenTitle(L10n.text("Arrange Sources"))
            .screenBackdrop()
            .confirmationDialog(moving.map { SourceLabel($0.name).parts[0] } ?? "",
                                isPresented: Binding { moving != nil } set: { if !$0 { moving = nil } },
                                titleVisibility: .visible, presenting: moving) { site in
                let index = sites.firstIndex { $0.id == site.id } ?? 0
                if index > 0 {
                    Button(L10n.text("Move to Top")) { move(site, to: 0) }
                    Button(L10n.text("Move Up")) { move(site, to: index - 1) }
                }
                if index < sites.count - 1 {
                    Button(L10n.text("Move Down")) { move(site, to: index + 2) }
                    Button(L10n.text("Move to Bottom")) { move(site, to: sites.count) }
                }
            }
        }
        .frame(width: 1100, height: 800)
        .onExitCommand { dismiss() }
        #else
        NavigationStack {
            List {
                Section {
                    ForEach(Array(sites.enumerated()), id: \.element.id) { index, site in
                        SourceOrderRow(site: site, rank: index + 1)
                            #if os(iOS)
                            .listRowBackground(Surface())
                            #endif
                            .accessibilityIdentifier("sources.order.row." + site.key)
                    }
                    .onMove { sites.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text(L10n.text("Drag sources to reorder them. Sources at the top are searched first, and their results are listed first."))
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background { Backdrop() }
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle(L10n.text("Arrange Sources"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Done")) { save(); dismiss() }.fontWeight(.semibold)
                        .accessibilityIdentifier("sources.order.done")
                }
                #if os(iOS)
                ToolbarItem(placement: .bottomBar) {
                    Button(L10n.text("Reset")) { withAnimation(.smooth) { sites = automatic } }.disabled(isAutomatic)
                }
                #else
                ToolbarItem(placement: .destructiveAction) {
                    Button(L10n.text("Reset")) { withAnimation(.smooth) { sites = automatic } }.disabled(isAutomatic)
                }
                #endif
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 600)
        #endif
        #endif
    }

    #if os(tvOS)
    private func move(_ site: Site, to offset: Int) {
        guard let index = sites.firstIndex(where: { $0.id == site.id }) else { return }
        withAnimation(.smooth) { sites.move(fromOffsets: [index], toOffset: offset) }
        save()
    }
    #endif
}

/// Opens `HiddenSourcesEditor`, under the search order on the sources page.
struct HideSourcesCard: View {
    let hidden: Int
    let open: () -> Void
    private var value: String { hidden > 0 ? L10n.text("%lld hidden", hidden) : "" }
    var body: some View {
        #if os(tvOS)
        Button(action: open) { TVSettingsRowLabel(title: L10n.text("Hide or Show Sources"), value: value, chevron: true) }
            .glassRow()
            .accessibilityIdentifier("sources.hidden.open")
        #else
        Button(action: open) {
            HStack(spacing: 14) {
                IconTile(symbol: "eye.slash", tint: Brand.teal, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Hide or Show Sources")).font(.headline).foregroundStyle(.primary)
                    Text(L10n.text("Choose many sources at once, or a whole subscription.")).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !value.isEmpty { Text(value).font(.subheadline).monospacedDigit().foregroundStyle(.secondary).lineLimit(1) }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(16)
            .contentPanel(cornerRadius: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sources.hidden.open")
        #endif
    }
}

/// Hiding or showing many sources at once: a ticked source is shown; Show All and Hide All take a whole group.
/// Sources stay in their own group here, hidden or not, and each change is saved at once.
struct HiddenSourcesEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// ⛔ 真删的源不算「隐藏」。它写了两条记录（`DeletedSources` + `HiddenSources`），
    /// 这里只查后者的话，它会以「已隐藏」身份在这个页面列出来 —— 而页面上就有
    /// 「Show All Sources」，一按就把它放回列表，删除等于没删。
    private func isHidden(_ site: Site) -> Bool {
        guard let origin = store.subscription?.origin else { return false }
        return store.hiddenSources.contains(site, origin: origin)
            && !store.deletedSources.contains(site, origin: origin)
    }
    /// ⛔ 批量显示 / 隐藏都必须跳过真删的源。
    ///
    /// 「Show All Sources」会 `hidden: false` 清掉隐藏标记；真删源的键还在
    /// `DeletedSources` 里，但列表过滤只认 `HiddenSources` —— 标记一清，源就回来了。
    /// 用户按「显示全部」不该把已删除的源请回来，那是数据错觉。
    private func setHidden(_ sites: [Site], _ hidden: Bool) {
        guard let config = store.subscription else { return }
        let origin = config.origin
        // 取消隐藏时剔除真删项；隐藏时无需剔除（给已删源再隐藏一次无害，且幂等）。
        let target = hidden ? sites : sites.filter { !store.deletedSources.contains($0, origin: origin) }
        guard !target.isEmpty else { return }
        store.hiddenSources.setHidden(target, origin: origin, hidden: hidden)
    }

    var body: some View {
        let groups = store.sourceGroups(includeHidden: true)
        let hiddenCount = groups.flatMap(\.sites).filter(isHidden).count
        #if os(tvOS)
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Ticked sources are shown. Hidden sources stay out of Watch Now and search."))
                        .font(.system(size: 24)).foregroundStyle(.secondary).padding(.bottom, 12)
                    if hiddenCount > 0 {
                        TVSettingsAction(title: L10n.text("Show All Sources")) { setHidden(groups.flatMap(\.sites), false) }
                            .padding(.bottom, 16)
                    }
                    ForEach(groups) { group in
                        let hidden = group.sites.filter(isHidden)
                        Text(L10n.text(group.title)).font(.system(size: 31, weight: .semibold)).lineLimit(1)
                            .padding(.top, 20).padding(.bottom, 6)
                            .accessibilityAddTraits(.isHeader)
                        HStack(spacing: 16) {
                            TVSettingsAction(title: L10n.text("Show All")) { setHidden(group.sites, false) }.disabled(hidden.isEmpty)
                            TVSettingsAction(title: L10n.text("Hide All")) { setHidden(group.sites, true) }.disabled(hidden.count == group.sites.count)
                        }
                        .focusSection()
                        ForEach(group.sites) { site in
                            let shown = !isHidden(site)
                            Button { setHidden([site], shown) } label: {
                                TVSettingsRowLabel(title: SourceLabel(site.name).parts[0], value: shown ? nil : L10n.text("Hidden")) {
                                    Image(systemName: shown ? "checkmark.circle.fill" : "circle").font(.system(size: 30))
                                }
                            }
                            .glassRow()
                            .accessibilityAddTraits(shown ? [.isSelected] : [])
                            .accessibilityIdentifier("sources.hidden.row." + site.key)
                        }
                    }
                }
                .glassRowInsets()
            }
            .screenTitle(L10n.text("Hide or Show Sources"))
            .screenBackdrop()
        }
        .frame(width: 1100, height: 800)
        .onExitCommand { dismiss() }
        #else
        NavigationStack {
            List {
                Section {
                    Text(L10n.text("Ticked sources are shown. Hidden sources stay out of Watch Now and search."))
                        .font(.subheadline).foregroundStyle(.secondary)
                        #if os(iOS)
                        .listRowBackground(Surface())
                        #endif
                }
                ForEach(groups) { group in
                    let hidden = group.sites.filter(isHidden)
                    Section {
                        ForEach(group.sites) { site in
                            let shown = !isHidden(site)
                            Button { setHidden([site], shown) } label: { HiddenSourceRow(site: site, shown: shown) }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(shown ? [.isSelected] : [])
                                .accessibilityIdentifier("sources.hidden.row." + site.key)
                                #if os(iOS)
                                .listRowBackground(Surface())
                                #endif
                        }
                    } header: {
                        HStack(spacing: 12) {
                            Text(L10n.text(group.title)).lineLimit(1)
                            Spacer(minLength: 8)
                            Button(L10n.text("Show All")) { setHidden(group.sites, false) }.disabled(hidden.isEmpty)
                            Button(L10n.text("Hide All")) { setHidden(group.sites, true) }.disabled(hidden.count == group.sites.count)
                        }
                        .buttonStyle(.borderless)
                        .textCase(nil)
                    }
                }
            }
            #if os(iOS)
            .scrollContentBackground(.hidden)
            .background { Backdrop() }
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle(L10n.text("Hide or Show Sources"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Done")) { dismiss() }.fontWeight(.semibold)
                        .accessibilityIdentifier("sources.hidden.done")
                }
                #if os(iOS)
                ToolbarItem(placement: .bottomBar) {
                    Button(L10n.text("Show All Sources")) { setHidden(groups.flatMap(\.sites), false) }.disabled(hiddenCount == 0)
                }
                #else
                ToolbarItem(placement: .destructiveAction) {
                    Button(L10n.text("Show All Sources")) { setHidden(groups.flatMap(\.sites), false) }.disabled(hiddenCount == 0)
                }
                #endif
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 600)
        #endif
        #endif
    }
}

#if !os(tvOS)
/// One source in `HiddenSourcesEditor`: a tick while it is shown, its icon and name.
private struct HiddenSourceRow: View {
    let site: Site
    let shown: Bool
    var body: some View {
        let label = SourceLabel(site.name)
        HStack(spacing: 12) {
            Image(systemName: shown ? "checkmark.circle.fill" : "circle").font(.title3)
                .foregroundStyle(shown ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.secondary))
            SourceIcon(site: site, label: label, size: 32).opacity(shown ? 1 : 0.45)
            Text(label.parts[0]).font(.body.weight(.medium)).lineLimit(1)
                .foregroundStyle(shown ? Color.primary : Color.secondary)
            SourceRouteBadge(site: site)
            Spacer(minLength: 8)
            if !shown { Text(L10n.text("Hidden")).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
#endif

/// Which group search asks first.
///
/// Why groups and not sources
/// --------------------------
/// The source order (`SourceOrderEditor`) answers "of these two sources, which first" — a fine
/// instrument that requires dragging 300 rows, which nobody does. A group is the unit the reader
/// already thinks in ("this feed is good, that one is junk"), it is what they already arranged the
/// page into, and there are six of them. Ranking six things is a decision someone actually makes;
/// ranking 300 is a chore disguised as a feature.
///
/// What it changes
/// ---------------
/// Search asks the ranked groups' sources before the rest, and lists their matches first. Sources
/// inside a group keep their own order, so this never discards hand-arranged rows — it only decides
/// which bucket is asked first. Nothing is hidden: an unranked group follows every ranked one rather
/// than being dropped, because "not ranked yet" is not "please ignore this feed".
///
/// The page's own order is untouched. A reader who wants a feed searched first has not thereby asked
/// for its section to jump to the top of the Sources page.
struct SourceGroupOrderEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Every group, empty ones included.
    ///
    /// An empty group is still a group the viewer made, and it still holds a place in the ranking —
    /// the Sources page lists it (a group with nothing in it needs somewhere to be dropped onto).
    /// Filtering empty ones out here would have the first arrow press write a ranking that silently
    /// drops them, which is the opposite of what `pruneGroupOrder` keeps on purpose.
    private var groups: [SourceGroup] {
        store.sourceGroups(includeHidden: false)
    }

    /// The ranked list first, in its saved order, then everything not ranked yet in page order.
    private var ordered: [SourceGroup] {
        let all = groups
        let ranked = store.sourceOrder.savedGroupOrder
        let rank = Dictionary(ranked.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return all.enumerated().sorted {
            let lhs = rank[$0.element.id] ?? Int.max
            let rhs = rank[$1.element.id] ?? Int.max
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
    }

    private var isBlank: Bool { store.sourceOrder.savedGroupOrder.isEmpty }

    private func move(_ group: SourceGroup, by offset: Int) {
        withAnimation(.smooth) {
            store.sourceOrder.moveGroup(group.id, by: offset, among: ordered.map(\.id))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { index, group in
                        row(group, rank: index + 1)
                    }
                } header: {
                    Text(L10n.text("Group Priority"))
                } footer: {
                    Text(L10n.text("Groups at the top are searched first, and their results are listed first. Sources inside a group keep their own order. A group left here unranked is still searched — it just comes after the ones you ranked."))
                }
                Section {
                    Button(role: .destructive) {
                        withAnimation(.smooth) { store.sourceOrder.saveGroupOrder([]) }
                    } label: {
                        Text(L10n.text("Clear the Ranking"))
                    }
                    .disabled(isBlank)
                } footer: {
                    Text(L10n.text("Clearing it returns search to the automatic order, which prefers quick, reliable sources. Nothing is ungrouped and no source order is lost."))
                }
            }
            #if os(iOS)
            .scrollContentBackground(.hidden)
            .background { Backdrop() }
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, .constant(.active))
            #endif
            .navigationTitle(L10n.text("Group Priority"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Done")) { dismiss() }.fontWeight(.semibold)
                        .accessibilityIdentifier("sources.groupOrder.done")
                }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 600)
        #endif
    }

    @ViewBuilder
    private func row(_ group: SourceGroup, rank: Int) -> some View {
        // Judged by whether this id is in the saved list, not by comparing positions: the saved list
        // can hold an id this page cannot draw (a hidden-only subscription), and a position compare
        // would then colour every row below it as unranked.
        let ranked = store.sourceOrder.savedGroupOrder.contains(group.id)
        HStack(spacing: 12) {
            Text(rank, format: .number)
                .font(.caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(ranked ? Color.primary : Color.secondary)
                .frame(minWidth: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(group.title)).font(.body.weight(.medium)).lineLimit(1)
                Text(L10n.text("%lld sources", group.sites.count))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            // 上下一步的按钮而不是只有拖动：Mac 没有编辑模式、tvOS 没有手势，
            // 而在一个六行的列表里按两下比拖动更快也更准。
            HStack(spacing: 2) {
                Button { move(group, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .disabled(rank == 1)
                    .accessibilityLabel(L10n.text("Move %@ up", group.title))
                Button { move(group, by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .disabled(rank == ordered.count)
                    .accessibilityLabel(L10n.text("Move %@ down", group.title))
            }
        }
        .accessibilityIdentifier("sources.groupOrder.row." + group.id)
    }
}
