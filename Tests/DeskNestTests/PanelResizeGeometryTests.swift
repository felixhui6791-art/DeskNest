import CoreGraphics
import Testing
@testable import DeskNest

struct PanelResizeGeometryTests {
    private let screen = CGRect(x: 0, y: 0, width: 1200, height: 1000)
    private let initial = CGRect(x: 200, y: 300, width: 320, height: 260)

    @Test(arguments: PanelResizeDirection.allCases)
    func eightDirectionsMoveOnlyTheirEdges(_ direction: PanelResizeDirection) {
        let frame = PanelResizeGeometry.frame(from: initial, translation: CGSize(width: 37, height: -29),
                                               direction: direction, in: screen)
        let expected: CGRect
        switch direction {
        case .left: expected = CGRect(x: 237, y: 300, width: 283, height: 260)
        case .right: expected = CGRect(x: 200, y: 300, width: 357, height: 260)
        case .top: expected = CGRect(x: 200, y: 300, width: 320, height: 231)
        case .bottom: expected = CGRect(x: 200, y: 271, width: 320, height: 289)
        case .topLeft: expected = CGRect(x: 237, y: 300, width: 283, height: 231)
        case .topRight: expected = CGRect(x: 200, y: 300, width: 357, height: 231)
        case .bottomLeft: expected = CGRect(x: 237, y: 271, width: 283, height: 289)
        case .bottomRight: expected = CGRect(x: 200, y: 271, width: 357, height: 289)
        }
        #expect(frame == expected)
    }

    @Test(arguments: PanelResizeDirection.allCases)
    func minimumSizeClampsActiveEdgesWithoutMovingTheAnchor(_ direction: PanelResizeDirection) {
        let translation = CGSize(width: direction.movesLeft ? 10_000 : -10_000,
                                 height: direction.movesBottom ? 10_000 : -10_000)
        let frame = PanelResizeGeometry.frame(from: initial, translation: translation,
                                               direction: direction, in: screen)
        #expect(frame.width == (movesX(direction) ? 160 : initial.width))
        #expect(frame.height == (movesY(direction) ? 140 : initial.height))
        expectFixedEdges(frame, from: initial, direction: direction)
    }

    @Test
    func continuedShrinkingStaysAtMinimumAndCanGrowAgain() {
        let pointerDistances: [CGFloat] = [80, 159, 160, 161, 300, 900, 161, 160, 159, 80]
        let widths = pointerDistances.map { distance in
            PanelResizeGeometry.frame(from: initial, translation: CGSize(width: -distance, height: 500),
                                      direction: .right, in: screen).width
        }
        #expect(widths == [240, 161, 160, 160, 160, 160, 160, 160, 161, 240])
    }

