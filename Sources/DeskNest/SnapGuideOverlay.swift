import AppKit
import CoreGraphics

/// Mouse-transparent previews live beside desktop widgets, below application windows.
@MainActor
final class SnapGuideOverlay {
    private var panels: [NSPanel] = []

    func show(_ result: SnapResult) {
        if panels.count != NSScreen.screens.count {
            hide()
            for panel in panels { panel.close() }
            panels = NSScreen.screens.map { screen in
                let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.ignoresMouseEvents = true
                panel.hidesOnDeactivate = false
                panel.isFloatingPanel = false
                panel.isReleasedWhenClosed = false
                panel.animationBehavior = .none
                panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
                // Native widgets use desktopIcon + 2 on current macOS versions.
                // This temporary layer remains far below .normal (application windows).
                panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 3)
                panel.contentView = SnapGuideView(frame: CGRect(origin: .zero, size: screen.frame.size))
                return panel
            }
        }
        for (panel, screen) in zip(panels, NSScreen.screens) {
            panel.setFrame(screen.frame, display: false)
            guard let view = panel.contentView as? SnapGuideView else { continue }
            view.screenOrigin = screen.frame.origin
            view.result = result
            view.needsDisplay = true
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    func hide() {
        for panel in panels { panel.orderOut(nil) }
    }
}

@MainActor
private final class SnapGuideView: NSView {
    var screenOrigin: CGPoint = .zero
    var result: SnapResult?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let result else { return }
        let color = result.blocked ? NSColor.systemRed : NSColor.systemGreen
        let preview = result.frame.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y).insetBy(dx: 1.5, dy: 1.5)
        let outline = NSBezierPath(roundedRect: preview, xRadius: 20, yRadius: 20)
        color.withAlphaComponent(0.07).setFill()
        outline.fill()
        color.withAlphaComponent(0.95).setStroke()
        outline.lineWidth = 2
        outline.setLineDash([7, 5], count: 2, phase: 0)
        outline.stroke()

        let referenceLines = NSBezierPath()
        referenceLines.lineWidth = 1
        referenceLines.setLineDash([4, 4], count: 2, phase: 0)
        for guide in result.guides {
            switch guide.axis {
            case .vertical:
                referenceLines.move(to: CGPoint(x: guide.position - screenOrigin.x, y: guide.start - screenOrigin.y))
                referenceLines.line(to: CGPoint(x: guide.position - screenOrigin.x, y: guide.end - screenOrigin.y))
            case .horizontal:
                referenceLines.move(to: CGPoint(x: guide.start - screenOrigin.x, y: guide.position - screenOrigin.y))
                referenceLines.line(to: CGPoint(x: guide.end - screenOrigin.x, y: guide.position - screenOrigin.y))
            }
        }
        color.withAlphaComponent(0.8).setStroke()
        referenceLines.stroke()
    }
}
