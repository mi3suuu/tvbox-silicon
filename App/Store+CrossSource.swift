import Foundation
import TVCore

// MARK: - 跨源换源

/// 「换个源看同一部剧」：在**所有订阅的所有源**里搜同名，判定哪些是同一部，按能不能看排好。
///
/// 为什么单独一个文件
/// ---------------
/// `Store` 主类已经 300+ 成员，二开原则是「上游为准 + 补丁独立开」。
/// 这里全是新增能力，放进 extension 不碰主类任何一行，也让这块逻辑能单独读。
///
/// 数据链路
/// --------
///   `GlobalSearch.search(sites:origin:jarURL:query:onResult:)` —— 已经会向所有源派发
///   → 每个 `SearchSourceResult(site, page, error)` 带回该源的 `[Video]`
///   → `site.provenance.origin` / `site.sourceKey` 给出「来自哪个订阅 / 哪个源」
///   → 喂给 `CrossSourceMatch.candidates`，由它判定 + 排序
///
/// 判定为什么不能查表
/// ----------------
/// `Video.id` 是源内 `vod_id`，同一部剧在不同源里是完全不同的数字，没有共同主键。
/// 所以只能靠 `CrossSourceMatch` 的内容比对（标题归一 + 年份 + 集数 + 分类）。
@MainActor
extension Store {

    /// 跨源换源的界面状态。挂在 `Store` 上而不是页面上：
    /// 搜索结果要跨「换源面板 → 详情页 → 播放页」存活，页面一重建就丢等于每次重搜。
    struct CrossSourceState {
        var query: String = ""
        var running = false
        /// 已判定为同一部、按「该切哪个」排好的候选。
        var candidates: [CrossSourceMatch.Candidate] = []
        /// 问过的源数 / 已回的源数，用来显示进度而不是一个转圈。
        var asked = 0
        var answered = 0
        /// 出错或没参与的源名，给用户一句实话而不是静默。
        var skipped: [String] = []
        var finished = false

        // ── 连通性测试（新增）────────────────────────────────────────
        /// 正在实测候选源。搜索本身很快，**测速慢得多**，所以状态分开，
        /// 面板能先出列表、再逐行把数字填上来，而不是等全部测完才显示。
        var probing = false
        /// 已完成 / 需测的总数，用来显示真实进度。
        var probed = 0
        var probeTotal = 0
        /// 正在跑的那一轮测速任务句柄，供「停止」用。
        ///
        /// `@ObservationIgnored`：它是副作用句柄，不该触发视图重算。
        @ObservationIgnored var probeTask: Task<Void, Never>?
        /// 实测得到的读数，按 `sourceKey|videoID` 存 —— 与候选 id 同构。
        ///
        /// 为什么不直接写回 `candidates[i].probe`：那是 `CrossSourceMatch.Candidate`
        /// 的 `let` 字段，而且排序已经按旧读数算过了。把新读数单独放一张表，
        /// 面板渲染时优先查这张表，就不必重排（重排会让用户正在看的那一行跳走）。
        var readings: [String: SourceProbeResult] = [:]
        /// 用户点「测试连通性」后为 true：全列表都要重测，不再只看缓存。
        var forceProbed = false

        // ── 线级矩阵（跨渠道 × 跨线路）────────────────────────────────
        var matrixRunning = false
        var matrixFinished = false
        var matrixDone = 0
        var matrixTotal = 0
        /// 摊平后的全部格子；面板按 `LineMatrix.build` 分组显示。
        var matrixCells: [LineMatrix.Cell] = []
    }

    /// 当前这一部剧的跨源候选。
    var crossSource: CrossSourceState {
        get { crossSourceStorage }
        set { crossSourceStorage = newValue }
    }

    /// 正在看的那部剧的跨源身份（标题 + 季 + 年份 + 集数 + 分类）。
    ///
    /// 集数优先取**详情**里的：列表项的 `episodes` 常常是空的或只有 1 集占位，
    /// 拿它当身份会把「46 集」误记成「1 集」，从而和别的源全判成不同部。
    func crossSourceIdentity() -> CrossSourceMatch.ShowIdentity? {
        guard let catalog = playbackCatalog else { return nil }
        return CrossSourceMatch.identity(of: catalog.video, episodes: catalog.video.episodes.count)
    }

