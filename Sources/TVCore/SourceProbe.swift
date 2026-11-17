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
    /// 同一档声明的宽度。单独存是为了算**长边**：竖屏短剧 1080×1920 的高度是 1920、
    /// 电影 1920×818 的高度只有 818，只按高度比较会把 720p 竖屏排到 1080p 电影前面。
    public var resolutionWidth: Int?
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
    /// 这条地址回的到底是什么：`hls` / `mp4` / `ts` / `mkv` / `html` / `json` / `other`。
    ///
    /// 为什么必须单独存：`reachability` 只回答「有没有字节回来」，而**一张网页也回 200 和几十 KB**。
    /// 采集站把「云播 / 平台页」当播放地址返回是常态（`feifan` / `xlyun` / `youku` / `qiyi` …），
    /// 只看 reachable 会把它们显示成绿色「120 ms」——用户点进去转圈到超时，
    /// 而我们这边还认为这条线是好的。看剧AI 修过同一个洞（`lineAlive` → `mediaAlive`）。
    public var mediaKind: String?
    public var measuredAt: Date

    public init(
        reachability: Reachability = .unknown,
        latencyMilliseconds: Int? = nil,
        kilobytesPerSecond: Int? = nil,
        resolutionHeight: Int? = nil,
        resolutionWidth: Int? = nil,
        resolutionLabel: String? = nil,
        declaredBitrateKbps: Int? = nil,
        fileSizeBytes: Int? = nil,
        colourRange: String? = nil,
        mediaKind: String? = nil,
        measuredAt: Date = .distantPast,
        declaredConflicted: Bool? = nil,
        declared: Bool? = nil
    ) {
        self.reachability = reachability
        self.latencyMilliseconds = latencyMilliseconds
        self.kilobytesPerSecond = kilobytesPerSecond
        self.resolutionHeight = resolutionHeight
        self.resolutionWidth = resolutionWidth
        self.resolutionLabel = resolutionLabel
        self.declaredBitrateKbps = declaredBitrateKbps
        self.fileSizeBytes = fileSizeBytes
        self.colourRange = colourRange
        self.mediaKind = mediaKind
        self.measuredAt = measuredAt
        self.declaredConflicted = declaredConflicted
        self.declared = declared
    }

    public static let unknown = SourceProbeResult()

    /// 读数是否已经过时。
    ///
    /// `tolerance` 默认取 `SourceProbeStore.staleness`（与「测速时跳过多久以内的读数」同一个值），
    /// 而不是各写一个常数：这两个问题其实是同一个 —— 「多旧的读数还算数」。
    /// 它们曾经不同（这里 300 秒、`Store.probeMaxAge` 600 秒），于是同一个源可能在选集页被判
    /// 「过期要重测」，在点播源页却被当成「新鲜」直接跳过，两处对同一条读数给出相反结论。
    /// 这一条读数是否说明「这条线路现在能用」。
    ///
    /// **全仓唯一判据出口。** 这不是为了少写几行：此前 15 处各自写
    /// `reachability != .unreachable` 或 `== .unreachable`，而它们对 `.unknown` 的处理并不一致 ——
    /// `LineMatrix` 把 `.unknown` 排除（不能用的意思），别的处当它是「没死」。
    /// 于是同一个源可能在一页「能用」、在另一页「测不到」，而两处都自称读的是同一个读数。
    ///
    /// 口径定在这里：
    /// - `.reachable` / `.slow` → 能用（慢不等于不能用，卡顿才是问题，而卡顿由速度字段表达）
    /// - `.unreachable` → 不能用
    /// - `.unknown` → **不能用**，但和「不可用」不是一回事：它是「这次没测出来」。
    ///   需要区分这两种情形的地方读 `reachability` 本身，不要拿本属性当唯一真相。
    public var isUsable: Bool {
        switch reachability {
        case .reachable, .slow: true
        case .unreachable, .unknown: false
        }
    }

    /// 回的是一张网页 / 一段 JSON，不是媒体。
    ///
    /// 与 `isUsable` 分开：`isUsable` 决定「这个源整体算不算能用」（会影响源排序与筛选口径，
    /// 不能因为一条线是网页就把整源判死）；这里只回答「这条**线**要不要先解析」。
    public var isPageOnly: Bool { mediaKind == "html" || mediaKind == "json" }

    /// 画面长边。只按高度比会把竖屏和宽银幕判反（见 `resolutionWidth`）。
    public var longEdge: Int? {
        if let width = resolutionWidth, let height = resolutionHeight { return max(width, height) }
        return resolutionHeight ?? resolutionWidth
    }

    public func isStale(now: Date = Date(), tolerance: TimeInterval = sourceProbeStaleness) -> Bool {
        now.timeIntervalSince(measuredAt) > tolerance
    }

    /// 这条读数还配不配当「它现在能用」的证据。
    ///
    /// 与 `isStale` 是两个问题，别混：
    /// - `isStale`（600 秒）：**要不要再测一遍**。短，因为重测便宜。
    /// - `isExpired`（7 天 / 包内 30 天）：**能不能拿它下结论**。长，因为结论要稳。
    ///
    /// 没有这一层，一个三周前测死的源会永远算「不通」：只看能播据此把它永久藏起来，
    /// 分组头的红徽标也永远不消 —— 筛选就从「现在能不能用」退化成了「历史结论」。
    public func isExpired(now: Date = Date()) -> Bool {
        let window = declared == true
            ? SourceConnectivity.declaredTrustWindow
            : SourceConnectivity.measuredTrustWindow
        return now.timeIntervalSince(measuredAt) > window
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
        // ⛔ 这套阶梯与 `SourceConnectivity.requiredSpeed(for:)` 是**同一套**（3000 / 750 / 375 / 150）：
        // 一处问「这个画质撑得住多快」，另一处问「够不够这个画质」，答案必须一致。
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

    /// 这条读数是从**随包配置里读来的**，不是这台设备量的。
    ///
    /// ⛔ 为什么要单独一个标记，而不是比较 `measuredAt`：
    ///
    /// 1. **真测必须永远压过包标签**。此前导入层给每条包内读数打的是「此刻」的时间戳
    ///    （`SourceProbeImport.reading` 的 `measuredAt: Date = Date()`），于是「昨天真测出来
    ///    这源不通」会被「包里写着直连」按时间压掉 —— 方向正好反了。比时间更可靠的是来源：
    ///    自测过的源，任何一次导入都不该再改动它。
    /// 2. **包标签不算「刚测过」**。`Store.needsProbing` 跳过十分钟内的读数；包内读数若带
    ///    此刻的时间戳，新装或刚刷新之后「测这一组 / 全部测速」会把所有源当新鲜的跳过，
    ///    按钮等于没反应。
    /// 3. 界面上也说得清：这一条是「打包时的结论」，不是「你刚才量的」。
    ///
    /// ⛔ **必须是 Optional**：`SourceProbeResult` 用合成的 `init(from:)`，非 Optional 属性
    /// 即使有默认值也不参与解码，缺键直接抛 `keyNotFound` —— 老用户的整张读数表会被
    /// `try?` 吞成空字典（`declaredConflicted` 的注释里记着这次事故的完整链条）。
    public var declared: Bool? = nil

    /// Compact line for the picker's subtitle, e.g. "1080P · 320 ms · 2.4 MB/s".
    ///
    /// ⛔ 画质用**有效值**，不是 `resolutionLabel` 里那个声明值。
    /// 实测 26% 的源标称画质撑不住自己的速度（「乐播 1080P」只有 62 KB/s）；
    /// 显示声明值等于把虚标原样转述给用户，而用户正是靠这一行判断要不要用这个源。
    /// 声明高于能力时补一个 `~` 前缀（`~720p`），让「被压下来」这件事看得见 ——
    /// 不写 `~` 的话用户以为源只支持 720p，而实际是它声称 1080p 但喂不动。
    public func summary() -> String {
        // 网页型线路先说实话：它不是慢、也不是通，是「播放器打不开」。
        if isPageOnly { return L10n.text("Needs parsing") }
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
///
/// `@Observable` 不是为了时髦：这个类此前是**普通类**，`revision` 只是「自增的数字」，
/// 视图里的 `.onChange(of: SourceProbeStore.shared.revision)` 于是只在别的可观察状态
/// （扫描进度）恰好同时变化时才顺带看到新值。选集页单独测出来的读数不经过扫描，
/// 源列表的分组头徽标与书架就永远不更新 —— 注释里写要覆盖的正是这种情形。
/// 加上 `@Observable` 之后，视图 body 里读到的 `health` / `revision` 会被登记成依赖，
/// 读数一落盘就重画，与 `revision` 有没有被单独观察到无关。
@MainActor @Observable
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
    /// 按 base(host) 的延迟表 —— **One 的 `latencyByBase` 的等价物**。
    ///
    /// ⛔ 这一张表补的是最贵的一处口径差异（RCA H4）。
    ///
    /// One 的 `PlayLines` 只有 `latencyByBase: [String: Int]`（interface.swift:1392-1399），
    /// 键是 **base = host**，没有「哪部剧」「哪一集」这两个维度。于是一部剧测过的线路延迟，
    /// 换到同源的任何另一部剧都直接命中、立即显示。
    ///
    /// 我方的 `probes` 表键是 `sourceKey|videoID|lineFlag`（见 `storageKey`）——
    /// 换一部剧就全部 miss，播放页于是**每进一部新剧都把全部线路重测一遍**。
    /// 这就是「进播放页初期特别慢」在数据层的根因：不是测一次，是每部剧都测一次。
    ///
    /// 这里不改 `probes` 的键（那套键回答的是「这部这集这条线」的历史读数，仍有用），
    /// 而是**并排加一张 base 级表**：一条线路只要测过一次，同 host 的其它剧立刻可用。
    /// 读数新鲜度仍按 `sourceProbeStaleness` 判。
    private static let baseKey = "player.playLine.baseLatency"

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
    /// 按 base(host) 的延迟读数 —— One `latencyByBase` 的等价物，见 `baseKey` 的说明。
    ///
    /// 键是 host（不含 scheme / 路径），值是那条 base 上「最近一次测到的」读数。
    /// 存整条 `SourceProbeResult` 而不是只存毫秒：播放页除了延迟还要显示速度与画质，
    /// 只留毫秒会让同 host 的其它剧显示「120 ms」却对速度一无所知 —— 那仍是半张表。
    private var baseLatency: [String: SourceProbeResult]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 全部先算在局部变量里，最后一次性赋值。
        //
        // ⛔ `@Observable` 之后不能一边赋值一边读：宏把每个存储属性改写成 `_x` + computed，
        // 在「所有存储属性都初始化完」之前读任何一个（哪怕只是 `health[key] = value`）
        // 都是 `self used before all stored properties are initialized`。旧写法能编过，
        // 是因为普通类没有这层改写。
        var probes: [String: SourceProbeResult] = [:]
        if let blob = defaults.data(forKey: Self.probeKey),
           let decoded = try? JSONDecoder().decode([String: SourceProbeResult].self, from: blob) {
            probes = decoded
        }
        var order = defaults.stringArray(forKey: Self.orderKey) ?? []
        for key in probes.keys where !order.contains(key) { order.append(key) }
        var health: [String: SourceProbeResult] = [:]
        if let blob = defaults.data(forKey: Self.healthKey),
           let decoded = try? JSONDecoder().decode([String: SourceProbeResult].self, from: blob) {
            health = decoded
        }
        var baseLatency: [String: SourceProbeResult] = [:]
        if let blob = defaults.data(forKey: Self.baseKey),
           let decoded = try? JSONDecoder().decode([String: SourceProbeResult].self, from: blob) {
            baseLatency = decoded
        }
        // Readings written before this table existed still answer `latest`: fold the newest detail
        // row of each source in once, so an upgrade does not look like a library nobody measured.
        for (key, value) in probes {
            guard let bar = key.firstIndex(of: "|") else { continue }
            let sourceKey = String(key[key.startIndex..<bar])
            guard let seen = health[sourceKey] else { health[sourceKey] = value; continue }
            if value.measuredAt > seen.measuredAt { health[sourceKey] = value }
        }
        var rotation = HostRotation()
        if let blob = defaults.data(forKey: Self.rotationKey),
           let decoded = try? JSONDecoder().decode(HostRotation.self, from: blob) {
            rotation = decoded
        }
        var learning = HostLearning()
        if let blob = defaults.data(forKey: Self.learningKey),
           let decoded = try? JSONDecoder().decode(HostLearning.self, from: blob) {
            learning = decoded
        }
        self.probes = probes
        self.order = order
        self.health = health
        self.baseLatency = baseLatency
        self.rotation = rotation
        self.learning = learning
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

    // MARK: - 全局在飞上限与轮次（One `pendingTests` / `generation` 的等价物）

    /// 同时在飞的探针总数上限 —— One 的 `PlayLines.pendingTests` 就是干这件事的。
    ///
    /// ⛔ 没有这一层时（RCA H5），每个测速入口各自限并发，但它们**互不知情**：
    /// 播放页 `buildLineSamples` 4~9 条、选集面板 `probeAll` 4 条、跨源矩阵 3 源 × 每条线、
    /// 全量扫描 32 源 × 每条线 —— 叠加起来能同时打出几十个请求，
    /// 而它们抢的正是用户此刻要用来起播的那条链路。
    ///
    /// 6 的依据：`probeSession` 每 host 允许 4 条（见 `probeSession`），跨 host 的探针
    /// 留 2 条余量。再多也不会更快 —— 瓶颈在用户带宽，不在探针数量。
    public static let maxGlobalProbes = 6
    private var globalInflight = 0
    /// 等名额的挂起器，先进先出。见 `waitForProbeSlot`。
    private var slotWaiters: [SlotWaiter] = []

    /// 一个排队者。带 `id` 是为了能在超时/取消时**精确**把自己摘掉 ——
    /// `CheckedContinuation` 本身不可比较，光凭它找不到队列里哪一个是自己。
    private struct SlotWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    /// 探针轮次。每个「一轮测速」开始时取一个新值；轮次变了就说明用户换了集/换了线/重进页面，
    /// 旧轮次还在跑的探针应当自己收手，而不是把结果写进新一轮的界面。
    ///
    /// One 用同样的办法（`PlayLines.generation`）解决「旧一轮的延迟数字飘进新一轮」。
    public private(set) var probeGeneration = 0

    /// 开始新的一轮：作废此前所有在跑的轮次，返回新轮次号。
    @discardableResult
    public func beginProbeGeneration() -> Int {
        probeGeneration += 1
        return probeGeneration
    }

    /// 这一轮还算不算当前的。
    public func isCurrentGeneration(_ generation: Int) -> Bool { generation == probeGeneration }

    /// 领一个全局探针名额。false = 已经满了，调用方应当**跳过这一条**（不是判它死）。
    ///
    /// 与 `beginBase` 的分工：那个按 host 限流（别把某个站打急），这个按全局限流
    /// （别把用户这条链路占满）。两层都过才发请求。
    public func claimProbeSlot() -> Bool {
        guard globalInflight < Self.maxGlobalProbes else { return false }
        globalInflight += 1
        return true
    }

    /// 归还名额。必须与 `claimProbeSlot()` 成对，用 `defer` 保证异常路径也归还。
    ///
    /// 归还时若有排队者，**把名额直接移交**给最前面那个：全局计数不降、唤醒等待者。
    /// 这样既不会"唤醒了却抢不到"（饥饿），也不会把同一个名额算两次。
    public func releaseProbeSlot() {
        if !slotWaiters.isEmpty {
            let waiter = slotWaiters.removeFirst()
            waiter.continuation.resume(returning: true)
            return
        }
        globalInflight = max(0, globalInflight - 1)
    }

    /// 排队等一个探针名额。
    ///
    /// ⛔ 这一条修的是「用户点了线路却什么都不发生」。
    ///
    /// 原先调用方拿到 `claimProbeSlot() == false` 就 `return` —— 名额被别的入口
    /// （播放页摸底、跨源矩阵、全量扫描）占满时，用户的点击**静默丢失**，
    /// 界面上既不显示数字也不报错，看起来就是坏了。
    ///
    /// 现在排队；名额由 `releaseProbeSlot` 一对一移交，不会有同批等待者互抢的饥饿。
    /// 等待有上限：超过 `budget` 返回 false —— 那时确实该放弃
    /// （前面还排着几十个同类请求），让调用方按"未测"处理比无限等更诚实。
    ///
    /// ## 谁该排队、谁该跳过
    ///
    /// 这条区分很重要，别一律改成本函数：
    ///
    ///   · **交互路径要排队** —— 用户点了某条线路、按了「重新测速」。
    ///     他正盯着这一条等结果，跳过等于"点了没反应"。用 `waitForProbeSlot`。
    ///   · **批量路径要跳过** —— 全量扫描（340 源 × 4 线）、跨源矩阵、跨源测速。
    ///     这些请求本身就在互相争名额，让它们排队只会把整轮扫描拖成串行，
    ///     用户看到的是进度条几分钟不动。跳过（保持 `claimProbeSlot`）并计入
    ///     "本轮未测"才是诚实的处理。
    public var slotBacklog: Int { slotWaiters.count }
    public func waitForProbeSlot(budget: Duration = .seconds(20)) async -> Bool {
        if claimProbeSlot() { return true }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                slotWaiters.append(SlotWaiter(id: id, continuation: continuation))
                // 到点仍未轮到：把自己摘出队列（`cancelSlotWaiter` 幂等，摘到就回 false）。
                Task { [weak self] in
                    try? await Task.sleep(for: budget)
                    self?.cancelSlotWaiter(id: id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelSlotWaiter(id: id) }
        }
    }

    /// 把一个还在排队的等待者摘掉并返回 false。已轮到或被移走时什么也不做。
    ///
    /// `slotWaiters` 是 `@MainActor` 隔离的（`SourceProbeStore` 整体如此），
    /// 所以这里就是唯一的写入口，不需要额外加锁。
    private func cancelSlotWaiter(id: UUID) {
        guard let index = slotWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = slotWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    /// 当前在飞数，供诊断面板。
    public var inflightProbes: Int { globalInflight }

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

    /// 给「默认线路」用的一份画质读数：某个 flag 当前**可信**的长边，没有就 nil。
    ///
    /// 三条都要过：新鲜（不是几天前测的）、能用（不是不可达/没测出）、不是网页型
    /// （网页型没有画质，把它算成 0 反而会把它排到最前）。
    /// 返回值是闭包而不是字典，是因为 `LinePreference.choose` 只在需要时才问，
    /// 而「需要」与否取决于有没有历史线路 —— 先算全表纯属浪费。
    public func qualityReader(sourceKey: String, videoID: String,
                              now: Date = Date()) -> (String) -> Int? {
        { [weak self] flag in
            guard let reading = self?.probe(sourceKey: sourceKey, videoID: videoID, lineFlag: flag),
                  !reading.isStale(now: now), reading.isUsable, !reading.isPageOnly
            else { return nil }
            return reading.longEdge
        }
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
        baseLatency.removeAll()
        persistNow()
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

    /// 刚测到「能播」之后，多久之内的失败不覆盖它。
    ///
    /// 一次探针失败常常是抖动（边缘节点、回源超时），而一次覆盖就是界面上的红点「不通」
    /// 加「按结果分组」把这条线搬走 —— 用户点进去却能播。
    /// 两分钟足够滤掉抖动，也不至于把真的掉线藏起来（用户手动重测时旧读数大概率已经过期）。
    nonisolated public static let failureGrace: TimeInterval = 120

    /// 这条新读数是否应当被丢弃（旧读数更新鲜且可用，新读数只是失败）。
    nonisolated static func shouldKeepExisting(_ existing: SourceProbeResult, over result: SourceProbeResult) -> Bool {
        guard existing.isUsable, !result.isUsable else { return false }
        return result.measuredAt.timeIntervalSince(existing.measuredAt) < failureGrace
    }

    public func record(_ result: SourceProbeResult, sourceKey: String, videoID: String, lineFlag: String) {
        guard !lineFlag.isEmpty else { return }
        let key = storageKey(sourceKey: sourceKey, videoID: videoID, lineFlag: lineFlag)
        if let existing = probes[key], Self.shouldKeepExisting(existing, over: result) { return }
        probes[key] = result
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.limit {
            probes.removeValue(forKey: order.removeFirst())
        }
        note(result, for: sourceKey)
        persistSummary()
        schedulePersistDetail()
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
            if let seen = health[sourceKey] {
                // ① 自测过的源，包内标签一律不再改动它。
                //
                //    旧写法只比时间戳，而导入层给包内读数打的是「此刻」——
                //    于是每次刷新订阅都会把用户昨天真测的结论按时间压掉。
                //    来源比时间可靠：不是这台设备量的，就没有资格覆盖这台设备量到的。
                if seen.declared != true { continue }
                // ② 同一条标签，内容没变就别重写（否则每次启动都要把整张表编码一遍）。
                if seen == reading { continue }
                // ③ 两份都来自包：新的那份更新，用新的。
                if seen.measuredAt > reading.measuredAt { continue }
            }
            health[sourceKey] = reading
            written += 1
        }
        guard written > 0 else { return 0 }
        persistNow()
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
            if let existing = probes[key], Self.shouldKeepExisting(existing, over: row.result) { continue }
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
        persistNow()
        revision += 1
    }

    /// Files one reading as a source's standing reading, keeping the newer of the two.
    private func note(_ result: SourceProbeResult, for sourceKey: String) {
        guard let seen = health[sourceKey] else { health[sourceKey] = result; return }
        if result.measuredAt >= seen.measuredAt { health[sourceKey] = result }
    }

    /// Writes the readings once, after a batch.
    // MARK: - 写盘：小表立即、大表合并

    /// ⛔ 这一处是「测速时播放页发卡」的第二个成因（RCA H7，已基准实测）。
    ///
    /// 原来的 `persist()` 每次都把 `probes`（上限 4000 行）**和** `health` 一起重新
    /// JSON 编码并写 UserDefaults，跑在主 actor 上 —— 实测单次 **≈ 9.0 ms**
    /// （swiftc -O，4000 条明细 + 340 个源）。而 `record` 每记一条读数就同步调一次：
    /// 选集面板一次测 4 条线 = 主线程卡 36 ms；跨源矩阵一次 240 条 = 2.1 秒。
    ///
    /// 拆成两层，因为两张表的代价差一个数量级：
    ///   · **汇总表**（`health` + `baseLatency`）—— 756 个源 + 400 个 host 实测 ≈ 2.2 ms。
    ///     它小、且是「重启后还认不认这条读数」的唯一依据（`latest` / `measuredSourceCount`
    ///     都读它），所以**立即同步写**。早先版本把它也延迟了，`SourceProbeRankingTests`
    ///     的 `aReadingSurvivesARestartThroughTheSummaryTable` 当场抓出回归。
    ///   · **明细表**（`probes` + `order`）—— 4000 行，≈ 7 ms，而且只服务「这部剧每条线」
    ///     的界面。它被合并成 0.6 秒一次的写：崩溃最多丢 0.6 秒内的明细，
    ///     而明细重测即可 —— 不值得为它卡界面。
    private static let persistDelay: Duration = .milliseconds(600)
    private var persistTask: Task<Void, Never>?

    /// 立即写**汇总表**。每次 `record` 都调，代价 ≈ 2.2 ms。
    private func persistSummary() {
        if let encoded = try? JSONEncoder().encode(health) {
            defaults.set(encoded, forKey: Self.healthKey)
        }
        if let encoded = try? JSONEncoder().encode(baseLatency) {
            defaults.set(encoded, forKey: Self.baseKey)
        }
    }

    /// 排队写**明细表**（合并 0.6 秒）。
    private func schedulePersistDetail() {
        guard persistTask == nil else { return }
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: Self.persistDelay)
            guard !Task.isCancelled else { return }
            self?.persistTask = nil
            self?.persistDetail()
        }
    }

    private func persistDetail() {
        if let encoded = try? JSONEncoder().encode(probes) {
            defaults.set(encoded, forKey: Self.probeKey)
        }
        defaults.set(order, forKey: Self.orderKey)
    }

    /// 立即写全部（重置、清空、批量落定等「不写就可能丢」的场合）。
    private func persistNow() {
        persistTask?.cancel()
        persistTask = nil
        persistDetail()
        persistSummary()
    }

    private func persist() { persistNow() }

    // MARK: - 按 base(host) 的读数（One `latencyByBase` 的等价物）

    /// 这条线路所属 host 上已有的读数，**与是哪部剧无关**。
    ///
    /// 播放页在决定「要不要现在测这条线」时先问这个：同 host 刚测过就直接用，
    /// 于是换剧不再重测。这正是 One 的行为 —— 它的 `latencyByBase` 里根本没有剧的维度。
    ///
    /// - Parameter url: 该线路的真实流地址。取 host 作键。
    /// - Parameter maxAge: 多旧的读数还算数。默认与 `sourceProbeStaleness` 同源。
    /// - Returns: nil 表示这个 host 没测过（或读数已过期），调用方应当去测。
    public func baseReading(for url: URL, maxAge: TimeInterval = sourceProbeStaleness,
                            now: Date = Date()) -> SourceProbeResult? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        guard let reading = baseLatency[host] else { return nil }
        guard now.timeIntervalSince(reading.measuredAt) <= maxAge else { return nil }
        return reading
    }

    /// 记下一条读数属于哪个 host，供 `baseReading(for:)` 跨剧复用。
    ///
    /// 公开版本：批量路径（跨源矩阵）攒的是 `(result, flag)` 而不是 URL，
    /// 没法走 `record(_:sourceKey:videoID:lineFlag:url:)`，只好在这里单独登记。
    public func noteBasePublic(_ result: SourceProbeResult, url: URL) { noteBase(result, url: url) }

    private func noteBase(_ result: SourceProbeResult, url: URL) {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return }
        // 只保留更新的那条：同 host 的两部剧可能并发测完，后到的不该覆盖更新的读数。
        if let seen = baseLatency[host], seen.measuredAt > result.measuredAt { return }
        baseLatency[host] = result
    }

    /// 为了把 `probes` 的写入与 base 表对齐，`record` 系列都需要知道 URL。
    /// 现有的 `record` 签名里没有 URL —— 这里提供带 URL 的入口，调用方顺手传即可。
    public func record(_ result: SourceProbeResult, sourceKey: String, videoID: String,
                       lineFlag: String, url: URL?) {
        // host 表也要守同一条规矩：一次抖动若写进 `baseLatency`，同 host 的**其它剧**
        // 下次也会拿这条失败读数当「这个 CDN 不行」而跳过 —— 一条线抖，整台 CDN 陪葬。
        if !lineFlag.isEmpty,
           let existing = probes[storageKey(sourceKey: sourceKey, videoID: videoID, lineFlag: lineFlag)],
           Self.shouldKeepExisting(existing, over: result) { return }
        if let url { noteBase(result, url: url) }
        record(result, sourceKey: sourceKey, videoID: videoID, lineFlag: lineFlag)
    }

    public func record(_ rows: [(result: SourceProbeResult, lineFlag: String, url: URL?)],
                       sourceKey: String, videoID: String) {
        for row in rows {
            // 会被 `record` 丢掉的行（刚测到能播、这次只是失败）也不许写 host 表。
            if !row.lineFlag.isEmpty,
               let existing = probes[storageKey(sourceKey: sourceKey, videoID: videoID, lineFlag: row.lineFlag)],
               Self.shouldKeepExisting(existing, over: row.result) { continue }
            if let url = row.url { noteBase(row.result, url: url) }
        }
        record(rows.map { (result: $0.result, lineFlag: $0.lineFlag) },
               sourceKey: sourceKey, videoID: videoID)
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
        persistNow()
    }
}

