import Foundation

/// Orders playable resources by the attributes a viewer actually chooses between.
///
/// When one title has several files — different sources, different resolutions, HDR and SDR copies,
/// a small fast one and a big slow one — "which do I play" is a decision, and the source's own order
/// is not an answer. Rex settles this with a rule the viewer composes: up to four attributes, each
/// ascending or descending, applied in order, with three presets on top
/// (`settings.aggregated.resource.*`). 映匣 has the data — `SourceProbeResult` already carries
/// resolution and throughput — but no way to express the preference.
///
/// The four attributes are the four that change the answer:
///
/// * **Resolution** — what most people mean by "better".
/// * **Bitrate** — what "better" means when resolution ties, and what predicts buffering.
/// * **File size** — what matters on a metered connection or a full disk.
/// * **Colour range** — whether the copy is HDR. Worth its own key because an HDR copy is *better*
///   on an HDR screen and *worse* on an SDR one, so it cannot be folded into resolution.
///
/// Ties fall through to the next key, and a resource missing an attribute sorts last among its peers
/// rather than being dropped: a file with no bitrate reading is still playable.
public struct ResourceRanking: Codable, Hashable, Sendable {

    /// One attribute, with the direction to sort it.
    public struct Key: Codable, Hashable, Sendable, Identifiable {
        public enum Attribute: String, Codable, Sendable, CaseIterable {
            case resolution, bitrate, fileSize, colourRange

            /// 探针能否提供这一项。
            ///
            /// 四项现在**全部可采**（都从头 8 KB 的 m3u8 主列表或响应头里读）：
            ///   · `resolution` ← `RESOLUTION=` 或文件名
            ///   · `bitrate`    ← `BANDWIDTH=` / `AVERAGE-BANDWIDTH=`（bit/s → kbps）
            ///   · `fileSize`   ← `Content-Range: bytes 0-N/TOTAL`（分片流拿不到）
            ///   · `colourRange`← `VIDEO-RANGE=SDR|HLG|PQ`
            ///
            /// ⛔ 之前的实现是 `self == .resolution`，理由是「源不是文件，扫不出码率/大小/HDR」。
            /// 那个理由只对**源级**扫描成立（每源只抓最新一部的一条线）；
            /// 一旦探针改读 m3u8 主列表，这三项就都在同一段头里。
            public var speedTestProvides: Bool { true }
        }
        public var attribute: Attribute
        /// True when larger is better (resolution, bitrate, HDR). False when smaller is better.
        public var descending: Bool

        public var id: String { attribute.rawValue + (descending ? "↓" : "↑") }

        public init(_ attribute: Attribute, descending: Bool = true) {
            self.attribute = attribute
            self.descending = descending
        }
    }

    /// The keys, most significant first.
    public var keys: [Key]

    public init(keys: [Key]) { self.keys = keys }

    // MARK: Presets

    /// What a person wants when they say nothing: the sharpest copy, breaking ties by bitrate.
    public static let standard = ResourceRanking(keys: [Key(.resolution), Key(.bitrate)])

    /// For a viewer who wants the best picture and does not care what it costs.
    public static let quality = ResourceRanking(keys: [
        Key(.resolution), Key(.colourRange), Key(.bitrate),
    ])

    /// For a viewer on a weak connection: the lightest copy first.
    ///
    /// Resolution is the only attribute the sweep actually reads, so "smallest first" has to be
    /// expressed through it. The preset used to be bitrate and file size ascending — neither of
    /// which the sweep measures — so choosing it reordered nothing while looking like it had.
    public static let speed = ResourceRanking(keys: [Key(.resolution, descending: false)])

    public static let presets: [(name: String, ranking: ResourceRanking)] = [
        ("Default", standard), ("Quality", quality), ("Speed", speed),
    ]

    // MARK: Ranking

