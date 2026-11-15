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
    /// 能看的门槛：KB/s。
    ///
    /// 300 KB/s ≈ 2.4 Mbps，是 720P 一部剧的正常码率下限。低于它的源不是「不能用」，
    /// 是「会转圈」—— 那归 `slow`，仍然排在没测过的前面：它至少证明自己能出字节。
    public static let playableKilobytesPerSecond = 300

    /// 一个源的档位。
    ///
    /// 三种来源按可信度依次回落：
    /// 1. **App 里刚测的读数**（`SourceProbeStore.latest`）—— 最新，而且是这台设备、这条网络上量的。
    /// 2. **包内实测结论**（`raw._probe` / `raw._route`）—— 打包那天测的，会过时，但比「没测过」强。
    /// 3. 都没有 → `untested`。
    public static func tier(of site: Site, reading: SourceProbeResult?) -> SourceTier {
        if let reading { return tier(of: reading) }
        return declaredTier(of: site)
    }

    public static func tier(of reading: SourceProbeResult) -> SourceTier {
        switch reading.reachability {
        case .unreachable:
            return .dead
        case .slow:
            return .slow
        case .reachable, .unknown:
            guard let kbps = reading.kilobytesPerSecond, kbps > 0 else {
                // `unknown` 且没有任何数字：这条读数其实什么也没说。
                return reading.reachability == .reachable ? .playable : .untested
            }
            return kbps >= playableKilobytesPerSecond ? .playable : .slow
        }
    }

    /// 随包数据里写在源定义上的结论。
    ///
    /// `_probe` 是打包脚本写进去的实测行（`verdict` / `kbps`），`_route` 是更早的粗结论。
    /// 两者都在时 `_probe` 优先：它是播放探测（真出了字节），`_route` 只是路由判定。
    public static func declaredTier(of site: Site) -> SourceTier {
        if let probe = site.raw["_probe"]?.object {
            var kbps = 0.0
            if case .number(let value)? = probe["kbps"] { kbps = value }
            if kbps > 0 { return kbps >= Double(playableKilobytesPerSecond) ? .playable : .slow }
            switch probe["verdict"]?.string?.lowercased() {
            case "unreachable", "dead", "failed": return .dead
            case "direct", "proxy", "playable": return .playable
            default: break
            }
        }
        switch site.raw["_route"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "直连": return .playable
        case "失效", "不通", "失败": return .dead
        case "慢": return .slow
        default: return .untested
        }
    }

    /// 一组源的分布。分组头、书架、测速页都读它，免得三处各算一遍而口径不同。
    public static func counts(_ sites: [Site], reading: (Site) -> SourceProbeResult?) -> TierCounts {
        var counts = TierCounts()
        for site in sites { counts.add(tier(of: site, reading: reading(site))) }
        return counts
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
