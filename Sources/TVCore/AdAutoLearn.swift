import Foundation

/// **首播自动学习**：同一站点里，把「每条视频开头都一样的那些秒」自动认成广告。
///
/// ## 为什么需要它
///
/// 清单层判据（`AdPrefix`）只能处理「广告来自另一个目录」的源，
/// 实测有 12 个源的分片全在同一个目录里（`index_000.ts` 之类），
/// 结构上完全分不出广告和正片 —— 那批源只能靠**画面内容**。
///
/// 用户不想手动标。所以这里做的是：**播几条就自动学会**。
///
/// ## 判据：同源多条视频，开头逐帧相同的部分 = 广告
///
/// 这是对实测现象的直接编码。抓 3 个源 × 3 个视频的真实分片逐秒算 dHash：
///
/// | 源 | 开头逐帧相同的时长 | 之后 |
/// |---|---|---|
/// | 玉兔 | **24 秒，距离全部 = 0** | 距离跳到 22–28 |
/// | 155 | 26 秒 | 距离跳到 31–33 |
/// | 杏吧 | 23 秒 | 距离跳到 25 |
///
/// 也就是说「同一个站的视频开头那一段是同一份文件」不是特例，是常态。
/// 这条规律不需要知道广告长什么样，只需要**两条视频的开头一样**。
///
/// ## 三条保护，宁可学不会也不许误判
///
/// 1. **至少 2 条样本**才开始推断（1 条无法区分「广告」和「正片本身」）。
/// 2. **要求连续一致**：一旦在某一秒不一致，比对立即停止，
///    后面的内容不再参与（否则正片里偶然相同的镜头会被当成广告）。
/// 3. **下限 3 秒、上限 `longestPrefix`**：太短的多半是台标，太长说明判据出错。
public enum AdAutoLearn {

    /// 一共要几段样本才下结论。
    ///
    /// 2 条就能算出「共同前缀」，但 2 条时无法排除「这两条恰好同系列」。
    /// 取 3 条：再多会拖慢学习速度，收益不明显。
    public static let minimumSamples = 3

    /// 共同前缀最长算到多少秒。超过就不像广告了（实测广告 15–105 秒，
    /// 但「每条都一样的开头」实测最长 26 秒，给到 120 秒留足余量）。
    public static let longestPrefix = 120.0

    /// 共同前缀至少多少秒才认。低于此值的多半是片头台标/黑场。
    public static let shortestPrefix = 3.0

    /// 两条哈希算「同一画面」的阈值（与 `AdMatcher.threshold` 一致）。
    public static let matchThreshold = 8

    /// 一段样本：某条视频开头的逐秒指纹。
    public struct Sample: Codable, Equatable, Sendable {
        /// 视频标识（同一站点内唯一即可）。
        public var videoID: String
        /// 逐秒 dHash，第 i 个对应第 `start + i * interval` 秒。
        public var hashes: [UInt64]
        /// 采样间隔（秒）。
        public var interval: Double
        /// 第一次采样的时间点（秒）。通常 0。
        public var start: Double
        public var createdAt: Date

        public init(videoID: String, hashes: [UInt64], interval: Double = 1.0,
                    start: Double = 0, createdAt: Date = Date()) {
            self.videoID = videoID
            self.hashes = hashes
            self.interval = interval
            self.start = start
            self.createdAt = createdAt
        }
    }

    /// 学出来的结论。
    public struct Learned: Codable, Equatable, Sendable, Identifiable {
        /// 稳定 id：站点 key 的哈希，保证同一站点只会有一条。
        public var id: String
        /// 站点标识（`PlaybackHistoryContext.sourceKey`）。
        public var sourceKey: String
        /// 共同前缀的逐秒指纹 —— 用它去比对后续视频。
        public var hashes: [UInt64]
        /// 采样间隔。
        public var interval: Double
        /// 前缀时长（秒）。
        public var span: Double
        /// 参与学习的样本数。
        public var sampleCount: Int
        /// 学出来的时间，用于展示「已在 N 条片子上验证」。
        public var learnedAt: Date