// MARK: - Runner

/// Probes one line with a single ranged GET: enough to learn whether it answers,
/// how fast, and what the manifest declares — without pulling a whole segment.
public enum SourceProbeRunner {
    /// 探针专用的 URLSession —— **绝不与播放共用连接池**。
    ///
    /// ⛔ 这一条是「起播变慢」的直接成因之一（RCA H3）。此前探针默认走
    /// `URLSession.shared`，而 iOS 的 `httpMaximumConnectionsPerHost` 默认只有 6。
    /// 打开播放页会同时发生两件事：`buildLineSamples` 为每条线路解析并探测，选集面板
    /// 一弹开又对每条线各拉 256 KB。它们把 6 条连接占满，于是**播放器自己的
    /// m3u8 清单与分片请求排在后面**，用户看到的就是「黑屏转圈、起播比平时慢很多」。
    ///
    /// One 的对应物是 `MediaResolver.probeSession`（interface.swift:1158），
    /// 一个 `let probeSession: NSURLSession` —— 实测它把探针与播放分在两个会话里。
    /// 这里照做：探针用自己的池，且每 host 上限压到 4，让 CDN 永远留有余量给播放。
    ///
    /// `ephemeral` 而不是 `default`：探针的缓存没有任何价值（每次都是 Range 取新字节），
    /// 而 `default` 会在磁盘上留下几十 MB 的探测残留。
    public static let probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // 与 `LineRotation.maxConcurrent` 同值：同一 host 最多 4 条探针在飞。
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        // 起播时探针不该被系统当成「用户等待的前台流量」而与播放争优先级。
        configuration.networkServiceType = .background
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // 探针的字节没有任何复用价值（每次都是新 Range），连内存缓存都不要 ——
        // `ephemeral` 只是不给磁盘，它仍然会给一个内存缓存。
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    /// Bytes to pull when measuring throughput. Large enough to separate a
    /// healthy CDN from a stalled one, small enough to stay harmless on cellular.
    public static let sampleBytes = 256 * 1024

