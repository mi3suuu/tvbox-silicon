import Foundation

/// 选哪条线路 —— **全仓唯一的优先级出口**。
///
/// ## 它解决什么
///
/// 同一个问题「这部剧该用哪条线」在三个地方各写过一遍，而三处的规则并不一致：
///
/// | 位置 | 原来的取值链 |
/// |---|---|
/// | 播放页 `loadDetail` | `watchedFlag ?? CloudDrive.preferredFlag(flags)` |
/// | 选集面板 `init` | `resumeContext?.episodeFlag`（**没有** `preferredFlag` 兜底） |
///
/// 于是同一部剧，播放页选中「能播的那条线」（跳过没登录的网盘、跳过要扫码的源），
/// 而选集面板的 chip 却停在 `flags.first` —— 可能是条根本播不了的线。
/// 用户点开面板看到的是另一条，点了播放又是另一条，两条路径互相打架。
///
/// ## 优先级（用户选择优先）
///
/// ```
/// ① 用户这次亲自选的（面板里点过的、播放页里点过的）
/// ② 上次看这部剧用的那条（历史记录 episodeFlag）
/// ③ 第一条「现在就能播」的（跳过要扫码 / 没登录的网盘）
/// ④ 第一条
/// ```
///
/// ① 必须在 ② 之上：用户刚点过 A 线，不能因为历史里记着 B 线就把选中态弹回 B。
/// 这就是"默认以用户选择的为先"。
///
/// ⚠️ ① 是**会话内**的临时选择（`Store.episodePickerLine` 等），不是持久偏好；
/// 持久偏好在 `SourceRouting` / 历史记录里，各自有各自的语义，别混进来。
public enum LinePreference {

    /// 用户这次亲自选的那一条，若它仍在这部剧的线路里。
    ///
    /// - Parameter picked: 用户刚点过的 flag。空串是合法值（单线源的线名叫空）。
    /// - Returns: 命中则原样返回；不在 `flags` 里（换剧/源换了线名）返回 nil。
    public static func sanitized(_ picked: String?, in flags: [String]) -> String? {
        guard let picked, flags.contains(picked) else { return nil }
        return picked
    }

    /// 这次要探测哪些线路。
    ///
    /// 三条规则，每条都对应一个真实场景：
    ///
    ///   · `subset == nil` → 全部可见线路（「重新测速」整轮重测）。
    ///   · `subset` 里的名字若已不在 `flags`（换剧、源改了线名），**剔除**
    ///     —— 否则会去测一条不存在的线，拿回一个假读数。
    ///   · `subset` 去重、且**保持 `flags` 的原始顺序**（不是调用方传入的顺序）。
    ///     顺序稳定才能让「逐条亮起来」的过程看起来是从上往下走的。
    ///
    /// - Parameters:
    ///   - flags: 这部剧的全部线路，顺序即源给的原始顺序。
    ///   - subset: 只测这些；`nil` 表示全部。
    /// - Returns: 去重、按 `flags` 排序、已剔除失效名字的线路列表。
    public static func linesToProbe(_ flags: [String], subset: [String]?) -> [String] {
        guard let subset else { return flags }
        let wanted = Set(subset)
        // 以 `flags` 为准做过滤：既去了重，也保证了顺序，还顺手剔除了已失效的名字。
        return flags.filter { wanted.contains($0) }
    }

