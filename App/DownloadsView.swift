import SwiftUI
import TVCore
#if !os(macOS)
import UIKit
#endif
#if os(iOS)
import BackgroundTasks
#endif

/// Downloaded episodes, the download queue, and how much space they take.
struct DownloadsView: View {
    @Environment(Store.self) private var store
    @State private var deleting: DownloadShow?
    /// The whole-list confirmation, which is a different question from deleting one show.
    @State private var confirmingAll = false
    /// Videos or songs, once there are songs; videos first unless only songs are saved.
    @State private var kind = Kind.videos
    private var library: DownloadLibrary { .shared }
    enum Kind: Hashable { case videos, music }
    // [mi3s] 二开：接入隐私保险库。上游直接渲染 library.items —— 已隐藏源的剧集仍显示在下载页。
    // 与历史、收藏同规则：保险库只能隐藏「能同时说出 origin 与 siteKey」的下载。
    /// Downloads the Privacy Vault may show. A hidden source's episodes vanish from this list entirely,
    /// like its history and favourites do. A download saved before its source carried an origin stays
    /// visible: the vault can only hide what it can name.
    private var visibleItems: [DownloadItem] {
        // 隐私保险库过滤（隐藏源的剧集不显示）+ 多环境隔离过滤（只看当前环境）。
        // 环境过滤收在 `DownloadLibrary.visibleItems()` 里，与详情页「这一集下过没有」用同一口径。
        store.vault.visibleDownloads(library.visibleItems())
    }

    var body: some View {
        let pending = visibleItems.filter(\.isPending)
        let shows = DownloadShow.group(visibleItems.filter { $0.status == .completed })
        Group {
            if hasMusic && kind == .music {
                MusicDownloadsView(embedded: true)
            } else if visibleItems.isEmpty {
                // One message instead of an empty storage card above it: a 0 KB total says nothing new.
                EmptyDownloads(available: library.usage.available) { store.section = .sites }
            } else {
                content(pending: pending, shows: shows)
            }
        }
        .modifier(DownloadKindBar(shown: hasMusic, kind: $kind))
        // One 的二次确认原文：「确认清空所有下载文件？」/「清空所有下载」。
        // 比原来那句「Delete every downloaded episode? The files leave this device.」多说一件事：
        // 打断点数据也算在里面（`removeAll()` 会清掉每个任务的 `plan.json`），
        // 所以清完再下是**从零开始**，不是续下。
        .confirmationDialog(L10n.text("Clear every downloaded file? Finished episodes, unfinished downloads and their resume data all go."),
                            isPresented: $confirmingAll, titleVisibility: .visible) {
            Button(L10n.text("Clear All Downloads"), role: .destructive) {
                // The reason this is not one `remove(ids)`: it also clears folders the list lost track of,
                // which is where the storage goes on a device that has been crashing.
                library.removeAll()
                MusicDownloadLibrary.shared.removeAll()
            }
        }
        .onAppear { if visibleItems.isEmpty && hasMusic { kind = .music } }
        .screenBackdrop()
        .tabTitle(L10n.text("Downloads"))
        .task { await library.measure() }
        .onChange(of: visibleItems.filter { $0.status == .completed }.count) { Task { await library.measure() } }
        #if os(macOS)
        // Space in one line under the window title, as Finder's status bar has it: beside a whole disk the
        // downloads were a sliver on a bar that was nearly all "Other".
        .navigationSubtitle(visibleItems.isEmpty && MusicDownloadLibrary.shared.visibleItems.isEmpty ? "" : storageSummary)
        // Files may have been deleted or moved in Finder while the app was in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await library.measure() }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { NSWorkspace.shared.open(hasMusic && kind == .music ? MusicDownloadLibrary.shared.root : library.root) } label: {
                    Label(L10n.text("Show in Finder"), systemImage: "folder")
                }
                .help(L10n.text("Show in Finder"))
            }
        }
        #endif
        .confirmationDialog(L10n.text("Delete all downloaded episodes of %@?", deleting?.title ?? ""),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(L10n.text("Delete Downloads"), role: .destructive) {
                if let deleting { library.remove(deleting.items.map(\.id)) }
                deleting = nil
            }
        }
    }

    /// 点一集已下载的片：起播，并**把全屏播放器真正推上来**。
    ///
    /// ⛔ 只写 `store.playing` 是不够的 —— 那就是「从下载入口点进去没反应」的原因。
    ///
    /// `RootView` 的 `fullScreenCover` 判据是
    /// `(playsInWatchPage(playing) || !presentingPlayer) ? nil : …`：
    /// 从下载页起播时观看页不在前台（`playsInWatchPage` 为 false），
    /// 而 `presentingPlayer` 是 `false`（它只由小窗点击 / 播放器关闭写），
    /// 于是 `!presentingPlayer` 为真 → 整个表达式为真 → 弹层被判成 nil。
    /// `playing` 变了、会话也建了，**但没有东西被展示** —— 用户看到的就是点了没反应。
    ///
    /// 所以这里必须显式置 `presentingPlayer = true`。全 App 只有两处会写它：
    /// 小窗点击（RootView:377）与这里。两处都是「用户要求现在就看」。
    private func playDownloaded(_ item: DownloadItem) {
        store.presentingPlayer = true
        store.playing = library.channel(for: item)
    }

    /// Songs are saved apart, in Music; this page leads there too.
    private var hasMusic: Bool { !MusicDownloadLibrary.shared.visibleItems.isEmpty }

    /// 「保存位置：文件 App › 我的 iPhone › 顾及」+ 一键跳转。
    ///
    /// One 把这一行放在下载页底部（`保存位置：文件 App › 我的 iPhone › One`）与设置页各一份。
    /// 我们放在存储卡下面 —— 它和「占了多少空间」是同一个问题的两面：
    /// 「这些字节到底在哪」。
    ///
    /// 跳转用 `UIApplication.open` 打 `shareddocuments://`，这是「文件」App 唯一
    /// 公开可用的入口；它不接受路径参数，所以直接落到「最近」而不是目标文件夹。
    /// 只给 iOS/tvOS：macOS 上「文件」App 不存在，那边用「Show in Finder」那一套。
    @ViewBuilder private var saveLocationCard: some View {
        #if os(iOS)
        let folder = DownloadLibrary.defaultRoot.lastPathComponent
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .foregroundStyle(Brand.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("Save To")).font(.subheadline.weight(.medium))
                Text(L10n.text("Files app › On My iPhone › %@", folder))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let url = URL(string: "shareddocuments://") {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Text(L10n.text("Open")).font(.subheadline.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.accent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)) }
        #endif
    }

    #if os(macOS)
    private var storageSummary: String {
        let used = L10n.text("%@ used by downloads", DownloadFormat.size(library.usage.downloads + MusicDownloadLibrary.shared.size))
        guard let free = library.usage.available else { return used }
        return used + " · " + L10n.text("%@ free", DownloadFormat.size(free))
    }
    #endif

    private func content(pending: [DownloadItem], shows: [DownloadShow]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                #if !os(macOS)
                StorageCard(usage: library.usage, songs: MusicDownloadLibrary.shared.size)
                saveLocationCard
                #endif
                if !pending.isEmpty { queue(pending) }
                if !shows.isEmpty {
                    VStack(alignment: .leading, spacing: Layout.headerSpacing) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            SectionHeader(title: L10n.text("Downloaded"))
                            Spacer(minLength: 8)
                            Button(role: .destructive) { confirmingAll = true } label: {
                                Label(L10n.text("Clear All"), systemImage: "trash").lineLimit(1).fixedSize()
                            }
                            .controlButton()
                            .accessibilityLabel(L10n.text("Clear All Downloads"))
                        }
                        // Not lazy: the remote only moves focus to views that exist, and below a download queue
                        // as tall as the screen a lazy stack had built none, so Down stopped at the queue.
                        VStack(spacing: Layout.cardSpacing) {
                            ForEach(shows) { show in
                                ShowPanel(show: show) { playDownloaded($0) } delete: { deleting = show }
                            }
                        }
                    }.tvFocusSection()
                }
            }.pageContainer()
        }
    }

    #if os(macOS)
    /// The queue as Safari's downloads list: one grouped box of rows, with quiet text controls above it.
    private func queue(_ pending: [DownloadItem]) -> some View {
        let paused = pending.filter { $0.status == .paused || $0.status == .failed }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.text("Downloading")).font(.title3.weight(.semibold))
                Text("\(pending.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                Spacer(minLength: 12)
                SpeedMenu(compact: true)
                Divider().frame(height: 12)
                Divider().frame(height: 12)
                if paused.count == pending.count {
                    Button(L10n.text("Resume All")) { library.resumeAll() }.buttonStyle(.borderless)
                } else {
                    Button(L10n.text("Pause All")) { library.pauseAll() }.buttonStyle(.borderless)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(pending.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, 70) }
                    QueueRow(item: item, rate: library.rates[item.id], position: queuePosition(item, in: pending))
                }
            }
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)) }
        }
    }
    #else
    private func queue(_ pending: [DownloadItem]) -> some View {
        let paused = pending.filter { $0.status == .paused || $0.status == .failed }
        return VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            HStack(alignment: .center, spacing: 12) {
                SectionHeader(title: L10n.text("Downloading"))
                Text("\(pending.count)").font(.headline).monospacedDigit().foregroundStyle(.secondary)
                Spacer(minLength: 12)
                SpeedMenu(compact: false)
                if paused.count == pending.count {
                    Button { library.resumeAll() } label: { Label(L10n.text("Resume All"), systemImage: "play.fill").lineLimit(1).fixedSize() }.controlButton()
                } else {
                    Button { library.pauseAll() } label: { Label(L10n.text("Pause All"), systemImage: "pause.fill").lineLimit(1).fixedSize() }.controlButton()
                }
            }
            VStack(spacing: DownloadMetrics.rowSpacing) {
                ForEach(pending) { item in
                    QueueRow(item: item, rate: library.rates[item.id], position: queuePosition(item, in: pending))
                }
            }
        }.tvFocusSection()
    }
    #endif

    /// 1 for the next download to start.
    private func queuePosition(_ item: DownloadItem, in pending: [DownloadItem]) -> Int? {
        guard item.status == .queued else { return nil }
        return (pending.filter { $0.status == .queued }.firstIndex { $0.id == item.id } ?? 0) + 1
    }
}

