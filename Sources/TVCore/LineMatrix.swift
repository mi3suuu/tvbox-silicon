import Foundation

/// 同一个剧、跨渠道/跨子源/跨线路的连通性矩阵。
///
/// ## 它解决什么
///
/// 现有两处测速都只回答半个问题：
///   · `SourceSpeedTestView` 是**按源**一排一行，测的是「这个源整体怎么样」；
///   · 播放页线路菜单是**按当前源**的线路，测的是「这部在这源里哪条线快」。
///
/// 而用户换源的动机常常是「同一部剧，A 源的 2 号线 40ms 但只有 80KB/s，
/// B 源的 1 号线 120ms 但 3MB/s」—— 这需要**把三个维度摊平在一张表里**：
/// 剧（同一部） × 源（渠道/子源） × 线路。
///
/// 本文件只做纯数据聚合与排序，不碰网络 —— 探针由调用方注入，
/// 这样排序与择优逻辑可以单测钉死。
public enum LineMatrix {

    /// 一格：某源某线测得的一次读数。
    public struct Cell: Identifiable, Hashable, Sendable {
        public let sourceKey: String
        public let sourceName: String
        /// 该源里这一部的 id。**必须参与 `id`**。
        ///
        /// 去重键（`CrossSourceMatch.candidates`）是 `sourceKey|video.id`，
        /// 而展示 id 若只用 `sourceKey|flag`，同一源两个不同 vod_id 的同名条目
        /// 会撞 id —— 而「同源两个同名条目同时成为候选」是 CMS 源的常态。
        /// 撞了 id 会让 SwiftUI 的 `ForEach` 出现未定义行为（丢格/错视图），
        /// 且 `Row.best` / `overallBest` 可能选中看不见的那一格。
        public let videoID: String
        /// 线路名（`Episode.flag`）。单线源可能是空串或 "default"。
        public let flag: String
        public let result: SourceProbeResult?

        public var id: String { sourceKey + "|" + videoID + "|" + flag }

        public init(sourceKey: String, sourceName: String, videoID: String = "",
                    flag: String, result: SourceProbeResult?) {
            self.sourceKey = sourceKey
            self.sourceName = sourceName
            self.videoID = videoID
            self.flag = flag
            self.result = result
        }

        /// 可播的判据：测到了、且不是「不可连」。
        ///
        /// 未测（`nil`）**不算可播** —— 没测过不等于能用，把它当能用会误导换源。
        public var isUsable: Bool {
            guard let result else { return false }
            return result.isUsable
        }
    }

    /// 一行：一个源，连同它的所有线路。
    public struct Row: Identifiable, Hashable, Sendable {
        public let sourceKey: String
        public let sourceName: String
        public let cells: [Cell]

        public var id: String { sourceKey }

        public init(sourceKey: String, sourceName: String, cells: [Cell]) {
            self.sourceKey = sourceKey
            self.sourceName = sourceName
            self.cells = cells
        }

        /// 该源测得最好的一条线（按 `better(_:_:)` 的口径）。
        ///
        /// ⛔ 这里必须是 `max(by:)`，不是 `min { better($1, $0) }`。
        /// 后者把比较器参数调了个头又交给 `min`，两次取反等于没取 ——
        /// 实测选出来的正是**最差**那条（测试 `rowBestPicksFastestUsableLine` 抓到的就是这个）。
        public var best: Cell? {
            cells.filter(\.isUsable).max { LineMatrix.better($1, $0) }
        }
        public var usableCount: Int { cells.filter(\.isUsable).count }
    }