    /// 按优先级挑一条。
    ///
    /// - Parameters:
    ///   - flags: 这部剧的全部线路（顺序即源的原始顺序，最后一级兜底要靠它）。
    ///   - picked: 用户这次亲自选的。传 nil 表示「还没选过」。
    ///   - watched: 上次看这部剧用的那条（历史记录）。
    ///   - playableNow: 判断「现在能播」的谓词。由调用方注入 —— 它要读网盘账号，
    ///     属于 App 层的事，TVCore 不该知道。传 nil 表示不做这一级筛选。
    /// - Returns: 选中的 flag；`flags` 为空时返回 nil。
    public static func choose(
        flags: [String],
        picked: String? = nil,
        watched: String? = nil,
        playableNow: ((String) -> Bool)? = nil,
        quality: ((String) -> Int?)? = nil,
        /// 这条线**明确不该当默认**：回的是网页（需要解析）或实测不可达。
        /// 与 `playableNow` 分开，是因为「没测过」不该被当成「不能播」—— 那条要尊重历史。
        unplayableNow: ((String) -> Bool)? = nil
    ) -> String? {
        guard !flags.isEmpty else { return nil }

        // ① 用户这次亲自选的 —— 最高优先级。
        if let picked = sanitized(picked, in: flags) { return picked }

        // 能播的那几条；一条都不认时退回全部（与第四级兜底同理）。
        let playable = playableNow.map { predicate in flags.filter(predicate) } ?? flags
        let pool = playable.isEmpty ? flags : playable
        // 再把「明确不该当默认」的剔掉（网页型 / 实测不可达）。
        //
        // ⛔ 只在**还剩下别的东西**时才剔：如果整组线路都是网页，剔完就没有候选了，
        //    那时保留原组、照旧尊重历史 —— 那不是「选错」，是这部片只有这样的地址。
        let filtered = pool.filter { !(unplayableNow?($0) ?? false) }
        let usable = filtered.isEmpty ? pool : filtered

        // ② 上次看这部剧用的那条 —— 但「实测明显更好的线」可以把历史顶掉。
        //
        // ⛔ 这条是 2026-11-17 加的。此前历史无条件胜出，于是出现：
        //    用户上次在一部剧里点到了 720p 的线，之后每次进来都从这条 720p 起播，
        //    而同一集里明明有一条 1080p。用户的原话是「4K 源出来的不是 4K」——
        //    机制与看剧AI 的 official→ordinary 静默降级同型：默认值由**旧记录**决定，
        //    不由**当下的证据**决定。
        //
        // 判据用长边（宽高取大），且要「明显」更好才改判（≥15%），避免 818 与 1080
        // 这种同一档内的差异把历史反复打翻。没有实测读数时一律尊重历史。
        // ⛔ 历史必须落在「现在能播」的那几条里，且不能是一条**明确不可播**的线。
        //
        //    2026-11-17 审查发现：这里用的是 `flags`（全部线路），于是
        //      · 历史是一条网页线（`quality` 为 nil，因为它不是媒体）→ 永远返回它；
        //      · 历史是网盘线且现在要登录（不在 `usable` 里）→ 仍然返回它。
        //    两种都让「默认线路」重新变成由旧记录决定、而不是由当下证据决定 ——
        //    与看剧AI 的 official→ordinary 静默降级是同一个病。
        //    现在让位给「能播且有实测」的那条；一条读数都没有时才继续尊重历史。
        if let watched = sanitized(watched, in: flags), usable.contains(watched) {
            guard let quality else { return watched }
            let best = bestMeasured(in: usable, quality: quality)
            guard let best, best != watched,
                  let bestEdge = quality(best), let watchedEdge = quality(watched),
                  Double(bestEdge) >= Double(watchedEdge) * 1.15
            else { return watched }
            return best
        }

        // ③ 有实测画质时取最好的一条（并列时保持源给的顺序）。
        if let quality, let best = bestMeasured(in: usable, quality: quality) { return best }

        // ④ 第一条现在就能播的。
        if let first = usable.first { return first }

        // ⑤ 第一条。
        return flags.first
    }

    /// 这一组里实测画质最高的那条；一条读数都没有时返回 nil（不猜）。
    ///
    /// 平局保持 `flags` 的原始顺序 —— `max(by:)` 在两值相等时返回先出现的那条，
    /// 这正是「源把 1080 放前面就先用它」的意思。
    static func bestMeasured(in lines: [String], quality: (String) -> Int?) -> String? {
        let measured = lines.compactMap { flag in quality(flag).map { (flag, $0) } }
        guard let top = measured.map(\.1).max() else { return nil }
        return measured.first { $0.1 == top }?.0
    }
}