/// Videos | Music once songs are saved too: in the window's toolbar on the Mac, beside the title, as
/// Music and Photos place theirs; a band of its own took a second row there. On iPhone and iPad it is
/// pinned under the title while the page scrolls under it; on Apple TV it is two chips over the page,
/// like the Music page's kinds.
private struct DownloadKindBar: ViewModifier {
    let shown: Bool
    @Binding var kind: DownloadsView.Kind

    func body(content: Content) -> some View {
        if shown {
            #if os(macOS)
            content.toolbar {
                ToolbarItem(placement: .principal) { picker.fixedSize() }
            }
            #elseif os(tvOS)
            content.safeAreaInset(edge: .top, spacing: 0) {
                GlassGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        Chip(title: L10n.text("Videos"), selected: kind == .videos) { kind = .videos }
                        Chip(title: L10n.text("Music"), selected: kind == .music) { kind = .music }
                    }
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Layout.gutter)
                .background(TVStyle.background)
                .focusSection()
            }
            #else
            content.topBar {
                picker
                    .frame(maxWidth: 320)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Layout.gutter).padding(.vertical, 8)
            }
            #endif
        } else {
            content
        }
    }

    private var picker: some View {
        Picker(L10n.text("Downloads"), selection: $kind) {
            Text(L10n.text("Videos")).tag(DownloadsView.Kind.videos)
            Text(L10n.text("Music")).tag(DownloadsView.Kind.music)
        }
        .pickerStyle(.segmented).labelsHidden()
    }
}

enum DownloadMetrics {
    #if os(tvOS)
    static let thumb: CGFloat = 96, showPoster: CGFloat = 170, episodeMin: CGFloat = 440, rowSpacing: CGFloat = 20
    #elseif os(macOS)
    static let thumb: CGFloat = 44, showPoster: CGFloat = 96, episodeMin: CGFloat = 260, rowSpacing: CGFloat = 10
    #else
    static let thumb: CGFloat = 46, showPoster: CGFloat = 84, episodeMin: CGFloat = 220, rowSpacing: CGFloat = 10
    #endif
}

/// Finished episodes of one video from one source.
struct DownloadShow: Identifiable {
    let id: String
    let title: String
    let poster: URL?
    let posterHeaders: [String: String]
    let sourceName: String
    let items: [DownloadItem]
    var size: Int64 { items.reduce(0) { $0 + $1.size } }
    /// Most recently finished first; episodes in the order the source lists them.
    static func group(_ items: [DownloadItem]) -> [DownloadShow] {
        let groups = Dictionary(grouping: items) { $0.source.siteKey + "\u{1F}" + $0.source.videoID }
        return groups.map { key, items in
            let first = items[0]
            return DownloadShow(id: key, title: first.title, poster: first.poster, posterHeaders: first.posterHeaders,
                                sourceName: first.source.siteName,
                                items: items.sorted { $0.episode.localizedStandardCompare($1.episode) == .orderedAscending })
        }
        .sorted { ($0.items.compactMap(\.finished).max() ?? .distantPast) > ($1.items.compactMap(\.finished).max() ?? .distantPast) }
    }
}

