import AppKit
import Testing
@testable import DeskNest

struct PanelResizeRegionsTests {
    @Test func allEdgesAndCornersWorkAtTheMinimumSize() {
        let bounds = CGRect(x: 0, y: 0, width: 160, height: 140)
        let cases: [(CGPoint, PanelResizeDirection)] = [
            (CGPoint(x: 4, y: 70), .left), (CGPoint(x: 156, y: 70), .right),
            (CGPoint(x: 80, y: 136), .top), (CGPoint(x: 80, y: 4), .bottom),
            (CGPoint(x: 4, y: 136), .topLeft), (CGPoint(x: 156, y: 136), .topRight),
            (CGPoint(x: 4, y: 4), .bottomLeft), (CGPoint(x: 156, y: 4), .bottomRight)
        ]
        for (point, direction) in cases {
            #expect(PanelResizeRegions.direction(at: point, in: bounds) == direction)
        }
    }

    @Test func titleButtonsAndContentAreNotResizeTargets() {
        let bounds = CGRect(x: 0, y: 0, width: 160, height: 140)
        for point in [CGPoint(x: 80, y: 70), CGPoint(x: 146, y: 126),
                      CGPoint(x: 15, y: 125), CGPoint(x: -1, y: 70), CGPoint(x: 161, y: 70)] {
            #expect(PanelResizeRegions.direction(at: point, in: bounds) == nil)
        }
    }

    @MainActor @Test func hitTestingConvertsContainerCoordinatesAndHonorsLock() {
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let border = PanelResizeBorderView(frame: CGRect(x: 40, y: 60, width: 160, height: 140))
        parent.addSubview(border)
        #expect(border.hitTest(CGPoint(x: 44, y: 130)) === border)
        #expect(border.hitTest(CGPoint(x: 120, y: 130)) == nil)
        border.isEnabled = false
        #expect(border.hitTest(CGPoint(x: 44, y: 130)) == nil)
    }

    @MainActor @Test func hoveringWorksWithoutAKeyWindowAndLockRemovesTracking() {
        let border = PanelResizeBorderView(frame: CGRect(x: 0, y: 0, width: 160, height: 140))
        border.updateTrackingAreas()
        #expect(!border.trackingAreas.isEmpty)
        #expect(border.trackingAreas.allSatisfy { $0.options.contains(.activeAlways) })
        #expect(border.trackingAreas.allSatisfy { $0.options.contains(.mouseMoved) })
        border.isEnabled = false
        #expect(border.trackingAreas.isEmpty)
    }
}
