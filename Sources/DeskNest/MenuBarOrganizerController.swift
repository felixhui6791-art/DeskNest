import AppKit
import Combine
import CoreGraphics

/// Keeps its own separator wide or narrow. macOS still owns all other apps' icons.
@MainActor
final class MenuBarOrganizerController: NSObject, ObservableObject {
    @Published private var adjustmentSession = MenuBarAdjustmentSession()
    var isAdjusting: Bool { adjustmentSession.isActive }
    @Published private(set) var isExpanded = true
    @Published private(set) var isEnabled = false
    @Published private(set) var isTrayShown = false
    @Published private(set) var statusMessage = "开启后，按住 ⌘ 将不常用的图标拖到分隔线左侧。"

    private var toggleItem: NSStatusItem?
    private var dividerItem: NSStatusItem?
    private var collapseTimer: Timer?
    private var recoveryTimer: Timer?
    private var autoCollapseDelay: TimeInterval = 0
    private var userHasCollapsed = false
    private var recoveryState = MenuBarRecoveryState()
    private var menuTrackingDepth = 0
    private var layoutSettlesAt: TimeInterval = 0
    private static let expandedLength: CGFloat = 18
    var excludedStatusWindowIDs: (() -> Set<CGWindowID>)?
    private let foldedTray = FoldedMenuBarTray()
    private let itemActivator = MenuBarItemActivator()
    private var iconWarmupTask: Task<Void, Never>?
    private var trayTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var foldRestorationTask: Task<Void, Never>?
    private var collapseAfterPreparation = false
    private var presentationGeneration = UUID()

