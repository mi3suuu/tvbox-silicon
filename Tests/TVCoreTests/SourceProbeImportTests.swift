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
