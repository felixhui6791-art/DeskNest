import Foundation
import CoreGraphics

enum SnapGuideAxis: Equatable, Sendable {
    case vertical, horizontal
}

struct SnapGuide: Equatable, Sendable {
    var axis: SnapGuideAxis
    var position: CGFloat
    var start: CGFloat
    var end: CGFloat
}

struct SnapResult: Equatable, Sendable {
    var frame: CGRect
    var guides: [SnapGuide]
    var blocked: Bool
}

struct SnapConfiguration: Sendable {
    var gridSize: CGFloat
    var threshold: CGFloat
    var margin: CGFloat
    var gap: CGFloat

    init(gridSize: CGFloat = 20, threshold: CGFloat = 12, margin: CGFloat = 20, gap: CGFloat = 16) {
        self.gridSize = gridSize.isFinite ? max(0, gridSize) : 20
        self.threshold = threshold.isFinite ? max(0, threshold) : 12
        self.margin = margin.isFinite ? max(0, margin) : 20
        self.gap = gap.isFinite ? max(0, gap) : 16
    }
}

/// Geometry uses AppKit's global screen coordinates: increasing y points upwards.
enum SnapEngine {
    /// Neighbors provide alignment targets; only obstacles forbid overlap.
    static func snap(
        frame: CGRect,
        in visibleFrame: CGRect,
        neighbors: [CGRect],
        obstacles: [CGRect],
        configuration: SnapConfiguration = SnapConfiguration()
    ) -> SnapResult {
        let bounds = visibleFrame.insetBy(dx: configuration.margin, dy: configuration.margin)
        guard valid(frame), valid(bounds), frame.width <= bounds.width, frame.height <= bounds.height else {
            return blocked(frame)
        }
        let targets = (neighbors + obstacles).filter(valid)
        let barriers = obstacles.filter(valid)
        let x = clamp(frame.minX, bounds.minX, bounds.maxX - frame.width)
        let y = clamp(frame.minY, bounds.minY, bounds.maxY - frame.height)
        var xs = baseOptions(value: x, gridOrigin: bounds.minX, lower: bounds.minX,
                             upper: bounds.maxX - frame.width, configuration: configuration)
        // Align the top edge to the grid, irrespective of this panel's height.
        var ys = baseOptions(value: y, gridOrigin: bounds.maxY - frame.height, lower: bounds.minY,
                             upper: bounds.maxY - frame.height, configuration: configuration)
        add(&xs, value: bounds.minX, position: bounds.minX, span: bounds.minY...bounds.maxY,
            proposed: x, configuration: configuration)
        add(&xs, value: bounds.maxX - frame.width, position: bounds.maxX, span: bounds.minY...bounds.maxY,
            proposed: x, configuration: configuration)
        add(&ys, value: bounds.minY, position: bounds.minY, span: bounds.minX...bounds.maxX,
            proposed: y, configuration: configuration)
        add(&ys, value: bounds.maxY - frame.height, position: bounds.maxY, span: bounds.minX...bounds.maxX,
            proposed: y, configuration: configuration)
        for target in targets {
            for edge in [target.minX, target.maxX] {
                add(&xs, value: edge, position: edge, span: target.minY...target.maxY,
                    proposed: x, configuration: configuration)
                add(&xs, value: edge - frame.width, position: edge, span: target.minY...target.maxY,
                    proposed: x, configuration: configuration)
            }
            for edge in [target.minY, target.maxY] {
                add(&ys, value: edge, position: edge, span: target.minX...target.maxX,
                    proposed: y, configuration: configuration)
                add(&ys, value: edge - frame.height, position: edge, span: target.minX...target.maxX,
                    proposed: y, configuration: configuration)
            }
            add(&xs, value: target.maxX + configuration.gap, position: target.maxX + configuration.gap,
                span: target.minY...target.maxY, proposed: x, configuration: configuration)
            add(&xs, value: target.minX - configuration.gap - frame.width,
                position: target.minX - configuration.gap, span: target.minY...target.maxY,
                proposed: x, configuration: configuration)
            add(&ys, value: target.maxY + configuration.gap, position: target.maxY + configuration.gap,
                span: target.minX...target.maxX, proposed: y, configuration: configuration)
            add(&ys, value: target.minY - configuration.gap - frame.height,
                position: target.minY - configuration.gap, span: target.minX...target.maxX,
                proposed: y, configuration: configuration)
        }
        // A shallow accidental overlap can slide to the obstacle's outside edge.
        // Larger overlaps are rejected instead of moving a panel across the desktop.
        for barrier in barriers {
            for gap in [configuration.gap, 0] {
                recover(&xs, values: [barrier.maxX + gap, barrier.minX - gap - frame.width],
                        proposed: x, configuration: configuration, rank: gap == 0 ? 4 : 3)
                recover(&ys, values: [barrier.maxY + gap, barrier.minY - gap - frame.height],
                        proposed: y, configuration: configuration, rank: gap == 0 ? 4 : 3)
            }
        }
        return choose(xs: xs, ys: ys, original: frame, bounds: bounds, obstacles: barriers) { x, y in
            CGRect(origin: CGPoint(x: x, y: y), size: frame.size)
        }
    }

