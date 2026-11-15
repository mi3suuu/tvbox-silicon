import Foundation

/// 记住源列表用哪种书架：按连通、按内容，或者「有实测就按连通」。
///
/// 为什么单独存一个键：这是读者的偏好，不是某一组的临时状态。它跨分组生效（4K 组按连通看，
/// 影视组也一样），所以不能塞进每组的折叠状态里；重启后还要在，否则每次进页面都回到默认，
/// 「我上次切成按内容了」这件事就白做了。
public struct SourceShelfState {
    private let defaults: UserDefaults
    private static let storageKey = "sourceShelfMode.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 默认 `.auto`：有实测结论就按连通分，没有就按内容分。新装用户与老用户都从这一档开始。
    public var mode: SourceShelfMode {
        guard let raw = defaults.string(forKey: Self.storageKey) else { return .auto }
        return SourceShelfMode(rawValue: raw) ?? .auto
    }

    public func save(_ mode: SourceShelfMode) {
        defaults.set(mode.rawValue, forKey: Self.storageKey)
    }
}
