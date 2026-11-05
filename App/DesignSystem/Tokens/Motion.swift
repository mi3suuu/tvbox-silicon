import SwiftUI

/// Named animation curves and durations, so interaction feedback is consistent app-wide and every
/// motion respects "Reduce Motion".
enum Motion {
    static let quick: Double = 0.15
    static let standard: Double = 0.2
    static let smooth: Double = 0.3

    static var easeOut: Animation { .easeOut(duration: standard) }
    static var press: Animation { .smooth(duration: quick) }
    static var crossfade: Animation { .smooth(duration: smooth) }

    static func respectingReduceMotion(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}
