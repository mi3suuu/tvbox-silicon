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
//     **lazy**: opening the sheet sends **no probe at all** — it only paints what
//     the cache already knows. A probe happens when the viewer taps a line chip
//     (`probeLines([flag])`) or presses 「重新测速」(`probeLines(force: true)`).
//     The result is cached, so reopening the sheet does not re-measure anything.
//
//  ## Probing has one entry point
//
//  `probeLines(subset:force:)` is the only way in. It was three near-duplicate
//  functions (`probeVisibleLines` / `retestLines` / `probe(flag)`): the first two
//  each copied the same preparation — inject `state.resolve`, build the line list —
//  and the third skipped both. That third one was a real defect: type 3/4 sources
//  hand back a *play parameter* (`第1集$abc123`) in `Episode.address`, so measuring
//  it directly hit `ProbePlanTarget.isRequestable`, which rejects relative URLs, and
//  returned in silence. 605 of the 756 sources in the current subscription are type 3.
//  Every path now goes through `probeOne`, which resolves first.
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
        // ⛔ 守卫必须是「这个地址能不能当 HTTP 请求发」，不能是 `URL(string:) != nil`：
        // type 3/4 源的 `Episode.address` 是 play 参数（`第1集$abc123`），`URL(string:)` 会把它
        // 接受成**相对 URL**，于是这里给一个不存在的地址写一条 `.unreachable`，
        // 还经 `record` → `note` 覆盖掉解析路径刚写好的好读数，污染源测速页、分组与排序。
        guard !line.isEmpty, ProbePlanTarget.isRequestable(address),
              let url = URL(string: address), !inFlight.contains(line) else { return }
        if let host = url.host { bases[line] = host }
        if !force, let known = readings[line] ?? store.probe(sourceKey: sourceKey, videoID: videoID, lineFlag: line),
           !known.isStale(), known.reachability != .unknown {
            readings[line] = known
            return
        }
        // ★ 按 base 的读数（One `latencyByBase` 的等价物，RCA H4）。
        //
        // 上面那条查的是「这个源 · 这部剧 · 这条线」的历史读数 —— 换任何一部剧都会 miss，
        // 于是每进一部新剧就把全部线路重测一遍。这里补一层 host 级：同 host 刚测过就直接用。
        // One 的 `latencyByBase` 根本没有剧的维度，正是这个原因。
        if !force, let byBase = store.baseReading(for: url) {
            readings[line] = byBase
            return
        }

        inFlight.insert(line)
        defer { inFlight.remove(line) }

        // ★ 全局名额（One `pendingTests` 的等价物，RCA H5）。
        //
        // 这一层面板自己有个 4 路上限，但播放页的 `buildLineSamples`、跨源矩阵、全量扫描
        // 各自也有自己的上限，它们互不知情 —— 叠起来能同时打出几十个请求，
        // 抢的正是用户此刻要用来起播的那条链路。全局限流把它们收进同一个池子。
        //
        // ⛔ 必须**先**领全局名额、再领 host 名额。反过来时，若 host 名额领到、
        //    全局名额却没领到就直接返回，那个 host 的在飞计数永远不会归还 ——
        //    该 host 会被永久判成 saturated，后续每条线都测不动。
        // ★ 名额抢不到要**排队**，不能静默丢弃。
        //
        // ⛔ 原来是 `guard store.claimProbeSlot() else { return }` —— 名额被别的入口
        //    （播放页摸底、跨源矩阵、全量扫描）占满时，用户点的这一条**静默丢失**：
        //    界面上既不显示数字也不报错，看起来就是「点了没反应」。
        //
        // 现在排队等（上限 20 秒）。排队期间用户改变主意——换线路、关面板——
        // 会被 `Task` 取消，`waitForProbeSlot` 的取消分支会把自己从队列摘掉并归还。
        guard await store.waitForProbeSlot() else { return }
        defer { store.releaseProbeSlot() }

        // HostRotation is keyed by host: claim it, then record success/failure/cancel on the same key.
        let base = url.host
        if let base, !store.beginBase(base) { return }

        // ★ light 采样（RCA H2）：面板一弹开就测，是「用户还没决定看哪条」的时刻，
        //   要的是「哪条是活的」，不是精确吞吐。128 KB 只有常规探针的一半。
        let result = await SourceProbeRunner.probe(url: url, headers: headers, light: true)
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
        // 带 url 记，才能同时写进 base 表，让同 host 的其它剧直接复用（见 `baseReading`）。
        store.record(result, sourceKey: sourceKey, videoID: videoID, lineFlag: line, url: url)
    }

    /// 把 `Episode.address` 解析成真实流地址。
    ///
    /// ⛔ 必须有这一步：type 3/4（CatPaw / 苹果CMS 播放器接口）的 `address`
    /// 只是一个 play 参数，不是可请求的 URL。旧实现直接拿它去 HEAD，
    /// 测的是一个不存在的地址 —— 数字纯属摆设，而且会把好线路判成不可达。
    /// `VideoDetailView.buildLineSamples` 早就这么做了（那里有 `client`），
    /// 选集面板此前没有，这是两条路径口径不一致的根因。
    var resolve: (@MainActor (Episode) async -> OneSkinLineSample?)?

    /// 并发测**所有**线路，而不只是当前那条。
    ///
    /// 旧注释写「其他线路等用户选了再测，保持打开面板便宜」，实际是死锁：
    /// 用户要比较速度才选线，而速度只有选了才测 —— 于是永远看不到对比。
    /// 现在一次并发测完（最多 4 路，由 `SourceProbeStore` 的主机轮换兜住突发），
    /// 面板一打开就把每条线的速度与画质都摆出来。
    func probeAll(_ lines: [(flag: String, episode: Episode)], headers: [String: String],
                  sourceKey: String, videoID: String, force: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func launch() -> Bool {
                guard next < lines.count else { return false }
                let item = lines[next]
                next += 1
                group.addTask {
                    await self.probeOne(item.flag, episode: item.episode, headers: headers,
                                        sourceKey: sourceKey, videoID: videoID, force: force)
                }
                return true
            }
            for _ in 0..<4 { if !launch() { break } }
            for await _ in group { if !launch() { continue } }
        }
    }

    /// 一条线路：先解析成真实流地址，再测。
    private func probeOne(_ line: String, episode: Episode, headers: [String: String],
                          sourceKey: String, videoID: String, force: Bool) async {
        guard !line.isEmpty, !inFlight.contains(line) else { return }
        // 缓存命中就不必解析 —— 解析比一次测速还贵（要过 preparePlayback + resolvePlayback）。
        if !force, let known = readings[line] ?? store.probe(sourceKey: sourceKey, videoID: videoID, lineFlag: line),
           !known.isStale(), known.reachability != .unknown {
            readings[line] = known
            return
        }
        guard let sample = await resolve?(episode) else {
            // 解析不出来（该线没有真实地址）：不写读数，不编造。
            return
        }
        await probeIfNeeded(line: line, address: sample.url.absoluteString, headers: sample.headers,
                            sourceKey: sourceKey, videoID: videoID, force: force)
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
    /// 选集呈现方式：网格 / 列表。
    ///
    /// One 的 `VideoDetailPage` 里有 `rectangle.grid.1x2` 这颗图标 —— 网格看封面、
    /// 列表看集名，两种场景（找特定一集 / 扫一遍目录）需要的信息不同。
    /// 读 `UserDefaults` 直取而不是 `@AppStorage`：这里只想让它跟着面板存活，
    /// 跨启动记忆反而不是用户要的（每次打开按最合适的那一种）。
    @State private var layout: PickerLayout = .grid

    /// 面板可用宽度；由 `body` 上的 `onGeometryChange` 写入（不参与布局）。
    ///
    /// ⛔ 用 `@State` 存而不是每帧现算：量到的宽度在旋转/折叠动画中
    /// 每帧都报新宽度，直接拿它当布局输入会让网格列数逐帧跳变（与 OneSkin
    /// 「控件推移」同一类病）。这里只存**离散档位**，同一档内宽度变化不触发重排。
    @State private var availableWidth: CGFloat = 0

    /// 当前尺寸档。宽度还没量到时（首帧 0）按外屏排，量到后会跳一次，肉眼不可见。
    private var metrics: PickerMetrics { PickerMetrics.forWidth(availableWidth) }
    /// 正在重测线路。
    @State private var retesting = false
    /// `onAppear` 里由 `LinePreference` **自动解析**出来的那条线路。
    ///
    /// ⛔ 它是为了让 `activeLine` 与播放页同口径（能播的线兜底），但**不是用户的选择**。
    ///    `onChange(of: activeLine)` 会把每次变化写回 `store.episodePickerLine` ——
    ///    如果不加这个标记，自动解析的结果就会冒充「用户选过」，
    ///    下一部剧、甚至下一次重建面板都拿它当第一优先级，
    ///    用户「我明明没选过」却被钉在一条线上。
    @State private var autoResolvedLine: String?

    enum PickerLayout: String, CaseIterable, Identifiable {
        case grid, list
        var id: String { rawValue }
        var symbol: String { self == .grid ? "rectangle.grid.2x2" : "list.bullet" }
    }

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
        // 默认线路：`init` 里只能拿到 view 的参数（`store`/`CloudDrive` 都还不合法），
        // 所以这里先按「历史记录 → 第一条」定一个初值，**能播的线兜底放在 `onAppear`**
        // （那里 `@Environment(Store)` 已就绪，`CloudDrive` 也可访问）。
        //
        // 优先级链本身只有一处出处：`LinePreference`。这里与 `onAppear` 用的是同一个函数，
        // 只是 `init` 阶段少传 `picked` 与 `playableNow` 两级。
        let flags = EpisodePlaylist(video.episodes).flags
        _activeLine = State(initialValue: LinePreference.choose(
            flags: flags, picked: nil, watched: resumeContext?.episodeFlag, playableNow: nil
        ) ?? "")
    }

    private var episodesOnActiveLine: [Episode] { playlist.episodes(for: activeLine) }

    /// 本剧「看过」的集：从逐集历史里按 scope 收一遍。
    /// 不能用单条续播点判断 —— 那只代表「上次看到哪一集」。
    private var watchedIDs: Set<String> {
        let scope = EpisodeSkipSettings.scope(origin: origin, source: sourceKey, video: video.id)
        // 同样只算本环境的：否则 B 环境点「只看未看」会把 A 环境看过的集滤掉，得到空列表。
        return Set(PlaybackHistory.shared.entries(in: PlaybackHistory.shared.activeEnvironmentID).compactMap { entry in
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

    /// 总页数。除零保护与取整规则住在 `TVCore.OneWatchPage.pageCount`（有回归测试）：
    /// 每页条数被写成 0 时不能崩，空列表也算 1 页（避免「1 / 0」）。
    private var pageCount: Int {
        OneWatchPage.pageCount(itemCount: visibleEpisodes.count, pageSize: pageSize)
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
        // 量一次宽度决定档位。sheet 与 Duo 内嵌面板的容器宽度差别很大（466 vs 951），
        // 内部的 `compact` 布尔看不出来，所以要真的量一次宽度。
        //
        // ⛔ 这里**不能用 `GeometryReader` 包**（第一版就是这么写的，闪退）：
        //
        // `GeometryReader` 会向父容器索取「能拿到的全部空间」，并**把它给的尺寸吃掉** ——
        // 它自己不向子视图转发尺寸，子视图拿到的是一个由 GeometryReader 决定的框。
        // 而这个面板是放进 `sheet` / Duo 内嵌面板里的，父级是**自适应尺寸**容器：
        //   · 父级问「你要多大」→ GeometryReader 答「我要无限」→ 面板被撑爆或塌成 0；
        //   · 面板里 `ScrollView` + `LazyVGrid` 在 0 宽/无限高的框里布局 → 崩。
        // 症状就是「点资源/点搜索结果 → 闪退」，以及「显示没达到预期」。
        //
        // 正确做法是 `onGeometryChange`：它**不参与布局**（只读量、不改框），
        // 与 `BiliPortraitPage` 里那处宽度测量同一范式。
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                if abs(w - availableWidth) > 0.5 { availableWidth = w }
            }
    }

    private var content: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: metrics.blockSpacing) {
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
                .padding(compact ? Spacing.medium : metrics.panelPadding)
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
                // 关闭键与「切成小窗」在 **sheet 形态**下都放导航栏。
                // 关掉之后再看集数就太晚了 —— 用户要的是「我先把它缩下去，回头再挑」。
                ToolbarItem(placement: .cancellationAction) {
                    if !compact {
                        Button(L10n.text("Close")) {
                            // In a Duo's inline shape the picker is an in-picture panel with no sheet, so the
                            // store flag is what actually closes it; the dismiss covers the sheet shape.
                            store.showsEpisodes = false
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if !compact { miniPlayerButton }
                }
            }
            #if os(iOS)
            .toolbar(compact ? .hidden : .visible, for: .navigationBar)
            #endif
        }
        .onAppear {
            // ★ 默认线路：走全仓唯一的优先级出口 `LinePreference`，与播放页同一口径。
            //
            // ① 用户这次亲自选的那条优先 —— **这就是「默认以用户选择的为先」**。
            //    Duo 折叠/展开会重建面板，用户刚点的线记在 store 上，必须活在重建之后；
            //    这个选择按 video 归属：flag 名在一个源里跨剧共用，
            //    在 A 剧选的线不该在 B 剧冒出来。
            // ② 上次看这部剧用的那条。
            // ③ 第一条现在就能播的（跳过要扫码 / 没登录的网盘）—— 与播放页 `loadDetail` 一致。
            // ④ 第一条。
            //
            // ⛔ 上一版这里只做了 ①②，没有 ③ —— 于是播放页选中一条能播的线，
            //    而面板 chip 停在 `flags.first`（可能是条根本播不了的），
            //    用户看到「面板高亮 A、实际播 B」。
            let picked = store.episodePickerVideoID == video.id ? store.episodePickerLine : nil
            let resolved = LinePreference.choose(
                flags: flags,
                picked: picked,
                watched: resumeContext?.episodeFlag,
                playableNow: { CloudDrive.preferredFlag([$0]) != nil },
                // 与播放页同一口径：面板高亮的那条必须就是会被播的那条。
                quality: SourceProbeStore.shared.qualityReader(
                    sourceKey: sourceKey, videoID: video.id),
                unplayableNow: SourceProbeStore.shared.blockedLineReader(
                    sourceKey: sourceKey, videoID: video.id)
            )
            if let resolved, resolved != activeLine {
                autoResolvedLine = resolved
                activeLine = resolved
            }

            // 保存/兜底的那条可能已被用户隐藏。若当前线路不再可见，
            // 退到第一条可见线路 —— 否则网格会显示一条没有对应 chip 的线路的剧集。
            if !flags.contains(activeLine), let first = flags.first {
                activeLine = first
            }
        }
        .onChange(of: activeLine) { _, line in
            // 只把**用户亲手点出来的**选择记进 store。
            //
            // ⛔ 自动解析（能播的线兜底）也会改 `activeLine`，那不是用户的选择：
            //    记进去之后它就成了下一轮的「第一优先级」，用户没选过却被钉死在这条线上。
            //    `autoResolvedLine` 标记了「这次变化是我自己算出来的」，跳过即可。
            if autoResolvedLine == line {
                autoResolvedLine = nil   // 消费掉，只挡这一次
                return
            }
            store.episodePickerVideoID = video.id
            store.episodePickerLine = line
        }
        .task(id: activeLine) {
            // ★ 只读缓存，**一个探针都不发**（用户明确要求：不点线路就不探测）。
            //
            // ⛔ 这一行以前还跟着一句全量探测（延后 1.2 秒，即旧的 `probeVisibleLines`），
            //    仍然是「弹开就替用户把所有线路摸一遍」。而这个面板在 iOS 上是
            //    **进页面自动弹出来的**（VideoDetailView.opensIntoEpisodes），
            //    于是用户什么都还没点，4 条线各拉一次采样 × 4~9 条线就把下行吃掉一截，
            //    紧接着的起播自然慢 —— 这是 RCA H2 的现场。
            //
            // 现在这里只做一件事：把已有读数铺上去（缓存命中即时显示「1080P · 120 ms」），
            // 没有读数的那条显示「点一下测速」。真正的探测只发生在：
            //   · 用户点某条线路 chip（`lineChip` 的 action → `probeLines([flag])`）；
            //   · 用户按「重新测速」（`probeLines(force: true)`，忽略缓存）。
            //
            // 这样面板打开是**零请求**的，用户选哪条才测哪条。
            await loadReadings()
        }
    }

    /// The inline panel's own header row: the title and a close affordance, with no navigation bar.
    /// The big poster header below it is hidden in the compact shape too, so the line chips and the
    /// episode grid get the room.
    private var compactHeader: some View {
        HStack(spacing: 8) {
            Text(video.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 8)
            miniPlayerButton
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

    /// 「切成小窗」：把正在播的这一幕收进坞，人退出选集页。
    ///
    /// ⛔ 这个键必须**在加载中也画出来**，不能等集数列表到齐才给。
    ///
    /// 用户报的正是这个窗口：点资源 → 面板打开了，但详情/线路还在解析，页面是空的，
    /// 而 `compact` 下整条 navigationBar 被 `.toolbar(compact ? .hidden : .visible)`
    /// 藏掉（连关闭键一起），于是**既没返回、也没小窗**，只能等 —— 等到慢源上就是「卡住了」。
    /// 现在标题行常驻，两个键都在。
    ///
    /// ⛔ 没有东西在播时**不给**这颗键：`dockForeground()` 在没有 `playing` 时是空操作，
    ///    按下去什么都不会发生 —— 一个按了没反应的键比没有更糟。
    @ViewBuilder private var miniPlayerButton: some View {
        // ⛔ 条件**不能**是 `store.playing != nil`（第一版就是这么写的，所以永远不出现）。
        //
        // 用户在选集页时大多**还没开始播**：`playing` 是 nil。
        // 而「提前播放到小窗」这个需求本身就是「还没播，先扔进坞里播」——
        // 拿「已经在播」当条件，恰好把唯一需要它的场景排除了。
        //
        // 现在无条件给出这颗键，按下时按两种情况走：
        //   · 有前台在播 → `dockForeground()` 把它整集收进坞（不动其他卡片）
        //   · 没有前台      → 用当前选中的那一集**新起**一个小窗（见 `sendToMiniPlayer`）
        Button {
            Task { await sendToMiniPlayer() }
        } label: {
                Image(systemName: "pip.enter").font(.footnote.weight(.semibold))
                    .frame(width: 28, height: 28)
                    #if os(tvOS)
                    .background(Color.primary.opacity(0.06), in: Circle())
                    #else
                    .glassOrFill(.regular.interactive(), Color.primary.opacity(0.06), in: Circle())
                    #endif
            }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("Mini Player"))
    }

    /// 「提前播放到小窗」：不进入播放页，直接把这一集扔进坞里开始播。
    ///
    /// 两条路：
    /// 1. 前台已经在播这一部剧 → `dockForeground()` 把它收进坞，**不重起流**
    ///    （`playing = nil` 的 didSet 只清前台槽，坞里那一份继续播）。
    /// 2. 还没播 → 起一个新的坞任务。`store.videoTasks.start(...)` 自己会取详情、
    ///    选第一集并解析，所以这里只要把作品交出去。
    ///
    /// ⛔ 走 `start(video:client:store:)` 而不是 `selectEpisode`：
    ///    `selectEpisode` 开头就有 `guard playing == channel`（Store.swift:2981），
    ///    在「还没播」的场景下必然直接 return —— 那正是这条需求要解决的场景。
    @MainActor private func sendToMiniPlayer() async {
        if let channel = store.playing {
            store.dockForeground()
            store.showsEpisodes = false
            return
        }
        // 拿不到 client 就没有源，按下去只会报错 —— 那就别假装成功。
        //
        // ⛔ 这里**不能**用 `store.catalogClient(for:)`：那个参数是 `FavoriteVideo`，
        //    而选集页手上是 `Video` + `sourceKey` + `origin`。
        //    按「源 + 地址」定位站点，是 `catalogClient(for:)` 内部的同一套比较。
        guard let config = store.subscription,
              let site = config.sites.first(where: {
                  $0.origin(or: config.origin) == origin && $0.sourceKey == sourceKey
              }) else {
            store.notice = L10n.text("This title has no source to play from.")
            return
        }
        let client = CatalogClient(site: store.resolvedSite(site, origin: config.origin),
                                   origin: config.origin, jarURL: config.spiderURL)
        await store.videoTasks.start(video: video, client: client, store: store)
        store.showsEpisodes = false
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
        let size: (CGFloat, CGFloat) = compact ? (56, 84) : metrics.coverSize
        return PosterImage(url: video.poster, headers: video.posterHeaders)
            .frame(width: size.0, height: size.1)
            .clipShape(RoundedRectangle(cornerRadius: compact ? Radius.medium : metrics.coverRadius, style: .continuous))
    }

    // MARK: Line switcher

    private var lineSwitcher: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(L10n.text("Source"), count: flags.count)
            // 线路 chip：外屏与内屏竖持横滑（省竖向空间），内屏横持/全屏**换行铺开**。
            //
            // ⛔ 为什么宽屏要换行：951pt 上放 6 条线路，横滑版一次只能看到 2–3 条，
            // 其余要手动滑 —— 而宽屏明明有余量。外屏 466pt 上横滑是对的（换行会把
            // 选集网格整体推下去）。这一条此前没有，因为面板从不区分屏幕宽度。
            if metrics == .innerLandscape {
                // 宽档：`Grid` 自动换行，chip 等宽排布。
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(flags, id: \.self) { flag in
                        lineChip(flag)
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(flags, id: \.self) { flag in
                            lineChip(flag)
                        }
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
            // 只测这一条。走 `probeLines` 才有 `resolve` —— 否则 type 3/4 源的
            // play 参数会被 `isRequestable` 判掉，点击静默无效。
            Task { await probeLines([flag]) }
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
                // Every configured proxy is offered, not just the first: with two set up (home and
                // away, say) only ever naming the first left the second unreachable from the one
                // place a line's route can be set.
                ForEach(store.customProxy.store.endpoints) { proxy in
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
        // 网页型线路先于可达性判：它回 200、耗时也正常，但播放器打不开 —— 显示成绿色就是在骗人。
        if reading?.isPageOnly == true { return Brand.amber }
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
            } else if layout == .grid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.gridMinColumn),
                                            spacing: metrics.gridSpacing)],
                          spacing: metrics.gridSpacing) {
                    ForEach(pagedEpisodes) { episode in
                        episodeCell(episode)
                    }
                }
            } else {
                // 列表：一行一集，集名完整可读（网格里集名被压成两行）。
                LazyVStack(spacing: 0) {
                    ForEach(Array(pagedEpisodes.enumerated()), id: \.element.id) { index, episode in
                        episodeRow(episode, index: index)
                        if episode.id != pagedEpisodes.last?.id {
                            Divider().opacity(0.35)
                        }
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
                // 重测线路。
                //
                // 读数缓存过期才自动重测，而「过期」是 5 分钟——用户刚发现某条线卡了，
                // 此时缓存里的数字还是好的。没有这个入口，他只能关掉面板再开（且要等过缓存）。
                Button {
                    Task { await probeLines(force: true) }
                } label: {
                    if retesting {
                        ProgressView().controlSize(.mini).frame(width: 30, height: 24)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 24)
                            .background(Capsule().fill(Color.primary.opacity(0.05)))
                    }
                }
                .buttonStyle(.plain)
                .disabled(retesting)
                .accessibilityLabel(L10n.text("重新测速"))

                // 网格 / 列表切换（One 的 `rectangle.grid.1x2`）。
                Button {
                    layout = layout == .grid ? .list : .grid
                } label: {
                    Image(systemName: layout.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 24)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text(layout == .grid ? "列表" : "网格"))
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
            // `keyboardType` is iOS-only: macOS and tvOS have no on-screen keyboard, so the
            // modifier does not exist there. The field and its binding are shared.
            #if os(iOS)
            TextField("1", text: $jumpDraft).keyboardType(.numberPad)
            #else
            TextField("1", text: $jumpDraft)
            #endif
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

    /// 列表态的一行：集号 + 集名 + 状态（正在播 / 续播进度）。
    ///
    /// 与网格格子的信息一致，只是排版不同 —— 网格把集名压成一行省略，
    /// 列表给足宽度，扫目录时能直接读全名。
    @ViewBuilder
    private func episodeRow(_ episode: Episode, index: Int) -> some View {
        let isResume = episode.id == resumeEpisode?.id
        let isCurrent = episode.id == currentEpisodeID
        Button {
            play(episode)
        } label: {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isCurrent ? Brand.onAccent : Color.secondary)
                    .frame(minWidth: 26, alignment: .trailing)
                Text(episode.name)
                    .font(.footnote.weight(isCurrent ? .semibold : .regular))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if isCurrent {
                    Label(L10n.text("Now Playing"), systemImage: "play.fill")
                        .font(.caption2.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                } else if isResume, let position = resumePosition, position > 1 {
                    Text(progressText(position))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isCurrent ? Brand.accent
                        : isResume ? Brand.accent.opacity(0.10)
                        : Color.clear)
            .foregroundStyle(isCurrent ? Brand.onAccent : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Probing

    /// Cached readings first, so the sheet paints instantly with whatever the
    /// last visit learned.
    private func loadReadings() async {
        state.loadCached(sourceKey: sourceKey, videoID: video.id)
    }

    /// 探测入口 —— **唯一**。
    ///
    /// 原来这里是三个几乎重复的函数（`probeVisibleLines` / `retestLines` / `probe(flag)`）：
    /// 前两个各自把「注入 `state.resolve` + 建设探测清单」抄了一遍，第三个干脆两样都没做。
    ///
    /// ## 三个缺陷，都在这里一并收掉
    ///
    /// **① 点 chip 在 type3/4 源上根本不测（最严重）。**
    /// `probe(flag)` 直接拿 `episode.address` 去测，而 type 3/4 源的 `address` 是
    /// play 参数（`第1集$abc123`），`ProbePlanTarget.isRequestable` 会把相对 URL 判掉，
    /// 于是**静默 return**，界面既不显示数字也不报错。当前订阅 756 个源里 605 个是
    /// type 3（80%），等于「点线路测速」在绝大多数源上是坏的。
    /// 现在单条探测也走 `probeOne` → `resolve`，与全量探测同一条路。
    ///
    /// **② 重复的准备逻辑。** `resolve` 的注入与清单构建现在只写一次。
    ///
    /// **③ 名额抢不到时静默丢弃。** `probeIfNeeded` 里 `claimProbeSlot() == false` 就 `return`；
    /// 现在改走 `waitForProbeSlot`（排队等，见那边的说明）。
    ///
    /// - Parameters:
    ///   - subset: 只测这些线路（`nil` = 全部可见线路）。
    ///   - force: 忽略缓存，强制重测（「重新测速」按钮用）。
    private func probeLines(_ subset: [String]? = nil, force: Bool = false) async {
        // 解析器一次注好：type 3/4 的 address 只是 play 参数，
        // 必须过 preparePlayback + resolvePlayback 才变成可测的真实流地址。
        await state.resolve = { episode in
            await store.lineSample(for: episode, sourceKey: sourceKey, origin: origin, headers: headers)
        }

        // 每条线取「当前正在看的这一集」，该线没有就退回它自己的首集。
        // 过滤规则（去重 / 保序 / 剔除失效名字）在 `LinePreference.linesToProbe` 里，
        // 那一层有单测；这里只负责取集数。
        let wanted = LinePreference.linesToProbe(flags, subset: subset)
        let items: [(flag: String, episode: Episode)] = wanted.compactMap { flag in
            let onLine = playlist.episodes(for: flag)
            guard let pick = onLine.first(where: { $0.id == currentEpisodeID }) ?? onLine.first else { return nil }
            return (flag, pick)
        }
        guard !items.isEmpty else { return }
        await state.probeAll(items, headers: headers, sourceKey: sourceKey, videoID: video.id, force: force)
    }

    /// 单条线路探测 —— **保留但不再被调用**，只作为「拿裸地址去测」这条老路的正确写法留档。
    ///
    /// ⛔ 它原本的实现是直接 `probeIfNeeded(address: episode.address)`，而 type 3/4 源的
    ///    `address` 是 play 参数、会被 `isRequestable` 判掉并静默 return ——
    ///    这正是「点线路测速在 80% 源上失效」的成因。
    ///
    /// 现在它内部改走 `probeLines([flag])`（即经 `resolve` 的正路），
    /// 于是即使将来有人重新调它，也不会再踩同一个坑。
    /// 若要彻底删除，请先确认没有任何分支会用到「只测一条、且手里只有 address」的场景。
    private func probe(_ flag: String, address: String) async {
        _ = address   // 裸地址不可信：type 3/4 的 address 只是 play 参数，必须过 resolve。
        await probeLines([flag])
    }
}