    /// 在全部可见源里搜当前这部剧的同名结果。
    ///
    /// - Parameter force: 已搜过同一个关键词时，默认复用上次结果（换源面板反复开关
    ///   不该反复打 300 个源）；`force` 才重搜。
    func searchCrossSource(force: Bool = false) async {
        guard let config = subscription, let identity = crossSourceIdentity() else { return }
        let keyword = identity.titleKey.isEmpty ? (playbackCatalog?.video.name ?? "") : (playbackCatalog?.video.name ?? "")
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !force, crossSource.finished, crossSource.query == keyword, !crossSource.candidates.isEmpty { return }

        // 只问**能看**的源：保险库隐藏的源连搜索都不该发（与 `searchableSites` 同一口径）。
        let visible = searchableSites(config.sites, origin: config.origin)
        let eligible = visible.filter { $0.searchable }
        // ⛔ 不能整体替换 `crossSource`：那会把 `probing` / `matrixRunning` 一并抹成
        // false、并清空 `readings` / `matrixCells`。而「重新搜索」按钮的 disabled
        // 只判 `state.running`，测速期间它是 false 故可点 —— 标志被绕过、
        // 第二轮测速叠在第一轮上（probed 会超过 probeTotal，readings 混两代 id）。
        // 这里保留测速相关字段，只重置搜索相关字段。
        let keptProbing = crossSource.probing
        let keptMatrixRunning = crossSource.matrixRunning
        let keptReadings = crossSource.readings
        let keptMatrixCells = crossSource.matrixCells
        let keptProbeTotal = crossSource.probeTotal
        let keptProbed = crossSource.probed
        let keptProbeTask = crossSource.probeTask
        crossSource = CrossSourceState(query: keyword, running: true, asked: eligible.count)
        crossSource.probing = keptProbing
        crossSource.matrixRunning = keptMatrixRunning
        crossSource.readings = keptReadings
        crossSource.matrixCells = keptMatrixCells
        crossSource.probeTotal = keptProbeTotal
        crossSource.probed = keptProbed
        crossSource.probeTask = keptProbeTask

        // 收集器：`GlobalSearch` 的回调是 `@Sendable` 且并发跑，
        // 不能直接改外面的 `var`（Swift 6 的 SendableClosureCaptures 会拒）。用一个 actor 收，
        // 顺带也解决了「几十个源同时回调」的写竞争。
        let collector = CrossSourceCollector()
        // 探针读数是主 actor 上的（`SourceProbeStore` 那层是 @MainActor），
        // 所以先把读数快照成一张不可变的表传进去，回调里只做查表。
        let probeSnapshot = Dictionary(uniqueKeysWithValues: eligible.map { site in
            (site.sourceKey, SourceProbeStore.shared.latest(sourceKey: site.sourceKey))
        })

        await GlobalSearch.search(sites: eligible, origin: config.origin, jarURL: config.spiderURL, query: keyword) { result in
            let origin = result.site.origin(or: config.origin)
            guard let page = result.page else {
                // 这个源报错了。记名字，面板上给一句「这几个源没答」——
                // 静默会让用户以为「只有这几部」，比报错更误导。
                await collector.record(skipped: result.site.name)
                let progress = await collector.progress
                await MainActor.run {
                    self.crossSource.answered = progress.answered
                    self.crossSource.skipped = progress.skipped
                }
                return
            }
            let probe = probeSnapshot[result.site.sourceKey] ?? nil
            let rows = page.videos.map { video in
                CrossSourceCollector.Row(video: video,
                                         sourceKey: result.site.sourceKey,
                                         sourceName: result.site.name,
                                         origin: origin,
                                         probe: probe,
                                         episodes: video.episodes.isEmpty ? nil : video.episodes.count)
            }
            await collector.record(rows: rows)
            let progress = await collector.progress
            await MainActor.run {
                self.crossSource.answered = progress.answered
                self.crossSource.skipped = progress.skipped
            }
        }

        let collected = await collector.result
        let ranked = CrossSourceMatch.candidates(for: identity, from: collected.rows)
        // 已经是当前这一源/这一部的，不必出现在候选里 —— 用户点它等于什么都没做。
        let currentKey = playbackCatalog?.client.site.sourceKey
        let currentID = playbackCatalog?.video.id
        crossSource.candidates = ranked.filter { !($0.sourceKey == currentKey && $0.video.id == currentID) }
        crossSource.asked = eligible.count
        crossSource.answered = collected.answered
        crossSource.skipped = collected.skipped
        crossSource.running = false
        crossSource.finished = true
    }

