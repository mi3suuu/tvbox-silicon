//
//  EpisodePicker.swift
//  TVBox
//
//  The episode sheet the player opens straight into, ported from One's layout:
//  a compact picture at the top, the line switcher and the episode grid under it,
//  so tapping a video lands on "pick an episode" instead of a bare player.
//
//  Two behaviours the requirement calls out, both of which the previous sheet
//  did not have:
//
//  1. Reopening a video resumes the last episode at its saved position on the
//     last-used line. That state already exists — PlaybackHistoryContext records
//     `sourceKey`, `videoID` and `episodeFlag`, and PlaybackHistoryEntry keeps the
//     position — so this view only has to read it back, and fall back to episode 1
//     at 0 s when there is nothing saved.
//
//  2. Switching lines shows each line's health before committing. Readings are
//     lazy: only the lines in the visible grid get probed, one at a time, and the
//     result is cached so reopening the sheet does not re-measure everything.
//

import SwiftUI
import TVCore

// MARK: - Line health row model

/// One line of the current video, with whatever health we already know.
struct EpisodeLine: Identifiable, Hashable {
    let flag: String
    var probe: SourceProbeResult

    var id: String { flag }
}

// MARK: - Probe controller

/// Drives lazy probing for the picker. Keeps at most one probe in flight per
/// video so opening the sheet never fires a burst of requests.
@MainActor
@Observable
final class EpisodeProbeController {
    private(set) var readings: [String: SourceProbeResult] = [:]
    /// Line flag → probe host, so cooldown is queried by host (the rotator's key), not by flag.
    private var bases: [String: String] = [:]
    private var inFlight: Set<String> = []
    private let store = SourceProbeStore.shared

    func loadCached(sourceKey: String, videoID: String) {
        readings.merge(store.probes(sourceKey: sourceKey, videoID: videoID)) { current, _ in current }
    }

    /// Probes one line unless it is already known and fresh, or already running.
    func probeIfNeeded(
        line: String,
        address: String,
        headers: [String: String],
        sourceKey: String,
        videoID: String,
        force: Bool = false
    ) async {
        guard !line.isEmpty, let url = URL(string: address), !inFlight.contains(line) else { return }
        if let host = url.host { bases[line] = host }
        if !force, let known = readings[line] ?? store.probe(sourceKey: sourceKey, videoID: videoID, lineFlag: line),
           !known.isStale(), known.reachability != .unknown {
            readings[line] = known
            return
        }

        inFlight.insert(line)
        defer { inFlight.remove(line) }

        // HostRotation is keyed by host: claim it, then record success/failure/cancel on the same key.
        let base = url.host
        if let base, !store.beginBase(base) { return }

        let result = await SourceProbeRunner.probe(url: url, headers: headers)
        if Task.isCancelled {
            if let base { store.cancelBase(base) }
            return
        }
        if let base {
            switch result.reachability {
            case .reachable, .slow: store.succeedBase(base)
            case .unreachable: store.failBase(base)
            case .unknown: store.cancelBase(base)
            }
        }
        readings[line] = result
        store.record(result, sourceKey: sourceKey, videoID: videoID, lineFlag: line)
    }

    func reading(for line: String) -> SourceProbeResult? { readings[line] }

    /// Seconds until `line` may be tried again, or nil when it may be tried now.
    func cooldownRemaining(for line: String, now: Date = Date()) -> TimeInterval? {
        guard let base = bases[line] else { return nil }
        return store.cooldownRemaining(for: base, now: now)
    }

    /// The soonest any cooling line becomes usable, or nil when one already is.
    func soonestCooldown(now: Date = Date()) -> TimeInterval? {
        store.soonestCooldown(now: now)
    }
}

// MARK: - Picker

