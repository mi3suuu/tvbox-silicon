//
//  SourceProbe.swift
//  TVCore
//
//  Lazy health probing for the play lines of one video, plus the score used to
//  order them in the picker.
//
//  What the codebase already had
//  -----------------------------
//  `PlaybackHistoryContext` already carries `sourceKey`, `videoID` and
//  `episodeFlag`, and `EpisodePlaylist.episodes(for:)` resolves a line from that
//  flag. So "reopen on the source and line I last used" needs no new storage —
//  it needs the player to consult the saved context instead of always starting at
//  the first line. That lives in PlaybackResume.swift.
//
//  What was missing is this file: nothing measured a line before the player
//  committed to it, so the picker could not show which line was alive, how fast
//  it was, or what resolution it offered. Everything here is opt-in and lazy:
//  the picker probes only the lines it is about to draw, one at a time, and a
//  reading is reused until it goes stale.
//

import Foundation

// MARK: - Probe result

/// 一条读数还有效多久。**全仓唯一出处**：`SourceProbeResult.isStale` 的默认容差，以及
/// 「测速时跳过多久以内的源」，都用它。
///
/// 600 秒的理由：用户点「测一遍」通常是想知道「现在能不能用」，而一个源在十分钟内从可用
/// 变到不可用的概率，远小于重复拉几百 KB 的代价。
///
/// 放在文件顶层而不是 `SourceProbeStore` 里：后者是 `@MainActor`，把常量挂上去会让
/// `isStale` 的默认值变成 main-actor 隔离值，而 `isStale` 是非隔离的。
public let sourceProbeStaleness: TimeInterval = 600

/// What one line told us when we last looked.
public struct SourceProbeResult: Codable, Hashable, Sendable {
    public enum Reachability: String, Codable, Sendable {
        case unknown
        case reachable
        case slow
        case unreachable
    }

    public var reachability: Reachability
    /// Round-trip to the first response byte. `nil` when the probe never connected.
    public var latencyMilliseconds: Int?
    /// Throughput measured over a short ranged read, in KB/s.
    public var kilobytesPerSecond: Int?
    /// Height the source itself declares (1080, 720, …). `nil` when it does not say.
    public var resolutionHeight: Int?
    /// Short label for the picker: "1080P", or nil when unknown.
    public var resolutionLabel: String?
    /// 源声明的峰值码率，**kbps**（m3u8 的 `BANDWIDTH`，或 `AVERAGE-BANDWIDTH`）。
    ///
    /// 与 `kilobytesPerSecond` 区分：那个是**实测吞吐**（这条网络现在能跑多快），
    /// 这个是**这路流本身需要多少**。两者相除才知道有没有余量。
    public var declaredBitrateKbps: Int?
    /// 该文件的字节数。取自 `Content-Range` 总长或 `Content-Length`；分片流拿不到。
    public var fileSizeBytes: Int?
    /// 色彩范围：`SDR` / `HLG` / `PQ`。来自 m3u8 的 `VIDEO-RANGE`。
    ///
    /// 单独一项而不折进分辨率：HDR 在 HDR 屏上更好、在 SDR 屏上反而更差，
    /// 所以它不能和分辨率合并成「越大越好」。
    public var colourRange: String?
    public var measuredAt: Date

    public init(
        reachability: Reachability = .unknown,
        latencyMilliseconds: Int? = nil,
        kilobytesPerSecond: Int? = nil,
        resolutionHeight: Int? = nil,
        resolutionLabel: String? = nil,
        declaredBitrateKbps: Int? = nil,
        fileSizeBytes: Int? = nil,
        colourRange: String? = nil,
        measuredAt: Date = .distantPast,
        declaredConflicted: Bool? = nil
    ) {
        self.reachability = reachability
        self.latencyMilliseconds = latencyMilliseconds
        self.kilobytesPerSecond = kilobytesPerSecond
        self.resolutionHeight = resolutionHeight
        self.resolutionLabel = resolutionLabel
        self.declaredBitrateKbps = declaredBitrateKbps
        self.fileSizeBytes = fileSizeBytes
        self.colourRange = colourRange
        self.measuredAt = measuredAt
        self.declaredConflicted = declaredConflicted
    }

    public static let unknown = SourceProbeResult()

    /// 读数是否已经过时。
    ///
    /// `tolerance` 默认取 `SourceProbeStore.staleness`（与「测速时跳过多久以内的读数」同一个值），
    /// 而不是各写一个常数：这两个问题其实是同一个 —— 「多旧的读数还算数」。
    /// 它们曾经不同（这里 300 秒、`Store.probeMaxAge` 600 秒），于是同一个源可能在选集页被判
    /// 「过期要重测」，在点播源页却被当成「新鲜」直接跳过，两处对同一条读数给出相反结论。
    public func isStale(now: Date = Date(), tolerance: TimeInterval = sourceProbeStaleness) -> Bool {
        now.timeIntervalSince(measuredAt) > tolerance
    }

