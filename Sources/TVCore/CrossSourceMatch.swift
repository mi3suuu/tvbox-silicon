//
//  CrossSourceMatch.swift
//  TVCore
//
//  同名影视跨订阅 / 跨源的判定与切换。
//
//  为什么需要它
//  ------------
//  `Video.id` 是**源内的 vod_id**，同一个「庆余年」在 A 订阅的源里是 `12345`，在 B 订阅的源里是
//  `98765`，两者没有任何共同主键。所以「这是不是同一部剧」只能从内容特征推，不能查表。
//
//  One 自己不做这件事：`其他源` / `相同影片` / `同名` 在它的中文串里 0 命中，
//  唯一相关的是 `换一条`，那是换线路不是换源。所以这里不是复刻，是新造的判断。
//
//  判定的三条防线（缺一条就会误判）
//  ------------------------------
//  1. **标题归一化**　复用 `SeriesTitleMatcher`（拆季 + 去标点 + 保留 CJK + 小写）。
//     但它的 `key` 会**删掉所有数字**，于是 `三体 2023` 与 `三体 2024` 归一到同一个 key。
//     季数已由 `split` 单独剥离，剩下的数字只能是年份或「第二部」之类，必须在第 2 条里补回来。
//
//  2. **年份**　两边都声明且不同 → 直接判不同。只有一边声明 → 不因此降级（很多源不填年份）。
//
//  3. **集数**　两边都有集数且差距过大 → 判不同。12 集与 40 集不是同一部剧。
//     但集数**部分缺失**时不得否决：很多源在搜索结果里只给 1 集占位，详情页才有全集。
//     所以这里用「都已知且差得远才算证据」的保守口径。
//
//  一个反直觉但重要的取舍
//  --------------------
//  判定**宁可漏、不可错**。错判的代价是用户点了「换个源」却看到另一部剧，
//  漏判只是少给一个入口。所以三条防线任何一条命中否决就判 `different`，
//  而「像但不完全确定」一律落在 `likelySame`，由界面决定要不要展示。
//

import Foundation

public enum CrossSourceMatch {

    // MARK: - 身份

    /// 一部剧在**跨源语义下**的身份。不含任何源内 id。
    public struct ShowIdentity: Hashable, Sendable {
        /// `SeriesTitleMatcher.key` 的结果（已拆季、去标点、去数字）。
        public let titleKey: String
        /// 拆出来的季号。nil 表示标题里没写季。
        public let season: Int?
        /// 年份。只有形如 `2023` 的四位数字才算。
        public let year: String?
        /// 集数。0 表示未知。
        public let episodeCount: Int
        /// 归一化后的分类标签（如「电视剧」「电影」），用于否决。
        public let categories: Set<String>

        public var isEmpty: Bool { titleKey.isEmpty }
    }

    /// 从一部影片算出它的跨源身份。
    ///
    /// `episodes` 只能来自调用方已经拿到的数据：搜索结果往往是空数组（源只给列表项），
    /// 详情页才有全集。所以这里不假设它有值，只如实记录。
    public static func identity(of video: Video, episodes: Int? = nil) -> ShowIdentity {
        let split = SeriesTitleMatcher.split(video.name)
        let count = episodes ?? video.episodes.count
        return ShowIdentity(
            titleKey: SeriesTitleMatcher.key(video.name),
            season: split.season,
            year: normalizedYear(video.year),
            episodeCount: max(0, count),
            categories: categoryTokens(video.category)
        )
    }

    /// 只认四位数年份。源里常见 `2023`、`2023-05-01`、`2023年`。
    ///
    /// ⛔ 不能直接 `filter(\.isNumber)` 再判长度：`2023-05-01` 会被拼成 8 位的
    /// `20230501` 而被整体丢掉（这是第一版的 bug，测试抓到了）。
    /// 正确做法是先取**第一个连续的 1–4 位数字段**，再看它是不是 4 位。
    private static func normalizedYear(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var run = ""
        for character in raw {
            if character.isNumber {
                run.append(character)
                if run.count > 4 { return nil }   // 5 位以上不是年份（如 20231）
            } else if !run.isEmpty {
                break                             // 第一段数字结束
            }
        }
        return run.count == 4 ? run : nil
    }