enum DownloadFormat {
    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file) }
    static func rate(_ bytes: Double) -> String { L10n.text("%@/s", size(Int64(bytes))) }
    static func remaining(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : seconds >= 60 ? [.minute] : [.second]
        formatter.maximumUnitCount = 2
        return L10n.text("%@ left", formatter.string(from: max(1, seconds)) ?? "")
    }
}

/// The page before anything is downloaded: what the page is for, the way to start, and the room there is.
private struct EmptyDownloads: View {
    let available: Int64?
    let browse: () -> Void
    var body: some View {
        // One 的空态文案：「暂无下载内容」+「点一下直接播放，不用联网。」
        // 第二句比原来那句「去详情页点下载」多给了**为什么值得下** ——
        // 空态页是用户第一次来到这个 tab 的地方，只教操作不解释价值，
        // 大多数人都不会去点。两句都保留。
        EmptyPage(symbol: "arrow.down", title: L10n.text("No Downloads"),
                  message: L10n.text("Choose Download on a video's page to save episodes for watching offline. Tap one to play it straight away, no network needed."),
                  action: L10n.text("Browse Sources"), actionSymbol: AppSection.sites.icon, perform: browse) {
            if let available {
                Label(L10n.text("%@ available on this device", DownloadFormat.size(available)), systemImage: "internaldrive")
            }
        }
    }
}

/// Space used by downloads against the rest of the device, as one bar.
private struct StorageCard: View {
    let usage: DownloadLibrary.Usage
    /// Downloaded songs, kept apart from the episodes.
    var songs: Int64 = 0
    var body: some View {
        let downloads = usage.downloads + songs
        let capacity = usage.capacity ?? 0
        let free = usage.available ?? 0
        let other = max(0, capacity - free - downloads)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "internaldrive.fill").foregroundStyle(Brand.accent).accessibilityHidden(true)
                Text(L10n.text("Storage")).font(.headline)
                Spacer(minLength: 8)
                if usage.available != nil {
                    Text(L10n.text("%@ free", DownloadFormat.size(free))).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(DownloadFormat.size(downloads)).font(.system(.title, design: .rounded).weight(.bold)).monospacedDigit()
                Text(L10n.text("used by downloads")).font(.subheadline).foregroundStyle(.secondary)
            }
            if capacity > 0 {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let share = { (bytes: Int64) in width * CGFloat(Double(bytes) / Double(capacity)) }
                    HStack(spacing: 2) {
                        Rectangle().fill(Brand.cyan).frame(width: downloads > 0 ? max(4, share(downloads)) : 0)
                        Rectangle().fill(Color.primary.opacity(0.28)).frame(width: share(other))
                        Rectangle().fill(Color.primary.opacity(0.08))
                    }
                    .clipShape(Capsule())
                }
                .frame(height: DownloadMetrics.thumb > 60 ? 16 : 10)
                .accessibilityHidden(true)
                HStack(spacing: 18) {
                    legend(Brand.cyan, L10n.text("Downloads"), downloads)
                    legend(Color.primary.opacity(0.28), L10n.text("Other"), other)
                    legend(Color.primary.opacity(0.12), L10n.text("Free"), free)
                }
                .font(.caption)
            }
            #if os(tvOS)
            Text(L10n.text("tvOS may remove downloads when Apple TV runs low on storage.")).font(.caption).foregroundStyle(.secondary)
            #endif
        }
        .padding(DownloadMetrics.thumb > 60 ? 28 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.06)) }
        .accessibilityElement(children: .combine)
        #if os(tvOS)
        // Focusable so the remote can scroll back up to it.
        .focusable()
        #endif
    }
    private func legend(_ color: Color, _ title: String, _ bytes: Int64) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).foregroundStyle(.secondary)
            Text(DownloadFormat.size(bytes)).monospacedDigit()
        }.lineLimit(1)
    }
}

/// A download in the queue: progress, speed and its controls.
/// The three knobs the download engine reads, in one menu: how many files download at once, how many
/// connections each file opens, and how many megabytes each connection asks for.
///
/// They are one control rather than three because they only make sense together: the sockets a download
/// opens is files × connections, and the label says that product so the setting is not a guess.
private struct SpeedMenu: View {
    /// Drops the icon and says only the numbers, for the Mac's header line.
    let compact: Bool
    private var settings: DownloadSettings { .shared }
    private var tuning: DownloadTuning { settings.tuning }

