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
                Divider()
                // 「移到未分组」：移出所有分组与订阅，但仍留在源列表里。
                // 与「放回原订阅」是两条不同的去路，不能合并成一条。
                if !store.isUngrouped(site) {
                    Button { store.moveSourceToUngrouped(site) } label: {
                        Label(L10n.text("Move to Ungrouped"), systemImage: "tray")
                    }
                }
                if moved != nil {
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
    /// The group-priority list, opened from the search-order card.
    @State private var rankingGroups = false
    /// The sweep-and-file sheet, opened from the toolbar.
    @State private var showingSpeedLab = false
    /// Which sources are ticked. Empty = not selecting; the page is browsing, not choosing.
    @State private var selection: Set<String> = []
    /// Whether the page is in its choosing state. A separate flag from `selection` because "I ticked
    /// one card and then unticked it" must not drop the reader back into browsing mid-task.
    @State private var selecting = false
    /// The last batch result, said where the buttons are rather than in a sheet.
    @State private var batchNote: String?
    /// 已经点过「展开其余」的分组。组里 168 个源不该一次全画出来 —— 先给一屏，
    /// 想全看的人自己点开；搜索与选择模式下不看这个（那两种时刻要的是「全都在」）。
    /// 展开过哪几格会落盘（`SourceShelfState.expandedShelves`），关掉 App 再回来还是摊开的。
    @State private var expandedGroups: Set<String> = SourceShelfState().expandedShelves
    /// 每组先画多少张卡。手机上两列，12 张 = 六行，刚好一屏多一点。
    private var previewLimit: Int { 12 }
    /// 组内二级书架里，哪几个被折起来了（键是 `组id|书架`）。落盘：离开再回来还是折着。
    @State private var collapsedShelves: Set<String> = SourceShelfState().collapsedShelves
    /// 书架按什么分：连通 / 内容 / 有实测就按连通。跨分组生效，记住选择。
    @State private var shelfMode: SourceShelfMode = SourceShelfState().mode
    /// 只看能播。开关落盘 —— 读者按了一次是想「以后都这么看」，不是只这一眼。
    @State private var onlyPlayable: Bool = SourceShelfState().onlyPlayable
    /// 组内按连通排序（能播 → 偏慢 → 未测 → 不通）。默认开，同一档内保留原有顺序。
    @State private var sortByConnection: Bool = SourceShelfState().sortByConnection
    /// 读数落盘时 `SourceProbeStore` 自己会通知（它是 `@Observable`），这一页靠 body 里那次
    /// `probeTick` 的读取登记依赖 —— 不再需要本地计数。
    /// （旧写法是 `@State probeRevision` + `.onChange(of: revision)`，而那时 store 不是可观察对象：
    /// 只有扫描进度恰好同时在变时才会顺带看到新值，选集页单独测出来的读数永远不刷新。）
    private var probeTick: Int { SourceProbeStore.shared.revision }
    /// 正在改名的分组（幂等：非 nil 就弹那个改名框）。
    @State private var renamingGroup: SourceGroup?
    /// 正在改名的订阅地址。
    @State private var renamingSubscription: String?
    /// 待删除的分组（先弹确认，不直接删）。
    @State private var deletingGroup: SourceGroup?
    /// 待删除的子源。带上 origin —— 同一个 site.key 在不同订阅下是两条。
    @State private var deletingSite: (site: Site, origin: URL)?
    /// 待改名的子源。
    @State private var renamingSite: (site: Site, origin: URL)?

    /// 只有用户自建的分组能删。系统组（固定 / 内置 / 来自订阅 / 其他）没有「删除」这件事 ——
    /// 删订阅请去订阅管理，删内置源没有意义。
    func deletableGroup(_ group: SourceGroup) -> Bool {
        if case .custom = group.kind { return true }
        return false
    }
    /// The fold as it was before choosing began; put back when choosing ends.
    @State private var foldBeforeSelecting: Set<String>?
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
                // 读一次测速库的 revision：它是 `@Observable`，这一读把「读数落盘 → 重画」
                // 变成结构性的保证（分组头的徽标、书架、只看能播都读那张表）。
                let _ = probeTick
                let all = store.sourceGroups(includeHidden: false)
                let hiddenCount = all.first { $0.kind == .hidden }?.sites.count ?? 0
                let searched = all.filtered(by: query).limited(to: pick == nil ? nil : Set(pickable.map(\.key)))
                let groups = playedOnly(searched)
                let sites = store.orderedSites(config)
                ScrollViewReader { proxy in
                ScrollView {
                    // `pinnedViews: [.sectionHeaders]` —— 分组头吸顶。
                    //
                    // 这一页有几十个分组、几百张卡片：滚到第三屏之后，顶上那个「全部折叠」按钮
                    // 早就滚没了，想折一个分组得先滚回去找它。分组头吸顶之后，**滚到哪儿都能**
                    // 直接点当前那一组的头折起来 —— 「滑动到任何一个页面都可以折叠」就是这个意思。
                    LazyVStack(alignment: .leading, spacing: Layout.cardSpacing,
                               pinnedViews: [.sectionHeaders]) {
                        // 选择模式下顶部就是操作条：先看清楚选了几个，再决定做什么。
                        // 放在列表最上面而不是浮在底部，是为了和「选中的卡片」同处一屏——
                        // 底部浮条会遮住正在勾的那一行。
                        if selecting {
                            selectionBar(groups: groups, all: sites)
                        } else if pick == nil, !groups.isEmpty || onlyPlayable {
                            // 为什么要带 `|| onlyPlayable`：控制栏里装着「全部 / 只看能播」
                            // 两颗胶囊。某个时刻一个能播的源都没有（刚测完、换了个网络、
                            // 或者读数过期）时 `groups` 是空的 —— 只按 `!groups.isEmpty` 判断，
                            // 整条控制栏连同唯一的开关一起消失，页面上只剩空列表，
                            // 想关掉筛选只能进工具栏菜单。清空时最需要那个开关。
                            // Both numbers come from the same list: the groups drawn, and the sources
                            // inside them. Reading the source count off `orderedSites` counted a
                            // different set whenever hidden sources existed.
                            listControls(groups: groups.filter { $0.kind != .hidden },
                                         sources: groups.filter { $0.kind != .hidden }.flatMap(\.sites).count,
                                         counts: SourceConnectivity.counts(
                                            searched.filter { $0.kind != .hidden }.flatMap(\.sites),
                                            reading: latestReading))
                        }
                        if pick == nil, query.isEmpty && sites.count > 1, !selecting {
                            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                                // The sweep card is first among the tools because it is what the other
                                // two act on: measure, then file the answered ones and sort the rest.
                                //
                                // ⛔ 只在非 tvOS 上出现。它打开的是一个 `.sheet`，而那个 `.sheet` 写在
                                // `#if !os(tvOS)` 里（tvOS 上 sheet 盖在被 push 的页面上不会收拢，#272）。
                                // 守卫加在消费端却没加在触发端，结果是 tvOS 上有一张**点了没反应的卡** ——
                                // 比没有这张卡更糟。
                                #if !os(tvOS)
                                SpeedAndGroupingCard { showingSpeedLab = true }
                                #endif
                                SourceOrderCard(sites: sites, arrange: { arranging = true },
                                                arrangeGroups: { rankingGroups = true })
                                HideSourcesCard(hidden: hiddenCount) { choosingHidden = true }
                            }.tvFocusSection()
                        }
                        ForEach(groups) { group in
                            // 用 `Section` 而不是「头 + 网格」两行：只有 Section 的 header 会被
                            // `pinnedViews` 认成吸顶头。内容折起来时留一个空的 Section ——
                            // 头仍然在，仍然可以点开。
                            Section {
                                if !collapsed.contains(group.id) {
                                    groupBody(group, config: config, sites: sites)
                                }
                            } header: {
                                groupHeader(group)
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
                // `safeAreaInset` 而不是 `overlay`：胶囊出现时把列表内容顶上去一格，
                // 挡住最后一行卡片会让读者以为那一行点不到。
                .safeAreaInset(edge: .bottom, spacing: 0) { probeBar }
                .animation(.snappy(duration: 0.28), value: store.probeRun)
                // Picking opens on the current choice rather than the top of a long page.
                .defaultFocus($focusedSite, picked)
                .onAppear { if pick != nil, let picked { proxy.scrollTo(picked, anchor: .center) } }
                }
                .sheet(isPresented: $arranging) { SourceOrderEditor(sites: sites, automatic: store.automaticSites(config)) }
                .sheet(isPresented: $choosingHidden) { HiddenSourcesEditor() }
                .sheet(isPresented: $rankingGroups) { SourceGroupOrderEditor() }
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
            // The sweep belongs here rather than on a settings page: the decision it feeds — which
            // group a source is in, whether it goes direct or through the relay — is made on this
            // page, and a measurement you have to leave the page to take is a measurement nobody takes.
            // Two items in one group rather than two groups: on a phone the navigation bar keeps
            // both, and a second `.primaryAction` was silently dropped — which is how a feature ships
            // invisible.
            if pick == nil, store.subscription != nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        // 「全部折叠」在列表顶上，滚动之后就够不着了；分组头吸顶解决了「折哪一组」，
                        // 这一项解决「一次折全部」—— 滚到第几屏都能按到。
                        Button {
                            setAllCollapsed(!allFolded)
                        } label: {
                            Label(L10n.text(allFolded ? "Expand All" : "Collapse All"),
                                  systemImage: allFolded ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                        }
                        .disabled(!query.isEmpty)
                        .accessibilityIdentifier("sources.foldAllMenu")
                        Divider()
                        // 只看能播 / 按连通排序：与列表顶上那两颗胶囊是同一个状态，
                        // 这里再给一份是因为胶囊只在「有读数」时出现，而这两项在测速页回来、
                        // 或者列表滚下去之后也得能按到。
                        Toggle(isOn: $onlyPlayable) {
                            Label(L10n.text("Only Playable"), systemImage: "checkmark.circle")
                        }
                        .accessibilityIdentifier("sources.menu.onlyPlayable")
                        Toggle(isOn: $sortByConnection) {
                            Label(L10n.text("Sort by Connection"), systemImage: "arrow.up.arrow.down")
                        }
                        .accessibilityIdentifier("sources.menu.sortByConnection")
                        Divider()
                        // 书架按什么分。放在这里而不是顶上一排胶囊：它是「这一页怎么读」的设置，
                        // 不是每次都要按的动作；而它一改，整页所有分组一起换依据，得有个说法。
                        Menu {
                            ForEach(SourceShelfMode.allCases) { mode in
                                Button {
                                    withAnimation(.snappy(duration: 0.28)) { shelfMode = mode }
                                } label: {
                                    if shelfMode == mode {
                                        Label(mode.title, systemImage: "checkmark")
                                    } else {
                                        Text(mode.title)
                                    }
                                }
                            }
                        } label: {
                            Label(L10n.text("Shelves"), systemImage: "rectangle.split.3x1")
                        }
                        .accessibilityIdentifier("sources.shelfMode")
                        Divider()
                        Button {
                            showingSpeedLab = true
                        } label: {
                            Label(L10n.text("Speed & Grouping"), systemImage: "speedometer")
                        }
                        .accessibilityIdentifier("sources.speedLab")
                    } label: {
                        Label(L10n.text("Tools"), systemImage: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("sources.tools")
                    // Edit, where people look first to remove a source that stopped working or to bring back one they hid
                    // (#669, #704). It opens the same list as the Hide or Show Sources card.
                    Button(L10n.text("Edit")) { choosingHidden = true }.accessibilityIdentifier("sources.edit")
                }
            }
        }
        .sheet(isPresented: $showingSpeedLab) {
            // 勾过的源直接带进测速页：勾完再点一次「测速」是最常见的下一步，
            // 让它变成同一次动作，而不是回到列表再选一遍。
            SourceSpeedLab(picked: selectionPickedSites())
        }
        #endif
        // 改名：分组与订阅各一个输入框。
        //
        // 挂在这里（body 的 Group 之后）而不是 `groupHeader` 内部：分组头是 `LazyVStack`
        // 里的行，滚出屏幕会被回收，挂在行上的 alert 会跟着消失 —— 与 `VideoDetailView`
        // 那份「抽屉不能挂在分支内部」是同一个教训（见那里的注释）。
        //
        // ⛔ 收进独立的 `ViewModifier`，不要直接写进 body 那条 `.alert(...)` 链。
        // 这条链已经很长，再加两个带闭包的 alert 会把类型检查推到超时
        // （实测报 `unable to type-check this expression in reasonable time`）。
        .modifier(RenameAlerts(renamingGroup: $renamingGroup,
                               renamingSubscription: $renamingSubscription,
                               renamingSite: $renamingSite,
                               deletingGroup: $deletingGroup,
                               deletingSite: $deletingSite))
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
        // 下面这些是读者的选择：改一次就落盘。重启之后还按他上次看到的样子打开 ——
        // 折叠、展开、只看能播、按连通排序，一个都不该「关一次 App 就忘」。
        .onChange(of: collapsedShelves) { _, new in SourceShelfState().save(collapsedShelves: new) }
        .onChange(of: expandedGroups) { _, new in SourceShelfState().save(expandedShelves: new) }
        .onChange(of: onlyPlayable) { _, new in SourceShelfState().save(onlyPlayable: new) }
        .onChange(of: sortByConnection) { _, new in SourceShelfState().save(sortByConnection: new) }
        // 书架依据也是读者的选择，走同一个出口。此前它只在菜单按钮的闭包里顺手存了一次 ——
        // 从别处（QA 启动参数、以后加的入口）改 `shelfMode` 就不会落盘。
        .onChange(of: shelfMode) { _, new in SourceShelfState().save(new) }
    }

    @ViewBuilder
    private func groupHeader(_ group: SourceGroup) -> some View {
        let open = !collapsed.contains(group.id)
        // 这一组现在能用几个。分组头是吸顶的，滚到组中间也看得到这个数 ——
        // 「还有没有必要往下翻」是读者在这一页最常问的问题。
        let counts = SourceConnectivity.counts(group.sites, reading: latestReading)
        // 选择模式下的分组头：左边照旧是折叠开关，右边多一个「整组勾上」。
        // 分组是用户已经整理过的批次，所以「这一组全要」比「一个个点」常用得多。
        let header = HStack(spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.3)) {
                    if open { collapsed.insert(group.id) } else { collapsed.remove(group.id) }
                    // A picking visit folds for its own convenience and leaves the Sources page's saved
                    // fold alone: borrowing a page to choose from must not rearrange it.
                    // [mi3s] 二开：借用选择页时不动 Sources 页自己的折叠记忆
                    //
                    // ⛔ 也不能在**搜索中**落盘。搜索一开始 `collapsed` 就被清空、结束时才从
                    // `foldBeforeSearch` 恢复 —— 那是内存里的临时视图。搜索中折一个组，
                    // 磁盘上就只剩「折了这一个」，下次启动按磁盘打开，整页折叠状态全错。
                    if pick == nil, query.isEmpty { foldState.save(collapsed) }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(L10n.text(group.title)).font(.headline).lineLimit(1)
                    Text("\(group.sites.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    // 测过之后才有这个徽标：没读数时它只会是个「0」，比不显示更容易被误读成「全死了」。
                    if counts.measured > 0 {
                        let usable = counts.usable > 0
                        HStack(spacing: 3) {
                            Image(systemName: usable ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text("\(usable ? counts.usable : counts.dead)")
                                .font(.caption2.weight(.semibold)).monospacedDigit()
                        }
                        .foregroundStyle(usable ? Brand.teal : Brand.rose)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((usable ? Brand.teal : Brand.rose).opacity(0.15), in: Capsule())
                        .accessibilityLabel(usable
                                            ? L10n.text("%lld playable of %lld", counts.usable, counts.total)
                                            : L10n.text("%lld unreachable of %lld", counts.dead, counts.total))
                    }
                    if selecting, let ticked = tickedCount(in: group), ticked > 0 {
                        Text(L10n.text("%lld picked", ticked))
                            .font(.caption.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(Brand.accent)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Brand.accent.opacity(0.16), in: Capsule())
                    }
                    // 正在测这一组：头的右边直接给出「测到第几个」，读者不必回测速页看。
                    // 对号用 id，不用标题 —— 两个订阅同名时（「影视 · 可播」很常见），
                    // 按标题会对到另一个组的头上。
                    if let run = store.probeRun, store.probeScopeID == group.id {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text("\(run.done)/\(run.total)")
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("sources.groupProbe." + group.id)
                    }
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
            if selecting {
                // 「整组」不是「全选反选」的替代品：组是用户自己整理出来的批次，
                // 所以要的是「这一组全要 / 都不要」，两个状态一个按钮来回切。
                let all = group.sites.allSatisfy { selection.contains($0.key) }
                Button {
                    toggleGroup(group)
                } label: {
                    Text(L10n.text(all ? "Clear This Group" : "Pick This Group"))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(all ? Brand.accent : Color.white.opacity(0.10), in: Capsule())
                        .foregroundStyle(all ? Brand.onAccent : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sources.groupPick." + group.id)
            }
        }
        // 吸顶头必须自带底色，否则卡片会从它下面透过去。
        // 左右两个 padding 一正一负：文字仍与内容对齐，底色却铺到屏幕两侧 ——
        // 否则吸顶时会在左右各留一条 gutter，卡片从缝里滑过去。
        .padding(.horizontal, Layout.gutter)
        .padding(.vertical, 6)
        .background(CanvasColor())
        .padding(.horizontal, -Layout.gutter)
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
                // 订阅头：测速这一组 + 改名 + 整订阅是否参与搜索（要求 7）。
                .contextMenu {
                    measureGroupButton(group)
                    Divider()
                    SubscriptionSearchMenu(address: address) { renamingSubscription = address }
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
                    // `groupID:`, not `to:`: the page holds a group's id, while a move stores its
                    // target (`group:<id>`). Handing the bare id to the address form filed the card
                    // under "Other Sources" and left the group it was dropped on empty.
                    store.reassignSourceByKey(drag.key, origin: drag.origin, groupID: group.id)
                    return true
                }
                .contextMenu {
                    measureGroupButton(group)
                    Divider()
                    Button { store.moveCustomGroup(id, by: -1) } label: {
                        Label(L10n.text("Move Group Up"), systemImage: "arrow.up")
                    }
                    .disabled(!store.canMoveCustomGroup(id, by: -1))
                    Button { store.moveCustomGroup(id, by: 1) } label: {
                        Label(L10n.text("Move Group Down"), systemImage: "arrow.down")
                    }
                    .disabled(!store.canMoveCustomGroup(id, by: 1))
                    // 改名与搜索开关都挂在分组头上（要求 7）：分组是用户自己整理的批次，
                    // 这两件事都是「对整组做点什么」，放这里比放进设置页更近。
                    GroupSearchParticipationButton(sourceGroup: group) { renamingGroup = group }
                    // 删除分组（要求 7）。组内源**不会**跟着消失 —— 它们的 move 指向
                    // `group:<id>`，组没了就指不到，`SourceGroups.make` 会把它们放回
                    // 各自的订阅源下。用户要的正是这个：整理可以撤，销毁不行。
                    Button(role: .destructive) {
                        deletingGroup = group
                    } label: {
                        Label(L10n.text("Delete Group"), systemImage: "trash")
                    }
                    .disabled(!deletableGroup(group))
                }
        } else if group.kind == .other, query.isEmpty {
            // Dropping into "Other Sources" is the way back: the source returns to its own subscription.
            header.dropDestination(for: SourceDrag.self) { (items: [SourceDrag], _: CGPoint) -> Bool in
                guard query.isEmpty, let drag = items.first else { return false }
                store.reassignSourceByKey(drag.key, origin: drag.origin, to: nil)
                return true
            }
            .contextMenu { measureGroupButton(group) }
        } else {
            // 固定 / 内置 / 来自订阅这些系统组没有别的菜单，但「测这一组」对哪一组都成立。
            header.contextMenu { measureGroupButton(group) }
        }
        #else
        // tvOS：拖拽不存在，所以上面那整段（分组头拖拽 + 订阅头/分组头菜单）被排除了。
        // 但「改名 / 删分组」不能因此没有入口 —— 本项目自己在 `:138` 记过教训：
        // 「守卫加在消费端却没加在触发端，结果是一张点了没反应的卡」。
        // 反过来同样糟：`RenameAlerts` 的弹窗三平台都在，触发端却只有 iOS 有。
        //
        // tvOS 支持 `.contextMenu`（`WatchNowTV.swift:80/459` 已在用），
        // 所以这里给它补一份只含「菜单类」动作的分支，拖拽/放置那部分仍然不进来。
        switch group.kind {
        case .custom:
            header.contextMenu {
                measureGroupButton(group)
                Divider()
                Button { store.moveCustomGroup(group.id, by: -1) } label: {
                    Label(L10n.text("Move Group Up"), systemImage: "arrow.up")
                }
                .disabled(!store.canMoveCustomGroup(group.id, by: -1))
                Button { store.moveCustomGroup(group.id, by: 1) } label: {
                    Label(L10n.text("Move Group Down"), systemImage: "arrow.down")
                }
                .disabled(!store.canMoveCustomGroup(group.id, by: 1))
                GroupSearchParticipationButton(sourceGroup: group) { renamingGroup = group }
                Button(role: .destructive) { deletingGroup = group } label: {
                    Label(L10n.text("Delete Group"), systemImage: "trash")
                }
            }
        case .subscription(let address):
            header.contextMenu {
                measureGroupButton(group)
                Divider()
                SubscriptionSearchMenu(address: address) { renamingSubscription = address }
            }
        default:
            header.contextMenu { measureGroupButton(group) }
        }
        #endif
    }

    /// 一个分组的内容：源少就直接铺，源多就先分一层书架。
    ///
    /// 书架有两种依据：**内容形态**（磁力 / 网盘 / 蓝光…）与**实测连通状态**（能播 / 慢 / 未测 / 不通）。
    /// 选哪一种由 `shelfMode` 决定，默认 `.auto` —— 一旦这个组里测出了能用的源，读者的问题就从
    /// 「这是什么站」变成「哪些还能用」，书架该跟着换；一个都测不出来时仍按内容分，因为按连通
    /// 分只会得到「未测 120 / 不通 20」两层，不如内容形态有用。
    ///
    /// 分层只发生在需要它的组：源少于阈值、或者只分得出一层时，`shelves` 返回空，这里就平铺。
    @ViewBuilder
    private func groupBody(_ group: SourceGroup, config: Subscription, sites: [Site]) -> some View {
        // 读数落盘就重画（`@Observable`）。分组内的书架与排序都读那张表，
        // body 顶上的那一次读取覆盖不到这里 —— 这一行是这里的依赖声明。
        let _ = probeTick
        let members = sortedForDisplay(group.sites)
        let counts = SourceConnectivity.counts(members, reading: latestReading)
        let shelves = shelves(for: members, counts: counts)
        if shelves.isEmpty {
            sourceGrid(group, members: members, config: config, all: sites, scope: group.id)
        } else {
            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                ForEach(shelves) { entry in
                    let scope = group.id + "|" + entry.id
                    shelfHeader(scope: scope, entry: entry)
                    if !collapsedShelves.contains(scope) {
                        sourceGrid(group, members: entry.sites, config: config, all: sites, scope: scope)
                    }
                }
            }
        }
    }

    /// 「只看能播」打开时，把每一组里不是能播的源去掉；整组都不剩就整组不画。
    ///
    /// 过滤发生在分组层，而不是在网格里逐张跳过：分组头要跟着消失 ——
    /// 留一个「影视 · 失效 0」的空组头，读者会以为那一组加载失败了。
    private func playedOnly(_ groups: [SourceGroup]) -> [SourceGroup] {
        guard onlyPlayable else { return groups }
        return groups.compactMap { group in
            let playing = group.sites.filter { connectivityTier($0) == .playable }
            guard !playing.isEmpty else { return nil }
            return SourceGroup(kind: group.kind, title: group.title, sites: playing)
        }
    }

    /// 组内顺序：能播的排前面。同一档里不动 —— 那层顺序是 `SourceStrategy.arrange` 排的
    /// （同一站的不同接法挨着、运行时便宜的在前），重排会把它打散。
    private func sortedForDisplay(_ sites: [Site]) -> [Site] {
        guard sortByConnection else { return sites }
        return SourceConnectivity.sorted(sites, tier: connectivityTier)
    }

    /// 这一组该按哪种依据分层。
    ///
    /// `.auto` 的判据是「有没有测出能用的」：至少 3 个能播/偏慢，才值得把整组按连通重排 ——
    /// 只测出一个可播源就重排 168 张卡，是拿一个样本改整页的秩序。切到按连通分不出两层
    /// （比如全组都能播）时也回落到内容书架，免得只剩一条没有信息量的组头。
    private func shelves(for sites: [Site], counts: TierCounts) -> [SourceShelfGroup] {
        SourceShelf.shelves(for: sites, mode: shelfMode, counts: counts, tier: connectivityTier)
    }

    /// 这个源现在的读数（没测过就是 nil）。一页几百张卡，全靠这张 O(1) 的表。
    private func latestReading(_ site: Site) -> SourceProbeResult? {
        SourceProbeStore.shared.latest(sourceKey: site.sourceKey)
    }

    /// 档位：App 里刚测的读数优先，其次包内实测结论，都没有就是「未测」。
    private func connectivityTier(_ site: Site) -> SourceTier {
        SourceConnectivity.tier(of: site, reading: latestReading(site))
    }

    /// 二级书架的表头：小一号的标题 + 数量 + 折叠箭头。它比分组头轻，因为它只在分组里出现。
    /// 按连通分时标题前多一个档位图标（能播 ✓ / 偏慢 🐢 / 未测 ? / 不通 ✕），一眼看出这一层是什么。
    @ViewBuilder
    private func shelfHeader(scope: String, entry: SourceShelfGroup) -> some View {
        let open = !collapsedShelves.contains(scope)
        Button {
            withAnimation(.snappy(duration: 0.25)) {
                if open { collapsedShelves.insert(scope) } else { collapsedShelves.remove(scope) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                if let tier = entry.tier {
                    Image(systemName: tier.symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tierTint(tier))
                        .accessibilityHidden(true)
                }
                Text(entry.title).font(.subheadline.weight(.semibold))
                Text("\(entry.sites.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.leading, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sources.shelf." + scope)
    }

    /// 档位颜色：能播用青、偏慢用琥珀、不通用玫红、未测保持中性色。
    private func tierTint(_ tier: SourceTier) -> Color {
        switch tier {
        case .playable: return Brand.teal
        case .slow: return Brand.amber
        case .dead: return Brand.rose
        case .untested: return .secondary
        }
    }

    /// 一格书架（或不分层的整组）里的卡：先给 `previewLimit` 张，其余收在按钮后面。
    @ViewBuilder
    private func sourceGrid(_ group: SourceGroup, members: [Site], config: Subscription,
                            all sites: [Site], scope: String) -> some View {
        let preview = previewSites(members, scope: scope)
        LazyVGrid(columns: Layout.cardColumns, spacing: Layout.cardSpacing) {
            ForEach(preview.sites) { site in
                siteRow(site, group: group, config: config, sites: sites)
            }
        }
        // Unfolds from under its header; folding only fades, as the groups below slide up.
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -16)), removal: .opacity))
        if preview.hidden > 0 || expandedGroups.contains(scope) {
            moreSourcesButton(scope: scope, hidden: preview.hidden)
        }
    }

    /// 这一格现在该画哪些源。
    ///
    /// 一屏画不完的源只会在读者滚过去时被跳过 —— 先给 `previewLimit` 张，剩下的收在一颗按钮后面。
    /// 三种情况不预览：搜索中（要找的东西可能在后面）、选择中（整组勾选要靠满屏）、
    /// 已经点过展开。
    private func previewSites(_ members: [Site], scope: String) -> (sites: [Site], hidden: Int) {
        let showAll = !query.isEmpty || selecting || expandedGroups.contains(scope)
        guard !showAll, members.count > previewLimit else { return (members, 0) }
        return (Array(members.prefix(previewLimit)), members.count - previewLimit)
    }

    /// 「展开其余 156 个」/「收起」。
    ///
    /// 展开/收起也落盘（`SourceShelfState.expandedShelves`）：读者把一组 168 个源摊开、
    /// 翻到底，离开再回来又收成一屏，会以为那个「展开」没生效过。
    /// （这里曾经写着「不写盘」，而页面装配处一直在存 —— 注释与代码对不上，
    /// 后来的人照注释改就会把持久化删掉。以代码为准。）
    @ViewBuilder
    private func moreSourcesButton(scope: String, hidden: Int) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.28)) {
                if hidden > 0 { expandedGroups.insert(scope) } else { expandedGroups.remove(scope) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: hidden > 0 ? "chevron.down" : "chevron.up")
                    .font(.caption2.weight(.bold))
                Text(hidden > 0
                     ? L10n.text("Show the rest (%lld)", hidden)
                     : L10n.text("Fold the extra back"))
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityIdentifier("sources.more." + scope)
    }

    /// 长按分组头 → 「测速这一组」。
    ///
    /// 为什么是长按：测速是这一页上唯一会花几分钟、还会花掉流量的事，它不该占一个常驻按钮；
    /// 而它要作用的范围（这一组）正好就是手指按着的那个头 —— 用长按省掉「进测速页 → 选范围」
    /// 这两步。跑起来之后同一个位置变成「停止」，读者不用回测速页找那个按钮。
    @ViewBuilder
    private func measureGroupButton(_ group: SourceGroup) -> some View {
        // 与分组头上的进度徽标同一个判据：id，不是标题。
        let running = store.probeRun != nil && store.probeScopeID == group.id
        if running {
            Button(role: .destructive) {
                store.cancelProbingAllSources()
            } label: {
                Label(L10n.text("Stop Measuring"), systemImage: "stop.circle")
            }
        } else {
            Button {
                store.measure(group: group)
            } label: {
                Label(L10n.text("Measure This Group"), systemImage: "speedometer")
            }
            .disabled(group.sites.isEmpty)
        }
    }

    /// 测速中一直挂在底部的进度条。
    ///
    /// 「后台执行」如果只体现在代码里（`Store` 里的 Task 不随页面销毁），读者看到的是
    /// 「点了没反应」：他离开这一页、回来，不知道那轮测速还在不在跑。这条小胶囊把
    /// 在测的是哪一批、走到第几个、以及怎么停，全都摆在眼皮底下。
    @ViewBuilder
    private var probeBar: some View {
        if let run = store.probeRun, pick == nil, !selecting {
            HStack(spacing: 10) {
                ProgressView(value: Double(run.done), total: Double(max(run.total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 54)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.probeScopeLabel ?? L10n.text("Measure Every Source"))
                        .font(.caption.weight(.semibold)).lineLimit(1)
                    // 跳过的要说出来：测了 12 个而这一组有 46 个，不说清就是「按钮坏了」。
                    Text(L10n.text("%lld of %lld measured", run.done, run.total)
                         + skippedSuffix(store.probeSkipped))
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
                Button {
                    store.cancelProbingAllSources()
                } label: {
                    Image(systemName: "stop.circle.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Stop"))
                .accessibilityIdentifier("sources.probeStop")
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.10)))
            .shadow(radius: 12, y: 4)
            .padding(.bottom, 14)
            .accessibilityIdentifier("sources.probeBar")
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// 「· 跳过 34 个：刚刚测过。」，没有跳过时是空串。
    private func skippedSuffix(_ skipped: Int?) -> String {
        guard let skipped, skipped > 0 else { return "" }
        return " · " + L10n.text("%lld skipped: measured recently.", skipped)
    }

    /// Whether every listed group is folded — what decides whether the one press says
    /// "展开全部" or "全部折叠".
    private var allFolded: Bool {
        let ids = store.sourceGroups(includeHidden: false).map(\.id)
        return !ids.isEmpty && ids.allSatisfy { collapsed.contains($0) }
    }

    /// The list's own controls: how many groups and sources, one press to fold or unfold them all,
    /// and the way into choosing.
    ///
    /// These live above the list rather than in the toolbar. A phone's navigation bar already had a
    /// menu silently dropped for being a second `.primaryAction`; more to the point, "fold everything"
    /// is a property of the list below it, and a control sitting directly over its own list needs no
    /// explaining. It is also the only place the count of groups is ever stated, which is what makes
    /// folding them all a thought someone can have.
    private func listControls(groups: [SourceGroup], sources: Int, counts: TierCounts) -> some View {
        let all = allFolded
        let groupCount = groups.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("%lld groups", groupCount)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    // 测过之后第二行换成「多少能播」：这是读者来这一页最想知道的一个数，
                    // 而它比「多少源」更能说明这一页现在有没有用。
                    Text(counts.measured > 0
                         ? L10n.text("%lld sources · %lld playable", sources, counts.usable)
                         : L10n.text("%lld sources", sources))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                // 「一键」是这里的重点：分组一多，逐个点头标是唯一比测速更烦的事。
                Button {
                    setAllCollapsed(!all)
                } label: {
                    Label(L10n.text(all ? "Expand All" : "Collapse All"),
                          systemImage: all ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Color.white.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
                // While a search narrows the list, "fold everything" would act on groups the reader
                // cannot see — the old control refused for exactly this reason.
                .disabled(!query.isEmpty)
                .help(all ? L10n.text("Expand All") : L10n.text("Collapse All"))
                .accessibilityIdentifier("sources.foldAll")
                // 选择模式的入口放在同一行：这两件事都是「对整个列表做点什么」，
                // 分开放会让人以为它们属于不同页面。
                if pick == nil {
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { beginSelecting() }
                    } label: {
                        Label(L10n.text("Select"), systemImage: "checkmark.circle")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(Brand.accent.opacity(0.18), in: Capsule())
                            .foregroundStyle(Brand.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(sources == 0)
                    .accessibilityIdentifier("sources.selectMode")
                }
            }
            // 「只看能播」只在有读数时出现 —— 没测过的时候它只会把整页清空，
            // 那不是筛选，是让人以为源都挂了。
            //
            // ⛔ 但它自己开着的时候必须可见（`|| onlyPlayable`）：读数是会过期的，
            // 今天测好的 46 个源一周后全部翻成「未测」，于是 `measured == 0` ——
            // 胶囊按旧条件消失，而筛选仍然开着，页面就永久卡在空白上。
            if counts.measured > 0 || onlyPlayable, pick == nil {
                filterChips(counts)
            }
            // 筛到空的时候说一句为什么。没有这句，页面上只剩工具卡与空白，
            // 与「源全丢了」「加载失败」长得一模一样。
            if groupCount == 0 {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.caption)
                    Text(L10n.text("Nothing here is playable right now."))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("sources.emptyState")
            }
        }
        .padding(.horizontal, 4)
    }

    /// 全部 / 只看能播 两颗胶囊。
    ///
    /// 用胶囊而不是开关：开关只有「开/关」，读者看不出关掉之后会多出多少张卡；
    /// 两颗并排时，「全部 505」与「只看能播 51」把代价与收益同时摆在眼前。
    @ViewBuilder
    private func filterChips(_ counts: TierCounts) -> some View {
        HStack(spacing: 8) {
            filterChip(title: L10n.text("All"), count: counts.total, active: !onlyPlayable) {
                withAnimation(.snappy(duration: 0.25)) { onlyPlayable = false }
            }
            .accessibilityIdentifier("sources.filter.all")
            filterChip(title: L10n.text("Only Playable"), count: counts.playable,
                       active: onlyPlayable, tint: Brand.teal) {
                withAnimation(.snappy(duration: 0.25)) { onlyPlayable = true }
            }
            .accessibilityIdentifier("sources.filter.playable")
            Spacer(minLength: 0)
        }
    }

    private func filterChip(title: String, count: Int, active: Bool,
                            tint: Color = Brand.accent,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.caption.weight(.semibold))
                Text("\(count)").font(.caption2).monospacedDigit().opacity(0.7)
            }
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 11).padding(.vertical, 6)
            .foregroundStyle(active ? tint : Color.secondary)
            .background(active ? tint.opacity(0.16) : Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(active ? tint.opacity(0.45) : .clear))
        }
        .buttonStyle(.plain)
    }

    /// The bar that replaces the list controls while choosing: what is ticked, and everything that
    /// can be done to it.
    ///
    /// The batch actions are here, in one row, on purpose. Grouping, hiding, pinning and routing are
    /// all "do this to the ones I ticked", and scattering them across a menu makes the reader
    /// remember which menu holds which — the exact cost this page exists to remove.
    private func selectionBar(groups: [SourceGroup], all sites: [Site]) -> some View {
        // The batch acts on everything ticked, not only what the search box currently shows. A tick
        // that survives a search but not the action would be the worst kind of inconsistency: the
        // reader sees "3 selected", searches, sees "0 selected", and the three are still ticked.
        let picked = pickedSites(all: sites)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(L10n.text("%lld selected", picked.count))
                    .font(.headline).monospacedDigit()
                    .accessibilityIdentifier("sources.selectionCount")
                Spacer(minLength: 8)
                // Select-all is scoped to what is on screen, and says so when a search is narrowing it.
                Button(L10n.text(query.isEmpty ? "Select All" : "Select All Shown")) { selectAll(groups: groups) }
                    .font(.caption.weight(.semibold))
                    .disabled(visibleSites(groups: groups).allSatisfy { selection.contains($0.key) })
                Button(L10n.text("Deselect All")) { selection.removeAll() }
                    .font(.caption.weight(.semibold))
                    .disabled(selection.isEmpty)
                Button(L10n.text("Done")) {
                    withAnimation(.snappy(duration: 0.25)) { endSelecting() }
                }
                .font(.caption.weight(.semibold))
                .accessibilityIdentifier("sources.selectDone")
            }
            .buttonStyle(.plain)

            if picked.isEmpty {
                Text(L10n.text("Tick the sources you want, then choose what to do with them. A group's own button picks everything in it."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // 首屏只放四个最常用的：分组、隐藏、置顶、测速。
                // 路由与「放回原订阅」放进第二个菜单，因为它们要么更少用，要么有副作用要读文字。
                ViewThatFits(in: .horizontal) {
                    batchButtons(picked: picked, compact: false)
                    batchButtons(picked: picked, compact: true)
                }
            }
            if let batchNote {
                Text(batchNote).font(.caption).foregroundStyle(Brand.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sources.batchNote")
            }
        }
        .padding(14)
        .contentPanel(cornerRadius: 20)
        .accessibilityIdentifier("sources.selectionBar")
    }

    @ViewBuilder
    private func batchButtons(picked: [Site], compact: Bool) -> some View {
        HStack(spacing: 8) {
            Menu {
                Section {
                    Button {
                        fileSelection(picked, into: nil, label: L10n.text("their own subscriptions"))
                    } label: {
                        Label(L10n.text("Back to Their Own Subscription"), systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!picked.contains { store.reassignedAddress($0) != nil })
                }
                Section {
                    ForEach(store.sourceGroupBook.groups) { group in
                        Button(L10n.text("Move to %@", group.name)) { fileSelection(picked, into: group.id, label: group.name) }
                    }
                }
                Section {
                    ForEach(store.environmentSubscriptions.filter(\.enabled)) { entry in
                        Button(L10n.text("Move to %@", entry.title)) { fileSelection(picked, into: entry.address, label: entry.title) }
                    }
                }
                Section {
                    Button {
                        let created = store.createSourceGroup(named: nextGroupName())
                        if let created { fileSelection(picked, into: created.id, label: created.name) }
                    } label: {
                        Label(L10n.text("New Group…"), systemImage: "plus.rectangle.on.folder")
                    }
                }
            } label: {
                Label(L10n.text("Group"), systemImage: "folder")
                    .font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("sources.batch.group")

            Button {
                let hidden = picked.filter { site in
                    store.subscription.map { store.hiddenSources.contains(site, origin: $0.origin) } ?? false
                }
                // 全都已隐藏 ⇒ 这一按是「显示」，否则是「隐藏」。一个按钮两个方向，
                // 因为它描述的是这批源的状态，不是两个互不相干的功能。
                let show = hidden.count == picked.count
                // ⛔ 必须用 `setHidden` 的**返回值**报数，不能用 `picked.count`。
                //
                // `Store.setHidden(_:for:)` 是 `@discardableResult`，且它的整段注释
                // 都在说明「返回值描述实际改到了几条」，就是为了避免这个谎：
                //   · 取消隐藏时它会先剔掉已真删的源（否则「显示全部」会让删掉的源复活）；
                //   · 集合没实际变化时它返回 0（`hiddenSources.revision` 没动）。
                // 而这里原来把返回值丢掉了、改用 `picked.count` 上报 ——
                // 于是「勾了 12 个、其中 5 个已删」时，界面说「已显示 12 个源」，
                // 实际只有 7 个被改；这就是它注释里写的「同一个谎」。
                let changed = store.setHidden(!show, for: picked)
                if changed == 0 {
                    note(L10n.text("Nothing changed."))
                } else {
                    note(show ? L10n.text("Shown %lld sources.", changed) : L10n.text("Hidden %lld sources.", changed))
                }
            } label: {
                Label(L10n.text("Hide"), systemImage: "eye.slash")
                    .font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("sources.batch.hide")

            Button {
                // 同「隐藏」那颗：`setPinned` 也返回实际改动条数（`pinnedSources.revision`
                // 没动时返回 0），必须用它报数而不是 `picked.count`。
                let changed = store.setPinned(true, for: picked)
                note(changed == 0 ? L10n.text("Nothing changed.")
                                  : L10n.text("Pinned %lld sources.", changed))
            } label: {
                Label(L10n.text("Pin"), systemImage: "pin")
                    .font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("sources.batch.pin")

            Button {
                store.startProbing(picked, skippingFresh: store.probeMaxAge)
                note(L10n.text("Measuring %lld sources…", picked.count))
            } label: {
                // 不能用 "Measure" 这个键：它在 zh/ja 里是**名词**「测速范围」，是从测速页的
                // 作用域选择器借来的。放在这里会让批量按钮写「测速范围」，读起来不是一个动作。
                Label(L10n.text("Measure Now"), systemImage: "speedometer")
                    .font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
            }
            .buttonStyle(.borderless)
            .disabled(store.probeRun != nil)
            .accessibilityIdentifier("sources.batch.measure")

            Menu {
                Button {
                    let result = store.fileByReachability(picked,
                                                          into: L10n.text("Reachable"),
                                                          silentGroup: L10n.text("Unreachable"),
                                                          alsoMatching: L10n.everyRendering(of: "Reachable"),
                                                          silentAliases: L10n.everyRendering(of: "Unreachable"))
                    note(result.unknown > 0
                         ? L10n.text("Filed %lld answered and %lld silent; %lld have no reading yet.", result.answered, result.silent, result.unknown)
                         : L10n.text("Filed %lld answered and %lld silent.", result.answered, result.silent))
                } label: {
                    Label(L10n.text("File by Result (reachable / unreachable)"), systemImage: "square.grid.2x2")
                }
                Button {
                    let result = store.routeByReachability(picked)
                    note(L10n.text("%lld to Direct, %lld to Proxy, %lld left unmeasured.", result.direct, result.relay, result.unknown))
                } label: {
                    Label(L10n.text("Answered to Direct, Silent to Proxy"), systemImage: "arrow.triangle.branch")
                }
                Button {
                    let changed = store.setPinned(false, for: picked)
                    note(changed == 0 ? L10n.text("Nothing changed.")
                                      : L10n.text("Unpinned %lld sources.", changed))
                } label: {
                    Label(L10n.text("Unpin"), systemImage: "pin.slash")
                }
            } label: {
                Label(compact ? "" : L10n.text("More"), systemImage: "ellipsis.circle")
                    .font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("sources.batch.more")
        }
    }

    /// Every group open, or every group folded, at once.
    private func setAllCollapsed(_ all: Bool) {
        let ids = store.sourceGroups(includeHidden: false).map(\.id)
        withAnimation(.snappy(duration: 0.3)) { collapsed = all ? Set(ids) : [] }
        // Same rule as a single header: only the Sources page owns the saved fold, and a search's
        // temporary fold is not the viewer's saved one.
        // [mi3s] 二开：展开/折叠全部后也只由 Sources 页写折叠记忆
        if pick == nil, query.isEmpty { foldState.save(collapsed) }
    }

    // MARK: - 选择与批量

    /// The sources currently on screen — the ones a "select all" may tick, so a search narrows it too.
    private func visibleSites(groups: [SourceGroup]) -> [Site] {
        groups.flatMap(\.sites)
    }

    /// The ticked ones, in the order the page lists them. Order matters for the moves below:
    /// `SourceOrder` keeps first-seen order, so filing in the page's order leaves the group reading
    /// like the page it came from.
    ///
    /// Read from the whole library, not from the groups currently drawn: a search box narrows the
    /// list but does not un-tick anything, so the count and the batch have to cover the same set.
    private func pickedSites(all sites: [Site]) -> [Site] {
        guard !selection.isEmpty else { return [] }
        var seen = Set<String>()
        return sites.filter { selection.contains($0.key) && seen.insert($0.id).inserted }
    }

    /// How many of a group's cards are ticked, for the badge on its header. Nil when none, so the
    /// header does not grow a badge that says "0 picked".
    private func tickedCount(in group: SourceGroup) -> Int? {
        let n = group.sites.filter { selection.contains($0.key) }.count
        return n == 0 ? nil : n
    }

    private func beginSelecting() {
        selecting = true
        batchNote = nil
        // Opening every group for the duration of the choosing, and putting the fold back afterwards.
        // Unfolding permanently would be a side effect nobody asked for: the reader's fold is a
        // preference they set, and "I ticked some cards" is not a statement about it.
        foldBeforeSelecting = collapsed
        collapsed = []
    }

    private func endSelecting() {
        selecting = false
        selection.removeAll()
        batchNote = nil
        // Restore, not save: the fold the reader had is what they come back to.
        if let saved = foldBeforeSelecting { collapsed = saved }
        foldBeforeSelecting = nil
    }

    private func toggle(_ site: Site) {
        if selection.contains(site.key) { selection.remove(site.key) } else { selection.insert(site.key) }
        batchNote = nil
    }

    /// Picks a whole group, or clears it when every card in it is already picked.
    private func toggleGroup(_ group: SourceGroup) {
        let keys = group.sites.map(\.key)
        if keys.allSatisfy({ selection.contains($0) }) {
            selection.subtract(keys)
        } else {
            selection.formUnion(keys)
        }
        batchNote = nil
    }

    /// Adds everything on screen to the selection. A union, not an assignment: ticks made before a
    /// search must survive it, or "3 selected" would silently become "12" and the three would be gone.
    private func selectAll(groups: [SourceGroup]) {
        selection.formUnion(visibleSites(groups: groups).map(\.key))
        batchNote = nil
    }

    private func note(_ text: String) {
        batchNote = text
    }

    /// The ticked sources as a flat list, for the sheet this page opens. Read here rather than passed
    /// as a closure so the sheet gets a plain array: a sheet holding a live binding to the page's
    /// selection would change under the reader as they tick and untick behind it.
    private func selectionPickedSites() -> [Site] {
        guard !selection.isEmpty, let config = store.subscription else { return [] }
        return store.orderedSites(config).filter { selection.contains($0.key) }
    }

    /// The name for a group made by "New Group…": numbered so two presses in a row make two groups,
    /// and named after what it holds so the list stays readable later.
    private func nextGroupName() -> String {
        let taken = Set(store.sourceGroupBook.groups.map(\.name))
        var n = store.sourceGroupBook.groups.count + 1
        while taken.contains(L10n.text("Group %lld", n)) { n += 1 }
        return L10n.text("Group %lld", n)
    }

    /// Files the ticked sources under `target` (`nil` = back to their own subscription) and reports
    /// how many moved. The report stays on the bar: a batch that silently did nothing looks like a
    /// broken button, and a batch that moved 300 cards is a thing to be told about.
    private func fileSelection(_ sites: [Site], into target: String?, label: String) {
        guard !sites.isEmpty else { return }
        let moved = target == nil
            ? store.returnSourcesToTheirSubscription(sites)
            : store.fileSources(sites, intoGroupTarget: target)
        note(L10n.text("Moved %1$lld of %2$lld into %3$@.", moved, sites.count, label))
        // The move is done and the cards are elsewhere on the page: keeping them ticked would let a
        // second press move the same batch again, which is never what anyone means.
        selection.removeAll()
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
                                        if selecting {
                                            // 选择模式下整张卡片就是一个勾选框：不跳转、不开详情，
                                            // 点哪都是切换勾选。这是这个页面唯一「点了不进去」的时候，
                                            // 而顶部的操作条已经说明了此刻在做什么。
                                            Button { toggle(site) } label: {
                                                SiteCard(site: site, dimmed: group.kind == .hidden, chosen: selection.contains(site.key))
                                            }
                                            .tileButton()
                                            .accessibilityAddTraits(selection.contains(site.key) ? .isSelected : [])
                                            .accessibilityIdentifier("sources.pick." + site.key)
                                        } else if let pick {
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
                                                // 子源改名 + 删除（要求 7）。
                                                // 改名写 `SourceOverrides`（不动订阅文件，刷新后仍在）；
                                                // 删除写 `deletedSources` + 隐藏，理由见 `Store.deleteSite`。
                                                Button {
                                                    renamingSite = (site, config.origin)
                                                } label: {
                                                    Label(L10n.text("Rename Source"), systemImage: "character.cursor.ibeam")
                                                }
                                                Button(role: .destructive) {
                                                    deletingSite = (site, config.origin)
                                                } label: {
                                                    Label(L10n.text("Delete Source"), systemImage: "trash")
                                                }
                                                // 「看得见但这次不搜」——与隐藏正交，见 `SearchParticipationButton`。
                                                SearchParticipationButton(site: site)
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
        // The card must show the site the viewer actually gets, not the one the feed shipped.
        // `resolvedSite` applies the rename and the API override; reading `site.name` here was the
        // third instance of "written under one name, read under another": a rename took effect in the
        // player and nowhere on this page, so the tile kept the old name and only a "Customized"
        // badge hinted that anything had changed.
        let shown = store.subscription.map { store.resolvedSite(site, origin: $0.origin) } ?? site
        let label = SourceLabel(shown.name)
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
            SourceIcon(site: shown, label: label, size: icon)
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
                    if customized { SourceRouteBadge(site: site, fallback: L10n.text("Customized")) }
                    EgressWinnerBadge(sourceKey: site.sourceKey)
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
/// The way in to the sweep, on the page the decisions happen on.
///
/// It is a card rather than only a toolbar item because a toolbar menu on a phone hides its contents
/// behind one more tap, and the numbers below are the argument for opening it: how many sources have a
/// reading, how many are stale. Without them the card is a button with no reason to press.
private struct SpeedAndGroupingCard: View {
    let open: () -> Void
    @Environment(Store.self) private var store

    var body: some View {
        let probes = SourceProbeStore.shared
        let measured = probes.measuredSourceCount
        let window = store.probeMaxAge
        let fresh: Int = {
            guard window > 0 else { return 0 }
            let cutoff = Date().addingTimeInterval(-window)
            return probes.measuredSources().filter { $0.reading.measuredAt >= cutoff }.count
        }()
        Button(action: open) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "speedometer")
                    .font(.title3).foregroundStyle(Brand.accent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Speed & Grouping")).font(.headline)
                    Text(detail(measured: measured, fresh: fresh, window: window))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sources.speedLabCard")
        .glassRow()
    }

    private func detail(measured: Int, fresh: Int, window: TimeInterval) -> String {
        guard measured > 0 else { return L10n.text("Measure the sources, then file them by result.") }
        guard window > 0 else { return L10n.text("%lld measured", measured) }
        return L10n.text("%lld measured, %lld within the window", measured, fresh)
    }
}

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
    /// Opens the group-priority list.
    let arrangeGroups: () -> Void
    private var enabled: Binding<Bool> {
        Binding { store.sourceOrder.enabled } set: { on in withAnimation(.smooth) { store.setCustomSourceOrder(on) } }
    }
    private var detail: String {
        L10n.text(store.sourceOrder.enabled ? "Sources at the top are searched first, and their results are listed first."
                                            : "Mi3s searches quick, reliable sources first.")
    }
    /// The group ranking, said as what it does to a search rather than as a setting name: 300 sources
    /// is a list nobody orders by hand, while six groups is a list anyone can.
    private var groupDetail: String {
        let ranked = store.sourceOrder.savedGroupOrder.count
        let total = store.sourceGroups(includeHidden: false).count
        guard ranked > 0 else {
            return L10n.text("Rank whole groups — a feed, or a group you made — so one is asked before another. Sources inside a group keep their own order.")
        }
        return L10n.text("%lld of %lld groups ranked. The ones ranked are searched before the rest.", ranked, total)
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
            Button(action: arrangeGroups) {
                TVSettingsRowLabel(title: L10n.text("Group Priority"), detail: groupDetail, chevron: true)
            }
            .glassRow()
            .accessibilityIdentifier("sources.order.groups")
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
            Divider()
            // 分组优先级与「自定义源顺序」并排，而不是藏在它下面：两者回答的是同一个问题的
            // 两种粒度（哪一组先问 / 组里哪个先问），关掉后者不该顺带失去前者。
            HStack(spacing: 14) {
                IconTile(symbol: "square.stack.3d.up", tint: Brand.teal, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Group Priority")).font(.subheadline.weight(.semibold))
                    Text(groupDetail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(action: arrangeGroups) {
                    Text(L10n.text("Rank Groups"))
                        .font(.caption.weight(.semibold)).foregroundStyle(Brand.onAccent)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Brand.teal, in: Capsule())
                }
                .buttonStyle(LiftButtonStyle())
                .accessibilityIdentifier("sources.order.groups")
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

#if os(tvOS) && TVOS_DETAIL_PAGE_WIP
// ═══════════════════════════════════════════════════════════════════════════
// ⛔ 隔离中：Apple TV 的视频详情页（`bilibiliTVPage` / `tvDetailPage`）
// ═══════════════════════════════════════════════════════════════════════════
//
// 这段代码**从未编译通过过**，不是"平台守卫缺失"，而是**半成品**：
// 它引用了 4 个全仓不存在的符号 —— `bilibiliCreator` / `sourceExtras` /
// `sourceRelated` / `tvScrolled`（`tvScrolled` 只在 DiscoverDetailView 有同名私有属性）。
// `bilibiliTVPage` 与 `tvDetailPage` 也因此没有任何调用方（grep 零命中）。
//
// 它需要的是**功能补全**（UP 主数据从哪来、sourceExtras/sourceRelated 怎么拼），
// 不是平台隔离能解决的，也超出本次「tvOS 可编译性清理」的范围。
// 故用 `TVOS_DETAIL_PAGE_WIP` 编译开关隔离：默认不参与编译，tvOS 能过；
// 谁要接着做这份页面，打开开关就会重新看到全部待补点。
//
// 补全清单：
//   1. `bilibiliCreator: (mid: Int, name: String)?` —— 需要 VideoDetailView 拿到 UP 主信息
//   2. `sourceExtras: some View` —— 片源附加信息区
//   3. `sourceRelated: some View` —— 相关推荐区
//   4. `@State tvScrolled: Bool` —— 滚动状态（放 VideoDetailView 类体，不能放 extension）
//   5. `@FocusState tvHeroFocus: TVHeroItem?` + `@State showsTVSynopsis` 同理
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
                    // 「跟随订阅」是 `clear`，不是 `set(.auto)`：两者在 `effectiveRoute` 里都会回落到
                    // 订阅的默认路由，但 `set(.auto)` 会**留下一条显式记录** ——
                    // 而「Auto」那个档的意思本是「按连通性自动切换」。既然按钮写的是「跟随订阅」，
                    // 它就该把这条显式选择删掉，让源真正回到订阅的默认行为。
                    Button {
                        guard let config = store.subscription else { return }
                        store.sourceRouting.clear(site, origin: site.origin(or: config.origin))
                        store.rebuildSubscription()
                    } label: {
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

// MARK: - 参与搜索（源 / 分组 / 订阅）

/// 一条源在搜索里的开关。
///
/// 与 `HideSourceButton` 并排放在同一张菜单里，但**语义不同、不能合并**：
/// 隐藏让源在列表里看不见；这个只是「搜索时跳过它」。合并会让用户二选一地丢功能 ——
/// 把「不参与搜索」做成隐藏，他就再也找不到这条源；把隐藏做成「不参与搜索」，
/// 他以为只是不搜，结果列表也空了。见 `SearchScope` 头部。
struct SearchParticipationButton: View {
    @Environment(Store.self) private var store
    let site: Site
    var body: some View {
        let on = store.participatesInSearch(site)
        Button { store.setParticipatesInSearch(site, !on) } label: {
            Label(L10n.text(on ? "Skip in Search" : "Include in Search"),
                  systemImage: on ? "magnifyingglass.circle" : "magnifyingglass.circle.fill")
        }
        .accessibilityIdentifier("source.search." + site.key)
    }
}

/// 整组在搜索里的开关（分组头的菜单）。
struct GroupSearchParticipationButton: View {
    @Environment(Store.self) private var store
    /// ⛔ 名字不能叫 `group`：`Darwin` 里有一个全局 `group` 方法，`group.id` 会被解析成
    /// 「取那个方法」而不是「这个属性」，报 `use of 'group' refers to instance method`。
    let sourceGroup: SourceGroup
    /// 改名用。传 nil 时不显示改名项（系统组没有可改的名字）。
    var rename: (() -> Void)? = nil
    var body: some View {
        let id = sourceGroup.id
        let on = store.groupParticipatesInSearch(id)
        Button { store.setGroupParticipatesInSearch(id, !on) } label: {
            Label(L10n.text(on ? "Skip This Group in Search" : "Include This Group in Search"),
                  systemImage: on ? "magnifyingglass.circle" : "magnifyingglass.circle.fill")
        }
        .accessibilityIdentifier("sources.groupSearch." + id)
        if let rename {
            Button { rename() } label: {
                Label(L10n.text("Rename Group"), systemImage: "character.cursor.ibeam")
            }
            .accessibilityIdentifier("sources.groupRename." + id)
        }
    }
}

/// 订阅在搜索里的开关 + 改名（订阅头的菜单）。
struct SubscriptionSearchMenu: View {
    @Environment(Store.self) private var store
    let address: String
    var rename: () -> Void
    var body: some View {
        let on = store.subscriptionParticipatesInSearch(address)
        Button { store.setSubscriptionParticipatesInSearch(address, !on) } label: {
            Label(L10n.text(on ? "Skip This Subscription in Search" : "Include This Subscription in Search"),
                  systemImage: on ? "magnifyingglass.circle" : "magnifyingglass.circle.fill")
        }
        Button { rename() } label: {
            Label(L10n.text("Rename Subscription"), systemImage: "character.cursor.ibeam")
        }
    }
}

/// 改名输入框。`.alert` 里只能放 `TextField` / `Button`，所以用 `@ViewBuilder` 包一层。
///
/// `initial` 是**当前名字**：打开就带出来，用户按需改，而不是从空框重打一遍。
private struct RenameField: View {
    let initial: String
    let commit: (String) -> Void
    let cancel: () -> Void
    @State private var text = ""

    var body: some View {
        TextField(L10n.text("Name"), text: $text)
        Button(L10n.text("Save")) { commit(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        Button(L10n.text("Cancel"), role: .cancel) { cancel() }
        // 首次出现时把当前名字带出来。
        //
        // ⛔ 只靠 `onAppear` 不够。同一个 `RenameField` 被 3 个 alert（改名分组 /
        // 改名订阅 / 改名子源）以相同结构位置实例化，SwiftUI 在两次弹窗之间会复用
        // 同一份 `@State`；`onAppear` 是否重放取决于 alert 内容的身份稳定性，不能指望。
        // 不重放的后果很具体：第二次改名带出上一次目标的旧名字，用户按 Save
        // 就把 A 的名字写进 B。
        //
        // `.task(id:)` 在 `initial` 变化时保证重新播种（`initial` 不同 = 换了目标）。
        Color.clear.frame(height: 0)
            .onAppear { text = initial }
            .task(id: initial) { text = initial }
    }
}

/// 分组 / 订阅两个改名框。
///
/// 单独一个 `ViewModifier` 而不是直接写在 `SitesView.body` 的修饰符链上：那条链已经
/// 很长（选择模式、折叠、各种 sheet），再加两个带闭包参数的 `alert` 会让 Swift 的类型
/// 检查超时。拆出来之后每个 `body` 只多一个修饰符，复杂度回到编译器能处理的量级。
private struct RenameAlerts: ViewModifier {
    @Environment(Store.self) private var store
    @Binding var renamingGroup: SourceGroup?
    @Binding var renamingSubscription: String?
    /// 子源改名。与上面两个不同：子源没有「身份」可改，只能写 Override。
    @Binding var renamingSite: (site: Site, origin: URL)?
    /// 删除确认。破坏性操作一律二次确认 —— 尤其分组：用户会以为「删组=删源」。
    @Binding var deletingGroup: SourceGroup?
    @Binding var deletingSite: (site: Site, origin: URL)?

    func body(content: Content) -> some View {
        content
            .alert(L10n.text("Rename Group"), isPresented: Binding(
                get: { renamingGroup != nil },
                set: { if !$0 { renamingGroup = nil } }
            )) {
                RenameField(initial: renamingGroup?.title ?? "") { name in
                    if let group = renamingGroup, case .custom(let id) = group.kind {
                        store.renameSourceGroup(id, to: name)
                    }
                    renamingGroup = nil
                } cancel: {
                    renamingGroup = nil
                }
            }
            .alert(L10n.text("Rename Subscription"), isPresented: Binding(
                get: { renamingSubscription != nil },
                set: { if !$0 { renamingSubscription = nil } }
            )) {
                RenameField(initial: renamingSubscription.map { store.subscriptionTitle($0) } ?? "") { name in
                    if let address = renamingSubscription { store.renameSubscription(address, to: name) }
                    renamingSubscription = nil
                } cancel: {
                    renamingSubscription = nil
                }
            }
            // 子源改名。初始值取 `siteTitle`（带已有覆盖），否则每次打开都是原始名，
            // 用户改过一次再进来会以为没保存。
            .alert(L10n.text("Rename Source"), isPresented: Binding(
                get: { renamingSite != nil },
                set: { if !$0 { renamingSite = nil } }
            )) {
                RenameField(initial: renamingSite.map { store.siteTitle($0.site, origin: $0.origin) } ?? "") { name in
                    if let target = renamingSite { store.renameSite(target.site, origin: target.origin, to: name) }
                    renamingSite = nil
                } cancel: {
                    renamingSite = nil
                }
            }
            // 删分组：确认文案必须说清「源不会跟着删」，否则没人敢按。
            .alert(L10n.text("Delete Group?"), isPresented: Binding(
                get: { deletingGroup != nil },
                set: { if !$0 { deletingGroup = nil } }
            )) {
                Button(L10n.text("Delete"), role: .destructive) {
                    if let group = deletingGroup, case .custom(let id) = group.kind {
                        store.deleteSourceGroup(id)
                    }
                    deletingGroup = nil
                }
                Button(L10n.text("Cancel"), role: .cancel) { deletingGroup = nil }
            } message: {
                Text(L10n.text("Its sources go back to the subscription they came from. No source is deleted."))
            }
            // 删子源：真删，且要说清「刷新订阅也不会回来」——那是 `deletedSources` 的作用。
            .alert(L10n.text("Delete Source?"), isPresented: Binding(
                get: { deletingSite != nil },
                set: { if !$0 { deletingSite = nil } }
            )) {
                Button(L10n.text("Delete"), role: .destructive) {
                    if let target = deletingSite { store.deleteSite(target.site, origin: target.origin) }
                    deletingSite = nil
                }
                Button(L10n.text("Cancel"), role: .cancel) { deletingSite = nil }
            } message: {
                Text(L10n.text("This removes the source from this subscription for good. Refreshing the subscription will not bring it back, and it cannot be undone."))
            }
    }
}

// MARK: - 源出口标注

/// 一条源当前的出口：**代理 / 直连 / 自动**。
///
/// 之前源列表里只有一个笼统的「Customized」徽标，观众看得出「改过」，却看不出改成什么；
/// 详情页、播放页、搜索结果干脆什么都不显示。源出现在哪个面板都要能一眼看出它会从哪条腿出去。
///
/// `fallback` 是「没有显式路由、但源被改名/改地址」时显示的文字 —— 那种情况仍然要提示，
/// 只是不该再说成「自定义」而不给出口。
/// 「这个源上一次取片单，赛跑是谁赢的」。
///
/// 观众要能一眼看出实际走的哪条腿 —— 配置写「代理」而实际直连这种事，
/// 只有把**真实结果**摆在列表上才看得见。超过五分钟的结论不显示：
/// 改完设置还挂着旧结果会误导。
struct EgressWinnerBadge: View {
    let sourceKey: String

    var body: some View {
        if let entry = EgressOutcomeStore.shared.fresh(sourceKey: sourceKey) {
            let tint: Color = entry.isProxy ? Brand.amber : .secondary
            Text(entry.isProxy ? L10n.text("Proxy") : L10n.text("Direct"))
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(tint)
                .background(tint.opacity(0.14), in: Capsule())
                .accessibilityLabel(L10n.text("Last fetch took the %@ leg", entry.isProxy ? "proxy" : "direct"))
        }
    }
}

struct SourceRouteBadge: View {
    @Environment(Store.self) private var store
    let site: Site
    var fallback: String? = nil

    var body: some View {
        if site.native, !site.api.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let explicit = store.subscription.flatMap {
                store.sourceRouting.route(site, origin: $0.origin)
            }
            if let route = explicit {
                Text(route.title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .foregroundStyle(route.badgeTint)
                    .background(route.badgeTint.opacity(0.16), in: Capsule())
                    .accessibilityLabel(L10n.text("Route: %@", route.title))
            } else if let fallback {
                Text(fallback).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } else if let fallback {
            Text(fallback).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

extension SourceRoute {
    /// 三种出口的固定色：代理偏靛、直连偏绿、自动走次要色。
    var badgeTint: Color {
        switch self {
        case .proxy: return Brand.indigo
        case .direct: return Color(red: 0.20, green: 0.60, blue: 0.36)
        case .auto: return .secondary
        }
    }
}
