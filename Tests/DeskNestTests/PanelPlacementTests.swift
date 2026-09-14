import CoreGraphics
import Testing
@testable import DeskNest

struct PanelPlacementTests {
    @Test
    func oversizedBottomRightResizeKeepsOriginalTopLeftCorner() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 1000)
        let initial = CGRect(x: 600, y: 300, width: 350, height: 306)
        let proposed = CGRect(x: initial.minX, y: initial.maxY - 1600, width: 1800, height: 1600)
        let raw = PanelPlacement.clampBottomRightResize(
            proposed, anchoredAt: initial, in: screen, minimumSize: CGSize(width: 280, height: 230)
        )
        let snapped = SnapEngine.resize(frame: raw, in: screen, neighbors: [], obstacles: [],
                                        minimumSize: CGSize(width: 280, height: 230))

        #expect(raw == CGRect(x: 600, y: 20, width: 580, height: 586))
        #expect(!snapped.blocked)
        #expect(snapped.frame.minX == initial.minX)
        #expect(snapped.frame.maxY == initial.maxY)
        #expect(snapped.frame.maxX <= screen.maxX - 20)
        #expect(snapped.frame.minY >= screen.minY + 20)
    }

    @Test
    func resizeBoundsAndMinimumSizePreserveAnchorOnNegativeCoordinateScreen() {
        let screen = CGRect(x: -1600, y: -250, width: 1600, height: 1000)
        let initial = CGRect(x: -1100, y: 200, width: 350, height: 306)
        let minimum = CGSize(width: 280, height: 230)
        let oversized = PanelPlacement.clampBottomRightResize(
            CGRect(x: initial.minX, y: initial.maxY - 2000, width: 3000, height: 2000),
            anchoredAt: initial, in: screen, minimumSize: minimum
        )
        let undersized = PanelPlacement.clampBottomRightResize(
            CGRect(x: initial.minX, y: initial.maxY - 10, width: 10, height: 10),
            anchoredAt: initial, in: screen, minimumSize: minimum
        )

        #expect(oversized == CGRect(x: -1100, y: -230, width: 1080, height: 736))
        #expect(undersized.size == minimum)
        #expect(undersized.minX == initial.minX)
        #expect(undersized.maxY == initial.maxY)
    }
}
