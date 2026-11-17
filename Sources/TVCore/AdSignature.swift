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

    /// 加入一支新广告。
    ///
    /// 去重按「是不是同一支广告」判，不是按「哈希数组完全相同」判。
    ///
    /// ⛔ 原来是逐位相等（`$0.hashes == ad.hashes`）。那只在**同一份文件**上成立：
    ///   用户在 A 源标一次、换到 B 源又标一次（同一支广告，转码不同），
    ///   两份指纹差几个 bit ⇒ 当成两支入库。后果不是"多占几 KB"，
    ///   而是 `AdMatcher` 在同一个库里搜到 2 支几乎一样的广告，
    ///   确认计数在两者之间来回切、`runLength` 反复归 1，**永远凑不满连续 3 帧**。
    ///   用户看到的就是"标了两次反而完全不跳了"。
    @discardableResult
    public func add(_ ad: AdSignature) -> Bool {
        loadIfNeeded()
        guard ad.isUsable else { return false }
        if AdMatch.contains(ad.hashes, in: snapshot.ads) { return false }
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
        let existingIDs = Set(snapshot.ads.map { $0.id })
        var added = 0
        for ad in other.ads where ad.isUsable {
            if existingIDs.contains(ad.id) { continue }
            // 同 `add`：同一支广告的不同转码版本不能各存一份，
            // 否则确认计数会被两支几乎相同的指纹来回打断。
            if AdMatch.contains(ad.hashes, in: snapshot.ads) { continue }
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

// MARK: - 边界自适应

/// 从一串哈希里找出「同一支广告」的连续区间。
///
/// 用户只能告诉我们「现在这里在放广告」，无法精确说出它从哪一秒开始、
/// 到哪一秒结束。所以边界必须**自己找**：
///
///   1. 以标记点为锚，向两侧扩；
///   2. 每次往外看一格，与锚点附近已确认的区间做「整体相似度」比较
///      （不是比单帧 —— 单帧偶然相似太常见）；
///   3. 相似度掉下阈值就停，交界处就是广告边界。
///
/// 为什么用「整体相似度」而不是「相邻帧连续性」：
/// 广告内部常有转场、纯色卡、品牌动画收尾，相邻两帧可能毫不相干，
/// 但它们与广告开头那几帧的整体距离仍然很远（说明还在同一支广告里）。
/// 用相邻帧连续性会把这类广告从中间切断。
public enum AdBoundary {

    /// 判定「这一格还属于这支广告」的相似度下限（0…1，1 = 完全一致）。
    ///
    /// 取 0.55：同源广告转码后逐帧汉明距离通常在 0…8（64 bit 下约 0.125），
    /// 而不同内容之间普遍 ≥20（约 0.31）——但**整体相似度**是平均值，
    /// 转场帧会拉低它，所以阈值要比单帧宽松得多。
    public static let similarityFloor = 0.55

    /// 至少要连续这么多格才算一段，太短的认为是误标。
    public static let minimumSpan = 3

    /// 向两侧扩时容忍几个连续不像的格子。
    ///
    /// 广告标题卡、转场、纯色收尾用 1 秒采样时常常整整一格与模板毫不相干，
    /// 但下一格又接回广告。"一帧不像就断"会把这类广告切成两半，
    /// 只标到前半截 —— 用户看到的就是"跳到一半又出广告"。
    public static let maxMisses = 2

    /// 单帧汉明距离 → 相似度（0…1）。
    public static func similarity(_ distance: Int) -> Double {
        max(0, 1 - Double(distance) / 64.0)
    }

    /// 一组待判定哈希 vs 一支已确认广告的**平均相似度**。
    ///
    /// 对 `probe` 里每一帧，在 `template` 里找最像的那一帧，取平均。
    /// 这样广告内部换镜头也不会被判成「不像」——只要每一帧都能在模板里
    /// 找到对应的位置。
    public static func similarity(of probe: [UInt64], against template: [UInt64]) -> Double {
        guard !probe.isEmpty, !template.isEmpty else { return 0 }
        var total = 0.0
        for hash in probe {
            var best = 64
            for stored in template {
                let d = AdHash.hamming(hash, stored)
                if d < best { best = d }
                if best == 0 { break }
            }
            total += similarity(best)
        }
        return total / Double(probe.count)
    }

    /// 从标记点向两侧扩，返回这支广告在**所有抓到的哈希**里的区间。
    ///
    /// - Parameters:
    ///   - hashes: 整段待分析内容的哈希（按时间顺序，等间隔）
    ///   - anchor: 用户标记的那一格下标（通常是"当前播放位置"换算来的）
    ///   - window: 锚点附近取多少格当模板
    /// - Returns: 闭区间 `(start, end)`，下标含端点；找不到时返回 `nil`。
    public static func locate(in hashes: [UInt64], anchor: Int, window: Int = 4) -> ClosedRange<Int>? {
        guard !hashes.isEmpty, hashes.indices.contains(anchor) else { return nil }

        // ⛔ 模板必须能向**前**取。
        //
        // 这里原来只向回取：`left = anchor - window + 1`，模板 = `hashes[left...anchor]`。
        // 于是 `anchor == 0` 时模板只有 1 格，被下面的 `count >= 2` 挡掉，**直接返回 nil**。
        // 而 `resolveAndSkip` 传的正是 `anchor: 0`（候选序列从命中点开始），
        // 所以那条路上这个函数**从来没有成功过一次** —— 每次都退回
        // 「命中点 + 广告总时长」，正好把它注释里说要避免的「多跳、切掉正片开头」执行了个遍。
        //
        // 现在模板以锚点为中心向两侧取，两端各自钳位，锚点在序列头也能拿到完整模板。
        let half = max(1, window / 2)
        let lower = max(0, anchor - half)
        let upper = min(hashes.count - 1, lower + window - 1)
        let template = Array(hashes[lower...upper])
        guard template.count >= 2 else { return nil }

        // 向右扩：记「最后一个真正像的格子」，容忍中间至多 `maxMisses` 个不像的。
        // 边界取 `lastGood` 而不是「末格减掉 miss 数」—— 后者会把结尾真实命中的那一格也减掉。
        var end = anchor
        var lastGood = anchor
        var misses = 0
        while end + 1 < hashes.count {
            let sim = similarity(of: [hashes[end + 1]], against: template)
            if sim >= similarityFloor {
                lastGood = end + 1
                misses = 0
            } else {
                misses += 1
                if misses > maxMisses { break }
            }
            end += 1
        }
        end = lastGood

        // 向左扩（同一份模板、同一套判据）。
        var start = lower
        var firstGood = lower
        misses = 0
        while start - 1 >= 0 {
            let sim = similarity(of: [hashes[start - 1]], against: template)
            if sim >= similarityFloor {
                firstGood = start - 1
                misses = 0
            } else {
                misses += 1
                if misses > maxMisses { break }
            }
            start -= 1
        }
        start = min(anchor, firstGood)

        // 锚点自己必须像它自己的模板（锚点落在正片里时前面已 abort）。
        guard end - start + 1 >= minimumSpan else { return nil }
        return start...end
    }
}

// MARK: - 手标区间

/// 用户在时间轴上亲手定的广告区间。
///
/// 与「标记广告」按钮的区别（那条走 `AdBoundary.locate` 猜边界）：
/// 这是**用户说得准**的场景 —— 广告有清晰的黑场切换、片头卡、台标，
/// 或者算法猜歪了要人纠正。用户给两个时间点，就是两个时间点，
/// 算法不许再往里塞猜测。
public enum AdMarkRange {

    /// 最小可接受长度（秒）。低于这个当成误触：两次点在同一秒附近。
    public static let shortest = AdRange.shortestLength

    /// 由两个时间点造一段。起点比终点晚时自动摆正。
    ///
    /// - Returns: 可用区间；时间非有限、负数、或长度不足时 `nil`。
    public static func make(from: Double, to: Double, duration: Double) -> AdRange? {
        guard from.isFinite, to.isFinite, from >= 0, to >= 0 else { return nil }
        // 有片长就钳进去；两端都越过片尾时这一段不成立（`validated` 会返回 nil）。
        let limit = duration.isFinite && duration > 0 ? duration : .greatestFiniteMagnitude
        let low = min(min(from, to), limit)
        let high = min(max(from, to), limit)
        return AdRange(start: low, end: high, marked: true).validated
    }

    /// 把手标段并进现有列表：**同一集里**重叠的旧段先剔掉，再按起点排序。
    ///
    /// 为什么必须剔：`EpisodeSkipPass` 用 `first(where: contains)` 取段，
    /// 两段重叠时会取到先入列的那条，跳到它结尾 —— 如果那条是被纠正的错段，
    /// 用户改了反而跳到更错的地方。重叠即视为同一支广告的再次标注，新标注胜。
    ///
    /// ⛔ 只剔**同一集**的：`EpisodeSkipSettings` 按作品存，列表里躺着各集的段。
    ///   不分集就会在第 2 集标广告时把第 1 集标好的段删掉 —— 用户第二天回头看第 1 集，
    ///   广告又回来了，而且找不到原因。
    public static func merging(_ range: AdRange, into existing: [AdRange]) -> [AdRange] {
        var result = existing.filter { other in
            // 只在"同一集"范围内判定替换。跨集既不重叠也不替换。
            guard other.applies(to: range.episode), range.applies(to: other.episode) else { return true }
            return !other.overlaps(range)
        }
        result.append(range)
        return result.sorted { $0.start < $1.start }
    }

    /// 从列表里删掉一段（按 id）。
    public static func removing(id: UUID, from existing: [AdRange]) -> [AdRange] {
        existing.filter { $0.id != id }
    }
}

public extension AdRange {
    /// 自己过一遍 `isValid`，不合法返回 nil。
    var validated: AdRange? {
        guard start.isFinite, length.isFinite, start >= 0, length >= AdMarkRange.shortest else { return nil }
        return self
    }
}
