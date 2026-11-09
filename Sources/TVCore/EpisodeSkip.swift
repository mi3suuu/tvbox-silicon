import Foundation

/// 一段广告在时间轴上的位置。
///
/// 用「起点 + 时长」而不是「起点 + 终点」：
/// 同一支广告在不同视频里的**长度一致、位置不同**，存时长才能跨集复用同一份指纹
/// 记录（见 `AdSignature`），命中后再拿当前位置算出终点。
public struct AdRange: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// 广告开始时间（秒）。
    public var start: Double
    /// 广告时长（秒）。0 表示「到片尾」。
    public var length: Double

    public init(id: UUID = UUID(), start: Double, length: Double) {
        self.id = id; self.start = start; self.length = length
    }

    public var end: Double { length > 0 ? start + length : .greatestFiniteMagnitude }

    public func contains(_ time: Double) -> Bool {
        time >= start && time < end
    }
}

public struct EpisodeSkipSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var introEnd: Double
    /// Store the distance from the end so episodes with different lengths remain usable.
    public var outroLength: Double
    /// 手动或自动标记的广告分段。可有多段（用户场景：一部片里插好几支广告）。
    public var ads: [AdRange]

    public init(enabled: Bool = false, introEnd: Double = 0, outroLength: Double = 0,
                ads: [AdRange] = []) {
        self.enabled = enabled; self.introEnd = introEnd; self.outroLength = outroLength
        self.ads = ads
    }

    // 老版本存档没有 `ads` 字段，解码时补空数组，避免整份设置解不出来。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        introEnd = try c.decodeIfPresent(Double.self, forKey: .introEnd) ?? 0
        outroLength = try c.decodeIfPresent(Double.self, forKey: .outroLength) ?? 0
        ads = try c.decodeIfPresent([AdRange].self, forKey: .ads) ?? []
    }

    public static func introLimit(_ duration: Double) -> Double { min(300, duration / 4) }
    public static func outroLimit(_ duration: Double) -> Double { min(600, duration / 4) }

    public func validationError(duration: Double) -> String? {
        guard duration.isFinite, duration > 0 else { return L10n.text("Wait for the video duration. Live streams cannot use skipping.") }
        guard duration >= 120 else { return L10n.text("Skipping is available for videos at least two minutes long.") }
        guard introEnd.isFinite, outroLength.isFinite, introEnd >= 0, outroLength >= 0 else { return L10n.text("Enter a valid time such as 01:30.") }
        guard introEnd <= Self.introLimit(duration) else { return L10n.text("The intro cannot exceed five minutes or a quarter of the video.") }
        guard outroLength <= Self.outroLimit(duration) else { return L10n.text("The outro cannot exceed ten minutes or a quarter of the video.") }
        guard duration - introEnd - outroLength >= max(60, duration * 0.6) else { return L10n.text("Keep at least 60% of the video as main content.") }
        return nil
    }

    public static func parseTime(_ text: String) -> Double? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part), number <= 86_400,
                  index == 0 || number < 60 else { return nil }
            total = total * 60 + number
            guard total <= 86_400 else { return nil }
        }
        return Double(total)
    }

    public static func formatTime(_ time: Double) -> String {
        guard time.isFinite, (0...86_400).contains(time) else { return "00:00" }
        let seconds = Int(time.rounded(.down))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    public static func scope(origin: URL, source: String, video: String) -> String {
        // JSON encoding avoids collisions between identifiers containing delimiters.
        String(data: try! JSONEncoder().encode([origin.absoluteString, source, video]), encoding: .utf8)!
    }

    public static func load(scope: String, defaults: UserDefaults = .standard) -> Self {
        // Do not migrate a global time into every work: it belongs to an unknown previous film.
        var value = defaults.data(forKey: "episodeSkip.v1." + scope).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
        value.enabled = defaults.object(forKey: "episodeSkip.auto.v2") as? Bool ?? loadGlobal(defaults: defaults).enabled
        return value
    }

    public static func loadGlobal(defaults: UserDefaults = .standard) -> Self {
        defaults.data(forKey: "episodeSkip.global.v1").flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    public func saveGlobal(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: "episodeSkip.global.v1")
    }

    public func save(scope: String, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: "episodeSkip.v1." + scope)
        defaults.set(enabled, forKey: "episodeSkip.auto.v2")
    }
    public static func remove(scope: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: "episodeSkip.v1." + scope)
    }
}

/// Each segment is skipped once per play-through. Rewinding manually never traps the viewer
/// in an automatic seek loop; restarting playback or applying new settings starts a new pass.
public struct EpisodeSkipPass: Sendable {
    private var introHandled = false
    private var outroHandled = false
    /// 已经跳过的广告段 id。用 id 而不是索引：用户可能在播放中增删广告段，
    /// 索引会错位，id 不会。一段只跳一次，避免手往回拖又被弹回去。
    private var handledAds: Set<UUID> = []
    public init() {}

    public mutating func target(time: Double, duration: Double, playing: Bool, settings: EpisodeSkipSettings) -> Double? {
        guard playing, time.isFinite, time >= 0, time <= duration, settings.enabled else { return nil }

        // ★ 广告优先于片头片尾：广告可能正好压在片头位置，
        //   这时该跳到广告结尾而不是片头结尾。
        if let ad = settings.ads.first(where: { $0.contains(time) && !handledAds.contains($0.id) }) {
            handledAds.insert(ad.id)
            let end = min(ad.end, duration)
            // 记一下这次跳过的是广告（供界面显示「已跳过广告」toast）
            lastSkippedAd = ad
            return end
        }

        guard settings.validationError(duration: duration) == nil else { return nil }
        if !introHandled {
            introHandled = true
            if settings.introEnd > 0, time < settings.introEnd { return settings.introEnd }
        }
        if !outroHandled, settings.outroLength > 0, time >= duration - settings.outroLength {
            outroHandled = true
            return max(time, duration - 0.05)
        }
        return nil
    }

    /// 最近一次因命中广告而跳转的区间；界面用它弹一下提示。
    public private(set) var lastSkippedAd: AdRange?

    /// 应用了新的广告列表（用户刚标注过）时，把跳过的记录清掉，
    /// 让新加的广告段本集就能生效。
    public mutating func resetAds() { handledAds.removeAll() }
}
