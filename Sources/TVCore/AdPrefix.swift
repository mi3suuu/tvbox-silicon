import Foundation

/// **源级广告前缀**：某些源给每条视频都拼同一段（或几段）**外来分片**当广告。
///
/// ## 判据是「目录占少数」，不是「DISCONTINUITY」
///
/// 实测（2026-11-17，4 个成人源、真实抓下的播放清单）：
///
/// | 源 | 主目录时长占比 | 广告目录 |
/// |---|---|---|
/// | 番茄 A | 98.5% | 1.3% + 0.2% |
/// | 番茄 X1 | 98.0% | 1.6% + 0.4% |
/// | 玉兔 Y2 | 93.2% | 6.8% |
/// | 155 Z2 | 99.4% | 0.6% |
///
/// 形态高度一致：**正片来自一个主目录（93–99% 时长），广告来自别的小目录**。
/// 广告时长随源变（15.033 / 26.067 / 25.760 秒），所以**不能硬编码秒数**。
///
/// ## 三条必须避开的坑（都是实测踩到的）
///
/// ⛔ **不能用 `#EXT-X-DISCONTINUITY` 当判据**：
///    番茄 A/B/D 各有 13 个、X1 有 **131 个**，而真实广告块只有几段。
///    正片内部本来就按 DISCONTINUITY 分段，拿它当边界会大量误切。
///
/// ⛔ **不能用 `METHOD=NONE` 当判据**：
///    番茄是「广告段不加密、正片段 AES-128」，看着很干净；
///    但玉兔、155 **全片零 AES、100% METHOD=NONE** ——
///    在那两个源上会把整片判成广告。
///
/// ⛔ **不能跨视频记忆**：那又回到了「要学习」。
///    这里每次只看这一条清单自己的时长分布，因此对任何源都免学习。
///
/// ## 判据（刻意窄）
///
/// 1. 取**时长占比最高**的目录为主目录（正片）；
/// 2. 其他目录里，时长 ≤ `largestShare`（30%）的**整段**移除；
/// 3. 移除总量 ≤ `largestTotal`（35%）——超了说明判据不成立，整条放行；
/// 4. 至少还要留下一个分段；
/// 5. 只处理**已完结的 media playlist**（`#EXT-X-ENDLIST`，无 `#EXT-X-STREAM-INF`）。
///    直播清单不能动：切了会让播放器追不上直播边缘。
///
/// 主目录判据天然安全：广告不可能占多数时长（用户要看的是正片）。
/// 万一某条清单被判错，最坏是「整条不剥」而不是「切掉正片」。
public enum AdPrefix {

    /// 单个非主目录最多占多少时长才算广告。超过说明它不是广告，是另一路正片（多码率/多段）。
    public static let largestShare = 0.30
    /// 所有被移除的目录加起来最多占多少。超过就整条放行，不动。
    public static let largestTotal = 0.35
    /// 主目录至少占这么多 —— 达不到说明这条清单不是"一个主片 + 若干广告"的形态。
    public static let smallestMainShare = 0.60
    /// 全片至少这么长才动（短片的前几秒本来就是内容）。
    public static let shortestVideo = 120.0

    public struct Result: Equatable, Sendable {
        /// 去掉广告后的清单文本。
        public let text: String
        /// 被移除的分片数。
        public let segments: Int
        /// 被移除的总时长（秒）。
        public let seconds: Double
        /// 被判定为主目录（正片）的路径片段，用于诊断。
        public let mainPath: String
        /// 被移除的目录数。
        public let droppedGroups: Int
    }

    private struct Segment {
        var tags: [String]
        var address: String
        var url: URL
        var duration: Double
        var discontinuity: Bool
        /// 目录路径（用来分组）。
        var group: String
    }

    /// 剥掉外来分片广告。不是这种形态时返回 `nil`，调用方原样放行。
    public static func strip(_ text: String, origin: URL) -> Result? {
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
            segments.append(Segment(tags: pending, address: value, url: url,
                                    duration: duration, discontinuity: discontinuity,
                                    group: group(of: url)))
            pending = []
            discontinuity = false
            duration = 0
        }
        guard !segments.isEmpty else { return nil }

        let total = segments.reduce(0) { $0 + $1.duration }
        guard total >= shortestVideo else { return nil }

        // ① 按时长给目录排序，最高者 = 正片主目录。
        var byGroup: [String: Double] = [:]
        for segment in segments { byGroup[segment.group, default: 0] += segment.duration }
        guard let main = byGroup.max(by: { $0.value < $1.value }) else { return nil }
        guard main.value >= total * smallestMainShare else { return nil }

        // ② 其余目录里，占比够小的才算广告。
        var dropped: Set<String> = []
        var droppedSeconds = 0.0
        for (group, seconds) in byGroup where group != main.key {
            guard seconds <= total * largestShare else { continue }
            dropped.insert(group)
            droppedSeconds += seconds
        }
        guard !dropped.isEmpty, droppedSeconds <= total * largestTotal else { return nil }

        let kept = segments.filter { !dropped.contains($0.group) }
        // ③ 至少还要留下正片。
        guard !kept.isEmpty else { return nil }

        // ④ 被丢的段里若带 KEY / MAP 之类，要看它是不是**广告自己**的。
        //
        //    实测：番茄的中插广告每段都自带一条 `#EXT-X-KEY:METHOD=NONE`
        //    （正片是 AES-128）。这条 KEY 属于广告，必须随广告一起丢掉。
        //    但如果是 `#EXT-X-MAP`（初始化段）或 BYTERANGE 之类，
        //    后面可能真的依赖它 —— 那种情况保守放行。
        for segment in segments where dropped.contains(segment.group) {
            for tag in segment.tags where !tag.hasPrefix("#EXTINF:") {
                // 广告自己的密钥声明：跟着广告丢，是安全的。
                if tag.hasPrefix("#EXT-X-KEY:") { continue }
                return nil
            }
        }

        // 组装。
        //
        // ⛔ 必须原样保留每个保留段的**全部标签**（尤其是 `#EXT-X-KEY`）。
        //    正片在番茄这类源上是 AES-128 加密的，KEY 标签一丢就解密失败 ——
        //    表现是「广告没了，但正片也放不出来」，比不去广告更糟。
        //    只跳过两类：被丢广告段自带的标签（整段不写）、以及紧随广告的孤立 DISCONTINUITY。
        var lines = header
        var first = true
        for segment in kept {
            // 开头那个 DISCONTINUITY 没有意义（前面已经没有内容了）。
            if segment.discontinuity, !first { lines.append("#EXT-X-DISCONTINUITY") }
            lines += segment.tags
            lines.append(segment.address)
            first = false
        }
        lines.append("#EXT-X-ENDLIST")

        let mainPath = main.key.split(separator: "/").suffix(2).joined(separator: "/")
        return Result(text: lines.joined(separator: "\n") + "\n",
                      segments: segments.count - kept.count,
                      seconds: droppedSeconds,
                      mainPath: mainPath,
                      droppedGroups: dropped.count)
    }

    /// 分组键：目录部分（去掉文件名）。
    ///
    /// 用目录而不是"host + 文件名模式"：实测广告与正片常常同 host、
    /// 只差一层目录（`/20261116/df50…/` vs `/20261030/{id}/`）。
    private static func group(of url: URL) -> String {
        url.deletingLastPathComponent().absoluteString
    }
}
