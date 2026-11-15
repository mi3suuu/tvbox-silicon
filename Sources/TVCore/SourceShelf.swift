import Foundation

/// 组里的「二级书架」：一个分组太多源时，按**内容形态**再分一层，而不是把组拆成更多组。
///
/// 为什么不是拆订阅：组是观众自己整理出来的批次（`SourceGroups`），一次 4K 组有 168 个源，
/// 拆成五个订阅级分组会让他原来的整理一片散架；而「组内再分层」既不动数据，
/// 也不改变「这个源属于哪个订阅」。名字取得比组小一号，是为了让人一眼看出这是第二层。
///
/// 分类只认名字里的形态词（磁力 / 弹幕 / 蓝光 / 网盘 …）—— 采集站给源起的名字就是它们的
/// 自述，比去猜接口更像人话。判不出的一律进最后一个「其他」，绝不丢源。
public enum SourceShelf: String, CaseIterable, Sendable {
    case magnet
    case danmaku
    case kids
    case shortDrama
    case anime
    case music
    case sport
    case live
    case cloud
    case bluRay
    case apps
    case other

    public var title: String {
        switch self {
        case .magnet: return L10n.text("Shelf Magnet")
        case .danmaku: return L10n.text("Shelf Danmaku")
        case .kids: return L10n.text("Shelf Kids")
        case .shortDrama: return L10n.text("Shelf Short Drama")
        case .anime: return L10n.text("Shelf Anime")
        case .music: return L10n.text("Shelf Music")
        case .sport: return L10n.text("Shelf Sports")
        case .live: return L10n.text("Shelf Live")
        case .cloud: return L10n.text("Shelf Cloud")
        case .bluRay: return L10n.text("Shelf Blu-ray")
        case .apps: return L10n.text("Shelf Apps")
        case .other: return L10n.text("Shelf Other")
        }
    }

    /// 排序权重：越靠前越具体。判断也按这个顺序走，第一条命中就定档 ——
    /// 「4K弹幕」是弹幕站而不是蓝光站，「🚀盘搜 4K」是网盘而不是蓝光。
    static let ordered: [SourceShelf] = [.magnet, .kids, .shortDrama, .anime, .music, .sport, .live,
                                         .danmaku, .cloud, .bluRay, .apps, .other]

    private static let patterns: [(SourceShelf, NSRegularExpression)] = {
        // 模式都是我们自己写的字面量；万一写错，`try?` 让那一条静默不匹配，
        // 而不是让一条正则把整个源列表拖崩。
        let raw: [(SourceShelf, String)] = [
            (.magnet, "磁力|磁链|磁熊|磁[\\s┃|]|\\bBT\\b|种子|极影|哔嘀|BT天堂"),
            (.kids, "儿歌|宝宝|贝贝|兔兔|儿童|动画片"),
            (.shortDrama, "短剧|短视|漫短|微短"),
            (.anime, "动漫|番剧|次元|漫剧|漫画"),
            (.music, "音乐|戏曲|听书|电台|KTV|舞曲|有声"),
            (.sport, "体育|看球|球通|飞球|WWE|八八|足球|篮球"),
            (.live, "直播"),
            (.danmaku, "弹幕"),
            (.cloud, "网盘|盘搜|盘他|盘她|四盘|夸克|阿里|UC盘|uc盘|115|天翼|云盘|免扫|聚合盘|盘4k|盘se|盘1"),
            // 不带裸 `4K`：这一整组名字里几乎都有 4K，用它会把 166 个源全收进一层，
            // 等于没分层。认的是「蓝光 / HDR / 纯净 / 无广」这些真在描述片源类型的话。
            (.bluRay, "蓝光|HDR|剧院|超清|杜比|纯净|无广"),
            (.apps, "APP|应用|片单|端内|配置|内置"),
        ]
        return raw.compactMap { shelf, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return (shelf, regex)
        }
    }()

    /// 一个源属于哪个书架。判不出就是 `.other`。
    public static func shelf(for site: Site) -> SourceShelf {
        let text = [site.name, site.raw["group"]?.string ?? ""].joined(separator: " ")
        let range = NSRange(text.startIndex..., in: text)
        for (shelf, pattern) in patterns where pattern.firstMatch(in: text, range: range) != nil {
            return shelf
        }
        return .other
    }

