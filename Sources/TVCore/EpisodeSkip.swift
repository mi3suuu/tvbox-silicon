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
    /// 这段是用户手标起止点的，还是算法从指纹扩出来的。
    ///
    /// 两者必须能分辨：手标段是**用户看得见、点得准**的区间，删它要明确；
    /// 算法段是"大概在这儿"，用户标一次的手标段不应该被后续算法覆盖掉。
    /// 老存档没有这个字段，解码缺省 `false`（当时的段都是算法扩的）。
    public var marked: Bool
    /// 这段属于哪一集。
    ///
    /// ⛔ 这条是**必须**的，不是锦上添花：`EpisodeSkipSettings` 按**作品**存
    ///（`scope(origin:source:video:)` 只到 `videoID`，不含集），片头片尾这样存是对的
    ///（每集片头位置基本一致），但**广告位置每集都不一样**。
    /// 不区分集的话，第 1 集标的 30–45 秒会被套到第 2 集的 30–45 秒上 ——
    /// 把正片剪掉 15 秒，而且用户完全看不出原因（他只标过第 1 集）。
    ///
    /// `nil` = 没记集（老存档，或这个频道没有集的概念）。
    /// 这种段对所有集都生效 —— 保持旧行为，不静默丢用户已标的数据。
    public var episode: String?

    public init(id: UUID = UUID(), start: Double, length: Double, marked: Bool = false,
                episode: String? = nil) {
        self.id = id; self.start = start; self.length = length
        self.marked = marked; self.episode = episode
    }

    /// 手标「起点 + 终点」构造。终点在前会被自动摆正。
    public init(start: Double, end: Double, marked: Bool = true, episode: String? = nil) {
        let low = min(start, end), high = max(start, end)
        self.init(start: low, length: max(0, high - low), marked: marked, episode: episode)
    }

    private enum CodingKeys: String, CodingKey { case id, start, length, marked, episode }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        length = try c.decodeIfPresent(Double.self, forKey: .length) ?? 0
        marked = try c.decodeIfPresent(Bool.self, forKey: .marked) ?? false
        episode = try c.decodeIfPresent(String.self, forKey: .episode)
    }

    /// 这一段在当前这一集是否算数。
    ///
    /// 没记集的段（老数据 / 无集概念的频道）对所有集都算数：
    /// 宁可保持旧行为，也不要因为一次升级把用户标过的段悄悄作废。
    public func applies(to episode: String?) -> Bool {
        guard let own = self.episode else { return true }
        guard let episode else { return true }
        return own == episode
    }

    public var end: Double { length > 0 ? start + length : .greatestFiniteMagnitude }

    public func contains(_ time: Double) -> Bool {
        time >= start && time < end
    }

    /// 太短的段不算广告：手抖点两下就成一段，会把正片剪碎。
    public static let shortestLength = 1.5

    /// 这段能不能拿去用。`duration` 用来判断「到片尾」型的段是否越界。
    public func isValid(duration: Double) -> Bool {
        guard start.isFinite, length.isFinite, start >= 0 else { return false }
        if length > 0 { return length >= Self.shortestLength }
        // 0 = 到片尾，但起点必须真的在片子里。
        return duration.isFinite && duration > 0 && start < duration
    }

    /// 两段是否重叠（含端点相接视为不重叠：前一段结束正好是后一段开始是真的相邻广告）。
    public func overlaps(_ other: AdRange) -> Bool {
        let a0 = start, a1 = end, b0 = other.start, b1 = other.end
        guard a1.isFinite, b1.isFinite else { return true }
        return a0 < b1 && b0 < a1
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

    /// Any times the video has room for, as long as the intro ends before the outro starts. Limits on their length
    /// (five minutes, a quarter of the video, 60% left between) refused the right times for short episodes, such as
    /// an anime's 90-second opening in a 12-minute episode (#1003).
    public func validationError(duration: Double) -> String? {
        guard duration.isFinite, duration > 0 else { return L10n.text("Wait for the video duration. Live streams cannot use skipping.") }
        guard introEnd.isFinite, outroLength.isFinite, introEnd >= 0, outroLength >= 0 else { return L10n.text("Enter a valid time such as 01:30.") }
        guard introEnd + outroLength < duration else { return L10n.text("The intro must end before the outro starts.") }
        return nil
    }

    /// These settings with the intro ending, or the outro starting, at `position`, and switched on: what Apple TV's
    /// "Intro Ends Here" saves, where there is no keyboard for a time (#808). Nil where the rules above refuse it.
    public func marking(intro: Bool, at position: Double, duration: Double) -> Self? {
        guard position.isFinite, duration.isFinite, position >= 0, position <= duration else { return nil }
        var value = self
        value.enabled = true
        if intro { value.introEnd = position.rounded(.down) } else { value.outroLength = (duration - position).rounded(.up) }
        return value.validationError(duration: duration) == nil ? value : nil
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

    /// `scope` under a subscription's new address when it was saved under `old`; nil when it belongs to another one.
    /// A subscription whose address the viewer changed (#982) keeps what was saved against its sources this way.
    public static func rescope(_ scope: String, from old: URL, to new: URL) -> String? {
        guard let parts = try? JSONDecoder().decode([String].self, from: Data(scope.utf8)), parts.count == 3,
              parts[0] == old.absoluteString else { return nil }
        return Self.scope(origin: new, source: parts[1], video: parts[2])
    }

    /// Saved scope keys with `old` moved to `new`, in their order, without repeats.
    static func rescope(_ scopes: [String], from old: URL, to new: URL) -> [String] {
        var seen = Set<String>()
        return scopes.map { rescope($0, from: old, to: new) ?? $0 }.filter { seen.insert($0).inserted }
    }

    /// Moves the intro and outro times saved for a subscription's videos to its new address. Times already saved
    /// under the new one stay.
    public static func moveOrigin(from old: URL, to new: URL, defaults: UserDefaults = .standard) {
        let prefix = "episodeSkip.v1."
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            guard let scope = rescope(String(key.dropFirst(prefix.count)), from: old, to: new) else { continue }
            if defaults.object(forKey: prefix + scope) == nil { defaults.set(value, forKey: prefix + scope) }
            defaults.removeObject(forKey: key)
        }
    }
}