    var body: some View {
        Menu {
            Section(L10n.text("Files at Once")) {
                Picker(L10n.text("Files at Once"), selection: Binding(get: { tuning.parallel },
                                                                    set: { settings.set(parallel: $0) })) {
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.inline).labelsHidden()
            }
            Section(L10n.text("Connections per File")) {
                Picker(L10n.text("Connections per File"), selection: Binding(get: { tuning.connections },
                                                                         set: { settings.set(connections: $0) })) {
                    ForEach([1, 2, 4, 6, 8, 12, 16], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.inline).labelsHidden()
            }
            Section(L10n.text("Each Range")) {
                Picker(L10n.text("Each Range"), selection: Binding(get: { tuning.chunkMB },
                                                                  set: { settings.set(chunkMB: $0) })) {
                    ForEach([1, 2, 4, 8, 16], id: \.self) { Text("\($0) MB").tag($0) }
                }
                .pickerStyle(.inline).labelsHidden()
            }
            Divider()
            Text(L10n.text("%lld connections at most", tuning.sockets))
            Text(L10n.text("A link that throttles each connection goes faster the more there are. Past what the server allows, the extra ones only wait."))
                .font(.caption)
            // One 的两条说明，逐字对应它设置页里的文案：
            // 「连接数：所有下载任务加起来最多用这么多条，不是每个任务各用这么多条」
            // 与「只跑一个任务 / 同时跑几个任务」的分配规则。此前只有一行
            // 「N connections at most」，用户无法从界面判断到底是「每个文件 N 条」
            // 还是「全局 N 条」—— 这正是 One 用整段文案解释的那件事。
            Text(L10n.text("The pool is shared by every download, not one pool each: one task at a time takes all of them; several tasks split what is left, and a running task keeps its share until you pause and resume it."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("Changes apply to the next download."))
                .font(.caption2).foregroundStyle(.tertiary)

            Divider()

            // 「下载时保持屏幕常亮」（One 同名开关）。放在这一组里，与三个连接参数并排：
            // 它们都只影响「下载能不能跑完」，用户调它们时是同一个动机。
            Toggle(isOn: Binding(get: { settings.keepScreenAwake },
                                 set: { settings.keepScreenAwake = $0 })) {
                Label(L10n.text("Keep the Screen Awake While Downloading"), systemImage: "sun.max")
            }
            Text(L10n.text("Leave the app open while downloading: in the background the system gives it only a short time. Progress is saved, and it carries on when you come back."))
                .font(.caption).foregroundStyle(.secondary)
        } label: {
            label
        }
        #if os(macOS)
        .menuStyle(.button).buttonStyle(.borderless)
        #else
        .controlButton()
        #endif
        .accessibilityLabel(L10n.text("Download Speed"))
        .help(L10n.text("How many files download at once, and how many connections each one opens."))
    }

    @ViewBuilder private var label: some View {
        let text = L10n.text("%lld at a time · %lld each", tuning.parallel, tuning.connections)
        if compact {
            Text(text).lineLimit(1).fixedSize()
        } else {
            Label(text, systemImage: "square.stack.3d.down.right").lineLimit(1).fixedSize()
        }
    }
}

private struct QueueRow: View {
    let item: DownloadItem
    let rate: Double?
    let position: Int?
    private var library: DownloadLibrary { .shared }
    var body: some View {
        #if os(macOS)
        macRow.contextMenu { menu }
        #else
        regularRow.contextMenu { menu }
        #endif
    }

    @ViewBuilder private var menu: some View {
        if item.status == .queued, (position ?? 1) > 1 {
            Button(L10n.text("Download Next"), systemImage: "arrow.up.to.line") { library.prioritize(item.id) }
        }
        Button(L10n.text("Cancel Download"), systemImage: "xmark", role: .destructive) { library.remove([item.id]) }
    }

    #if os(macOS)
    /// A row of the grouped queue, as in Safari's downloads: the title, then the episode and quality, a thin bar,
    /// the numbers, and small round controls.
    private var macRow: some View {
        let detail = [item.episode == item.title ? nil : item.episode, item.quality].compactMap { $0?.isEmpty == false ? $0 : nil }
        let tint = item.status == .failed ? Brand.rose : item.status == .paused || item.status == .queued ? Color.secondary : Brand.accent
        return HStack(spacing: 14) {
            Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: 40)
                .overlay { PosterImage(url: item.poster, headers: item.posterHeaders) }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.1)) }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.body.weight(.semibold)).lineLimit(1).help(item.title)
                if !detail.isEmpty {
                    Text(detail.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                GeometryReader { proxy in
                    Capsule().fill(Color.primary.opacity(0.1))
                        .overlay(alignment: .leading) {
                            Capsule().fill(tint).frame(width: max(item.fraction > 0 ? 4 : 0, proxy.size.width * item.fraction))
                        }
                }
                .frame(height: 4).padding(.vertical, 2)
                .animation(.smooth, value: item.fraction)
                .accessibilityHidden(true)
                Text(status(compact: false)).font(.caption).monospacedDigit().lineLimit(1)
                    .foregroundStyle(item.status == .failed ? AnyShapeStyle(Brand.rose) : AnyShapeStyle(.secondary))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                switch item.status {
                case .paused, .failed:
                    roundControl(item.status == .failed ? "arrow.clockwise.circle.fill" : "play.circle.fill",
                                 L10n.text(item.status == .failed ? "Retry" : "Resume")) { library.resume(item.id) }
                case .finishing, .queued: EmptyView()
                default:
                    roundControl("pause.circle.fill", L10n.text("Pause")) { library.pause(item.id) }
                }
                roundControl("xmark.circle.fill", L10n.text("Cancel Download")) { library.remove([item.id]) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func roundControl(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 22)).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
    #endif

    private var regularRow: some View {
        HStack(spacing: 14) {
            Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: DownloadMetrics.thumb)
                .overlay { PosterImage(url: item.poster, headers: item.posterHeaders) }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title).font(.headline).lineLimit(1)
                    Text(item.episode).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    if let quality = item.quality { Pill(text: quality) }
                }
                ProgressView(value: item.fraction)
                    .tint(item.status == .failed ? Brand.rose : item.status == .paused ? Color.secondary : Brand.accent)
                // One line: drop the byte counts when the full status doesn't fit (phones).
                ViewThatFits(in: .horizontal) {
                    Text(status(compact: false)).fixedSize()
                    Text(status(compact: true)).lineLimit(item.status == .failed ? 2 : 1)
                }
                .font(.caption).monospacedDigit()
                .foregroundStyle(item.status == .failed ? AnyShapeStyle(Brand.rose) : AnyShapeStyle(.secondary))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                switch item.status {
                case .paused, .failed:
                    control(item.status == .failed ? "arrow.clockwise" : "play.fill", L10n.text(item.status == .failed ? "Retry" : "Resume")) { library.resume(item.id) }
                case .finishing: EmptyView()
                default:
                    control("pause.fill", L10n.text("Pause")) { library.pause(item.id) }
                }
                control("xmark", L10n.text("Cancel Download")) { library.remove([item.id]) }
            }
        }
        .padding(DownloadMetrics.thumb > 60 ? 18 : 12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func status(compact: Bool) -> String {
        let percent = Int((item.fraction * 100).rounded(.down))
        let amount = item.expected.map { L10n.text("%@ of %@", DownloadFormat.size(item.received), DownloadFormat.size($0)) }
            ?? DownloadFormat.size(item.received)
        switch item.status {
        case .queued:
            return position.map { L10n.text("Waiting · #%lld in queue", $0) } ?? L10n.text("Waiting")
        case .downloading:
            guard item.kind != nil else { return L10n.text("Getting the video link…") }
            var parts = compact ? ["\(percent)%"] : ["\(percent)%", amount]
            if let rate, rate > 1024 {
                parts.append(DownloadFormat.rate(rate))
                if let expected = item.expected, expected > item.received { parts.append(DownloadFormat.remaining(Double(expected - item.received) / rate)) }
            }
            // The socket count is what makes the rate legible: the same speed from 1 connection and
            // from 8 mean different things about the link, and only one of them has headroom left.
            if item.connections > 1 { parts.append(L10n.text("%lld connections", item.connections)) }
            return parts.joined(separator: " · ")
        case .finishing: return L10n.text("Finishing…")
        case .paused: return L10n.text("Paused") + " · \(percent)%" + (compact ? "" : " · " + amount)
        case .failed: return item.failure ?? L10n.text("Download failed")
        case .completed: return ""
        }
    }

    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: DownloadMetrics.thumb > 60 ? 24 : 13, weight: .semibold)).frame(width: DownloadMetrics.thumb > 60 ? 32 : 18)
        }
        .controlButton()
        .accessibilityLabel(label)
        .help(label)
    }
}

