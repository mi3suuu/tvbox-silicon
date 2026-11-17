import Foundation
import Testing
@testable import TVCore

// MARK: - 手标区间

@Test func aHandMarkedRangeTakesTheTwoPointsExactly() throws {
    // 用户给的两个时间点就是两个时间点：算法不许往里塞猜测。
    let range = try #require(AdMarkRange.make(from: 32, to: 47.5, duration: 1800))
    #expect(range.start == 32)
    #expect(range.end == 47.5)
    #expect(range.length == 15.5)
    #expect(range.marked)
}

@Test func twoPointsGivenBackwardsAreSwappedRatherThanRejected() throws {
    // 用户先点终点再点起点是常见操作（暂停位置在广告开头之后）。
    let range = try #require(AdMarkRange.make(from: 47.5, to: 32, duration: 1800))
    #expect(range.start == 32)
    #expect(range.end == 47.5)
}

@Test func aHandMarkedRangeIsClampedToTheVideo() throws {
    let range = try #require(AdMarkRange.make(from: 1790, to: 2000, duration: 1800))
    #expect(range.start == 1790)
    #expect(range.end == 1800)
}

@Test func aHandMarkedRangeTooShortOrInvalidIsRefused() {
    // 两次点在同一秒附近 = 误触，不能入库（会把正片剪碎）。
    #expect(AdMarkRange.make(from: 30, to: 30, duration: 1800) == nil)
    #expect(AdMarkRange.make(from: 30, to: 31, duration: 1800) == nil)
    #expect(AdMarkRange.make(from: -1, to: 30, duration: 1800) == nil)
    #expect(AdMarkRange.make(from: .nan, to: 30, duration: 1800) == nil)
    // 整段都在片子之外。
    #expect(AdMarkRange.make(from: 1900, to: 1950, duration: 1800) == nil)
}

@Test func aNewMarkReplacesTheOverlappingOneInsteadOfStacking() throws {
    // 纠正一段标歪的广告：重叠即视为同一支的再标注，新标注胜。
    // 若不替换，`first(where: contains)` 会取到先入列的那条旧段，
    // 用户改了反而跳到更错的位置。
    let wrong = AdRange(start: 20, length: 30)
    let kept = AdRange(start: 200, length: 10)
    let corrected = try #require(AdMarkRange.make(from: 32, to: 47, duration: 1800))
    let merged = AdMarkRange.merging(corrected, into: [wrong, kept])
    #expect(merged.count == 2)
    #expect(!merged.contains(where: { $0.id == wrong.id }))
    #expect(merged.contains(where: { $0.id == kept.id }))
    #expect(merged.contains(where: { $0.id == corrected.id }))
    // 按起点排序，界面上的列表才和进度条顺序一致。
    #expect(merged.map(\.start) == merged.map(\.start).sorted())
}

@Test func adjacentRangesAreNotTreatedAsOverlapping() throws {
    // 前一段结束正好是后一段开始 = 两支相邻广告，不能互相吞掉。
    let first = AdRange(start: 10, length: 20)     // 10..30
    let second = try #require(AdMarkRange.make(from: 30, to: 45, duration: 1800))
    #expect(!first.overlaps(second))
    #expect(AdMarkRange.merging(second, into: [first]).count == 2)
}

@Test func aMarkedRangeSurvivesAnOlderSaveWithoutTheFlag() throws {
    // 老存档没有 `marked` 字段：必须解出来（缺省 false），否则整份设置解不出来。
    let legacy = Data(#"{"id":"11111111-1111-1111-1111-111111111111","start":30,"length":15}"#.utf8)
    let range = try JSONDecoder().decode(AdRange.self, from: legacy)
    #expect(range.start == 30)
    #expect(range.length == 15)
    #expect(!range.marked)
}

// MARK: - 广告段只认「广告拦截」开关

@Test func adsAreSkippedOnlyWhileAdBlockingIsOn() {
    // ⛔ 这条以前是错的：广告段挂在 `settings.enabled`（跳过片头片尾）上，
    // 于是「关掉广告拦截，手标段照样跳」和「没开跳过片头，广告段永远不跳」两种反向错同时存在。
    let settings = EpisodeSkipSettings(enabled: false, ads: [AdRange(start: 100, length: 20)])

    var on = EpisodeSkipPass()
    #expect(on.target(time: 105, duration: 1800, playing: true,
                      settings: settings, blocksAds: true) == 120)

    var off = EpisodeSkipPass()
    #expect(off.target(time: 105, duration: 1800, playing: true,
                       settings: settings, blocksAds: false) == nil)
}