    /// 切到候选里的这一部：把它当成本页播放的那一部。
    ///
    /// 做三件事，顺序不能反：
    ///   1. 拉它的详情（列表项没有集数）
    ///   2. 用详情里的第一集解析出播放地址
    ///   3. `remember(...)` 把新 catalog 挂上，再 `playing =` 起播
    ///
    /// 第 3 步的两句不能调换：`playing` 的 didSet 会去 `catalog(for:)` 找
    /// 与 channel scope 对应的 catalog；catalog 还没换就先设 playing，
    /// 找到的是**上一部**，换源就成了原地重播。
    func switchToCrossSource(_ candidate: CrossSourceMatch.Candidate, success: (() -> Void)? = nil,
                             failed: ((String) -> Void)? = nil) {
        guard let config = subscription,
              let site = config.sites.first(where: {
                  $0.origin(or: config.origin) == candidate.origin && $0.sourceKey == candidate.sourceKey
              }) else {
            failed?(L10n.text("That source is no longer in your subscriptions."))
            return
        }
        // 与 `openSeriesVideo` 同一道闸：保险库隐藏的源不能借换源重新进入。
        guard vault.permitsPlayback(sourceKey: candidate.sourceKey, origin: candidate.origin) else {
            failed?(L10n.text("This title is hidden. Unlock the Privacy Vault to watch it."))
            return
        }
        let client = CatalogClient(site: resolvedSite(site, origin: config.origin), origin: config.origin,
                                   jarURL: config.spiderURL).applying(config)
        let known = candidate.video
        crossSourceSwitchTask?.cancel()
        crossSourceSwitchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let video = (try? await client.detail(known.id))?.keepingPoster(known.poster, headers: known.posterHeaders) ?? known
                guard !Task.isCancelled, let first = video.episodes.first else {
                    failed?(L10n.text("That source has no episode to play."))
                    return
                }
                let channel = try await client.playback(first)
                guard !Task.isCancelled else { return }
                self.remember(video, client: client, for: channel)
                self.playing = channel
                success?()
            } catch {
                Diagnostics.shared.failure("catalog", "cross-source switch \(client.reportContext) id=\(known.id)", error)
                failed?(error.localizedDescription)
            }
        }
    }
}

// MARK: - 并发收集

/// `GlobalSearch` 的回调是 `@Sendable` 且几十个源并发跑，所以结果必须收在一个 actor 里。
///
/// 直接用外部 `var` 有两层问题：Swift 6 的 `SendableClosureCaptures` 直接拒编译；
/// 就算绕过，几十个源同时写同一个数组也是竞争。actor 把这两件事一起解决。
actor CrossSourceCollector {
    typealias Row = CrossSourceMatch.Input

    private(set) var rows: [Row] = []
    private(set) var answered = 0
    private(set) var skipped: [String] = []

    var progress: (answered: Int, skipped: [String]) { (answered, skipped) }
    var result: (rows: [Row], answered: Int, skipped: [String]) { (rows, answered, skipped) }

    func record(rows new: [Row]) {
        rows.append(contentsOf: new)
        answered += 1
    }

    func record(skipped name: String) {
        skipped.append(name)
        answered += 1
    }
}

// MARK: - 单集 → 可测速的真实流地址

extension Store {
    /// 把一集解析成「可以直接发 HTTP 的地址 + 请求头」。
    ///
    /// 为什么需要它：type 3/4（CatPaw / 苹果CMS 播放器接口）的 `Episode.address`
    /// 只是一个 play 参数，必须过 `preparePlayback` + `resolvePlayback` 才变成流地址。
    /// 拿原始字符串去测速，测的是一个不存在的 URL —— 数字纯属摆设，
    /// 而且会把好线路判成不可达。
    ///
    /// `VideoDetailView.buildLineSamples` 早就这么做了，选集面板此前没有 ——
    /// 这是两条路径口径不一致的根因。现在两边共用这一个入口。
    ///
    /// - Parameters:
    ///   - sourceKey: 这一集所属的源（`Site.sourceKey`，合并订阅改了名也用这个）。
    ///   - origin: 该源所属订阅的地址。
    /// - Returns: nil 表示这条线解析不出地址（该线没有这一集 / 源报错），
    ///   调用方据此跳过、不写假读数。
    func lineSample(for episode: Episode, sourceKey: String, origin: URL,
                    headers: [String: String]) async -> OneSkinLineSample? {
        guard let config = subscription,
              let site = config.sites.first(where: {
                  $0.origin(or: config.origin) == origin && $0.sourceKey == sourceKey
              }) else { return nil }
        let client = CatalogClient(site: resolvedSite(site, origin: config.origin),
                                   origin: config.origin, jarURL: config.spiderURL).applying(config)
        do {
            let plan = try await client.preparePlayback(episode)
            guard let choice = plan.choices.first else { return nil }
            let channel = try await client.resolvePlayback(plan, choice: choice)
            // 已有的请求头优先（它来自实际播放中的 channel，最准）。
            return OneSkinLineSample(url: channel.url, headers: channel.headers.merging(headers) { a, _ in a })
        } catch {
            Diagnostics.shared.failure("probe", "line sample \(client.reportContext) id=\(episode.id)", error)
            return nil
        }
    }
}

