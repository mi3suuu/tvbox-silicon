import Foundation

// MARK: - 两阶段探测的调度

/// 把「全量源扫描」拆成两段，先便宜后昂贵。
///
/// 为什么需要拆
/// -----------
/// 旧扫描对**每个源**都走同一条重路径：抓主页（等插件编译 + 一次真实 API 请求，超时 25 s）
/// → 拿第一条视频 → 对它 4 条线路各拉 256 KB。
/// 341 个源、并发 2 的最坏耗时 = 341 / 2 × (25 + 4×3) ≈ **71 分钟**，
/// 流量 ≈ 341 × 4 × 256 KB ≈ **350 MB**。
///
/// 但其中大部分源根本不需要那 350 MB：一个连 API 都不应答的源，
/// 花 25 秒去问它的主页再花 4 次 256 KB 去测它的线路，得到的结论
/// 与「直接判不可达」完全一样，只是贵了 20 倍。
///
/// 所以拆成：
///
///   **阶段 1（筛）**：只对一个**廉价的探针地址**发一次小请求 —— 不看内容，
///   只看它答不答、多快答。开销 ≈ 1 个请求，无插件、无主页。
///   这一步把「死源」与「慢到不值得细测的源」直接判掉。
///
///   **阶段 2（测）**：只对阶段 1 通过的源做完整测量（主页 → 线路 → 稳态速度）。
///
/// 这样子账（按 341 个源、其中约 1/5 能通过筛来估）：
///   阶段 1：341 × 1 请求 ≈ 341 次、几十 KB；并发可以高得多（不占插件）
///   阶段 2：≈ 68 个源 × 4 线路 × 256 KB ≈ **70 MB**
///
/// 省下的是「给已经死了的源测速」这部分 —— 既省时间也省流量，
/// 而且它与准确度的方向一致：死源本来就不该占着排序表的低位被反复重测。
public struct ProbeSchedule: Sendable {

    /// 阶段 1 的并发。可以比阶段 2 高很多：
    /// 它不发插件调用、不编译脚本，只是 HTTP，瓶颈在网络与主机轮换，不在 CPU。
    public var screenWidth: Int
    /// 阶段 2 的并发。受插件编译限制，不能太高。
    public var measureWidth: Int
    /// 阶段 1 单源超时。只问「答不答」，不需要等完整响应。
    public var screenTimeout: TimeInterval
    /// 阶段 1 判定「值得细测」的最低门槛：必须在这么多秒内应答。
    ///
    /// 8 秒的依据：一个真的可用的源，API 首字节不会超过 8 秒；
    /// 超过就是线路本身有问题，细测它的视频速度没有意义（播放时同样会卡）。
    public var screenDeadline: TimeInterval

    /// 日常增量扫描：只补测过期的源，通常十几个，没必要开大火力。
    public static let standard = ProbeSchedule(screenWidth: 16, measureWidth: 4,
                                               screenTimeout: 8, screenDeadline: 6.0)

    /// 全量扫描用的快速档（「全部探测」按钮走这个）。
    ///
    /// ## 为什么原来慢
    ///
    /// `standard` 的 `measureWidth = 4` 是按「插件编译会抢 CPU」定的，
    /// 对**纯 HTTP 的线路测速**过于保守：每条线路就是一次 Range 请求，
    /// 瓶颈在网络与主机轮换，不在 CPU。设成 4 意味着 340 个源要排 85 轮、
    /// 每轮 ~3 秒 → **4 分钟以上**，用户看到的「探测缓慢」就是这个。
    ///
    /// ## 这里的数都是**源级**并发，不是「同时打某站多少次」
    ///
    /// ⛔ 上一版把 `measureWidth = 16` 的论证写成「单站被并发打 16 次已接近容忍边界」——
    ///    那个换算不成立：`measureWidth` 是**同时测多少个源**，
    ///    而每个源内部还会对它的多条线路并发（`probe` 里的 task group 上限 4）。
    ///    实际峰值是 16 × 4 = **64**，不是 16。
    ///
    /// 现在的两层限流：
    ///   · 源级：`measureWidth`（本结构）
    ///   · 每 host 级：`SourceProbeStore.beginBase` → `LineRotation.maxConcurrent`（默认 4，
    ///     按 host 计的在飞计数 + 退避）。这一层才是「别把某个站打急」的真正闸门，
    ///     而它原先**只有 EpisodePicker 一处在用，扫描路径完全绕过**。
    ///
    /// 有了 host 级闸门之后，源级可以开得比 16 高而不会把任何单站打急：
    /// 同一 host 最多 4 个在飞，多出来的源会在 `beginBase` 处被判 saturated 并顺延。
    /// 这里取 32 —— 340 个源约 11 轮，且单站峰值恒 ≤4。
    public static let bulk = ProbeSchedule(screenWidth: 24, measureWidth: 32,
                                           screenTimeout: 8, screenDeadline: 6.0)

    public init(screenWidth: Int, measureWidth: Int, screenTimeout: TimeInterval, screenDeadline: TimeInterval) {
        self.screenWidth = max(1, screenWidth)
        self.measureWidth = max(1, measureWidth)
        self.screenTimeout = max(1, screenTimeout)
        self.screenDeadline = max(0.5, screenDeadline)
    }

    /// 一次扫描的预估开销，供界面在开跑前把代价说清楚。
    ///
    /// 用户点「全部探测」时应当知道这是几十兆流量而不是几兆 ——
    /// 不告诉他，他就会在蜂窝上点下去。
    public struct Estimate: Sendable {
        public let screenedRequests: Int
        public let passedSources: Int
        public let measureBytes: Int64

        public var summary: String {
            let mb = Double(measureBytes) / 1_048_576
            return L10n.text("%lld sources screened · about %lld measured · up to %.0f MB",
                             screenedRequests, passedSources, mb)
        }
    }

    /// 按「历史上通过筛的比例」估算。
    ///
    /// `passRate` 用实测值传进来而不是写死：不同订阅集的存活率差很多
    /// （实测一套 341 源的集合里，`_route == "不通"` 的占 10/38 ≈ 26%，
    /// 但那只统计了被外部测过的子集，不能直接当全量存活率）。
    /// 没有历史时按 0.5 估，是刻意偏保守的中间值。
    public func estimate(sources: Int, linesPerSource: Int = 4, passRate: Double = 0.5) -> Estimate {
        let passed = Int((Double(sources) * min(max(passRate, 0), 1)).rounded())
        let bytes = Int64(passed) * Int64(linesPerSource) * Int64(SourceProbeRunner.sampleBytes)
        return Estimate(screenedRequests: sources, passedSources: passed, measureBytes: bytes)
    }
}
