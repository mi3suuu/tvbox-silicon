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
public enum SourceProbeImport {

    /// 从源定义里读出的结果。没有可用的 `_` 字段时返回 nil（= 这个源没被外部测过）。
    public static func reading(from raw: [String: JSONValue], measuredAt: Date = Date()) -> SourceProbeResult? {
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
        let reachability: SourceProbeResult.Reachability
        switch route {
        case let text? where text.contains("不通") || text.contains("失败"):
            reachability = .unreachable
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
        let height = parseHeight(quality)

        return SourceProbeResult(
            reachability: reachability,
            latencyMilliseconds: nil,       // 外部配置不带延迟，别编。
            kilobytesPerSecond: speed,
            resolutionHeight: height,
            resolutionLabel: height.map { "\($0)P" },
            measuredAt: measuredAt,
            declaredConflicted: conflicted
        )
    }

    /// `1920x1080` → 1080。取较长边，竖屏 `720x1280` 才不会被读成 720p。
    private static func parseHeight(_ quality: String?) -> Int? {
        guard let quality else { return nil }
        let parts = quality.lowercased().split(separator: "x")
        guard parts.count == 2,
              let a = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let b = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        let long = max(a, b), short = min(a, b)
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