    @Test(arguments: PanelResizeDirection.allCases)
    func screenLimitsClampMovingEdgesOnly(_ direction: PanelResizeDirection) {
        let translation = CGSize(width: direction.movesLeft ? -10_000 : 10_000,
                                 height: direction.movesBottom ? -10_000 : 10_000)
        let frame = PanelResizeGeometry.frame(from: initial, translation: translation,
                                               direction: direction, in: screen)
        if direction.movesLeft { #expect(frame.minX == 20) }
        if direction.movesRight { #expect(frame.maxX == 1180) }
        if direction.movesBottom { #expect(frame.minY == 20) }
        if direction.movesTop { #expect(frame.maxY == 980) }
        expectFixedEdges(frame, from: initial, direction: direction)
    }

    @Test(arguments: PanelResizeDirection.allCases)
    func negativeCoordinateDisplayUsesTheSameAnchors(_ direction: PanelResizeDirection) {
        let offset = CGSize(width: -1600, height: -900)
        let negativeScreen = screen.offsetBy(dx: offset.width, dy: offset.height)
        let negativeInitial = initial.offsetBy(dx: offset.width, dy: offset.height)
        let translation = CGSize(width: -85, height: 92)
        let positive = PanelResizeGeometry.frame(from: initial, translation: translation,
                                                  direction: direction, in: screen)
        let negative = PanelResizeGeometry.frame(from: negativeInitial, translation: translation,
                                                  direction: direction, in: negativeScreen)
        #expect(negative == positive.offsetBy(dx: offset.width, dy: offset.height))
    }

    @Test
    func singleEdgeDoesNotEnlargeAnAlreadySmallInactiveAxis() {
        let short = CGRect(x: 200, y: 300, width: 320, height: 100)
        let frame = PanelResizeGeometry.frame(from: short, translation: CGSize(width: -100, height: 600),
                                               direction: .right, in: screen)
        #expect(frame == CGRect(x: 200, y: 300, width: 220, height: 100))
    }

    @Test
    func invalidGeometryKeepsTheOriginalFrame() {
        #expect(PanelResizeGeometry.frame(from: initial, translation: CGSize(width: CGFloat.nan, height: 0),
                                         direction: .right, in: screen) == initial)
        #expect(PanelResizeGeometry.frame(from: initial, translation: .zero, direction: .right,
                                         in: screen, minimumSize: CGSize(width: 1600, height: 140)) == initial)
        #expect(PanelResizeGeometry.frame(from: initial, translation: .zero, direction: .right,
                                         in: screen, margin: 700) == initial)
    }

    @Test(arguments: PanelResizeDirection.allCases)
    func gridSnappingPreservesEveryFixedEdge(_ direction: PanelResizeDirection) {
        let proposed = CGRect(x: 203, y: 307, width: 334, height: 254)
        let result = SnapEngine.resize(frame: proposed, in: screen, neighbors: [], obstacles: [],
                                       minimumSize: PanelResizeGeometry.minimumSize, direction: direction)
        #expect(!result.blocked)
        if direction.movesLeft { #expect(result.frame.minX == 200) }
        if direction.movesRight { #expect(result.frame.maxX == 540) }
        if direction.movesBottom { #expect(result.frame.minY == 300) }
        if direction.movesTop { #expect(result.frame.maxY == 560) }
        expectFixedEdges(result.frame, from: proposed, direction: direction)
    }

    @Test(arguments: PanelResizeDirection.allCases)
    func snappingAtMinimumNeverExpandsToTheOldSize(_ direction: PanelResizeDirection) {
        let proposed = PanelResizeGeometry.frame(
            from: initial,
            translation: CGSize(width: direction.movesLeft ? 1000 : -1000,
                                height: direction.movesBottom ? 1000 : -1000),
            direction: direction, in: screen)
        let result = SnapEngine.resize(frame: proposed, in: screen, neighbors: [], obstacles: [],
                                       minimumSize: PanelResizeGeometry.minimumSize, direction: direction)
        #expect(!result.blocked)
        #expect(result.frame == proposed)
        expectFixedEdges(result.frame, from: initial, direction: direction)
    }

    @Test(arguments: [PanelResizeDirection.left, .right, .top, .bottom])
    func singleEdgeSnapDoesNotAddAnInactiveAxisGuide(_ direction: PanelResizeDirection) {
        let proposed = CGRect(x: 203, y: 307, width: 334, height: 254)
        let neighbor = proposed.offsetBy(dx: 5, dy: 5)
        let result = SnapEngine.resize(frame: proposed, in: screen, neighbors: [neighbor], obstacles: [],
                                       minimumSize: PanelResizeGeometry.minimumSize, direction: direction)
        #expect(!result.blocked)
        #expect(result.guides.count == 1)
        #expect(result.guides.first?.axis == (movesX(direction) ? .vertical : .horizontal))
        expectFixedEdges(result.frame, from: proposed, direction: direction)
    }

    @Test
    func legalNarrowFrameSurvivesWhenGridAndNeighborTargetsHitObstacles() {
        let proposed = CGRect(x: 203, y: 307, width: 166, height: 200)
        let obstacle = CGRect(x: 371, y: 300, width: 200, height: 300)
        let neighbor = CGRect(x: 379, y: 750, width: 100, height: 100)
        let result = SnapEngine.resize(frame: proposed, in: screen, neighbors: [neighbor], obstacles: [obstacle],
                                       minimumSize: PanelResizeGeometry.minimumSize, direction: .right)
        #expect(!result.blocked)
        #expect(result.frame.width >= 160)
        #expect(result.frame.maxX <= obstacle.minX)
        expectFixedEdges(result.frame, from: proposed, direction: .right)
    }

    @Test
    func narrowFreePositionIsUsedWhenEveryOtherSnapWouldOverlap() {
        let proposed = CGRect(x: 203, y: 307, width: 166, height: 200)
        // Both aligned targets and the nearest grid point are past the obstacle.
        // The minimum width prevents recovering to the configured outside gap.
        let obstacle = CGRect(x: 369.5, y: 300, width: 200, height: 300)
        let result = SnapEngine.resize(frame: proposed, in: screen, neighbors: [], obstacles: [obstacle],
                                       minimumSize: CGSize(width: 166, height: 140), direction: .right,
                                       configuration: SnapConfiguration(gridSize: 50, threshold: 0, gap: 0))
        #expect(!result.blocked)
        #expect(result.frame == proposed)
    }

    @Test(arguments: [PanelResizeDirection.left, .right, .top, .bottom])
    func shallowObstacleOverlapRecoversAlongTheDraggedEdge(_ direction: PanelResizeDirection) {
        let obstacle: CGRect
        switch direction {
        case .left: obstacle = CGRect(x: 50, y: 300, width: 160, height: 260)
        case .right: obstacle = CGRect(x: 510, y: 300, width: 200, height: 260)
        case .top: obstacle = CGRect(x: 200, y: 550, width: 320, height: 200)
        default: obstacle = CGRect(x: 200, y: 110, width: 320, height: 200)
        }
        let result = SnapEngine.resize(frame: initial, in: screen, neighbors: [], obstacles: [obstacle],
                                       minimumSize: PanelResizeGeometry.minimumSize, direction: direction)
        #expect(!result.blocked)
        let intersection = result.frame.intersection(obstacle)
        #expect(intersection.isNull || intersection.width == 0 || intersection.height == 0)
        expectFixedEdges(result.frame, from: initial, direction: direction)
    }

    @Test
    func singleEdgeSnappingPreservesAnInactiveDimensionBelowTheMinimum() {
        let proposed = CGRect(x: 203, y: 307, width: 334, height: 100)
        let result = SnapEngine.resize(frame: proposed, in: screen, neighbors: [], obstacles: [],
                                       minimumSize: PanelResizeGeometry.minimumSize, direction: .right)
        #expect(!result.blocked)
        #expect(result.frame.height == 100)
        expectFixedEdges(result.frame, from: proposed, direction: .right)
    }

    @Test(arguments: PanelResizeDirection.allCases)
    func fractionalAnchorsDoNotRejectTheMinimumSize(_ direction: PanelResizeDirection) {
        let fractional = CGRect(x: 203.4, y: 307.6, width: 334.2, height: 254.3)
        let proposed = PanelResizeGeometry.frame(
            from: fractional,
            translation: CGSize(width: direction.movesLeft ? 1000 : -1000,
                                height: direction.movesBottom ? 1000 : -1000),
            direction: direction, in: screen)
        let result = SnapEngine.resize(frame: proposed, in: screen, neighbors: [], obstacles: [],
                                       minimumSize: PanelResizeGeometry.minimumSize, direction: direction,
                                       configuration: SnapConfiguration(gridSize: 0, threshold: 0))
        #expect(!result.blocked)
        #expect(abs(result.frame.minX - proposed.minX) < 0.001)
        #expect(abs(result.frame.minY - proposed.minY) < 0.001)
        #expect(abs(result.frame.width - proposed.width) < 0.001)
        #expect(abs(result.frame.height - proposed.height) < 0.001)
    }

    private func movesX(_ direction: PanelResizeDirection) -> Bool {
        direction.movesLeft || direction.movesRight
    }

    private func movesY(_ direction: PanelResizeDirection) -> Bool {
        direction.movesTop || direction.movesBottom
    }

    private func expectFixedEdges(_ frame: CGRect, from initial: CGRect, direction: PanelResizeDirection) {
        if !direction.movesLeft { #expect(frame.minX == initial.minX) }
        if !direction.movesRight { #expect(frame.maxX == initial.maxX) }
        if !direction.movesBottom { #expect(frame.minY == initial.minY) }
        if !direction.movesTop { #expect(frame.maxY == initial.maxY) }
    }
}
