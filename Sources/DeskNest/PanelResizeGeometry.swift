import CoreGraphics

enum PanelResizeDirection: CaseIterable, Sendable, Equatable {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight

    var movesLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var movesRight: Bool { self == .right || self == .topRight || self == .bottomRight }
    var movesTop: Bool { self == .top || self == .topLeft || self == .topRight }
    var movesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
}

/// Resizes in AppKit screen coordinates, where positive y points up.
/// Always apply the total pointer translation to the frame at the start of a drag.
enum PanelResizeGeometry {
    static let minimumSize = CGSize(width: 160, height: 140)

    static func frame(
        from initial: CGRect,
        translation: CGSize,
        direction: PanelResizeDirection,
        in visibleFrame: CGRect,
        minimumSize: CGSize = minimumSize,
        margin: CGFloat = 20
    ) -> CGRect {
        guard valid(initial), valid(visibleFrame),
              translation.width.isFinite, translation.height.isFinite,
              minimumSize.width.isFinite, minimumSize.height.isFinite,
              minimumSize.width > 0, minimumSize.height > 0,
              margin.isFinite, margin >= 0 else { return initial }
        let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
        guard valid(bounds) else { return initial }

        var left = initial.minX
        var right = initial.maxX
        var bottom = initial.minY
        var top = initial.maxY

        if direction.movesLeft {
            let limit = right - minimumSize.width
            guard limit >= bounds.minX, right <= bounds.maxX else { return initial }
            left = clamp(initial.minX + translation.width, bounds.minX, limit)
        } else if direction.movesRight {
            let limit = left + minimumSize.width
            guard limit <= bounds.maxX, left >= bounds.minX else { return initial }
            right = clamp(initial.maxX + translation.width, limit, bounds.maxX)
        }

        if direction.movesBottom {
            let limit = top - minimumSize.height
            guard limit >= bounds.minY, top <= bounds.maxY else { return initial }
            bottom = clamp(initial.minY + translation.height, bounds.minY, limit)
        } else if direction.movesTop {
            let limit = bottom + minimumSize.height
            guard limit <= bounds.maxY, bottom >= bounds.minY else { return initial }
            top = clamp(initial.maxY + translation.height, limit, bounds.maxY)
        }

        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }

    private static func valid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }
}
