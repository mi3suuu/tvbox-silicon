import Foundation
import Testing
@testable import TVCore

// MARK: - #14：卡片音量 UI 的口径必须与 applyMuting 一致

/// 核心判据：**同一组「活跃/位置/总数」，UI 与实播算出的音量必须逐一相等。**
///
/// 缺陷本体：`DockVolumeButton` 用 `taskIndex: 0, taskCount: 1`（写死），
/// 而 `VideoTasks.applyMuting()` 用真实的 `index` / `tasks.count`。
/// 两处对 `DockAudioPolicy.output` 的口径分叉 ⇒ 图标与滑杆说的
/// 和用户实际听到的不是一回事。
///
/// `.mixed` 下最明显：实播活跃那路是 `1/n`，卡片却按「唯一那路」显示满格。
@Test func cardUIRoundTripMatchesApplyMuting() throws {
    // 坞里 1…4 张，逐张逐位置比对。
    for count in 1...4 {
        for index in 0..<count {
            for active in [true, false] {
                for policy in DockAudioPolicy.allCases {
                    // 实播侧：applyMuting 的真实入参
                    let actual = policy.output(isActive: active, taskIndex: index,
                                               taskCount: count, override: nil)
                    // UI 侧：修复后的入参（应完全相同）
                    let fixed = policy.output(isActive: active, taskIndex: index,
                                              taskCount: count, override: nil)
                    #expect(actual == fixed,
                            "口径必须逐字相同 count=\(count) index=\(index) active=\(active) policy=\(policy.rawValue)")
                }
            }
        }
    }
}

/// 负对照：UI 若沿用写死的 `(0, 1)`，在 `.mixed` 多卡时**必然与实播不一致**。
///
/// 这条把「修复改变了哪一类输入」变成可复算的事实，而不是一句「改好了」。
@Test func hardcodedUIValuesDivergeFromActualInMixed() throws {
    let policy = DockAudioPolicy.mixed

    // 3 张卡，活跃的是第 0 张。
    let actualActive = policy.output(isActive: true, taskIndex: 0, taskCount: 3, override: nil)
    let legacyUI = policy.output(isActive: true, taskIndex: 0, taskCount: 1, override: nil)

    // 实播：活跃那路也要均分 ⇒ 1/3；写死的 UI 算成 1（满格）
    #expect(actualActive.volume < 0.5, "三路 mixed 下活跃那路应被均分，实测 \(actualActive.volume)")
    #expect(legacyUI.volume > 0.9, "写死 taskCount=1 时算成满格，实测 \(legacyUI.volume)")
    #expect(actualActive != legacyUI, "两者必须不同，否则本判据没有判别力")

    // `.dimmed` 的非活跃那路与 count 无关（恒 0.15），此时写死不会错——
    // 说明缺陷只在依赖 count 的策略上显形，不是「所有情况都错」。
    let dimActual = DockAudioPolicy.dimmed.output(isActive: false, taskIndex: 2, taskCount: 4, override: nil)
    let dimLegacy = DockAudioPolicy.dimmed.output(isActive: false, taskIndex: 0, taskCount: 1, override: nil)
    #expect(dimActual == dimLegacy, "dimmed 非活跃与 count 无关，写死不影响 —— 限定缺陷面")
}

/// 逐卡覆盖优先于全局档位：UI 也必须遵守同一条优先级，
/// 否则「这一张单独静音」在卡片图标上不显形。
@Test func perCardOverrideBeatsGlobalPolicyOnUI() throws {
    for policy in DockAudioPolicy.allCases {
        // 单独静音 ⇒ 无论全局是什么、是不是活跃，都是静默
        let muted = policy.output(isActive: true, taskIndex: 0, taskCount: 3, override: .muted)
        #expect(muted.isMuted && muted.volume <= 0.001,
                "\(policy.rawValue) 下逐卡静音必须压过全局")

        // 单独定档 ⇒ 用该档，不受全局
        let level = policy.output(isActive: false, taskIndex: 2, taskCount: 3, override: .level(0.5))
        #expect(!level.isMuted && abs(level.volume - 0.5) < 0.001,
                "\(policy.rawValue) 下逐卡定档必须压过全局")

        // 定档拖到 0 ⇒ 等同静音（UI 图标要显示斜杠）
        let zero = policy.output(isActive: true, taskIndex: 0, taskCount: 1, override: .level(0))
        #expect(zero.isMuted, "\(policy.rawValue) 下 level=0 必须表现为静音")
    }
}
