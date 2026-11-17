import Foundation
import CoreGraphics

// MARK: - 坞的会话快照（下次进 App 一键恢复）

/// 一条「上次开着小窗」的记录：看的是哪一集、放到哪、窗口摆在哪。
///
/// ## 为什么需要
///
/// 用户要求：「迷你小窗的历史播放窗口 坐标 各个窗口进度，需要记忆住，
/// 在下次重新进入 app 的时候可以一键恢复上次打开的所有迷你小窗。」
///
/// 坞里的任务本质上是**一路 AVPlayer**，App 被杀掉之后它一定没了 ——
/// 能留下的是「怎么把它重新建起来」的配方：哪一集、哪条线、看到哪、窗口多大放在哪。
///
/// ## 为什么不存播放地址
///
/// 存 `Channel.url` 是不行的：源站的直链带时效签名，下次进来早就过期了。
/// 所以只存 `PlaybackHistoryContext`（剧/集/源的标识），恢复时**重新解析**一次。
/// 这也和「继续播放」那条链路天然一致 —— 它本来就要重新解析。
public struct DockSessionSnapshot: Codable, Hashable, Sendable {

    /// 看的是哪一集（同时决定从哪儿重新解析）。
    public var context: PlaybackHistoryContext
    /// 上次看到的位置（秒）。恢复后从这里接着播。
    public var position: Double
    /// 上次的总时长（秒）。0 表示未知 —— 恢复后等 tick 填。
    public var duration: Double
    /// 窗口宽度倍率（相对坞给的基准宽度）。1 = 默认大小。
    public var scale: Double
    /// 窗口相对右下角锚点的偏移（pt）。往左/上为负。
    public var offsetX: Double
    public var offsetY: Double
    /// 保存时刻。用于排序（最近的在前）与清理。
    public var savedAt: Date

    public init(context: PlaybackHistoryContext, position: Double, duration: Double,
                scale: Double, offset: CGSize, savedAt: Date = Date()) {
        self.context = context
        self.position = position
        self.duration = duration
        self.scale = scale
        self.offsetX = Double(offset.width)
        self.offsetY = Double(offset.height)
        self.savedAt = savedAt
    }

    public var offset: CGSize { CGSize(width: offsetX, height: offsetY) }
}

/// 快照集合的编解码 + 清理规则。纯数据，可直接断言。
public enum DockSessionStore {

    /// 最多记几条。与 `PlaybackCapacity.dock` 对齐 —— 能挂几个就记几个，
    /// 多记的没用（坞本身也放不下）。
    public static var capacity: Int { PlaybackCapacity.dock }

    /// 超过多久的快照不再恢复（秒）。
    ///
    /// 3 天：短于「隔夜还想接着看」，长于「源站的直链早就不能用了」这个直觉边界。
    /// 但**过期不等于丢掉进度** —— 位置已经写进 `PlaybackHistory`，
    /// 这里只是不再自动把窗口摆回来。
    public static let maxAge: TimeInterval = 3 * 24 * 3600

    /// 归一化：按时间倒序、去重（同一集只留最新）、丢掉过期与无效项，并截到容量。
    public static func normalized(_ items: [DockSessionSnapshot], now: Date = Date()) -> [DockSessionSnapshot] {
        var seen = Set<String>()
        var out: [DockSessionSnapshot] = []
        for item in items.sorted(by: { $0.savedAt > $1.savedAt }) {
            // 过期的不再恢复。
            guard now.timeIntervalSince(item.savedAt) <= maxAge else { continue }
            // 同一集（同 scope + 同 episodeID）只留最新那条。
            let key = item.context.id + "|" + item.context.episodeID
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(item)
            if out.count >= capacity { break }
        }
        return out
    }

    /// 把快照的窗口位置钳回可视区（形态变化后可能已经出界）。
    ///
    /// ⛔ 恢复时必须钳一次：上次是横屏摆的，这次竖屏进来，原来的偏移可能整个在屏外。
    ///    这正是用户说的「不能找回不在屏幕内的小窗」在**恢复路径**上的同一个坑。
    public static func clamped(_ items: [DockSessionSnapshot],
                               containers: [CGSize],
                               card: CGSize) -> [DockSessionSnapshot] {
        guard let container = containers.first else { return items }
        return items.map { item in
            var copy = item
            let c = DockCardClamp.clamp(item.offset, card: card, in: container)
            copy.offsetX = Double(c.width)
            copy.offsetY = Double(c.height)
            return copy
        }
    }

    public static func encode(_ items: [DockSessionSnapshot]) -> Data? {
        try? JSONEncoder().encode(normalized(items))
    }

    public static func decode(_ data: Data) -> [DockSessionSnapshot] {
        guard let items = try? JSONDecoder().decode([DockSessionSnapshot].self, from: data) else { return [] }
        return normalized(items)
    }
}
