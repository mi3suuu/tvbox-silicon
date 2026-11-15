import Foundation
import Testing
@testable import TVCore

/// 源列表的显示偏好要跨重启活着：书架依据、只看能播、按连通排序、书架折叠/展开。
@Suite struct SourceShelfStateTests {

    private func scratch() -> (SourceShelfState, UserDefaults) {
        let name = "SourceShelfStateTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (SourceShelfState(defaults: defaults), defaults)
    }

    @Test func defaultsDoNotRearrangeAnything() {
        let (state, _) = scratch()
        #expect(state.mode == .auto)
        #expect(state.onlyPlayable == false)
        // 默认开，但没读数时四档都是「未测」，排序是空操作 —— 所以它不会改变第一次打开的顺序。
        #expect(state.sortByConnection == true)
        #expect(state.collapsedShelves.isEmpty)
        #expect(state.expandedShelves.isEmpty)
    }

    /// 每个偏好都单独读回来：换一个 `SourceShelfState` 实例（= 重启 App）仍是那个选择。
    @Test func everyChoiceSurvivesANewInstance() {
        let (state, defaults) = scratch()
        state.save(.content)
        state.save(onlyPlayable: true)
        state.save(sortByConnection: false)
        state.save(collapsedShelves: ["00|tier.dead", "00|content.bluRay"])
        state.save(expandedShelves: ["00|tier.playable"])

        let reopened = SourceShelfState(defaults: defaults)
        #expect(reopened.mode == .content)
        #expect(reopened.onlyPlayable == true)
        #expect(reopened.sortByConnection == false)
        #expect(reopened.collapsedShelves == ["00|tier.dead", "00|content.bluRay"])
        #expect(reopened.expandedShelves == ["00|tier.playable"])
    }

    /// 存一个不认识的模式（旧版本写的）时回落到默认，而不是崩。
    @Test func anUnknownStoredModeFallsBackToAuto() {
        let (_, defaults) = scratch()
        defaults.set("by-vibes", forKey: "sourceShelfMode.v1")
        #expect(SourceShelfState(defaults: defaults).mode == .auto)
    }

    @Test func clearResetsEverything() {
        let (state, defaults) = scratch()
        state.save(.connectivity)
        state.save(onlyPlayable: true)
        state.clear()
        let reopened = SourceShelfState(defaults: defaults)
        #expect(reopened.mode == .auto)
        #expect(reopened.onlyPlayable == false)
    }
}
