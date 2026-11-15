import Foundation

/// 源列表的**显示偏好**：书架按什么分、只看能播、源按连通排序，连同组内书架的折叠/展开。
///
/// 为什么单独存而不是留在 `@State`：这些都是读者调过一次就想一直生效的设置。
/// 重启、锁屏几小时、切到别的环境再回来，页面应当还是他离开时的样子 ——
/// 一份躺在内存里的折叠状态，关一次 App 就散，读者会以为「这功能记不住」。
///
/// 每个偏好一个键：旧版本没有的键读到 nil 时用默认值，不会把已经存下的其它偏好一起清掉。
public struct SourceShelfState {
    private let defaults: UserDefaults

    private enum Key {
        static let mode = "sourceShelfMode.v1"
        static let onlyPlayable = "sourceOnlyPlayable.v1"
        static let sortByConnection = "sourceSortByConnection.v1"
        static let collapsed = "sourceCollapsedShelves.v1"
        static let expanded = "sourceExpandedShelves.v1"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 默认 `.auto`：有实测结论就按连通分，没有就按内容分。
    public var mode: SourceShelfMode {
        guard let raw = defaults.string(forKey: Key.mode) else { return .auto }
        return SourceShelfMode(rawValue: raw) ?? .auto
    }

    public func save(_ mode: SourceShelfMode) {
        defaults.set(mode.rawValue, forKey: Key.mode)
    }

    /// 只看能播。默认关 —— 一进来只剩几十张卡，会像「源全丢了」。
    public var onlyPlayable: Bool {
        defaults.object(forKey: Key.onlyPlayable) as? Bool ?? false
    }

    public func save(onlyPlayable: Bool) {
        defaults.set(onlyPlayable, forKey: Key.onlyPlayable)
    }

    /// 组内把能播的排到前面。默认开：没有读数时四档都是「未测」，排序是空操作，
    /// 有读数时才生效 —— 所以默认开不会改变没测过的人看到的顺序。
    public var sortByConnection: Bool {
        defaults.object(forKey: Key.sortByConnection) as? Bool ?? true
    }

    public func save(sortByConnection: Bool) {
        defaults.set(sortByConnection, forKey: Key.sortByConnection)
    }

    /// 组内哪些书架折着（键是 `组id|书架id`）。
    public var collapsedShelves: Set<String> {
        Set(defaults.stringArray(forKey: Key.collapsed) ?? [])
    }

    public func save(collapsedShelves: Set<String>) {
        defaults.set(Array(collapsedShelves).sorted(), forKey: Key.collapsed)
    }

    /// 哪些书架点过「展开其余」。
    ///
    /// 与折叠同理：读者把一组 168 个源摊开、翻到底，离开再回来又收成一屏，
    /// 会以为那个「展开」没生效过。展开的是哪几格，也一并记住。
    public var expandedShelves: Set<String> {
        Set(defaults.stringArray(forKey: Key.expanded) ?? [])
    }

    public func save(expandedShelves: Set<String>) {
        defaults.set(Array(expandedShelves).sorted(), forKey: Key.expanded)
    }

    public func clear() {
        for key in [Key.mode, Key.onlyPlayable, Key.sortByConnection, Key.collapsed, Key.expanded] {
            defaults.removeObject(forKey: key)
        }
    }
}