struct EpisodePicker: View {
    let video: Video
    let sourceKey: String
    let sourceName: String
    let origin: URL
    /// Saved context for this video, if it has ever been played.
    let resumeContext: PlaybackHistoryContext?
    /// Saved position to jump to on open, in seconds.
    let resumePosition: Double?
    /// How far the resume episode was watched, 0…1, to draw a progress bar on its cell.
    let resumeProgress: Double?
    /// The episode playing right now, so its cell can carry a "now playing" mark apart from
    /// "resume here".
    let currentEpisodeID: String?
    /// The Duo's inline shape: a compact panel inside the picture, so the header drops the big
    /// poster and the navigation bar in favour of more room for the episode grid.
    let compact: Bool
    let headers: [String: String]
    let play: @MainActor (Episode) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    @State private var state = EpisodeProbeController()
    @State private var activeLine: String
    /// 选集面板的搜索 / 筛选 / 分页。
    ///
    /// 面板可能列上千集（1282 集的剧很常见），整段 LazyVGrid 一次性铺开
    /// 既滑不准也找不到目标。这里做成「搜索 + 筛选 + 每页固定条数」。
    @State private var query = ""
    @State private var filter: PickerFilter = .all
    @State private var page = 0
    @State private var pageSize = 50
    @State private var jumping = false
    @State private var jumpDraft = ""

