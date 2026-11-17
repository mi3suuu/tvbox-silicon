import Foundation

public enum SourceLists {
    /// Sources the home row, the home picker, and the More count may use.
    public static func browsable(_ sites: [Site], jarURL: URL?, userHidden: (Site) -> Bool) -> [Site] {
        SourceStrategy.arrange(sites) { !$0.hidden && $0.canBrowse(jarURL: jarURL) && !userHidden($0) }
    }
}

public struct SourceGroup: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case pinned, builtIn, subscription(String)
        /// A group the viewer made up (`CustomSourceGroup`), listed by its id.
        case custom(String)
        /// The sources the viewer hid, last on the page.
        case hidden
        // [mi3s] 二开：case other —— 改派来源落不到任何订阅时仍需显示，否则「源存在却看不见」
        // 会被当成 bug（上游只有 pinned/builtIn/subscription/hidden 四种）
        /// Sources that reached the merged list but belong to no listed subscription: filed onto a
        /// subscription that is now off, or carried by a copy whose address changed. They are listed
        /// rather than dropped, because a source that exists and cannot be seen looks like a bug.
        case other
    }
    public var kind: Kind
    public var title: String
    public var sites: [Site]

    public init(kind: Kind, title: String, sites: [Site]) {
        self.kind = kind
        self.title = title
        self.sites = sites
    }
    public var id: String {
        switch kind {
        case .pinned: "pinned"
        case .builtIn: "builtIn"
        case .subscription(let address): address
        case .custom(let id): "group:" + id
        case .hidden: "hidden"
        case .other: "other"
        }
    }
}