/// One video's downloaded episodes.
private struct ShowPanel: View {
    let show: DownloadShow
    let play: (DownloadItem) -> Void
    let delete: () -> Void
    private var library: DownloadLibrary { .shared }
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: DownloadMetrics.showPoster)
                .overlay { PosterImage(url: show.poster, headers: show.posterHeaders) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(show.title).font(.headline).lineLimit(2)
                    Text([SourceLabel(show.sourceName).text, show.items.count == 1 ? L10n.text("1 episode") : L10n.text("%lld episodes", show.items.count), DownloadFormat.size(show.size)].joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                EpisodeGrid(minimum: DownloadMetrics.episodeMin, spacing: 8, rowSpacing: DownloadMetrics.thumb > 60 ? 12 : 4).callAsFunction {
                    ForEach(show.items) { item in episode(item) }
                }
                .tvFocusSection()
                Button(role: .destructive, action: delete) {
                    Label(L10n.text("Delete Downloads"), systemImage: "trash").font(.subheadline)
                }
                .controlButton()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DownloadMetrics.thumb > 60 ? 22 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func episode(_ item: DownloadItem) -> some View {
        Button { play(item) } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.fill").font(.system(size: DownloadMetrics.thumb > 60 ? 18 : 10)).foregroundStyle(.secondary)
                Text(item.episode).lineLimit(1)
                Spacer(minLength: 8)
                if let quality = item.quality { Text(quality).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                Text(DownloadFormat.size(item.size)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            #if !os(tvOS)
            .padding(.horizontal, 10).frame(minHeight: 34)
            #endif
            .frame(maxWidth: .infinity, alignment: .leading)
            #if !os(tvOS)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            #endif
            .contentShape(Rectangle())
        }
        .glassRow()
        .accessibilityLabel(L10n.text("Play %@", item.episode))
        .contextMenu {
            #if os(macOS)
            if let file = library.file(for: item) {
                Button(L10n.text("Show in Finder"), systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
            #endif
            Button(L10n.text("Delete Download"), systemImage: "trash", role: .destructive) { library.remove([item.id]) }
        }
    }
}

/// LazyVGrid's adaptive columns, built all at once, for the same reason as the list of shows: a lazy grid below
/// the screen has no episodes yet for the remote to move to.
private struct EpisodeGrid: SwiftUI.Layout {
    let minimum: CGFloat
    let spacing: CGFloat
    let rowSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // SwiftUI can ask for the size at an unbounded width (.infinity), not only an unspecified one; Int(_:)
        // in columns(_:) traps on that (TestFlight crash on iPad, build 44, opening Downloads).
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimum
        let rows = rows(subviews, width: width)
        return CGSize(width: width, height: rows.reduce(0) { $0 + $1.height } + rowSpacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cell = cellWidth(bounds.width)
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            for (column, index) in row.indices.enumerated() {
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (cell + spacing), y: y),
                                      proposal: ProposedViewSize(width: cell, height: row.height))
            }
            y += row.height + rowSpacing
        }
    }

    private func columns(_ width: CGFloat) -> Int { max(1, Int((width + spacing) / (minimum + spacing))) }
    private func cellWidth(_ width: CGFloat) -> CGFloat {
        let count = CGFloat(columns(width))
        return max(0, (width - spacing * (count - 1)) / count)
    }
    private func rows(_ subviews: Subviews, width: CGFloat) -> [(indices: Range<Int>, height: CGFloat)] {
        let count = columns(width), cell = ProposedViewSize(width: cellWidth(width), height: nil)
        return stride(from: 0, to: subviews.count, by: count).map { start in
            let indices = start..<min(start + count, subviews.count)
            return (indices, indices.map { subviews[$0].sizeThatFits(cell).height }.max() ?? 0)
        }
    }
}

/// A downloaded episode's mark on a short episode chip.
struct DownloadedBadge: View {
    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: DownloadMetrics.thumb > 60 ? 22 : 12, weight: .semibold))
            .foregroundStyle(Brand.onAccent, Brand.accent)
            .offset(x: 4, y: -4)
            .accessibilityLabel(L10n.text("Downloaded"))
    }
}

/// A download's state beside an episode name: downloaded, progress, waiting or failed.
struct DownloadState: View {
    let status: DownloadItem.Status
    let fraction: Double
    init(item: DownloadItem) { status = item.status; fraction = item.fraction }
    init(status: DownloadItem.Status, fraction: Double) { self.status = status; self.fraction = fraction }
    static var size: CGFloat { DownloadMetrics.thumb > 60 ? 24 : 13 }
    var body: some View {
        let size = Self.size
        Group {
            switch status {
            case .completed:
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Brand.accent).accessibilityLabel(L10n.text("Downloaded"))
            case .failed:
                Image(systemName: "exclamationmark.circle").foregroundStyle(Brand.rose).accessibilityLabel(L10n.text("Download failed"))
            case .downloading, .finishing:
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2)
                    Circle().trim(from: 0, to: max(0.03, fraction)).stroke(Brand.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: size, height: size)
                .accessibilityLabel(L10n.text("Downloading"))
            case .queued, .paused:
                Image(systemName: "arrow.down.circle").foregroundStyle(.secondary).accessibilityLabel(L10n.text("In Queue"))
            }
        }
        .font(.system(size: size))
        .animation(.smooth, value: fraction)
    }
}

