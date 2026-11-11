import Foundation
import Testing
@testable import TVCore

// MARK: - 传感器避让：横屏刘海那一支曾经是死代码

/// 横屏时 `safeAreaInsets.top` 通常是 0，而刘海在**左缘**。
///
/// 旧实现第一行就是 `guard safeTop > 0 else { return .none }`，于是横屏直接
/// 返回 `.none` → `Housing.bottom = 0` → `overlaps` 里的 `guard bottom > 0` 恒 false
/// → 那句 `notch = max(safeLeft, 44)` **永远执行不到**。
/// 用户报的「最边缘不能正常点击」正是这一支没生效。
@Test func theLandscapeNotchIsAvoidedEvenWhenSafeTopIsZero() {
    // 横屏：顶部安全区 0，左侧有 44pt 刘海
    let housing = OneSkinSafeArea.housing(screen: CGSize(width: 951, height: 669),
                                          safeTop: 0, safeLeft: 44, portrait: false)
    #expect(housing.bottom > 0, "横屏遮挡带的纵向范围不能为 0，否则 overlaps 恒 false")
    #expect(housing.right >= 44, "刘海宽度至少 44")
    #expect(housing.left == 0, "横屏缺口贴左缘")
    // 最左边那颗按钮（x 0...28）必须被判定为撞上
    #expect(housing.overlaps(0, 28), "左上角按钮必须判定为落在刘海带里")
    // 屏幕中部的按钮不该被殃及
    #expect(!housing.overlaps(400, 460), "中部按钮不该被刘海连累")
}

/// 竖屏：safeTop > 0 时按原有逻辑走（Duo 上的竖排岛取整宽避让）。
@Test func thePortraitIslandTakesTheFullWidthOnDuo() {
    let duo = OneSkinSafeArea.housing(screen: CGSize(width: 669, height: 951),
                                      safeTop: 84, safeLeft: 0, portrait: true)
    #expect(duo.bottom == 84)
    #expect(duo.left == 0 && duo.right == 669, "Duo 竖排岛按整宽避让")
    #expect(duo.overlaps(0, 100), "左侧控件也要让开（岛竖排贴边）")

    // 直板机 440 宽仍走「居中岛 0.27」模型
    let bar = OneSkinSafeArea.housing(screen: CGSize(width: 440, height: 900),
                                      safeTop: 59, safeLeft: 0, portrait: true)
    #expect(bar.right - bar.left < 200, "直板机岛宽应远小于整宽")
    #expect(!bar.overlaps(0, 20), "直板机左侧空着，不需让开")
}

/// 完全没有遮挡时返回 .none，不能让顶栏无故下压。
@Test func noInsetMeansNoAvoidance() {
    let none = OneSkinSafeArea.housing(screen: CGSize(width: 951, height: 669),
                                       safeTop: 0, safeLeft: 0, portrait: false)
    #expect(none == .none)
    #expect(!none.overlaps(0, 100))
}

/// `topUp` 只补差额（遮挡带与系统安全区语义重叠，不能相加）。
@Test func theTopUpIsOnlyTheShortfall() {
    #expect(OneSkinSafeArea.topUp(occlusion: 60, safe: 84) == 0)
    #expect(OneSkinSafeArea.topUp(occlusion: 100, safe: 84) == 16)
    #expect(OneSkinSafeArea.topUp(occlusion: 84, safe: 0) == 84)
}