public enum SourceGroups {
    /// `privacyHidden` marks a source the privacy vault keeps off the list *while locked*. Unlike a
    /// plain `userHidden` source — which waits in the "Hidden Sources" group so the viewer can unhide
    /// it — a privacy-hidden source must disappear entirely when locked, or the "Hidden Sources" group
    /// and its count would tell a locked-out viewer how much is in the vault. Unlock and it returns
    /// to its own group.
    public static func make(entries: [SubscriptionEntry], documents: [String: Subscription], builtIns: [Site], builtInOrigin: URL, mergedSites: [Site], pinOrder: [Site], userHidden: (Site) -> Bool, includeHidden: Bool, jarURL: URL?, privacyHidden: (Site) -> Bool = { _ in false }, deletedHidden: (Site) -> Bool = { _ in false }, reassign: (Site, String) -> String? = { _, _ in nil }, customGroups: [CustomSourceGroup] = []) -> [SourceGroup] {
        /// An entry is known by the address the viewer typed; its copy is known by where the address
        /// finally landed — a redirect, a mirror, an http-to-https hop. Grouping used to compare the
        /// two directly, so every subscription that redirected filed nothing: its sources silently
        /// disappeared and only the built-in ones were left. Map one to the other instead.
        var addressOfOrigin: [String: String] = [:]
        for entry in entries {
            guard let origin = documents[entry.address]?.origin.absoluteString, addressOfOrigin[origin] == nil else { continue }
            addressOfOrigin[origin] = entry.address
        }
        /// The entry address of the subscription a source came from: what the viewer typed, which a
        /// refresh never changes. An origin no entry claims keeps itself.
        func ownAddress(_ site: Site) -> String {
            let origin = site.origin(or: builtInOrigin).absoluteString
            return addressOfOrigin[origin] ?? origin
        }
        /// The address a source belongs under: the one the viewer moved it to, else its own.
        func home(_ site: Site) -> String {
            let own = ownAddress(site)
            guard let destination = reassign(site, own) else { return own }
            // 「未分组」是显式去路，不是「没有去路」：原样返回，不能被下面的回落吞掉，
            // 否则用户刚拖出去的源下一秒又回原订阅，看起来像拖拽没生效。
            if CustomSourceGroup.isUngrouped(destination) { return destination }
            // A move that names a group the viewer has since deleted files the source back where it
            // came from; letting it fall through would strand it in "Other Sources" for good.
            if CustomSourceGroup.id(inTarget: destination) != nil,
               !customGroups.contains(where: { $0.target == destination }) { return own }
            return destination
        }
        func isPinned(_ site: Site, fallback: URL) -> Bool {
            let origin = site.origin(or: fallback)
            return pinOrder.contains { $0.sourceKey == site.sourceKey && $0.origin(or: fallback) == origin }
        }
        func eligible(_ site: Site) -> Bool {
            !site.hidden && site.canBrowse(jarURL: jarURL) && !privacyHidden(site) && (includeHidden || !userHidden(site))
        }
        var groups: [SourceGroup] = []
        let pinnedSites = pinOrder.filter(eligible)
        if !pinnedSites.isEmpty { groups.append(SourceGroup(kind: .pinned, title: "Pinned Group", sites: pinnedSites)) }
        let builtInSites = builtIns.filter { eligible($0) && !isPinned($0, fallback: builtInOrigin) }
        if !builtInSites.isEmpty { groups.append(SourceGroup(kind: .builtIn, title: "Recommended", sites: builtInSites)) }
        // The viewer's own groups sit above the feeds: a sweep that says "these answer, those do not"
        // is only useful if the answer is the first thing on the page. A group with nothing in it is
        // still listed — it was just made, and it needs somewhere to be dropped onto.
        for custom in customGroups {
            let members = mergedSites.filter { !$0.isBuiltIn && !isPinned($0, fallback: builtInOrigin) && eligible($0) && home($0) == custom.target }
            groups.append(SourceGroup(kind: .custom(custom.id), title: custom.name,
                                      sites: SourceStrategy.arrange(members, where: { _ in true })))
        }
        // A source the viewer dragged onto another subscription files under that subscription instead of its own.
        for entry in entries where entry.enabled {
            guard let origin = documents[entry.address]?.origin else { continue }
            let own = mergedSites.filter { !$0.isBuiltIn && !isPinned($0, fallback: origin) && eligible($0) && home($0) == entry.address }
            let arranged = SourceStrategy.arrange(own, where: { _ in true })
            if !arranged.isEmpty { groups.append(SourceGroup(kind: .subscription(entry.address), title: entry.title, sites: arranged)) }
        }
        // Sources with no listed subscription of their own still show at the end rather than vanishing:
        // edited onto a subscription that is now off, or carried by a copy whose entry is gone.
        // 「未分组」= 两种源：(a) 用户显式拖出去的（move 指向 `ungrouped`）；
        // (b) 原本收在这里的「无主源」（所属订阅被关掉/地址变了）。
        // 两者对用户是同一件事——「不属于任何分组」——所以合成一组，标题就叫「未分组」。
        // 之前这一组叫 "Other Sources" 且只装 (b)，用户拖出去无处可去。
        let placed = Set(groups.flatMap(\.sites).map(\.id))
        let unplaced = mergedSites.filter { !$0.isBuiltIn && !placed.contains($0.id) && eligible($0) && !isPinned($0, fallback: builtInOrigin) }
        if !unplaced.isEmpty { groups.append(SourceGroup(kind: .other, title: "Ungrouped", sites: SourceStrategy.arrange(unplaced, where: { _ in true }))) }
        // Hidden sources leave their groups and wait in one group at the end, where they can be unhidden.
        // Privacy-hidden sources are not here: a locked vault must not reveal them, even as a count.
        if !includeHidden {
            // ⛔ `deletedHidden` 必须在这里单独排除，**不能靠把 `userHidden` 取反来实现**。
            //
            // `userHidden` 同时被两处消费，语义相反：
            //   · 上面 `eligible()` 用它**剔除**列表（`!userHidden`）；
            //   · 这里用它**收进**隐藏分区（`userHidden`）。
            // 所以「真删」不能表达成 `userHidden && !deleted` —— 那样 eligible 会算出
            // `!false == true`，被删的源反而**留在原分组里**（比出现在已隐藏更糟）。
            // 「不显示」与「不列进隐藏分区」是两个位，必须分开表达。
            let hidden = (builtIns + mergedSites.filter { !$0.isBuiltIn }).filter {
                !$0.hidden && $0.canBrowse(jarURL: jarURL) && userHidden($0)
                    && !privacyHidden($0) && !deletedHidden($0)
            }
            if !hidden.isEmpty { groups.append(SourceGroup(kind: .hidden, title: "Hidden Sources", sites: hidden)) }
        }
        return groups
    }

    /// The Watch Now source row. Pinned and built-in sources keep the order they were given.
    /// Every other source follows the sources page: one subscription after another, in that page's order.
    /// Hidden sources stay in their group on the sources page and do not join this row.
    public static func homeRow(pinned: [Site], builtIn: [Site], groups: [SourceGroup]) -> [Site] {
        let placed = Set((pinned + builtIn).map(\.id))
        let directory = groups.filter { $0.kind != .hidden }.flatMap(\.sites)
        return pinned + builtIn + directory.filter { !placed.contains($0.id) }
    }
}

public enum SubscriptionOrder {
    /// The displayed addresses after `address` is dropped onto the header of `target`. Dropping onto an
    /// earlier header inserts before it, onto a later header inserts after it. Indexes are from before the removal.
    public static func moving(_ address: String, onto target: String, in displayed: [String]) -> [String] {
        guard address != target, let from = displayed.firstIndex(of: address), let to = displayed.firstIndex(of: target) else { return displayed }
        var next = displayed
        next.remove(at: from)
        // After the removal a later target sits at `to - 1`, so inserting at `to` lands after it.
        next.insert(address, at: to)
        return next
    }

    public static func applying(displayed: [String], to subscriptions: [SubscriptionEntry]) -> [SubscriptionEntry] {
        let shown = Set(displayed)
        var next = displayed.makeIterator()
        return subscriptions.map { entry in
            guard shown.contains(entry.address), let address = next.next(), let replacement = subscriptions.first(where: { $0.address == address }) else { return entry }
            return replacement
        }
    }
}
