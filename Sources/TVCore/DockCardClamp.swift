import Foundation
import CoreGraphics

// MARK: - 坞卡片的位置钳位

/// 保证卡片的**整块**都留在容器（屏幕）里。
///
/// ## 为什么口径从「留一角」改成「全在里面」
///
/// 上一版只要求「至少留 72pt 可触摸」—— 那是为了修「拖出屏幕叫不回来」。
/// 但用户要的不是「能抓回来」，是**根本不允许出去**：
/// 卡片压在状态栏 / 底部手势条上时，那部分内容既看不见也点不到，
/// 看起来就是「窗口被屏幕吃掉半截」。
///
/// 现在的判据：四条边都落在 `[margin, container - margin]` 内。
/// 卡片被捏得比容器还大时无解，此时取区间中点（居中溢出），
/// 并且调用方必须先过 `fit(_:in:)` 把尺寸压回容器内 —— 那是「捏不出去」的另一半。
///
/// 坐标系：卡片以容器**右下角**为锚点，`offset` 往左/上为负。
/// 于是卡片的四条边是：
///   right  = container.width  + offset.width
///   left   = right - card.width
///   bottom = container.height + offset.height
///   top    = bottom - card.height
public enum DockCardClamp {

    /// 卡片与容器边缘之间至少留的空隙（pt）。
    ///
    /// 不留空隙的话，卡片会贴在屏幕圆角 / 手势条上 —— 视觉上像被切掉，
    /// 触摸上边角那几 pt 也点不准。
    public static let margin: CGFloat = 8

    /// 把偏移钳到「整块都在容器内」。
    ///
    /// 约束（两个方向各两条）：
    ///   left ≥ margin              ⇒ offset.width  ≥ card.width  - container.width + margin
    ///   right ≤ container - margin ⇒ offset.width  ≤ -margin
    /// 上下同理。
    public static func clamp(_ offset: CGSize,
                             card: CGSize,
                             in container: CGSize,
                             margin: CGFloat = DockCardClamp.margin) -> CGSize {
        CGSize(width: clampAxis(offset.width,
                                cardLength: card.width, containerLength: container.width, margin: margin),
               height: clampAxis(offset.height,
                                 cardLength: card.height, containerLength: container.height, margin: margin))
    }

    /// 把卡片尺寸压回「放得进容器」的大小。
    ///
    /// 用户能捏到 2.2 倍，320pt 的基础宽在手机上就是 704pt —— 比屏幕还宽。
    /// 那种尺寸无论怎么摆都会出界，所以**尺寸**这一侧也必须有一道闸：
    /// 最多到 `container - 2 * margin`，宽高按同一比例收（不改变画面比例）。
    public static func fit(_ size: CGSize,
                           in container: CGSize,
                           margin: CGFloat = DockCardClamp.margin) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 1, height: 1) }
        let maxW = max(1, container.width - margin * 2)
        let maxH = max(1, container.height - margin * 2)
        let scale = min(1, min(maxW / size.width, maxH / size.height))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// 单轴版本。容器比卡片还小时上下界会交叉 —— 那时取区间中点，
    /// 而不是让 `min(max(x,lo),hi)` 在 `lo > hi` 下给出随实现摆动的值。
    private static func clampAxis(_ value: CGFloat,
                                  cardLength: CGFloat,
                                  containerLength: CGFloat,
                                  margin: CGFloat) -> CGFloat {
        let lower = cardLength + margin - containerLength
        let upper = -margin
        guard lower <= upper else { return (lower + upper) / 2 }
        return min(max(value, lower), upper)
    }
}
