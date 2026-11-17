import SwiftUI

// Content-first surfaces: neutral backgrounds, quiet controls, and strong selection contrast.

/// The app's colours, driven by the colour theme (`App/ColorThemes.swift`).
///
/// 上游把这套颜色从固定值改成主题驱动（Classic 外加十套 + 自定义，见 #1186 前一串 Color Themes 提交）。
/// 我方二开把 Brand/Layout 拆到本目录，因此这里承接上游的主题化实现，`GlassKit.swift` 不再重复定义。
enum Brand {
    /// Selection, prominent actions and progress, in the colour theme's highlight. Classic's is a fixed grey rather than
    /// `.primary`: as a tint, `.primary` turned prominent buttons white-on-white. On Apple TV no button is filled with it,
    /// so it never sits beside the white focus.
    static var accent: Color { ColorThemes.shared.current.palette.accent }
    /// Label colour on an accent fill.
    static var onAccent: Color { ColorThemes.shared.current.palette.onAccent }
    /// The icon's cyan, for decoration only (icon tiles, charts, artwork placeholders), not for state. A mixed colour
    /// theme puts its own four icon colours in place of cyan, indigo, teal and amber.
    static var cyan: Color { decor(0) ?? ThemeRegions.standardDecor[0] }
    static var indigo: Color { decor(1) ?? ThemeRegions.standardDecor[1] }
    static var teal: Color { decor(2) ?? ThemeRegions.standardDecor[2] }
    static var amber: Color { decor(3) ?? ThemeRegions.standardDecor[3] }
    private static func decor(_ index: Int) -> Color? { ColorThemes.shared.current.palette.regions?.decor[index] }
    static let rose = Color(red: 0.95, green: 0.38, blue: 0.42)

    /// [mi3s] 二开：设置页与卡片底色。上游改用 `ThemeCanvas` 直接铺画布色，
    /// 我方 218 处仍在用这个静态令牌，故保留，由主题的 `canvas`（跟随外观）派生。
    static var pageBackground: Color { ColorThemes.shared.current.palette.canvas }

    // MARK: - Type scale
    static let hero = Font.system(size: 34, weight: .semibold)
    static let title = Font.system(size: 20, weight: .semibold)
    static let heading = Font.system(size: 15, weight: .semibold)
    static let body = Font.body
    static let callout = Font.callout
    static let meta = Font.caption
    static let metaFixed = Font.system(size: 11)
    static let badge = Font.system(size: 11, weight: .semibold, design: .rounded)

    /// Yingxia's own credit. Third-party notices keep their authors' copyright lines unchanged.
    static let copyright = "© 2026 getmegaportal.com"
    static let website = URL(string: "https://www.getmegaportal.com")!
}
