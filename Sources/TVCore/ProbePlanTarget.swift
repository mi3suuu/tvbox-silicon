import Foundation

/// 一次「测这条线路」的完整定义：**先解析，再测**。
///
/// ## 为什么要有这个类型
///
/// 全仓有五个地方会测速（设置页、点播源面板、批量扫描、选集页、播放页/跨源面板）。它们本该测
/// 同一件事，但历史上各写各的，于是出现了三种口径分叉：
///
/// 1. **直接拿 `Episode.address` 去 HEAD。** 对 type 3/4（CatPaw / 苹果 CMS 播放器接口）的源，
///    `address` 是一个 play 参数（`第1集$abc123`），不是 URL。而 `URL(string: "abc123")` 会
///    返回一个**相对 URL** 而不是 nil，所以「地址非 nil 就测」的过滤条件一个都拦不住 ——
///    每次都在测一个不存在的地址，好源被判「不可达」。
/// 2. **不传 headers。** 要 Referer 的 CDN 对裸请求回 403，于是在选集页能播的源，在扫描里是死的。
/// 3. **缓存键与显示键不一致**（空 flag 被 `record` 静默丢弃，界面上却显示 `default`）。
///
/// 这三条的共同点：**「我要测什么」这件事没有唯一出处**。`resolve` 把它收敛成一处 ——
/// 给一个 `Episode` 和它所属的 `CatalogClient`，拿回「真实 URL + 该带的头」，测速调用方只
/// 需要关心这一个函数，就再也不可能分叉。
///
/// ## 用法
///
/// ```swift
/// guard let target = await ProbePlanTarget.resolve(episode, client: client) else { return nil }
/// let result = await SourceProbeRunner.probe(url: target.url, headers: target.headers)
/// ```
///
/// 解析失败返回 `nil`，调用方应当**跳过这条线路**（留作「未测」），而不是记成不可达：
/// 插件答不出播放地址和线路本身是死的，是两件不同的事。
public struct ProbePlanTarget: Sendable, Hashable {
    /// 真实可请求的流地址。
    public let url: URL
    /// 该 CDN 要求的请求头（UA / Referer / 签名）。空字典表示这条线路不需要额外头。
    public let headers: [String: String]
    /// 这条线路的标识，已归一化。空 flag 一律归成 `ProbePlanTarget.defaultFlag`。
    ///
    /// ⛔ 归一化必须发生在**写缓存之前**：`SourceProbeStore.record` 会静默丢弃空 flag，
    /// 而界面显示的是 `flag.isEmpty ? "default" : flag` —— 两处不一致时，那条线路的缓存
    /// 命中率恒为 0，界面上还看不出问题。
    public let flag: String

    /// 空 flag 线路的归一化标识。写库与显示必须都用它。
    public static let defaultFlag = "default"

    public init(url: URL, headers: [String: String] = [:], flag: String) {
        self.url = url
        self.headers = headers
        self.flag = flag.isEmpty ? Self.defaultFlag : flag
    }

    /// 把一个剧集解析成可测目标：`preparePlayback` → `resolvePlayback`，与播放走同一条路。
    ///
    /// 走 `client.playback(_:)`（内部就是那两步），因为那正是播放器按下播放时执行的路径 ——
    /// 测速如果和播放走了不同的路，测出来的数字就不代表「能不能播」。
    public static func resolve(_ episode: Episode, client: CatalogClient) async -> ProbePlanTarget? {
        guard let channel = try? await client.playback(episode) else { return nil }
        return ProbePlanTarget(url: channel.url, headers: channel.headers, flag: episode.flag)
    }

    /// 已经是真实 URL 时直接构造（播放页手里已经有了 `channel`）。
    public static func direct(url: URL, headers: [String: String], flag: String) -> ProbePlanTarget {
        ProbePlanTarget(url: url, headers: headers, flag: flag)
    }

    /// 这个地址是否值得送进 `URLRequest`：必须带 http(s) 方案。
    ///
    /// ⛔ 不能用 `URL(string:) != nil` 判断 —— 那个条件对 `abc123`、`/play/1-1-1` 全部成立。
    public static func isRequestable(_ address: String) -> Bool {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }
}
