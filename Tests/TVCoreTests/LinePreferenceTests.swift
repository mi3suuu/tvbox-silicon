import Foundation
import Testing
@testable import TVCore

/// 锁住「默认以用户选择的为先」这条产品约束的优先级链。
///
/// 这个问题（「这部剧该用哪条线」）原先在播放页与选集面板各写过一遍，规则还不一致：
/// 播放页有「能播的线」兜底，面板没有 —— 于是面板 chip 可能停在一条根本播不了的线上，
/// 与真正在播的那条不是同一条。
///
/// `LinePreference` 把优先级收成一处，这些测试把四级顺序钉住。
@Suite struct LinePreferenceTests {

    private let flags = ["线路1", "线路2", "线路3"]

    // MARK: - 一级：用户这次亲自选的

    /// 用户刚点过的那条压过历史记录。
    ///
    /// 这是「默认以用户选择的为先」的字面含义：用户点 A、历史记着 B，不能因为 B 就弹回 B。
    @Test func theLineTheViewerJustPickedWinsOverHistory() {
        #expect(LinePreference.choose(flags: flags, picked: "线路3", watched: "线路1") == "线路3")
    }

    /// 用户的选择也压过「能播的线」这一级 —— 即使用户选的这条恰好排位靠后。
    @Test func theLineTheViewerJustPickedWinsOverThePlayableFallback() {
        let chosen = LinePreference.choose(
            flags: flags,
            picked: "线路3",
            watched: nil,
            playableNow: { $0 == "线路1" }
        )
        #expect(chosen == "线路3")
    }

    /// 用户选的那条若已不在线路表里（换剧、源改了线名），当作没选过，落到下一级。
    ///
    /// 不这么做的后果：面板会卡在一个不存在的 flag 上，网格空白、chip 无高亮。
    @Test func aPickThatNoLongerExistsFallsThrough() {
        #expect(LinePreference.choose(flags: flags, picked: "已下架的线", watched: "线路2") == "线路2")
        #expect(LinePreference.choose(flags: flags, picked: nil, watched: "线路2") == "线路2")
    }

    // MARK: - 二级：上次看的那条

    /// 没有用户选择、没有任何「现在不能播」的证据时，历史照用。
    @Test func historyIsUsedWhenNothingWasJustPicked() {
        #expect(LinePreference.choose(flags: flags, watched: "线路2") == "线路2")
    }

    /// ⛔ 历史那条**现在播不了**（要扫码/没登录的网盘）时必须让位。
    ///
    /// 原断言是反的：`playableNow: { $0 == "线路1" }` 却期望返回「线路2」——
    /// 那意味着用户会先撞一次登录/60 秒超时，而同一集里就有一条能直接播的线。
    /// 2026-11-17 审查把这条改成「历史落在能播的那几条里才作数」。
    @Test func historyYieldsToAPlayableLine() {
        #expect(LinePreference.choose(flags: flags, watched: "线路2", playableNow: { $0 == "线路1" }) == "线路1")
    }

    // MARK: - 三级：现在就能播的第一条

    /// 没有用户选择、也没有历史时，跳过现在播不了的线。
    ///
    /// 「播不了」= 要扫码的网盘、没登录的网盘 —— 谓词由调用方注入，
    /// 因为那要读账号状态，属于 App 层。
    @Test func theFirstPlayableLineIsPreferredOverTheFirstLine() {
        let chosen = LinePreference.choose(
            flags: flags,
            playableNow: { $0 != "线路1" }   // 线路1 需要登录
        )
        #expect(chosen == "线路2")
    }

    // MARK: - 四级：第一条

    /// 什么信息都没有时退到第一条 —— 不能返回 nil（面板必须有一条选中）。
    @Test func everythingUnknownFallsBackToTheFirstLine() {
        #expect(LinePreference.choose(flags: flags) == "线路1")
        // 谓词一个都不认（全部都播不了）时，仍然要有兜底，否则面板无选中。
        #expect(LinePreference.choose(flags: flags, playableNow: { _ in false }) == "线路1")
    }

    /// 没有线路时返回 nil，由调用方决定怎么画空状态。
    @Test func noLinesMeansNoChoice() {
        #expect(LinePreference.choose(flags: []) == nil)
    }

    // MARK: - 空 flag 是合法值

