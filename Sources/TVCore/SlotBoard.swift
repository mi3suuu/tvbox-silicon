import Foundation

/// 两行槽位的**纯算法**：把「用户把某颗控件拖到第几格」变成一份合法的槽位数组。
///
/// ## 为什么把它单独抽出来
///
/// 设置页原本只有一个写入口 `setTopOrder(_ controls:)`，它收「非空控件的顺序」，
/// 内部 `wanted.map(Optional.some)` 把整行**压实**成连续的一串。于是：
///
/// ```
/// 用户想要：   [ 空 ][ 空 ][ 空 ][ 空 ][ 空 ][ 空 ][画质]
/// 实际存成：   [画质][ 空 ][ 空 ][ 空 ][ 空 ][ 空 ][ 空 ]
/// ```
///
/// 用户看到的就是「x 不受控制」：无论把控件拖到多靠右，它总是被顶到最左边。
/// 根因不是手势算错，而是**行内没有位置这个概念，只有先后**。
///
/// 这个文件只做数据：不 import SwiftUI、不认识任何具体控件类型，用 `Item` 泛型。
/// App 层（`PlayerControlsLayout`）把 `PlayerControl` 填进来即可，
/// 测试则可以填字符串 —— **测的是同一段实现，不是另抄一份模型**。
///
/// 之前 `SlotPlacementInvariantTests` 只能用字符串模型「与实现同构」地跑，
/// 注释里也承认「这不是另写一份实现来测自己」是个需要辩解的事。
/// 抽到这里之后不再需要辩解。
public enum SlotBoard {
    /// 一行**默认**能放几格。
    ///
    /// ⛔ 这个数曾经是 `10`（App 层 `PlayerControlsLayout.slotCount` 也是 10）。
    /// 10 只是「默认布局恰好用满」的巧合，不是物理约束 —— 存储是逗号分隔，无长度上限。
    /// 写死它会让第 11 颗控件被静默截断。
    ///
    /// 现在 App 层把真实上限（= 可摆放控件总数）**显式传进来**，
    /// 这个常量只剩「调用方没传时」的兜底，测试也用它当默认值。
    public static let defaultSlotCount = 32

    /// 一次写入的结果：两行槽位 + 「更多」。
    public struct Result<Item: Hashable>: Equatable {
        public var top: [Item?]
        public var bottom: [Item?]
        public var more: [Item]
        public init(top: [Item?], bottom: [Item?], more: [Item]) {
            self.top = top
            self.bottom = bottom
            self.more = more
        }
    }

    /// 把 `slots` 写进 `row` 那一行（`true` = 顶栏）。
    ///
    /// 不变量（每一条都有测试）：
    /// 1. **空槽保真**：写进来的第 N 格就落在第 N 格，中间的空格不被压实。
    /// 2. 只留 `allowed` 里的控件；重复的只保留第一次出现，后面的位置记为空格。
    /// 3. 超出行宽（`slotCount` 参数）的**不静默丢**，进「更多」。
    /// 4. 被从这一行摘下去的控件仍然有家：
    ///    - `center` 里的回到对面那一行（它老家）；
    ///    - 其余进「更多」。
    /// 5. 同一颗控件不会同时出现在两行里。
    public static func assign<Item: Hashable>(
        _ slots: [Item?],
        toTopRow isTop: Bool,
        top: [Item?],
        bottom: [Item?],
        more: [Item],
        allowed: Set<Item>,
        center: Set<Item>,
        slotCount: Int = SlotBoard.defaultSlotCount
    ) -> Result<Item> {
        // ① 清洗：只留画得出来的；同一颗只留第一次出现；超宽的单独记下来。
        var kept: [Item?] = []
        var seen = Set<Item>()
        var squeezed: [Item] = []
        for slot in slots {
            guard let item = slot, allowed.contains(item) else { kept.append(nil); continue }
            guard !seen.contains(item) else { kept.append(nil); continue }
            if kept.count >= slotCount { squeezed.append(item); continue }
            seen.insert(item)
            kept.append(item)
        }
        // ② 行宽上限：被挤出去的进「更多」，不能凭空消失。
        if kept.count > slotCount { kept = Array(kept.prefix(slotCount)) }

        var nextMore = more.filter { !seen.contains($0) }
        for item in squeezed where !nextMore.contains(item) { nextMore.append(item) }

        var nextTop = top
        var nextBottom = bottom

        // ③ 从这一行被摘下去的要有去处。
        for item in (isTop ? top : bottom).compactMap({ $0 }) where !seen.contains(item) {
            if center.contains(item) {
                // 回「中央」= 写进对面那一行（中央与进度行共用 bottomSlots 这一份）。
                if isTop {
                    if !nextBottom.compactMap({ $0 }).contains(item) {
                        nextBottom = appending(item, to: nextBottom)
                    }
                } else if !nextTop.compactMap({ $0 }).contains(item) {
                    nextTop = appending(item, to: nextTop)
                }
            } else if !nextMore.contains(item) {
                nextMore.append(item)
            }
        }

        // ④ 写进来的从对面那一行摘掉，保证不重复。
        func clearing(_ row: [Item?]) -> [Item?] {
            row.map { slot in
                guard let item = slot else { return nil }
                return seen.contains(item) ? nil : item
            }
        }
        nextTop = clearing(nextTop)
        nextBottom = clearing(nextBottom)

        if isTop { nextTop = kept } else { nextBottom = kept }
        return Result(top: nextTop, bottom: nextBottom, more: nextMore)
    }

    /// 追加到某行**第一个空槽**；没有空槽就接在末尾。
    ///
    /// 与 `assign` 里的「回老家」共用：空槽优先，是为了不把已有的位置往后挤。
    public static func appending<Item>(_ item: Item, to slots: [Item?]) -> [Item?] {
        var result = slots
        if let index = result.firstIndex(where: { $0 == nil }) {
            result[index] = item
        } else {
            result.append(item)
        }
        return result
    }

    /// 某个坐标该落在第几格 —— 设置页拖动时用来吸附。
    ///
    /// `x` 是手指在**窗口坐标系**里的横坐标，`leading` 是这一行的左内边距，
    /// `cell` 是每格宽度。返回值钳在 `0...slotCount-1`（可传真实上限）。
    public static func cellIndex(forX x: CGFloat,
                                 leading: CGFloat,
                                 cell: CGFloat,
                                 slotCount: Int = SlotBoard.defaultSlotCount) -> Int {
        guard cell > 0 else { return 0 }
        let limit = max(slotCount, 1)
        let raw = Int(((x - leading) / cell).rounded(.down))
        return min(max(raw, 0), limit - 1)
    }
}
