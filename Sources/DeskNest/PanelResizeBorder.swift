import AppKit

/// The content fills the requested frame; only the narrow perimeter intercepts
/// pointer events. File selection, scrolling and title dragging pass through.
@MainActor
final class DesktopPanelContentView: NSView {
    private let hosting: NSView
    let resizeBorder = PanelResizeBorderView()

    var resizeEnabled: Bool {
        get { resizeBorder.isEnabled }
        set { resizeBorder.isEnabled = newValue }
    }

    init(hosting: NSView, resizeEnabled: Bool) {
        self.hosting = hosting
        super.init(frame: hosting.frame)
        hosting.autoresizingMask = [.width, .height]
        resizeBorder.autoresizingMask = [.width, .height]
        hosting.frame = bounds
        resizeBorder.frame = bounds
        addSubview(hosting)
        addSubview(resizeBorder)
        self.resizeEnabled = resizeEnabled
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        hosting.frame = bounds
        resizeBorder.frame = bounds
        window?.invalidateCursorRects(for: resizeBorder)
    }
}

enum PanelResizeRegions {
    static func regions(in bounds: CGRect) -> [(PanelResizeDirection, CGRect)] {
        let edge: CGFloat = 8
        let corner: CGFloat = 20
        let horizontal = max(0, bounds.width - 2 * corner)
        let vertical = max(0, bounds.height - 2 * corner)
        return [
            // L-shaped corner targets keep titlebar buttons clickable even in
            // the compact layout, while the perimeter uses diagonal cursors.
            (.topLeft, CGRect(x: bounds.minX, y: bounds.maxY - corner, width: edge, height: corner)),
            (.topLeft, CGRect(x: bounds.minX, y: bounds.maxY - edge, width: corner, height: edge)),
            (.topRight, CGRect(x: bounds.maxX - edge, y: bounds.maxY - corner, width: edge, height: corner)),
            (.topRight, CGRect(x: bounds.maxX - corner, y: bounds.maxY - edge, width: corner, height: edge)),
            (.bottomLeft, CGRect(x: bounds.minX, y: bounds.minY, width: edge, height: corner)),
            (.bottomLeft, CGRect(x: bounds.minX, y: bounds.minY, width: corner, height: edge)),
            (.bottomRight, CGRect(x: bounds.maxX - edge, y: bounds.minY, width: edge, height: corner)),
            (.bottomRight, CGRect(x: bounds.maxX - corner, y: bounds.minY, width: corner, height: edge)),
            (.left, CGRect(x: bounds.minX, y: bounds.minY + corner, width: edge, height: vertical)),
            (.right, CGRect(x: bounds.maxX - edge, y: bounds.minY + corner, width: edge, height: vertical)),
            (.top, CGRect(x: bounds.minX + corner, y: bounds.maxY - edge, width: horizontal, height: edge)),
            (.bottom, CGRect(x: bounds.minX + corner, y: bounds.minY, width: horizontal, height: edge))
        ]
    }

    static func direction(at point: CGPoint, in bounds: CGRect) -> PanelResizeDirection? {
        guard bounds.contains(point) else { return nil }
        return regions(in: bounds).first { $0.1.contains(point) }?.0
    }
}

@MainActor
final class PanelResizeBorderView: NSView {
    var isEnabled = true {
        didSet {
            if !isEnabled { trackingDirection = nil }
            window?.invalidateCursorRects(for: self)
            if oldValue != isEnabled {
                updateTrackingAreas()
                if !isEnabled && showsResizeCursor { NSCursor.arrow.set(); showsResizeCursor = false }
            }
        }
    }
    private var trackingDirection: PanelResizeDirection?
    private var hoverAreas: [NSTrackingArea] = []
    private var showsResizeCursor = false

    override func isAccessibilityElement() -> Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled,
              PanelResizeRegions.direction(at: convert(point, from: superview), in: bounds) != nil else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled,
              let direction = PanelResizeRegions.direction(at: convert(event.locationInWindow, from: nil), in: bounds),
              let handler = window as? DesktopPanelInteractionHandling,
              handler.beginInteraction(.resize(direction), at: NSEvent.mouseLocation) else { return }
        trackingDirection = direction
        PanelResizeCursors.cursor(for: direction).set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let direction = trackingDirection else { return }
        (window as? DesktopPanelInteractionHandling)?.updateInteraction(at: NSEvent.mouseLocation,
                                                                       modifiers: event.modifierFlags)
        PanelResizeCursors.cursor(for: direction).set()
    }

    override func mouseUp(with event: NSEvent) {
        guard trackingDirection != nil else { return }
        trackingDirection = nil
        (window as? DesktopPanelInteractionHandling)?.endInteraction(at: NSEvent.mouseLocation,
                                                                    modifiers: event.modifierFlags)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        guard isEnabled else { return }
        for (direction, rect) in PanelResizeRegions.regions(in: bounds) {
            addCursorRect(rect, cursor: PanelResizeCursors.cursor(for: direction))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hoverAreas.forEach(removeTrackingArea)
        hoverAreas.removeAll()
        guard isEnabled else { return }
        // Desktop windows commonly aren't key and their app may be inactive.
        // activeAlways delivers mouse events in that state (cursorUpdate does
        // not), so show resize arrows before the first click as well.
        for (_, rect) in PanelResizeRegions.regions(in: bounds) {
            let area = NSTrackingArea(rect: rect,
                                      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverAreas.append(area)
        }
    }

    override func mouseEntered(with event: NSEvent) { updateHoverCursor(event) }
    override func mouseMoved(with event: NSEvent) { updateHoverCursor(event) }
    override func mouseExited(with event: NSEvent) { updateHoverCursor(event) }

    private func updateHoverCursor(_ event: NSEvent) {
        guard trackingDirection == nil else { return }
        if isEnabled, let direction = PanelResizeRegions.direction(
            at: convert(event.locationInWindow, from: nil), in: bounds) {
            PanelResizeCursors.cursor(for: direction).set()
            showsResizeCursor = true
        } else if showsResizeCursor {
            NSCursor.arrow.set()
            showsResizeCursor = false
        }
    }
}

@MainActor
enum PanelResizeCursors {
    static func cursor(for direction: PanelResizeDirection) -> NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition
            switch direction {
            case .left: position = .left
            case .right: position = .right
            case .top: position = .top
            case .bottom: position = .bottom
            case .topLeft: position = .topLeft
            case .topRight: position = .topRight
            case .bottomLeft: position = .bottomLeft
            case .bottomRight: position = .bottomRight
            }
            return .frameResize(position: position, directions: .all)
        }
        switch direction {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .bottomRight: return descendingDiagonal
        case .topRight, .bottomLeft: return ascendingDiagonal
        }
    }

    private static let ascendingDiagonal = diagonal(ascending: true)
    private static let descendingDiagonal = diagonal(ascending: false)

    private static func diagonal(ascending: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: x, y: ascending ? y : 20 - y)
            }
            let path = NSBezierPath()
            path.move(to: point(4, 4)); path.line(to: point(16, 16))
            path.move(to: point(4, 10)); path.line(to: point(4, 4)); path.line(to: point(10, 4))
            path.move(to: point(10, 16)); path.line(to: point(16, 16)); path.line(to: point(16, 10))
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.white.setStroke(); path.lineWidth = 4; path.stroke()
            NSColor.black.setStroke(); path.lineWidth = 2; path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 10, y: 10))
    }
}