    override init() {
        super.init()
        foldedTray.onVisibilityChange = { [weak self] shown in
            guard let self else { return }
            self.isTrayShown = shown
            if !shown {
                self.trayTask?.cancel()
                self.trayTask = nil
                let shouldCollapse = self.collapseAfterPreparation
                self.collapseAfterPreparation = false
                if shouldCollapse {
                    let generation = self.presentationGeneration
                    // Expanding the separator relayouts asynchronously. Wait for
                    // that layout before validating a cancelled preview's fold.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                        guard let self, self.isEnabled, !self.isTrayShown,
                              self.presentationGeneration == generation else { return }
                        self.performCollapse(userInitiated: true)
                    }
                }
            }
            self.updateButton()
        }
        foldedTray.onActivate = { [weak self] item in self?.activateFoldedItem(item) }
        foldedTray.onAdjust = { [weak self] in self?.expand() }
        foldedTray.onRefresh = { [weak self] in self?.showFoldedItems(forceRefresh: true) }
        NotificationCenter.default.addObserver(self, selector: #selector(screenConfigurationChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuBeganTracking),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEndedTracking),
                                               name: NSMenu.didEndTrackingNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenConfigurationChanged),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceSuspended(_:)),
                                                              name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceResumed(_:)),
                                                              name: name, object: nil)
        }
    }

    func configure(enabled: Bool, autoCollapseDelay: TimeInterval,
                   transparency: Double = AppearanceSettings.defaultMenuBarTransparency,
                   glassTone: GlassTone = .frost) {
        foldedTray.setGlassTone(glassTone)
        foldedTray.setTransparency(transparency)
        let delay = MenuBarOrganizerGeometry.validDelay(autoCollapseDelay)
        let delayChanged = self.autoCollapseDelay != delay
        self.autoCollapseDelay = delay
        guard enabled != isEnabled else {
            if delayChanged { scheduleAutoCollapseIfNeeded() }
            return
        }
        if enabled {
            isEnabled = true
            userHasCollapsed = false
            recoveryState.reset()
            createItems()
            setExpanded(scheduleCollapse: false)
            statusMessage = Self.expandedHelp
            // Read the already-visible icons once after launch, before the first click.
            iconWarmupTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled, self.isEnabled, self.isExpanded,
                      !self.isTrayShown, let context = self.catalogContext(), context.captureIcons else { return }
                await self.foldedTray.prepareIcons(in: context)
                self.iconWarmupTask = nil
            }
            recoveryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkControlAccessibility() }
            }
        } else {
            removeItems()
            statusMessage = "菜单栏整理已关闭，已释放折叠区域。"
        }
    }

    func toggle() {
        guard isEnabled else { return }
        if isAdjusting { collapse(); return }
        isTrayShown ? foldedTray.close() : showFoldedItems()
    }

    func showFoldedItems(collapseFirst: Bool = true, message: String? = nil, forceRefresh: Bool = false) {
        guard isEnabled, !recoveryState.isSuspended else { return }
        if collapseFirst { recoveryState.requestFold() }
        adjustmentSession.finish()
        presentationGeneration = UUID()
        foldRestorationTask?.cancel()
        foldRestorationTask = nil
        activationTask?.cancel()
        activationTask = nil
        iconWarmupTask?.cancel()
        iconWarmupTask = nil
        trayTask?.cancel()
        trayTask = nil
        foldedTray.close()
        collapseTimer?.invalidate()
        collapseTimer = nil
        guard let button = toggleItem?.button,
              let arrow = frame(of: toggleItem),
              MenuBarOrganizerGeometry.isOnScreen(arrow, screens: NSScreen.screens.map(\.frame),
                                                   visibleAreas: visibleMenuBarAreas) else { return }
        foldedTray.show(below: button, delay: autoCollapseDelay, context: { [weak self] in
            self?.catalogContext()
        }, message: message, loadImmediately: false)
        guard isTrayShown else { return }
        collapseAfterPreparation = collapseFirst
        trayTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.isEnabled else { return }
            if let context = self.catalogContext(), self.foldedTray.needsIconPreparation(in: context, forceRefresh: forceRefresh) {
                self.setExpanded(scheduleCollapse: false)
                self.statusMessage = "正在读取折叠区图标…"
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled, self.isEnabled else { return }
                if let visibleContext = self.catalogContext() {
                    await self.foldedTray.prepareIcons(in: visibleContext, forceRefresh: forceRefresh)
                }
                guard !Task.isCancelled, self.isEnabled else { return }
            }
            if collapseFirst && self.isExpanded {
                self.performCollapse(userInitiated: true)
                // Only a real layout change needs settling time. Cached, already
                // folded items can be displayed and activated immediately.
                try? await Task.sleep(for: .milliseconds(220))
            }
            guard !Task.isCancelled, self.isEnabled, self.isTrayShown else { return }
            self.collapseAfterPreparation = false
            self.trayTask = nil
            self.foldedTray.refresh()
            self.statusMessage = "折叠区显示在菜单栏下方。点选图标可打开原菜单；点击外部或按 Esc 关闭。"
        }
    }

    func expand() {
        guard isEnabled else { return }
        recoveryState.requestExpansion()
        adjustmentSession.begin()
        collapseAfterPreparation = false
        foldRestorationTask?.cancel()
        foldRestorationTask = nil
        activationTask?.cancel()
        activationTask = nil
        iconWarmupTask?.cancel()
        iconWarmupTask = nil
        trayTask?.cancel()
        trayTask = nil
        foldedTray.close()
        presentationGeneration = UUID()
        setExpanded(scheduleCollapse: false)
        statusMessage = Self.adjustmentHelp
    }

    func collapse() {
        recoveryState.requestFold()
        adjustmentSession.finish()
        foldRestorationTask?.cancel()
        foldRestorationTask = nil
        activationTask?.cancel()
        activationTask = nil
        iconWarmupTask?.cancel()
        iconWarmupTask = nil
        trayTask?.cancel()
        trayTask = nil
        foldedTray.close()
        presentationGeneration = UUID()
        performCollapse(userInitiated: true)
    }

    /// Call during application termination, before releasing this controller.
    func shutdown() {
        removeItems()
        foldedTray.shutdown()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private static var adjustmentHelp: String {
        "调整模式保持展开。按住 ⌘ 拖动菜单栏图标到竖线左侧；完成后点击菜单栏的 ✓ 或“完成调整并收起”。"
    }

    private static var expandedHelp: String {
        "按住 ⌘ 将不常用的图标拖到分隔线左侧；点击箭头，在下方面板查看折叠区。"
    }

    private func createItems() {
        // New items are inserted from right to left. Existing positions use AppKit autosave.
        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        toggle.autosaveName = "DeskNest.MenuBarOrganizer.Toggle"
        toggle.behavior = []
        toggle.isVisible = true
        if let button = toggle.button {
            button.target = self
            button.action = #selector(togglePressed)
            button.sendAction(on: [.leftMouseUp])
        }
        toggleItem = toggle

        let divider = NSStatusBar.system.statusItem(withLength: Self.expandedLength)
        divider.autosaveName = "DeskNest.MenuBarOrganizer.Divider"
        divider.behavior = []
        divider.isVisible = true
        if let button = divider.button {
            button.image = NSImage(size: NSSize(width: 8, height: 16), flipped: false) { rect in
                NSColor.labelColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.midX - 0.75, y: 2, width: 1.5, height: 12),
                             xRadius: 0.75, yRadius: 0.75).fill()
                return true
            }
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.toolTip = "按住 ⌘ 将待收起的图标拖到此分隔线左侧；点击可展开。"
            button.setAccessibilityLabel("栖桌菜单栏分隔线")
            button.target = self
            button.action = #selector(dividerPressed)
        }
        dividerItem = divider
        updateButton()
    }

    private func removeItems() {
        adjustmentSession.finish()
        iconWarmupTask?.cancel()
        iconWarmupTask = nil
        trayTask?.cancel()
        trayTask = nil
        foldRestorationTask?.cancel()
        foldRestorationTask = nil
        activationTask?.cancel()
        activationTask = nil
        foldedTray.close()
        presentationGeneration = UUID()
        collapseTimer?.invalidate()
        collapseTimer = nil
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        // Shrink before removal so a disabled feature can never leave a wide slot behind.
        dividerItem?.length = Self.expandedLength
        if let dividerItem { NSStatusBar.system.removeStatusItem(dividerItem) }
        if let toggleItem { NSStatusBar.system.removeStatusItem(toggleItem) }
        dividerItem = nil
        toggleItem = nil
        userHasCollapsed = false
        recoveryState.reset()
        isExpanded = true
        isEnabled = false
    }

    private func setExpanded(scheduleCollapse: Bool) {
        layoutSettlesAt = ProcessInfo.processInfo.systemUptime + 0.5
        collapseTimer?.invalidate()
        collapseTimer = nil
        if dividerItem?.length != Self.expandedLength { dividerItem?.length = Self.expandedLength }
        if dividerItem?.isVisible == false { dividerItem?.isVisible = true }
        if toggleItem?.isVisible == false { toggleItem?.isVisible = true }
        if !isExpanded { isExpanded = true }
        updateButton()
        if scheduleCollapse { scheduleAutoCollapseIfNeeded() }
    }

    private func performCollapse(userInitiated: Bool) {
        guard isEnabled, isExpanded, !recoveryState.isSuspended else { return }
        guard !adjustmentSession.blocksCollapse(
            commandDown: NSEvent.modifierFlags.contains(.command), mouseDown: NSEvent.pressedMouseButtons != 0) else {
            if !isAdjusting { scheduleFoldRestoration() }
            return
        }
        collapseTimer?.invalidate()
        collapseTimer = nil
        guard let arrow = frame(of: toggleItem), let divider = frame(of: dividerItem),
              MenuBarOrganizerGeometry.canCollapse(arrow: arrow, divider: divider,
                                                    screens: NSScreen.screens.map(\.frame),
                                                    visibleAreas: visibleMenuBarAreas) else {
            recover(message: "已保持展开。请按住 ⌘ 将箭头放在分隔线右侧，并让两个标记在菜单栏中可见。")
            return
        }
        recoveryState.requestFold()
        if userInitiated { userHasCollapsed = true }
        layoutSettlesAt = ProcessInfo.processInfo.systemUptime + 0.5
        dividerItem?.length = MenuBarOrganizerGeometry.collapsedLength(screenWidths: NSScreen.screens.map { $0.frame.width })
        isExpanded = false
        updateButton()
        statusMessage = "分隔线左侧的图标已收起，点击箭头可在下方面板查看。"
        // AppKit lays out status items asynchronously; immediately recover a stranded arrow.
        let generation = presentationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.checkControlAccessibility()
        }
    }

    private func updateButton() {
        guard let button = toggleItem?.button else { return }
        let label = isAdjusting ? "完成调整并收起" : (isTrayShown ? "关闭折叠区面板" : "在下方显示折叠区")
        let symbol = isAdjusting ? "checkmark" : (isTrayShown ? "chevron.up" : "chevron.down")
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.image?.isTemplate = true
        button.toolTip = "栖桌 · \(label)"
        button.setAccessibilityLabel("栖桌 · \(label)")
    }

    private func frame(of item: NSStatusItem?) -> CGRect? {
        guard let item, item.isVisible, let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private var visibleMenuBarAreas: [CGRect] {
        NSScreen.screens.flatMap { screen -> [CGRect] in
            // AppKit supplies these in global coordinates, on either side of a notch.
            let auxiliary = [screen.auxiliaryTopLeftArea, screen.auxiliaryTopRightArea]
                .compactMap { $0 }.filter { !$0.isEmpty }
            if !auxiliary.isEmpty { return auxiliary }
            // An obscured top edge with unavailable auxiliary geometry is not proof
            // that a control there is usable; keep the feature expanded in that case.
            return screen.safeAreaInsets.top > 0 ? [] : [screen.frame]
        }
    }

    private func checkControlAccessibility() {
        // NSStatusItem.length changes before the system-hosted button frame does.
        // A recovery check in that interval mistakes the old wide separator for
        // a misplaced control and cancels the pending return to folding.
        guard isEnabled, !recoveryState.isSuspended, ProcessInfo.processInfo.systemUptime >= layoutSettlesAt,
              activationTask == nil, trayTask == nil, foldRestorationTask == nil,
              !NSEvent.modifierFlags.contains(.command), NSEvent.pressedMouseButtons == 0 else { return }
        let screens = NSScreen.screens.map(\.frame)
        let visibleAreas = visibleMenuBarAreas
        let arrowVisible = frame(of: toggleItem).map {
            MenuBarOrganizerGeometry.isOnScreen($0, screens: screens, visibleAreas: visibleAreas)
        } ?? false
        if !arrowVisible || toggleItem?.isVisible == false || dividerItem?.isVisible == false {
            recover(message: "已恢复展开。若标记被挤出菜单栏，可先关闭整理，再腾出空间后开启。")
        } else if isExpanded,
                  let arrow = frame(of: toggleItem), let divider = frame(of: dividerItem),
                  !MenuBarOrganizerGeometry.canCollapse(arrow: arrow, divider: divider, screens: screens,
                                                        visibleAreas: visibleAreas) {
            recover(message: "已保持展开。请按住 ⌘ 将分隔线移到箭头左侧，并让两个标记都可见。")
        } else if recoveryState.shouldRestore(isAdjusting: isAdjusting) {
            if isExpanded {
                scheduleFoldRestoration()
            } else if !MenuBarOrganizerGeometry.hasFoldedLayout(
                requestedLength: dividerItem?.length, divider: frame(of: dividerItem),
                screenWidths: screens.map(\.width)) {
                // The system can rebuild the hosted status view without changing
                // our isExpanded flag, especially after screen sleep.
                screenConfigurationChanged()
            }
        }
    }

    private func recover(message: String) {
        iconWarmupTask?.cancel()
        iconWarmupTask = nil
        trayTask?.cancel()
        trayTask = nil
        foldRestorationTask?.cancel()
        foldRestorationTask = nil
        activationTask?.cancel()
        activationTask = nil
        foldedTray.close()
        presentationGeneration = UUID()
        setExpanded(scheduleCollapse: false)
        if statusMessage != message { statusMessage = message }
        if recoveryState.shouldRestore(isAdjusting: isAdjusting) { scheduleFoldRestoration() }
    }

    private func scheduleAutoCollapseIfNeeded() {
        collapseTimer?.invalidate()
        collapseTimer = nil
        // Enabling or launching never starts a hidden countdown. First collapse is explicit.
        guard isEnabled, !recoveryState.isSuspended, isExpanded, !isAdjusting, userHasCollapsed, autoCollapseDelay > 0,
              activationTask == nil, foldRestorationTask == nil else { return }
        collapseTimer = Timer.scheduledTimer(withTimeInterval: autoCollapseDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.collapseTimer = nil
                if self.isInteractingWithMenuBar() {
                    self.scheduleAutoCollapseIfNeeded()
                } else {
                    self.performCollapse(userInitiated: false)
                }
            }
        }
    }

    private func isInteractingWithMenuBar(activatedOwnerPID: pid_t? = nil) -> Bool {
        if menuTrackingDepth > 0 || adjustmentSession.blocksCollapse(
            commandDown: NSEvent.modifierFlags.contains(.command), mouseDown: NSEvent.pressedMouseButtons != 0) { return true }
        let mouse = NSEvent.mouseLocation
        if NSScreen.screens.contains(where: { screen in
            let height = max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)
            return MenuBarOrganizerGeometry.menuBarBand(screen: screen.frame, height: height).contains(mouse)
        }) { return true }

        // NSMenu tracking notifications are process-local. Public WindowServer metadata
        // provides a conservative extra guard for other apps' dropdowns, without titles,
        // screenshots, input monitoring, or Accessibility access. For a temporarily
        // revealed item, also protect its owner's normal-level anchored popover.
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return true }
        let popupLevel = CGWindowLevelForKey(.popUpMenuWindow)
        let shieldLevel = CGWindowLevelForKey(.screenSaverWindow)
        return windows.contains { info in
            guard let level = info[kCGWindowLayer as String] as? Int,
                  level < shieldLevel,
                  (level >= popupLevel || (activatedOwnerPID != nil
                    && (info[kCGWindowOwnerPID as String] as? Int32) == activatedOwnerPID)),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            let appKitRect = CGRect(x: rect.minX,
                                    y: CGDisplayBounds(CGMainDisplayID()).height - rect.maxY,
                                    width: rect.width, height: rect.height)
            return rect.width > 1 && rect.height > NSStatusBar.system.thickness + 2
                && NSScreen.screens.contains { screen in
                    let height = max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)
                    return MenuBarOrganizerGeometry.isMenuBarPopup(appKitRect, screen: screen.frame, barHeight: height)
                }
        }
    }

    @objc private func togglePressed() {
        guard NSApp.currentEvent?.modifierFlags.contains(.command) != true else { return }
        toggle()
    }

    @objc private func dividerPressed() {
        guard NSApp.currentEvent?.modifierFlags.contains(.command) != true else { return }
        expand()
    }

    @objc private func screenConfigurationChanged() {
        guard isEnabled, !recoveryState.isSuspended else { return }
        // Intent survives missing controls, repeated notifications and temporary expansion.
        let restoreFold = recoveryState.shouldRestore(isAdjusting: isAdjusting)
        iconWarmupTask?.cancel()
        iconWarmupTask = nil
        trayTask?.cancel()
        trayTask = nil
        activationTask?.cancel()
        activationTask = nil
        foldRestorationTask?.cancel()
        foldRestorationTask = nil
        collapseAfterPreparation = false
        presentationGeneration = UUID()
        foldedTray.close()
        setExpanded(scheduleCollapse: !restoreFold)
        if restoreFold {
            statusMessage = "正在恢复折叠位置…"
            scheduleFoldRestoration()
        } else {
            statusMessage = isAdjusting ? Self.adjustmentHelp : Self.expandedHelp
        }
    }

    @objc private func workspaceSuspended(_ notification: Notification) {
        guard isEnabled else { return }
        recoveryState.suspend(Self.suspensionReason(notification.name))
        // Cancel transient work before closing the panel so its callback cannot
        // enqueue a late collapse against sleeping displays.
        collapseAfterPreparation = false
        presentationGeneration = UUID()
        iconWarmupTask?.cancel(); iconWarmupTask = nil
        trayTask?.cancel(); trayTask = nil
        activationTask?.cancel(); activationTask = nil
        foldRestorationTask?.cancel(); foldRestorationTask = nil
        collapseTimer?.invalidate(); collapseTimer = nil
        foldedTray.close()
        menuTrackingDepth = 0
    }

    @objc private func workspaceResumed(_ notification: Notification) {
        guard isEnabled else { return }
        recoveryState.resume(Self.suspensionReason(notification.name))
        guard !recoveryState.isSuspended else { return }
        menuTrackingDepth = 0
        screenConfigurationChanged()
    }

    private static func suspensionReason(_ name: Notification.Name) -> MenuBarRecoveryState.Suspension {
        switch name {
        case NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification: .system
        case NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification: .screens
        default: .session
        }
    }

    private var controlsReadyToFold: Bool {
        guard let arrow = frame(of: toggleItem), let divider = frame(of: dividerItem) else { return false }
        return MenuBarOrganizerGeometry.canCollapse(arrow: arrow, divider: divider,
            screens: NSScreen.screens.map(\.frame), visibleAreas: visibleMenuBarAreas)
    }

    @objc private func menuBeganTracking() { menuTrackingDepth += 1 }
    @objc private func menuEndedTracking() { menuTrackingDepth = max(0, menuTrackingDepth - 1) }

    private func catalogContext() -> MenuBarCatalogContext? {
        guard let divider = frame(of: dividerItem), let arrow = frame(of: toggleItem),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(arrow) }) else { return nil }
        let ownWindows = [toggleItem, dividerItem].compactMap { item -> CGWindowID? in
            guard let number = item?.button?.window?.windowNumber else { return nil }
            return MenuBarOrganizerGeometry.windowID(for: number)
        }
        return MenuBarCatalogContext(dividerFrame: divider, isExpanded: isExpanded,
                                     screenFrame: screen.frame,
                                     mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height,
                                     excludedProcessID: ProcessInfo.processInfo.processIdentifier,
                                     captureIcons: CGPreflightScreenCaptureAccess(),
                                     excludedWindowIDs: Set(ownWindows).union(excludedStatusWindowIDs?() ?? []))
    }

    /// Temporary exposure for an original menu always returns to folding, even
    /// when the optional countdown for explicit adjustment is disabled.
    private func scheduleFoldRestoration(activatedOwnerPID: pid_t? = nil) {
        foldRestorationTask?.cancel()
        foldRestorationTask = nil
        guard recoveryState.shouldRestore(isAdjusting: isAdjusting) else { return }
        let generation = presentationGeneration
        foldRestorationTask = Task { [weak self] in
            var restoration = MenuBarFoldRestoration(startedAt: ProcessInfo.processInfo.systemUptime)
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled, self.isEnabled,
                      self.presentationGeneration == generation,
                      self.recoveryState.shouldRestore(isAdjusting: self.isAdjusting) else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let layoutReady = now >= self.layoutSettlesAt && self.controlsReadyToFold
                if restoration.shouldRestore(at: now,
                    isInteracting: !layoutReady || self.isInteractingWithMenuBar(activatedOwnerPID: activatedOwnerPID)) {
                    self.foldRestorationTask = nil
                    self.performCollapse(userInitiated: true)
                    return
                }
            }
        }
    }

    private func activateFoldedItem(_ item: FoldedMenuBarItem) {
        recoveryState.requestFold()
        iconWarmupTask?.cancel()
        iconWarmupTask = nil
        trayTask?.cancel()
        trayTask = nil
        foldRestorationTask?.cancel()
        foldRestorationTask = nil
        activationTask?.cancel()
        activationTask = nil
        collapseAfterPreparation = false
        presentationGeneration = UUID()
        foldedTray.close()
        setExpanded(scheduleCollapse: false)
        activationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard let self, !Task.isCancelled, self.isEnabled else { return }
            let result = await self.itemActivator.activate(windowID: item.windowID, ownerPID: item.pid)
            guard !Task.isCancelled, self.isEnabled else { return }
            self.activationTask = nil
            switch result {
            case .performed:
                self.statusMessage = "已请求打开原图标菜单，结束操作后恢复收起。"
                self.scheduleFoldRestoration(activatedOwnerPID: item.pid)
            case .unconfirmed(let reason):
                // A synchronous menu may already be open even when AX times out.
                // Leave it in place; neither repeat the click nor reopen our tray.
                self.statusMessage = reason
                self.scheduleFoldRestoration(activatedOwnerPID: item.pid)
            case .needsAccessibility:
                self.showFoldedItems(message: "请先允许栖桌使用辅助功能，再点击图标打开原菜单。")
            case .unavailable(let reason):
                self.showFoldedItems(message: reason)
            }
        }
    }
}

