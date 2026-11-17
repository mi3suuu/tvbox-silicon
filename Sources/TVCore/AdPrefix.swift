import Foundation

/// **源级广告前缀**：某些源给**每一条视频**都拼同一段开头广告。
///
/// ## 为什么需要单独一套机制
///
/// 用户实测的现象：番茄资源采集接口「每个视频前 15 秒都是一样的」。
/// 这与「随机贴片广告」是**完全不同的问题**：
///   · 随机贴片 → 只能按**内容**认（画面指纹），要学习、会误判；
///   · 固定前缀 → 按**结构**认（播放清单里的固定那几片），**零学习、零误判**。
///
/// 实测证据（2026-11-17，番茄源 fqzy.me → fqm3u8.cc，3 个不同视频）：
///
/// ```
/// 三个视频的清单开头完全相同：
///   #EXT-X-KEY:METHOD=NONE
///   #EXTINF:4,         /20261116/df50c5905e2cbc7e/seg_k8bord_00000.jpg
///   #EXTINF:4,         /20261116/df50c5905e2cbc7e/seg_k8bord_00001.jpg
///   #EXTINF:4,         /20261116/df50c5905e2cbc7e/seg_k8bord_00002.jpg
///   #EXTINF:3.033333,  /20261116/df50c5905e2cbc7e/seg_k8bord_00003.jpg
///   #EXT-X-DISCONTINUITY          ← 广告结束
///   #EXT-X-KEY:METHOD=AES-128,…   ← 正片开始（鉴权与会话都不一样）
///   …各自不同的正片分片…
/// ```
///
/// 三条清单的广告段：分片地址**逐字相同**、时长**都是 15.03 秒**。
/// 正片首段则各自不同（`9fcf6455…` / `30a1ae31…` / `f35db80c…`）。
///
/// ## 判据（刻意做得非常窄）
///
/// 只认这种形态：**开头一小段**（≤ `prefixLimit` 秒）+ 紧跟一个 `#EXT-X-DISCONTINUITY`
/// + 这段的**文件路径段与后面正片不同**。三条同时成立才动。
///
/// 宁可漏掉，不可错切：切错会把正片开头吃掉，用户看不出来是哪个功能干的。
/// 所以：
///   · 只处理**开头**的前缀，不动中段（中段广告交给 `AdSkip` 的 host/family 判据）；
///   · 前缀总时长上限 90 秒（超过就是正片的一部分，不是广告）；
///   · 要求它后面确实还有片子，且被切掉的占比很小；
///   · 不要求跨视频记忆 —— 每次只看这一条清单自己的结构，因此**对任何源都免学习**。
public enum AdPrefix {

    /// 前缀最长多少秒还算广告。实测这条源是 15.03 秒；给到 90 秒覆盖更长的贴片。
    public static let longestPrefix = 90.0
    /// 前缀至少要这么多秒，太短的（<2 秒）多半是台标或缓冲片头，不当广告。
    public static let shortestPrefix = 2.0
    /// 切掉的部分不得超过全片这个占比 —— 保护短视频与"整段都是广告"的异常清单。
    public static let largestShare = 0.10
    /// 全片至少这么长才动（短片的前几秒本来就是内容）。
    public static let shortestVideo = 120.0

    public struct Result: Equatable, Sendable {
        /// 去掉前缀后的清单文本。
        public let text: String
        /// 被当作广告切掉的分片数。
        public let segments: Int
        /// 被切掉的总时长（秒）。
        public let seconds: Double
        /// 前缀分片所在路径（用于诊断/展示）。
        public let path: String
    }

    private struct Segment {
        var tags: [String]
        var address: String
        var url: URL
        var duration: Double
        var discontinuity: Bool
    }