// MARK: - 跨源连通性实测

/// 「换个源看」的测速。
///
/// ## 修的是什么
///
/// 这个面板此前**从不测速**：只把 `SourceProbeStore.latest(sourceKey:)` 的旧缓存查出来显示。
/// 于是除极少数之前碰巧测过的源，每行的 `ms` / KB/s / 分辨率都是空的 ——
/// 界面呈现出「能测速」的样子，实际一个请求都没发。
///
/// 现在分两步，因为代价差得很远：
///   1. **搜索**（几十上百个源并发查询）先出列表；
///   2. **测速**（每源要拉详情 + 解析播放地址 + 读几百 KB）按需启动，逐行把数字填上来。
///
/// ## 为什么必须走 `playback(_:)` 而不是直接 HEAD 列表里的地址
///
/// 列表项只有概要，没有可直接请求的流地址。`CatalogClient.playback(episode)` 内部完成
/// 「preparePlayback → resolvePlayback」两步，给出真实 URL + 请求头 —— 与选集面板、
/// 播放页线路测速完全同一口径。少了这一步直接 HEAD，测的是不存在的 URL，
/// 好线路会被判成不可达。
extension Store {
    /// 跨源测速的单轮总预算。超过就停止续投，已完成的读数保留。
    ///
    /// 20 分钟的依据：候选源最多约 60 个、并发 4、每源最长 8 秒（详情 + 解析 + 探针），
    /// 正常网络下 60/4 × (2+3) ≈ 75 秒；给到 20 分钟是「极慢但还没死」的上界。
    /// 没有这个闸门时最坏情况无上界，用户只能杀 App。
    static let crossSourceProbeBudget: TimeInterval = 20 * 60

    /// 停止一轮跨源测速。
    ///
    /// 只置标志 + 取消任务；已测到的读数**不清**（那是有效结果）。
    @MainActor
    func cancelCrossSourceProbe() {
        crossSource.probeTask?.cancel()
        crossSource.probeTask = nil
        crossSource.probing = false
        crossSource.matrixRunning = false
    }

    /// 实测每个候选源：解析它自己第一集的真实播放地址，再用统一探针测一次。
    ///
    /// - Parameter force: true 时连新鲜缓存也不用，全部重测。
    @MainActor
    func probeCrossSourceCandidates(force: Bool = false) async {
        guard !crossSource.candidates.isEmpty, subscription != nil else { return }
        // 与 `buildCrossSourceLineMatrix` 互斥（同上）。
        if crossSource.probing || crossSource.matrixRunning { return }

        crossSource.probing = true
        crossSource.forceProbed = force
        crossSource.probed = 0
        // 记下句柄，让「停止」能真的取消在飞的请求。
        // 用 `defer` 清空：无论正常结束、超时还是被取消，句柄都不会留成悬空引用。
        let work = Task { await self.runCrossSourceProbe(force: force) }
        crossSource.probeTask = work
        await work.value
        crossSource.probeTask = nil
        crossSource.probing = false
    }