    /// 一个分组该不该分层、分成哪几层。
    ///
    /// - 组里源少于 `minimum`（默认 24）不分：十几张卡本来就看得完，多一层只是多一次点击。
    /// - 只有一层命中时也不分：分层要有两个以上的书架才有意义。
    /// - 少于 3 个源的书架并进「其他」：一个书架只有一张卡，比不加书架还乱。
    /// - 顺序按书架大小降序，「其他」永远垫底。
    public static func shelves(for sites: [Site], minimum: Int = 24) -> [SourceShelfGroup] {
        guard sites.count >= minimum else { return [] }
        var buckets: [SourceShelf: [Site]] = [:]
        for site in sites { buckets[shelf(for: site), default: []].append(site) }
        guard buckets.count > 1 else { return [] }
        // 小书架并入「其他」：保持分组不丢源，也避免三个组头各挂一张卡。
        for (shelf, members) in buckets where shelf != .other && members.count < 3 {
            buckets[.other, default: []].append(contentsOf: members)
            buckets[shelf] = nil
        }
        let groups: [SourceShelfGroup] = Self.ordered.compactMap { shelf -> SourceShelfGroup? in
            guard let members = buckets[shelf], !members.isEmpty else { return nil }
            return SourceShelfGroup(basis: .content(shelf), sites: members)
        }
        // 大的书架在前（先看占多数的那一类），「其他」永远垫底；
        // 同样大就按 `ordered` 的固定次序，免得两次进入页面顺序不一样。
        let rank = Dictionary(uniqueKeysWithValues: Self.ordered.enumerated().map { ($1, $0) })
        return groups.sorted { lhs, rhs in
            guard let left = lhs.shelf, let right = rhs.shelf else { return lhs.id < rhs.id }
            if left == .other { return false }
            if right == .other { return true }
            if lhs.sites.count != rhs.sites.count { return lhs.sites.count > rhs.sites.count }
            return (rank[left] ?? 0) < (rank[right] ?? 0)
        }
    }

    /// 按**实测连通状态**分书架。
    ///
    /// 测速之后读者的问题从「这是什么站」变成了「哪些还能用」，所以这一层不按名字、按档位：
    /// 能播 / 慢 / 没测过 / 测了不通。顺序就用 `SourceTier.rank`，`untested` 在 `dead` 前面 ——
    /// 没试过的还有机会，试过不通的才是真没法用。
    ///
    /// 只有一个档位时不分层（一条「能播 46」的书架没有信息量）；少于 `minimum` 也不分。
    public static func shelves(byConnectivity sites: [Site], minimum: Int = 8,
                               tier: (Site) -> SourceTier) -> [SourceShelfGroup] {
        guard sites.count >= minimum else { return [] }
        var buckets: [SourceTier: [Site]] = [:]
        for site in sites { buckets[tier(site), default: []].append(site) }
        guard buckets.count > 1 else { return [] }
        return SourceTier.allCases
            .sorted { $0.rank < $1.rank }
            .compactMap { tier in
                guard let members = buckets[tier], !members.isEmpty else { return nil }
                return SourceShelfGroup(basis: .connectivity(tier), sites: members)
            }
    }

    /// 按模式选出这一组该用哪种书架。
    ///
    /// `.auto` 的判据是「有没有测出能用的」：至少 3 个能播/偏慢，才值得把整组按连通重排 ——
    /// 只测出一个可播源就重排 168 张卡，是拿一个样本改整页的秩序。按连通分不出两层
    /// （比如全组都能播）时回落到内容书架，免得只剩一条没有信息量的组头。
    public static func shelves(for sites: [Site], mode: SourceShelfMode, counts: TierCounts,
                               tier: (Site) -> SourceTier) -> [SourceShelfGroup] {
        switch mode {
        case .content:
            return shelves(for: sites)
        case .connectivity:
            return shelves(byConnectivity: sites, tier: tier)
        case .auto:
            guard counts.usable >= 3 else { return shelves(for: sites) }
            let byTier = shelves(byConnectivity: sites, tier: tier)
            return byTier.isEmpty ? shelves(for: sites) : byTier
        }
    }
}

/// 组内书架的排列依据。
public enum SourceShelfMode: String, CaseIterable, Identifiable, Sendable {
    /// 有实测结论就按连通分，没有就按内容分 —— 默认，也是「自动分好」的那一档。
    case auto
    /// 永远按连通（即便还没测过：那就是一整层「没测过」，等于提醒去测）。
    case connectivity
    /// 永远按内容形态。
    case content

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return L10n.text("Shelves Auto")
        case .connectivity: return L10n.text("Shelves By Connection")
        case .content: return L10n.text("Shelves By Content")
        }
    }
}

/// 一层书架：按内容形态分的，或者按实测状态分的。
///
/// 单独一个结构而不是元组，是为了 `ForEach` 能直接用它 —— `id:` 要的是 key path，
/// 而 Swift 的 key path 指不到元组成员上。
public struct SourceShelfGroup: Identifiable, Sendable {
    public enum Basis: Equatable, Sendable {
        case content(SourceShelf)
        case connectivity(SourceTier)
    }

    public let basis: Basis
    public let sites: [Site]

    public init(basis: Basis, sites: [Site]) {
        self.basis = basis
        self.sites = sites
    }

    /// 折叠状态、展开状态都靠它做键：内容书架与状态书架的 id 不会撞（前缀不同）。
    public var id: String {
        switch basis {
        case .content(let shelf): return "content." + shelf.rawValue
        case .connectivity(let tier): return "tier." + tier.rawValue
        }
    }

    public var title: String {
        switch basis {
        case .content(let shelf): return shelf.title
        case .connectivity(let tier): return tier.title
        }
    }

    public var shelf: SourceShelf? { if case .content(let shelf) = basis { return shelf }; return nil }
    public var tier: SourceTier? { if case .connectivity(let tier) = basis { return tier }; return nil }
}