    /// 单线源的线名是空串，不能被「假值」逻辑吞掉。
    ///
    /// ⛔ 这里很容易写错成 `picked.isEmpty ? nil : picked` —— 于是单线源的用户选择
    /// 永远不生效，面板每次都弹回第一条。
    @Test func anEmptyFlagIsARealLineName() {
        #expect(LinePreference.choose(flags: ["", "线路2"], picked: "") == "")
        #expect(LinePreference.sanitized("", in: ["", "线路2"]) == "")
        // 但空串不在表里时仍然要被拒。
        #expect(LinePreference.sanitized("", in: ["线路1"]) == nil)
    }

    // MARK: - 「用户选的」与「系统算出来的」不是一回事

    /// 自动解析的结果不能冒充用户选择。
    ///
    /// 面板 `onAppear` 会用本类型的第三级（能播的线）兜底改 `activeLine`，
    /// 而这个变化会被 `onChange` 看到。若不加区分地写回 store，
    /// 下一轮它的优先级就变成第一级「用户选过」—— 用户没选过却被钉死。
    ///
    /// 这条测试守住的是**类型层面**的区分：`picked`（用户亲手点的）与
    /// `playableNow` 选出来的线在语义上不同，实现里必须分开记账。
    /// 这里用行为断言表达该语义：同一份输入下，「显式传 picked」与
    /// 「靠 playableNow 兜底」得到同一条线，但前者必须能被再次识别为「用户选的」，
    /// 后者不能 —— 具体标记由调用方维护（`autoResolvedLine`）。
    @Test func aResolvedFallbackIsNotTheSameAsAPick() {
        let flags = ["需要登录的线", "能播的线"]
        let playable: (String) -> Bool = { $0 == "能播的线" }

        // 没有用户选择 → 第三级兜底
        let fallback = LinePreference.choose(flags: flags, picked: nil, playableNow: playable)
        #expect(fallback == "能播的线")

        // 同一个结果，但这次是**用户亲手选的**，语义不同
        let picked = LinePreference.choose(flags: flags, picked: "能播的线", playableNow: playable)
        #expect(picked == "能播的线")

        // 区别体现在这里：拿 picked 去校验，它被认下；拿 nil 去校验，得不到任何结论。
        #expect(LinePreference.sanitized(picked, in: flags) == "能播的线")
        #expect(LinePreference.sanitized(nil, in: flags) == nil)
    }

    // MARK: - 这次要测哪几条

    /// `nil` = 全部（「重新测速」整轮）。
    @Test func aNilSubsetMeansEveryLine() {
        #expect(LinePreference.linesToProbe(flags, subset: nil) == flags)
    }

    /// 只测点中的那一条 —— 但结果按 `flags` 的原始顺序给出，不是传入顺序。
    @Test func aSubsetIsReturnedInTheSourcesOrder() {
        let picked = LinePreference.linesToProbe(flags, subset: ["线路3"])
        #expect(picked == ["线路3"])

        // 传入顺序打乱、且带重复，输出仍按 flags 顺序去重。
        let messy = LinePreference.linesToProbe(flags, subset: ["线路3", "线路1", "线路3"])
        #expect(messy == ["线路1", "线路3"])
    }

    /// 名字已失效（换剧 / 源改了线名）的要剔除，不能去测一条不存在的线。
    ///
    /// 不剔除的后果：拿回一个假读数写进缓存，界面显示一条根本播不了的线的数字。
    @Test func aStaleNameIsDropped() {
        #expect(LinePreference.linesToProbe(flags, subset: ["已下架的线", "线路2"]) == ["线路2"])
        #expect(LinePreference.linesToProbe(flags, subset: ["已下架的线"]) == [])
    }

    /// 空 subset 表示「一条都不测」，不是「测全部」。
    ///
    /// 这两种语义很容易被 `isEmpty ? nil : subset` 之类写法混掉，
    /// 混掉的后果是：调用方以为只测 0 条，实际把 4~9 条全打出去了。
    @Test func anEmptySubsetProbesNothing() {
        #expect(LinePreference.linesToProbe(flags, subset: []) == [])
    }

    /// 单线源的空 flag 在 subset 里也要能正常匹配。
    @Test func anEmptyFlagStillMatchesAsASubset() {
        let single = ["", "线路2"]
        #expect(LinePreference.linesToProbe(single, subset: [""]) == [""])
    }

    // MARK: - sanitized 的边界

