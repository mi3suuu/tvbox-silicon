import SwiftUI

/// Layout constants that differ per platform (phone / Mac / Apple TV). These are the few numbers
/// that shape a page's grid and gutters; spacing *between* elements uses `Spacing` instead.
enum Layout {
    #if os(tvOS)
    static let gutter: CGFloat = 64, posterMin: CGFloat = 240, cardMin: CGFloat = 480, tileMin: CGFloat = 340
    static let heroTitle: CGFloat = 68, detailPoster: CGFloat = 300, episodeMin: CGFloat = 200
    #elseif os(macOS)
    static let gutter: CGFloat = 24, posterMin: CGFloat = 174, cardMin: CGFloat = 280, tileMin: CGFloat = 220
    static let heroTitle: CGFloat = 48, detailPoster: CGFloat = 210, episodeMin: CGFloat = 120
    #else
    static let gutter: CGFloat = 16, posterMin: CGFloat = 104, cardMin: CGFloat = 280, tileMin: CGFloat = 160
    static let heroTitle: CGFloat = 34, detailPoster: CGFloat = 130, episodeMin: CGFloat = 90
    #endif
    #if os(tvOS)
    static let gridSpacing: CGFloat = 40, gridRowSpacing: CGFloat = 48
    #elseif os(macOS)
    static let gridSpacing: CGFloat = 18, gridRowSpacing: CGFloat = 22
    #else
    static let gridSpacing: CGFloat = 10, gridRowSpacing: CGFloat = 18
    #endif
    #if os(tvOS)
    static let sectionSpacing: CGFloat = 72, headerSpacing: CGFloat = 24, cardSpacing: CGFloat = 40
    #elseif os(macOS)
    static let sectionSpacing: CGFloat = 40, headerSpacing: CGFloat = 14, cardSpacing: CGFloat = 16
    #else
    static let sectionSpacing: CGFloat = 32, headerSpacing: CGFloat = 12, cardSpacing: CGFloat = 12
    #endif
    static var cardColumns: [GridItem] {
        [GridItem(.adaptive(minimum: cardMin), spacing: cardSpacing)]
    }
    static var posterColumns: [GridItem] {
        [GridItem(.adaptive(minimum: posterMin), spacing: gridSpacing, alignment: .top)]
    }
    #if os(tvOS)
    static let maxWidth: CGFloat = 1800
    static let settingsWidth: CGFloat = 1200
    #else
    static let maxWidth: CGFloat = 1240
    static let settingsWidth: CGFloat = 760
    #endif
}