    /// 测速主体（从 `probeCrossSourceCandidates` 拆出，只为了让句柄能被取消）。
    @MainActor
    private func runCrossSourceProbe(force: Bool) async {
        // force 重测必须清掉旧读数：否则某源这次测不成了（拿不到详情/解析失败 → nil），
        // `if let result` 跳过写入，上一轮的数字会一直留在界面上，
        // 看起来像「测过了还是那个速度」，实际这次根本没测到。
        if force { crossSource.readings.removeAll() }

        // 只测还没读数的（force 时全测）。已测过的行原地保留，不闪。
        let todo: [CrossSourceMatch.Candidate] = crossSource.candidates.filter { candidate in
            if force { return true }
            if crossSource.readings[candidate.id] != nil { return false }
            if let cached = SourceProbeStore.shared.latest(sourceKey: candidate.sourceKey),
               !cached.isStale(), cached.reachability != .unknown {
                return false
            }
            return true
        }
        crossSource.probeTotal = todo.count
        guard !todo.isEmpty else {
            crossSource.probing = false
            return
        }

        // 主线程隔离的量先快照，再并发解析。
        let config = subscription
        let sites = config?.sites ?? []
        let jarURL = config?.spiderURL
        let limit = 4   // 与播放页线路测速同档：并发太高会把源站打急
        // 总时限：没有它，最坏情况（几十个源全部超时 + 每条线路 8 秒）能挂 30–45 分钟
        // 不返回，用户只能杀掉 App。每个候选源内部已有单次 probe 的 8 秒超时，
        // 但**源数 × 线路数**累起来仍然没有上界，所以这里再兜一层总闸。
        // 超时后已完成的读数照常保留（下面 for await 里写入的都已经落进 readings）。
        let deadline = Date().addingTimeInterval(Self.crossSourceProbeBudget)

        await withTaskGroup(of: (String, SourceProbeResult?).self) { group in
            var index = 0
            func launch() {
                guard index < todo.count else { return }
                // 到总时限就停止续投新任务（在飞的由 group 自然收尾）。
                guard Date() < deadline else { return }
                let candidate = todo[index]
                index += 1
                group.addTask {
                    let result = await Self.probeOneCandidate(
                        candidate,
                        site: sites.first {
                            $0.sourceKey == candidate.sourceKey
                                && $0.origin(or: candidate.origin) == candidate.origin
                        },
                        origin: candidate.origin,
                        jarURL: jarURL,
                        config: config
                    )
                    await MainActor.run { [weak self] in self?.crossSource.probed += 1 }
                    return (candidate.id, result)
                }
            }
            for _ in 0..<min(limit, todo.count) { launch() }
            for await (id, result) in group {
                // 用户点了「停止」→ 立刻收工，不再续投。
                if Task.isCancelled { group.cancelAll(); break }
                if let result {
                    crossSource.readings[id] = result
                    // 顺带写回全局探针库：源测速页、资源排序、候选排序都用同一份读数。
                    if let candidate = crossSource.candidates.first(where: { $0.id == id }) {
                        // ⛔ `?? "default"` 只兜 `nil`，**不兜空串**。
                        // 而 `flag == ""` 在 CMS 源里是常态（vod_play_url 的分组数
                        // 常多于 vod_play_from 的段数），`SourceProbeStore.record` 里
                        // `guard !lineFlag.isEmpty else { return }` 会把空 flag **静默丢弃** ——
                        // 面板看得见数字，全局探针库永远没有。
                        let rawFlag = candidate.video.episodes.first?.flag ?? ""
                        let flag = rawFlag.isEmpty ? "default" : rawFlag
                        SourceProbeStore.shared.record(result,
                                                       sourceKey: candidate.sourceKey,
                                                       videoID: candidate.video.id,
                                                       lineFlag: flag)
                    }
                }
                launch()
            }
        }
    }

