import Foundation
import Testing
@testable import TVCore

/// 跨源同名判定。
///
/// 这套判定的价值全在**边界**上：正例（同一部剧）好写，真正会咬人的是
/// 「三体 2023 vs 三体 2024」「庆余年 vs 庆余年 第二季」「搜索结果只给 1 集占位」
/// 这几类。所以下面每个测试都对着一条具体的误判风险。

private func video(_ name: String, year: String? = nil, episodes: Int = 0, category: String? = nil) -> Video {
    let list = (0..<episodes).map { Episode(id: "0-\($0)", name: "第\($0 + 1)集", address: "https://x/\($0)", flag: "m3u8", videoID: "v") }
    return Video(id: "v", name: name, year: year, episodes: list, category: category)
}

private func identity(_ name: String, year: String? = nil, episodes: Int = 0, category: String? = nil) -> CrossSourceMatch.ShowIdentity {
    CrossSourceMatch.identity(of: video(name, year: year, episodes: episodes, category: category))
}

// MARK: - 正例

@Test func theSameTitleInTwoSourcesIsTheSameShow() {
    let a = identity("庆余年", year: "2019", episodes: 46)
    let b = identity("庆余年", year: "2019", episodes: 46)
    let match = CrossSourceMatch.compare(a, b)
    #expect(match.verdict == .sameShow)
    #expect(match.reason.contains("2019"))
}

@Test func punctuationAndSpacingDoNotSplitATitle() {
    let a = identity("庆余年 · 第一季")
    let b = identity("庆余年第一季")
    #expect(CrossSourceMatch.compare(a, b).verdict != .different)
}

// MARK: - 年份（`SeriesTitleMatcher.key` 删数字留下的洞）

/// 关键回归：`key` 会把数字全删掉，所以 `三体 2023` 与 `三体 2024` 归一到同一个 key。
/// 年份必须由这里补回来，否则两部完全不同的剧会被判成同一部。
@Test func twoDifferentYearsAreNotTheSameShow() {
    let a = identity("三体", year: "2023", episodes: 30)
    let b = identity("三体", year: "2024", episodes: 30)
    let match = CrossSourceMatch.compare(a, b)
    #expect(match.verdict == .different)
    #expect(match.refusedBy == .yearMismatch)
}

/// 只有一边写了年份时不得否决：很多源根本不填年份。
@Test func aMissingYearNeverRefuses() {
    let a = identity("三体", year: "2023", episodes: 30)
    let b = identity("三体")
    #expect(CrossSourceMatch.compare(a, b).verdict != .different)
}

/// 年份只认四位。`2023-05-01` / `2023年` 也认，`23` / `20231` 不认。
@Test func onlyFourDigitYearsCount() {
    #expect(identity("x", year: "2023-05-01").year == "2023")
    #expect(identity("x", year: "2023年").year == "2023")
    #expect(identity("x", year: "23").year == nil)
    #expect(identity("x", year: "20231").year == nil)
}

// MARK: - 季

/// 相邻季是两部不同的剧：`庆余年` 与 `庆余年 第二季` 不能互相「换源」，
/// 否则用户点换源会直接跳到下一季第一集。
@Test func adjacentSeasonsAreDifferentShows() {
    let a = identity("庆余年 第一季", episodes: 46)
    let b = identity("庆余年 第二季", episodes: 36)
    let match = CrossSourceMatch.compare(a, b)
    #expect(match.verdict == .different)
    #expect(match.refusedBy == .seasonMismatch)
}

/// 但一边不写季时放行：「庆余年」通常就指第一季。
@Test func anUnstatedSeasonDoesNotRefuse() {
    let a = identity("庆余年", episodes: 46)
    let b = identity("庆余年 第一季", episodes: 46)
    #expect(CrossSourceMatch.compare(a, b).verdict != .different)
}

// MARK: - 集数

/// 12 集与 40 集不是同一部剧。
@Test func wildlyDifferentEpisodeCountsRefuse() {
    let a = identity("某剧", episodes: 12)
    let b = identity("某剧", episodes: 40)
    let match = CrossSourceMatch.compare(a, b)
    #expect(match.verdict == .different)
    #expect(match.refusedBy == .episodeMismatch)
}

/// 差一两集是源之间对「完结/在更」的正常分歧，不能判成两部。
@Test func aCoupleOfEpisodesOfDriftIsTolerated() {
    #expect(CrossSourceMatch.compare(identity("某剧", episodes: 36), identity("某剧", episodes: 38)).verdict != .different)
}

