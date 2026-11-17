import Foundation
import CoreGraphics

// MARK: - 坞卡片的位置钳位

/// 保证「任何拖动结果都还留得下一角能抓回来」。
///
/// ## 为什么必须有
///
/// 坞卡片的偏移是相对**右下角锚点**的，拖动时是纯累加。于是卡片能被拖到任意远，
/// 一旦整块出屏：屏幕上没有它，也就没有它的手势 —— **再也抓不回来**，只能杀 App。
/// 用户报的「不小心拖到屏幕外无法呼唤回来」就是这条。
///
/// 判据不是「不许出界」，而是「至少要留 `keep` 那一角在容器里」：
/// 把卡片拖到边上是用户的自由，我们只保证他还能再抓到它。
public enum DockCardClamp {

    /// 默认要求留下的最小可见宽度（pt）。比 44pt 的触摸目标大一些，好按。
    public static let keep: CGFloat = 72

    /// 把偏移钳到「至少露一角」。
    ///
    /// 坐标系：卡片以容器**右下角**为锚点，`offset` 往左/上为负。
    /// 于是卡片的四条边是：
    ///   right  = container.width  + offset.width
    ///   left   = right - card.width
    ///   bottom = container.height + offset.height
    ///   top    = bottom - card.height
    ///
    /// 约束（两个方向各两条，保证「至少 keep 宽/高 落在容器内」）：
    ///   right ≥ keep                     ⇒ offset.width  ≥ keep  - container.width
    ///   left  ≤ container.width - keep   ⇒ offset.width  ≤ card.width - keep
    /// 上下同理。
    public static func clamp(_ offset: CGSize,
                             card: CGSize,
                             in container: CGSize,
                             keep: CGFloat = DockCardClamp.keep) -> CGSize {
        CGSize(width: clampAxis(offset.width,
                                cardLength: card.width, containerLength: container.width, keep: keep),
               height: clampAxis(offset.height,
                                 cardLength: card.height, containerLength: container.height, keep: keep))
    }

    /// 单轴版本。容器比卡片还小时上下界会交叉 —— 那时取区间中点，
    /// 而不是让 `min(max(x,lo),hi)` 在 `lo > hi` 下给出随实现摆动的值。
    private static func clampAxis(_ value: CGFloat,
                                  cardLength: CGFloat,
                                  containerLength: CGFloat,
                                  keep: CGFloat) -> CGFloat {
        let lower = keep - containerLength
        let upper = cardLength - keep
        guard lower <= upper else { return (lower + upper) / 2 }
        return min(max(value, lower), upper)
    }
}
