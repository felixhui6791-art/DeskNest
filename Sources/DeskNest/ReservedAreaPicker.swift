import AppKit

/// A user-invoked rectangle selector. It records geometry only, without taking screenshots.
@MainActor
final class ReservedAreaPicker {
    private var windows: [SelectionPanel] = []
    private var applicationObservers: [NSObjectProtocol] = []
    private var spaceObserver: NSObjectProtocol?
    private let completion: (WidgetFrame?) -> Void
    private var finished = false

    init(completion: @escaping (WidgetFrame?) -> Void) { self.completion = completion }

    func begin() {
        guard windows.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        for name in [NSApplication.didResignActiveNotification, NSApplication.didChangeScreenParametersNotification] {
            applicationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.finish(nil) }
            })
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish(nil) }
        }
        for screen in NSScreen.screens {
            let frame = screen.visibleFrame
            let panel = SelectionPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "标记保留区域"
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = true
            panel.isReleasedWhenClosed = false
            // This temporary input surface appears only after the user chooses to mark an area.
            panel.level = .modalPanel
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone]
            let selection = SelectionView(frame: NSRect(origin: .zero, size: frame.size)) { [weak self] selection in
                let result = selection.map {
                    WidgetFrame(x: frame.minX + $0.minX, y: frame.minY + $0.minY, width: $0.width, height: $0.height)
                }
                Task { @MainActor [weak self] in self?.finish(result) }
            }
            panel.contentView = selection
            panel.makeFirstResponder(selection)
            windows.append(panel)
            panel.orderFrontRegardless()
        }
        if let window = windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? windows.first {
            window.makeKeyAndOrderFront(nil)
        } else {
            finish(nil)
        }
    }

    private func finish(_ frame: WidgetFrame?) {
        guard !finished else { return }
        finished = true
        for observer in applicationObservers { NotificationCenter.default.removeObserver(observer) }
        applicationObservers.removeAll()
        if let observer = spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        spaceObserver = nil
        for window in windows { window.orderOut(nil); window.close() }
        windows.removeAll()
        completion(frame)
    }
}

@MainActor
private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class SelectionView: NSView {
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private let completion: (NSRect?) -> Void
    private let accent = NSColor(calibratedRed: 0.53, green: 0.72, blue: 0.60, alpha: 1)

    init(frame: NSRect, completion: @escaping (NSRect?) -> Void) {
        self.completion = completion
        super.init(frame: frame)
        setAccessibilityLabel("标记保留区域。拖动框选，按 Escape 取消。")
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    private var selection: NSRect? {
        guard let startPoint, let currentPoint else { return nil }
        return NSRect(x: min(startPoint.x, currentPoint.x), y: min(startPoint.y, currentPoint.y),
                      width: abs(currentPoint.x - startPoint.x), height: abs(currentPoint.y - startPoint.y)).intersection(bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.16).setFill()
        bounds.fill()
        if let selection {
            accent.withAlphaComponent(0.17).setFill()
            NSBezierPath(roundedRect: selection, xRadius: 8, yRadius: 8).fill()
            let border = NSBezierPath(roundedRect: selection.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            border.lineWidth = 2
            border.setLineDash([7, 5], count: 2, phase: 0)
            accent.setStroke()
            border.stroke()
        }

        let instructionFrame = NSRect(x: max(18, (bounds.width - 460) / 2), y: bounds.maxY - 100, width: min(460, bounds.width - 36), height: 75)
        NSColor(calibratedWhite: 0.12, alpha: 0.91).setFill()
        NSBezierPath(roundedRect: instructionFrame, xRadius: 16, yRadius: 16).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let title = NSAttributedString(string: "拖出要保留的区域", attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph
        ])
        title.draw(in: NSRect(x: instructionFrame.minX + 12, y: instructionFrame.maxY - 32, width: instructionFrame.width - 24, height: 25))
        let subtitle = NSAttributedString(string: "松开鼠标确认 · Esc 取消 · 不会移动原有组件", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white.withAlphaComponent(0.75), .paragraphStyle: paragraph
        ])
        subtitle.draw(in: NSRect(x: instructionFrame.minX + 12, y: instructionFrame.minY + 14, width: instructionFrame.width - 24, height: 20))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        if let selection, selection.width >= 32, selection.height >= 32 {
            completion(selection)
        } else {
            startPoint = nil
            currentPoint = nil
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { completion(nil) }
        else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { completion(nil) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
}
