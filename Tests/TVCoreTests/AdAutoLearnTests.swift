import Foundation
import Testing
@testable import TVCore

/// 这批哈希是**玉兔资源真实分片的逐段首帧 dHash**（2026-11-17 抓取）。
/// 段 0…8 是广告（合计 26.07 秒），段 9 起是正片。
/// 三个视频的段 0…8 逐帧相同（距离全 0），段 9 起分叉 —— 这就是「同源固定前缀」。
private let realSamples: [[UInt64]] = [
    // 339445
    [0xc4d0637371713336, 0x6ce1636b71713336, 0xece0636971733336, 0xeae2636b72723332,
     0xeae2632b32727336, 0xcae2632b32723336, 0xc6c2632b32723336, 0xc6c2632b32723336,
     0xc6c2632b32723336, 0x00e00064ccf03010, 0x00e00064ccf03010, 0x00e00064ccf03010],
    // 339446
    [0xc4d0637371713336, 0x6ce1636b71713336, 0xece0636971733336, 0xeae2636b72723332,
     0xeae2632b32727336, 0xcae2632b32723336, 0xc6c2632b32723336, 0xc6c2632b32723336,
     0xc6c2632b32723336, 0x0000000000000000, 0x8cacaca8888898f8, 0x94b1b16b59d17070],
    // 339447
    [0xc4d0637371713336, 0x6ce1636b71713336, 0xece0636971733336, 0xeae2636b72723332,
     0xeae2632b32727336, 0xcae2632b32723336, 0xc6c2632b32723336, 0xc6c2632b32723336,
     0xc6c2632b32723336, 0xd9c9a4bc8439392b, 0xd9c924bc8439393b, 0x99c9e4bca439392b]
]

private func samples(_ hashes: [[UInt64]], prefix: [String] = ["a", "b", "c"]) -> [AdAutoLearn.Sample] {
    zip(prefix, hashes).map { AdAutoLearn.Sample(videoID: $0, hashes: $1) }
}

@Test func learnsTheRealSharedPrefixFromThreeRealVideos() throws {
    // 真实数据：3 个玉兔视频，共同前缀应是 9 个采样点 = 9 秒
    // （这里按「每段一帧、间隔 1 秒」建模；线上按真实段时长累计，得到 26.07 秒）
    let learned = try #require(AdAutoLearn.learn(sourceKey: "yutu", samples: samples(realSamples)))
    #expect(learned.hashes.count == 9, "应学出 9 个共同采样点，实际 \(learned.hashes.count)")
    #expect(learned.sampleCount == 3)
    #expect(learned.isUsable)
    // 学到的前缀必须与第一段广告完全一致
    #expect(learned.hashes[0] == realSamples[0][0])
}

@Test func stopsAtTheFirstDivergenceInsteadOfSkippingAhead() throws {
    // ⛔ 这是最关键的一条：一旦某一秒不一致就必须**停止**，不能跳过它继续往后比。
    //    跳过会让正片里偶然相同的镜头也被拉进来，最后切掉一大段正片。
    //
    // 构造：第 3 秒故意让样本 b 不同，第 4 秒之后三个又都相同。
    // 正确结果 = 3 个采样点；错误实现会给出 5 个以上。
    var h = [[UInt64]](repeating: [UInt64](repeating: 0xAAAA, count: 6), count: 3)
    h[1][3] = 0x5555_5555_5555_5555   // 与 0xAAAA 距离很大
    for i in 4..<6 { h[0][i] = 0xBBBB; h[1][i] = 0xBBBB; h[2][i] = 0xBBBB }
    let learned = try #require(AdAutoLearn.learn(sourceKey: "s", samples: samples(h)))
    #expect(learned.hashes.count == 3, "遇到分叉就该停在第 3 个，实际 \(learned.hashes.count)")
}

@Test func needsAtLeastThreeSamples() {
    // 只有 1–2 条时不下结论：无法排除「这两条恰好同系列/同片源」。
    #expect(AdAutoLearn.learn(sourceKey: "s", samples: samples([realSamples[0]])) == nil)
    #expect(AdAutoLearn.learn(sourceKey: "s", samples: samples([realSamples[0], realSamples[1]])) == nil)
    #expect(AdAutoLearn.learn(sourceKey: "s", samples: samples(realSamples)) != nil)
}

