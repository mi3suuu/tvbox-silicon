import Foundation
import CoreGraphics

/// 坞里多窗的排布方式。
///
/// 用户要求：「不同迷你窗的图层前后显示顺序需要可以拖拽」「多个窗口需要支持平铺处理」。
/// 这两件事是分开的：
///   · **z-order（谁在前）** —— 由 `VideoTaskCenter.tasks` 的数组顺序决定，用户拖动可改；
///   · **摆位（在哪）** —— 有「自由堆叠」与「平铺」两种，这里给出平铺的算法。
public enum DockLayoutMode: String, CaseIterable, Codable, Sendable {
    /// 自由摆放：每张卡各自记自己的偏移，可以重叠。
    case free
    /// 平铺：所有卡按网格自动排好，不重叠。
    case tiled
}

public enum DockLayout {

    /// 平铺时每张卡的尺寸与位置（相对坞容器，原点左上）。
    public struct Tile: Equatable, Sendable {
        public let origin: CGPoint
        public let size: CGSize
        public init(origin: CGPoint, size: CGSize) {
            self.origin = origin
            self.size = size
        }
    }

    /// 把 `count` 张卡排进 `container`。
    ///
    /// 规则（刻意简单，因为要能预测）：
    ///   · 列数取 `ceil(sqrt(n))`，让格子接近正方形 —— 8 张是 3×3，4 张是 2×2；
    ///   · 格子宽高按容器等分，**保持画面宽高比**（`aspect`），不拉伸；
    ///   · 整组在容器内**居中**，不做左上对齐（视觉上更稳）；
    ///   · 间距固定 8pt，容器太小就自动退化为 1 列。
    ///
    /// 空 `count` 或非正容器尺寸返回空数组 —— 调用方据此不画。
    public static func tiles(count: Int,
                             in container: CGSize,
                             aspect: CGFloat,
                             spacing: CGFloat = 8) -> [Tile] {
        guard count > 0, container.width > 1, container.height > 1 else { return [] }
        let cols = max(1, Int(ceil(Double(count).squareRoot())))
        let rows = max(1, Int(ceil(Double(count) / Double(cols))))

        let cellW = (container.width - spacing * CGFloat(cols + 1)) / CGFloat(cols)
        let cellH = (container.height - spacing * CGFloat(rows + 1)) / CGFloat(rows)
        guard cellW > 1, cellH > 1 else {
            // 容器太小放不下网格：退化成「一列铺满」。
            let h = max(1, (container.height - spacing * CGFloat(count + 1)) / CGFloat(count))
            return (0..<count).map { i in
                Tile(origin: CGPoint(x: spacing, y: spacing + CGFloat(i) * (h + spacing)),
                     size: CGSize(width: max(1, container.width - spacing * 2), height: h))
            }
        }

        // 按格子定卡片尺寸：宽取格子宽，高 = 宽 / 画面宽高比，超高就反过来压宽。
        let safeAspect = max(aspect, 0.2)
        var w = cellW
        var h = w / safeAspect
        if h > cellH {
            h = cellH
            w = h * safeAspect
        }

        // 整组居中。
        let gridW = CGFloat(cols) * w + CGFloat(cols + 1) * spacing
        let gridH = CGFloat(rows) * h + CGFloat(rows + 1) * spacing
        let originX = max(spacing, (container.width - gridW) / 2 + spacing)
        let originY = max(spacing, (container.height - gridH) / 2 + spacing)

        return (0..<count).map { i in
            let r = i / cols
            let c = i % cols
            return Tile(origin: CGPoint(x: originX + CGFloat(c) * (w + spacing),
                                        y: originY + CGFloat(r) * (h + spacing)),
                        size: CGSize(width: w, height: h))
        }
    }

    /// 把平铺的绝对位置换算成坞使用的「相对右下角」偏移。
    ///
    /// 坞里卡片位置一律存成「相对容器右下角」的偏移（往左/上为负），
    /// 平铺算出来是左上原点，所以要转一次。转换放在这里，
    /// 是为了不让 UI 层重复写这个减法（写错过一次就会全歪）。
    public static func offset(for tile: Tile, in container: CGSize) -> CGSize {
        CGSize(width: tile.origin.x + tile.size.width - container.width,
               height: tile.origin.y + tile.size.height - container.height)
    }
}
