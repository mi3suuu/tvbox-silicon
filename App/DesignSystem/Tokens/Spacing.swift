import SwiftUI

/// A four-step spacing scale for padding and gaps between elements. Named by role, not size, so the
/// same name means the same thing on every platform. Use for space *between* things; page gutters
/// and grid geometry stay in `Layout`.
enum Spacing {
    #if os(tvOS)
    static let tight: CGFloat = 8
    #else
    static let tight: CGFloat = 4
    #endif
    #if os(tvOS)
    static let small: CGFloat = 16
    #else
    static let small: CGFloat = 8
    #endif
    #if os(tvOS)
    static let medium: CGFloat = 28
    #else
    static let medium: CGFloat = 12
    #endif
    #if os(tvOS)
    static let large: CGFloat = 48
    #else
    static let large: CGFloat = 24
    #endif
    #if os(tvOS)
    static let panel: CGFloat = 28
    #else
    static let panel: CGFloat = 16
    #endif
}