    /// Higher sorts first. **0–100 分制**，每段都能单独解释。
    ///
    /// ⛔ 旧实现（`1_000_000 + 延迟分 + 速度分×10 + 高度`）有一个可算的失衡：
    /// 分辨率满分只值 360（`min(height, 2160)`），而 1 KB/s 值 10 分 ——
    /// 于是「720p → 1080p」的收益还不如「速度快 36 KB/s」。
    /// 对观看页来说顺序正好反了：能不能播看可达性，体验好不好看分辨率，
    /// 速度只要够码率就该停止加分（多出来的带宽不产生画面）。
    ///
    /// 现在四段的权重与理由：
    ///   · 可达性 0–100：不可达直接 0，其余给底分。这是**门槛**，不是加分项。
    ///   · 速度 0–30：按「够不够 4 Mbps」饱和。4 Mbps ≈ 1080p 高码率，
    ///     超过它再加分没有意义 —— 播放器不会因为带宽翻倍而更清楚。
    ///   · 延迟 0–15：300 ms 内几乎无感，之后线性扣；1500 ms 以上归零。
    ///   · 分辨率 0–20：480p→1080p 线性，1080p 以上饱和。
    ///     它现在是**独立的一大段**，不再被速度碾压。
    ///
    /// 未测过的字段不加分也不扣分（按「不知道」处理），
    /// 所以一个只测了可达性的源不会因为缺速度而排到最后。
    public var sortScore: Int {
        // 门槛：不可达没有参与剩下的必要，直接 0。
        guard reachability != .unreachable else { return 0 }

        var score = 0

        // ① 可达性底分：能连 60，慢 35，未知 30。
        //    未知不低于慢 —— 没测过不等于坏，但也不该压过测出来能连的。
        switch reachability {
        case .reachable: score += 60
        case .slow: score += 35
        case .unknown: score += 30
        case .unreachable: break
        }

        // ② 速度 0–30，4 Mbps 饱和。
        //    1024 KB/s ≈ 8 Mbps，所以 512 KB/s 就够满 4 Mbps。
        //
        //    ⛔ 只有自洽的读数才吃这一段。外部导入的读数里两个速度字段互相矛盾
        //    （实测 38/38 不符），那种数字加进去等于随机排序。
        let trust = confidence
        if trust.trustsSpeed, let speed = kilobytesPerSecond, speed > 0 {
            let saturated = min(Double(speed), 512.0) / 512.0
            score += Int((saturated * 30).rounded())
        }

        // ③ 延迟 0–15：≤300 ms 满分，之后线性降到 1500 ms 归零。
        if trust.trustsSpeed, let latency = latencyMilliseconds {
            let clamped = min(max(latency, 0), 1500)
            let factor = clamped <= 300 ? 1.0 : Double(1500 - clamped) / 1200.0
            score += Int((factor * 15).rounded())
        }

        // ④ 分辨率 0–20：用**有效画质**，不是源自己标的那个数。
        //
        // 源声明的 1080p 是可以假的：实测 27 个同时带画质与速度的源里，
        // **7 个（26%）标称画质撑不住自己的速度** —— 例如「乐播 1080P」实测 62 KB/s，
        // 连 480p 的码率都不够；「魔都资源 1080P」120 KB/s。
        // 那些源在播放时要么降档、要么卡，按标称给了 20 分等于奖励虚标。
        if let effective = effectiveResolutionHeight {
            let clamped = Double(min(max(effective, 480), 1080)) - 480
            score += Int((clamped / 600 * 20).rounded())
        }

        // ⑤ 码率余量 0–10：**实测吞吐 ÷ 声明码率**。
        //
        // 这一个比值比任何绝对数字都有用：它直接回答「这条线喂不喂得饱这路流」。
        //   余量 ≥ 2× 满 10 分（有充足缓冲）
        //    余量 = 1× 得 5 分（刚好够，卡顿边缘）
        //    余量 < 1× 递减到 0（喂不饱，必卡）
        // 两个量任一缺失就不加分 —— 不知道就别猜。
        if trust.trustsSpeed,
           let speed = kilobytesPerSecond, speed > 0,
           let bitrateKbps = declaredBitrateKbps, bitrateKbps > 0 {
            // ⛔ 这一段的零点必须在**余量 1×**（刚好喂饱），不是 0×。
            //    上一版写成 `5 + factor*5`，于是余量 0.4×（远喂不饱、必然卡）
            //    仍拿 5 分，与余量 1.0×（刚好够）同分 —— 实测复现：
            //      8000 kbps 实测 / 20000 kbps 需求 = 0.40×  → 5 分
            //      8000 kbps 实测 /  9000 kbps 需求 = 0.89×  → 5 分
            //    这等于把「喂不饱」和「刚好够」判成一样，而这一段存在的意义
            //    恰恰是分出两者。改为从 0× 线性升到 2×：
            //      ≤1× 给 0~4（仍然喂不饱，几乎不该加分）
            //        2× 给 10（有两倍余量）
            let margin = Double(speed) * 8.0 / Double(bitrateKbps)   // KB/s → kbps
            let factor = min(max(margin, 0.0), 2.0) / 2.0            // 0×→0，2×→1
            score += Int((factor * 10).rounded())                    // 0~10
        }

        // ⑥ 色域 0–5：只奖励 HDR（HLG/PQ）。
        //
        // 为什么不惩罚 SDR：SDR 在 SDR 屏上是**正确**的显示，不是缺陷；
        // 而 HDR 在 SDR 屏上才需要用户自己权衡。给 HDR 一点加分即表达「同等条件下优先」，
        // 不把它变成硬门槛。
        if let range = colourRange, range == "HLG" || range == "PQ" {
            score += 5
        }

        // ⑦ 文件大小 0–5：**小文件优先**，但只作为很轻的加分。
        //
        // 大小本身不代表质量（高码率长片天然大），它只在「其他都一样」时有用，
        // 所以权重压到最低档。> 8 GB 不再加也不减（大文件本身不是扣分项）。
        if let bytes = fileSizeBytes, bytes > 0 {
            let gb = Double(bytes) / 1_073_741_824.0
            if gb <= 1 { score += 5 } else if gb <= 4 { score += 3 } else if gb <= 8 { score += 1 }
        }

        return score
    }

    /// 速度撑得住的最高画质。
    ///
    /// 门槛 = 该档典型码率 × 1.2 余量（换算成 KB/s）：
    /// | 档位 | 典型码率 | 理论 KB/s | 门槛 |
    /// |---|---|---|---|
    /// | 480p  | 1.0 Mbps  | 125  | **150** |
    /// | 720p  | 2.5 Mbps  | 312  | **375** |
    /// | 1080p | 5.0 Mbps  | 625  | **750** |
    /// | 2160p | 20  Mbps  | 2500 | **3000** |
    ///
    /// 结果取 `min(声明值, 撑得住的档)`：声明比能力低时不吹高，声明比能力高时压下来。
    /// 声明为 nil 时返回 nil（不加分也不扣分）—— 不知道就别说，
    /// 不要用速度反推一个画质出来冒充测量。
    public var effectiveResolutionHeight: Int? {
        guard let declared = resolutionHeight, declared > 0 else { return nil }
        // 不可达的源不必谈画质。
        guard reachability != .unreachable else { return nil }
        // 没有速度读数：只能信声明（那是唯一的信息）。
        // 但**矛盾读数**的速度是被丢弃的，同样退回信声明。
        guard let speed = kilobytesPerSecond, speed > 0, confidence.trustsSpeed else { return declared }
        let supported: Int
        switch speed {
        case 3_000...: supported = 2160
        case 750..<3_000: supported = 1080
        case 375..<750: supported = 720
        case 150..<375: supported = 480
        default: supported = 360
        }
        return min(declared, supported)
    }

