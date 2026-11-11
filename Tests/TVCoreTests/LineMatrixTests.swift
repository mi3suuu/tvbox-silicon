import Foundation
import Testing
@testable import TVCore

/// 造一个读数。默认「通、有速度、有延迟」，按需覆盖。
private func result(_ reach: SourceProbeResult.Reachability = .reachable,
                    kbps: Int? = 1_000,
                    ms: Int? = 100,
                    height: Int? = 1080) -> SourceProbeResult {
    SourceProbeResult(reachability: reach, latencyMilliseconds: ms,
                      kilobytesPerSecond: kbps, resolutionHeight: height,
                      resolutionLabel: height.map { "\($0)P" }, measuredAt: Date())
}

private func cell(_ src: String, _ flag: String, _ r: SourceProbeResult?) -> LineMatrix.Cell {
    LineMatrix.Cell(sourceKey: src, sourceName: src.uppercased(), flag: flag, result: r)
}

// MARK: - 择优口径

/// 吞吐优先于延迟：40ms 但 80KB/s 的线不该赢过 120ms 但 3MB/s 的线。
///
/// 这是换源的真实动机 —— 用户在意"卡不卡"，不是"握手快不快"。
/// 旧实现按延迟挑，会稳定挑中前者。
@Test func throughputBeatsLatency() {
    let fast = cell("a", "1", result(kbps: 3_000, ms: 120))
    let snappy = cell("b", "1", result(kbps: 80, ms: 40))
    #expect(LineMatrix.better(fast, snappy), "3MB/s 应胜过 80KB/s，即使后者延迟更低")
    #expect(!LineMatrix.better(snappy, fast))
}

/// 可播 > 慢 > 未测 > 不可连。
@Test func reachabilityOutranksEverything() {
    let good = cell("a", "1", result(.reachable, kbps: 10))
    let slow = cell("b", "1", result(.slow, kbps: 99_999))
    let unknown = cell("c", "1", result(.unknown))
    let dead = cell("d", "1", result(.unreachable))
    #expect(LineMatrix.better(good, slow), "通但慢速也应胜过 slow")
    #expect(LineMatrix.better(slow, unknown), "slow 应胜过未测")
    #expect(LineMatrix.better(unknown, dead), "未测应胜过不可连")
    // 未测不等于坏，但绝不能压过测通的。
    #expect(!LineMatrix.better(unknown, good))
}

/// 未测（nil）永远排在测过的后面 —— 没测过≠能用。
@Test func unmeasuredIsNeverUsable() {
    let measured = cell("a", "1", result())
    let unmeasured = cell("b", "1", nil)
    #expect(measured.isUsable)
    #expect(!unmeasured.isUsable)
    #expect(LineMatrix.better(measured, unmeasured))
}

/// 「不可连」不算可播 —— 否则换源会推荐一条死线。
@Test func unreachableIsNotUsable() {
    #expect(!cell("a", "1", result(.unreachable)).isUsable)
    #expect(cell("a", "1", result(.slow)).isUsable)
}

// MARK: - 分组与行

/// 按源分组、源内按线路名排序。
@Test func cellsGroupBySourceAndSortByFlag() {
    let rows = LineMatrix.build([
        cell("b", "2", result()), cell("b", "1", result()),
        cell("a", "1", result()),
    ])
    #expect(rows.count == 2)
    let b = try? #require(rows.first { $0.sourceKey == "b" })
    #expect(b?.cells.map(\.flag) == ["1", "2"], "源内线路应按名字排序")
}

/// 有可播线的源排在没有的前面 —— 换源只关心能用的。
@Test func rowsWithUsableCellsComeFirst() {
    let rows = LineMatrix.build([
        cell("dead", "1", result(.unreachable)),
        cell("alive", "1", result(kbps: 100)),
    ])
    #expect(rows.first?.sourceKey == "alive")
}

/// 全测不了时按名字稳定排序，刷新不跳。
@Test func allDeadRowsAreStableByName() {
    let a = LineMatrix.build([cell("z", "1", result(.unreachable)),
                              cell("a", "1", result(.unreachable))])
    let b = LineMatrix.build([cell("a", "1", result(.unreachable)),
                              cell("z", "1", result(.unreachable))])
    #expect(a.map(\.sourceKey) == b.map(\.sourceKey))
    #expect(a.map(\.sourceKey) == ["a", "z"])
}

/// `overallBest` 跨源挑出全局最优的一格 —— 「一键切到最快」的答案。
@Test func overallBestSpansEverySourceAndLine() {
    let rows = LineMatrix.build([
        cell("a", "1", result(kbps: 500, ms: 30)),
        cell("a", "2", result(kbps: 900, ms: 200)),
        cell("b", "1", result(kbps: 4_000, ms: 150)),
        cell("c", "1", result(.unreachable)),
    ])
    let best = LineMatrix.overallBest(rows)
    #expect(best?.sourceKey == "b")
    #expect(best?.flag == "1")
}

