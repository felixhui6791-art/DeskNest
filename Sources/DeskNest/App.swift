import AppKit
import Combine
import SwiftUI

@main
@MainActor
struct DeskNestLauncher {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var store: WorkspaceStore!
    private var desktop: DesktopPanelController!
    private var managerWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var errorObserver: AnyCancellable?
    private var reservedAreaPicker: ReservedAreaPicker?
    private let menuBarOrganizer = MenuBarOrganizerController()
    private let updates = AppUpdateController()
    private var menuBarSettingsObserver: AnyCancellable?
    private var updateReminderObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A separate directory makes development and UI checks independent of the user's layout.
        let arguments = ProcessInfo.processInfo.arguments
        let dataDirectory: URL?
        if let index = arguments.firstIndex(of: "--data-directory"), arguments.indices.contains(index + 1) {
            dataDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        } else {
            dataDirectory = nil
        }
        store = WorkspaceStore(directory: dataDirectory)
        updates.start()
        configureMainMenu()
        configureStatusItem()
        updateReminderObserver = updates.$availableVersion.sink { [weak self] version in
            self?.statusItem?.button?.image = NSImage(
                systemSymbolName: version == nil ? "square.grid.2x2" : "arrow.down.circle.fill",
                accessibilityDescription: version.map { "栖桌有更新：\($0)" } ?? "栖桌")
            self?.statusItem?.button?.toolTip = version.map { "新版本 \($0) 可用，点击菜单查看更新" }
                ?? "\(AppRelease.current.channel.applicationName) · 桌面分区"
        }
        menuBarSettingsObserver = store.$menuBarOrganizerEnabled
            .combineLatest(store.$menuBarAutoCollapseDelay, store.$menuBarTransparency, store.$menuBarGlassTone)
            .sink { [weak self] enabled, delay, transparency, tone in
                self?.menuBarOrganizer.configure(enabled: enabled, autoCollapseDelay: TimeInterval(delay),
                                                transparency: transparency, glassTone: tone)
            }
        desktop = DesktopPanelController(store: store) { [weak self] in self?.showManager() }
        desktop.start()
        errorObserver = store.$lastError
            .removeDuplicates()
            .compactMap { $0 }
            .sink { [weak self] _ in
                // Errors from a desktop card must be visible even when its manager is closed.
                Task { @MainActor [weak self] in
                    guard let self, self.store.lastError != nil else { return }
                    self.showManager()
                }
            }
        showManager()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarOrganizer.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showManager()
        return true
    }

    @objc func showManager() {
        if managerWindow == nil {
            let content = ManagerView(
                store: store,
                updates: updates,
                menuBarOrganizer: menuBarOrganizer,
                arrange: { [weak self] in self?.desktop.arrangePanels() },
                showDesktop: { [weak self] in self?.revealDesktopPanels() },
                scanDesktop: { [weak self] in self?.desktop.refreshDesktopObstacles() },
                markReservedArea: { [weak self] in self?.markReservedArea() }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "\(AppRelease.current.channel.applicationName) · 我的桌面"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor(calibratedRed: 0.967, green: 0.967, blue: 0.952, alpha: 1)
            window.minSize = NSSize(width: 960, height: 640)
            window.contentView = NSHostingView(rootView: content)
            window.delegate = self
            window.setFrameAutosaveName("DeskNestManager")
            if !window.setFrameUsingName("DeskNestManager") { window.center() }
            managerWindow = window
        }
        managerWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func revealDesktopPanels() {
        store.panelsVisible = true
        managerWindow?.orderOut(nil)
    }

    @objc private func togglePanels() { store.panelsVisible.toggle() }
    @objc private func showMenuBarSettings() {
        showManager()
        NotificationCenter.default.post(name: .deskNestShowMenuBarOrganizer, object: nil)
    }
    @objc private func toggleMenuBarItems() { menuBarOrganizer.toggle() }
    @objc private func expandMenuBarItems() { menuBarOrganizer.expand() }
    @objc private func arrangePanels() { desktop.arrangePanels() }
    @objc private func scanDesktop() { desktop.refreshDesktopObstacles() }
    @objc private func markReservedArea() {
        guard reservedAreaPicker == nil else { return }
        let reopenManager = managerWindow?.isVisible ?? false
        managerWindow?.orderOut(nil)
        let picker = ReservedAreaPicker { [weak self] frame in
            guard let self else { return }
            if let frame { self.store.addReservedArea(frame: frame) }
            self.reservedAreaPicker = nil
            if reopenManager && NSApp.isActive { self.showManager() }
        }
        reservedAreaPicker = picker
        picker.begin()
    }
    @objc private func newWidget() {
        _ = store.addWidget(kind: .files)
        store.panelsVisible = true
        showManager()
    }
    @objc private func checkForUpdates() { updates.checkForUpdates() }
    @objc private func terminate() { NSApp.terminate(nil) }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "DeskNest.Main"
        item.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "栖桌")
        item.button?.toolTip = "\(AppRelease.current.channel.applicationName) · 桌面分区"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        menuBarOrganizer.excludedStatusWindowIDs = { [weak self] in
            guard let number = self?.statusItem?.button?.window?.windowNumber,
                  let id = MenuBarOrganizerGeometry.windowID(for: number) else { return [] }
            return [id]
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        append("打开管理窗口", action: #selector(showManager), key: "", to: menu)
        append("新建文件分区", action: #selector(newWidget), key: "", to: menu)
        menu.addItem(.separator())
        append("菜单栏整理…", action: #selector(showMenuBarSettings), key: "", to: menu)
        if menuBarOrganizer.isEnabled {
            append(menuBarOrganizer.isTrayShown ? "关闭折叠区面板" : "在下方显示折叠区", action: #selector(toggleMenuBarItems), key: "", to: menu)
            append("调整图标位置", action: #selector(expandMenuBarItems), key: "", to: menu)
        }
        menu.addItem(.separator())
        append(store.panelsVisible ? "隐藏桌面分区" : "显示桌面分区", action: #selector(togglePanels), key: "", to: menu)
        append("整理分区布局", action: #selector(arrangePanels), key: "", to: menu)
        append("扫描桌面组件", action: #selector(scanDesktop), key: "", to: menu)
        append("标记保留区域…", action: #selector(markReservedArea), key: "", to: menu)
        menu.addItem(.separator())
        append(updates.availableVersion.map { "安装更新 \($0)…" } ?? "检查更新…",
               action: #selector(checkForUpdates), key: "", to: menu)
        append("退出栖桌", action: #selector(terminate), key: "q", to: menu)
    }

    private func configureMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "栖桌")
        append("打开管理窗口", action: #selector(showManager), key: "0", to: appMenu)
        append("菜单栏整理…", action: #selector(showMenuBarSettings), key: ",", to: appMenu)
        appMenu.addItem(.separator())
        append("检查更新…", action: #selector(checkForUpdates), key: "", to: appMenu)
        append("退出栖桌", action: #selector(terminate), key: "q", to: appMenu)
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        append("新建文件分区", action: #selector(newWidget), key: "n", to: fileMenu)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [
            ("撤销", Selector(("undo:")), "z"),
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a")
        ] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func append(_ title: String, action: Selector, key: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }
}