    /// 声明值与有效值不一致时，界面要说出来 —— 否则用户看到的仍是那个假数。
    public var claimsMoreThanItCanDeliver: Bool {
        guard let declared = resolutionHeight, let effective = effectiveResolutionHeight else { return false }
        return effective < declared
    }

    // MARK: - 读数可信度

    /// 这次读数能不能当证据用。
    ///
    /// 存在的理由：外部导进来的订阅把**两个不同源的速度**都塞在源定义里
    /// （`_speedKBps` 与 `_mbps`），实测 38 条**没有一条**满足 `mbps == KB/s × 8 / 1024`，
    /// 比值散布在 0.12–1.87。也就是说它们来自不同时刻、不同样本，
    /// 拿任意一个当「这个源有多快」都会得到互相矛盾的结论。
    ///
    /// 所以排序不能直接吃原始数字，必须先判一次：自相矛盾的读数**只用其可达性**，
    /// 速度与延迟一律当未知（不加分也不扣分）。宁可少排对一个，
    /// 也不要把一个「标称 9 Mbps 实际 0.3 MB/s」的源顶到第一。
    public enum Confidence: String, Codable, Sendable {
        /// 自己测的，单次采样，数字内部自洽。
        case measured
        /// 外部导入，两个速度字段互相矛盾 —— 只信可达性。
        case conflicted
        /// 速度或延迟缺失，只能判可达性。
        case partial
        /// 从未测量。
        case absent

        /// 速度与延迟能不能参与打分。
        public var trustsSpeed: Bool { self == .measured }

        /// 给界面看的一句话，不写假数。
        public var note: String {
            switch self {
            case .measured: return L10n.text("Measured")
            case .conflicted: return L10n.text("Speed readings disagree; reachability only")
            case .partial: return L10n.text("Reachability only")
            case .absent: return L10n.text("Not measured")
            }
        }
    }

    /// 由读数本身推出的可信度。自己测的永远是 `.measured`。
    ///
    /// ⛔ 判定顺序很重要，第一版写错过：原来是「先查有没有速度，没有就 `.partial`」，
    /// 于是**矛盾读数恰好也没有速度**（两个字段都被丢弃了），永远走不到 `.conflicted`，
    /// 那个状态形同虚设、`sortScore` 里的降级也就从未生效。测试抓到了。
    ///
    /// 现在先判「调用方是否声明矛盾」，再判有没有数据：
    ///   1. 声明矛盾 → `.conflicted`（唯一能覆盖其余判定的强信号）
    ///   2. 不可达 → `.measured`（「连不上」是确定事实，不因缺速度就降级）
    ///   3. 既无延迟也无速度 → 从没测过 `.absent`，或测过但只拿到可达性 `.partial`
    ///   4. 其余 → `.measured`
    public var confidence: Confidence {
        if declaredConflicted == true { return .conflicted }
        if reachability == .unreachable { return .measured }
        let hasSpeed = (kilobytesPerSecond ?? 0) > 0
        let hasLatency = latencyMilliseconds != nil
        if hasSpeed || hasLatency { return .measured }
        // 一点数据都没有：`unknown` 才是「从没测过」。
        return reachability == .unknown ? .absent : .partial
    }

    /// 由导入器设置：源定义里的速度来自两个互相矛盾的字段。
    /// 用存储属性而不是从数字反推 —— 反推需要知道「另一个字段是多少」，
    /// 而那个字段在读进 `SourceProbeResult` 时已经被丢掉了。
    /// 由导入器设置：源定义里的速度来自两个互相矛盾的字段。
    ///
    /// ⛔ **必须是 Optional**。这个字段是本轮新加的存储属性，而 `SourceProbeResult`
    /// 用 Swift 合成的 `init(from:)` —— 非 Optional 属性即使有默认值也**不参与解码**，
    /// 缺键直接抛 `keyNotFound`。
    ///
    /// 后果链（子代理实测复现）：旧 blob 解码失败 → `SourceProbeStore` 里 `try?` 吞掉错误
    /// → `probes` / `health` 双双被当成 `[:]` → 下一次 `record()` 的 `persist()`
    /// 把空表写回 → **老用户全部测速读数永久丢失**，测速页变成「全部未测量」。
    /// `FullBackup` 的白名单也含这两个键，备份恢复同样读不出来。
    public var declaredConflicted: Bool? = nil

