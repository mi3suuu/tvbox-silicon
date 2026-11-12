//
//  Store+SearchScope.swift
//  映匣 / Mi3s
//
//  「分组和订阅要支持重命名；分组和源要支持管理是否参与搜索」——
//  这一层放这些动作的**唯一写法**，UI 只调它们。
//
//  两条设计约束（与项目里反复出现的那类 bug 直接相关）
//  ------------------------------------------------
//  ① **重命名不改身份。**
//     分组与订阅的 id 分别是 `CustomSourceGroup.id` 与 `SubscriptionEntry.address`，
//     名字只是显示。改名**绝不能**顺手改 id / address —— 那会让「源归在哪一组」的
//     改派记录、订阅的解析副本、看过的历史全部对不上，表现是「改个名，源全跑回别的组」。
//  ② **搜索开关与隐藏是两件事。**
//     `hiddenSources` 让源看不见；`searchScope` 让它看得见但不搜。混用会二选一地丢功能：
//     把「不参与搜索」写成隐藏，用户再也找不到那条源；把隐藏写成不参与搜索，
//     用户以为只是不搜，结果列表也空了。两者在这里各调各的。
//

import Foundation
import TVCore

extension Store {

    // MARK: - 重命名

    /// 给订阅改名。
    ///
    /// 只写 `entry.name` —— 地址是它的身份，动它就等于换了一个订阅（解析副本、改派记录、
    /// 历史都会失联）。空名字是合法的，回落到按地址推导的标题（`SubscriptionEntry.title`）。
    func renameSubscription(_ address: String, to name: String) {
        guard let index = subscriptions.firstIndex(where: { $0.address == address }) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard subscriptions[index].name != clean else { return }
        subscriptions[index].name = clean
        saveSubscriptionList()
        // 名字参与分组标题与源列表戳，改完要让那两张缓存重建。
        rebuildSubscription()
    }

    /// 一个订阅当前显示的名字（改名框的初始值）。
    func subscriptionTitle(_ address: String) -> String {
        subscriptions.first { $0.address == address }?.title ?? address
    }

    /// 给用户自建分组改名。分组 id 不动（理由见文件头 ①）。
    func renameSourceGroup(_ id: String, to name: String) {
        sourceGroupBook.rename(id, to: name)
    }

    /// 删除用户自建分组。**组内源一个都不丢** —— 它们的 `SourceReassignment` 指向
    /// `group:<id>`，组没了就指不到任何东西，`SourceGroups.make` 自然把它们放回
    /// 各自的订阅源下（这正是用户选的 C 语义）。
    ///
    /// ⛔ 不要「顺手把组内源一起删掉」：那会把「整理」变成「销毁」，
    /// 而用户对这条路径的原话是「未分组删掉才是真删」—— 反过来说，
    /// 从分组里删只应该是「退出这个分组」。
    func deleteSourceGroup(_ id: String) {
        sourceGroupBook.remove(id)
    }

    /// 给单个子源改名（写 `SourceOverrides`，不动订阅文件，刷新后仍在）。
    ///
    /// ⛔ `origin` 必须由调用方给，不能读 `subscription.origin`。
    /// 源页把**每个订阅各自**的 `config` 传进 `siteRow`，多订阅清单里两者不同；
    /// 用 `subscription.origin` 会把改名写到「当前选中的那个订阅」名下，
    /// 于是改了 A 订阅的源、B 订阅里同名源跟着变，而 A 自己没变 ——
    /// 正是本项目反复出现的「一套状态两套键」那类缺陷。
    func renameSite(_ site: Site, origin: URL, to name: String) {
        sourceOverrides.rename(site, origin: origin, to: name)
        rebuildSubscription()
    }

    /// 一个子源当前显示的名字（改名框的初始值 —— 要带上已有覆盖，否则每次打开都是原始名）。
    func siteTitle(_ site: Site, origin: URL) -> String {
        resolvedSite(site, origin: origin).name
    }

    /// 删除单个子源 = 真删（用户 2026-11-11 定：从「未分组」删掉就是真删掉）。
    ///
    /// 实现是 `hiddenSources` 而不是从 `subscription.sites` 里移除，理由有两条：
    ///   ① **订阅是只读快照。** `sites` 来自订阅文件解析，本地移除会在下次
    ///      `rebuildSubscription()` / 刷新订阅时整批复活 —— 那是假删除。
    ///      `hiddenSources` 按 `origin|sourceKey` 记账，刷新后照样挡得住。
    ///   ② 与既有的「隐藏」共用同一份记账。语义上「删除」= 「隐藏」+ 「不在任何
    ///      「已隐藏」入口里露出」；本项目已有隐藏源的恢复页面，真删就不该出现在那儿。
    ///
    /// ⛔ 所以这里**额外写一条真删标记**（`deletedSources`），让「已隐藏」列表
    /// 把它排除掉 —— 否则用户删掉的源会以「已隐藏」的形式又冒出来一次。
    func deleteSite(_ site: Site, origin: URL) {
        // 真删标记要在隐藏之前写：先隐藏会让列表立刻重算一次，那一瞬间它还会以
        // 「已隐藏」出现一帧。
        deletedSources.insert(site, origin: origin)
        hiddenSources.insert(site, origin: origin)
        // ⛔ 必须同时清掉**不受 `deletedSources` 管辖**的那两处记录。
        //
        // 删源原本只写记账，而「继续观看」与「收藏」根本不读它（只有源列表、搜索、
        // 网页端读）。后果是用户删掉一条源之后：
        //   · 首页「继续观看」留一张卡片，点开弹 `reportMissingFavoriteSource`
        //     「这个源已不在当前订阅里」；
        //   · 收藏页同样一张死卡片，点一下报错。
        // 两者都没有「批量清理」的入口，用户只能一条条手删 —— 实际上删不掉，
        // 因为点进去就是报错页。「彻底删除」在这个口径下等于没删干净。
        //
        // 用**源身份**（origin + sourceKey）匹配，与 `EpisodeSkipSettings.scope`
        // 同一对标识；跨环境清理是刻意的（同一条源在各环境留的是同一批死记录）。
        let siteOrigin = site.origin(or: origin)
        let removedFavorites = favorites.removeAll(fromSource: site.sourceKey, origin: siteOrigin)
        let removedHistory = playbackHistory.removeAll(fromSource: site.sourceKey, origin: siteOrigin)
        rebuildSubscription()
        // 只在真的清掉了东西时打扰用户，否则「删除」这类操作弹提示很吵。
        let cleared = removedFavorites + removedHistory
        if cleared > 0 {
            notice = L10n.text("Removed this source, along with %lld saved shows from it.", cleared)
        }
    }

