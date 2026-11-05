import SwiftUI

// Content-first surfaces: neutral backgrounds, quiet controls, and strong selection contrast.

/// The icon's navy canvases with neutral controls: the active state is light on dark (dark on light),
/// never a hue, so it reads the same on Liquid Glass.
enum Brand {
    static let pageBackground = Color(light: Color(white: 0.97), dark: Color(white: 0.07))
    static let accent = Color(light: Color(white: 0.12), dark: Color(white: 0.92))
    static let onAccent = Color(light: .white, dark: Color(white: 0.06))
    static let cyan = Color(red: 0.30, green: 0.78, blue: 1.0)
    static let indigo = Color(red: 0.42, green: 0.50, blue: 1.0)
    static let teal = Color(red: 0.20, green: 0.84, blue: 0.80)
    static let amber = Color(red: 1.0, green: 0.76, blue: 0.30)
    static let rose = Color(red: 0.95, green: 0.38, blue: 0.42)

    // MARK: - Type scale
    static let hero = Font.system(size: 34, weight: .semibold)
    static let title = Font.system(size: 20, weight: .semibold)
    static let heading = Font.system(size: 15, weight: .semibold)
    static let body = Font.body
    static let callout = Font.callout
    static let meta = Font.caption
    static let metaFixed = Font.system(size: 11)
    static let badge = Font.system(size: 11, weight: .semibold, design: .rounded)

    static let copyright = "© 2026 getmegaportal.com"
    static let website = URL(string: "https://www.getmegaportal.com")!
}
