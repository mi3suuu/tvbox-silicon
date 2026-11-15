import Foundation
import Testing
@testable import TVCore

/// 外部配置里夹带的测速读数。
///
/// 这些断言全部来自实测数据（`yingxia-unified-20261110-ranked.json`）：
/// 38 条读数**没有一条**满足 `mbps == KB/s × 8 / 1024`，比值 0.12–1.87。
/// 所以导入层的主要工作不是「把数字读进来」，而是**判断哪个数字不能用**。

private func raw(_ fields: [String: JSONValue]) -> [String: JSONValue] { fields }

// MARK: - 核心：两个速度字段矛盾

/// 两个速度字段都给 → 一个都不采信，只判可达性。
///
/// 这是本模块存在的唯一理由。挑其中一个等于在无依据的情况下替用户决定信谁，
/// 而实测里两个数差过 8 倍的源不在少数。
@Test func twoDisagreeingSpeedFieldsAreBothDiscarded() {
    let reading = SourceProbeImport.reading(from: raw([
        "_route": .string("现状"),
        "_speedKBps": .number(299.2),
        "_mbps": .number(0.92),
        "_quality": .string("1920x1080"),
    ]))
    let r = try! #require(reading)
    #expect(r.kilobytesPerSecond == nil)
    #expect(r.declaredConflicted == true)
    #expect(r.confidence == .conflicted)
    // 但可达性与分辨率照常保留 —— 那是两个字段都不矛盾的证据。
    #expect(r.reachability == .reachable)
    #expect(r.resolutionHeight == 1080)
}

/// 只有一个速度字段时用它，并把 Mbps 换算成 KB/s。
@Test func aSingleSpeedFieldIsUsedAndConverted() {
    let kbpsOnly = SourceProbeImport.reading(from: raw([
        "_route": .string("直连"), "_speedKBps": .number(480),
    ]))
    #expect(kbpsOnly?.kilobytesPerSecond == 480)
    #expect(kbpsOnly?.declaredConflicted == false)
    #expect(kbpsOnly?.confidence == .measured)

    let mbpsOnly = SourceProbeImport.reading(from: raw([
        "_route": .string("直连"), "_mbps": .number(8),
    ]))
    // 8 Mbps = 8 × 1024 / 8 = 1024 KB/s
    #expect(mbpsOnly?.kilobytesPerSecond == 1_024)
    #expect(mbpsOnly?.declaredConflicted == false)
}

// MARK: - 可达性

/// `_route == "不通"` 是确定的负结论，比任何速度都强。
/// 实测有源同时标着 0 KB/s 和 720x1280 的画质，只有 route 能裁决。
@Test func anExplicitFailureRouteWinsOverAnyNumbers() {
    let r = try! #require(SourceProbeImport.reading(from: raw([
        "_route": .string("不通"),
        "_speedKBps": .number(0),
        "_quality": .string("720x1280"),
        "_note": .string("2026-11-10 实测：列表/播放均失败"),
    ])))
    #expect(r.reachability == .unreachable)
    #expect(r.sortScore == 0)
}

@Test func aWorkingRouteIsReachable() {
    for route in ["直连", "代理", "现状"] {
        let r = SourceProbeImport.reading(from: raw(["_route": .string(route)]))
        #expect(r?.reachability == .reachable)
    }
}

/// 没有 route 但有速度数字：数字本身证明它连上过。
@Test func numbersWithoutARouteStillProveItConnected() {
    let r = SourceProbeImport.reading(from: raw(["_speedKBps": .number(120)]))
    #expect(r?.reachability == .reachable)
}

// MARK: - 分辨率

/// 竖屏转码 `720x1280` 必须读成 720p，不是 720 —— 取短边。
@Test func aPortraitQualityStringReadsAsItsShortSide() {
    #expect(SourceProbeImport.reading(from: raw(["_quality": .string("720x1280")]))?.resolutionHeight == 720)
    #expect(SourceProbeImport.reading(from: raw(["_quality": .string("1920x1080")]))?.resolutionHeight == 1080)
    #expect(SourceProbeImport.reading(from: raw(["_quality": .string("1080x606")]))?.resolutionHeight == 606)
}

@Test func aMalformedQualityStringIsIgnoredNotGuessed() {
    #expect(SourceProbeImport.reading(from: raw(["_quality": .string("1080P")]))?.resolutionHeight == nil)
    #expect(SourceProbeImport.reading(from: raw(["_quality": .string("")]))?.resolutionHeight == nil)
}