    /// ⛔ 不提供 `undeleteSite`。
    ///
    /// 曾经加过一个「撤销删除」，但它没有任何 UI 入口 —— 留着就是**假承诺**：
    /// 方法在、文档说可恢复，用户却找不到入口。用户对这条路径的原话是「真删掉」，
    /// 那就不该在旁边放一个只有源码里才存在的后门。
    ///
    /// 真要恢复有正规路径：删掉整个订阅再重新加入（`removeSubscriptions` 会顺手
    /// `deletedSources.forget(origin:)` 清掉这批记账，源自然全部回来）。

    // MARK: - 是否参与搜索

    /// 这条源参不参与搜索（三层合成的最终答案，UI 用它画勾）。
    ///
    /// 与 `SearchModel` 侧同一判据：源本身的开关 + 所在分组 + 所属订阅，任一关即不参与。
    /// 这里另算一份而不是复用 `searchScopeIndex()`，是因为 UI 一次只问一条，
    /// 建两张表不划算；`searchScope.permits` 内部全是集合查找，单条也是 O(1)。
    func participatesInSearch(_ site: Site) -> Bool {
        guard let config = subscription else { return true }
        let key = "\(site.origin(or: config.origin).absoluteString)|\(site.sourceKey)"
        let groupID = sourceGroups(includeHidden: true).first { group in
            group.sites.contains { "\($0.origin(or: config.origin).absoluteString)|\($0.sourceKey)" == key }
        }?.id
        let address = environmentSubscriptions.first { entry in
            guard let document = documents[entry.address] else { return false }
            return document.sites.contains { "\($0.origin(or: document.origin).absoluteString)|\($0.sourceKey)" == key }
        }?.address
        return searchScope.permits(site, origin: config.origin, groupID: groupID, subscriptionAddress: address)
    }

    /// 直接开关一条源的搜索参与度。
    func setParticipatesInSearch(_ site: Site, _ participates: Bool) {
        guard let config = subscription else { return }
        searchScope.setSourceExcluded(site, origin: config.origin, excluded: !participates)
        rebuildSubscription()
    }

    /// 一批源一起开关（选择模式的批量动作）。
    func setParticipatesInSearch(_ sites: [Site], _ participates: Bool) {
        guard let config = subscription, !sites.isEmpty else { return }
        searchScope.setSourcesExcluded(sites, origin: config.origin, excluded: !participates)
        rebuildSubscription()
    }

    /// 整组开关。`SourceGroup.id` 对系统组是 `builtIn` / `pinned` 这类固定串，
    /// 对自建组是 `group:<id>` —— 两者都能存进同一个集合，不必分两种键。
    func setGroupParticipatesInSearch(_ groupID: String, _ participates: Bool) {
        searchScope.setGroupExcluded(groupID, excluded: !participates)
    }

    func groupParticipatesInSearch(_ groupID: String) -> Bool {
        !searchScope.isGroupExcluded(groupID)
    }

    /// 整个订阅开关。地址是身份，与重命名无关（见文件头 ①）。
    func setSubscriptionParticipatesInSearch(_ address: String, _ participates: Bool) {
        searchScope.setSubscriptionExcluded(address, excluded: !participates)
    }

    func subscriptionParticipatesInSearch(_ address: String) -> Bool {
        !searchScope.isSubscriptionExcluded(address)
    }

    /// 有任何一个搜索开关关着吗？搜索页用它决定要不要提示「当前只搜了一部分源」。
    var searchScopeIsNarrowed: Bool {
        let scope = searchScope
        return !(scope.savedSourceKeys.isEmpty && scope.savedGroupKeys.isEmpty && scope.savedSubscriptionKeys.isEmpty)
    }

    /// 一键恢复：所有源 / 分组 / 订阅都重新参与搜索。
    func resetSearchScope() {
        searchScope.adoptSources([])
        searchScope.adoptGroups([])
        searchScope.adoptSubscriptions([])
        rebuildSubscription()
    }
}