    @Test func sanitizedRejectsWhatIsNotInTheList() {
        #expect(LinePreference.sanitized("线路2", in: flags) == "线路2")
        #expect(LinePreference.sanitized("线路9", in: flags) == nil)
        #expect(LinePreference.sanitized(nil, in: flags) == nil)
    }

    // MARK: - 实测画质（2026-11-17）

    /// 有实测读数时，默认线路取长边最大的那条 —— 而不是「第一条像直链的」。
    ///
    /// 真实形状：`Video.init` 把带 `.m3u8` 的分组排前面，源给的顺序里 720p 常排在 1080p 前。
    /// 于是同一部剧、同一集，用户每次都被送上 720p —— 他说的「4K 源出来的不是 4K」
    /// 与看剧AI 的 official→ordinary 静默降级是同一个病：默认值由形状决定，不由证据决定。
    @Test func measuredQualityBeatsTheFirstLine() {
        let edges = ["线路1": 1280, "线路2": 1920]
        let chosen = LinePreference.choose(flags: flags, quality: { edges[$0] })
        #expect(chosen == "线路2")
    }

    /// 一条读数都没有时不能猜：退回源给的第一条（老行为）。
    @Test func noReadingsKeepTheFirstLine() {
        #expect(LinePreference.choose(flags: flags, quality: { _ in nil }) == "线路1")
    }

    /// 历史线路明显更差（≥15%）时才被实测更好的线顶掉。
    @Test func historyYieldsToAClearlyBetterLine() {
        let edges = ["线路1": 1280, "线路2": 1920]
        let chosen = LinePreference.choose(flags: flags, watched: "线路1", quality: { edges[$0] })
        #expect(chosen == "线路2")
    }

    /// 同一档内的差异（1080 高度 vs 1920 长边）不足以推翻历史 —— 否则用户每次进来线路都在跳。
    @Test func historySurvivesASmallQualityDifference() {
        let edges = ["线路1": 1920, "线路2": 2160]
        let chosen = LinePreference.choose(flags: flags, watched: "线路1", quality: { edges[$0] })
        #expect(chosen == "线路1")
    }

    /// 画质只在「现在能播」的那几条里挑：要登录的网盘线再高也不能被选中。
    @Test func qualityIsOnlyConsideredAmongPlayableLines() {
        let edges = ["线路1": 1280, "线路2": 2160]
        let chosen = LinePreference.choose(flags: flags, playableNow: { $0 != "线路2" }, quality: { edges[$0] })
        #expect(chosen == "线路1")
    }

    /// 用户亲手选的那条不被画质推翻 —— 他选 720p 就是想要 720p（省流量/更稳）。
    @Test func anExplicitPickOutranksQuality() {
        let edges = ["线路1": 1920, "线路3": 720]
        let chosen = LinePreference.choose(flags: flags, picked: "线路3", quality: { edges[$0] })
        #expect(chosen == "线路3")
    }

    // MARK: - 历史必须让位给「当下不可播」的线（2026-11-17 审查）

    /// 历史停在一条**网页线**（回 HTML，需要解析）上：不能因为「上次是它」就继续默认它。
    ///
    /// 真实形状：内置「可播」组里 19 个源各有一条云播/平台页线路，用户点过一次之后
    /// `watched` 就记成了那条；此后每次进来先撞 15 秒嗅探，而同一集里有一条正常 1080p。
    @Test func historyYieldsWhenItIsAPageOnlyLine() {
        let edges = ["线路2": 1920]
        let chosen = LinePreference.choose(
            flags: flags,
            watched: "线路1",
            quality: { edges[$0] },
            unplayableNow: { $0 == "线路1" }
        )
        #expect(chosen == "线路2")
    }


    /// 整组都是网页线时保留历史：那不是选错，是这部片只有这样的地址。
    @Test func historySurvivesWhenEveryLineIsUnplayable() {
        let chosen = LinePreference.choose(
            flags: flags,
            watched: "线路2",
            unplayableNow: { _ in true }
        )
        #expect(chosen == "线路2")
    }

    /// 「没测过」不等于「不能播」：冷启动没有任何读数时仍尊重历史。
    @Test func neverMeasuredHistoryIsStillRespected() {
        #expect(LinePreference.choose(flags: flags, watched: "线路2",
                                      quality: { _ in nil },
                                      unplayableNow: { _ in false }) == "线路2")
    }
}
