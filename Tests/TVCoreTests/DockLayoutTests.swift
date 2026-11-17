import Foundation
import Testing
import CoreGraphics
@testable import TVCore

/// Tiling rules for the dock: tiles must not overlap, must stay on screen,
/// must keep the video aspect ratio, and offsets must align to bottom-right.
@Suite("DockLayout")
struct DockLayoutTests {

    private let screen = CGSize(width: 466, height: 678)

    @Test func tilesNeverOverlap() {
        for n in 2...8 {
            let tiles = DockLayout.tiles(count: n, in: screen, aspect: 0.5625)
            #expect(tiles.count == n)
            for i in 0..<tiles.count {
                for j in (i + 1)..<tiles.count {
                    let a = CGRect(origin: tiles[i].origin, size: tiles[i].size)
                    let b = CGRect(origin: tiles[j].origin, size: tiles[j].size)
                    #expect(!a.intersects(b), "overlap at n=\(n) i=\(i) j=\(j)")
                }
            }
        }
    }

    @Test func everyTileStaysInsideTheContainer() {
        for n in 1...8 {
            let tiles = DockLayout.tiles(count: n, in: screen, aspect: 0.5625)
            for (i, t) in tiles.enumerated() {
                let right = t.origin.x + t.size.width
                let bottom = t.origin.y + t.size.height
                #expect(t.origin.x >= -0.5, "left edge out at n=\(n) i=\(i)")
                #expect(t.origin.y >= -0.5, "top edge out at n=\(n) i=\(i)")
                #expect(right <= screen.width + 0.5, "right edge out at n=\(n) i=\(i)")
                #expect(bottom <= screen.height + 0.5, "bottom edge out at n=\(n) i=\(i)")
            }
        }
    }

    @Test func tilesKeepTheAspectRatio() {
        let aspect: CGFloat = 0.5625
        for n in 1...8 {
            for t in DockLayout.tiles(count: n, in: screen, aspect: aspect) {
                let got = t.size.width / max(t.size.height, 0.001)
                #expect(abs(got - aspect) < 0.02, "aspect \(got) drifted at n=\(n)")
            }
        }
    }

    /// The offset must be the exact vector from container bottom-right to the
    /// tile's bottom-right corner: adding it back must land on the tile corner.
    ///
    /// Note this does NOT claim the tile corner equals the container corner --
    /// tiling centres the grid, so tiles generally sit away from the edges.
    @Test func offsetConversionIsReversible() {
        let tiles = DockLayout.tiles(count: 4, in: screen, aspect: 0.5625)
        for t in tiles {
            let o = DockLayout.offset(for: t, in: screen)
            // Where the tile lands if anchored at container bottom-right.
            let landedX = screen.width + o.width
            let landedY = screen.height + o.height
            #expect(abs(landedX - (t.origin.x + t.size.width)) < 0.001)
            #expect(abs(landedY - (t.origin.y + t.size.height)) < 0.001)
        }
    }

    @Test func degenerateInputsReturnNothing() {
        #expect(DockLayout.tiles(count: 0, in: screen, aspect: 0.5625).isEmpty)
        #expect(DockLayout.tiles(count: 3, in: .zero, aspect: 0.5625).isEmpty)
        #expect(DockLayout.tiles(count: 3, in: CGSize(width: 1, height: 1), aspect: 0.5625).isEmpty)
    }

    @Test func singleTileUsesTheSpace() {
        let t = DockLayout.tiles(count: 1, in: screen, aspect: 0.5625)
        #expect(t.count == 1)
        #expect(t[0].size.width > screen.width * 0.5)
    }
}