    /// Snaps only the dragged edges. Opposite edges and inactive axes stay fixed.
    static func resize(
        frame: CGRect,
        in visibleFrame: CGRect,
        neighbors: [CGRect],
        obstacles: [CGRect],
        minimumSize: CGSize,
        direction: PanelResizeDirection = .bottomRight,
        configuration: SnapConfiguration = SnapConfiguration()
    ) -> SnapResult {
        let bounds = visibleFrame.insetBy(dx: configuration.margin, dy: configuration.margin)
        guard valid(frame), valid(bounds), minimumSize.width.isFinite, minimumSize.height.isFinite,
              minimumSize.width > 0, minimumSize.height > 0 else {
            return blocked(frame)
        }
        let raw = PanelResizeGeometry.frame(from: frame, translation: .zero, direction: direction,
                                            in: visibleFrame, minimumSize: minimumSize,
                                            margin: configuration.margin)
        let movesX = direction.movesLeft || direction.movesRight
        let movesY = direction.movesTop || direction.movesBottom
        guard contains(bounds, raw),
              !movesX || raw.width >= minimumSize.width - 0.001,
              !movesY || raw.height >= minimumSize.height - 0.001 else { return blocked(frame) }

        let movingX = direction.movesLeft ? raw.minX : raw.maxX
        let movingY = direction.movesBottom ? raw.minY : raw.maxY
        let lowerX = direction.movesLeft ? bounds.minX : raw.minX + minimumSize.width
        let upperX = direction.movesLeft ? raw.maxX - minimumSize.width : bounds.maxX
        let lowerY = direction.movesBottom ? bounds.minY : raw.minY + minimumSize.height
        let upperY = direction.movesBottom ? raw.maxY - minimumSize.height : bounds.maxY
        var xs = movesX
            ? baseOptions(value: movingX, gridOrigin: bounds.minX, lower: lowerX, upper: upperX,
                          configuration: configuration)
            : [Option(value: movingX, rank: 2)]
        var ys = movesY
            ? baseOptions(value: movingY, gridOrigin: bounds.maxY, lower: lowerY, upper: upperY,
                          configuration: configuration)
            : [Option(value: movingY, rank: 2)]
        if movesX {
            let edge = direction.movesLeft ? bounds.minX : bounds.maxX
            add(&xs, value: edge, position: edge, span: bounds.minY...bounds.maxY,
                proposed: movingX, configuration: configuration)
        }
        if movesY {
            let edge = direction.movesBottom ? bounds.minY : bounds.maxY
            add(&ys, value: edge, position: edge, span: bounds.minX...bounds.maxX,
                proposed: movingY, configuration: configuration)
        }
        for target in (neighbors + obstacles).filter(valid) {
            if movesX {
                let outside = direction.movesLeft ? target.maxX + configuration.gap : target.minX - configuration.gap
                for edge in [target.minX, target.maxX, outside] {
                    add(&xs, value: edge, position: edge, span: target.minY...target.maxY,
                        proposed: movingX, configuration: configuration)
                }
            }
            if movesY {
                let outside = direction.movesBottom ? target.maxY + configuration.gap : target.minY - configuration.gap
                for edge in [target.minY, target.maxY, outside] {
                    add(&ys, value: edge, position: edge, span: target.minX...target.maxX,
                        proposed: movingY, configuration: configuration)
                }
            }
        }
        let barriers = obstacles.filter(valid)
        for barrier in barriers {
            if movesX {
                let values = direction.movesLeft
                    ? [barrier.maxX + configuration.gap, barrier.maxX]
                    : [barrier.minX - configuration.gap, barrier.minX]
                recover(&xs, values: values, proposed: movingX, configuration: configuration, rank: 3)
            }
            if movesY {
                let values = direction.movesBottom
                    ? [barrier.maxY + configuration.gap, barrier.maxY]
                    : [barrier.minY - configuration.gap, barrier.minY]
                recover(&ys, values: values, proposed: movingY, configuration: configuration, rank: 3)
            }
        }
        let result = choose(xs: xs, ys: ys, original: frame, bounds: bounds, obstacles: barriers) { x, y in
            guard !movesX || (x >= lowerX && x <= upperX),
                  !movesY || (y >= lowerY && y <= upperY) else { return nil }
            let left = direction.movesLeft ? x : raw.minX
            let right = direction.movesRight ? x : raw.maxX
            let bottom = direction.movesBottom ? y : raw.minY
            let top = direction.movesTop ? y : raw.maxY
            return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
        }
        // A legal pointer position must never be rejected merely because its nearby
        // snap targets overlap an obstacle or would cross the minimum size.
        if result.blocked && !barriers.contains(where: { overlaps(raw, $0) }) {
            return SnapResult(frame: raw, guides: [], blocked: false)
        }
        return result
    }