    /// 播放页在「用户还没点播放」时用的采样量。
    ///
    /// 128 KB 按 4 Mbps 算仍有 0.25 秒，足够分出发不出字节的死线与活线；
    /// 而它只有常规探针的一半流量 —— 播放页同时要跑 4~9 条线，
    /// 这一档把「进页面就吃掉 1 MB 下行」压到 512 KB 以内。
    public static let lightSampleBytes = 128 * 1024

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
    /// - Parameter light: 拉 `lightSampleBytes`。播放页在**用户还没点播放**时用它：
    ///   那时用户要的只是「哪条线是活的」，不是精确吞吐，不该为四个数字吃掉 1 MB。
    ///   `deep` 优先。
    /// - Parameter session: 默认走 `probeSession`（专用池），**不是** `.shared`。
    ///   传 `.shared` 会让探针重新与播放抢那 6 条连接 —— 见 `probeSession` 的说明。
    public static func probe(url: URL, headers: [String: String] = [:],
                             session: URLSession = SourceProbeRunner.probeSession,
                             deep: Bool = false, light: Bool = false) async -> SourceProbeResult {
        // 三条「不是 HTTP」的地址也必须能测：云盘文件（`tvbox-cloud`）、红果加密 MP4
        // （`tvbox-hongguo`）、重打包的 DASH（`tvbox-dash`）。它们由 App 内的资源加载器回答，
        // 直接发 `URLRequest` 必然失败 —— 于是这些源在每一轮扫描里都被判「不可达」，
        // 而它们在播放页明明能播。
        //
        // 它们并不神秘：每个都只是「给我某个文件的第 N..M 字节」。走同一个字节读取口，
        // 用同一套两段计时，测出来的就是**真实吞吐**，而不是「能不能发 HTTP」。
        if let source = await WebCastVirtualStreams.source(for: url) {
            return await probeVirtual(source, url: url, deep: deep)
        }
        // 是这三种 scheme 但解析不出流（还没注册、或注册已被回收）：**没测出来**，不是判死。
        // 落到下面的 `URLRequest` 会必然失败并被记成 `.unreachable` —— 那就把一个能播的源
        // 送进了「不通」分组。
        if let scheme = url.scheme, [CloudStreams.scheme, HongguoStreams.scheme, DashStreams.scheme].contains(scheme) {
            return SourceProbeResult(reachability: .unknown)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = deep ? 15 : 8
        let budget = deep ? deepSampleBytes : (light ? lightSampleBytes : sampleBytes)
        request.setValue("bytes=0-\(budget - 1)", forHTTPHeaderField: "Range")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }

        // 一次「没答复」不等于死线，所以给第二次机会。
        //
        // ⛔ 实测（2026-11-17，24 条被判死的线全量复测）：
        //    `v.lzcdn31.com/…/index.m3u8` 是一条正常的 1080×608 主清单（96 字节），
        //    第一轮探针却拿到一张 HTML 错误页 → 判「网页」；同一地址三种请求形态复测全部 200/206。
        //    这类抖动在采集站的 CDN 上很常见（边缘节点刚上线、回源超时），
        //    而一次误判会让这条线在界面上「不通」5–10 分钟 —— 用户点进去却能播。
        //    两次都失败才下结论；而且「拿不到答复」一律记 `.unknown`（未测），不记 `.unreachable`（不通）。
        var outcome = await attempt(request, url: url, budget: budget, session: session)
        if outcome.shouldRetry {
            try? await Task.sleep(for: .milliseconds(250))
            // 第二次更快收手：8 秒 + 8 秒 = 16 秒的等待对「点一条线的测速」太长。
            // 5 秒足够等到抖动过去（实测同一条线一秒内就回了 200）。
            var retry = request
            retry.timeoutInterval = min(request.timeoutInterval, 5)
            outcome = await attempt(retry, url: url, budget: budget, session: session)
        }
        // 两次都拿不到答复 → 「没测出来」，不是「不通」。
        //
        // 这个区分决定界面上是灰点「未测」还是红点「不通」，而后者会被
        // 「按结果分组」真的搬进「不通」组 —— 一条能播的线因此被藏起来。
        // 真正的死线仍会被判死：它们回 4xx/5xx，走的是另一条分支。
        guard outcome.noResponse else { return outcome.result }
        return SourceProbeResult(reachability: .unknown, measuredAt: outcome.result.measuredAt)
    }

