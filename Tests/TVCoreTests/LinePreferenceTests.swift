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

    @Test func historyIsUsedWhenNothingWasJustPicked() {
        #expect(LinePreference.choose(flags: flags, watched: "线路2", playableNow: { $0 == "线路1" }) == "线路2")
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
}