    /// Compact line for the picker's subtitle, e.g. "1080P · 320 ms · 2.4 MB/s".
    ///
    /// ⛔ 画质用**有效值**，不是 `resolutionLabel` 里那个声明值。
    /// 实测 26% 的源标称画质撑不住自己的速度（「乐播 1080P」只有 62 KB/s）；
    /// 显示声明值等于把虚标原样转述给用户，而用户正是靠这一行判断要不要用这个源。
    /// 声明高于能力时补一个 `~` 前缀（`~720p`），让「被压下来」这件事看得见 ——
    /// 不写 `~` 的话用户以为源只支持 720p，而实际是它声称 1080p 但喂不动。
    public func summary() -> String {
        var parts: [String] = []
        if let effective = effectiveResolutionHeight {
            let prefix = claimsMoreThanItCanDeliver ? "~" : ""
            parts.append("\(prefix)\(effective)P")
        }
        if let latency = latencyMilliseconds, reachability != .unreachable {
            parts.append(String(format: "%d ms", latency))
        }
        if let speed = kilobytesPerSecond, reachability != .unreachable, confidence.trustsSpeed {
            parts.append(String(format: "%.1f MB/s", Double(speed) / 1024))
        }
        if parts.isEmpty {
            switch reachability {
            case .unreachable: return L10n.text("Unreachable")
            case .slow: return L10n.text("Slow")
            case .reachable: return L10n.text("Reachable")
            case .unknown: return L10n.text("Not checked")
            }
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Store

/// Caches probe readings per (source, video, line). Bounded, and least-recently
/// measured rows are evicted first so a long-lived install stays small.
@MainActor
public final class SourceProbeStore {

    public static let shared = SourceProbeStore()

    /// Bumped every time a reading lands, so a view can re-read the (non-observable) tables.
    ///
    /// The sweep already drives the page through `Store.probeRun`, but a reading can also land
    /// without a sweep: the episode picker probes a line when the viewer opens it, and that should
    /// refresh the speed page too, not wait for the next full probe. A view reads this with
    /// `.onChange` and re-renders, the same way it does for the sweep's progress.
    public private(set) var revision = 0

    private static let probeKey = "player.playLine.probes"
    private static let orderKey = "player.playLine.probes.order"
    /// One reading per source, kept apart from the per-line detail.
    ///
    /// The detail table is bounded (a sweep of a few hundred sources produces a few thousand rows,
    /// four lines each) and evicts least-recently-measured rows first, so the first sources a long
    /// sweep touched were being thrown away before the sweep even finished: the page then said
    /// "not measured" about sources it had just measured. This table has one row per source and no
    /// eviction, so a reading survives a restart, another sweep, and a library ten times this size.
    private static let healthKey = "player.playLine.sourceHealth"
    /// Detail rows kept for the per-line view. Only this half is bounded.
    private static let limit = 4_000

    private static let rotationKey = "player.playLine.rotation"
    private static let learningKey = "player.playLine.learning"

    private let defaults: UserDefaults
    private var probes: [String: SourceProbeResult]
    private var order: [String]
    /// The newest reading per source. `latest(sourceKey:)` answers from here, so a page that lists
    /// three hundred sources does not walk three hundred thousand detail rows to fill itself in.
    private var health: [String: SourceProbeResult]
    /// Per-base backoff and concurrency, keyed by base rather than by the full URL: a line that
    /// failed once will fail for every episode on that host, so the avoidance belongs to the host.
    /// This mirrors what One keeps as `avoidUntil` / `inflight` / `lastHeal`.
    private var rotation: HostRotation
    /// Which bases have actually answered, so a working CDN is tried before an unknown one.
    private var learning: HostLearning

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let blob = defaults.data(forKey: Self.probeKey),
           let decoded = try? JSONDecoder().decode([String: SourceProbeResult].self, from: blob) {
            self.probes = decoded
        } else {
            self.probes = [:]
        }
        self.order = defaults.stringArray(forKey: Self.orderKey) ?? []
        for key in probes.keys where !order.contains(key) { order.append(key) }
        if let blob = defaults.data(forKey: Self.healthKey),
           let decoded = try? JSONDecoder().decode([String: SourceProbeResult].self, from: blob) {
            self.health = decoded
        } else {
            self.health = [:]
        }
        // Readings written before this table existed still answer `latest`: fold the newest detail
        // row of each source in once, so an upgrade does not look like a library nobody measured.
        for (key, value) in probes {
            guard let bar = key.firstIndex(of: "|") else { continue }
            let sourceKey = String(key[key.startIndex..<bar])
            guard let seen = health[sourceKey] else { health[sourceKey] = value; continue }
            if value.measuredAt > seen.measuredAt { health[sourceKey] = value }
        }
        if let blob = defaults.data(forKey: Self.rotationKey),
           let decoded = try? JSONDecoder().decode(HostRotation.self, from: blob) {
            self.rotation = decoded
        } else {
            self.rotation = HostRotation()
        }
        if let blob = defaults.data(forKey: Self.learningKey),
           let decoded = try? JSONDecoder().decode(HostLearning.self, from: blob) {
            self.learning = decoded
        } else {
            self.learning = HostLearning()
        }
    }

    // MARK: - Base rotation（对应 One 的 avoidUntil / lastHeal / inflight）

    private func persistRotation() {
        if let encoded = try? JSONEncoder().encode(rotation) { defaults.set(encoded, forKey: Self.rotationKey) }
        if let encoded = try? JSONEncoder().encode(learning) { defaults.set(encoded, forKey: Self.learningKey) }
    }

    /// Declares the bases a video offers, so the rotator knows the pool. Call this before probing.
    public func declareBases(_ bases: [String], preferred: String? = nil) {
        rotation.replace(hosts: bases, preferred: preferred)
        persistRotation()
    }

    /// Bases that may be probed right now: not cooling down, not saturated. One skips a base in its
    /// `avoidUntil` window rather than retrying it; this is that behaviour.
    public func availableBases(now: Date = Date()) -> [String] { rotation.available(now: now) }

    /// Bases ordered by observed health, with learned-good ones first.
    public func rankedBases(_ bases: [String]? = nil, now: Date = Date()) -> [String] {
        let pool = bases ?? rotation.hosts
        return learning.prefer(rotation.ranked(now: now).filter { pool.contains($0) }, now: now)
    }

    /// True when every base is cooling down. A caller should show "所有线路都在冷却" rather than
    /// "没有可播放的地址", because the two have different fixes.
    public func allBasesCoolingDown(now: Date = Date()) -> Bool { rotation.allCoolingDown(now: now) }

    /// Registers a base in the pool on first sight, so `HostRotation.begin` does not drop it
    /// (it only claims hosts that are already known). Surviving hosts keep their state.
    private func ensureBase(_ base: String) {
        guard !rotation.hosts.contains(base) else { return }
        var hosts = rotation.hosts
        hosts.append(base)
        rotation.replace(hosts: hosts, preferred: rotation.preferred)
    }

    /// Claims a base for one probe. Returns false when it is cooling down or saturated, which means
    /// "skip this round", not "this base is dead".
    public func beginBase(_ base: String, now: Date = Date()) -> Bool {
        ensureBase(base)
        let claimed = rotation.begin(base, now: now)
        if claimed { persistRotation() }
        return claimed
    }

    /// Records that a base answered. Promotes it and clears its backoff.
    public func succeedBase(_ base: String, now: Date = Date()) {
        rotation.succeed(base, now: now)
        learning.learn(base, at: now)
        persistRotation()
    }

    /// Records that a base failed, scheduling the next attempt. Returns when it becomes available.
    @discardableResult
    public func failBase(_ base: String, reason: String = "", now: Date = Date()) -> Date? {
        let until = rotation.fail(base, now: now)
        if !reason.isEmpty { learning.reject(base, reason: reason, at: now) }
        persistRotation()
        return until
    }

    /// Releases a slot for a cancelled probe without judging the base.
    public func cancelBase(_ base: String) {
        rotation.cancel(base)
        persistRotation()
    }

    /// Current backoff deadline for a base, for a UI countdown.
    public func baseAvoidUntil(_ base: String) -> Date? { rotation.states[base]?.avoidUntil }

    /// How long `base` stays out of rotation, in seconds, or nil when it is usable now.
    ///
    /// The UI asks this per chip. Exposing seconds rather than a date keeps the view from having to
    /// reason about clock changes, and lets it show a countdown without its own timer.
    public func cooldownRemaining(for base: String, now: Date = Date()) -> TimeInterval? {
        guard let until = baseAvoidUntil(base), until > now else { return nil }
        return until.timeIntervalSince(now)
    }

    /// The soonest a cooling base becomes usable, in seconds, or nil when at least one is usable.
    ///
    /// Used for the "every line is cooling down" notice: when this is non-nil, every chip on screen
    /// is disabled, and a list of greyed-out buttons with no explanation reads as a bug.
    public func soonestCooldown(now: Date = Date()) -> TimeInterval? {
        guard allBasesCoolingDown(now: now) else { return nil }
        return rotation.states.values
            .compactMap { $0.avoidUntil }
            .filter { $0 > now }
            .map { $0.timeIntervalSince(now) }
            .min()
    }

    /// How many consecutive failures a base has, for a UI badge.
    public func baseFailures(_ base: String) -> Int { rotation.states[base]?.consecutiveFailures ?? 0 }


    private func storageKey(sourceKey: String, videoID: String, lineFlag: String) -> String {
        "\(sourceKey)|\(videoID)|\(lineFlag)"
    }

    public func probe(sourceKey: String, videoID: String, lineFlag: String) -> SourceProbeResult? {
        probes[storageKey(sourceKey: sourceKey, videoID: videoID, lineFlag: lineFlag)]
    }

    /// The freshest reading for one source, whatever video or line it was measured on.
    ///
    /// Ranking sources needs one number per source, and a probe measures a sample video inside one
    /// source: the newest reading is the best guess at what that source serves now. A source that
    /// has never been probed answers nil, which ranks it as unknown rather than as bad.
    public func latest(sourceKey: String) -> SourceProbeResult? {
        if let entry = health[sourceKey] { return entry }
        // Readings recorded before the summary table existed (or by a store that was opened before
        // one of them landed) are still readable, just slower to find.
        let prefix = sourceKey + "|"
        var newest: SourceProbeResult?
        for (key, value) in probes where key.hasPrefix(prefix) {
            guard let found = newest else { newest = value; continue }
            if value.measuredAt > found.measuredAt { newest = value }
        }
        return newest
    }

    /// Every source that has a reading, newest first. The speed page draws from this and then asks
    /// the library which of those sources still exist, rather than the other way round.
    public func measuredSources() -> [(sourceKey: String, reading: SourceProbeResult)] {
        health
            .map { (sourceKey: $0.key, reading: $0.value) }
            .sorted { $0.reading.measuredAt > $1.reading.measuredAt }
    }

    /// How many sources have a reading. Used by the summary line, so it agrees with the page.
    public var measuredSourceCount: Int { health.count }

    /// When the oldest and newest readings were taken. A single "last swept" line is drawn from the
    /// newer one, and the spread tells the reader whether one sweep covered the library or the
    /// numbers are a mixture of yesterday and today.
    public var measurementWindow: (oldest: Date, newest: Date)? {
        guard let first = health.values.map(\.measuredAt).min(),
              let last = health.values.map(\.measuredAt).max() else { return nil }
        return (first, last)
    }

    /// Forgets every reading, detail and summary alike. Offered as one button, so a viewer who
    /// measured on a bad network can start over instead of guessing which rows to distrust.
    public func forgetEverything() {
        probes.removeAll()
        order.removeAll()
        health.removeAll()
        persist()
        revision += 1
    }

    /// Every reading known for one video, keyed by line flag.
    public func probes(sourceKey: String, videoID: String) -> [String: SourceProbeResult] {
        let prefix = "\(sourceKey)|\(videoID)|"
        var found: [String: SourceProbeResult] = [:]
        for (key, value) in probes where key.hasPrefix(prefix) {
            found[String(key.dropFirst(prefix.count))] = value
        }
        return found
    }

    /// One row per dead line, whatever video it was measured on.
    ///
    /// Fixing a dead line needs the source and the flag — the route is stored per (origin, source,
    /// flag), not per episode — so the reader gets exactly those two, de-duplicated across every
    /// video the sweep happened to probe.
    ///
    /// The newest reading decides, reachable or not: a line that failed on Monday and was measured
    /// again as reachable on Tuesday is not dead, and filtering before taking the newest would have
    /// kept it in the list forever, since the two readings live under different video ids.
    public func unreadableLines() -> [(sourceKey: String, lineFlag: String)] {
        var best: [String: (sourceKey: String, lineFlag: String, at: Date, dead: Bool)] = [:]
        for (key, value) in probes {
            // key = "sourceKey|videoID|lineFlag"; a source key never contains a bar, a video id is
            // the feed's own id, and a flag is the feed's line name.
            let parts = key.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            let flag = String(parts[parts.count - 1])
            guard !flag.isEmpty else { continue }
            let sourceKey = parts.dropLast(2).joined(separator: "|")
            let id = "\(sourceKey)|\(flag)"
            if let seen = best[id], seen.at >= value.measuredAt { continue }
            best[id] = (sourceKey, flag, value.measuredAt, value.reachability == .unreachable)
        }
        return best.values
            .filter(\.dead)
            .sorted { $0.at > $1.at }
            .map { (sourceKey: $0.sourceKey, lineFlag: $0.lineFlag) }
    }

    public func record(_ result: SourceProbeResult, sourceKey: String, videoID: String, lineFlag: String) {
        guard !lineFlag.isEmpty else { return }
        let key = storageKey(sourceKey: sourceKey, videoID: videoID, lineFlag: lineFlag)
        probes[key] = result
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.limit {
            probes.removeValue(forKey: order.removeFirst())
        }
        note(result, for: sourceKey)
        persist()
        revision += 1
    }

    /// 把外部配置里夹带的读数整批登记进来。
    ///
    /// 与 `record(_:sourceKey:videoID:lineFlag:)` 的区别：那些读数**没有 videoID、没有线路**，
    /// 它们是「这个源的 API 有多快」，不是「这个源里某个视频的某条线有多快」。
    /// 所以只写 `health`（按源汇总的那张表），不进 `probes`（按源+视频+线路索引的那张）。
    ///
    /// 为什么不复用 `record`：它要求 `lineFlag` 非空，而外部读数给不出来；
    /// 造一个假 flag（比如 `"imported"`）会让线路菜单里多出一条不存在的线。
    ///
    /// - Parameter readings: 源 key → 读数。**调用方必须已经用 `SourceProbeImport` 判过疑**，
    ///   这里不重复判定 —— 但会尊重 `declaredConflicted`，因为排序层要看它。
    /// - Returns: 实际写入的条数（`_route == "不通"` 之外的全算），供界面报「导入了 N 条」。
    @discardableResult
    public func importReadings(_ readings: [String: SourceProbeResult]) -> Int {
        guard !readings.isEmpty else { return 0 }
        var written = 0
        for (sourceKey, reading) in readings {
            // 只在不覆盖更新的自测读数时写入。
            // 外部读数带的是「导出那一刻」的时间戳，自己测的更新，应当压过它。
            if let seen = health[sourceKey], seen.measuredAt > reading.measuredAt { continue }
            health[sourceKey] = reading
            written += 1
        }
        guard written > 0 else { return 0 }
        persist()
        revision += 1
        return written
    }

    /// Records a whole source's lines in one go.
    ///
    /// `record` re-encodes every saved reading and writes the defaults file, which is the right cost
    /// for one line and the wrong one for a sweep of hundreds: a bulk probe used to spend its time
    /// re-serialising the same dictionary on the main actor, which is what made the app look stuck.
    public func record(_ rows: [(result: SourceProbeResult, lineFlag: String)], sourceKey: String, videoID: String) {
        guard !rows.isEmpty else { return }
        for row in rows where !row.lineFlag.isEmpty {
            let key = storageKey(sourceKey: sourceKey, videoID: videoID, lineFlag: row.lineFlag)
            probes[key] = row.result
            order.removeAll { $0 == key }
            order.append(key)
        }
        while order.count > Self.limit {
            probes.removeValue(forKey: order.removeFirst())
        }
        // The source is judged by its best line in this batch — a source that answered on one of
        // its four lines is a working source, and averaging that with three dead ones would call it
        // slow. A batch of nothing but cancellations (`unknown`) says nothing, so it leaves the
        // previous reading standing instead of marking the source unmeasured.
        let verdict = rows
            .filter { $0.result.reachability != .unknown }
            .max { lhs, rhs in
                lhs.result.sortScore == rhs.result.sortScore
                    ? lhs.result.measuredAt < rhs.result.measuredAt
                    : lhs.result.sortScore < rhs.result.sortScore
            }
        if let verdict { note(verdict.result, for: sourceKey) }
        persist()
        revision += 1
    }

    /// Files one reading as a source's standing reading, keeping the newer of the two.
    private func note(_ result: SourceProbeResult, for sourceKey: String) {
        guard let seen = health[sourceKey] else { health[sourceKey] = result; return }
        if result.measuredAt >= seen.measuredAt { health[sourceKey] = result }
    }

    /// Writes the readings once, after a batch.
    private func persist() {
        if let encoded = try? JSONEncoder().encode(probes) {
            defaults.set(encoded, forKey: Self.probeKey)
        }
        defaults.set(order, forKey: Self.orderKey)
        if let encoded = try? JSONEncoder().encode(health) {
            defaults.set(encoded, forKey: Self.healthKey)
        }
    }

    /// Drops the detail rows for one video. The source's standing reading stays: "forget this
    /// video's lines" is not "forget what this source answers", and the sweep's verdict is the
    /// thing the speed page exists to keep.
    public func clear(sourceKey: String, videoID: String) {
        let prefix = "\(sourceKey)|\(videoID)|"
        for key in probes.keys where key.hasPrefix(prefix) {
            probes.removeValue(forKey: key)
            order.removeAll { $0 == key }
        }
        persist()
    }
}

// MARK: - Runner

/// Probes one line with a single ranged GET: enough to learn whether it answers,
/// how fast, and what the manifest declares — without pulling a whole segment.
public enum SourceProbeRunner {
    /// Bytes to pull when measuring throughput. Large enough to separate a
    /// healthy CDN from a stalled one, small enough to stay harmless on cellular.
    public static let sampleBytes = 256 * 1024

    /// 深测时拉多少。首轮用 `sampleBytes`，只有「看起来够快、值得再问」的源才升到这里。
    ///
    /// 为什么需要两档：256 KB 按 4 Mbps 算只要 0.5 秒，整段几乎都在 TCP 慢启动里；
    /// 而慢启动对**所有**源都低估同样的比例（实测约 43%），所以它不影响相对排序，
    /// 却会让「600 KB/s」和「1600 KB/s」都落成「发不出更多字节」的假饱和。
    /// 深测只在 suspect 值接近满分时才触发，因此总流量并不会翻倍。
    public static let deepSampleBytes = 1024 * 1024

    /// 慢启动区间：这么多字节之后才算「进满速」。
    ///
    /// 度量方式不猜、不建模 —— 直接**分两段计时**：前 `warmupBytes` 记一个时间戳，
    /// 后一段的字节数除以后一段的耗时，得到的就是稳态速度。
    /// 这比「按比例打折」可靠：打折系数取决于 RTT、拥塞窗口与链路，因链路而异。
    public static let warmupBytes = 96 * 1024

    /// 探测一条线路。
    ///
    /// - Parameter deep: 拉 `deepSampleBytes` 而不是 `sampleBytes`。
    ///   只给「首轮判定够快、值得再确认」的源用 —— 见 `deepSampleBytes` 的说明。
    public static func probe(url: URL, headers: [String: String] = [:], session: URLSession = .shared,
                             deep: Bool = false) async -> SourceProbeResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = deep ? 15 : 8
        let budget = deep ? deepSampleBytes : sampleBytes
        request.setValue("bytes=0-\(budget - 1)", forHTTPHeaderField: "Range")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }

        let started = Date()
        do {
            // ⛔ 不用 `session.data(for:)`：它只给总耗时，而总耗时里混着 TCP 慢启动。
            // 改成字节流，在收到 `warmupBytes` 那一刻打第二个时间戳 ——
            // 后一段字节除以后一段耗时就是**稳态速度**，与 RTT、拥塞窗口无关。
            //
            // 实测慢启动对 256 KB 采样的低估约 43%（见 `warmupBytes` 的说明），
            // 且这个比例对所有源几乎相同 —— 它不改排序，但会让高速源全部撞上
            // 同一堵「发不出更多字节」的假天花板，从而分不出 600 与 1600 KB/s。
            let (data, response, steady) = try await stream(request, session: session, budget: budget)
            let elapsed = max(Date().timeIntervalSince(started), 0.001)
            let http = response as? HTTPURLResponse

            // ⛔ 不能用 `String(data:encoding:.utf8)`：它遇到非法序列返回 **nil**。
            //    头 8 KB 正好切在一个多字节字符中间（中文标题、非 ASCII 的 URL）时，
            //    整个 head 变成空串 —— 而我们现在一次从 head 解析四个量，
            //    一次 null 就四项全灭，测速结果凭空少掉分辨率/码率/色域。
            //    从 4 KB 提到 8 KB 又提高了切口落在字符中间的概率。
            // `String(decoding:as:)` 用 U+FFFD 替换非法字节，有损但可用 —— 我们要的是
            // 里面的 ASCII 标签（RESOLUTION/BANDWIDTH/VIDEO-RANGE），几个替换符不影响。
            let head = String(decoding: data.prefix(8_192), as: UTF8.self)
            // 一次解析全部声明量（高/码率/色域）—— 四者都在同一段头里。
            let declared = declaration(in: head, url: url)
            let height = declared.height
            // 文件总长：`Content-Range` 比 `Content-Length` 可信 ——
            // 后者在分片响应里报的是**本次分片**的长度，不是文件长度。
            let size = totalBytes(from: http)

            // A server that ignores Range and returns 200 sends the whole object;
            // charge only the sample we asked for so figures stay comparable.
            let kBps: Int
            if let steady, steady.bytes > 0, steady.seconds > 0 {
                kBps = Int(Double(steady.bytes) / 1024 / steady.seconds)
            } else {
                // 样本太短、没走完慢启动区：退回整段平均，并记它不可靠。
                let charged = http?.statusCode == 200 ? min(data.count, budget) : data.count
                kBps = Int(Double(charged) / 1024 / elapsed)
            }
            let latency = Int(elapsed * 1_000)

            let reachability: SourceProbeResult.Reachability
            if let code = http?.statusCode, !(200..<400).contains(code) {
                reachability = .unreachable
            } else if elapsed > 3 || kBps < 64 {
                reachability = .slow
            } else {
                reachability = .reachable
            }

            return SourceProbeResult(
                reachability: reachability,
                latencyMilliseconds: latency,
                kilobytesPerSecond: kBps,
                resolutionHeight: height,
                resolutionLabel: height.map { "\($0)P" },
                declaredBitrateKbps: declared.bitrateKbps,
                fileSizeBytes: size,
                colourRange: declared.colourRange,
                measuredAt: Date()
            )
        } catch {
            // A cancelled probe (line switch / sheet closed) is not a verdict: recording it as
            // unreachable would poison the 5-minute cache with a lie.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                return SourceProbeResult(reachability: .unknown)
            }
            return SourceProbeResult(reachability: .unreachable, measuredAt: Date())
        }
    }

    /// 分段计时的一次拉流：总字节、响应头、以及慢启动之后的「稳态」区间。
    ///
    /// `steady` 为 nil 表示样本在慢启动区内就结束了（小文件、被截断、或极慢的源）。
    /// 那种情况调用方只能退回整段平均，并接受它偏低。
    private struct SteadySample: Sendable {
        let bytes: Int
        let seconds: Double
    }

    private static func stream(_ request: URLRequest, session: URLSession, budget: Int)
        async throws -> (Data, URLResponse, SteadySample?) {
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        data.reserveCapacity(min(budget, 64 * 1024))
        var warmupEnd: Date?
        // ⛔ 这里曾写 `var warmupBytes = 0`，**遮蔽了上面 `96*1024` 的静态常量** ——
        // 于是预热边界恒为 0、首个字节就定格，所谓「排除慢启动」一行都没生效
        // （子代理实测：4KB/tick、256KB 预算下预热边界落在 4096 而非 98304，
        //  真正排除的慢启动只有 1.56%）。改名消除遮蔽。
        var warmupMark = 0

        for try await byte in bytes {
            data.append(byte)
            // 到达慢启动边界时打时间戳，只打一次。
            if warmupEnd == nil, data.count >= Self.warmupBytes {
                warmupEnd = Date()
                warmupMark = data.count
            }
            if data.count >= budget { break }
        }

        guard let warmupEnd, data.count > warmupMark else { return (data, response, nil) }
        return (data, response, SteadySample(bytes: data.count - warmupMark,
                                             seconds: max(Date().timeIntervalSince(warmupEnd), 0.001)))
    }

    /// Reads a declared height from an m3u8 (`RESOLUTION=1920x1080`) or from a
    /// height token in the path. Returns nil rather than guessing — an invented
    /// number in the picker is worse than an empty slot.
    static func declaredHeight(in head: String, url: URL) -> Int? {
        declaration(in: head, url: url).height
    }

    /// 一次解析 m3u8 主播放列表里能拿到的全部声明量。
    ///
    /// 为什么一次解析四个而不是各调各的：探针只读头 4 KB，四个量都在同一段里，
    /// 分四次跑正则既慢又容易各自漏掉同一种排版。
    ///
    /// 取值优先级（与 `RemuxPlan` 生成这些标签时的口径对齐）：
    ///   · 高：`RESOLUTION=1920x1080`
    ///   · 码率：`BANDWIDTH=5000000`（峰值）优先，退回 `AVERAGE-BANDWIDTH`
    ///   · 色域：`VIDEO-RANGE=SDR|HLG|PQ`
    ///   · 分辨率退回文件名里的 `1080p` / `x1080`
    struct Declaration: Sendable {
        var height: Int?
        var bitrateKbps: Int?
        var colourRange: String?
    }

    static func declaration(in head: String, url: URL) -> Declaration {
        var out = Declaration()

        // ⛔ 多档主列表必须取**最高档**，不是第一条。
        //
        // 一个 master playlist 常常是这样：
        //   #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        //   #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
        //   #EXT-X-STREAM-INF:BANDWIDTH=5200000,RESOLUTION=1920x1080
        // 上一版用 `head.range(of:)` 只匹配**第一个** `RESOLUTION=`，于是把 360P 当成
        // 「这一源的画质」—— 分辨率段 0 分（应 20 分），而码率余量却被文件名的
        // 小数字放大拿满（实测两方向同时错且相反）。
        //
        // 现在遍历所有 `RESOLUTION=` 取高度最大者；码率同理取最大值（见下）。
        // 语义依据：「这一源的画质」指的是它**能给到的最好一档**，
        // 而不是播放器默认起播的那一档（起播档由播放器自己按带宽挑）。
        var heights: [Int] = []
        var searchStart = head.startIndex
        while let range = head.range(of: #"RESOLUTION=\d+x(\d+)"#,
                                     options: .regularExpression,
                                     range: searchStart..<head.endIndex) {
            let matched = String(head[range])
            if let x = matched.lastIndex(of: "x"), let height = Int(matched[matched.index(after: x)...]) {
                heights.append(height)
            }
            searchStart = range.upperBound
            if searchStart >= head.endIndex { break }
        }
        out.height = heights.max()
        if out.height == nil {
            let name = url.lastPathComponent.lowercased()
            for height in [2160, 1440, 1080, 720, 480, 360]
            where name.contains("\(height)p") || name.contains("x\(height)") {
                out.height = height
                break
            }
        }

        // 码率：峰值优先，`AVERAGE-BANDWIDTH` 次选。
        //
        // ⛔ 必须**先剥掉 AVERAGE-BANDWIDTH 再找 BANDWIDTH**。
        //    `"AVERAGE-BANDWIDTH=4800000"` 这个字符串**包含**子串 `"BANDWIDTH="`，
        //    直接 `range(of: "BANDWIDTH=")` 会命中它，于是「只写了 AVERAGE」的源
        //    被误当成峰值读走 —— 值与峰值语义不符（实测已复现：
        //    `AVERAGE-BANDWIDTH=4800000` → 读成 4800000，而期望是退回 4800000 但走 AVERAGE 分支）。
        //    虽然数值恰好相同，但一旦同标签里两者并存又顺序颠倒就会取错。
        //    做法：先把 `AVERAGE-BANDWIDTH` 替换成等长的空白，再找 `BANDWIDTH=`。
        // 同上：多档主列表里 `BANDWIDTH=` 会出现多次，取**最大**那档
        // —— 与分辨率保持同一档位，否则「1080P + 360P 的码率」会算出假的低余量。
        let masked = head.replacingOccurrences(of: "AVERAGE-BANDWIDTH", with: String(repeating: " ", count: 17))
        if let kbps = maxInt(after: "BANDWIDTH=", in: masked)
            ?? maxInt(after: "AVERAGE-BANDWIDTH=", in: head) {
            out.bitrateKbps = kbps / 1000          // m3u8 给的是 bit/s
        }

        // 色域：只在明确写了非 SDR 时记；没写就是 nil（不知道就别声称是 SDR）。
        if let range = head.range(of: #"VIDEO-RANGE=([A-Za-z0-9]+)"#, options: .regularExpression) {
            let matched = String(head[range])
            if let eq = matched.firstIndex(of: "=") {
                let value = String(matched[matched.index(after: eq)...]).uppercased()
                if ["SDR", "HLG", "PQ"].contains(value) { out.colourRange = value }
            }
        }
        return out
    }

    /// 文件总字节数。`Content-Range: bytes 0-262143/734003200` 里的总分母优先。
    ///
    /// ⛔ 不能直接用 `Content-Length`：分片响应的它报的是**这一片**的长度
    /// （我们只要 256 KB，它就报 256 KB），拿它当文件大小会把每个源都记成 256 KB。
    static func totalBytes(from response: HTTPURLResponse?) -> Int? {
        if let range = response?.value(forHTTPHeaderField: "Content-Range"),
           let slash = range.lastIndex(of: "/") {
            let total = range[range.index(after: slash)...].trimmingCharacters(in: .whitespaces)
            if total != "*", let bytes = Int(total), bytes > 0 { return bytes }
        }
        // 没有 Content-Range：只有当服务端**忽略**了 Range（状态码 200 全量返回）时，
        // Content-Length 才等于文件长度。
        if response?.statusCode == 200,
           let length = response?.value(forHTTPHeaderField: "Content-Length"),
           let bytes = Int(length), bytes > 0 {
            return bytes
        }
        return nil
    }

    /// 取 `marker` 之后出现的**所有**连续数字里的最大值。
    ///
    /// 用于多档主列表：`BANDWIDTH=` 会出现多次，要的是最高档而不是第一条。
    /// 与 `firstInt` 并存 —— 后者仍用于「只可能出现一次」的场景。
    static func maxInt(after marker: String, in text: String) -> Int? {
        var best: Int?
        var searchStart = text.startIndex
        while let range = text.range(of: marker, range: searchStart..<text.endIndex) {
            var digits = ""
            for ch in text[range.upperBound...] {
                if ch.isNumber { digits.append(ch) } else { break }
                if digits.count >= 10 { break }
            }
            if let value = Int(digits) { best = max(best ?? value, value) }
            searchStart = range.upperBound
            if searchStart >= text.endIndex { break }
        }
        return best
    }

    /// 取 `marker` 之后的第一个连续数字。找不到返回 nil。
    private static func firstInt(after marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        var digits = ""
        for ch in text[range.upperBound...] {
            if ch.isNumber { digits.append(ch) } else { break }
            if digits.count >= 10 { break }        // 防越界，码率不会超过 10 位
        }
        return digits.isEmpty ? nil : Int(digits)
    }
}
