import Foundation

/// 把外部「已测速」配置里夹带的读数读进来 —— 但要先判它可不可信。
///
/// 为什么需要这一层
/// --------------
/// 外部生成的订阅（`yingxia-unified-*-ranked.json`）会把测速结果**写进源定义本身**：
///
/// ```json
/// "raw": { …, "_speedKBps": 299.2, "_mbps": 0.92, "_quality": "1920x1080",
///                "_route": "现状", "_note": "2026-11-10 实测" }
/// ```
///
/// 这本来是好事：341 个源里有 38 个带着读数，省掉一轮全量测速。
/// 但实测那 38 条**没有一条**满足 `mbps == KB/s × 8 / 1024`，比值散布在 0.12–1.87 ——
/// 两个数来自不同时刻、不同样本。所以不能直接信。
///
/// 这里的做法：**两个都给就按矛盾处理**，只用 `_route` 判可达性；
/// 只有一个速度字段时才当速度用；`_route == "不通"` 直接判不可达。
/// 判定结果写进 `declaredConflicted`，排序层（`sortScore`）据此决定要不要吃速度。
///
/// 还有两件同样重要的事：
/// - **时间戳必须来自数据，不能来自 `Date()`**。给「此刻」会让包内标签压过昨天真测的结论，
///   也会让「刚装完测速」十分钟内全是「刚测过」。见 `declaredDate(in:)`。
/// - 每条结果都带 `declared: true`：`SourceProbeStore.importReadings` 靠它保证
///   「自测过的源，包标签永不覆盖」。
public enum SourceProbeImport {