    /// 剥掉开头的固定广告前缀。不是这种形态时返回 `nil`，调用方原样放行。
    ///
    /// - Parameter text: 已下发的 media playlist 文本（含 `#EXT-X-ENDLIST`）
    /// - Parameter origin: 该清单自身的地址，用于把相对分片解析成绝对地址
    public static func strip(_ text: String, origin: URL) -> Result? {
        // 只处理**已完结的 media playlist**：master playlist 里没有分片；
        // 直播清单（无 ENDLIST）不能改 —— 切了会让播放器追不上直播边缘。
        guard text.contains("#EXT-X-ENDLIST"), !text.contains("#EXT-X-STREAM-INF") else { return nil }

        var header: [String] = []
        var segments: [Segment] = []
        var pending: [String] = []
        var duration = 0.0
        var discontinuity = false
        var started = false

        for line in text.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            if value == "#EXT-X-DISCONTINUITY" { discontinuity = true; continue }
            if value.hasPrefix("#") {
                if value.hasPrefix("#EXTINF:") {
                    started = true
                    duration = Double(value.dropFirst(8).prefix { $0 != "," }
                        .trimmingCharacters(in: .whitespaces)) ?? 0
                }
                if started { pending.append(line) } else { header.append(line) }
                continue
            }
            guard started, let url = URL(string: value, relativeTo: origin)?.absoluteURL else { return nil }
            segments.append(Segment(tags: pending, address: line, url: url,
                                    duration: duration, discontinuity: discontinuity))
            pending = []
            discontinuity = false
            duration = 0
        }
        guard !segments.isEmpty else { return nil }

        let total = segments.reduce(0) { $0 + $1.duration }
        guard total >= shortestVideo else { return nil }

        // 找**第一个** discontinuity —— 那就是"前缀结束、正片开始"的位置。
        //
        // 只认第一个：后面的 discontinuity 属于正片内部的正常分界
        // （这份清单里就有 13 个），碰了会把正片切碎。
        guard let cut = segments.firstIndex(where: { $0.discontinuity }), cut > 0 else { return nil }

        let prefix = segments[0..<cut]
        let prefixSeconds = prefix.reduce(0) { $0 + $1.duration }
        guard prefixSeconds >= shortestPrefix, prefixSeconds <= longestPrefix else { return nil }
        guard prefixSeconds <= total * largestShare else { return nil }
        // 切完必须还有片子。
        guard cut < segments.count else { return nil }

        // **关键判据**：前缀必须与正片"不是同一批文件"。
        //
        // 拿路径的目录部分比：广告 `/20261116/df50…/seg_k8bord_*`、
        // 正片 `https://fqts5.top/20261030/9fcf…/seg_*` —— 目录不同。
        // 若目录相同（同一批编号连续的分片），那多半是正片被 `#EXT-X-DISCONTINUITY`
        // 正常分成了多段（比如广告插播点、或转码分片边界），不是广告前缀 —— 不动。
        let prefixDirs = Set(prefix.map { $0.url.deletingLastPathComponent().absoluteString })
        let bodyDirs = Set(segments[cut...].map { $0.url.deletingLastPathComponent().absoluteString })
        guard prefixDirs.isDisjoint(with: bodyDirs) else { return nil }

        // 前缀里若带 KEY / MAP / BYTERANGE 之类的非 EXTINF 标签，说明它与后面共享加密或索引，
        // 切掉会让保留部分失去依赖 —— 保守放行。
        for segment in prefix {
            if segment.tags.contains(where: { !$0.hasPrefix("#EXTINF:") }) { return nil }
        }

        // 组装：header + 正片（首个正片分片自带的 discontinuity 已经失去意义，去掉）
        var lines = header
        var first = true
        for segment in segments[cut...] {
            if segment.discontinuity, !first { lines.append("#EXT-X-DISCONTINUITY") }
            lines += segment.tags
            lines.append(segment.address)
            first = false
        }
        // 收尾：原清单是已完结的（上面 guard 过），补回 ENDLIST。
        lines.append("#EXT-X-ENDLIST")

        let path = prefix.first?.url.deletingLastPathComponent().lastPathComponent ?? "-"
        return Result(text: lines.joined(separator: "\n") + "\n",
                      segments: prefix.count, seconds: prefixSeconds, path: path)
    }
}
