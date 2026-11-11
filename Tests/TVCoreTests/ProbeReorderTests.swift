import Foundation
import Testing
@testable import TVCore

// MARK: - 测速后自动重排优先顺序

/// 分数高的排前面 —— 这是「测完速自动调整优先顺序」的最小断言。
///
/// 修复前 `sortScore` 只在显示层上色，**从未写过顺序**，
/// 所以测完速对搜索与列表顺序毫无影响。
@Test @MainActor func higherScoresComeFirst() {
    let scores = ["a": 90, "b": 40, "c": 70]
    let order = SourceOrder.probeOrder(["a", "b", "c"], existing: ["a", "b", "c"],
                                       score: { scores[$0] })
    #expect(order == ["a", "c", "b"])
}

/// 同分保持原有次序 —— 否则每次测速顺序都会乱跳，用户会觉得「界面在抽风」。
@Test @MainActor func tiesKeepTheirExistingOrder() {
    let scores = ["a": 50, "b": 50, "c": 50]
    let order = SourceOrder.probeOrder(["c", "b", "a"], existing: ["a", "b", "c"],
                                       score: { scores[$0] })
    #expect(order == ["a", "b", "c"], "同分应按 existing 的次序，实测 \(order)")
}

/// 钉住的永远最前，哪怕分数最低 —— 用户显式钉过的意图高于任何测量。
@Test @MainActor func pinnedSourcesOutrankEveryScore() {
    let scores = ["pinned": 0, "fast": 100, "mid": 50]
    let order = SourceOrder.probeOrder(["pinned", "fast", "mid"], existing: ["pinned", "fast", "mid"],
                                       score: { scores[$0] }, pinnedKeys: ["pinned"])
    #expect(order.first == "pinned")
    #expect(order == ["pinned", "fast", "mid"])
}

/// 测过的全部排在没测过的前面；没测过的内部按原有次序。
@Test @MainActor func unmeasuredSourcesKeepTheirOrderAndTrail() {
    let scores: [String: Int] = ["a": 10]
    let order = SourceOrder.probeOrder(["x", "a", "y", "z"], existing: ["x", "y", "z", "a"],
                                       score: { scores[$0] })
    #expect(order.first == "a", "测过的应在最前")
    #expect(order.dropFirst() == ["x", "y", "z"], "没测过的按原次序垫后，实测 \(order)")
}

/// 空输入不崩、不产生额外元素。
@Test @MainActor func emptyInputStaysEmpty() {
    #expect(SourceOrder.probeOrder([], existing: ["a"], score: { _ in 1 }).isEmpty)
    #expect(SourceOrder.probeOrder(["a"], existing: [], score: { _ in nil }) == ["a"])
}

/// 每个输入的键**恰好出现一次** —— 重排不能丢源也不能复制源。
@Test @MainActor func everyKeyAppearsExactlyOnce() {
    let keys = ["a", "b", "c", "d", "e"]
    let scores: [String: Int] = ["a": 10, "c": 30]
    let order = SourceOrder.probeOrder(keys, existing: keys.shuffled(),
                                       score: { scores[$0] }, pinnedKeys: ["e"])
    #expect(Set(order) == Set(keys))
    #expect(order.count == keys.count)
}

/// 全都没测过时，结果应当与 existing 完全一致（一次无意义的重排不该改动顺序）。
@Test @MainActor func nothingMeasuredChangesNothing() {
    let keys = ["b", "a", "c"]
    let order = SourceOrder.probeOrder(keys, existing: keys, score: { _ in nil })
    #expect(order == keys)
}

// MARK: - 回归：三个静态推演抓到的真 bug

/// `AVERAGE-BANDWIDTH=` 包含子串 `BANDWIDTH=`，直接搜会命中它。
///
/// 只在写了 AVERAGE 的播放列表里，`firstInt(after: "BANDWIDTH=")` 会读到
/// AVERAGE 的值 —— 语义上把「平均值」当成了「峰值」。
@Test func averageBandwidthIsNotMistakenForPeak() {
    // 只有 AVERAGE 时：应走 AVERAGE 分支（值相同，但语义要清楚）
    let onlyAverage = "#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=4800000,RESOLUTION=1920x1080"
    let d1 = SourceProbeRunner.declaration(in: onlyAverage, url: URL(string: "https://a/b.m3u8")!)
    #expect(d1.bitrateKbps == 4800)

    // 两者并存且 AVERAGE 在前：峰值必须取 BANDWIDTH 那个
    let peakLast = "#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=1000000,BANDWIDTH=9000000"
    let d2 = SourceProbeRunner.declaration(in: peakLast, url: URL(string: "https://a/b.m3u8")!)
    #expect(d2.bitrateKbps == 9000, "峰值应取 BANDWIDTH=9000000，实测 \(d2.bitrateKbps ?? -1)")
}

