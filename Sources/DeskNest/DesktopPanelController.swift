import AppKit
import Combine
import CoreGraphics
import SwiftUI

/// Owns persistent desktop windows and commits placement only when a gesture ends.
@MainActor
final class DesktopPanelController: NSObject, NSWindowDelegate {
    private let store: WorkspaceStore
    private let openManager: () -> Void
    private var panels: [UUID: DesktopPanel] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var updatingFrames = false
    private var started = false
    private var nativeObstacles: [CGRect] = []
    private let guides = SnapGuideOverlay()
    private var tracking: PanelTracking?

    private struct PanelTracking {
        var id: UUID
        var kind: PanelInteractionKind
        var initialFrame: CGRect
        var initialMouse: CGPoint
        var lastLegalFrame: CGRect
        var preview: SnapResult
        var hasMoved = false
    }

    init(store: WorkspaceStore, openManager: @escaping () -> Void) {
        self.store = store
        self.openManager = openManager
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        store.$widgets
            .combineLatest(store.$panelsVisible)
            .sink { [weak self] _ in
                // @Published emits before its property is written.
                Task { @MainActor [weak self] in self?.synchronize() }
            }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.keepPanelsOnScreen() }
            }
            .store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.cancelInteraction() }
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.guides.hide() }
            }
            .store(in: &subscriptions)
        refreshDesktopObstacles()
        synchronize()
    }

    func showAll() {
        store.panelsVisible = true
        synchronize()
    }

    func refreshDesktopObstacles() {
        let result = DesktopObstacleScanner.scan()
        nativeObstacles = result.obstacles.map(\.frame)
        store.desktopScanMessage = result.message
        store.detectedNativeWidgetCount = result.obstacles.count
        store.nativeScanLimited = result.isLimited
    }

    func arrangePanels() {
        cancelInteraction()
        refreshDesktopObstacles()
        let widgets = store.widgets.filter(\.isVisible)
        guard !NSScreen.screens.isEmpty else { return }
        var unchanged = Set(widgets.filter(\.isLocked).map(\.id))
        var failed = Set<UUID>()
        var planned: [UUID: CGRect] = [:]

        // If a group cannot fit, reserve its old position and re-plan. This also
        // prevents an earlier planned group from covering one left in place.
        while true {
            var occupied = obstacleFrames
                + widgets.filter { unchanged.contains($0.id) }.compactMap(currentFrame)
            planned.removeAll()
            var retry = false
            for widget in widgets where !unchanged.contains(widget.id) {
                let size = currentFrame(widget)?.size ?? CGSize(width: 350, height: 306)
                if let frame = availableFrame(size: size, occupied: occupied) {
                    planned[widget.id] = frame
                    occupied.append(frame)
                } else {
                    unchanged.insert(widget.id)
                    failed.insert(widget.id)
                    retry = true
                    break
                }
            }
            if !retry { break }
        }

        updatingFrames = true
        for (id, frame) in planned {
            panels[id]?.setFrame(frame, display: true)
            store.setFrame(id: id, frame: modelFrame(frame))
        }
        updatingFrames = false
        if !failed.isEmpty {
            store.lastError = "桌面空间不足，\(failed.count) 个分区保留原位置。可以缩小分区、隐藏暂时不用的分区，或调整预留区域。"
        }
        store.panelsVisible = true
        synchronize()
    }

    private var obstacleFrames: [CGRect] {
        (store.avoidNativeWidgets ? nativeObstacles : []) + store.reservedAreas.map { nsFrame($0.frame) }
    }

    private var snapConfiguration: SnapConfiguration {
        store.snappingEnabled ? SnapConfiguration()
            : SnapConfiguration(gridSize: 0, threshold: 0, margin: 20, gap: 16)
    }

    private func synchronize() {
        if let tracking,
           !store.panelsVisible || store.widgets.first(where: { $0.id == tracking.id })?.isVisible != true
               || store.widgets.first(where: { $0.id == tracking.id })?.isLocked != false {
            cancelInteraction()
        }
        let existingIDs = Set(store.widgets.map(\.id))
        for id in Array(panels.keys) where !existingIDs.contains(id) {
            panels[id]?.delegate = nil
            panels[id]?.close()
            panels.removeValue(forKey: id)
        }

        for (index, widget) in store.widgets.enumerated() {
            let panel: DesktopPanel
            if let existing = panels[widget.id] {
                panel = existing
            } else {
                panel = makePanel(for: widget, index: index)
                panels[widget.id] = panel
            }

            panel.title = widget.title
            // The SwiftUI background owns transparency; file icons and labels
            // always render at their normal opacity.
            panel.alphaValue = 1
            // Desktop panels always remain below normal application windows.
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            panel.isMovable = !widget.isLocked
            (panel.contentView as? DesktopPanelContentView)?.resizeEnabled = !widget.isLocked

            if tracking?.id != widget.id,
               let saved = store.widgets.first(where: { $0.id == widget.id })?.frame {
                let desired = nsFrame(saved)
                if framesDiffer(panel.frame, desired) && !updatingFrames {
                    updatingFrames = true
                    panel.setFrame(desired, display: panel.isVisible)
                    updatingFrames = false
                }
            }

            if store.panelsVisible && widget.isVisible {
                if !panel.isVisible { panel.orderFrontRegardless() }
            } else if panel.isVisible {
                panel.orderOut(nil)
            }
        }
        if !store.panelsVisible { guides.hide() }
    }

    private func makePanel(for widget: DesktopWidget, index: Int) -> DesktopPanel {
        let proposed: CGRect
        if let saved = widget.frame {
            proposed = nsFrame(saved)
        } else {
            refreshDesktopObstacles()
            let occupied = obstacleFrames + store.widgets
                .filter { $0.id != widget.id && $0.isVisible }.compactMap(currentFrame)
            proposed = availableFrame(size: CGSize(width: 350, height: 306), occupied: occupied)
                ?? defaultFrame(index: index)
        }
        let frame = clampedFrame(proposed)
        let panel = DesktopPanel(
            contentRect: frame,
            // A single custom resize lifecycle serves every edge and corner.
            // Native resizing would compete with its anchors and final save.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.widgetID = widget.id
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.minSize = PanelResizeGeometry.minimumSize
        // These persistent groups are windows, not application dialogs.
        panel.setAccessibilitySubrole(.standardWindow)
        panel.beginTracking = { [weak self, weak panel] kind, location in
            guard let self, let panel else { return false }
            return self.beginInteraction(panel: panel, kind: kind, at: location)
        }
        panel.updateTracking = { [weak self, weak panel] location, modifiers in
            guard let self, let panel else { return }
            self.updateInteraction(panel: panel, at: location, modifiers: modifiers)
        }
        panel.endTracking = { [weak self, weak panel] location, modifiers in
            guard let self, let panel else { return }
            self.endInteraction(panel: panel, at: location, modifiers: modifiers)
        }
        let hosting = NSHostingView(rootView: DesktopWidgetView(store: store, widgetID: widget.id, openManager: openManager))
        // SwiftUI content must fit the user's size, not impose an intrinsic
        // minimum that grows the window again during the next layout pass.
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.cornerRadius = 21
        hosting.layer?.masksToBounds = true
        panel.contentView = DesktopPanelContentView(hosting: hosting, resizeEnabled: !widget.isLocked)
        panel.delegate = self

        if widget.frame == nil || framesDiffer(proposed, frame) {
            store.setFrame(id: widget.id, frame: modelFrame(frame))
        }
        return panel
    }

    private func beginInteraction(panel: DesktopPanel, kind: PanelInteractionKind, at location: CGPoint) -> Bool {
        guard let id = panel.widgetID, let widget = store.widgets.first(where: { $0.id == id }),
              !widget.isLocked, widget.isVisible, store.panelsVisible else { return false }
        cancelInteraction()
        refreshDesktopObstacles()
        let frame = panel.frame
        let safe = snap(frame: frame, panel: panel, kind: kind)
        tracking = PanelTracking(id: id, kind: kind, initialFrame: frame, initialMouse: location,
                                 lastLegalFrame: safe.blocked ? frame : safe.frame,
                                 preview: safe)
        return true
    }

    private func updateInteraction(panel: DesktopPanel, at location: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard let tracking, tracking.id == panel.widgetID else { return }
        let dx = location.x - tracking.initialMouse.x
        let dy = location.y - tracking.initialMouse.y
        let proposed: CGRect
        switch tracking.kind {
        case .move:
            proposed = tracking.initialFrame.offsetBy(dx: dx, dy: dy)
        case .resize(let direction):
            proposed = PanelResizeGeometry.frame(
                from: tracking.initialFrame, translation: CGSize(width: dx, height: dy), direction: direction,
                in: screenArea(for: tracking.initialFrame) ?? tracking.initialFrame, minimumSize: panel.minSize)
        }
        updatePreview(panel: panel, proposed: proposed, modifiers: modifiers)
    }

    private func updatePreview(panel: DesktopPanel, proposed: CGRect, modifiers: NSEvent.ModifierFlags) {
        guard var gesture = tracking, gesture.id == panel.widgetID else { return }
        let raw: CGRect
        switch gesture.kind {
        case .resize:
            raw = proposed // Already constrained without moving the opposite edge.
        case .move:
            raw = clampedFrame(proposed)
        }
        gesture.hasMoved = gesture.hasMoved || framesDiffer(raw, gesture.initialFrame)
        updatingFrames = true
        panel.setFrame(raw, display: true)
        updatingFrames = false
        if modifiers.contains(.option) {
            gesture.preview = SnapResult(frame: raw, guides: [], blocked: false)
            guides.hide()
        } else {
            let result = snap(frame: raw, panel: panel, kind: gesture.kind)
            gesture.preview = result
            if !result.blocked { gesture.lastLegalFrame = result.frame }
            guides.show(result)
        }
        tracking = gesture
    }

    private func endInteraction(panel: DesktopPanel, at location: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard tracking?.id == panel.widgetID else { return }
        // Mouse-up can be the first event after a short drag. Consume its final
        // position before deciding that the gesture did not change anything.
        updateInteraction(panel: panel, at: location, modifiers: modifiers)
        guard let gesture = tracking else { return }
        if !gesture.hasMoved {
            tracking = nil
            guides.hide()
            return
        }
        let destination = gesture.preview.blocked ? gesture.lastLegalFrame : gesture.preview.frame
        tracking = nil
        guides.hide()
        updatingFrames = true
        panel.setFrame(clampedFrame(destination), display: true)
        store.setFrame(id: gesture.id, frame: modelFrame(panel.frame))
        updatingFrames = false
        if gesture.preview.blocked {
            store.lastError = "这里放不下分区，已撤回本次落位。请拖到空白处，或按住 Option 临时自由摆放。"
        }
    }

    private func cancelInteraction() {
        guard let gesture = tracking else { guides.hide(); return }
        tracking = nil
        guides.hide()
        updatingFrames = true
        panels[gesture.id]?.setFrame(gesture.initialFrame, display: true)
        updatingFrames = false
    }

    private func snap(frame: CGRect, panel: DesktopPanel, kind: PanelInteractionKind) -> SnapResult {
        let area = screenArea(for: frame) ?? frame
        let neighbors = store.widgets.filter { $0.isVisible && $0.id != panel.widgetID }.compactMap(currentFrame)
        if case .resize(let direction) = kind {
            return SnapEngine.resize(frame: frame, in: area, neighbors: neighbors, obstacles: obstacleFrames,
                                     minimumSize: panel.minSize, direction: direction, configuration: snapConfiguration)
        }
        return SnapEngine.snap(frame: frame, in: area, neighbors: neighbors, obstacles: obstacleFrames,
                               configuration: snapConfiguration)
    }

    private func currentFrame(_ widget: DesktopWidget) -> CGRect? {
        panels[widget.id]?.frame ?? widget.frame.map(nsFrame)
    }

    private func availableFrame(size: CGSize, occupied: [CGRect]) -> CGRect? {
        let main = NSScreen.main
        let screens = NSScreen.screens.sorted { $0 == main && $1 != main }
        for screen in screens {
            let area = screen.visibleFrame
            let fittingSize = CGSize(width: min(size.width, max(1, area.width - 40)),
                                     height: min(size.height, max(1, area.height - 40)))
            if let frame = SnapEngine.place(size: fittingSize, in: area, occupied: occupied,
                                            configuration: SnapConfiguration()) {
                return frame
            }
        }
        return nil
    }

    private func defaultFrame(index: Int) -> CGRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return CGRect(x: 40, y: 80, width: 350, height: 306)
        }
        let area = screen.visibleFrame.insetBy(dx: 20, dy: 20)
        return CGRect(x: area.minX + CGFloat(index % 5) * 24,
                      y: area.maxY - 306 - CGFloat(index % 5) * 24, width: 350, height: 306)
    }

    private func keepPanelsOnScreen() {
        cancelInteraction()
        refreshDesktopObstacles()
        updatingFrames = true
        for (id, panel) in panels {
            let frame = clampedFrame(panel.frame)
            guard framesDiffer(panel.frame, frame) else { continue }
            panel.setFrame(frame, display: true)
            store.setFrame(id: id, frame: modelFrame(frame))
        }
        updatingFrames = false
    }

    private func screenArea(for frame: CGRect) -> CGRect? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let overlapping = screens.max { intersectionArea(frame, $0.visibleFrame) < intersectionArea(frame, $1.visibleFrame) }
        if let overlapping, intersectionArea(frame, overlapping.visibleFrame) > 0 { return overlapping.visibleFrame }
        return (NSScreen.main ?? screens[0]).visibleFrame
    }

    private func clampedFrame(_ proposed: CGRect) -> CGRect {
        let frame = proposed.minX.isFinite && proposed.minY.isFinite
            && proposed.width.isFinite && proposed.height.isFinite && proposed.width > 0 && proposed.height > 0
            ? proposed : defaultFrame(index: 0)
        guard let screen = screenArea(for: frame) else { return frame }
        let area = screen.insetBy(dx: 20, dy: 20)
        let width = min(max(PanelResizeGeometry.minimumSize.width, frame.width), area.width)
        let height = min(max(PanelResizeGeometry.minimumSize.height, frame.height), area.height)
        return CGRect(x: min(max(frame.minX, area.minX), area.maxX - width),
                      y: min(max(frame.minY, area.minY), area.maxY - height), width: width, height: height)
    }

    private func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func saveFrame(_ notification: Notification) {
        guard !updatingFrames, let panel = notification.object as? DesktopPanel,
              let id = panel.widgetID, tracking?.id != id else { return }
        store.setFrame(id: id, frame: modelFrame(panel.frame))
    }

    func windowDidMove(_ notification: Notification) { saveFrame(notification) }

    func windowDidResize(_ notification: Notification) { saveFrame(notification) }

    private func framesDiffer(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) > 0.5 || abs(a.minY - b.minY) > 0.5
            || abs(a.width - b.width) > 0.5 || abs(a.height - b.height) > 0.5
    }

    private func nsFrame(_ value: WidgetFrame) -> CGRect {
        CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
    }

    private func modelFrame(_ value: CGRect) -> WidgetFrame {
        WidgetFrame(x: value.minX, y: value.minY, width: value.width, height: value.height)
    }
}

