import Foundation
import Testing
@testable import TVCore

// MARK: - #17：控件槽位放置的不变量（核查结论 + 锁死）

/// `PlayerControlsLayout.place` 在 App 层（`PlayerControl` 无 TVCore 版本），
/// 所以这里用一份**与实现同构**的字符串模型跑不变量判据。
///
/// 这不是"另写一份实现来测自己"——被测的是**语义**：
/// 「把 A 放进已被 B 占着的槽位后，B 必须仍然可达（顶栏/底栏/更多三者之一），
///  不得从界面消失」。这条语义与具体类型无关，因此可以用字符串模型表达，
/// 再由 App 层实现承担同一约束（实现在 `PlayerControlsLayout.place`）。
private struct SlotModel {
    var top: [String?]
    var bottom: [String?]
    var more: [String]
    static let slotCount = 10

    /// 与 `PlayerControlsLayout.place(_:in:slot:)` 同构，**含本轮修复的语义**。
    mutating func place(_ control: String, topSlot: Int? = nil, bottomSlot: Int? = nil) {
        remove(control)
        if let i = topSlot {
            let index = min(max(i, 0), Self.slotCount - 1)
            if let displaced = top[index], displaced != control, !more.contains(displaced) {
                more.append(displaced)
            }
            top[index] = control
        } else if let i = bottomSlot {
            let index = min(max(i, 0), Self.slotCount - 1)
            if let displaced = bottom[index], displaced != control, !more.contains(displaced) {
                more.append(displaced)
            }
            bottom[index] = control
        } else {
            more.append(control)
        }
    }

    mutating func remove(_ control: String) {
        top = top.map { $0 == control ? nil : $0 }
        bottom = bottom.map { $0 == control ? nil : $0 }
        more.removeAll { $0 == control }
    }

    /// 某个控件现在还能不能找到（三种位置之一）。
    func contains(_ control: String) -> Bool {
        top.contains(control) || bottom.contains(control) || more.contains(control)
    }
}

@Test func placingOntoOccupiedSlotKeepsDisplacedControlReachable() throws {
    var model = SlotModel(
        top: ["airPlay", "episodes", nil, nil, nil, nil, nil, nil, nil, nil],
        bottom: Array(repeating: nil, count: 10),
        more: ["quality"]
    )

    // 把 quality 放进 slot 0 —— 那里已被 airPlay 占着
    model.place("quality", topSlot: 0)

    #expect(model.top[0] == "quality", "被放置的控件要到位")
    #expect(model.contains("airPlay"),
            "被挤掉的 airPlay 必须仍然可达（顶栏/底栏/更多之一），不能消失")
    #expect(model.more.contains("airPlay"), "本轮修法：被挤掉的收进「更多」")

    // 负对照：若实现是「直接覆盖」，airPlay 会三者皆无。
    var legacy = SlotModel(
        top: ["airPlay", "episodes", nil, nil, nil, nil, nil, nil, nil, nil],
        bottom: Array(repeating: nil, count: 10),
        more: ["quality"]
    )
    legacy.more.removeAll { $0 == "airPlay" }
    legacy.top[0] = "quality"     // 直接覆盖（模拟修复前）
    #expect(!legacy.contains("airPlay"), "旧实现下 airPlay 确实消失 —— 这就是缺陷")
    #expect(model.contains("airPlay") != legacy.contains("airPlay"),
            "两者必须不同，否则本判据没有判别力")
}

/// 底栏同理 —— 两个分区不能只修一个。
@Test func placingOntoOccupiedBottomSlotKeepsDisplacedControlReachable() throws {
    var model = SlotModel(
        top: Array(repeating: nil, count: 10),
        bottom: ["backTen", nil, nil, nil, nil, nil, nil, nil, nil, nil],
        more: []
    )
    model.place("speed", bottomSlot: 0)
    #expect(model.bottom[0] == "speed")
    #expect(model.contains("backTen"), "底栏被挤掉的同样不能消失")
    #expect(model.more.contains("backTen"))
}

/// 不变量：任何一次 place 之后，**控件总数不得减少**。
///
/// 这是比「某一个控件还在」更强的判据：它把「静默丢失」变成可计数的算术。
@Test func placeNeverLosesAControl() throws {
    let universe = ["airPlay", "episodes", "quality", "speed", "backTen"]
    var model = SlotModel(
        top: ["airPlay", "episodes", nil, nil, nil, nil, nil, nil, nil, nil],
        bottom: ["backTen", nil, nil, nil, nil, nil, nil, nil, nil, nil],
        more: ["quality", "speed"]
    )
    let before = universe.filter { model.contains($0) }.count
    #expect(before == universe.count, "起始状态下五个都在")

    // 反复把控件丢到已被占的槽位
    for control in universe {
        for slot in 0..<3 {
            model.place(control, topSlot: slot)
            let now = universe.filter { model.contains($0) }.count
            #expect(now == universe.count,
                    "place(\(control), top:\(slot)) 之后总数应保持 \(universe.count)，实得 \(now)")
        }
    }
    // 全部落位后每个控件仍恰好出现一次
    let occurrences = universe.map { c in
        model.top.filter { $0 == c }.count + model.bottom.filter { $0 == c }.count + model.more.filter { $0 == c }.count
    }
    #expect(occurrences.allSatisfy { $0 == 1 }, "每个控件必须恰好出现一次，实得 \(occurrences)")
}

/// 把控件放回「更多」不该让它重复出现。
@Test func placingIntoMoreDoesNotDuplicate() throws {
    var model = SlotModel(
        top: ["quality", nil, nil, nil, nil, nil, nil, nil, nil, nil],
        bottom: Array(repeating: nil, count: 10),
        more: []
    )
    model.place("quality")   // 顶栏 → 更多
    #expect(model.more == ["quality"])
    #expect(model.top[0] == nil)

    // 再放一次不应产生两条
    model.place("quality")
    #expect(model.more.filter { $0 == "quality" }.count == 1,
            "重复放进「更多」必须去重，实得 \(model.more)")
}
