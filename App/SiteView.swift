import SwiftUI
import TVCore

struct SiteView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) var dismiss
    let site: Site
    let origin: URL
    let jarURL: URL?
    var initialQuery: String = ""
    /// A drive source's folder: the page lists it in place of the source's home.
    var folder: Video? = nil
    /// The source's home as another page already has it (Watch Now's recommendations): shown at once, then refreshed.
    var preview: (videos: [Video], categories: [TVCore.Category])? = nil
    private var canLoad: Bool { site.canBrowse(jarURL: jarURL) }
    private var isIndex: Bool { (site.raw["indexs"]?.int ?? 0) == 1 }
    @State var browser = CatalogBrowser()
    @State private var query = ""
    /// The Bilibili login this page loaded with; signing in or out reloads it with the account's lists.
    @State private var bilibiliLogin = BilibiliAccount.load().cookie
    private var initialLoading: Bool { browser.videos.isEmpty && browser.error == nil && (browser.busy || !browser.loaded) }
    var client: CatalogClient { CatalogClient(site: site, origin: origin, jarURL: jarURL) }
    @State private var requestTask: Task<Void, Never>?

    func startRequest(_ operation: @escaping @MainActor () async -> Void) {
        requestTask?.cancel()
        requestTask = Task {
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    /// 这个源当前显示的 name（带用户在「源」页做的改名）。
    private var shownName: String {
        guard let origin = store.subscription?.origin else { return site.name }
        return store.resolvedSite(site, origin: origin).name
    }

    var body: some View {
        Group {
            if !canLoad {
                ContentUnavailableView {
                    Label(site.compatibility, systemImage: "puzzlepiece.extension")
                } description: {
                    if site.type != 3 {
                        Text(L10n.text("This source format is not supported. Choose another source."))
                    } else {
                        Text(site.runtime == .jar ? L10n.text("This source uses a plugin that requires Android DEX and native libraries. This platform does not yet have the required compatibility layer.\n\n%@", site.api)
                             : site.runtime == .python ? L10n.text("This source requires a Python runtime, which is not available on this platform.")
                             : L10n.text("This source requires a JavaScript engine, which is not supported yet."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #if os(tvOS)
                .focusable()
                .onExitCommand { dismiss() }
                #endif
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        #if os(tvOS)
                        // The remote's keyboard has no return key, so typing only edits the query; as in
                        // the Search tab, a focusable button below the keyboard runs the search.
                        let pending = query.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !pending.isEmpty, pending != browser.query {
                            SearchQueryButton(query: pending) { startRequest { await search() } }
                                .accessibilityIdentifier("site.search.submit")
                        }
                        #endif
                        if site.isBilibili && !BilibiliAccount.load().signedIn { BilibiliSignInBanner() }
                        if !browser.categories.isEmpty { categoryBar } else if initialLoading && folder == nil { ChipSkeletonRow() }
                        if browser.query.isEmpty, let current = browser.categories.first(where: { $0.id == browser.category }), !current.filters.isEmpty {
                            CategoryFilterBar(filters: current.filters, choices: browser.filters) { choices in
                                startRequest { await browser.load(.list(category: current.id, query: "", page: 1, filters: choices), client: client) }
                            }
                        }
                        if isIndex && !browser.videos.isEmpty {
                            Text(L10n.text("Choose a title to find it across your sources.")).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if browser.busy {
                            LoadingCard { .source(site, origin: origin, title: L10n.text("Loading source content…")) }
                        }
                        if initialLoading { PosterSkeletonGrid().loadingFocus { dismiss() } }
                        if let error = browser.error {
                            ErrorStateCard(
                                title: L10n.text("Unable to load this source"),
                                message: L10n.text("Try again, or choose another source to keep watching."),
                                details: error,
                                retry: { startRequest { await browser.load(browser.request, client: client) } },
                                goBack: { dismiss() },
                                busy: browser.busy
                            )
                            .padding(.vertical, browser.videos.isEmpty ? 24 : 8)
                        }
                        if browser.videos.isEmpty && browser.loaded && !browser.busy && browser.error == nil { EmptyResults(symbol: "film", title: L10n.text("No Videos"), message: L10n.text("Try selecting a category or searching.")) }
                        LazyVGrid(columns: Layout.posterColumns, spacing: Layout.gridRowSpacing) {
                            ForEach(browser.videos) { video in
                                // An index source (a ranking or list site) names titles; other sources play them.
                                // [mi3s] 二开融合（D-11 回填）：最后一张封面出现时追加下一页，
                                // 滚动不会停在页边界。失败的一页交给底部 footer 的 Retry，
                                // 不在滚动里反复重试（与上游 1.8.11 SitesView 同语义）。
                                // 用 Group 包住 if/else 才能挂 .onAppear —— 语句块后面不能直接接修饰符。
                                Group {
                                    if isIndex {
                                        Button { store.searchVideos(video.name) } label: { PosterCard(video: video) }.cardButton()
                                    } else {
                                        RouteLink { CatalogDestination(video: video, client: client) } label: { PosterCard(video: video) }.cardButton()
                                    }
                                }
                                // [mi3s] 二开：长按海报 → 迷你播放器播放 / 下载（要求 6）。
                                // 索引源（ranking / 列表站）的海报点了是「跨源搜索」，没有可播的一集，
                                // 所以不挂这个菜单 —— 挂了只会给出两个点了就报错的项。
                                .modifier(OptionalPosterMenu(enabled: !isIndex, video: video, client: client))
                                .onAppear {
                                    guard browser.moreError == nil, video.id == browser.videos.last?.id else { return }
                                    startRequest { await loadMore() }
                                }
                            }
                        }
                        .opacity(browser.busy && !browser.videos.isEmpty ? 0.55 : 1).animation(.smooth, value: browser.busy)
                        // [mi3s] 二开融合（D-11 回填）：底部续页状态条。
                        // tvFocusSection 让 tvOS 从任意列的封面按 Down 都能落到它。
                        if !browser.videos.isEmpty && (browser.hasMore || browser.loadingMore || browser.moreError != nil) {
                            loadMoreFooter.tvFocusSection()
                        }
                    }.pageContainer()
                }
                // [mi3s] 二开融合（D-12 回填）：页码条与自动续页互斥。
                // loadMoreFooter 在滚动区末尾，pager 是固定底栏 —— 两者同屏会出现
                // 「滚到底有 Load More，屏底还有页码条」两套翻页控件（D-12 说的混装）。
                // 规则：只要这个源支持续页（hasMore / loadingMore / moreError 任一为真）
                // 就不显示页码条，交给自动续页；不支持的源仍用页码条。
                .safeAreaInset(edge: .bottom) {
                    if browser.pageCount > 1 && !browser.hasMore && !browser.loadingMore && browser.moreError == nil {
                        pager
                    }
                }
                .catalogSearchable(text: Binding(get: { query }, set: { value in
                    query = value
                    if value.isEmpty && !browser.query.isEmpty { startRequest { await home() } }
                }), prompt: L10n.text("Search videos"))
                .onSubmit(of: .search) { startRequest { await search() } }
            }
        }
        .onDisappear { requestTask?.cancel(); browser.cancel() }
        .toolbar {
            // Handed the store: UIKit can size a bar item before SwiftUI gives it the page's environment, and these
            // buttons read Store first thing (a TestFlight crash on iPhone).
            Group {
                PinSourceButton(site: site, origin: origin)
                HideSourceButton(site: site, origin: origin)
            }
            .environment(store)
        }
        .screenBackdrop()
        .onAppear {
            guard site.isBilibili, browser.loaded else { return }
            let login = BilibiliAccount.load().cookie
            if login != bilibiliLogin { bilibiliLogin = login; query = ""; startRequest { await home(); await browser.loadCategories(client: client) } }
        }
        // ⛔ 标题必须走 `resolvedSite`，否则卡片上改了名、点进源里还是旧名 ——
        // 用户会以为改名没保存。一个源「显示什么名」只能有一个来源。
        .screenTitle(folder?.name ?? shownName).task {
            store.searchModel.suspend()
            // A source card can still be on screen when the vault relocks (timeout, screenshot, background):
            // the page must not then browse a hidden source's catalog.
            if !store.vault.permits(site: site, fallback: origin) {
                store.error = L10n.text("This source is hidden. Unlock the Privacy Vault to browse it.")
                dismiss()
                return
            }
            if let preview, folder == nil, initialQuery.isEmpty { browser.seed(videos: preview.videos, categories: preview.categories) }
            if canLoad && !browser.loaded {
                if browser.request != .home {
                    await browser.load(browser.request, client: client)
                } else if initialQuery.isEmpty {
                    await home()
                    #if DEBUG
                    // `-qaCategory <type id>` opens that category, for screenshots.
                    if let category = UserDefaults.standard.string(forKey: "qaCategory") {
                        await browser.load(.list(category: category, query: "", page: 1), client: client)
                    }
                    // `-qaSearchDraft <text>` types a query without running it, for the remote's Search button.
                    if let draft = UserDefaults.standard.string(forKey: "qaSearchDraft") { query = draft }
                    #endif
                }
                else { query = initialQuery; await search(); await browser.loadCategories(client: client) }
            }
        }
    }
    private var categoryBar: some View {
        ChipRow {
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    Chip(title: L10n.text("Recommendations"), selected: browser.query.isEmpty && browser.category.isEmpty) { query = ""; startRequest { await home() } }
                    ForEach(browser.categories) { item in
                        Chip(title: item.name, selected: browser.query.isEmpty && browser.category == item.id) {
                            query = ""
                            let filters = CategoryFilter.initialChoices(item.filters)
                            startRequest { await browser.load(.list(category: item.id, query: "", page: 1, filters: filters), client: client) }
                        }
                    }
                }
            }.padding(.vertical, 4)
        }
    }
    private var pager: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                Button { startRequest { await load(page: browser.page - 1) } } label: { Image(systemName: "chevron.left").frame(width: 22) }
                    .controlButton().disabled(browser.page <= 1 || browser.busy).accessibilityLabel(L10n.text("Previous"))
                Text(L10n.text("Page %lld of %lld", browser.page, browser.pageCount)).font(.subheadline.weight(.medium).monospacedDigit())
                    .padding(.horizontal, 16).padding(.vertical, 10)
                Button { startRequest { await load(page: browser.page + 1) } } label: { Image(systemName: "chevron.right").frame(width: 22) }
                    .controlButton().disabled(browser.page >= browser.pageCount || browser.busy).accessibilityLabel(L10n.text("Next"))
            }
        }.controlSize(.large)
        #if os(tvOS)
        .padding(.vertical, 20).frame(maxWidth: .infinity).background(TVStyle.background).focusSection()
        #else
        .padding(.vertical, 8).frame(maxWidth: .infinity).controlBackdrop()
        #endif
    }
    private func home() async { await browser.load(folder.map { .list(category: $0.id, query: "", page: 1) } ?? .home, client: client) }
    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { await home() }
        else { await browser.load(.list(category: nil, query: text, page: 1), client: client) }
    }
    private func load(page next: Int) async {
        await browser.load(.list(category: browser.category.isEmpty ? nil : browser.category, query: browser.query, page: next, filters: browser.filters),
                           client: client)
    }

    // [mi3s] 二开融合（D-11 回填）：追加下一页而不清空当前列表。
    // CatalogBrowser.loadMore(client:) 自带 hasMore/loadingMore/moreError 三态与去重，
    // UI 只负责触发与呈现。
    func loadMore() async {
        await browser.loadMore(client: client)
    }

    // [mi3s] 二开融合（D-11 回填）：底部续页状态条，三态与上游一致
    // （加载中 / 加载更多 / 重试），文案沿用上游 key。
    @ViewBuilder var loadMoreFooter: some View {
        if let message = browser.moreError {
            VStack(spacing: 10) {
                Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(L10n.text("Try Again")) { startRequest { await loadMore() } }
                    .controlButton()
                    .accessibilityIdentifier("site.loadMore.retry")
            }
            .padding(.vertical, 18).frame(maxWidth: .infinity)
        } else if browser.loadingMore {
            HStack(spacing: 10) {
                ProgressView()
                Text(L10n.text("Loading…")).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.vertical, 18).frame(maxWidth: .infinity)
        } else if browser.hasMore {
            Button(L10n.text("Load More")) { startRequest { await loadMore() } }
                .controlButton()
                .padding(.vertical, 18).frame(maxWidth: .infinity)
                .accessibilityIdentifier("site.loadMore")
        }
    }
}