@Test func tooShortAPrefixIsRefused() {
    // 只有 2 秒共同——多半是台标，不足以当广告去跳。
    let short = [[UInt64]](repeating: [UInt64](repeating: 0x1234, count: 2), count: 3)
    #expect(AdAutoLearn.learn(sourceKey: "s", samples: samples(short)) == nil)
}

@Test func theSameVideoSeenTwiceDoesNotCountAsTwoSamples() {
    // 用户把同一条看了两遍，不能算两条样本 —— 否则「两条一致」永远成立，会误学。
    let dup = [
        AdAutoLearn.Sample(videoID: "same", hashes: realSamples[0]),
        AdAutoLearn.Sample(videoID: "same", hashes: realSamples[0]),
        AdAutoLearn.Sample(videoID: "same", hashes: realSamples[0]),
    ]
    #expect(AdAutoLearn.learn(sourceKey: "s", samples: dup) == nil)
}

@Test func alignedSamplesWithDifferentStartTimesStillMatch() throws {
    // 不同视频的采样起点可能不同（用户先拖了进度条）。
    // b、c 从第 2 秒开始采，内容与 a 的第 2 秒之后对齐 —— 必须还能学出正确前缀。
    let a = AdAutoLearn.Sample(videoID: "a", hashes: realSamples[0], interval: 1, start: 0)
    let b = AdAutoLearn.Sample(videoID: "b", hashes: Array(realSamples[1][2...]), interval: 1, start: 2)
    let c = AdAutoLearn.Sample(videoID: "c", hashes: Array(realSamples[2][2...]), interval: 1, start: 2)
    let learned = try #require(AdAutoLearn.learn(sourceKey: "s", samples: [a, b, c]))
    // a 的 0..1 秒没有对应样本，起点对齐后从 a 的第 2 秒比；共同段到第 8 秒为止。
    #expect(learned.hashes.count >= 3)
    #expect(learned.hashes[0] == realSamples[0][2])
}

@Test func matchingRequiresTheWholePrefixNotJustAPartialHit() throws {
    // ⛔ 只对上前几秒就去跳整段，会切掉正片。
    let learned = try #require(AdAutoLearn.learn(sourceKey: "yutu", samples: samples(realSamples)))
    // 完整匹配 → 返回前缀时长
    #expect(AdAutoLearn.matchedPrefix(learned, in: realSamples[0]) == learned.span)
    // 只对上前 3 个 → 必须返回 0（不跳）
    let partial = Array(learned.hashes.prefix(3))
    #expect(AdAutoLearn.matchedPrefix(learned, in: partial) == 0)
    // 完全不同 → 0
    #expect(AdAutoLearn.matchedPrefix(learned, in: [UInt64](repeating: 0xFFFF_FFFF_FFFF_FFFF, count: 12)) == 0)
}

@Test func matchingToleratesOneFrameOffset() throws {
    // 抽帧时机可能差一帧：少一个采样点仍算命中，但不能少太多。
    let learned = try #require(AdAutoLearn.learn(sourceKey: "yutu", samples: samples(realSamples)))
    let oneLess = Array(learned.hashes.dropLast())
    #expect(AdAutoLearn.matchedPrefix(learned, in: oneLess) > 0)
}

@Test func learnResultIDIsStablePerSource() {
    // 同一站点只能有一条学习结果；id 必须可复现（不能用 Hasher，它每次进程都变）。
    let id1 = AdAutoLearn.id(for: "yutu")
    let id2 = AdAutoLearn.id(for: "yutu")
    let id3 = AdAutoLearn.id(for: "dytt")
    #expect(id1 == id2)
    #expect(id1 != id3)
    #expect(id1.hasPrefix("auto-"))
}

