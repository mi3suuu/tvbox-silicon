import Foundation

/// 一个源「现在还能不能用」——测速之后最先想知道的那件事。
///
/// 为什么值得单独一个类型：源卡片上有路由（直连 / 中转）、有测速读数（ms、KB/s）、有画质标签，
/// 但没有一个**一句话结论**。分组与书架要按结论分层，就不能各自去解释 `_route`、`_probe`、
/// `SourceProbeResult.reachability` 这三套口径 —— 那三套各写一遍，迟早出现「书架说它能播、
/// 卡片说它不通」。这里把它们收成一个枚举。
///
/// 顺序就是书架的顺序：能播的在最前，测了不通的垫底；**没测过的排在不通前面** ——
/// 「没试过」还有机会，「试过不通」才是真的没法用。
public enum SourceTier: String, CaseIterable, Identifiable, Sendable {
    /// 出过字节，且速度够看。
    case playable
    /// 连上了，但慢到不够看（或者只拿到了握手，没有吞吐）。
    case slow
    /// 没有读数：这一版没测过它，或者它只在包外测过。
    case untested
    /// 测过，没出字节。
    case dead

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .playable: return L10n.text("Tier Playable")
        case .slow: return L10n.text("Tier Slow")
        case .untested: return L10n.text("Tier Untested")
        case .dead: return L10n.text("Tier Dead")
        }
    }

    /// 书架里的先后。`untested` 在 `dead` 之前：没试过的还可能是好的。
    public var rank: Int {
        switch self {
        case .playable: return 0
        case .slow: return 1
        case .untested: return 2
        case .dead: return 3
        }
    }

    public var symbol: String {
        switch self {
        case .playable: return "checkmark.circle.fill"
        case .slow: return "tortoise.fill"
        case .untested: return "questionmark.circle"
        case .dead: return "xmark.octagon"
        }
    }

    /// 算不算「测过」。`untested` 之外都算。
    public var isMeasured: Bool { self != .untested }
}

/// 从各处读数里得出「这个源现在算哪一档」。
public enum SourceConnectivity {
    /// 能看的门槛：KB/s，**720P 的底线**。
    ///
    /// 300 KB/s ≈ 2.4 Mbps，是 720P 一部剧的正常码率下限（阶梯里 720P 要 375，这一条是
    /// 「连标都不到」的那条线，也是没声明画质时的默认门槛）。低于它的源不是「不能用」，
    /// 是「会转圈」—— 那归 `slow`，仍然排在没测过的前面：它至少证明自己能出字节。
    ///
    /// ⛔ 不要拿它去判 4K：4K 的码率是 15–25 Mbps（1900–3200 KB/s），用 720P 的底线判
    /// 「能播」等于打开就转圈。按画质抬门槛用 `requiredSpeed(for:)`。
    public static let playableKilobytesPerSecond = 300

    /// 这个画质要多少 KB/s 才算「能播」。
    ///
    /// ⛔ 阶梯与 `SourceProbeResult.effectiveResolutionHeight` **必须同一套**（3000 / 750 / 375 / 150）。
    /// 两处回答的其实是同一个问题 ——「这个画质喂饱要多少带宽」—— 各写一套迟早出现
    /// 「档位说它够快、画质分档说它撑不住 1080p」的自相矛盾。这里的改动请同步那一边。
    ///
    /// 没声明画质就用 720P 的底线 300：不知道就不替它挑门槛。
    public static func requiredSpeed(for height: Int?) -> Int {
        switch height ?? 0 {
        case 2_000...: return 3_000   // 4K
        case 1_000..<2_000: return 750 // 1080P
        case 700..<1_000: return 375   // 720P
        case 1..<700: return 150       // 480P 及以下
        default: return playableKilobytesPerSecond
        }
    }

    /// 一条**自测**读数能用多久来判断「现在能不能用」。
    ///
    /// 与 `sourceProbeStaleness`（600 秒，决定「要不要重测」）是两个问题：
    /// 那个问的是「值不值得再花流量测一遍」，这个问的是「能不能拿它当结论」。
    /// 没有这一条，一个三周前测死的源会永远算不通 —— 只看能播就等于把它永久藏起来。
    public static let measuredTrustWindow: TimeInterval = 7 * 24 * 3_600

    /// 一条**包内**读数（`declared`）能用多久。
    ///
    /// 比自测宽得多：它是打包那天跑出来的实测行，比「没测过」强得多，而且会随每次发版刷新。
    /// 但也不能无限期 —— 一个两个月前的包说某个源能播，那是历史，不是现状。
    ///
    /// 60 天这个数的取舍：短于一个月会让「没升级的人」在包还没换的时候整页退回「未测」
    /// （徽标消失、只看得能播清空），而那不是数据变了，是窗口太窄；长于两个月，
    /// 「包是新的」这个前提就不成立了。
    public static let declaredTrustWindow: TimeInterval = 60 * 24 * 3_600