    /// Finds a free position, scanning rows from top-left. Occupied panels keep the configured gap.
    static func place(
        size: CGSize,
        in visibleFrame: CGRect,
        occupied: [CGRect],
        preferredOrigin: CGPoint? = nil,
        configuration: SnapConfiguration = SnapConfiguration()
    ) -> CGRect? {
        let bounds = visibleFrame.insetBy(dx: configuration.margin, dy: configuration.margin)
        guard valid(CGRect(origin: .zero, size: size)), valid(bounds),
              size.width <= bounds.width, size.height <= bounds.height else { return nil }
        let barriers = occupied.filter(valid).map { $0.insetBy(dx: -configuration.gap, dy: -configuration.gap) }
        func available(_ origin: CGPoint) -> CGRect? {
            let frame = CGRect(origin: origin, size: size)
            return contains(bounds, frame) && !barriers.contains(where: { overlaps(frame, $0) }) ? frame : nil
        }
        if let origin = preferredOrigin, origin.x.isFinite, origin.y.isFinite {
            let x = clamp(grid(origin.x, origin: bounds.minX, size: configuration.gridSize),
                          bounds.minX, bounds.maxX - size.width)
            let y = clamp(grid(origin.y, origin: bounds.maxY - size.height, size: configuration.gridSize),
                          bounds.minY, bounds.maxY - size.height)
            if let frame = available(CGPoint(x: x, y: y)) { return frame }
        }
        let scanStep = configuration.gridSize > 0 ? configuration.gridSize : 20
        var xs = steps(from: bounds.minX, through: bounds.maxX - size.width, by: scanStep)
        var ys = steps(from: bounds.minY, through: bounds.maxY - size.height, by: scanStep)
            .map { bounds.maxY - size.height - ($0 - bounds.minY) }
        // Also inspect obstacle edges so narrow free spaces between grid lines are usable.
        xs += barriers.flatMap { [$0.maxX, $0.minX - size.width] }
        ys += barriers.flatMap { [$0.maxY, $0.minY - size.height] }
        xs = Array(Set(xs.filter { $0 >= bounds.minX && $0 <= bounds.maxX - size.width })).sorted()
        ys = Array(Set(ys.filter { $0 >= bounds.minY && $0 <= bounds.maxY - size.height })).sorted(by: >)
        for y in ys {
            for x in xs {
                if let frame = available(CGPoint(x: x, y: y)) { return frame }
            }
        }
        return nil
    }

