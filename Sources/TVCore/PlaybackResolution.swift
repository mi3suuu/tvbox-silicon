import Foundation

public struct PlaybackChoice: Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let address: String

    /// 这条地址是不是「一个网页」，而不是媒体流。
    ///
    /// 采集站把云播页（`/share/<hash>`、`/play/<id>`）与平台页（优酷/爱奇艺/腾讯/芒果/B站）
    /// 直接填在 `vod_play_url` 里是常态：内置 141 个源实测 26 条线是这样。
    /// 它们回 200、回几十 KB HTML，探针判「通」，播放器拿到却打不开 —— 转圈到超时。
    ///
    /// 判据只看**地址长相**（不看内容，播放前没有内容可看）：
    /// 不是直链媒体 + （已知平台域名 或 路径像播放页）。真正的内容判定在解析之后
    /// （`SourceProbeResult.mediaKind`），两层各管一段。
    public var looksLikePage: Bool { PlaybackChoice.isPageAddress(address) }

    static func isPageAddress(_ address: String) -> Bool {
        let lower = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty, !lower.hasPrefix("magnet:") else { return false }
        // 已带 scheme 前缀的解析服务地址（`parse:` / `json:`）不在这里判。
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
        if CatalogClient.isDirectMedia(address) { return false }
        guard let url = try? WebAddress.resolve(address), let host = url.host()?.lowercased() else { return false }
        let platforms = ["youku.com", "v.qq.com", "iqiyi.com", "mgtv.com", "bilibili.com",
                         "b23.tv", "sohu.com", "le.com", "pptv.com", "tudou.com", "wasu.cn"]
        if platforms.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        let path = url.path.lowercased()
        return path.contains("/share/") || path.contains("/play/") || path.hasPrefix("/v_show/")
    }
    static func parse(_ value: JSONValue?, prefix: String = "", fallbackName: String) -> [PlaybackChoice] {
        if let text = value?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [PlaybackChoice(id: 0, name: fallbackName, address: prefix + text)]
        }
        if let values = value?.object?["values"]?.array {
            // FongMi's Url: {"values": [{"n": name, "v": address}], "position": the one it plays}; the others are
            // the same episode in other qualities. FongMi's new-SDK spiders answer this (#500).
            let position = value?.object?["position"]?.int ?? 0
            let order = values.indices.contains(position) ? [position] + values.indices.filter { $0 != position } : Array(values.indices)
            var choices: [PlaybackChoice] = []
            for index in order {
                guard let address = values[index].object?["v"]?.string, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let name = values[index].object?["n"]?.string ?? ""
                choices.append(PlaybackChoice(id: choices.count, name: name.isEmpty ? fallbackName : name, address: prefix + address))
            }
            return choices
        }
        guard let values = value?.array else { return [] }
        var choices: [PlaybackChoice] = []
        for index in stride(from: 0, to: values.count - values.count % 2, by: 2) {
            guard let name = values[index].string, let address = values[index + 1].string,
                  !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            choices.append(PlaybackChoice(id: index / 2, name: name.isEmpty ? fallbackName : name, address: prefix + address))
        }
        return choices
    }
}

public struct PlaybackPlan: Sendable {
    public let choices: [PlaybackChoice]
    public let headers: [String: String]
    public let group: String
    public let requiresWebDetection: Bool
    /// Site click when that is non-empty, otherwise the play result click.
    public let click: String
    /// `json:` or `parse:` copied off the front of the address. Empty when the prefix is already joined on, or there is none.
    public let webPlayURL: String
    /// The play result's subtitle files (`subs`).
    public let subtitles: [ExternalSubtitle]
    /// The play result's opening and ending credits (`skips`).
    public let skips: [PlaybackSkip]
    public init(choices: [PlaybackChoice], headers: [String: String], group: String, requiresWebDetection: Bool, click: String = "", webPlayURL: String = "",
                subtitles: [ExternalSubtitle] = [], skips: [PlaybackSkip] = []) {
        self.skips = skips
        self.choices = choices
        self.headers = headers
        self.group = group
        self.requiresWebDetection = requiresWebDetection
        self.click = click
        self.webPlayURL = webPlayURL
        self.subtitles = subtitles
    }
}