    /// 一个源的档位。
    ///
    /// 四种来源按可信度依次回落：
    /// 1. **App 里刚测的读数**（`SourceProbeStore.latest`）—— 最新，而且是这台设备、这条网络上量的。
    /// 2. **包内实测结论**（`raw._probe` / `raw._route`）—— 打包那天测的，会过时，但比「没测过」强。
    ///    包内读数只贡献**速度**：它没有速度时，结论仍由 `declaredTier(of:)` 从同一份数据里给，
    ///    而不是把「直连」这个路由标签当成吞吐证据。
    /// 3. 读数过期 → 回落到包内结论；包内结论也过期 → `untested`。
    public static func tier(of site: Site, reading: SourceProbeResult?, now: Date = Date()) -> SourceTier {
        guard let reading else { return declaredTier(of: site, now: now) }
        if reading.isExpired(now: now) { return declaredTier(of: site, now: now) }
        if reading.declared == true, (reading.kilobytesPerSecond ?? 0) <= 0 { return declaredTier(of: site, now: now) }
        return tier(of: reading)
    }

    public static func tier(of reading: SourceProbeResult) -> SourceTier {
        switch reading.reachability {
        case .unreachable:
            return .dead
        case .slow:
            return .slow
        case .reachable, .unknown:
            guard let kbps = reading.kilobytesPerSecond, kbps > 0 else {
                // 连上了但没有吞吐：不是「不通」，是「会转圈」。
                //
                // ⛔ 这里曾经返回 `.playable`。理由是「能连上就能看」，但实测反例很直接：
                // 只拿到握手、一个字节正文都没读到的源，打开播放器是黑屏转圈。
                // `SourceTier.slow` 的定义本来就写着「或者只拿到了握手，没有吞吐」——
                // 判 `.playable` 等于绕过了自己写下的定义。
                // `unknown` 且没有任何数字：这条读数其实什么也没说。
                return reading.reachability == .reachable ? .slow : .untested
            }
            return kbps >= requiredSpeed(for: reading.resolutionHeight) ? .playable : .slow
        }
    }

    /// 随包数据里写在源定义上的结论。
    ///
    /// `_probe` 是打包脚本写进去的实测行（`verdict` / `kbps` / `at`），`_route` 是更早的粗结论。
    /// 两者都在时 `_probe` 优先：它是播放探测（真出了字节），`_route` 只是路由判定。
    public static func declaredTier(of site: Site, now: Date = Date()) -> SourceTier {
        let fresh = !isDeclaredExpired(site, now: now)
        if let probe = site.raw["_probe"]?.object {
            var kbps = 0.0
            if case .number(let value)? = probe["kbps"] { kbps = value }
            let height = SourceProbeImport.height(fromQuality: site.raw["_quality"]?.string)
            if kbps > 0 {
                guard fresh else { return .untested }
                return kbps >= Double(requiredSpeed(for: height)) ? .playable : .slow
            }
            switch probe["verdict"]?.string?.lowercased() {
            case "unreachable", "dead", "failed": return fresh ? .dead : .untested
            case "direct", "proxy", "playable": return fresh ? .playable : .untested
            default: break
            }
        }
        guard fresh else { return .untested }
        switch site.raw["_route"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "直连": return .playable
        case "失效", "不通", "失败": return .dead
        case "慢": return .slow
        default: return .untested
        }
    }

    /// 包内结论是不是已经旧到没有参考价值。
    ///
    /// 只看得出日期的那些源：`_probe.at` / `_note` 的日期。看不出日期的一律当成**不过期**
    /// （旧包里的源很多没有日期，全判过期会让老用户一进来整页「未测」，
    /// 那不是诚实，是把一个数据缺口变成一次显然的错误结论）。
    static func isDeclaredExpired(_ site: Site, now: Date = Date()) -> Bool {
        guard let date = SourceProbeImport.declaredDate(in: site.raw) else { return false }
        return now.timeIntervalSince(date) > declaredTrustWindow
    }

    /// 一组源的分布。分组头、书架、测速页都读它，免得三处各算一遍而口径不同。
    public static func counts(_ sites: [Site], now: Date = Date(),
                              reading: (Site) -> SourceProbeResult?) -> TierCounts {
        var counts = TierCounts()
        for site in sites { counts.add(tier(of: site, reading: reading(site), now: now)) }
        return counts
    }

    /// 按档位排序：能播 → 偏慢 → 未测 → 不通。
    ///
    /// **稳定排序**：同一档里保留调用方原来的顺序。这是关键 —— 组内的原始顺序是
    /// `SourceStrategy.arrange` 排出来的（同一个站的不同接法挨着、运行时便宜的在前），
    /// 用一次不稳定的排序会把那层秩序打散，读者看到的会是「换个页面顺序就变」。
    public static func sorted(_ sites: [Site], tier: (Site) -> SourceTier) -> [Site] {
        sites.enumerated()
            .sorted { lhs, rhs in
                let left = tier(lhs.element).rank, right = tier(rhs.element).rank
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

/// 四个档位各有多少个源。
public struct TierCounts: Equatable, Sendable {
    public var playable = 0
    public var slow = 0
    public var untested = 0
    public var dead = 0

    public init() {}

    public var total: Int { playable + slow + untested + dead }
    /// 测过了的（三个非 `untested` 之和）。
    public var measured: Int { total - untested }
    /// 还能看的（能播 + 慢）。
    public var usable: Int { playable + slow }

    public mutating func add(_ tier: SourceTier) {
        switch tier {
        case .playable: playable += 1
        case .slow: slow += 1
        case .untested: untested += 1
        case .dead: dead += 1
        }
    }

    public subscript(tier: SourceTier) -> Int {
        switch tier {
        case .playable: return playable
        case .slow: return slow
        case .untested: return untested
        case .dead: return dead
        }
    }
}