    /// 从源定义里读出的结果。没有可用的 `_` 字段时返回 nil（= 这个源没被外部测过）。
    ///
    /// - Parameters:
    ///   - measuredAt: 这条读数是什么时候量的。**不要传 `Date()`** —— 那是「现在」，
    ///     不是「量的时候」。调用方传所在订阅的 `importedAt`；源自己写着日期时优先用源的
    ///     （`_probe.at` / `_note` 开头的 `2026-11-11`）。两样都没有就是 `.distantPast`：
    ///     一条没有日期的读数就该被当成很旧，而不是刚出炉。
    public static func reading(from raw: [String: JSONValue], measuredAt: Date? = nil) -> SourceProbeResult? {
        let route = raw["_route"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kbps = number(raw["_speedKBps"])
        let mbps = number(raw["_mbps"])
        let quality = raw["_quality"]?.string

        // 三个字段全无 → 这个源没被外部测过，别硬造一条读数。
        guard route != nil || kbps != nil || mbps != nil || quality != nil else { return nil }

        // ① 可达性：只认 `_route` 里的明确措辞。
        //
        //    「不通」是确定的负结论，比任何速度数字都强 —— 有源标着 0 KB/s
        //    却也标着 720x1280 的画质，那种自相矛盾只有 route 能裁决。
        //
        // ⛔ 「需代理」必须排在「代理」之前判。它含「代理」两个字，而被中转时代的措辞
        //    （「需中转」「代理」）判的是**可达**；漏了这一条，「需代理」会被读成
        //    「经代理可达」—— 方向正好反了，一个本机连不上的源会拿到 `reachable` 的读数。
        let reachability: SourceProbeResult.Reachability
        switch route {
        case let text? where text.contains("不通") || text.contains("失败"):
            reachability = .unreachable
        case let text? where text.contains("需代理"):
            reachability = .unknown
        case let text? where text.contains("慢"):
            reachability = .slow
        case let text? where text.contains("直连") || text.contains("代理") || text.contains("现状"):
            reachability = .reachable
        case nil:
            // 没有 route 但有数字：数字本身能证明它连上过。
            reachability = (kbps != nil || mbps != nil) ? .reachable : .unknown
        default:
            reachability = .unknown
        }

        // ② 速度：**两个字段都有就一个都不用**。
        //
        //    这是本文件存在的主要理由。挑了其中一个，等于在没有依据的情况下
        //    替用户决定「信哪个」，而两个数差过 8 倍的源不在少数。
        //    只留一个时用它，并把 Mbps 换算成 KB/s（1024 进制，与 UI 一致）。
        let conflicted = kbps != nil && mbps != nil
        var speed: Int?
        if conflicted {
            speed = nil
        } else if let kbps, kbps > 0 {
            speed = Int(kbps.rounded())
        } else if let mbps, mbps > 0 {
            // Mbps → KB/s：× 1024 / 8。
            speed = Int((mbps * 1024 / 8).rounded())
        }

        // ③ 分辨率：`1920x1080` / `1280x720`。取**较高的那一边**当高度 ——
        //    有竖屏源写成 `720x1280`，按第一个数字会读成 720p，实际它是 720 宽。
        let height = height(fromQuality: quality)

        return SourceProbeResult(
            reachability: reachability,
            latencyMilliseconds: nil,       // 外部配置不带延迟，别编。
            kilobytesPerSecond: speed,
            resolutionHeight: height,
            resolutionLabel: height.map { "\($0)P" },
            measuredAt: declaredDate(in: raw) ?? measuredAt ?? .distantPast,
            declaredConflicted: conflicted,
            declared: true
        )
    }

    /// 源定义里写着的「什么时候量的」。
    ///
    /// 打包脚本给每个探测过的源写了 `_probe: { …, "at": "2026-11-11" }`（日精度），
    /// 没走到 `_probe` 的那些只留下 `_note: "2026-11-11 实测可播 · 1280x720"`。
    /// 两种都认：这条读数有多可信，一半取决于它有多旧。
    ///
    /// 解析不出来就返回 nil，由调用方回落到订阅的导入时间 —— **绝不回落到「现在」**。
    static func declaredDate(in raw: [String: JSONValue]) -> Date? {
        if let at = raw["_probe"]?.object?["at"]?.string, let date = parseDay(at) { return date }
        if let note = raw["_note"]?.string, let date = parseDay(note) { return date }
        return nil
    }

    /// `2026-11-11` / `2026-11-11 实测…` → 当天中午（UTC+8）。
    ///
    /// 取正午而不是零点：同一天的两条读数在哪个时区解析都落在同一天，
    /// 不会因为时区差一天而让「谁更新」翻面。
    ///
    /// 手算公历→儒略日，不用 `Calendar` / `DateFormatter`：这个函数会被源列表的每次 body
    /// 反复调用（每张卡片一次），而 `Calendar.date(from:)` 每次都要建对象、查时区表，
    /// 700 个源的页面上那是肉眼可见的一帧开销。这里的算术是常数时间、零分配。
    static func parseDay(_ text: String) -> Date? {
        let prefix = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10)
        guard prefix.count == 10,
              prefix[prefix.index(prefix.startIndex, offsetBy: 4)] == "-",
              prefix[prefix.index(prefix.startIndex, offsetBy: 7)] == "-" else { return nil }
        let parts = prefix.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        var year = parts[0]
        let month = parts[1], day = parts[2]
        // Howard Hinnant 的 `days_from_civil`：1970-01-01 为第 0 天。
        year -= month <= 2 ? 1 : 0
        let era = (year >= 0 ? year : year - 399) / 400
        let yearOfEra = year - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -9 : 3)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        // 当天正午（UTC+8）= 04:00 UTC。
        return Date(timeIntervalSince1970: Double(days) * 86_400 + 4 * 3_600)
    }

    /// `1920x1080` → 1080。取较长边，竖屏 `720x1280` 才不会被读成 720p。
    ///
    /// `internal` 而不是 `private`：`SourceConnectivity.declaredTier` 也要读画质来抬门槛，
    /// 而它不该为此把整条读数（含日期解析、字典分配）算一遍。
    static func height(fromQuality quality: String?) -> Int? {
        guard let quality else { return nil }
        let parts = quality.lowercased().split(separator: "x")
        guard parts.count == 2,
              let a = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let b = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        let short = min(a, b)
        // 常见的 16:9 与 2.35:1：宽 > 高 时高度是短边。
        // 但 `720x1280` 是竖屏海报式转码，短边才是「垂直分辨率」的语义 ——
        // 对观看页来说能拿到多少像素行由短边决定，所以统一取短边。
        return short == 0 ? nil : short
    }

    /// JSON 里的数字可能是 int 也可能是 double。
    private static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let d): return d
        case .string(let text): return Double(text)
        default: return nil
        }
    }
}