/// Picks episodes of the current line to download.
struct DownloadPicker: View {
    let video: Video
    let site: Site
    let flag: String
    let episodes: [Episode]
    var origin: URL? = nil
    /// 播放页是 One 皮肤（黑底）时传 true：抽屉也用深色，否则系统浅色材质会把
    /// 文字和按钮压成一片灰（实测「可用 3.23 TB」几乎看不见）。
    var dark: Bool = false
    /// 宽屏（Duo 展开 / iPad）直接满高，与选集抽屉一致；窄屏先半屏。
    var startsLarge: Bool = false
    /// 打开时预先勾上的集。One 的 `EpisodeCard` 自带下载钮，点哪一集就只下那一集 ——
    /// 抽屉打开时那颗不该让用户再选一次。`nil` 时保持原来「全不选」的行为。
    var preselect: Set<String> = []
    var added: (Int) -> Void = { _ in }
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: Set<String> = []
    /// 与选集抽屉同一套高度：窄屏先给半屏，宽屏（Duo 展开）直接给满高。
    @State private var detent: PresentationDetent = .medium
    private var library: DownloadLibrary { .shared }
    private func source(_ episode: Episode) -> DownloadSource { DownloadSource(site: site, videoID: video.id, episode: episode, origin: origin) }
    /// 本环境下还能下的集：本环境没有记录，或本环境那条失败了。
    ///
    /// 必须走 `visibleItem`。用 `item(for:)` 会把另一个环境下过的同一集算成本环境也已下，
    /// 于是这一集在这里被锁成「Downloaded」、连勾都勾不上 —— 从一个空环境导入同一订阅后
    /// 整部剧一集也下不下来。
    private var available: [Episode] { episodes.filter { library.visibleItem(for: source($0)).map { $0.status == .failed } ?? true } }
    #if os(macOS)
    /// The checklist's natural height, so the sheet fits a few episodes instead of a fixed, mostly empty box.
    @State private var listHeight: CGFloat = 0
    var body: some View { macBody.task { await library.measure() } }
    #else
    var body: some View { regularBody }

