import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import SwiftUI

/// A transient tray anchored to the organizer arrow, populated with actual status items.
@MainActor
final class FoldedMenuBarTray: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isShown = false
    @Published private(set) var items: [FoldedMenuBarItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasCaptureAccess = false
    @Published private(set) var hasAccessibilityAccess = false
    @Published var message: String?
    @Published private(set) var glassTone: GlassTone = .frost
    @Published private(set) var transparency = AppearanceSettings.defaultMenuBarTransparency

    var onVisibilityChange: ((Bool) -> Void)?
    var onActivate: ((FoldedMenuBarItem) -> Void)?
    var onAdjust: (() -> Void)?
    var onRefresh: (() -> Void)?
    private let panel = FoldedMenuBarPanel(contentRect: .zero,
                                          styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
    private weak var anchorButton: NSStatusBarButton?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private let catalog = MenuBarItemCatalog()
    private var context: (() -> MenuBarCatalogContext?)?
    private var loadTask: Task<Void, Never>?
    private var closeTimer: Timer?
    private var closeDelay: TimeInterval = 0
    private var generation = UUID()

    override init() {
        super.init()
        panel.title = "栖桌 · 折叠区"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.setAccessibilitySubrole(.standardWindow)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        // The glass is drawn by a separate background view. The window and all
        // foreground content must remain fully opaque as its setting changes.
        panel.alphaValue = 1
    }

    func show(below button: NSStatusBarButton, delay: TimeInterval,
              context: @escaping () -> MenuBarCatalogContext?, message: String? = nil,
              loadImmediately: Bool = true) {
        if isShown { close() }
        anchorButton = button
        guard anchorFrame != nil, anchorScreen != nil else { return }
        self.context = context
        self.message = message
        closeDelay = delay
        hasCaptureAccess = CGPreflightScreenCaptureAccess()
        hasAccessibilityAccess = AXIsProcessTrusted()
        items = context().map { catalog.snapshot(in: $0) } ?? []
        isLoading = !loadImmediately && items.contains { !$0.isActualIcon }
        let hosting = NSHostingView(rootView: FoldedMenuBarTrayView(tray: self))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.cornerRadius = 21
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
        updatePanelFrame()
        panel.makeKeyAndOrderFront(nil)
        isShown = panel.isVisible
        onVisibilityChange?(isShown)
        if isShown {
            installDismissalMonitors()
            if loadImmediately { refresh() }
            scheduleClose()
        }
    }

    func close() {
        loadTask?.cancel()
        loadTask = nil
        generation = UUID()
        closeTimer?.invalidate()
        closeTimer = nil
        removeDismissalMonitors()
        isLoading = false
        if isShown {
            isShown = false
            onVisibilityChange?(false)
        }
        panel.orderOut(nil)
    }

    func shutdown() {
        close()
        panel.contentView = nil
        panel.onCancel = nil
        anchorButton = nil
        onActivate = nil
        onAdjust = nil
        onRefresh = nil
        onVisibilityChange = nil
        context = nil
    }

    func setGlassTone(_ tone: GlassTone) {
        if glassTone != tone { glassTone = tone }
    }

    func setTransparency(_ value: Double) {
        transparency = AppearanceSettings.normalizedTransparency(
            value, fallback: AppearanceSettings.defaultMenuBarTransparency)
    }

    func refresh() {
        loadTask?.cancel()
        hasCaptureAccess = CGPreflightScreenCaptureAccess()
        hasAccessibilityAccess = AXIsProcessTrusted()
        guard let context = context?() else { return }
        isLoading = true
        updatePanelFrame()
        let token = UUID()
        generation = token
        loadTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.catalog.items(in: context) { [weak self] update in
                guard let self, !Task.isCancelled, self.isShown, self.generation == token else { return }
                self.items = update
            }
            guard !Task.isCancelled, self.isShown, self.generation == token else { return }
            self.items = result
            self.isLoading = false
            self.updatePanelFrame()
        }
        scheduleClose()
    }

    /// Hidden status surfaces are not always available to ScreenCaptureKit. The
    /// controller can briefly expose only the menu-bar section to warm this cache.
    func needsIconPreparation(in context: MenuBarCatalogContext, forceRefresh: Bool = false) -> Bool {
        context.captureIcons && catalog.snapshot(in: context).contains { forceRefresh || !$0.isActualIcon }
    }

    func prepareIcons(in context: MenuBarCatalogContext, forceRefresh: Bool = false) async {
        let token = generation
        _ = await catalog.items(in: context, forceRefresh: forceRefresh) { [weak self] update in
            guard let self, !Task.isCancelled, self.isShown, self.generation == token else { return }
            self.items = update
        }
    }

    func requestRefresh() {
        if let onRefresh { onRefresh() } else { refresh() }
    }

    func activate(_ item: FoldedMenuBarItem) {
        closeTimer?.invalidate()
        hasAccessibilityAccess = AXIsProcessTrusted()
        guard hasAccessibilityAccess else {
            message = "需要辅助功能权限才能打开原图标菜单。请点下方“允许菜单操作”，开启栖桌后再回来刷新。"
            updatePanelFrame()
            return
        }
        onActivate?(item)
    }

    func requestCaptureAccess() {
        close()
        // Only this explicitly labelled user action may request a privacy permission.
        if !CGRequestScreenCaptureAccess() {
            openPrivacyPane("Privacy_ScreenCapture")
        }
    }

    func requestAccessibilityAccess() {
        close()
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openPrivacyPane("Privacy_Accessibility")
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // A status-button click can also resign key before its mouse-up action;
        // leave that click to the organizer's existing toggle handler.
        if isShown, anchorFrame?.contains(NSEvent.mouseLocation) != true {
            dismissIfOutside(at: NSEvent.mouseLocation,
                             commandDown: NSEvent.modifierFlags.contains(.command))
        }
    }

    fileprivate var contentSize: NSSize {
        let idealWidth = items.reduce(CGFloat(32)) { $0 + min(168, max(36, $1.frame.width + 8)) }
            + CGFloat(max(0, items.count - 1)) * 4
        let width = min(640, max(320, idealWidth))
        let accessHeight: CGFloat = (!hasCaptureAccess || !hasAccessibilityAccess) ? 85 : 0
        let desired = NSSize(width: width, height: (items.isEmpty ? 166 : 138) + accessHeight + (message == nil ? 0 : 62))
        guard let anchor = anchorFrame, let screen = anchorScreen else { return desired }
        return FoldedMenuBarTrayPlacement.frame(contentSize: desired, anchor: anchor,
                                                visibleFrame: screen.visibleFrame).size
    }

    private var anchorFrame: NSRect? {
        guard let button = anchorButton, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private var anchorScreen: NSScreen? {
        guard let anchor = anchorFrame else { return nil }
        return NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) }
            ?? anchorButton?.window?.screen
    }

    private func updatePanelFrame() {
        guard let anchor = anchorFrame, let screen = anchorScreen else { return }
        panel.setFrame(FoldedMenuBarTrayPlacement.frame(contentSize: contentSize, anchor: anchor,
                                                       visibleFrame: screen.visibleFrame), display: true)
    }

    private func installDismissalMonitors() {
        removeDismissalMonitors()
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            let consume = MainActor.assumeIsolated {
                guard let self, self.isShown else { return false }
                if event.type == .keyDown {
                    if event.keyCode == 53 {
                        self.close()
                        return true
                    }
                } else {
                    let location = event.window?.convertPoint(toScreen: event.locationInWindow)
                        ?? NSEvent.mouseLocation
                    self.dismissIfOutside(at: location, commandDown: event.modifierFlags.contains(.command))
                }
                return false
            }
            return consume ? nil : event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.dismissIfOutside(at: NSEvent.mouseLocation, commandDown: event.modifierFlags.contains(.command))
            }
        }
    }

    private func dismissIfOutside(at location: NSPoint, commandDown: Bool) {
        guard isShown, !panel.frame.contains(location) else { return }
        let pointerInBar = NSScreen.screens.contains { screen in
            MenuBarOrganizerGeometry.menuBarBand(screen: screen.frame,
                height: max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)).contains(location)
        }
        if MenuBarAdjustmentSession.wantsAdjustment(commandDown: commandDown, pointerInMenuBar: pointerInBar) {
            // Enter adjustment before closing: a cancelled preview must not fold
            // the very icons that the Command-click is about to move.
            if let onAdjust { onAdjust() } else { close() }
            return
        }
        // The arrow already toggles the tray on mouse-up. Closing on its
        // mouse-down would make that same click immediately open it again.
        guard anchorFrame?.contains(location) != true else { return }
        close()
    }

    private func removeDismissalMonitors() {
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        if let globalEventMonitor { NSEvent.removeMonitor(globalEventMonitor) }
        localEventMonitor = nil
        globalEventMonitor = nil
    }

    private func scheduleClose() {
        closeTimer?.invalidate()
        guard isShown, closeDelay > 0 else { return }
        closeTimer = Timer.scheduledTimer(withTimeInterval: closeDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pointerInside = self.panel.frame.contains(NSEvent.mouseLocation)
                if pointerInside || NSEvent.modifierFlags.contains(.command)
                    || NSEvent.pressedMouseButtons != 0 || self.isLoading {
                    self.scheduleClose()
                } else {
                    self.close()
                }
            }
        }
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
private final class FoldedMenuBarPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
private struct FoldedMenuBarTrayView: View {
    @ObservedObject var tray: FoldedMenuBarTray
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "tray.full").foregroundStyle(.secondary)
                Text("折叠区").font(.system(size: 13, weight: .semibold))
                Text("\(tray.items.count)").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if tray.isLoading { ProgressView().controlSize(.mini) }
                Button { tray.onAdjust?() } label: {
                    Label("调整", systemImage: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.primary.opacity(0.07), in: Capsule())
                }
                .help("调整图标位置")
                .accessibilityLabel("调整图标位置")
                Button { tray.requestRefresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新折叠区").accessibilityLabel("刷新折叠区")
                Button { tray.close() } label: { Image(systemName: "xmark") }
                    .help("关闭折叠区").accessibilityLabel("关闭折叠区")
                    .keyboardShortcut(.cancelAction)
            }.buttonStyle(.plain)

            if tray.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.dashed").font(.system(size: 23)).foregroundStyle(.secondary)
                    Text(tray.isLoading ? "正在读取菜单栏图标…" : "折叠区还没有可显示的图标")
                        .font(.system(size: 12, weight: .medium))
                    Text("点右上角“调整”，按住 ⌘ 将图标拖到竖线左侧。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 64)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 4) {
                        ForEach(tray.items, id: \.windowID) { item in
                            Button { tray.activate(item) } label: {
                                Group {
                                    if let icon = item.icon {
                                        Image(nsImage: icon).resizable().scaledToFit()
                                    } else {
                                        Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary)
                                    }
                                }.frame(width: min(160, max(28, item.frame.width)), height: 28)
                                    .frame(width: min(168, max(36, item.frame.width + 8)), height: 44)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .help("\(item.displayName)\(item.isActualIcon ? "" : " · 图标预览暂不可用")")
                                .accessibilityLabel("打开 \(item.displayName) 的菜单")
                        }
                    }
                }.frame(height: 48)
            }

            if let message = tray.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !tray.hasCaptureAccess || !tray.hasAccessibilityAccess {
                Divider()
                Text(!tray.hasCaptureAccess ? "显示原始图标需屏幕录制权限；当前显示可识别的名称与占位图标。" : "点击图标打开原菜单，需要辅助功能权限。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if !tray.hasCaptureAccess { Button("允许图标预览") { tray.requestCaptureAccess() } }
                    if !tray.hasAccessibilityAccess { Button("允许菜单操作") { tray.requestAccessibilityAccess() } }
                }.controlSize(.small)
            }
            HStack(spacing: 4) {
                Image(systemName: "cursorarrow")
                Text(tray.hasCaptureAccess && tray.items.contains(where: { !$0.isActualIcon })
                     ? "部分图标预览暂不可用" : "点选打开原菜单")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }.padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }.scrollIndicators(.hidden)
            .frame(width: tray.contentSize.width, height: tray.contentSize.height, alignment: .topLeading)
            .background { GlassBackground(transparency: tray.transparency, cornerRadius: 21, tone: tray.glassTone) }
            .environment(\.colorScheme, tray.glassTone.colorScheme ?? systemColorScheme)
    }
}
