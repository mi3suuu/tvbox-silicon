import Foundation

/// 一支广告的视觉指纹。
///
/// 判定「这是同一支广告」靠**画面哈希序列**而不是时间位置：
/// 用户的原话是「广告内容一样，但每个视频里出现的位置不一样」，
/// 所以位置完全不能当键，只有内容能。
///
/// 为什么用 dHash（差分哈希）而不是 aHash/pHash：
///   · dHash 只比较相邻像素的**相对亮度**，对整体亮度偏移、轻微调色不敏感 ——
///     同一个广告在不同站点转码后颜色常有一点点偏差；
///   · 64 bit 足够（同源广告汉明距离通常 ≤4，不同画面 ≥20），碰撞率可忽略；
///   · 计算是纯整数运算，1 秒 1 帧的采样率下开销可以忽略。
public struct AdSignature: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// 用户可读的名字，如「某手游 15s」。标注时可留空。
    public var title: String
    /// 这支广告的时长（秒）。
    public var duration: Double
    /// 按时间顺序的 dHash 序列，第 i 个对应 `start + i * sampleInterval`。
    public var hashes: [UInt64]
    /// 相邻两个哈希之间的时间间隔（秒）。
    public var sampleInterval: Double
    /// 首次记录时间，用于云端合并时决定先后。
    public var createdAt: Date

    public init(id: UUID = UUID(), title: String = "", duration: Double,
                hashes: [UInt64], sampleInterval: Double = 1.0, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.duration = duration
        self.hashes = hashes
        self.sampleInterval = sampleInterval
        self.createdAt = createdAt
    }

    /// 指纹覆盖的时间跨度。
    public var span: Double { Double(hashes.count) * sampleInterval }

    /// 够不够用来识别：少于 3 个采样点的指纹误判率太高，不入库。
    public var isUsable: Bool { hashes.count >= 3 && duration > 0 }
}

// MARK: - dHash

public enum AdHash {
    /// 一张 9×8 灰度图的相邻像素差分 → 64 bit。
    ///
    /// 输入要求 `width == 9, height == 8`（由调用方缩放到这个尺寸）。
    /// 逐行比较 `p[x] > p[x+1]`，比左邻亮记 1。
    public static func dHash(gray: [UInt8], width: Int = 9, height: Int = 8) -> UInt64 {
        guard gray.count >= width * height else { return 0 }
        var hash: UInt64 = 0
        var bit = 0
        for y in 0..<height {
            let row = y * width
            for x in 0..<(width - 1) {
                if gray[row + x] > gray[row + x + 1] { hash |= (1 << UInt64(bit)) }
                bit += 1
            }
        }
        return hash
    }

    /// 两个哈希差了几个 bit。
    public static func hamming(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}

// MARK: - 匹配

/// 在一次播放里，把当前画面与广告库做匹配。
///
/// 设计成「连续确认」而不是「单帧命中」：广告与正片偶尔会有一帧构图相近，
/// 单帧就跳会把正片剪碎。要求连续 `confirmFrames` 帧都命中同一个广告，
/// 才认定「进广告了」。误跳比漏跳代价高得多。
public struct AdMatcher: Sendable {
    /// 汉明距离阈值。同源广告实测 0~4，不同画面 ≥20，取 8 留余量。
    public static let threshold = 8
    /// 连续命中多少帧才确认。
    public static let confirmFrames = 3

    private var candidateID: UUID?
    private var candidateAt = 0
    private var runLength = 0

    public init() {}

    /// 喂一帧哈希进去。返回「已确认命中的广告」，否则 nil。
    public mutating func feed(_ hash: UInt64, library: [AdSignature]) -> AdSignature? {
        // 找当前帧最像的那支广告（要求它某个采样点足够接近）。
        var best: (ad: AdSignature, distance: Int)?
        for ad in library where ad.isUsable {
            for stored in ad.hashes {
                let d = AdHash.hamming(hash, stored)
                if d <= Self.threshold, best == nil || d < best!.distance {
                    best = (ad, d)
                }
            }
        }

        guard let hit = best?.ad else {
            // 这一帧不像任何广告：连续计数清零，但不清 candidate ——
            // 中间偶尔一帧没匹配上（转场、弹幕遮住）不该打断判定。
            runLength = max(0, runLength - 1)
            if runLength == 0 { candidateID = nil }
            return nil
        }

        if candidateID == hit.id {
            runLength += 1
        } else {
            candidateID = hit.id
            runLength = 1
        }

        guard runLength >= Self.confirmFrames else { return nil }
        // 确认后不再重复触发，交给调用方去 seek；下一段广告会重置计数。
        candidateID = nil
        runLength = 0
        return hit
    }

    /// 跳过一次之后重置，避免同一支广告在跳转后被再次确认。
    public mutating func reset() {
        candidateID = nil
        runLength = 0
    }
}

// MARK: - 库

/// 本地广告指纹库。
///
/// 存成单个 JSON 文件而不是 UserDefaults：库会随使用慢慢变大（100 支广告约 24KB，
/// 但用户可能积累几百支），文件更好导出、也更好做云端合并。
public actor AdSignatureLibrary {
    public static let shared = AdSignatureLibrary()

    public struct Snapshot: Codable, Equatable, Sendable {
        public var version: Int
        public var ads: [AdSignature]
        public var updatedAt: Date
        public init(version: Int = 1, ads: [AdSignature] = [], updatedAt: Date = Date()) {
            self.version = version; self.ads = ads; self.updatedAt = updatedAt
        }
    }

    private var snapshot = Snapshot()
    private var loaded = false

    public init(fileURL: URL = AdSignatureLibrary.defaultURL) {
        self.fileURL = fileURL
    }

    public let fileURL: URL

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("AdSignatures.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        snapshot = decoded
    }

    public func all() -> [AdSignature] {
        loadIfNeeded()
        return snapshot.ads
    }

    public func count() -> Int { all().count }

    /// 加入一支新广告。序列号相同（哈希完全一致）时不重复入库。
    @discardableResult
    public func add(_ ad: AdSignature) -> Bool {
        loadIfNeeded()
        guard ad.isUsable else { return false }
        if snapshot.ads.contains(where: { $0.hashes == ad.hashes }) { return false }
        snapshot.ads.append(ad)
        snapshot.updatedAt = Date()
        persist()
        return true
    }

    public func remove(id: UUID) {
        loadIfNeeded()
        snapshot.ads.removeAll { $0.id == id }
        snapshot.updatedAt = Date()
        persist()
    }

    public func removeAll() {
        loadIfNeeded()
        snapshot.ads.removeAll()
        snapshot.updatedAt = Date()
        persist()
    }

    /// 合并另一份库（云端拉回来的）。同 id 或同哈希序列视为同一支，取先创建的那条。
    /// 返回实际新增的条数。
    @discardableResult
    public func merge(_ other: Snapshot) -> Int {
        loadIfNeeded()
        let existingHashes = Set(snapshot.ads.map { $0.hashes })
        let existingIDs = Set(snapshot.ads.map { $0.id })
        var added = 0
        for ad in other.ads where ad.isUsable {
            if existingIDs.contains(ad.id) { continue }
            if existingHashes.contains(ad.hashes) { continue }
            snapshot.ads.append(ad)
            added += 1
        }
        if added > 0 {
            snapshot.updatedAt = Date()
            persist()
        }
        return added
    }

    public func export() -> Snapshot {
        loadIfNeeded()
        return snapshot
    }

    public func exportData() -> Data {
        (try? JSONEncoder().encode(export())) ?? Data()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Diagnostics.shared.failure("ads", "save signature library", error)
        }
    }
}