/// 搜索结果的 1 集是占位，不能否决。这条防的是「详情页有 46 集、搜索里只有 1 集」时被判成两部。
@Test func aPlaceholderEpisodeCountIsNotEvidence() {
    let detail = identity("庆余年", episodes: 46)
    let search = identity("庆余年", episodes: 1)
    let match = CrossSourceMatch.compare(detail, search)
    #expect(match.verdict != .different)
    // 一条正面证据都没有时落到 likelySame，而不是谎称 sameShow。
    #expect(match.verdict == .likelySame)
}

// MARK: - 分类

/// 一边电影一边电视剧，是强矛盾。
@Test func aFilmAgainstASeriesRefuses() {
    let a = identity("某作", episodes: 1, category: "电影,动作片")
    let b = identity("某作", episodes: 30, category: "电视剧,国产剧")
    let match = CrossSourceMatch.compare(a, b)
    #expect(match.verdict == .different)
    #expect(match.refusedBy == .categoryMismatch)
}

/// 只是用词不同（电视剧 / 连续剧）不算矛盾。
@Test func differentWordingForTheSameKindIsNotAContradiction() {
    let a = identity("某剧", episodes: 30, category: "电视剧,国产剧")
    let b = identity("某剧", episodes: 30, category: "连续剧,大陆剧")
    #expect(CrossSourceMatch.compare(a, b).verdict != .different)
}

// MARK: - 空标题

/// 源里没标题的条目会全归一到空串；放行就把整页「暂无」聚成一部剧。
@Test func anEmptyTitleNeverMatches() {
    let empty = CrossSourceMatch.ShowIdentity(titleKey: "", season: nil, year: nil, episodeCount: 0, categories: [])
    #expect(CrossSourceMatch.compare(empty, identity("庆余年")).verdict == .different)
    #expect(CrossSourceMatch.compare(identity("庆余年"), empty).verdict == .different)
}

// MARK: - 候选排序

private func probe(_ reach: SourceProbeResult.Reachability, height: Int? = nil,
                   latency: Int? = nil) -> SourceProbeResult {
    SourceProbeResult(reachability: reach, latencyMilliseconds: latency, kilobytesPerSecond: nil,
                      resolutionHeight: height, resolutionLabel: nil, measuredAt: Date())
}

@Test func candidatesDropDifferentShowsAndRankByReachability() {
    let current = identity("庆余年", year: "2019", episodes: 46)
    let rows: [CrossSourceMatch.Input] = [
        CrossSourceMatch.Input(video: video("庆余年", year: "2019", episodes: 46), sourceKey: "dead", sourceName: "死源", origin: URL(string: "https://a")!, probe: probe(.unreachable), episodes: nil),
        CrossSourceMatch.Input(video: video("庆余年", year: "2019", episodes: 46), sourceKey: "fast", sourceName: "快源", origin: URL(string: "https://b")!, probe: probe(.reachable, height: 1080), episodes: nil),
        CrossSourceMatch.Input(video: video("另一部剧", year: "2019"), sourceKey: "other", sourceName: "别的剧", origin: URL(string: "https://c")!, probe: probe(.reachable), episodes: nil),
        CrossSourceMatch.Input(video: video("庆余年", year: "2019", episodes: 46), sourceKey: "fast", sourceName: "快源", origin: URL(string: "https://b")!, probe: probe(.reachable), episodes: nil),
    ]
    let ranked = CrossSourceMatch.candidates(for: current, from: rows)
    // 不同剧被剔除。
    #expect(!ranked.contains { $0.sourceKey == "other" })
    // 同一 sourceKey+id 只留一次。
    #expect(ranked.filter { $0.sourceKey == "fast" }.count == 1)
    // 可连的排在不可连的前面。
    #expect(ranked.first?.sourceKey == "fast")
    #expect(ranked.last?.sourceKey == "dead")
}

@Test func anUnprobedSourceRanksBetweenSlowAndUnreachable() {
    let current = identity("某剧", episodes: 10)
    let rows: [CrossSourceMatch.Input] = [
        CrossSourceMatch.Input(video: video("某剧", episodes: 10), sourceKey: "unknown", sourceName: "没测过", origin: URL(string: "https://a")!, probe: nil, episodes: nil),
        CrossSourceMatch.Input(video: video("某剧", episodes: 10), sourceKey: "slow", sourceName: "慢", origin: URL(string: "https://b")!, probe: probe(.slow), episodes: nil),
        CrossSourceMatch.Input(video: video("某剧", episodes: 10), sourceKey: "dead", sourceName: "死", origin: URL(string: "https://c")!, probe: probe(.unreachable), episodes: nil),
    ]
    let ranked = CrossSourceMatch.candidates(for: current, from: rows).map(\.sourceKey)
    #expect(ranked == ["slow", "unknown", "dead"])
}