        public init(id: String, sourceKey: String, hashes: [UInt64], interval: Double,
                    span: Double, sampleCount: Int, learnedAt: Date = Date()) {
            self.id = id
            self.sourceKey = sourceKey
            self.hashes = hashes
            self.interval = interval
            self.span = span
            self.sampleCount = sampleCount
            self.learnedAt = learnedAt
        }

        /// 能不能用来跳过：太短的共同前缀跳了也没意义，还可能切到正片。
        public var isUsable: Bool {
            hashes.count >= Int(shortestPrefix / max(interval, 0.001)) && span >= shortestPrefix
        }
    }

    /// 从若干样本里推断「同源固定前缀」。
    ///
    /// - Returns: 够条件时返回学到的前缀；样本不足或没有稳定前缀时返回 `nil`。
    public static func learn(sourceKey: String, samples: [Sample]) -> Learned? {
        // 同一视频只算一次（用户可能把同一条看了两遍）。
        var unique: [String: Sample] = [:]
        for s in samples where !s.hashes.isEmpty {
            if let existing = unique[s.videoID] {
                // 保留更长的那次采样。
                if s.hashes.count > existing.hashes.count { unique[s.videoID] = s }
            } else {
                unique[s.videoID] = s
            }
        }
        let pool = Array(unique.values)
        guard pool.count >= minimumSamples else { return nil }

        // 逐位比对：所有样本在第 i 秒都彼此接近，才算「共同」。
        //
        // ⛔ 一旦某秒不成立就**立即停止**。不能「跳过这一秒继续往后比」——
        //    正片里出现一个偶然相同的镜头时，那样会把后面的内容也拉进来，
        //    最后切掉一大段正片。连续性是这个判据成立的前提。
        // ⛔ 采样起点必须对齐：不同视频可能不是从第 0 秒开始采的
        //    （用户先拖了进度条、或首帧解码慢了半秒）。
        //    不对齐就直接按下标配对，会把「A 的第 3 秒」和「B 的第 1 秒」当成同一时刻，
        //    得出的共同前缀要么偏短、要么错位。
        let start = pool.map(\.start).max() ?? 0
        // 每个样本从「自己起点 ≥ start」处开始参与，最多回退一帧。
        let aligned: [[UInt64]] = pool.map { sample in
            let skip = max(0, Int(((start - sample.start) / max(sample.interval, 0.001)).rounded()))
            return skip < sample.hashes.count ? Array(sample.hashes[skip...]) : []
        }
        let shortest = aligned.map(\.count).min() ?? 0
        var common: [UInt64] = []
        for i in 0..<shortest {
            let hashes = aligned.map { $0[i] }
            guard isConsistent(hashes) else { break }
            // 用第一个样本的值作为代表（一致时它们本就几乎相同）。
            common.append(hashes[0])
            if Double(common.count) * pool[0].interval >= longestPrefix { break }
        }

        let interval = pool[0].interval
        let span = Double(common.count) * interval
        guard span >= shortestPrefix, !common.isEmpty else { return nil }

        return Learned(id: id(for: sourceKey),
                       sourceKey: sourceKey,
                       hashes: common,
                       interval: interval,
                       span: span,
                       sampleCount: pool.count)
    }

    /// 这一秒在所有样本里是不是同一画面。
    private static func isConsistent(_ hashes: [UInt64]) -> Bool {
        guard let first = hashes.first else { return false }
        for other in hashes.dropFirst() where AdHash.hamming(first, other) > matchThreshold {
            return false
        }
        return true
    }

    /// 稳定 id：同一站点只会有一条学习结果，避免重复入库。
    public static func id(for sourceKey: String) -> String {
        // 简单的稳定哈希（FNV-1a 64bit），不依赖 Swift 的 Hasher（每次进程不同）。
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in sourceKey.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "auto-" + String(hash, radix: 16)
    }

    // MARK: - 用学到的前缀去匹配