enum MenuBarOrganizerGeometry {
    static func windowID(for windowNumber: Int) -> CGWindowID? {
        guard windowNumber > 0 else { return nil }
        // macOS 26 status proxies can expose synthetic 64-bit NSWindow numbers.
        // They are not WindowServer IDs and must not be truncated or force-converted.
        return CGWindowID(exactly: windowNumber)
    }

    static func hasFoldedLayout(requestedLength: CGFloat?, divider: CGRect?, screenWidths: [CGFloat]) -> Bool {
        let expected = collapsedLength(screenWidths: screenWidths)
        guard let requestedLength, requestedLength.isFinite, let divider,
              divider.width.isFinite, divider.height > 0 else { return false }
        return abs(requestedLength - expected) < 2 && divider.width >= expected - 2
    }

    static func validDelay(_ delay: TimeInterval) -> TimeInterval {
        [0.0, 5, 15, 30].contains(delay) ? delay : 0
    }

    static func collapsedLength(screenWidths: [CGFloat]) -> CGFloat {
        let widest = screenWidths.filter { $0.isFinite && $0 > 0 }.max() ?? 1920
        return min(10_000, max(500, widest + 128))
    }

    static func isOnScreen(_ rect: CGRect, screens: [CGRect], visibleAreas: [CGRect]? = nil) -> Bool {
        guard !rect.isEmpty, rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return false }
        return screens.contains { $0.contains(rect) } && (visibleAreas ?? screens).contains { $0.contains(rect) }
    }

    static func canCollapse(arrow: CGRect, divider: CGRect, screens: [CGRect], visibleAreas: [CGRect]? = nil) -> Bool {
        guard isOnScreen(arrow, screens: screens, visibleAreas: visibleAreas),
              isOnScreen(divider, screens: screens, visibleAreas: visibleAreas),
              abs(arrow.midY - divider.midY) < 4 else { return false }
        // Both controls must be visible in the same physical menu bar.
        return screens.contains { screen in
            screen.contains(arrow) && screen.contains(divider) && divider.maxX <= arrow.minX + 2
        }
    }

    static func menuBarBand(screen: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: screen.minX, y: screen.maxY - max(24, min(80, height)),
               width: screen.width, height: max(24, min(80, height)))
    }

    static func isMenuBarPopup(_ rect: CGRect, screen: CGRect, barHeight: CGFloat) -> Bool {
        let band = menuBarBand(screen: screen, height: barHeight)
        // A menu anchored to the bar starts just below it. Unrelated floating
        // windows elsewhere on the desktop must not suspend the timer forever.
        return rect.height > band.height + 2
            && rect.maxX > screen.minX && rect.minX < screen.maxX
            && rect.maxY <= screen.maxY + 2 && rect.maxY >= band.minY - 24
    }
}

/// Wait for both menu-opening latency and a continuous idle interval. All times
/// are monotonic; interaction resets the interval instead of racing a fixed delay.
struct MenuBarFoldRestoration {
    let startedAt: TimeInterval
    private var idleSince: TimeInterval?

    init(startedAt: TimeInterval) { self.startedAt = startedAt }

    mutating func shouldRestore(at now: TimeInterval, isInteracting: Bool) -> Bool {
        guard !isInteracting else {
            idleSince = nil
            return false
        }
        if idleSince == nil { idleSince = now }
        return now - startedAt >= 1 && now - (idleSince ?? now) >= 0.75
    }
}