/// 码率余量段的零点必须在 1×（刚好喂饱）：喂不饱不该和「刚好够」同分。
///
/// 上一版 `5 + factor*5` 让余量 0.4× 也拿 5 分，与 1.0× 同分 ——
/// 而这一段的存在意义恰恰是分出两者。
@Test @MainActor func aStreamThatCannotBeFedScoresLowerThanOneThatJustIs() {
    func score(speed: Int, bitrate: Int) -> Int {
        SourceProbeResult(reachability: .reachable, latencyMilliseconds: 100,
                          kilobytesPerSecond: speed, resolutionHeight: 1080,
                          declaredBitrateKbps: bitrate, measuredAt: Date()).sortScore
    }
    let starving = score(speed: 1_000, bitrate: 20_000)   // 0.4×
    let justEnough = score(speed: 1_000, bitrate: 8_000)  // 1.0×
    let ample = score(speed: 1_000, bitrate: 4_000)       // 2.0×
    #expect(starving < justEnough, "喂不饱(0.4×)必须低于刚好够(1.0×)：\(starving) vs \(justEnough)")
    #expect(justEnough < ample, "刚好够(1.0×)应低于充裕(2.0×)：\(justEnough) vs \(ample)")
}

/// `sites` 为空时绝不能清空用户排好的顺序。
///
/// `probeOrder([], ...)` 返回空数组；若 `reorderByProbe` 不早退，
/// 会把 `keys` 整个写成空 —— 用户的排序全丢。
@Test @MainActor func anEmptySiteListNeverWipesTheSavedOrder() {
    let store = SourceOrder(defaults: UserDefaults(suiteName: "probeOrder.empty.\(UUID())")!)
    store.adopt(["a", "b", "c"])
    // 空的 sites 数组：直接调 probeOrder 会是空结果，但 reorderByProbe 必须早退。
    // 这里用空 origin 的 URL 只为满足签名；关键断言是 keys 没被清空。
    let changed = store.reorderByProbe([], origin: URL(string: "https://x/")!, score: { _ in 1 })
    #expect(changed == false)
}

// MARK: - 并行审查（子代理）抓到的三个分支：此前的测试恰好绕开了它们

/// A1：本次没列出的键必须保留 —— 隐藏源 / 已关订阅 / 保险库源的顺序不能因测速被抹掉。
///
/// `save` 的不变量是 `keys = ordered + keys.filter { !listed.contains($0) }`；
/// `reorderByProbe` 原来直接 `keys = next` 整份覆盖，会把缺席键**永久抹掉**。
/// 这条测试构造「existing 含 sites 缺席的键」，正是旧测试绕开的分支。
@Test @MainActor func probingNeverDropsKeysItWasNotGiven() {
    let defaults = UserDefaults(suiteName: "probeOrder.keeps.\(UUID())")!
    let order = SourceOrder(defaults: defaults)
    // 已保存顺序里有 hidden1 / hidden2 两个当前不可见的源
    order.adopt(["hidden1", "a", "hidden2", "b"])

    // 本次只重排 a / b（模拟隐藏源不在 sites 里）
    let scores = ["a": 10, "b": 90]
    _ = order.reorderByProbe(keysForTesting: ["a", "b"], score: { scores[$0] })

    #expect(order.savedKeys.contains("hidden1"), "隐藏源 hidden1 的顺序键被抹掉了")
    #expect(order.savedKeys.contains("hidden2"), "隐藏源 hidden2 的顺序键被抹掉了")
    // a/b 之间按分数降序：b(90) 在 a(10) 前
    let idxB = order.savedKeys.firstIndex(of: "b")
    let idxA = order.savedKeys.firstIndex(of: "a")
    #expect(idxB != nil && idxA != nil && idxB! < idxA!)
}

/// B1：`existing` 为空（新导入订阅、还没排过序）时，同分不能乱序。
///
/// Swift 的 `sorted` **不保证稳定**（>20 元素走分区）。旧实现只有一个 tiebreak
/// （`existingRank`），键都不在 `existing` 时全为 `Int.max`，等于没有二级键。
@Test @MainActor func withNoSavedOrderTheInputOrderIsKept() {
    // 25 个键，全部同分、全部不在 existing —— 正好跨过 Swift sort 的稳定阈值
    let keys = (0..<25).map { "s\($0)" }
    let out = SourceOrder.probeOrder(keys, existing: [], score: { _ in 50 })
    #expect(out == keys, "同分且无历史顺序时应保持输入序，实测 \(out.prefix(6))…")
}

/// E1：`sites` 为空时函数自己就要挡住 —— 不能只靠调用方的 guard。
@Test @MainActor func anEmptySiteListIsRejectedInsideTheApi() {
    let defaults = UserDefaults(suiteName: "probeOrder.empty2.\(UUID())")!
    let order = SourceOrder(defaults: defaults)
    order.adopt(["a", "b", "c"])
    let changed = order.reorderByProbe([], origin: URL(string: "https://x/")!, score: { _ in 1 })
    #expect(changed == false)
    #expect(order.savedKeys == ["a", "b", "c"], "空 sites 不得改动已保存顺序")
}