/// A category's filters (TVBox `filters`: 类型, 地区, 年份…) drawn as Discover's catalog search draws its own: one
/// "地区：全部 ⌄" chip per filter. On the Mac a chip opens a popover of choices, on iPhone, iPad and Apple TV a
/// menu. Each choice reloads the category from its first page.
struct CategoryFilterBar: View {
    let filters: [CategoryFilter]
    let choices: [String: String]
    let choose: ([String: String]) -> Void
    #if os(macOS)
    @State private var open: String?
    #endif

    private func value(_ filter: CategoryFilter) -> String { choices[filter.key] ?? filter.initial }
    private func changed(_ filter: CategoryFilter) -> Bool { value(filter) != filter.initial }
    private var anyChanged: Bool { filters.contains(where: changed) }
    private func title(_ filter: CategoryFilter) -> String {
        let current = value(filter)
        return filter.name + "：" + (filter.options.first { $0.value == current }?.name ?? current)
    }
    private func pick(_ filter: CategoryFilter, _ option: String) {
        guard value(filter) != option else { return }
        var next = choices
        next[filter.key] = option
        choose(next)
    }
    private func reset() { choose(CategoryFilter.initialChoices(filters)) }

    var body: some View {
        #if os(macOS)
        DiscoverChipFlow(spacing: 8) {
            ForEach(filters) { filter in
                Button { open = open == filter.key ? nil : filter.key } label: { FilterChipLabel(title: title(filter), open: open == filter.key) }
                    .buttonStyle(.plain)
                    .popover(isPresented: Binding(get: { open == filter.key }, set: { if !$0, open == filter.key { open = nil } }), arrowEdge: .bottom) {
                        panel(filter)
                    }
                    .accessibilityIdentifier("site.filter.\(filter.key)")
            }
            if anyChanged {
                Button(action: reset) {
                    Label(L10n.text("Reset Filters"), systemImage: "xmark").font(.system(size: 13)).padding(.horizontal, 12).frame(height: 30)
                        .contentShape(Capsule())
                }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityIdentifier("site.filters.reset")
            }
        }
        .accessibilityIdentifier("site.filters")
        #if DEBUG
        // `-qaOpenFilter <key>` opens that filter's choices, for screenshots.
        .task { if let key = UserDefaults.standard.string(forKey: "qaOpenFilter") { try? await Task.sleep(for: .seconds(1)); open = key } }
        #endif
        #elseif os(tvOS)
        ScrollView(.horizontal) {
            HStack(spacing: 18) {
                ForEach(filters) { filter in
                    Menu { picker(filter) } label: { Text(title(filter)) }
                        .menuStyle(.button)
                        .buttonStyle(DiscoverTVChipStyle(active: changed(filter)))
                        .accessibilityIdentifier("site.filter.\(filter.key)")
                }
                if anyChanged {
                    Button(action: reset) { Label(L10n.text("Reset Filters"), systemImage: "xmark") }
                        .buttonStyle(DiscoverTVChipStyle(active: false))
                        .accessibilityIdentifier("site.filters.reset")
                }
            }.padding(.vertical, 16)
        }
        .scrollIndicators(.hidden).scrollClipDisabled().focusSection()
        .accessibilityIdentifier("site.filters")
        #else
        ScrollView(.horizontal) {
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(filters) { filter in
                        Menu { picker(filter) } label: { FilterChipLabel(title: title(filter)) }
                            .accessibilityIdentifier("site.filter.\(filter.key)")
                    }
                    if anyChanged {
                        Button(action: reset) { Image(systemName: "xmark").frame(width: 38, height: 38).glassSurface(.regular, in: Circle()) }
                            .accessibilityLabel(L10n.text("Reset Filters")).accessibilityIdentifier("site.filters.reset")
                    }
                }
            }
        }
        .scrollIndicators(.hidden).scrollClipDisabled().frame(height: 38)
        .tint(.primary)
        .accessibilityIdentifier("site.filters")
        #endif
    }

    #if os(macOS)
    /// The filter's choices as Discover's filter popovers lay them out; a long list (years) scrolls.
    private func panel(_ filter: CategoryFilter) -> some View {
        let grid = LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(filter.options, id: \.value) { option in
                FilterChoiceButton(title: option.name, selected: value(filter) == option.value) {
                    pick(filter, option.value)
                    open = nil
                }
            }
        }.padding(14)
        return Group {
            if filter.options.count > 30 { ScrollView { grid }.frame(height: 340) } else { grid }
        }
        .frame(width: 360)
    }
    #else
    private func picker(_ filter: CategoryFilter) -> some View {
        Picker(filter.name, selection: Binding(get: { value(filter) }, set: { pick(filter, $0) })) {
            ForEach(filter.options, id: \.value) { Text($0.name).tag($0.value) }
        }
    }
    #endif
}

/// Where a listed title opens: its details, or for a drive source's folder the folder's listing.
struct CatalogDestination: View {
    let video: Video
    let client: CatalogClient
    var body: some View {
        if video.isFolder { SiteView(site: client.site, origin: client.origin, jarURL: client.jarURL, folder: video) }
        else { VideoDetailView(video: video, client: client) }
    }
}

/// `isIndex` 为真时不挂长按菜单。
///
/// 不能写成 `if isIndex { … } else { content.catalogPosterMenu(…) }` 包住整段：那样两个分支
/// 是不同视图身份，滚到屏幕外的卡片重建时会丢掉 `onAppear` 的续页触发。用一个空修饰器保持身份。
private struct OptionalPosterMenu: ViewModifier {
    let enabled: Bool
    let video: Video
    let client: CatalogClient

    func body(content: Content) -> some View {
        if enabled { content.catalogPosterMenu(video, client: client) } else { content }
    }
}
