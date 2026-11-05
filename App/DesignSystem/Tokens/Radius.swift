import SwiftUI

/// Corner radii for the app's continuous-rounded rectangles, so a card, a panel and a chip that
/// should feel alike share one value. Always pair with `.continuous`.
enum Radius {
    static let small: CGFloat = 6
    static let medium: CGFloat = 10
    static let card: CGFloat = 12
    static let large: CGFloat = 16
    static let hero: CGFloat = 22
    static let round: CGFloat = 999
}