/// 没有可播格时 `overallBest` 返回 nil，而不是随便挑一个。
@Test func overallBestIsNilWhenNothingWorks() {
    let rows = LineMatrix.build([cell("a", "1", result(.unreachable)),
                                 cell("b", "1", nil)])
    #expect(LineMatrix.overallBest(rows) == nil)
}

/// `Row.best` 只在可播格里挑，速度优先。
@Test func rowBestPicksFastestUsableLine() {
    let rows = LineMatrix.build([
        cell("a", "1", result(kbps: 100, ms: 10)),
        cell("a", "2", result(kbps: 2_000, ms: 300)),
        cell("a", "3", result(.unreachable)),
    ])
    #expect(rows.first?.best?.flag == "2")
    #expect(rows.first?.usableCount == 2, "不可连那条不算可用")
}

// MARK: - 并行审查（子代理 B1/B2/C1）抓到：跨行排序此前 100% 无覆盖

/// B1：行必须**快的在前**。
///
/// 旧实现方向反了：`better(rb,lb) → return true` 让更差的那行排前面。
/// 源名刻意让慢的那条更靠前（"aaa" < "zzz"），以排除名字兜底的干扰。
@Test func rowsAreOrderedFastestFirst() {
    let rows = LineMatrix.build([
        cell("zzz", "1", result(kbps: 4_000)),
        cell("aaa", "1", result(kbps: 900)),
    ])
    #expect(rows.map(\.sourceKey) == ["zzz", "aaa"],
            "4000KB/s 必须排在 900KB/s 前，与源名无关；实测 \(rows.map(\.sourceKey))")
}

/// B2：比较器必须是严格弱序 —— 同一份输入连排多次结果必须一致。
///
/// 旧实现缺 `return false`，落到名字兜底后「A 更好且 A 名字更靠前」时双向都返回 true，
/// 排序结果取决于 `Dictionary(grouping:)` 的随机迭代序 → 面板每次刷新都重排。
@Test func theRowOrderIsDeterministic() {
    let cells = [
        cell("Aurora", "1", result(kbps: 4_000)),
        cell("Borealis", "1", result(kbps: 900)),
        cell("Cobalt", "1", result(kbps: 3_000)),
        cell("Delta", "1", result(kbps: 100)),
        cell("Ember", "1", result(kbps: 2_500)),
        cell("Falcon", "1", result(kbps: 500)),
    ]
    let first = LineMatrix.build(cells).map(\.sourceKey)
    // 同一进程内多次调用：旧实现在这里就会给出不同结果
    for _ in 0..<20 {
        #expect(LineMatrix.build(cells).map(\.sourceKey) == first,
                "同样输入必须给出同样顺序，实测 \(LineMatrix.build(cells).map(\.sourceKey)) vs \(first)")
    }
    // 期望顺序：按吞吐降序
    #expect(first == ["Aurora", "Cobalt", "Ember", "Borealis", "Falcon", "Delta"],
            "应按吞吐降序，实测 \(first)")
}

/// B2 补充：全并列时用 sourceKey 兜底，保证全序（不留不稳定排序的空隙）。
@Test func fullyTiedRowsFallBackToTheSourceKey() {
    let tied = (0..<8).map { cell("s\($0)", "1", result(kbps: 1_000, ms: 100, height: 1080)) }
    let first = LineMatrix.build(tied).map(\.sourceKey)
    #expect(first == first.sorted(), "全并列时应按 sourceKey 升序，实测 \(first)")
    #expect(LineMatrix.build(tied.reversed()).map(\.sourceKey) == first,
            "输入顺序不应影响全并列的排序结果")
}

/// C1：同一源同一线路被传入两次时，不能产生重复 id（否则 ForEach 崩/串行）。
///
/// 真实路径：调用方用原始 flag 建 firstPerFlag 字典，建 Cell 时才把空串归一成 "default"，
/// 于是同源同时有 `""` 与 `"default"` 时两格 id 相同。
@Test func duplicateCellIdsAreCollapsed() {
    let rows = LineMatrix.build([
        cell("a", "default", result(kbps: 100)),
        cell("a", "default", result(kbps: 200)),
    ])
    let ids = rows.flatMap { $0.cells.map(\.id) }
    #expect(ids.count == Set(ids).count, "Cell id 必须唯一，实测 \(ids)")
    #expect(ids.count == 1, "重复项应折叠成一格")
}