/// Pure geometry shared by the live resize preview and its regression tests.
enum PanelPlacement {
    static func clampBottomRightResize(
        _ proposed: CGRect, anchoredAt anchor: CGRect, in visibleFrame: CGRect,
        minimumSize: CGSize, margin: CGFloat = 20
    ) -> CGRect {
        let area = visibleFrame.insetBy(dx: margin, dy: margin)
        guard area.width > 0, area.height > 0, anchor.minX.isFinite, anchor.maxY.isFinite else { return anchor }
        let minimumWidth = min(max(1, minimumSize.width), area.width)
        let minimumHeight = min(max(1, minimumSize.height), area.height)
        // A valid starting anchor stays exact. If a native edge crosses the
        // display boundary, recover only enough to fit the minimum dimensions.
        let left = min(max(anchor.minX, area.minX), area.maxX - minimumWidth)
        let top = min(max(anchor.maxY, area.minY + minimumHeight), area.maxY)
        let proposedWidth = proposed.width.isFinite ? proposed.width : anchor.width
        let proposedHeight = proposed.height.isFinite ? proposed.height : anchor.height
        let width = min(max(minimumWidth, proposedWidth), area.maxX - left)
        let height = min(max(minimumHeight, proposedHeight), top - area.minY)
        return CGRect(x: left, y: top - height, width: width, height: height)
    }
}

@MainActor
private final class DesktopPanel: NSPanel, DesktopPanelInteractionHandling {
    var widgetID: UUID?
    var beginTracking: ((PanelInteractionKind, CGPoint) -> Bool)?
    var updateTracking: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    var endTracking: ((CGPoint, NSEvent.ModifierFlags) -> Void)?

    func beginInteraction(_ kind: PanelInteractionKind, at location: CGPoint) -> Bool {
        beginTracking?(kind, location) ?? false
    }

    func updateInteraction(at location: CGPoint, modifiers: NSEvent.ModifierFlags) {
        updateTracking?(location, modifiers)
    }

    func endInteraction(at location: CGPoint, modifiers: NSEvent.ModifierFlags) {
        endTracking?(location, modifiers)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