    /// The attributes of one candidate. Every field is optional because a probe may not know it.
    public struct Candidate: Sendable {
        public var resolutionHeight: Int?
        public var bitrateBitsPerSecond: Int?
        public var fileSizeBytes: Int64?
        /// True for HDR/Dolby Vision, false for SDR, nil when unknown.
        public var isHDR: Bool?

        public init(resolutionHeight: Int? = nil, bitrateBitsPerSecond: Int? = nil,
                    fileSizeBytes: Int64? = nil, isHDR: Bool? = nil) {
            self.resolutionHeight = resolutionHeight
            self.bitrateBitsPerSecond = bitrateBitsPerSecond
            self.fileSizeBytes = fileSizeBytes
            self.isHDR = isHDR
        }

        /// Builds from a probe result, so the two never drift apart.
        ///
        /// ⛔ 原来这里是 `bitrateBitsPerSecond = nil` 硬写、另两项取调用方默认 nil。
        ///    也就是说：`speedTestProvides` 允许四项排序之后，**唯一的生产调用点**
        ///    （`Store+SourceAdmin` 的 `Candidate(reading)`）拿到的三个字段全是 nil，
        ///    `sort` 逐键 `continue` → 排序效果与「只按分辨率」完全一样。
        ///    设置页于是出现三个「能选、但选了没变化」的开关 ——
        ///    与修复前那三个空开关是同一个病，只是从「没数据」变成了「有数据但没人读」。
        ///
        /// 现在三项全部从探针真实字段取：
        ///   · 码率 ← `declaredBitrateKbps`（源自己声明的峰值，kbps → bit/s）
        ///   · 文件大小 ← `fileSizeBytes`（`Content-Range` 总长）
        ///   · HDR ← `colourRange == "HLG" || "PQ"`
        /// 参数仍保留，供「调用方有更准确数字」时覆盖。
        public init(_ probe: SourceProbeResult, fileSizeBytes: Int64? = nil, isHDR: Bool? = nil) {
            self.resolutionHeight = probe.resolutionHeight
            // 用**声明码率**，不是实测吞吐 —— 后者是「这条线现在能跑多快」，
            // 前者才是「这路流本身需要多少」。用吞吐冒充码率会把快服务器排在
            // 高码率文件前面，正好与要回答的问题相反。
            self.bitrateBitsPerSecond = probe.declaredBitrateKbps.map { $0 * 1_000 }
            self.fileSizeBytes = fileSizeBytes ?? probe.fileSizeBytes.map(Int64.init)
            self.isHDR = isHDR ?? probe.colourRange.map { $0 == "HLG" || $0 == "PQ" }
        }

        func value(for attribute: Key.Attribute) -> Double? {
            switch attribute {
            case .resolution: return resolutionHeight.map(Double.init)
            case .bitrate: return bitrateBitsPerSecond.map(Double.init)
            case .fileSize: return fileSizeBytes.map(Double.init)
            case .colourRange: return isHDR.map { $0 ? 1 : 0 }
            }
        }
    }

    /// Sorts `items` by the keys, most significant first.
    ///
    /// A missing attribute is "unknown", not "worst": it sorts after every candidate that has a value
    /// for that key, but before falling through to the next key. Dropping such candidates would hide
    /// playable files; treating them as zero would rank them as terrible, which is a different claim.
    public func sort<T>(_ items: [T], by candidate: (T) -> Candidate) -> [T] {
        guard !keys.isEmpty else { return items }
        return items.enumerated().sorted { lhs, rhs in
            let a = candidate(lhs.element), b = candidate(rhs.element)
            for key in keys {
                let av = a.value(for: key.attribute), bv = b.value(for: key.attribute)
                switch (av, bv) {
                case let (x?, y?) where x != y:
                    return key.descending ? x > y : x < y
                case (nil, _?):
                    return false          // unknown goes after a known value
                case (_?, nil):
                    return true
                default:
                    continue              // equal, or both unknown: try the next key
                }
            }
            // Fully tied — keep the source's order, which is at least stable.
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
