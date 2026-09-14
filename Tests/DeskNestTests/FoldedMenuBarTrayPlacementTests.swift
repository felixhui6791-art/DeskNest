import CoreGraphics
import Testing
@testable import DeskNest

struct FoldedMenuBarTrayPlacementTests {
    @Test func centeredBelowAnchorAndClampedAtRightEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 870)
        let centered = FoldedMenuBarTrayPlacement.frame(
            contentSize: CGSize(width: 360, height: 232),
            anchor: CGRect(x: 700, y: 875, width: 24, height: 24), visibleFrame: screen)
        #expect(centered.midX == 712)
        #expect(centered.maxY == 862)
        let atRightEdge = FoldedMenuBarTrayPlacement.frame(
            contentSize: CGSize(width: 640, height: 232),
            anchor: CGRect(x: 1400, y: 875, width: 24, height: 24), visibleFrame: screen)
        #expect(atRightEdge.maxX == 1432)
        #expect(screen.contains(atRightEdge))
    }

    @Test func negativeOriginDisplayKeepsItsOwnCoordinates() {
        let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1050)
        let frame = FoldedMenuBarTrayPlacement.frame(
            contentSize: CGSize(width: 360, height: 317),
            anchor: CGRect(x: -1890, y: 855, width: 24, height: 24), visibleFrame: screen)
        #expect(frame.minX == -1912)
        #expect(frame.maxY == 842)
        #expect(screen.contains(frame))
    }

    @Test func dynamicContentGrowsDownwardWithoutMovingItsAnchor() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 870)
        let anchor = CGRect(x: 1120, y: 875, width: 24, height: 24)
        let normal = FoldedMenuBarTrayPlacement.frame(
            contentSize: CGSize(width: 360, height: 232), anchor: anchor, visibleFrame: screen)
        let withMessage = FoldedMenuBarTrayPlacement.frame(
            contentSize: CGSize(width: 360, height: 379), anchor: anchor, visibleFrame: screen)
        #expect(normal.maxY == withMessage.maxY)
        #expect(normal.midX == withMessage.midX)
        #expect(withMessage.minY == normal.minY - 147)
    }

    @Test func oversizedContentFitsTheAvailableDisplay() {
        let screen = CGRect(x: 0, y: 80, width: 400, height: 260)
        let frame = FoldedMenuBarTrayPlacement.frame(
            contentSize: CGSize(width: 640, height: 379),
            anchor: CGRect(x: 350, y: 345, width: 24, height: 24), visibleFrame: screen)
        #expect(frame == screen.insetBy(dx: 8, dy: 8))
    }
}