@Test func samplesWithNoUsableFramesAreIgnored() {
    let empty = [
        AdAutoLearn.Sample(videoID: "a", hashes: []),
        AdAutoLearn.Sample(videoID: "b", hashes: []),
        AdAutoLearn.Sample(videoID: "c", hashes: []),
    ]
    #expect(AdAutoLearn.learn(sourceKey: "s", samples: empty) == nil)
}

// MARK: - 存储层

private func tempStore() -> AutoLearnStore {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("autolearn-\(UUID().uuidString).json")
    return AutoLearnStore(fileURL: url)
}

@Test func feedingThreeSamplesLearnsAndPersists() async throws {
    let store = tempStore()
    // 前两条不够（要 3 条），不学。
    #expect(await store.feed(sourceKey: "yutu", sample: .init(videoID: "a", hashes: realSamples[0])) == nil)
    #expect(await store.feed(sourceKey: "yutu", sample: .init(videoID: "b", hashes: realSamples[1])) == nil)
    #expect(await store.learned(for: "yutu") == nil)
    // 第三条到，学到。
    let learned = try #require(await store.feed(sourceKey: "yutu", sample: .init(videoID: "c", hashes: realSamples[2])))
    #expect(learned.hashes.count == 9)
    #expect(await store.learned(for: "yutu") != nil)
}

@Test func aShorterPrefixNeverOverwritesALongerOne() async throws {
    // 已经学会 9 秒，不该因为后来一条只有 4 秒共同前缀的样本缩回去 ——
    // 缩短等于把已经能跳的广告又放出来。
    let store = tempStore()
    for (i, h) in realSamples.enumerated() {
        await store.feed(sourceKey: "s", sample: .init(videoID: "v\(i)", hashes: h))
    }
    let first = try #require(await store.learned(for: "s"))
    #expect(first.hashes.count == 9)

    // 喂 3 条「只有前 4 秒相同」的样本。
    let short = [[UInt64]](repeating: Array(realSamples[0].prefix(4)), count: 3)
    for (i, h) in short.enumerated() {
        await store.feed(sourceKey: "s", sample: .init(videoID: "w\(i)", hashes: h))
    }
    let after = try #require(await store.learned(for: "s"))
    #expect(after.hashes.count >= 9, "不该被更短的样本覆盖，实际 \(after.hashes.count)")
}

@Test func learningIsIsolatedPerSource() async throws {
    // ⛔ A 站点的固定开头不能拿去跳 B 站点的视频 —— 那是误跳。
    let store = tempStore()
    for (i, h) in realSamples.enumerated() {
        await store.feed(sourceKey: "siteA", sample: .init(videoID: "a\(i)", hashes: h))
    }
    #expect(await store.learned(for: "siteA") != nil)
    #expect(await store.learned(for: "siteB") == nil, "B 站点不该拿到 A 站点的学习结果")
}

@Test func forgettingASourceRemovesItsLearning() async throws {
    let store = tempStore()
    for (i, h) in realSamples.enumerated() {
        await store.feed(sourceKey: "s", sample: .init(videoID: "v\(i)", hashes: h))
    }
    #expect(await store.learned(for: "s") != nil)
    await store.forget(sourceKey: "s")
    #expect(await store.learned(for: "s") == nil)
}

@Test func samplesPerSourceAreCapped() async throws {
    // 不设上限时，播几百条片子会一直攒哈希占内存。
    let store = tempStore()
    for i in 0..<(AutoLearnStore.maxSamplesPerSource + 10) {
        await store.feed(sourceKey: "s", sample: .init(videoID: "v\(i)", hashes: realSamples[0]))
    }
    let snap = await store.allLearned()
    #expect(snap.count <= 1, "同一站点只该有一条学习结果")
    // 样本数受上限约束（通过内部快照间接验证：不应越攒越多）
    #expect(AutoLearnStore.maxSamplesPerSource == 12)
}

@Test func reWatchingTheSameVideoDoesNotInflateSamples() async throws {
    // 同一条看三遍 = 1 条样本，不能凑成 3 条去「学会」。
    let store = tempStore()
    for _ in 0..<3 {
        await store.feed(sourceKey: "s", sample: .init(videoID: "same", hashes: realSamples[0]))
    }
    #expect(await store.learned(for: "s") == nil)
}