@Test func introAndOutroStillNeedTheirOwnSwitch() {
    // 广告开关不能顺带把片头片尾也打开。
    let settings = EpisodeSkipSettings(enabled: false, introEnd: 90, outroLength: 120)
    var pass = EpisodeSkipPass()
    #expect(pass.target(time: 0, duration: 2700, playing: true,
                        settings: settings, blocksAds: true) == nil)
}

@Test func anAdAtTheVeryEndDoesNotSeekToWhereItAlreadyIs() {
    // 段尾 == 当前位置时返回原值会 seek 到原地 → 下一 tick 又命中 → 无限 seek。
    let settings = EpisodeSkipSettings(enabled: false, ads: [AdRange(start: 100, length: 20)])
    var pass = EpisodeSkipPass()
    #expect(pass.target(time: 120, duration: 1800, playing: true,
                        settings: settings, blocksAds: true) == nil)
}

@Test func anAdThatCouldNotBeSeekedIsRetriedOnTheNextTick() {
    // `handledAds` 在 `target()` 里就写入，但 seek 可能失败（未缓冲 / 越界）。
    // 不回滚就等于「第一次跳了、后面不跳了」。
    let ad = AdRange(start: 100, length: 20)
    let settings = EpisodeSkipSettings(enabled: false, ads: [ad])
    var pass = EpisodeSkipPass()
    #expect(pass.target(time: 105, duration: 1800, playing: true,
                        settings: settings, blocksAds: true) == 120)
    // seek 失败 → 回滚
    pass.rollbackPending()
    #expect(pass.target(time: 106, duration: 1800, playing: true,
                        settings: settings, blocksAds: true) == 120)
}

@Test func theSkippedAdIsReportedToTheInterface() throws {
    // 手标段被跳过时界面前此收不到任何东西（`lastSkippedAd` 只写不读）。
    let settings = EpisodeSkipSettings(enabled: false, ads: [AdRange(start: 100, length: 20)])
    var pass = EpisodeSkipPass()
    _ = pass.target(time: 105, duration: 1800, playing: true, settings: settings, blocksAds: true)
    // 先取出再断言：`takeSkippedAd` 是 mutating，不能塞进 `#require` 的宏展开里。
    let reported = pass.takeSkippedAd(settings: settings)
    #expect(reported?.start == 100)
    // 取过一次就清掉，同一个提示不会连弹。
    #expect(pass.takeSkippedAd(settings: settings) == nil)
}

@Test func applyingNewAdsClearsWhatWasAlreadyHandled() {
    // 用户刚标注 → `applySkipSettings` 重建 pass。验证重置真的清掉处理记录。
    let ad = AdRange(start: 100, length: 20)
    var pass = EpisodeSkipPass()
    let settings = EpisodeSkipSettings(enabled: false, ads: [ad])
    _ = pass.target(time: 105, duration: 1800, playing: true, settings: settings, blocksAds: true)
    pass.resetAds()
    #expect(pass.target(time: 105, duration: 1800, playing: true,
                        settings: settings, blocksAds: true) == 120)
}

// MARK: - 边界自适应（anchor 0 曾经永远失败）

/// 一支广告的一帧：与 `base` 只差几位 —— 同一支广告内部的正常波动。
private func adFrame(_ base: UInt64, _ step: Int) -> UInt64 { base ^ UInt64(step & 0xF) }

/// 一段正片的一帧：与 `base` 差 32 位（相似度 0.5 < 阈值 0.55），一定被认成别的内容。
private func filmFrame(_ base: UInt64, _ step: Int) -> UInt64 { (base ^ 0xFFFF_FFFF_0000_0000) ^ UInt64((step & 0xF) << 8) }

@Test func boundaryLocatingWorksWhenTheAnchorIsTheFirstFrame() throws {
    // ⛔ 这条以前必失败：模板只向回取，`anchor == 0` 时只有 1 格、被 `count >= 2` 挡掉。
    // 而 `resolveAndSkip` 传的正是 `anchor: 0` —— 那条路上这个函数从没成功过，
    // 每次都退回「命中点 + 广告总时长」，把正片开头切掉。
    let base: UInt64 = 0x0123_4567_89AB_CDEF
    let ad = (0..<20).map { adFrame(base, $0) }
    let film = (0..<20).map { filmFrame(base, $0) }
    let range = try #require(AdBoundary.locate(in: ad + film, anchor: 0))
    #expect(range.lowerBound == 0)
    #expect(range.upperBound == 19)
}

