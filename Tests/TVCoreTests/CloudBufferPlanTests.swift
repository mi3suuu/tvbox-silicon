import Testing
@testable import TVCore

@Suite struct CloudBufferPlanTests {
    private let chunk = CloudByteStream.chunkSize

    @Test func aBigFileOnAFastDeviceReadsFarAhead() {
        // 1 GB over 1000 s: 1 MB/s, so 90 s is 45 chunks of 2 MB.
        let plan = CloudBufferPlan.make(length: 1_000_000_000, duration: 1000, budget: 256 << 20, chunkSize: chunk)
        #expect(plan.readAhead == 43)
        #expect(plan.readAhead > CloudByteStream.readAhead)
        #expect(plan.cacheChunks >= 2 * plan.readAhead)
        #expect(plan.seconds >= 85)
    }

    @Test func aHighBitrateIsLimitedByMemoryNotByWishes() {
        // 10 GB over 1000 s: 10 MB/s; 90 s would be 900 MB.
        let plan = CloudBufferPlan.make(length: 10_000_000_000, duration: 1000, budget: 256 << 20, chunkSize: chunk)
        #expect(plan.cacheChunks == 128)
        #expect(plan.readAhead == (128 - 4) / 2)
        #expect(plan.readAhead * chunk <= 256 << 20 / 2 + chunk)
    }

    @Test func aSmallBudgetShrinksTheWindow() {
        let big = CloudBufferPlan.make(length: 1_000_000_000, duration: 1000, budget: 256 << 20, chunkSize: chunk)
        let small = CloudBufferPlan.make(length: 1_000_000_000, duration: 1000, budget: 32 << 20, chunkSize: chunk)
        #expect(small.readAhead < big.readAhead)
        #expect(small.cacheChunks == CloudBufferPlan.fewestCached)
        #expect(small.readAhead >= CloudBufferPlan.fewestAhead)
    }

    @Test func aLowBitrateKeepsTheFloor() {
        let plan = CloudBufferPlan.make(length: 100_000_000, duration: 1000, budget: 256 << 20, chunkSize: chunk)
        #expect(plan.readAhead == CloudBufferPlan.fewestAhead)
    }

    @Test func anUnknownDurationKeepsTheOldWindow() {
        let plan = CloudBufferPlan.make(length: 1_000_000_000, duration: nil, budget: 256 << 20, chunkSize: chunk)
        #expect(plan.readAhead == CloudByteStream.readAhead)
        #expect(plan.seconds == 0)
        #expect(CloudBufferPlan.make(length: 1, duration: 0, budget: 256 << 20, chunkSize: chunk).seconds == 0)
    }
}

// MARK: - 多路同时放时的预算均分

@Suite("CloudBufferShare")
struct CloudBufferShareTests {
    private let chunk = CloudByteStream.chunkSize

    /// 预算按「同时活着几条云流」均分：20 路时单路必须变浅。
    ///
    /// ⛔ 没有这条，`budget` 是**每条流**各吃一份的：20 路 × 160 块 = 6.4 GB。
    @Test func manyStreamsShareTheBudget() {
        let alone = CloudBufferPlan.make(length: 10_000_000_000, duration: 1000,
                                         budget: 256 << 20, chunkSize: chunk, share: 1)
        let among = CloudBufferPlan.make(length: 10_000_000_000, duration: 1000,
                                         budget: 256 << 20, chunkSize: chunk, share: 20)
        #expect(among.cacheChunks < alone.cacheChunks)
        // 20 路总占用不得明显超过一份预算（留一个块的余量给取整）。
        #expect(among.cacheChunks * chunk * 20 <= (256 << 20) + chunk * 20)
        // 但也不能浅到不能播：至少 6 块 ≈ 12 MB。
        #expect(among.cacheChunks >= 6)
        #expect(among.readAhead >= CloudBufferPlan.fewestAhead)
    }

    /// 单路时行为与改动前一致（不能因为引入均分把单流变慢）。
    @Test func oneStreamKeepsTheFullBudget() {
        let plan = CloudBufferPlan.make(length: 1_000_000_000, duration: 1000,
                                        budget: 256 << 20, chunkSize: chunk, share: 1)
        #expect(plan.cacheChunks == 128)
    }

    /// share 的极端值（0 / 负数来自计数竞态）不能把预算除爆。
    @Test func aNonPositiveShareIsTreatedAsOne() {
        let plan = CloudBufferPlan.make(length: 1_000_000_000, duration: 1000,
                                        budget: 256 << 20, chunkSize: chunk, share: 0)
        #expect(plan.cacheChunks == 128)
    }
}
