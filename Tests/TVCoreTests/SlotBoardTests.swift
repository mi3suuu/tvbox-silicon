import Foundation
import Testing
@testable import TVCore

// MARK: - 槽位写入：空槽保真 + 「控件都有家」

/// 被测的是 **TVCore 里的真实现**（`SlotBoard.assign`），不是另抄一份模型。
/// App 层 `PlayerControlsLayout.setTopSlots/setBottomSlots` 只是把 `PlayerControl`
/// 填进同一个泛型入口 —— 所以这里通过 = App 层那条路通过。

private let topAllowed: Set<String> = ["a", "b", "c", "d", "e"]
private let bottomAllowed: Set<String> = ["p", "q", "r", "s", "t"]
private let centered: Set<String> = ["p"]

private func assign(_ slots: [String?],
                    isTop: Bool,
                    top: [String?] = [],
                    bottom: [String?] = [],
                    more: [String] = []) -> SlotBoard.Result<String> {
    SlotBoard.assign(slots,
                     toTopRow: isTop,
                     top: top,
                     bottom: bottom,
                     more: more,
                     allowed: isTop ? topAllowed : bottomAllowed,
                     center: centered)
}

// MARK: 核心：空槽保真（这就是「x 不受控制」的修复判据）

@Test func emptySlotsBeforeAnItemSurviveTheWrite() throws {
    // 用户要的：前 6 格空着，第 7 格（下标 6）放 a。
    var slots: [String?] = Array(repeating: nil, count: 6)
    slots.append("a")

    let out = assign(slots, isTop: true)

    #expect(out.top.count >= 7)
    #expect(out.top[0] == nil)
    #expect(out.top[5] == nil)
    #expect(out.top[6] == "a", "第 7 格必须还是第 7 格 —— 被压实说明又退回「只有先后没有位置」")
}

@Test func itemKeepsItsCellInTheMiddleOfTheRow() throws {
    // 第 2 格与第 4 格各一颗，中间留着空。
    let slots: [String?] = [nil, "a", nil, "b"]

    let out = assign(slots, isTop: true)

    #expect(out.top[1] == "a")
    #expect(out.top[2] == nil)
    #expect(out.top[3] == "b")
}

// MARK: 准入与去重

@Test func itemsNotAllowedOnThisRowBecomeEmptySlots() throws {
    // 底栏专属的 "p" 写进顶栏：不许出现，且不能把别的挤走。
    let slots: [String?] = ["p", "a"]

    let out = assign(slots, isTop: true)

    #expect(out.top[0] == nil, "画不出来的控件必须变成空格，否则播放器忽略它 =「加了没反应」")
    #expect(out.top[1] == "a")
}

@Test func duplicateItemKeepsOnlyItsFirstCell() throws {
    let slots: [String?] = ["a", "b", "a"]

    let out = assign(slots, isTop: true)

    #expect(out.top[0] == "a")
    #expect(out.top[1] == "b")
    #expect(out.top[2] == nil, "重复的那颗要变成空格，不能画两遍")
    #expect(out.top.compactMap { $0 }.filter { $0 == "a" }.count == 1)
}

// MARK: 不静默丢

@Test func overflowBeyondRowWidthGoesToMoreInsteadOfVanishing() throws {
    // 显式给一个**窄上限**（6）来验溢出行为本身 —— 不能依赖默认上限是多少，
    // 否则默认值一调（10 → 32）这条测试就悄悄失去判别力（本轮真实发生）。
    let items = (0..<8).map { "x\($0)" }
    let allowed = Set(items)
    let out = SlotBoard.assign(items.map { Optional($0) },
                               toTopRow: true,
                               top: [], bottom: [], more: [],
                               allowed: allowed, center: [],
                               slotCount: 6)

    #expect(out.top.compactMap { $0 }.count == 6)
    #expect(out.more.sorted() == ["x6", "x7"], "超出行宽的不许凭空消失")
}

@Test func defaultSlotCountFitsEveryPlaceableControlOnOneRow() throws {
    // 「每栏格数尽可能自由」的判据：任意一颗可摆放控件都必须能落到**任意一行**，
    // 所以默认上限不得小于「可摆放控件总数」。App 层传的就是这个数。
    #expect(SlotBoard.defaultSlotCount >= 32,
            "默认上限小于可摆放控件总数时，第 N 颗控件会被静默截掉")
}

