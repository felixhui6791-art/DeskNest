import Foundation
import CoreGraphics
import Testing
@testable import DeskNest

struct SnapEngineTests {
    private let screen = CGRect(x: 0, y: 0, width: 1200, height: 1000)

    @Test
    func gridUsesTopLeftOriginOnNegativeCoordinateDisplay() {
        let display = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let frame = CGRect(x: -1127, y: 337, width: 250, height: 170)
        let result = SnapEngine.snap(frame: frame, in: display, neighbors: [], obstacles: [])

        #expect(!result.blocked)
        #expect(result.frame == CGRect(x: -1120, y: 330, width: 250, height: 170))
        #expect(result.guides.isEmpty)
    }

    @Test
    func exactThresholdAlignsBeforeGridAndOutsideThresholdUsesGrid() {
        let neighbor = CGRect(x: 213, y: 450, width: 100, height: 100)
        let atThreshold = SnapEngine.snap(frame: CGRect(x: 225, y: 600, width: 100, height: 100),
                                          in: screen, neighbors: [neighbor], obstacles: [])
        let outside = SnapEngine.snap(frame: CGRect(x: 226, y: 600, width: 100, height: 100),
                                      in: screen, neighbors: [neighbor], obstacles: [])

        #expect(atThreshold.frame.minX == 213)
        #expect(atThreshold.guides.contains { $0.axis == .vertical && $0.position == 213 })
        #expect(outside.frame.minX == 220)
        #expect(outside.guides.isEmpty)
    }

    @Test
    func alignsToScreenMarginsAndPreventsOffscreenDrop() {
        let near = SnapEngine.snap(frame: CGRect(x: 30, y: 771, width: 200, height: 200),
                                   in: screen, neighbors: [], obstacles: [])
        let outside = SnapEngine.snap(frame: CGRect(x: -400, y: 1300, width: 200, height: 200),
                                      in: screen, neighbors: [], obstacles: [])

        #expect(near.frame == CGRect(x: 20, y: 780, width: 200, height: 200))
        #expect(near.guides.count == 2)
        #expect(outside.frame == CGRect(x: 20, y: 780, width: 200, height: 200))
        #expect(!outside.blocked)
    }

    @Test
    func snapsToSixteenPointGapBesideNeighbor() {
        let neighbor = CGRect(x: 200, y: 400, width: 100, height: 200)
        let result = SnapEngine.snap(frame: CGRect(x: 324, y: 400, width: 100, height: 200),
                                     in: screen, neighbors: [neighbor], obstacles: [])

        #expect(!result.blocked)
        #expect(result.frame.minX - neighbor.maxX == 16)
        #expect(result.guides.contains { $0.axis == .vertical && $0.position == 316 })
    }

    @Test
    func shallowObstacleOverlapCanRecoverLocally() {
        let obstacle = CGRect(x: 200, y: 300, width: 100, height: 400)
        let proposed = CGRect(x: 280, y: 400, width: 100, height: 100)
        let result = SnapEngine.snap(frame: proposed, in: screen, neighbors: [], obstacles: [obstacle])

        #expect(!result.blocked)
        #expect(result.frame.minX == obstacle.maxX)
        #expect(result.frame.minY == proposed.minY)
        #expect(!hasOverlap(result.frame, obstacle))
    }

    @Test
    func deepObstacleOverlapIsBlockedInsteadOfTeleporting() {
        let obstacle = CGRect(x: 200, y: 200, width: 400, height: 400)
        let proposed = CGRect(x: 320, y: 320, width: 100, height: 100)
        let result = SnapEngine.snap(frame: proposed, in: screen, neighbors: [], obstacles: [obstacle])

        #expect(result.blocked)
        #expect(result.frame == proposed)
        #expect(result.guides.isEmpty)
    }

    @Test
    func fullDesktopReturnsBlockedAndPlacementReturnsNil() {
        let proposed = CGRect(x: 100, y: 100, width: 240, height: 200)
        let result = SnapEngine.snap(frame: proposed, in: screen, neighbors: [], obstacles: [screen])

        #expect(result.blocked)
        #expect(SnapEngine.place(size: proposed.size, in: screen, occupied: [screen]) == nil)
    }