    private struct Option {
        var value: CGFloat
        var rank: Int
        var position: CGFloat? = nil
        var span: ClosedRange<CGFloat>? = nil
    }

    private static func baseOptions(value: CGFloat, gridOrigin: CGFloat, lower: CGFloat, upper: CGFloat,
                                    configuration: SnapConfiguration) -> [Option] {
        [Option(value: clamp(grid(value, origin: gridOrigin, size: configuration.gridSize), lower, upper), rank: 1),
         Option(value: value, rank: 2)]
    }

    private static func add(_ options: inout [Option], value: CGFloat, position: CGFloat,
                            span: ClosedRange<CGFloat>, proposed: CGFloat, configuration: SnapConfiguration) {
        if configuration.threshold > 0 && abs(value - proposed) <= configuration.threshold + 0.001 {
            options.append(Option(value: value, rank: 0, position: position, span: span))
        }
    }

    private static func recover(_ options: inout [Option], values: [CGFloat], proposed: CGFloat,
                                configuration: SnapConfiguration, rank: Int) {
        for value in values where abs(value - proposed) <= configuration.threshold + configuration.gap + 0.001 {
            options.append(Option(value: value, rank: rank))
        }
    }

    private static func choose(xs: [Option], ys: [Option], original: CGRect, bounds: CGRect,
                               obstacles: [CGRect], makeFrame: (CGFloat, CGFloat) -> CGRect?) -> SnapResult {
        var best: (frame: CGRect, x: Option, y: Option, rank: Int, alignments: Int, distance: CGFloat)?
        for x in xs {
            for y in ys {
                guard let frame = makeFrame(x.value, y.value), valid(frame), contains(bounds, frame),
                      !obstacles.contains(where: { overlaps(frame, $0) }) else { continue }
                let rank = x.rank + y.rank
                let alignments = (x.rank == 0 ? 1 : 0) + (y.rank == 0 ? 1 : 0)
                let distance = pow(frame.minX - original.minX, 2) + pow(frame.minY - original.minY, 2)
                    + pow(frame.width - original.width, 2) + pow(frame.height - original.height, 2)
                if let current = best {
                    if rank > current.rank { continue }
                    if rank == current.rank && alignments < current.alignments { continue }
                    if rank == current.rank && alignments == current.alignments && distance >= current.distance { continue }
                }
                best = (frame, x, y, rank, alignments, distance)
            }
        }
        guard let best else { return blocked(original) }
        var guides: [SnapGuide] = []
        if let position = best.x.position, let span = best.x.span {
            guides.append(SnapGuide(axis: .vertical, position: position,
                                    start: min(best.frame.minY, span.lowerBound), end: max(best.frame.maxY, span.upperBound)))
        }
        if let position = best.y.position, let span = best.y.span {
            guides.append(SnapGuide(axis: .horizontal, position: position,
                                    start: min(best.frame.minX, span.lowerBound), end: max(best.frame.maxX, span.upperBound)))
        }
        return SnapResult(frame: best.frame, guides: guides, blocked: false)
    }

    private static func blocked(_ frame: CGRect) -> SnapResult {
        SnapResult(frame: frame, guides: [], blocked: true)
    }

    private static func grid(_ value: CGFloat, origin: CGFloat, size: CGFloat) -> CGFloat {
        guard size > 0 else { return value }
        return origin + ((value - origin) / size).rounded() * size
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }

    private static func valid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }

    private static func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        inner.minX >= outer.minX - 0.001 && inner.maxX <= outer.maxX + 0.001
            && inner.minY >= outer.minY - 0.001 && inner.maxY <= outer.maxY + 0.001
    }

    private static func overlaps(_ first: CGRect, _ second: CGRect) -> Bool {
        min(first.maxX, second.maxX) - max(first.minX, second.minX) > 0.001
            && min(first.maxY, second.maxY) - max(first.minY, second.minY) > 0.001
    }

    private static func steps(from start: CGFloat, through end: CGFloat, by step: CGFloat) -> [CGFloat] {
        var values: [CGFloat] = []
        var value = start
        while value <= end {
            values.append(value)
            value += step
        }
        if values.last != end { values.append(end) }
        return values
    }
}