/// Each segment is skipped once per play-through. Rewinding manually never traps the viewer
/// in an automatic seek loop; restarting playback or applying new settings starts a new pass.
public struct EpisodeSkipPass: Sendable {
    /// How long before the outro the player counts down to skipping it, so the viewer can keep it (#1003).
    public static let outroWarning = 5.0
    private var introHandled = false
    private var outroHandled = false
    /// 已经跳过的广告段 id。用 id 而不是索引：用户可能在播放中增删广告段，
    /// 索引会错位，id 不会。一段只跳一次，避免手往回拖又被弹回去。
    private var handledAds: Set<UUID> = []
    /// 上一次请求跳过的广告段，只用来「确认未成功时回滚」。
    ///
    /// 这个字段以前叫 `lastSkippedAd`，只写不读（全仓 0 处读取），
    /// 于是手标段被跳过时用户看不到任何提示；而且 id 在执行 seek **之前**
    /// 就进了 `handledAds`，seek 失败后这一段本轮再也不会跳。
    /// 现在改成「先记待确认，调用方确认成功再 `confirm`」。
    private var pending: UUID?
    public init() {}

    /// Seconds until the outro is skipped, while that is `outroWarning` or less; nil before then, and once it is
    /// skipped or kept.
    public func outroCountdown(time: Double, duration: Double, settings: EpisodeSkipSettings) -> Double? {
        guard !outroHandled, settings.enabled, settings.outroLength > 0, time.isFinite,
              settings.validationError(duration: duration) == nil else { return nil }
        let left = duration - settings.outroLength - time
        return left > 0 && left <= Self.outroWarning ? left : nil
    }

    /// The viewer keeps this play-through's outro.
    public mutating func keepOutro() { outroHandled = true }

    /// - Parameter blocksAds: 「广告拦截」总开关（`player.skipAds`）。
    ///
    ///   ⛔ 广告段的跳过**不能**挂在 `settings.enabled` 上。那个字段是
    ///   「自动跳过片头片尾」的开关，与广告是两件事：
    ///   于是出现两种反向错——① 用户关掉广告拦截，手标的广告段照样被跳；
    ///   ② 用户没开"跳过片头片尾"，广告段就永远不跳。
    ///   两边的开关各管各的，这里必须单独收一个参数。
    /// - Parameter episode: 当前这一集的标识（`PlaybackHistoryContext.episodeID`）。
    ///
    ///   广告段只对**标它的那一集**生效。片头片尾可以按作品复用（每集位置基本一致），
    ///   广告位置每集都不一样 —— 第 1 集标的 30–45 秒套到第 2 集上就是把正片剪掉。
    ///   `nil`（没有集概念的频道，或老存档里没记集的段）对所有集都生效。
    public mutating func target(time: Double, duration: Double, playing: Bool,
                                settings: EpisodeSkipSettings, blocksAds: Bool = true,
                                episode: String? = nil) -> Double? {
        guard playing, time.isFinite, time >= 0, time <= duration else { return nil }

        // ★ 广告优先于片头片尾：广告可能正好压在片头位置，
        //   这时该跳到广告结尾而不是片头结尾。
        //   广告只认 `blocksAds`；片头片尾才认 `settings.enabled`。
        if blocksAds,
           let ad = settings.ads.first(where: {
               $0.applies(to: episode) && $0.contains(time) && !handledAds.contains($0.id)
           }) {
            handledAds.insert(ad.id)
            pending = ad.id
            let end = min(ad.end, duration)
            // 段尾就是当前播放位置的兜底：不能返回一个不前进的目标，
            // 否则 seek 到原地 → 下一 tick 又命中 → 无限 seek 循环。
            return end > time + 0.25 ? end : nil
        }

        guard settings.enabled else { return nil }
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

    /// 刚才那段广告的终点，用来给界面弹提示。
    public mutating func takeSkippedAd(settings: EpisodeSkipSettings) -> AdRange? {
        guard let pending else { return nil }
        defer { self.pending = nil }
        return settings.ads.first { $0.id == pending }
    }

    /// seek 失败时调用：把这段放回去，下一 tick 还能再试一次。
    ///
    /// `handledAds` 在 `target` 里就已经写入，seek 却可能在 `!seekableTimeRanges`
    /// 或 seek 回调失败时什么都不做 —— 不回收就等于「这段广告本轮永远不再跳」，
    /// 而用户看到的是「第一次跳了、后面不跳了」。
    public mutating func rollbackPending() {
        guard let pending else { return }
        handledAds.remove(pending)
        self.pending = nil
    }

    /// 应用了新的广告列表（用户刚标注过）时，把跳过的记录清掉，
    /// 让新加的广告段本集就能生效。
    public mutating func resetAds() {
        handledAds.removeAll()
        pending = nil
    }
}
