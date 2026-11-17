import Foundation

/// 每个源「最后一次取片单，赛跑是哪条腿赢的」。
///
/// 观众要能一眼看出「这个源到底走的直连还是代理」，而不是翻日志自己拼。
/// 记录点是**请求成功之后**，所以这里存的永远是真实发生了的那一次，
/// 不是配置里希望的那一次 —— 「标了代理但实际直连」这种事，靠它才看得见。
public final class EgressOutcomeStore: @unchecked Sendable {
    public struct Entry: Sendable, Equatable {
        public let host: String
        /// `direct` 或 `proxy`。
        public let leg: String
        public let at: Date
        public var isProxy: Bool { leg == "proxy" }
    }

    public static let shared = EgressOutcomeStore()

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    public func note(sourceKey: String, host: String, leg: EgressLeg) {
        guard !sourceKey.isEmpty, !host.isEmpty else { return }
        let entry = Entry(host: host.lowercased(), leg: leg.label, at: Date())
        lock.withLock { entries[sourceKey] = entry }
    }

    public func latest(sourceKey: String) -> Entry? {
        lock.withLock { entries[sourceKey] }
    }

    /// 超过一分钟的结论不再展示：观众改完设置后，旧结果留在界面上会误导。
    public func fresh(sourceKey: String, within seconds: TimeInterval = 300) -> Entry? {
        guard let entry = latest(sourceKey: sourceKey) else { return nil }
        return Date().timeIntervalSince(entry.at) <= seconds ? entry : nil
    }
}