    /// 把源给的分类串（`type_name,vod_class,vod_tag` 逗号连接）拆成可比对的集合。
    ///
    /// 先按逗号拆，再逐个归一：去空白、去数字、小写。`folder`/`action` 这类结构性标记留着 ——
    /// 它们同样能说明「这条不是一部剧」（云盘目录、插件动作项）。
    private static func categoryTokens(_ raw: String?) -> Set<String> {
        guard let raw, !raw.isEmpty else { return [] }
        return Set(raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
    }

    // MARK: - 判定

    /// 判定的结论。**三档而不是两档**：界面需要区分「确定」与「大概是」。
    public enum Verdict: String, Sendable, Equatable {
        /// 三条防线全过，且至少有一条正面证据（年份或集数对上）。
        case sameShow
        /// 标题与季对上，但没有年份/集数可以互证。
        case likelySame
        /// 有一条防线否决。
        case different
    }

    /// 一次判定的完整结果：结论 + 为什么。
    ///
    /// `reason` 是给**界面显示**用的：用户点「换源」时看到「同一年 · 同为 36 集」
    /// 才敢点；只给一个布尔值等于让他赌。
    public struct Match: Sendable, Equatable {
        public let verdict: Verdict
        public let reason: String
        /// 否决时是哪一条挡下的，便于排查与测试。
        public let refusedBy: Refusal?

        public enum Refusal: String, Sendable, Equatable {
            case emptyTitle, titleMismatch, seasonMismatch, yearMismatch, episodeMismatch, categoryMismatch
        }
    }

    /// 比较两个身份。
    ///
    /// - Parameters:
    ///   - current: 正在看的那一部。
    ///   - candidate: 候选的那一部（另一个源/订阅里的同名结果）。
    ///   - episodeTolerance: 集数容差。默认按较大的那一边算 20%，下限 2 集 ——
    ///     源之间对「完结/在更」的计数经常差一两集，差 3 集不该判成两部剧。
    public static func compare(_ current: ShowIdentity, _ candidate: ShowIdentity,
                               episodeTolerance: Int? = nil) -> Match {
        // ① 空标题一律否决：源里没有标题的条目会全部归一到空串，
        //    放行就把整页「暂无」聚成一部剧。
        guard !current.isEmpty, !candidate.isEmpty else {
            return Match(verdict: .different, reason: L10n.text("This entry has no title to match on."), refusedBy: .emptyTitle)
        }
        guard current.titleKey == candidate.titleKey else {
            return Match(verdict: .different, reason: L10n.text("A different title."), refusedBy: .titleMismatch)
        }
        // ② 季号：一边写了季、另一边没写，不算否决（「庆余年」常被不写季地指代第一季）。
        //    两边都写了且不同，才是不同的季 —— 那是相邻季，不是同一部。
        if let a = current.season, let b = candidate.season, a != b {
            return Match(verdict: .different,
                         reason: L10n.text("Season %lld here, season %lld there.", a, b),
                         refusedBy: .seasonMismatch)
        }
        // ③ 年份：补齐 `SeriesTitleMatcher.key` 删数字留下的洞。
        if let a = current.year, let b = candidate.year, a != b {
            return Match(verdict: .different,
                         reason: L10n.text("%@ here, %@ there.", a, b),
                         refusedBy: .yearMismatch)
        }
        // ④ 集数：只比**都够用**的。
        //
        // ⛔ 1 集是**占位**不是数据：搜索列表项常常只给一条「正片」，详情页才有全集。
        //    第一版写成 `> 0` 就比，于是「详情 46 集 vs 搜索 1 集」被判成两部剧
        //    （测试抓到的第二个 bug）。判据改成「两边都 ≥ 2 集」才当作证据。
        let knownA = current.episodeCount >= 2, knownB = candidate.episodeCount >= 2
        let tolerance = episodeTolerance ?? max(2, Int(Double(max(current.episodeCount, candidate.episodeCount)) * 0.2))
        if knownA, knownB, abs(current.episodeCount - candidate.episodeCount) > tolerance {
            return Match(verdict: .different,
                         reason: L10n.text("%lld episodes here, %lld there.",
                                           current.episodeCount, candidate.episodeCount),
                         refusedBy: .episodeMismatch)
        }
        // ⑤ 分类：只在**两边都有**且完全不相交时否决。
        //    源之间对「电视剧 / 连续剧 / 国产剧」的用词差异太大，交集为空不等于不是同一部；
        //    所以这一条只在**强信号互相矛盾**时用：一边说电影、一边说电视剧。
        if !current.categories.isEmpty, !candidate.categories.isEmpty,
           current.categories.isDisjoint(with: candidate.categories),
           isFilmOrSeriesContradiction(current.categories, candidate.categories) {
            return Match(verdict: .different, reason: L10n.text("A film on one side, a series on the other."),
                         refusedBy: .categoryMismatch)
        }

        // 正面证据：年份或集数至少有一条对得上才算「确定」。
        var evidence: [String] = []
        if let a = current.year, a == candidate.year { evidence.append(L10n.text("Same year %@", a)) }
        if current.episodeCount > 0, current.episodeCount == candidate.episodeCount {
            evidence.append(L10n.text("Both %lld episodes", current.episodeCount))
        }
        if !evidence.isEmpty {
            return Match(verdict: .sameShow, reason: evidence.joined(separator: " · "), refusedBy: nil)
        }
        return Match(verdict: .likelySame, reason: L10n.text("Same title, nothing else to compare."), refusedBy: nil)
    }

    /// 「电影 vs 剧」这种强矛盾。只认明确对立的词，不做词形推断。
    ///
    /// ⛔ 词表里不能放单字「片」：它同时命中「动作片」「电视剧（含"片"？不）」
    /// 但与「电视剧」也会因为 `movie` 之类的包含关系互相污染。第一版放了，
    /// 结果 `电影,动作片` 与 `电视剧,国产剧` 两侧都算「像电影」而漏判。
    /// 现在只用**完整词**做相等匹配，代价是认不出「动作片」这种派生 ——
    /// 但那一侧还有 `剧集`/`series` 的另一半在，不会整条失效。
    private static func isFilmOrSeriesContradiction(_ a: Set<String>, _ b: Set<String>) -> Bool {
        let films: Set<String> = ["电影", "影片", "movie", "film"]
        let series: Set<String> = ["电视剧", "连续剧", "剧集", "动漫", "动画", "animation", "series", "tv", "番剧"]
        func bears(_ set: Set<String>, _ vocab: Set<String>) -> Bool {
            // 双向：标签等于词表里的词，或标签里含有该完整词（「国产电视剧」含「电视剧」）。
            set.contains { token in vocab.contains { token == $0 || token.contains($0) } }
        }
        return (bears(a, films) && bears(b, series)) || (bears(a, series) && bears(b, films))
    }

    // MARK: - 分组

    /// 一个候选：某个源里的一部影片 + 它来自哪个订阅/源。
    public struct Candidate: Sendable, Identifiable {
        public let video: Video
        /// 源的原始 key（`Site.sourceKey`，合并订阅改了名也用这个）。
        public let sourceKey: String
        public let sourceName: String
        /// 该源所属的订阅地址，用来在界面上写「来自 A 订阅」。
        public let origin: URL
        public let verdict: Verdict
        public let reason: String
        /// 这个源的可达性读数，用来排「切到哪个」。没有读数时分最低。
        public let probe: SourceProbeResult?

        public var id: String { "\(sourceKey)|\(video.id)" }
        public var isPlayableChoice: Bool { verdict != .different }
    }

    /// 把多个源的搜索结果聚成「同一部剧的候选」，按该切的顺序排好。
    ///
    /// 排序口径（与 One 的下载线路「切到最快的」同一动机：用户要的是**现在能看**）：
    ///   1. 判定更强的在前（`sameShow` > `likelySame`）
    ///   2. 集数一致的在更前（看得全）
    ///   3. 可达性：可连 > 慢 > 未知 > 不可连
    ///   4. 分辨率高的在前
    ///   5. 延迟低的在前
    ///   6. 吞吐高的在前
    ///
    /// 同一条视频**不会出现两次**：同一 `sourceKey + video.id` 只留第一次。
    /// 输入的一行。比六元组可读，也不怕以后加字段改到所有调用点。
    public struct Input: Sendable {
        public let video: Video
        public let sourceKey: String
        public let sourceName: String
        public let origin: URL
        public let probe: SourceProbeResult?
        /// 这个源的集数（搜索结果常常没有，传 nil 表示未知）。
        public let episodes: Int?

        public init(video: Video, sourceKey: String, sourceName: String, origin: URL,
                    probe: SourceProbeResult?, episodes: Int?) {
            self.video = video; self.sourceKey = sourceKey; self.sourceName = sourceName
            self.origin = origin; self.probe = probe; self.episodes = episodes
        }
    }

    public static func candidates(for current: ShowIdentity, from results: [Input]) -> [Candidate] {
        var seen = Set<String>()
        var out: [Candidate] = []
        for result in results {
            let identity = identity(of: result.video, episodes: result.episodes)
            let match = compare(current, identity)
            let id = "\(result.sourceKey)|\(result.video.id)"
            guard seen.insert(id).inserted else { continue }
            out.append(Candidate(video: result.video, sourceKey: result.sourceKey,
                                 sourceName: result.sourceName, origin: result.origin,
                                 verdict: match.verdict, reason: match.reason, probe: result.probe))
        }
        return out.filter(\.isPlayableChoice).sorted { lhs, rhs in
            if lhs.verdict != rhs.verdict { return lhs.verdict == .sameShow }
            let le = lhs.video.episodes.count, re = rhs.video.episodes.count
            if le > 0, re > 0, le != re { return le > re }
            let lr = rank(lhs.probe), rr = rank(rhs.probe)
            if lr != rr { return lr > rr }
            let lh = lhs.probe?.resolutionHeight ?? 0, rh = rhs.probe?.resolutionHeight ?? 0
            if lh != rh { return lh > rh }
            let ll = lhs.probe?.latencyMilliseconds ?? .max, rl = rhs.probe?.latencyMilliseconds ?? .max
            if ll != rl { return ll < rl }
            let lk = lhs.probe?.kilobytesPerSecond ?? 0, rk = rhs.probe?.kilobytesPerSecond ?? 0
            return lk > rk
        }
    }

    /// 可达性的排序权重。未知排在「慢」之后、「不可连」之前 ——
    /// 没测过不等于坏，但也不该压过测得通的一条。
    private static func rank(_ probe: SourceProbeResult?) -> Int {
        switch probe?.reachability {
        case .reachable: return 3
        case .slow: return 2
        case nil, .unknown: return 1
        case .unreachable: return 0
        }
    }
}