    /// 测一个候选源：拉详情第一集 → `playback(_:)` 解析真实地址 → 统一探针。
    ///
    /// 拿不到地址时返回 `nil`（面板显示「测不了」），**不编造数字** ——
    /// 与 `OneSkin.measure` 的约定一致：连不上就不显示，不猜。
    private nonisolated static func probeOneCandidate(_ candidate: CrossSourceMatch.Candidate,
                                                      site: Site?,
                                                      origin: URL,
                                                      jarURL: URL?,
                                                      config: Subscription?) async -> SourceProbeResult? {
        guard let site, let config else { return nil }
        let client = CatalogClient(site: site, origin: origin, jarURL: jarURL).applying(config)
        do {
            // 列表项通常没有集数，先拉详情（与 `switchToCrossSource` 第一步同源）。
            let detail = try await client.detail(candidate.video.id)
            guard let episode = detail.episodes.first else { return nil }
            let channel = try await client.playback(episode)
            let url = channel.url
            // ⛔ **不要**把 `.unreachable` 折成 nil。
            //
            // 上一版 `return result.reachability == .unreachable ? nil : result`，
            // 而 body 里 `if let result { readings[id] = result }` —— 于是：
            //   用户重测一个**已经死掉**的源 → 读数不写 → 旧读数也不清 →
            //   面板继续显示上次的「1080P · 120 ms · 2.0 MB/s」。
            // 这就是本功能立项要修的「数字纯属摆设」在同一批新码里复发：
            // 测通了写、测死了不写，只报喜不报忧。
            // 而且 `readings` 里永远不会出现 `.unreachable`，
            // 于是 CrossSourceSheet 的 "Not reachable last time" 分支实测走不到。
            //
            // nil 只留给「**根本没测成**」（详情拿不到、地址解析失败、抛异常）——
            // 那种情况没有读数可言，与「测了但连不上」是两件事。
            // 全局名额（RCA H5）+ light 采样（RCA H2）：这里是「搜完顺手测一遍」的场景，
            // 用户关心的是哪个源活，不是精确吞吐。
            //
            // ★ 用 claim 不用 wait：这是批量路径（几十上百个候选源同时要测），
            //   排队会拖成串行。跳过并计入"未测"更诚实。交互路径才该排队。
            guard await SourceProbeStore.shared.claimProbeSlot() else { return nil }
            let result: SourceProbeResult = await SourceProbeRunner.probe(url: url, headers: channel.headers, light: true)
            await SourceProbeStore.shared.releaseProbeSlot()
            return result
        } catch {
            return nil
        }
    }
}

// MARK: - 同剧跨渠道 × 跨线路 连通性矩阵

/// 把「同一部剧」在**每个候选源 × 每条线路**上摊平成一张矩阵并逐个实测。
///
/// 与 `probeCrossSourceCandidates` 的分工：
///   · 那个测的是**每源一条线**（该源第一集的默认线），回答「换到哪个源」；
///   · 这个测的是**每源每条线**，回答「换到哪个源的哪条线」。
///
/// 用户换源的真实动机常常是跨维度的：A 源 2 号线 40ms 但 80KB/s，
/// B 源 1 号线 120ms 但 3MB/s —— 只看源级数字挑不出来，必须摊到线级。
extension Store {
    /// 逐个候选源 × 逐条线路实测，结果按 `LineMatrix` 聚合。
    ///
    /// - Parameter force: true 时不用缓存，全部重测。
    @MainActor
    func buildCrossSourceLineMatrix(force: Bool = false) async {
        guard !crossSource.candidates.isEmpty, subscription != nil else { return }
        // ⛔ 两颗按钮必须互斥。
        //
        // 上一版各自只看自己的标志，于是「测试连通性」跑着的时候还能点「全部线路」
        // —— 4 + 3 = 7 路并发同时打几十个源，正是这两段代码自己写要避免的事。
        if crossSource.matrixRunning || crossSource.probing { return }

        crossSource.matrixRunning = true
        crossSource.matrixDone = 0
        crossSource.matrixTotal = crossSource.candidates.count
        crossSource.matrixCells = []

        let config = subscription
        let sites = config?.sites ?? []
        let jarURL = config?.spiderURL
        let limit = 3   // 比源级测速更低：这一步每个源要多花「列线路 + 逐条解析」
        // 主 actor 上的候选先快照成不可变数组 —— 闭包是 nonisolated 的，读不到 `crossSource`。
        let candidates = crossSource.candidates

        await withTaskGroup(of: [LineMatrix.Cell].self) { group in
            var index = 0
            func launch() {
                guard index < candidates.count else { return }
                let candidate = candidates[index]
                index += 1
                group.addTask {
                    let cells = await Self.probeLines(
                        candidate,
                        site: sites.first {
                            $0.sourceKey == candidate.sourceKey
                                && $0.origin(or: candidate.origin) == candidate.origin
                        },
                        origin: candidate.origin,
                        jarURL: jarURL,
                        config: config,
                        force: force
                    )
                    await MainActor.run { [weak self] in
                        self?.crossSource.matrixDone += 1
                        self?.crossSource.matrixCells.append(contentsOf: cells)
                    }
                    return cells
                }
            }
            for _ in 0..<min(limit, candidates.count) { launch() }
            for await _ in group { launch() }
        }
        crossSource.matrixRunning = false
        crossSource.matrixFinished = true
    }