    private var regularBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: DownloadMetrics.thumb * 1.2)
                    .overlay { PosterImage(url: video.poster, headers: video.posterHeaders) }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Download Episodes")).font(.title2.weight(.bold))
                    Text(video.name).font(.headline).lineLimit(2)
                    if !flag.isEmpty { Text(SourceLabel(flag).text).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                let all = !available.isEmpty && available.allSatisfy { selection.contains($0.id) }
                Button { selection = all ? [] : Set(available.map(\.id)) } label: {
                    Label(L10n.text(all ? "Deselect All" : "Select All"), systemImage: all ? "circle" : "checkmark.circle")
                }
                .controlButton().disabled(available.isEmpty)
                Spacer(minLength: 8)
                if let free = library.usage.available {
                    Text(L10n.text("%@ free", DownloadFormat.size(free))).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .tvFocusSection()
            ScrollView {
                // One column of glass rows on the TV, as in the danmaku list; a compact grid elsewhere.
                LazyVGrid(columns: Self.columns, spacing: DownloadMetrics.thumb > 60 ? 4 : 8) {
                    ForEach(episodes) { episode in row(episode) }
                }
                .padding(.vertical, 4)
                .glassRowInsets()
            }
            #if os(tvOS)
            // Let the insets reach into the page margin, so the rows' glass lines up with the header.
            .padding(.horizontal, -40)
            #endif
            .tvFocusSection()
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(L10n.text("Cancel")) { dismiss() }.controlButton()
                downloadButton
            }
            // A full-width focus section: the buttons sit at the right, out of line with most episodes,
            // and the remote only finds them moving down when the whole row takes focus.
            .tvFocusSection()
        }
        .padding(DownloadMetrics.thumb > 60 ? 60 : 22)
        #if os(iOS)
        // 与选集抽屉一致：同一组档位、同样的拖拽指示条、同样的底色。
        // 下载抽屉以前没有自己的底色，iOS 26 的液态玻璃会透出播放页的海报，
        // 于是同一个页面里「选集是黑的、下载是浅灰的」，按钮也跟着发灰。
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(dark ? AnyShapeStyle(Color(white: 0.07)) : AnyShapeStyle(.regularMaterial))
        .preferredColorScheme(dark ? .dark : nil)
        .environment(\.glassControls, true)
        .onAppear {
            if startsLarge || sizeClass == .regular { detent = .large }
            // 单集下载入口预选的集；只留 `available` 里还存在的（已下完/在下的不再勾）。
            if !preselect.isEmpty {
                selection = preselect.intersection(Set(available.map(\.id)))
            }
        }
        #else
        .frame(maxWidth: 1300).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Backdrop() }
        #endif
        .task { await library.measure() }
    }
    #endif

    private var downloadButton: some View {
        Button {
            let chosen = episodes.filter { selection.contains($0.id) }
            for episode in chosen { library.download(source(episode), title: video.name, poster: video.poster, posterHeaders: video.posterHeaders, environmentID: store.environments.activeID) }
            added(chosen.count)
            dismiss()
        } label: {
            Label(selection.isEmpty ? L10n.text("Download") : L10n.text("Download %lld", selection.count), systemImage: "arrow.down.circle.fill")
        }
        .controlButton(prominent: true).disabled(selection.isEmpty)
    }

    #if os(macOS)
    /// A compact header, the episodes as a checklist that grows with them up to a scrolling height, and a footer
    /// with Select All beside Cancel and Download (Esc and Return).
    private var macBody: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: 44)
                    .overlay { PosterImage(url: video.poster, headers: video.posterHeaders) }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1)) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Download Episodes")).font(.title3.weight(.semibold))
                    Text(video.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(macSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            Divider()
            ScrollView {
                macChecklist
                    .padding(16)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(listHeight, 56), 380))
            Divider()
            HStack(spacing: 10) {
                Toggle(L10n.text("Select All"), isOn: Binding(
                    get: { !available.isEmpty && available.allSatisfy { selection.contains($0.id) } },
                    set: { selection = $0 ? Set(available.map(\.id)) : [] }))
                .toggleStyle(.checkbox)
                .disabled(available.isEmpty)
                if let free = library.usage.available {
                    Text(L10n.text("%@ free", DownloadFormat.size(free))).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                }
                Spacer(minLength: 12)
                // Liquid Glass, as the sheet's own surface is.
                Button(L10n.text("Cancel")) { dismiss() }.controlButton().keyboardShortcut(.cancelAction)
                downloadButton.keyboardShortcut(.defaultAction)
            }
            .environment(\.glassControls, true)
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 540)
    }

    /// The line's name and how many episodes it has.
    private var macSubtitle: String {
        let count = episodes.count == 1 ? L10n.text("1 episode") : L10n.text("%lld episodes", episodes.count)
        return flag.isEmpty ? count : SourceLabel(flag).text + " · " + count
    }

    /// Short names (第1集, EP01) as a grid of chips; long ones (a film's full title) as a list, one per row.
    @ViewBuilder private var macChecklist: some View {
        if episodes.allSatisfy({ $0.name.count <= 10 }) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                ForEach(episodes) { episode in macChip(episode) }
            }
        } else {
            VStack(spacing: 0) {
                ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                    if index > 0 { Divider().padding(.leading, 40) }
                    macRow(episode)
                }
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)) }
        }
    }

    private func macRow(_ episode: Episode) -> some View {
        let existing = library.visibleItem(for: source(episode))
        let locked = existing.map { $0.status != .failed } ?? false
        let selected = selection.contains(episode.id)
        return Button { toggle(episode) } label: {
            HStack(spacing: 10) {
                checkmark(selected: selected, locked: locked)
                Text(episode.name).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(locked ? .secondary : .primary)
                Spacer(minLength: 8)
                if let existing, locked { stateLabel(existing) }
            }
            .padding(.horizontal, 12).frame(minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .help(episode.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func macChip(_ episode: Episode) -> some View {
        let existing = library.visibleItem(for: source(episode))
        let locked = existing.map { $0.status != .failed } ?? false
        let selected = selection.contains(episode.id)
        return Button { toggle(episode) } label: {
            HStack(spacing: 6) {
                checkmark(selected: selected, locked: locked)
                Text(episode.name).lineLimit(1).foregroundStyle(locked ? .secondary : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(selected ? Brand.accent.opacity(0.16) : Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Brand.accent.opacity(0.5) : Color.primary.opacity(0.06))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .help(existing.flatMap { locked ? ($0.status == .completed ? L10n.text("Downloaded") : L10n.text("In Queue")) : nil } ?? episode.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Downloaded or queued episodes show the download mark instead of a box to tick.
    private func checkmark(selected: Bool, locked: Bool) -> some View {
        Image(systemName: locked ? "arrow.down.circle.fill" : selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 15))
            .foregroundStyle(locked ? AnyShapeStyle(.tertiary) : selected ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.tertiary))
            .frame(width: 18)
    }

    private func stateLabel(_ item: DownloadItem) -> some View {
        Text(item.status == .completed ? L10n.text("Downloaded") : L10n.text("In Queue"))
            .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
    }

    private func toggle(_ episode: Episode) {
        if selection.contains(episode.id) { selection.remove(episode.id) } else { selection.insert(episode.id) }
    }
    #endif

    private static var columns: [GridItem] {
        #if os(tvOS)
        [GridItem(.flexible())]
        #else
        [GridItem(.adaptive(minimum: 220), spacing: 8)]
        #endif
    }

    private func row(_ episode: Episode) -> some View {
        let existing = library.visibleItem(for: source(episode))
        let locked = existing.map { $0.status != .failed } ?? false
        let selected = selection.contains(episode.id)
        return Button {
            if selected { selection.remove(episode.id) } else { selection.insert(episode.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: locked ? "checkmark.circle.fill" : selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(locked ? AnyShapeStyle(.tertiary) : selected ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.secondary))
                Text(episode.name).lineLimit(1)
                Spacer(minLength: 6)
                if let existing, locked {
                    Text(existing.status == .completed ? L10n.text("Downloaded") : L10n.text("In Queue")).font(.caption).foregroundStyle(.secondary)
                }
            }
            #if !os(tvOS)
            .padding(.horizontal, 10).frame(minHeight: 36)
            #endif
            .frame(maxWidth: .infinity, alignment: .leading)
            #if !os(tvOS)
            .background(Color.primary.opacity(selected ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            #endif
            .contentShape(Rectangle())
        }
        .glassRow()
        .disabled(locked)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

extension View {
    /// A sheet, or on tvOS a full-screen page: tvOS sheets are small and let the page show through.
    @ViewBuilder func downloadPicker<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(tvOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }
}

/// Downloads keep going after the app leaves the screen. On iOS 26 and later a continued-processing task keeps
/// them running until the queue is empty (see `ContinuedDownloads`). Otherwise, or when the system ends that task,
/// they get the usual short grace period, then stop and resume when the app returns.
@MainActor enum DownloadsLifecycle {
    #if !os(macOS)
    private static var task: UIBackgroundTaskIdentifier = .invalid
    static func install() {
        #if os(iOS)
        DownloadLibrary.shared.onStart = { started() }
        MusicDownloadLibrary.shared.onStart = { started() }
        // 开关一改立刻生效：关掉时若队列还在跑，`applyScreenAwake()` 会立刻放开锁屏；
        // 打开时同理立刻压住。不等下一次 start。
        DownloadSettings.shared.onKeepAwakeChange = { _ in applyScreenAwake() }
        // 队列由跑到空时**必须**回一次这里，否则压住自动锁屏的那次调用永远不会撤销。
        DownloadLibrary.shared.onActivityChange = { _ in queueChanged() }
        MusicDownloadLibrary.shared.onActivityChange = { _ in queueChanged() }
        #endif
    }
    static func enteredBackground() {
        guard hasWork, task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "Downloads") {
            if !continuing { suspend() }
            end()
        }
    }
    static func becameActive() {
        end()
        DownloadLibrary.shared.wake()
        MusicDownloadLibrary.shared.wake()
        started()
    }
    /// The queue emptied, or everything was paused or removed: let the screen sleep again.
    ///
    /// 与 `started()` 成对。`schedule()` 每次跑完都会回到这里（`running.isEmpty` 时）
    /// 或继续跑（有活时），所以这是一个「队列真实状态」的采样点，
    /// 不是「某个按钮按了」的猜测 —— 漏消息也不会把屏幕常亮留在 true。
    static func queueChanged() { applyScreenAwake() }
    static var hasWork: Bool {
        DownloadLibrary.shared.items.contains(where: \.isActive) || MusicDownloadLibrary.shared.items.contains(where: \.isActive)
    }
    private static func suspend() {
        DownloadLibrary.shared.suspend()
        MusicDownloadLibrary.shared.suspend()
    }
    private static func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
    /// A download started or the app came back: ask for a continued-processing task while the app is open.
    private static func started() {
        #if os(iOS)
        if #available(iOS 26.0, *) { ContinuedDownloads.begin() }
        applyScreenAwake()
        #endif
    }

    /// 「下载时保持屏幕常亮」（One 的同名开关）。
    ///
    /// 挂在队列活动状态上而不是挂在下载页上：下载页可以关掉、可以切到别的 tab，
    /// 但任务还在跑时锁屏会立刻把下载掐掉。判据与 `hasWork` 同一个 ——
    /// 有任务在跑就压住自动锁屏，队列空了立刻放开，绝不长期占用。
    ///
    /// 只碰 `isIdleTimerDisabled`，不与阅读器的同名设置冲突：那边只在阅读页
    /// onAppear/onDisappear 里改，两者都遵循「进入时置位、离开时复位」，
    /// 而这里的判据是队列状态，队列空了不会留下 true。
    static func applyScreenAwake() {
        #if os(iOS)
        let wanted = DownloadSettings.shared.keepScreenAwake && hasWork
        if UIApplication.shared.isIdleTimerDisabled != wanted {
            UIApplication.shared.isIdleTimerDisabled = wanted
        }
        #endif
    }
    private static var continuing: Bool {
        #if os(iOS)
        if #available(iOS 26.0, *) { return ContinuedDownloads.isRunning }
        #endif
        return false
    }
    /// The continued-processing task ended: the queue emptied, or the system (or the person, from its progress)
    /// stopped it. Off screen, stop as the grace period's end would.
    static func continuedEnded(expired: Bool) {
        guard UIApplication.shared.applicationState != .active else { return }
        if expired { suspend() }
        end()
    }
    #endif
}

#if os(iOS)
/// iOS 26 lets an app keep work a person started running in the background, as a continued-processing task whose
/// progress the system shows on the Lock Screen and in the Dynamic Island. The task can only be asked for while the
/// app is open, so it starts with the first download and follows every download (videos and songs) until the queue
/// is empty. When the system ends it early, the downloads stop as before and carry on when the app comes back.
@available(iOS 26.0, *)
@MainActor enum ContinuedDownloads {
    private static var task: BGContinuedProcessingTask?
    /// When a request was submitted and its task hasn't started yet.
    private static var submitted: Date?
    /// Downloads this task has followed, for its progress: finished, paused or removed ones count as done.
    private static var followed: Set<String> = []
    private static var subtitle = ""
    private static var follower: Task<Void, Never>?

    static var isRunning: Bool { task != nil }

    static func begin() {
        guard task == nil, submitted.map({ Date().timeIntervalSince($0) > 10 }) ?? true,
              UIApplication.shared.applicationState == .active, let name = current() else { return }
        let identifier = "\(Bundle.main.bundleIdentifier ?? "com.tvbox.yingxia").downloads.\(UUID().uuidString)"
        // Each request has its own identifier, registered just before it is submitted (allowed for this kind of task).
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated { run(task) }
        }
        guard registered else {
            Diagnostics.shared.record(.warning, "download", "continued task not permitted")
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: L10n.text("Downloading"), subtitle: name)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            submitted = Date()
        } catch {
            Diagnostics.shared.record(.warning, "download", "continued task refused \(error)")
        }
    }

    private static func run(_ started: BGTask) {
        submitted = nil
        guard let started = started as? BGContinuedProcessingTask else { started.setTaskCompleted(success: false); return }
        guard task == nil, let name = current() else { started.setTaskCompleted(success: true); return }
        task = started
        followed = []
        subtitle = name
        started.expirationHandler = { Task { @MainActor in expire() } }
        Diagnostics.shared.record(.info, "download", "continued task started")
        follower = Task {
            while !Task.isCancelled, follow() {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Reports progress; false, after ending the task, once nothing is left to download.
    private static func follow() -> Bool {
        guard let task else { return false }
        var fractions: [String: Double] = [:]
        for item in DownloadLibrary.shared.items where item.status == .queued || item.isActive { fractions["v" + item.id] = item.fraction }
        for item in MusicDownloadLibrary.shared.items where item.status == .queued || item.isActive { fractions["m" + item.id] = item.fraction }
        guard !fractions.isEmpty else {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            finish(success: true)
            DownloadsLifecycle.continuedEnded(expired: false)
            return false
        }
        followed.formUnion(fractions.keys)
        let done = followed.reduce(0.0) { $0 + (fractions[$1] ?? 1) }
        task.progress.totalUnitCount = Int64(followed.count) * 1000
        task.progress.completedUnitCount = Int64(done * 1000)
        if let name = current(), name != subtitle {
            subtitle = name
            task.updateTitle(L10n.text("Downloading"), subtitle: name)
        }
        return true
    }

    private static func expire() {
        guard task != nil else { return }
        Diagnostics.shared.record(.info, "download", "continued task expired")
        finish(success: false)
        DownloadsLifecycle.continuedEnded(expired: true)
    }

    private static func finish(success: Bool) {
        follower?.cancel(); follower = nil
        task?.setTaskCompleted(success: success)
        task = nil
    }

    /// The download running now (else the next one waiting), as the progress names it.
    private static func current() -> String? {
        let videos = DownloadLibrary.shared.items, songs = MusicDownloadLibrary.shared.items
        if let item = videos.first(where: \.isActive) ?? videos.first(where: { $0.status == .queued }) {
            return item.episode.isEmpty ? item.title : "\(item.title) · \(item.episode)"
        }
        return (songs.first(where: \.isActive) ?? songs.first(where: { $0.status == .queued }))?.track.title
    }
}
#endif

// [融合补入] 上游 225 提交新增：下载文件的分享/存到相册。
// MusicDownloadsView 依赖它，缺了就编不过。


// [融合补入] 上游 225 提交新增：把下载好的文件存到「文件」或相册、AirDrop 分享。
// MusicDownloadsView 依赖它，缺了就编不过。
#if os(iOS)
/// Saves a finished download to Files or Photos, or sends it with AirDrop, through the share sheet. It hands over a
/// renamed copy (`DownloadExport`), so deleting the saved file elsewhere leaves the download in the app.
@MainActor enum DownloadSharing {
    static func share(_ file: URL, named name: String) {
        Task {
            let copy = await Task.detached { () -> Result<URL, any Error> in Result { try DownloadExport.copy(file, named: name) } }.value
            guard case .success(let copy) = copy else {
                if case .failure(let error) = copy { Diagnostics.shared.failure("download", "share copy", error) }
                // Deleted outside the app: stop listing it.
                DownloadLibrary.shared.forgetMissing()
                MusicDownloadLibrary.shared.forgetMissing()
                return
            }
            guard let scene = UIApplication.shared.appWindowScene, let window = scene.keyWindow ?? scene.windows.first else { return }
            var controller = window.rootViewController
            while let next = controller?.presentedViewController, !next.isBeingDismissed { controller = next }
            let sheet = UIActivityViewController(activityItems: [copy], applicationActivities: nil)
            sheet.completionWithItemsHandler = { @Sendable _, _, _, _ in DownloadExport.clear() }
            if let popover = sheet.popoverPresentationController {
                // iPad: a sheet in the middle of the window, as the menu that opened it is gone.
                popover.sourceView = window
                popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            controller?.present(sheet, animated: true)
        }
    }
}
#endif