@Test func displacedControlStaysReachable() throws {
    // 顶栏原本有 a、b；新写入只保留 a ⇒ b 必须落到「更多」。
    let out = assign(["a"], isTop: true, top: ["a", "b"])

    #expect(out.top.compactMap { $0 } == ["a"])
    #expect(out.more.contains("b"), "被摘下去的控件必须仍然可达")
}

@Test func displacedCenterControlReturnsToItsHomeRow() throws {
    // 底栏原本有 p（中心传输类）。用户重新写底栏且不含 p ⇒ p 应回到对面那一行，而不是进更多。
    let out = assign(["q"], isTop: false, bottom: ["p", "q"])

    #expect(out.bottom.compactMap { $0 } == ["q"])
    #expect(out.top.compactMap { $0 }.contains("p"), "中心控件的老家是画面中央，不该掉进「更多」")
}

// MARK: 不重复

@Test func aControlNeverLivesInBothRows() throws {
    // 底栏已有 a（假设它在两行都画得出来），再把 a 写进顶栏 ⇒ 底栏那份必须消失。
    let out = SlotBoard.assign(["a"], toTopRow: true,
                               top: [], bottom: ["a"], more: [],
                               allowed: topAllowed, center: ["a"])

    #expect(out.top.compactMap { $0 } == ["a"])
    #expect(!out.bottom.compactMap { $0 }.contains("a"))
}

// MARK: 吸附（拖动落格）

@Test func cellIndexSnapsToTheNearestColumn() throws {
    // 每格 44pt，左内边距 8pt。
    #expect(SlotBoard.cellIndex(forX: 8, leading: 8, cell: 44) == 0)
    #expect(SlotBoard.cellIndex(forX: 51, leading: 8, cell: 44) == 0)   // 刚过第 1 格
    #expect(SlotBoard.cellIndex(forX: 53, leading: 8, cell: 44) == 1)   // 进入第 2 格
    #expect(SlotBoard.cellIndex(forX: 96, leading: 8, cell: 44) == 2)
}

@Test func cellIndexIsClampedInsideTheRow() throws {
    #expect(SlotBoard.cellIndex(forX: -500, leading: 8, cell: 44) == 0, "拖到行外左边，钳在第 1 格")
    #expect(SlotBoard.cellIndex(forX: 99_999, leading: 8, cell: 44) == SlotBoard.defaultSlotCount - 1)
}

@Test func cellIndexWithZeroCellDoesNotCrashOrGoNegative() throws {
    #expect(SlotBoard.cellIndex(forX: 100, leading: 8, cell: 0) == 0)
}

// MARK: - 端到端：拖动坐标 → 吸附 → 写盘 → 读回（用户实际走的那条路）

@Test func draggingToTheSixthCellStoresItInTheSixthCell() throws {
    // 用户在窗口里把某颗控件拖到第 6 格（下标 5），松手后存储里必须在第 6 格。
    // 这条把「吸附」与「写入」串起来 —— 只测其中一段都不足以说明用户能摆准。
    let cell: CGFloat = 44, leading: CGFloat = 6
    let x = leading + cell * 5 + cell / 2          // 第 6 格中心
    let index = SlotBoard.cellIndex(forX: x, leading: leading, cell: cell)
    #expect(index == 5)

    var slots: [String?] = Array(repeating: nil, count: 10)
    slots[index] = "a"
    let out = assign(slots, isTop: true)

    #expect(out.top[5] == "a", "吸附到第 6 格，就必须存进第 6 格")
    #expect(out.top[0] == nil)
    #expect(out.top[4] == nil)
}

@Test func draggingBetweenCellsSnapsToTheNearerSideNotAlwaysZero() throws {
    // 旧实现在这一串输入下会全部落成「插在第一个之前」，也就是恒为 0 —— x 不受控的观感。
    let cell: CGFloat = 44, leading: CGFloat = 6
    let indices = [0, 1, 2, 3, 4, 5, 6].map {
        SlotBoard.cellIndex(forX: leading + cell * CGFloat($0) + cell * 0.5,
                            leading: leading, cell: cell)
    }
    #expect(indices == [0, 1, 2, 3, 4, 5, 6], "每一格都必须吸附到自己，不能全塌到 0")
}