    /// 测一个候选源的所有线路：详情 → 按 `flag` 分组 → 每条取一集解析 → 探针。
    private nonisolated static func probeLines(_ candidate: CrossSourceMatch.Candidate,
                                               site: Site?,
                                               origin: URL,
                                               jarURL: URL?,
                                               config: Subscription?,
                                               force: Bool) async -> [LineMatrix.Cell] {
        guard let site, let config else { return [] }
        let client = CatalogClient(site: site, origin: origin, jarURL: jarURL).applying(config)
        do {
            let detail = try await client.detail(candidate.video.id)
            // 按线路分组；同一线路取第一集当样本（与播放页 `buildLineSamples` 同一口径）。
            var firstPerFlag: [String: Episode] = [:]
            for episode in detail.episodes where firstPerFlag[episode.flag] == nil {
                firstPerFlag[episode.flag] = episode
            }
            guard !firstPerFlag.isEmpty else { return [] }

            // 缓存命中就不必再解析 —— 解析比一次测速还贵。
            var cached: [String: SourceProbeResult] = [:]
            if !force {
                for (rawFlag, _) in firstPerFlag {
                    // 查缓存也要用归一化后的键 —— 与 record 写进去的键一致。
                    let key = rawFlag.isEmpty ? "default" : rawFlag
                    if let known = await SourceProbeStore.shared.probe(sourceKey: candidate.sourceKey,
                                                                      videoID: candidate.video.id,
                                                                      lineFlag: key) {
                        cached[rawFlag] = known
                    }
                }
            }

            var cells: [LineMatrix.Cell] = []
            // 攒批写库（见循环内注释）。
            var pendingWrites: [(result: SourceProbeResult, lineFlag: String)] = []
            for (rawFlag, episode) in firstPerFlag {
                // ⛔ 写库键与显示键必须是**同一个归一化后的值**。
                // 上一版写库用原始 `flag`（"" 被 record 静默丢弃）、Cell 显示用
                // `flag.isEmpty ? "default" : flag`，于是同一条线路
                // 「界面上叫 default、缓存里根本没写」—— 而且 :469 的缓存查询
                // 查的是永远不会被写入的原始键，空 flag 线路的缓存命中率恒 0。
                let flag = rawFlag.isEmpty ? ProbePlanTarget.defaultFlag : rawFlag
                var result = cached[rawFlag]
                if result == nil {
                    do {
                        // 云盘 / 红果 / DASH 的虚拟流地址也能测：探针内部会解析成字节流。
                        // 不要在这里按 scheme 拦。
                        guard let target = await ProbePlanTarget.resolve(episode, client: client) else {
                            throw TVError.unsupported("no measurable line")
                        }
                        // 全局名额 + light 采样，理由同上。
                        guard await SourceProbeStore.shared.claimProbeSlot() else {
                            throw TVError.unsupported("probe slots busy")
                        }
                        let probed = await SourceProbeRunner.probe(url: target.url,
                                                                   headers: target.headers, light: true)
                        await SourceProbeStore.shared.releaseProbeSlot()
                        // 带 url 记，才能写进 base 表（同 host 跨剧复用，见 baseReading）。
                        if probed.reachability != .unknown {
                            await SourceProbeStore.shared.noteBasePublic(probed, url: target.url)
                        }
                        // ⛔ 逐条 `record` 每次都 persist()：全量重编码 probes 表
                        // （上限 4000 行）+ 写 UserDefaults，而且**全在主 actor 上**。
                        // 线级扫描最多 240 次 → 明显卡顿。上游代码自己写着这就是
                        // 「made the app look stuck」的成因，并为此加了批量口
                        // `record(_ rows:sourceKey:videoID:)`。这里攒到循环末尾一次写。
                        if probed.reachability != .unknown {
                            pendingWrites.append((probed, flag))
                        }
                        result = probed
                    } catch {
                        result = nil
                    }
                }
                cells.append(LineMatrix.Cell(sourceKey: candidate.sourceKey,
                                             sourceName: candidate.sourceName,
                                             videoID: candidate.video.id,
                                             flag: flag,
                                             result: result))
            }
            // 一次批量落盘 —— 本源的读数全在这里，写一遍就够。
            if !pendingWrites.isEmpty {
                await SourceProbeStore.shared.record(pendingWrites,
                                                     sourceKey: candidate.sourceKey,
                                                     videoID: candidate.video.id)
            }
            return cells
        } catch {
            return []
        }
    }
}