    enum PickerFilter: String, CaseIterable, Identifiable {
        case all, unwatched, watched
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: L10n.text("全部")
            case .unwatched: L10n.text("未看")
            case .watched: L10n.text("已看")
            }
        }
    }

    private var playlist: EpisodePlaylist { EpisodePlaylist(video.episodes) }
    /// Lines the picker shows: the full flag list minus the viewer-hidden ones. A hidden line is
    /// restored from the source's full detail, where a small button brings it back.
    private var flags: [String] { playlist.flags.filter { !store.lineSettings.isHidden(origin: origin, sourceKey: sourceKey, flag: $0) } }
    /// All flags, including hidden ones, for the "restore hidden lines" button.
    private var hiddenFlags: [String] { playlist.flags.filter { store.lineSettings.isHidden(origin: origin, sourceKey: sourceKey, flag: $0) } }

    init(
        video: Video,
        sourceKey: String,
        sourceName: String,
        origin: URL,
        resumeContext: PlaybackHistoryContext?,
        resumePosition: Double?,
        resumeProgress: Double? = nil,
        currentEpisodeID: String? = nil,
        compact: Bool = false,
        headers: [String: String],
        play: @escaping @MainActor (Episode) -> Void
    ) {
        self.video = video
        self.sourceKey = sourceKey
        self.sourceName = sourceName
        self.origin = origin
        self.resumeContext = resumeContext
        self.resumePosition = resumePosition
        self.resumeProgress = resumeProgress
        self.currentEpisodeID = currentEpisodeID
        self.compact = compact
        self.headers = headers
        self.play = play
        // Reopen on the line that was in use; fall back to the source's first.
        let saved = resumeContext?.episodeFlag
        let firstFlags = EpisodePlaylist(video.episodes).flags
        let first = firstFlags.first ?? ""
        _activeLine = State(initialValue: saved.flatMap { firstFlags.contains($0) ? $0 : nil } ?? first)
    }

    private var episodesOnActiveLine: [Episode] { playlist.episodes(for: activeLine) }

    /// 本剧「看过」的集：从逐集历史里按 scope 收一遍。
    /// 不能用单条续播点判断 —— 那只代表「上次看到哪一集」。
    private var watchedIDs: Set<String> {
        let scope = EpisodeSkipSettings.scope(origin: origin, source: sourceKey, video: video.id)
        return Set(PlaybackHistory.shared.entries.compactMap { entry in
            guard entry.context.id == scope else { return nil }
            return entry.progress > 0.02 || entry.completed ? entry.context.episodeID : nil
        })
    }

    /// 筛选 + 搜索之后的集（顺序不变）。
    ///
    /// 顺序固定：**先筛选、再搜索**。反过来会出现「搜第 12 集，但它被筛掉了」，
    /// 用户会以为集不见了。
    private var visibleEpisodes: [Episode] {
        var items = episodesOnActiveLine
        switch filter {
        case .all: break
        case .unwatched:
            let seen = watchedIDs
            items = items.filter { !seen.contains($0.id) && $0.id != currentEpisodeID }
        case .watched:
            let seen = watchedIDs
            items = items.filter { seen.contains($0.id) || $0.id == currentEpisodeID }
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        if let n = Int(q) {
            // 纯数字按集号精确匹配；没有精确命中才退回子串。
            let exact = items.filter { TMDBMatch.episodeNumber($0.name) == n }
            if !exact.isEmpty { return exact }
        }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || EpisodeRow.title($0.name).localizedCaseInsensitiveContains(q)
        }
    }

    private var pageCount: Int {
        max(1, Int(ceil(Double(visibleEpisodes.count) / Double(max(pageSize, 1)))))
    }

    /// 当前页。页码越界时夹回（换筛选/搜索后总数变小）。
    private var pagedEpisodes: [Episode] {
        let all = visibleEpisodes
        let size = max(pageSize, 1)
        let p = min(page, max(0, pageCount - 1))
        let start = min(p * size, max(0, all.count))
        let end = min(start + size, all.count)
        guard start < end else { return [] }
        return Array(all[start..<end])
    }

    /// The episode the play button should resume: the saved one when it still
    /// exists on this line, else the first.
    private var resumeEpisode: Episode? {
        if let context = resumeContext, let saved = context.episode(in: episodesOnActiveLine) { return saved }
        return episodesOnActiveLine.first
    }

    private var resumeTargetText: String? {
        guard let episode = resumeEpisode else { return nil }
        guard let position = resumePosition, position > 1 else { return episode.name }
        let pattern: Duration.TimeFormatStyle.Pattern = position >= 3600 ? .hourMinuteSecond : .minuteSecond
        return L10n.text("%@ · from %@", episode.name, Duration.seconds(Int(position)).formatted(.time(pattern: pattern)))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? Spacing.medium : Spacing.panel) {
                    if compact { compactHeader }
                    header
                    if let error = store.episodeError {
                        // The last picked episode failed to resolve. The panel stays open (the play
                        // callback only closes it on success), so surface why, right where the viewer
                        // is looking, instead of leaving a dead grid and no explanation.
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if flags.count > 1 { lineSwitcher }
                    episodeGrid
                }
                .padding(compact ? Spacing.medium : Spacing.panel)
            }
            // Transparent: the sheet shape gets the system sheet material, and the Duo's inline
            // panel gets the glass the surface host wraps it in. An opaque fill here would read as a
            // hard white board floating over the picture.
            .background(.clear)
            .navigationTitle(video.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if !compact {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.text("Close")) {
                            // In a Duo's inline shape the picker is an in-picture panel with no sheet, so the
                            // store flag is what actually closes it; the dismiss covers the sheet shape.
                            store.showsEpisodes = false
                            dismiss()
                        }
                    }
                }
            }
            #if os(iOS)
            .toolbar(compact ? .hidden : .visible, for: .navigationBar)
            #endif
        }
        .onAppear {
            // A Duo fold/unfold rebuilds the picker; restore the line the viewer had just chosen
            // (held on the store) before falling back, so the selection survives the swap. The choice
            // is scoped to this video: a flag name is shared by every video of a source, so a line
            // picked on a different video must not surface here.
            if store.episodePickerVideoID == video.id, let picked = store.episodePickerLine, flags.contains(picked) {
                activeLine = picked
            }
            // The saved/fallback line can be one the viewer hid after it was last used. If the active
            // line is no longer visible, step to the first visible line so the grid never shows a
            // hidden line's episodes with no matching chip.
            if !flags.contains(activeLine), let first = flags.first {
                activeLine = first
            }
        }
        .onChange(of: activeLine) { _, line in
            store.episodePickerVideoID = video.id
            store.episodePickerLine = line
        }
        .task(id: activeLine) {
            await loadReadings()
            await probeVisibleLines()
        }
    }

    /// The inline panel's own header row: the title and a close affordance, with no navigation bar.
    /// The big poster header below it is hidden in the compact shape too, so the line chips and the
    /// episode grid get the room.
    private var compactHeader: some View {
        HStack(spacing: 8) {
            Text(video.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 8)
            Button {
                store.showsEpisodes = false
            } label: {
                Image(systemName: "xmark").font(.footnote.weight(.semibold))
                    .frame(width: 28, height: 28)
                    #if os(tvOS)
                    .background(Color.primary.opacity(0.06), in: Circle())
                    #else
                    .glassOrFill(.regular.interactive(), Color.primary.opacity(0.06), in: Circle())
                    #endif
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Close"))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: compact ? 10 : 14) {
            poster
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                // The standard sheet shape already names the video in its visible navigation bar
                // (navigationTitle below), so the poster's own title would only repeat it. The
                // compact in-picture panel has no navigation bar, so it keeps the title here.
                if compact {
                    Text(video.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                if !compact && !video.remarks.isEmpty {
                    Text(video.remarks).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                if !compact, let target = resumeTargetText {
                    Label(target, systemImage: "play.circle")
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                        .lineLimit(2)
                }
                Button {
                    guard let episode = resumeEpisode else { return }
                    play(episode)
                } label: {
                    Label(
                        resumePosition.map { $0 > 1 } == true ? L10n.text("Continue") : L10n.text("Play"),
                        systemImage: "play.fill"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .controlButton(prominent: true)
                .tint(Brand.accent)
                .controlSize(.regular)
                .disabled(resumeEpisode == nil)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    private var poster: some View {
        let size: (CGFloat, CGFloat) = compact ? (56, 84) : (108, 162)
        return PosterImage(url: video.poster, headers: video.posterHeaders)
            .frame(width: size.0, height: size.1)
            .clipShape(RoundedRectangle(cornerRadius: compact ? Radius.medium : Radius.card, style: .continuous))
    }

    // MARK: Line switcher

    private var lineSwitcher: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(L10n.text("Source"), count: flags.count)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(flags, id: \.self) { flag in
                        lineChip(flag)
                    }
                }
            }
            if !hiddenFlags.isEmpty {
                Button {
                    store.lineSettings.restoreAll(origin: origin, sourceKey: sourceKey)
                } label: {
                    // A hidden line is hidden for every video from this source, so the label says so.
                    Label(L10n.text("Show %lld hidden lines (all videos)", hiddenFlags.count), systemImage: "eye")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
                .accessibilityIdentifier("lines.restoreHidden")
            }
            allCoolingNotice
        }
    }

    private func lineChip(_ flag: String) -> some View {
        let reading = state.reading(for: flag)
        let selected = flag == activeLine
        // A line that failed recently is not offered again until its backoff expires. Showing the
        // countdown matters more than hiding the chip: a line that silently vanished reads as a bug.
        let cooling = state.cooldownRemaining(for: flag)
        return Button {
            guard cooling == nil else { return }
            activeLine = flag
            Task { await probe(flag) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if cooling != nil {
                        Image(systemName: "clock.arrow.circlepath").font(.caption2)
                            .foregroundStyle(selected ? Brand.onAccent.opacity(0.72) : .secondary)
                    } else {
                        Circle().fill(color(for: reading)).frame(width: 8, height: 8)
                            .overlay { Circle().strokeBorder(selected ? Brand.onAccent.opacity(0.35) : .clear, lineWidth: 1.5) }
                    }
                    Text(flag.isEmpty ? L10n.text("Line 1") : flag)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Brand.onAccent : (cooling == nil ? .primary : .secondary))
                }
                Text(cooling.map { L10n.text("Retry in %@s", String(Int($0.rounded(.up)))) }
                     ?? reading?.summary() ?? L10n.text("Tap to check"))
                    .font(.caption2)
                    .foregroundStyle(selected ? Brand.onAccent.opacity(0.72) : .secondary)
                    .lineLimit(1)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(selected ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Color.primary.opacity(0.05)))
            .opacity(cooling == nil ? 1 : 0.55)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(cooling != nil)
        .contextMenu {
            // Per-line routing: this line alone can go direct or through a custom proxy, whatever its source does.
            Menu {
                Button { store.lineSettings.setRoute(nil, origin: origin, sourceKey: sourceKey, flag: flag) } label: {
                    Label(L10n.text("Follow Source"), systemImage: store.lineSettings.route(origin: origin, sourceKey: sourceKey, flag: flag) == nil ? "checkmark" : "arrow.uturn.backward")
                }
                Button { store.lineSettings.setRoute(.direct, origin: origin, sourceKey: sourceKey, flag: flag) } label: {
                    Label(L10n.text("Direct"), systemImage: store.lineSettings.route(origin: origin, sourceKey: sourceKey, flag: flag) == .direct ? "checkmark" : "bolt")
                }
                if let proxy = store.customProxy.store.endpoints.first {
                    Button { store.lineSettings.setRoute(.proxy(proxy.id), origin: origin, sourceKey: sourceKey, flag: flag) } label: {
                        Label(proxy.name, systemImage: store.lineSettings.route(origin: origin, sourceKey: sourceKey, flag: flag)?.proxyID == proxy.id ? "checkmark" : "network")
                    }
                }
            } label: {
                Label(L10n.text("Connection"), systemImage: "network")
            }
            Button(role: .destructive) {
                store.lineSettings.setHidden(true, origin: origin, sourceKey: sourceKey, flag: flag)
            } label: {
                Label(L10n.text("Hide Line"), systemImage: "eye.slash")
            }
        }
    }

    /// Shown under the switcher when every line is inside its backoff, so the list does not look
    /// broken. Wording follows One's own copy for the same situation.
    @ViewBuilder private var allCoolingNotice: some View {
        if let soonest = state.soonestCooldown() {
            Label(L10n.text("Every line is cooling down. Soonest is ready in %@s.", String(Int(soonest.rounded(.up)))),
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func color(for reading: SourceProbeResult?) -> Color {
        switch reading?.reachability {
        case .reachable: return Brand.teal
        case .slow: return Brand.amber
        case .unreachable: return Brand.rose
        case .unknown, .none: return .secondary
        }
    }

    // MARK: Episodes

    private var episodeGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 标题行带上总数与「当前显示」的数：筛选后一眼看清还剩多少。
            sectionHeader(L10n.text("Episodes"),
                          count: visibleEpisodes.count == episodesOnActiveLine.count
                              ? episodesOnActiveLine.count
                              : visibleEpisodes.count)
            pickerControls

            if pagedEpisodes.isEmpty {
                Text(query.isEmpty && filter == .all
                     ? L10n.text("No episodes")
                     : L10n.text("No matching episodes"))
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                    ForEach(pagedEpisodes) { episode in
                        episodeCell(episode)
                    }
                }
            }
            if pageCount > 1 { pager }
        }
    }

    /// 搜索 + 筛选 + 每页条数。
    ///
    /// 上千集的面板只靠滚动基本找不到目标；这里给三件事：
    /// 搜（集号或标题）、筛（全部/未看/已看）、每页条数。
    private var pickerControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField(L10n.text("Search episode number or title"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.footnote)
                    .autocorrectionDisabled()
                    .onChange(of: query) { _, _ in page = 0 }
                if !query.isEmpty {
                    Button { query = ""; page = 0 } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.07)))

            HStack(spacing: 8) {
                ForEach(PickerFilter.allCases) { f in
                    Button {
                        filter = f; page = 0
                    } label: {
                        Text(f.label)
                            .font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(
                                filter == f ? Color.primary.opacity(0.16) : Color.primary.opacity(0.05)))
                            .foregroundStyle(filter == f ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Menu {
                    ForEach([20, 50, 100], id: \.self) { n in
                        Button {
                            pageSize = n; page = 0
                        } label: {
                            if pageSize == n { Label("\(n) / " + L10n.text("page"), systemImage: "checkmark") }
                            else { Text("\(n) / " + L10n.text("page")) }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("\(pageSize) / " + L10n.text("page")).font(.caption)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                }
            }
        }
    }

    /// 分页条：‹ 页码 ›，点页码弹输入框直接跳。
    private var pager: some View {
        HStack(spacing: 12) {
            Button { page = max(0, page - 1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                    .frame(width: 40, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(page <= 0)
            .opacity(page <= 0 ? 0.35 : 1)

            Spacer(minLength: 0)

            Button {
                jumpDraft = "\(page + 1)"
                jumping = true
            } label: {
                Text("\(min(page, pageCount - 1) + 1) / \(pageCount)")
                    .font(.caption).monospacedDigit()
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button { page = min(pageCount - 1, page + 1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    .frame(width: 40, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(page >= pageCount - 1)
            .opacity(page >= pageCount - 1 ? 0.35 : 1)
        }
        .alert(L10n.text("Jump to page"), isPresented: $jumping) {
            TextField("1", text: $jumpDraft).keyboardType(.numberPad)
            Button(L10n.text("Cancel"), role: .cancel) {}
            Button(L10n.text("Go")) {
                if let n = Int(jumpDraft), n >= 1 { page = min(pageCount - 1, n - 1) }
            }
        } message: {
            Text(L10n.text("Page %d of %d", min(page, pageCount - 1) + 1, pageCount))
        }
    }

    /// A section's label plus its item count, shared by the line switcher and the episode grid so the
    /// two read as one rhythm instead of two hand-rolled headings.
    private func sectionHeader(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            if let count { Text("\(count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary) }
            Spacer(minLength: 8)
        }
    }

    private func episodeCell(_ episode: Episode) -> some View {
        let isResume = episode.id == resumeEpisode?.id
        let isCurrent = episode.id == currentEpisodeID
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        return Button {
            play(episode)
        } label: {
            VStack(spacing: 2) {
                Text(episode.name).font(.footnote.weight(isCurrent ? .semibold : .medium)).monospacedDigit().lineLimit(1)
                if isCurrent {
                    // Now playing: a speaker/play affordance instead of the resume timestamp, so the
                    // "watching now" and "resume here" marks never read as the same thing.
                    Label(L10n.text("Now Playing"), systemImage: "play.fill")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Brand.onAccent)
                        .lineLimit(1)
                } else if isResume, let position = resumePosition, position > 1 {
                    Text(progressText(position))
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .background(
                isCurrent ? AnyShapeStyle(Brand.accent) :
                isResume ? AnyShapeStyle(Brand.accent.opacity(0.10)) :
                AnyShapeStyle(Color.primary.opacity(0.05))
            )
            .foregroundStyle(isCurrent ? Brand.onAccent : Color.primary)
            .clipShape(shape)
            .overlay(alignment: .bottom) {
                // Resume progress bar, only on the resume cell (and not the one already playing).
                if isResume && !isCurrent, let progress = resumeProgress, progress > 0, progress < 1 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Brand.accent.opacity(0.15))
                            Rectangle().fill(Brand.accent.opacity(0.6))
                                .frame(width: geo.size.width * CGFloat(progress))
                        }
                    }
                    .frame(height: 3)
                    .clipShape(shape)
                }
            }
            .overlay(shape.strokeBorder(isResume && !isCurrent ? Brand.accent.opacity(0.30) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func progressText(_ position: Double) -> String {
        let pattern: Duration.TimeFormatStyle.Pattern = position >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(Int(position)).formatted(.time(pattern: pattern))
    }

    // MARK: Probing

    /// Cached readings first, so the sheet paints instantly with whatever the
    /// last visit learned.
    private func loadReadings() async {
        state.loadCached(sourceKey: sourceKey, videoID: video.id)
    }

    /// Probes only the active line's address. Other lines are measured when the
    /// user actually selects them, which keeps opening the sheet cheap.
    private func probeVisibleLines() async {
        if let episode = episodesOnActiveLine.first {
            await probe(activeLine, address: episode.address)
        }
    }

    private func probe(_ flag: String) async {
        guard let episode = playlist.episodes(for: flag).first else { return }
        await probe(flag, address: episode.address)
    }

    private func probe(_ flag: String, address: String) async {
        await state.probeIfNeeded(
            line: flag,
            address: address,
            headers: headers,
            sourceKey: sourceKey,
            videoID: video.id
        )
    }
}