    /// 在一段指纹里，从头开始连续匹配学到的前缀多少秒。
    ///
    /// - Returns: 连续匹配的秒数；第一秒就不匹配时返回 0。
    public static func matchedPrefix(_ learned: Learned, in hashes: [UInt64]) -> Double {
        var matched = 0
        for (i, expected) in learned.hashes.enumerated() {
            guard i < hashes.count else { break }
            guard AdHash.hamming(expected, hashes[i]) <= matchThreshold else { break }
            matched += 1
        }
        // 必须**完整**匹配才算数：只对上前 5 秒就去跳 26 秒会切掉正片。
        //
        // 这里留 1 帧容差（`hashes.count - 1`）：抽帧时机可能差一帧，
        // 但不接受「只匹配一半就跳」。
        guard matched >= learned.hashes.count - 1 else { return 0 }
        return Double(matched) * learned.interval
    }
}

// MARK: - 存储

/// 学到的前缀存在本地，按站点隔离。
///
/// 与 `AdSignatureLibrary` 分开两处存，理由：
/// * 那边是「某支广告」的指纹，跨站点通用，用户手动标出来的；
/// * 这边是「某个站点的开头」的指纹，**只对该站点有意义**，自动学的。
///   混在一起会让「A 站的固定开头」被拿去匹配 B 站视频 —— 那是误跳。
public actor AutoLearnStore {
    public static let shared = AutoLearnStore()

    private var snapshot = Snapshot()
    private var loaded = false
    public let fileURL: URL

    public struct Snapshot: Codable, Sendable {
        public var learned: [AdAutoLearn.Learned] = []
        public var samples: [String: [AdAutoLearn.Sample]] = [:]   // sourceKey -> 最近几条样本
        public var updatedAt: Date = Date()
    }

    /// 每个站点保留多少条样本。到量后淘汰最旧的。
    ///
    /// ⛔ 必须设上限：每个样本是一组哈希（每秒 8 字节），
    ///    不加限制时播几百条片子就会占掉几十 KB 并拖慢每次学习。
    ///    12 条足够算出稳定前缀，且覆盖「同一站有多种开头」的情况。
    public static let maxSamplesPerSource = 12

    public init(fileURL: URL = AutoLearnStore.defaultURL) {
        self.fileURL = fileURL
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("AdAutoLearn.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        snapshot = decoded
    }

    /// 某站点学到的前缀（没有则 nil）。
    public func learned(for sourceKey: String) -> AdAutoLearn.Learned? {
        loadIfNeeded()
        return snapshot.learned.first { $0.sourceKey == sourceKey && $0.isUsable }
    }

    public func allLearned() -> [AdAutoLearn.Learned] {
        loadIfNeeded()
        return snapshot.learned
    }

    /// 喂一条样本；攒够样本就（重新）学习该站点的前缀。
    ///
    /// - Returns: 若因此学到了新的/更长的前缀，返回它；否则 nil。
    @discardableResult
    public func feed(sourceKey: String, sample: AdAutoLearn.Sample) -> AdAutoLearn.Learned? {
        loadIfNeeded()
        guard !sample.hashes.isEmpty, !sourceKey.isEmpty else { return nil }

        var list = snapshot.samples[sourceKey] ?? []
        // 同一视频只留最新一次（用户可能重看）。
        list.removeAll { $0.videoID == sample.videoID }
        list.append(sample)
        if list.count > Self.maxSamplesPerSource {
            list = Array(list.sorted { $0.createdAt > $1.createdAt }.prefix(Self.maxSamplesPerSource))
        }
        snapshot.samples[sourceKey] = list

        guard let fresh = AdAutoLearn.learn(sourceKey: sourceKey, samples: list) else {
            persist()
            return nil
        }
        // 只在「新的更长」时覆盖：已经学会 20 秒，不该因为一次只有 5 秒的样本缩回去。
        if let existing = snapshot.learned.first(where: { $0.sourceKey == sourceKey }) {
            guard fresh.span > existing.span + 0.5 else {
                persist()
                return nil
            }
            snapshot.learned.removeAll { $0.sourceKey == sourceKey }
        }
        snapshot.learned.append(fresh)
        snapshot.updatedAt = Date()
        persist()
        return fresh
    }

    /// 用户清掉某站点的学习结果（比如学了错的东西）。
    public func forget(sourceKey: String) {
        loadIfNeeded()
        snapshot.learned.removeAll { $0.sourceKey == sourceKey }
        snapshot.samples[sourceKey] = nil
        snapshot.updatedAt = Date()
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Diagnostics.shared.failure("ads", "save auto-learn", error)
        }
    }
}