// MARK: - 缺席

/// 完全没有 `_` 字段 → 不造读数。返回一条假读数会让「未测」的源
/// 混进「已测」的统计里，用户看到的覆盖率就是假的。
@Test func aSourceWithNoProbeFieldsYieldsNothing() {
    #expect(SourceProbeImport.reading(from: raw(["key": .string("x"), "api": .string("https://a")])) == nil)
}

/// 外部配置不带延迟，不许编一个。
@Test func importedReadingsNeverInventALatency() {
    let r = SourceProbeImport.reading(from: raw([
        "_route": .string("直连"), "_speedKBps": .number(300), "_quality": .string("1920x1080"),
    ]))
    #expect(r?.latencyMilliseconds == nil)
}

// MARK: - 与排序的衔接

/// 矛盾读数在排序里必须低于同规格的可信读数。
@Test func aConflictedImportRanksBelowAnEquivalentMeasuredSource() {
    let imported = try! #require(SourceProbeImport.reading(from: raw([
        "_route": .string("现状"),
        "_speedKBps": .number(480),
        "_mbps": .number(1.0),
        "_quality": .string("1920x1080"),
    ])))
    let measured = SourceProbeResult(reachability: .reachable, latencyMilliseconds: 90,
                                     kilobytesPerSecond: 480, resolutionHeight: 1080,
                                     resolutionLabel: "1080P", measuredAt: Date())
    #expect(imported.sortScore < measured.sortScore)
}

// MARK: - 来源与时间

/// 包内读数一律带 `declared`：它决定「真测能不能被覆盖」与「算不算刚测过」。
@Test func importedReadingsAreMarkedAsDeclared() {
    let r = SourceProbeImport.reading(from: raw(["_route": .string("直连"), "_speedKBps": .number(480)]))
    #expect(r?.declared == true)
    // 自己测的读数没有这个标记 —— 它是「这台设备量的」。
    #expect(SourceProbeResult(reachability: .reachable).declared == nil)
}

/// 时间戳必须来自数据。
///
/// 旧实现默认 `measuredAt: Date()`，于是每次刷新订阅都给每个源盖一个「此刻」：
/// 用户昨天真测的 `unreachable` 被包里的粗标签按时间压掉，而「刚装完测一遍」在十分钟内
/// 又会因为读数「太新」而全部跳过。两头都反了。
@Test func theDateComesFromTheDataNotFromNow() {
    // 源自己写着哪天量的（打包脚本的 `_probe.at`）。
    let probed = SourceProbeImport.reading(from: raw([
        "_route": .string("直连"), "_speedKBps": .number(480),
        "_probe": .object(["verdict": .string("direct"), "kbps": .number(480), "at": .string("2026-11-11")]),
    ]))
    let expected = try! #require(SourceProbeImport.parseDay("2026-11-11"))
    #expect(probed?.measuredAt == expected)

    // 只有 `_note` 里带日期也认。
    let noted = SourceProbeImport.reading(from: raw([
        "_route": .string("直连"), "_note": .string("2026-11-11 实测可播 · 1280x720"),
    ]))
    #expect(noted?.measuredAt == expected)

    // 两样都没有 → 用调用方给的订阅导入时间。
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    let fallback = SourceProbeImport.reading(from: raw(["_route": .string("直连")]), measuredAt: stamp)
    #expect(fallback?.measuredAt == stamp)

    // 连调用方都没给 → 「很久以前」，绝不是「现在」。
    let bare = SourceProbeImport.reading(from: raw(["_route": .string("直连")]))
    #expect(bare?.measuredAt == .distantPast)
}

/// `parseDay` 只认真正的日期前缀，别把备注文本硬读成日期。
@Test func dayParsingIsStrict() {
    #expect(SourceProbeImport.parseDay("2026-11-11") != nil)
    #expect(SourceProbeImport.parseDay("2026-11-11 实测") != nil)
    #expect(SourceProbeImport.parseDay("源扩搜（旧公共中转站）") == nil)
    #expect(SourceProbeImport.parseDay("2026-13-40") == nil)
    #expect(SourceProbeImport.parseDay("") == nil)
    // 同一天里带不带时间都是同一个瞬间：否则「谁更新」会因为时区差一天而翻面。
    #expect(SourceProbeImport.parseDay("2026-11-11") == SourceProbeImport.parseDay("2026-11-11 23:59"))
}
