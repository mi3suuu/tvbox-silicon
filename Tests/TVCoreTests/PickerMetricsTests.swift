import Foundation
import Testing
@testable import TVCore

// MARK: - 选集面板的尺寸档

/// 这组判据锁住「宽屏 = 更多列，不是更大格子」。
///
/// 背景：第一版 `PickerMetrics` 按「宽屏就把格子放大」写成 92/108/128，
/// 真机后果是 951pt 上从 9 列掉到 6 列 —— 一屏能看到的集数少了一半，
/// 而文字周围全是空白。这不是审美问题，是**功能退化**。
@Suite("PickerMetricsColumns")
struct PickerMetricsColumnsTests {

    /// 可用宽度（真机实测的三种容器宽度）。
    private static let widths: [(name: String, width: CGFloat)] = [
        ("外屏", 466), ("内屏竖持", 669), ("内屏横持", 951),
    ]

    /// `LazyVGrid(.adaptive(minimum:))` 的列数：n = floor((avail + spacing) / (min + spacing))。
    private func columns(available: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        max(1, Int((available + spacing) / (minimum + spacing)))
    }

    /// 列数必须**随可用宽度单调不减**。
    ///
    /// 反面就是第一版的缺陷：951pt 反而比 466pt 的「每列相对内容」更差，
    /// 因为格子被放大后列数掉了。
    @Test func moreWidthNeverMeansFewerColumns() {
        let m = PickerMetrics.forWidth(466)
        let avail466 = 466 - m.panelPadding * 2
        let c466 = columns(available: avail466, minimum: m.gridMinColumn, spacing: m.gridSpacing)

        let m951 = PickerMetrics.forWidth(951)
        let avail951 = 951 - m951.panelPadding * 2
        let c951 = columns(available: avail951, minimum: m951.gridMinColumn, spacing: m951.gridSpacing)

        #expect(c951 > c466,
                "951pt 的列数(\(c951)) 必须多于 466pt(\(c466))；宽屏的意义是多看到几集，不是把格子撑大")
    }

    /// 三种形态下，格子实际宽度都要在「放得下集数文字、又不浪费空间」的区间里。
    ///
    /// 下限 64pt：`footnote` 字号的「第01集」约 65pt 宽，再窄就要截断。
    /// 上限 130pt：超过就是空白多于文字，属于第一版那个退化。
    @Test func everyCellStaysWithinAUsefulWidth() {
        let minimumUsable: CGFloat = 64
        let wasteful: CGFloat = 130
        for c in Self.widths {
            let m = PickerMetrics.forWidth(c.width)
            let avail = c.width - m.panelPadding * 2
            let n = columns(available: avail, minimum: m.gridMinColumn, spacing: m.gridSpacing)
            let cellWidth = (avail - CGFloat(n - 1) * m.gridSpacing) / CGFloat(n)
            #expect(cellWidth >= minimumUsable,
                    "\(c.name) 格宽 \(cellWidth) 小于 \(minimumUsable)，集数文字会被截断")
            #expect(cellWidth <= wasteful,
                    "\(c.name) 格宽 \(cellWidth) 超过 \(wasteful)，空白多于文字（第一版的缺陷形态）")
        }
    }

    /// 档位边界必须与真机三种容器宽度对得上。
    @Test func theThreeRealWidthsLandInThreeTiers() {
        #expect(PickerMetrics.forWidth(466) == .outer)
        #expect(PickerMetrics.forWidth(669) == .innerPortrait)
        #expect(PickerMetrics.forWidth(951) == .innerLandscape)
    }
}