    /// 一次探测的结果，外加「要不要再来一次」的判据。
    struct ProbeAttempt {
        var result: SourceProbeResult
        /// 值得再问一次：没拿到答复，或 200 却回了一张网页。
        var shouldRetry: Bool
        /// 一个字节的答复都没有（超时 / 连接被断 / TLS 握手失败）。
        ///
        /// 与「明确拒绝」分开：前者是**不知道**，后者才是**不能用**。
        /// 分不出来的代价就是用户看到的「标注不通，点进去却能播」。
        var noResponse = false
    }

    /// 真正发一次请求。判定口径与原来完全一致，只是把「重试」这件事交给了调用方。
    private static func attempt(_ request: URLRequest, url: URL,
                                budget: Int, session: URLSession) async -> ProbeAttempt {
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

            let kind = Self.mediaKind(of: data)
            let result = SourceProbeResult(
                reachability: reachability,
                latencyMilliseconds: latency,
                kilobytesPerSecond: kBps,
                resolutionHeight: height,
                resolutionWidth: declared.width,
                resolutionLabel: height.map { "\($0)P" },
                declaredBitrateKbps: declared.bitrateKbps,
                fileSizeBytes: size,
                colourRange: declared.colourRange,
                mediaKind: kind,
                measuredAt: Date()
            )
            // 200 却回了一张网页：采集站边缘节点紧张时会拿错误页顶替。
            // 这一档值得再问一次 —— 只有两次都是网页，才真的需要解析。
            return ProbeAttempt(result: result, shouldRetry: kind == "html")
        } catch {
            // A cancelled probe (line switch / sheet closed) is not a verdict: recording it as
            // unreachable would poison the 5-minute cache with a lie.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                return ProbeAttempt(result: SourceProbeResult(reachability: .unknown), shouldRetry: false)
            }
            // 拿不到答复：`timedOut` / `networkConnectionLost` / TLS 被断 / DNS 被污染。
            // 这些**都不是**「这条线死了」的证据 —— 真正的死线会明确回 4xx/5xx。
            // 实测同一条线隔一秒就回 200，把它记成 `.unreachable` 就是把能播的线送进「不通」。
            return ProbeAttempt(result: SourceProbeResult(reachability: .unreachable, measuredAt: Date()),
                                shouldRetry: true, noResponse: true)
        }
    }

    /// 这段字节是什么。只看魔数与前缀，不做解码 —— 判「播放器能不能打开」不需要知道编码，
    /// 需要的是分清**媒体**与**网页**。
    ///
    /// 与 `TVBoxProbe` 里那份同名实现同口径（那边用于线路审计）。
    public static func mediaKind(of data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let head = data.prefix(2_048)
        let text = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#EXTM3U") { return "hls" }
        if text.hasPrefix("<") { return "html" }
        if text.hasPrefix("{") || text.hasPrefix("[") { return "json" }
        if data.count >= 8, data[4..<8] == Data("ftyp".utf8) { return "mp4" }
        if data.count >= 376, data[0] == 0x47, data[188] == 0x47 { return "ts" }
        if head.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return "mkv" }
        return "other"
    }

    /// 测一条虚拟流：按 `sampleBytes` 读一段字节，用与 HTTP 探针**相同的两段计时**算稳态速度。
    ///
    /// 口径必须一致，否则同一个源在「选集页（HTTP 直测）」和「扫描（虚拟流）」里会给出两套数字。
    /// 这里不复用 `stream(_:session:budget:)`：那个函数吃 `URLRequest`，而这几个来源是 App 内的
    /// 字节流（云盘分块、红果解密、DASH 播放列表），没有请求可发。计时的算法是一样的：
    /// 前 `warmupBytes` 记时间戳，后一段的字节数除以后一段的耗时。
    private static func probeVirtual(_ source: WebCastVirtualStreams.Source,
                                     url: URL, deep: Bool) async -> SourceProbeResult {
        let budget = deep ? deepSampleBytes : sampleBytes
        // 播放列表（DASH）只有几百字节，长度已知即全文；读它本身就是「能不能拿到清单」。
        let total = await source.length()
        let started = Date()
        do {
            var received = 0
            var warmupEnd: Date?
            var warmupBytesSeen = 0
            // 分块读，块大小与 HTTP 路径的单次 `bytes(for:)` 批次同量级。
            let chunk = 32 * 1024
            while received < budget {
                let want = min(chunk, budget - received)
                let piece = try await source.read(at: received, count: want)
                if piece.isEmpty { break }
                received += piece.count
                if warmupEnd == nil {
                    warmupBytesSeen += piece.count
                    if warmupBytesSeen >= warmupBytes { warmupEnd = Date() }
                }
                if Task.isCancelled { return SourceProbeResult(reachability: .unknown) }
            }
            let elapsed = max(Date().timeIntervalSince(started), 0.001)
            guard received > 0 else {
                // 一个字节都拿不到：和 HTTP 路径的 4xx 等价，是「这条线不通」。
                return SourceProbeResult(reachability: .unreachable, measuredAt: Date())
            }
            // 稳态速度：慢启动之后那一段。没走完预热区就退回整段平均，并如实偏低。
            let kBps: Int
            if let warmupEnd {
                let steadyBytes = received - warmupBytesSeen
                let steadySeconds = Date().timeIntervalSince(warmupEnd)
                if steadyBytes > 0, steadySeconds > 0 {
                    kBps = Int(Double(steadyBytes) / 1024 / steadySeconds)
                } else {
                    kBps = Int(Double(received) / 1024 / elapsed)
                }
            } else {
                kBps = Int(Double(received) / 1024 / elapsed)
            }
            let latency = Int(elapsed * 1_000)
            let reachability: SourceProbeResult.Reachability =
                elapsed > 3 || kBps < 64 ? .slow : .reachable
            return SourceProbeResult(
                reachability: reachability,
                latencyMilliseconds: latency,
                kilobytesPerSecond: kBps,
                // 虚拟流的画质不由 URL 声明，来源本身已经知道分辨率；这里不猜。
                resolutionHeight: nil,
                resolutionLabel: nil,
                fileSizeBytes: total,
                measuredAt: Date()
            )
        } catch {
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

        // ★ 预热边界必须随预算缩放，否则 light 采样测不出稳态。
        //
        // ⛔ `warmupBytes` 是固定 96 KB，而 `lightSampleBytes` 只有 128 KB ——
        //    留给「稳态窗」的只剩 32 KB。32 KB 的耗时里 RTT 抖动占比极大，
        //    算出来的 KB/s 会大幅跳动，同一 host 两次读数能差一倍。
        //    那会让线路菜单里的速度数字变成随机数，比没有数字更糟。
        //
        // 取「预算的一半」与 `warmupBytes` 的较小者：
        //   · 常规 256 KB → min(96 KB, 128 KB) = **96 KB，一个字节没变**
        //     （既有口径与历史读数继续可比 —— 这一条是硬约束，先按 /3 写过一次，
        //      把常规探针的预热区改成了 85 KB，被 `theWarmupBoundaryAlwaysLeavesASteadyWindow`
        //      当场抓出）；
        //   · light 128 KB → min(96 KB, 64 KB) = 64 KB，稳态窗正好一半。
        let warmupBoundary = min(Self.warmupBytes, max(budget / 2, 16 * 1024))

        for try await byte in bytes {
            data.append(byte)
            // 到达慢启动边界时打时间戳，只打一次。
            if warmupEnd == nil, data.count >= warmupBoundary {
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
        var width: Int?
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
        // 宽和高一起取：同一个 RESOLUTION 里的两个数属于同一档，分开解析会把
        // 「最高档的高度」和「最低档的宽度」配成一对，长边算出来就是错的。
        var sizes: [(width: Int, height: Int)] = []
        var searchStart = head.startIndex
        while let range = head.range(of: #"RESOLUTION=(\d+)x(\d+)"#,
                                     options: .regularExpression,
                                     range: searchStart..<head.endIndex) {
            let matched = String(head[range])
            let numbers = matched.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if numbers.count >= 2 { sizes.append((numbers[0], numbers[1])) }
            searchStart = range.upperBound
            if searchStart >= head.endIndex { break }
        }
        if let best = sizes.max(by: { $0.height < $1.height }) {
            out.width = best.width
            out.height = best.height
        }
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
