import Foundation
import Testing
@testable import TVCore

/// 观看页（One 选集播放页）的纯逻辑。
///
/// 这些数值是 rea + MachOSwiftSection 对 One 1.7.0 的**双重取证**结果，不是调参：
/// 类型层从 `AmbientBackground` 的 `body` 类型别名确认结构，函数层（`sub_1001e3ed4`）
/// 逐条指令读常量，像素层用 `Fig-clone` VM 截图复核（边缘能量 0.56 vs 实测 0.55）。
///
/// 钉在这里的目的：谁要改背景观感，必须先改这份断言（即先拿出新证据），
/// 而不是悄悄改一个浮点数然后靠肉眼比对截图。
///
/// ⚠️ 两次翻车记录，别再走回头路：
/// 1. 曾钉 `sub_1001e5360` 的 0.08 / 0.55 / `center→bottom` —— 那个函数**不是**观看页背景
///    （self 取自结构体 +0x38，而 `AmbientBackground` 的 self 就是一个 String）。
/// 2. 曾用 `blur(radius: 40)` + `dim 0.786` 去凑「边缘能量 3.41」—— 二进制里没有任何
///    模糊调用，body 类型链里只有 `_ScaleEffect` 和 `_OpacityEffect`。

@Test func backdropUsesTheConstantsOneShipsWith() {
    // 函数层：`sub_1001e3ed4` 逐条指令的立即数 / 常量池。
    #expect(OneWatchPage.Backdrop.maxPixel == 48)          // mov w8, #0x30
    #expect(OneWatchPage.Backdrop.scale == 1.4)            // 0x3ff6666666666666
    #expect(OneWatchPage.Backdrop.coverOpacity == 0.6)     // 0x3fe3333333333333
    // ⛔ topDim / bottomDim **故意不等于**二进制原值（0.15 / 0.88），已按真机反推改小。
    //
    // 原值会让海报几乎不可见：最终亮度 = (1 - d) × coverOpacity × 海报原亮度 L，
    // 底部实测 22.7，若 d = 0.88 ⟹ L 需 315 > 255（物理不可能）；
    // 最亮处实测 110.7 ⟹ L 需 1537（荒谬）。
    // 用户原话：「它的明暗是根据海报来做的后续处理，都取决于海报，而不是硬编码。」
    // 所以现在这两个值只是「保证文字可读」的兜底，不再充当遮罩。
    // 判据改成区间：够暗到保证可读，又不至于把海报压没。
    #expect(OneWatchPage.Backdrop.topDim < 0.15 && OneWatchPage.Backdrop.topDim >= 0.05,
            "顶部遮罩应比二进制原值(0.15)更轻，且仍保证文字可读")
    #expect(OneWatchPage.Backdrop.bottomDim < 0.88 && OneWatchPage.Backdrop.bottomDim >= 0.2,
            "底部遮罩应远轻于二进制原值(0.88)，否则海报不可见")
    // 渐变必须**自顶向下变暗**（top < bottom），这是排版可读性的方向要求。
    #expect(OneWatchPage.Backdrop.topDim < OneWatchPage.Backdrop.bottomDim)
}

/// 渐变是 `.top → .bottom` 的两停，整条 0…1 都在过渡（不是 center→bottom）。
@Test func theGradientRampsAcrossTheWholeHeight() {
    let b = OneWatchPage.Backdrop.self
    #expect(b.opacity(at: 0) == b.topDim)
    #expect(b.opacity(at: 1) == b.bottomDim)
    #expect(abs(b.opacity(at: 0.5) - (b.topDim + b.bottomDim) / 2) < 1e-12)
    // 越往下越暗：这是观看页「上亮下暗」的唯一来源。
    #expect(b.opacity(at: 0.25) < b.opacity(at: 0.75))
}

@Test func backdropClampsOutOfRangeFractions() {
    let b = OneWatchPage.Backdrop.self
    #expect(b.opacity(at: -3) == b.topDim)
    #expect(b.opacity(at: 42) == b.bottomDim)
}

@Test func aShortSynopsisGetsNoExpandButton() {
    let text = "一句话就说完。"
    #expect(!OneWatchPage.synopsisNeedsExpand(text, columnWidth: 236))
}

@Test func aLongSynopsisGetsAnExpandButton() {
    let text = String(repeating: "这段简介很长，会被收起态的三行截断。", count: 20)
    #expect(OneWatchPage.synopsisNeedsExpand(text, columnWidth: 236))
}

@Test func anEmptySynopsisNeverNeedsExpand() {
    #expect(!OneWatchPage.synopsisNeedsExpand("", columnWidth: 236))
}

@Test func aZeroWidthColumnNeverCriesForExpand() {
    // 宽度未知时不该报「需要展开」—— 那会在布局前闪一下按钮。
    #expect(!OneWatchPage.synopsisNeedsExpand("任意长度的简介", columnWidth: 0))
}

@Test func pageCountRoundsUpAndNeverReturnsZero() {
    #expect(OneWatchPage.pageCount(itemCount: 0) == 1)
    #expect(OneWatchPage.pageCount(itemCount: 1, pageSize: 50) == 1)
    #expect(OneWatchPage.pageCount(itemCount: 50, pageSize: 50) == 1)
    #expect(OneWatchPage.pageCount(itemCount: 51, pageSize: 50) == 2)
    #expect(OneWatchPage.pageCount(itemCount: 1282, pageSize: 50) == 26)
}

@Test func aZeroPageSizeIsTreatedAsOne() {
    // 除零保护：设置里把每页条数写成 0 时不能崩。
    #expect(OneWatchPage.pageCount(itemCount: 3, pageSize: 0) == 3)
}

@Test func anOutOfRangePageIsClampedWhenTheListShrinks() {
    // 1282 集在第 25 页，筛选后只剩 3 集（1 页）→ 必须落回第 0 页，否则停在空页。
    #expect(OneWatchPage.clampPage(25, itemCount: 3) == 0)
    #expect(OneWatchPage.clampPage(-4, itemCount: 300) == 0)
    #expect(OneWatchPage.clampPage(1, itemCount: 300) == 1)
    #expect(OneWatchPage.clampPage(99, itemCount: 300) == 5)
}