@Test func boundaryLocatingFindsBothEndsOfAMiddleAd() throws {
    let base: UInt64 = 0x0123_4567_89AB_CDEF
    let filmHead = (0..<30).map { filmFrame(base, $0) }
    let ad = (0..<15).map { adFrame(base, $0) }
    let filmTail = (0..<30).map { filmFrame(base, $0 + 1) }
    let range = try #require(AdBoundary.locate(in: filmHead + ad + filmTail, anchor: 30 + 7))
    // 不能把正片吃进来。
    #expect(range.lowerBound == 30)
    #expect(range.upperBound == 44)
}

@Test func aSingleUnrelatedFrameInsideAnAdDoesNotCutItInHalf() throws {
    // 广告里的转场/纯色卡用 1 秒采样时常整整一格不像。
    // 原来一帧不像就断，这类广告被切成两半 —— 用户看到「跳到一半又出广告」。
    let base: UInt64 = 0x0123_4567_89AB_CDEF
    var frames = (0..<6).map { adFrame(base, $0) }
    frames.append(filmFrame(base, 0))            // 完全不相关的一帧
    frames += (6..<12).map { adFrame(base, $0) }
    let range = try #require(AdBoundary.locate(in: frames, anchor: 3))
    // 索引 0–5 与 7–12 都是这支广告（索引 6 是那帧转场），整段必须连成一片。
    #expect(range.lowerBound == 0)
    #expect(range.upperBound == frames.count - 1)
}

@Test func boundaryLocatingRefusesInputItCannotWorkOn() {
    // 空序列 / 锚点越界：必须老实返回 nil，而不是给出一个编出来的区间。
    let film = (0..<40).map { filmFrame(0x0123_4567_89AB_CDEF, $0) }
    #expect(AdBoundary.locate(in: [], anchor: 0) == nil)
    #expect(AdBoundary.locate(in: film, anchor: 999) == nil)
    #expect(AdBoundary.locate(in: [UInt64(1)], anchor: 0) == nil)
}

// MARK: - 集级隔离（广告位置每集不同）

@Test func aMarkFromOneEpisodeDoesNotSkipInAnother() throws {
    // 第 1 集标的 30–45 秒，第 2 集同一位置是正片。
    // 不隔离就会把第 2 集正片剪掉 15 秒，而用户只标过第 1 集。
    let settings = EpisodeSkipSettings(enabled: false,
        ads: [AdRange(start: 30, end: 45, episode: "ep1")])
    var inEp1 = EpisodeSkipPass()
    #expect(inEp1.target(time: 32, duration: 1800, playing: true,
                         settings: settings, blocksAds: true, episode: "ep1") == 45)
    var inEp2 = EpisodeSkipPass()
    #expect(inEp2.target(time: 32, duration: 1800, playing: true,
                         settings: settings, blocksAds: true, episode: "ep2") == nil)
}

@Test func markingInOneEpisodeKeepsTheOtherEpisodesMarks() throws {
    // 在第 2 集标一段，不能把第 1 集那一段（时间重叠）删掉。
    let ep1 = AdRange(start: 30, length: 15, marked: true, episode: "ep1")
    let ep2 = try #require(AdMarkRange.make(from: 30, to: 45, duration: 1800))
    var second = ep2
    second.episode = "ep2"
    let merged = AdMarkRange.merging(second, into: [ep1])
    #expect(merged.count == 2)
    #expect(merged.contains { $0.id == ep1.id })
    #expect(merged.contains { $0.id == second.id })
}

@Test func aMarkSavedWithoutAnEpisodeStillAppliesEverywhere() throws {
    // 老存档 / 没有集概念的频道：不能因为升级把已标的段作废。
    let legacy = AdRange(start: 30, length: 15)
    #expect(legacy.episode == nil)
    #expect(legacy.applies(to: "ep1"))
    #expect(legacy.applies(to: nil))
    let settings = EpisodeSkipSettings(enabled: false, ads: [legacy])
    var pass = EpisodeSkipPass()
    #expect(pass.target(time: 32, duration: 1800, playing: true,
                        settings: settings, blocksAds: true, episode: "ep7") == 45)
}

@Test func theEpisodeIsPersistedThroughACodableRoundTrip() throws {
    let range = AdRange(start: 30, end: 45, episode: "ep3")
    let data = try JSONEncoder().encode(range)
    let back = try JSONDecoder().decode(AdRange.self, from: data)
    #expect(back.episode == "ep3")
    #expect(back.marked)
    #expect(back.start == 30)
}