    @Test
    func placementScansTopRowBeforeNextRowAndKeepsGap() throws {
        let display = CGRect(x: -800, y: 0, width: 800, height: 600)
        let first = try #require(SnapEngine.place(size: CGSize(width: 240, height: 200),
                                                 in: display, occupied: []))
        let second = try #require(SnapEngine.place(size: first.size, in: display, occupied: [first]))

        #expect(first == CGRect(x: -780, y: 380, width: 240, height: 200))
        #expect(second.minY == first.minY)
        #expect(second.minX - first.maxX == 16)
        #expect(!hasOverlap(first, second))
    }

    @Test
    func placementUsesPreferredFreeOriginAndFallsBackWhenOccupied() throws {
        let size = CGSize(width: 200, height: 200)
        let preferred = CGPoint(x: 500, y: 400)
        let first = try #require(SnapEngine.place(size: size, in: screen, occupied: [], preferredOrigin: preferred))
        let fallback = try #require(SnapEngine.place(size: size, in: screen, occupied: [first], preferredOrigin: preferred))

        #expect(first.origin == preferred)
        #expect(fallback.origin == CGPoint(x: 20, y: 780))
    }

    @Test
    func resizeKeepsTopLeftAndEnforcesMinimumSize() {
        let proposed = CGRect(x: 200, y: 500, width: 100, height: 100)
        let result = SnapEngine.resize(frame: proposed, in: screen, neighbors: [], obstacles: [],
                                       minimumSize: CGSize(width: 240, height: 200))

        #expect(!result.blocked)
        #expect(result.frame.minX == proposed.minX)
        #expect(result.frame.maxY == proposed.maxY)
        #expect(result.frame.size == CGSize(width: 240, height: 200))
    }

    @Test
    func resizeClampsRightAndBottomToVisibleScreen() {
        let proposed = CGRect(x: 200, y: -100, width: 1200, height: 700)
        let result = SnapEngine.resize(frame: proposed, in: screen, neighbors: [], obstacles: [],
                                       minimumSize: CGSize(width: 240, height: 200))

        #expect(!result.blocked)
        #expect(result.frame.minX == 200)
        #expect(result.frame.maxY == 600)
        #expect(result.frame.maxX == 1180)
        #expect(result.frame.minY == 20)
    }

    @Test
    func resizeAlignsMovingEdgeWithoutMovingAnchor() {
        let neighbor = CGRect(x: 513, y: 300, width: 200, height: 200)
        let proposed = CGRect(x: 200, y: 540, width: 303, height: 200)
        let result = SnapEngine.resize(frame: proposed, in: screen, neighbors: [neighbor], obstacles: [],
                                       minimumSize: CGSize(width: 240, height: 200))

        #expect(!result.blocked)
        #expect(result.frame.minX == proposed.minX)
        #expect(result.frame.maxY == proposed.maxY)
        #expect(result.frame.maxX == 497)
        #expect(result.guides.contains { $0.axis == .vertical && $0.position == 497 })
    }

    @Test
    func resizeRecoversAtObstacleButRejectsImpossibleMinimumSize() {
        let obstacle = CGRect(x: 500, y: 200, width: 300, height: 600)
        let shallow = CGRect(x: 200, y: 400, width: 320, height: 200)
        let recovered = SnapEngine.resize(frame: shallow, in: screen, neighbors: [], obstacles: [obstacle],
                                          minimumSize: CGSize(width: 240, height: 200))
        let impossible = SnapEngine.resize(frame: shallow, in: screen, neighbors: [], obstacles: [obstacle],
                                           minimumSize: CGSize(width: 340, height: 200))

        #expect(!recovered.blocked)
        #expect(recovered.frame.maxX == obstacle.minX)
        #expect(recovered.frame.minX == shallow.minX)
        #expect(recovered.frame.maxY == shallow.maxY)
        #expect(!hasOverlap(recovered.frame, obstacle))
        #expect(impossible.blocked)
        #expect(impossible.frame == shallow)
    }

    @Test
    func oversizedPanelCannotBePlacedOrSnapped() {
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 1200)
        #expect(SnapEngine.snap(frame: frame, in: screen, neighbors: [], obstacles: []).blocked)
        #expect(SnapEngine.place(size: frame.size, in: screen, occupied: []) == nil)
    }

    @Test
    func disabledSnappingPreservesFreePositionAndStillAvoidsObstacles() {
        let configuration = SnapConfiguration(gridSize: 0, threshold: 0)
        let proposed = CGRect(x: 223, y: 397, width: 200, height: 200)
        let neighbor = CGRect(x: 230, y: 100, width: 200, height: 200)
        let free = SnapEngine.snap(frame: proposed, in: screen, neighbors: [neighbor], obstacles: [],
                                   configuration: configuration)
        let blocked = SnapEngine.snap(frame: proposed, in: screen, neighbors: [], obstacles: [screen],
                                      configuration: configuration)

        #expect(!free.blocked)
        #expect(free.frame == proposed)
        #expect(free.guides.isEmpty)
        #expect(blocked.blocked)
        #expect(SnapEngine.place(size: proposed.size, in: screen, occupied: [], configuration: configuration) != nil)
    }

    private func hasOverlap(_ first: CGRect, _ second: CGRect) -> Bool {
        let intersection = first.intersection(second)
        return !intersection.isNull && intersection.width > 0 && intersection.height > 0
    }
}