    /// 按源分组，源内按线路名排序，源间按「有没有可播线」+ 最优线排。
    ///
    /// 排序口径与 `CrossSourceMatch` 一致：先可达性，再吞吐，再延迟，最后分辨率 ——
    /// 「卡不卡」比「握手快不快」更接近换源的真实动机
    /// （旧的按延迟排会挑中 40ms 但 80KB/s 的线）。
    public static func build(_ cells: [Cell]) -> [Row] {
        let grouped = Dictionary(grouping: cells, by: \.sourceKey)
        let rows: [Row] = grouped.map { key, group in
            // 按 `Cell.id` 去重（保留第一个）。
            //
            // 重复是可达的：调用方先用**原始** flag 建 firstPerFlag 字典、
            // 建 Cell 时才把空串归一成 "default"，于是同一源若有 `""` 与 `"default"`
            // 两条线路，归一后两格 id 都是 `src|default` → ForEach id 冲突。
            // （子代理 C1 实跑确认 unique ids = 1 of 2。）
            var seenID = Set<String>()
            let unique = group.filter { seenID.insert($0.id).inserted }
            return Row(sourceKey: key,
                       sourceName: group.first?.sourceName ?? key,
                       cells: unique.sorted { $0.flag < $1.flag })
        }
        // ⛔ 这个比较器曾同时犯两个错（并行审查的子代理 B1/B2 用实跑抓出）：
        //
        // ① **方向反了**：原来写 `better(rb, lb) → return true`，
        //    `better(rb,lb)` 为真表示 **rhs 更好**，却让 lhs 排前面。
        //    实跑 `build([Zeta:4000kbps, Alpha:900kbps])` → 900 排第一，
        //    整个「跨线路矩阵」面板顺序几乎完全颠倒。
        //
        // ② **不构成严格弱序**：`better(rb,lb)` 为 false 时没有 `return false`，
        //    直落到名字兜底，实际语义变成 `cmp(A,B) = better(B,A) ? true : (A.name < B.name)`。
        //    于是「A 确实更好」且「A 名字更靠前」时**双向都返回 true**（反对称性被违反）。
        //    实跑：同一份 6 源输入连跑 4 次进程得到 4 种不同顺序 ——
        //    恰好与「避免每次刷新顺序乱跳」的设计目标相反。
        //
        // 现在：方向修正 + 两个方向都判 + 完全并列时用 sourceKey 兜底（保证全序）。
        return rows.sorted { lhs, rhs in
            // 有可播线的源排前面：换源只关心能用的。
            if (lhs.usableCount > 0) != (rhs.usableCount > 0) { return lhs.usableCount > 0 }
            if let lb = lhs.best, let rb = rhs.best {
                if better(lb, rb) { return true }
                if better(rb, lb) { return false }
                // 完全并列（同可达性、同吞吐、同延迟、同分辨率）也要有确定序，
                // 否则 Swift 的不稳定排序会让面板每次刷新都重排。
                return lhs.sourceKey < rhs.sourceKey
            }
            // 走到这里说明两者 best 同时为 nil 或同时非 nil。
            // `best != nil ⟺ usableCount > 0` 恒成立（上面已按该谓词分流），
            // 所以这两个分支实际是死代码 —— 保留只为穷尽，兜底仍是名字。
            return lhs.sourceName < rhs.sourceName
        }
    }

    /// `a` 是否比 `b` 更值得选。**未测的永远排在测过的后面。**
    public static func better(_ a: Cell, _ b: Cell) -> Bool {
        let ra = rank(a.result), rb = rank(b.result)
        if ra != rb { return ra > rb }
        let ka = a.result?.kilobytesPerSecond ?? 0
        let kb = b.result?.kilobytesPerSecond ?? 0
        if ka != kb { return ka > kb }
        let la = a.result?.latencyMilliseconds ?? Int.max
        let lb = b.result?.latencyMilliseconds ?? Int.max
        if la != lb { return la < lb }
        let ha = a.result?.resolutionHeight ?? 0
        let hb = b.result?.resolutionHeight ?? 0
        return ha > hb
    }

    /// 可达性权重。未知排「慢」之后、「不可连」之前 —— 没测过不等于坏，但也不该压过测通的。
    public static func rank(_ result: SourceProbeResult?) -> Int {
        switch result?.reachability {
        case .reachable: return 3
        case .slow: return 2
        case nil, .unknown: return 1
        case .unreachable: return 0
        }
    }

    /// 全矩阵里最值得选的一格 —— 「一键切到最快」的答案。
    public static func overallBest(_ rows: [Row]) -> Cell? {
        rows.compactMap(\.best).max { better($1, $0) }
    }
}
