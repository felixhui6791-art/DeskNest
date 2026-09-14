import AppKit

/// Keeps one file picker shared by the manager and every desktop group.
@MainActor
enum FileImportCoordinator {
    static private(set) var activePanel: NSOpenPanel?

    static func present(store: WorkspaceStore, widgetID: UUID, applications: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)

        if let panel = activePanel {
            panel.sheetParent?.makeKeyAndOrderFront(nil)
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            return
        }

        // Only the manager is a titled main window; desktop cards are NSPanels.
        // Capture it before presenting a picker, which becomes the key window.
        let parent = NSApp.keyWindow.flatMap { window -> NSWindow? in
            guard !(window is NSPanel), window.canBecomeMain,
                  window.styleMask.contains(.titled), window.isVisible,
                  !window.isMiniaturized, window.attachedSheet == nil else { return nil }
            return window
        }

        let panel = NSOpenPanel()
        panel.title = applications ? "添加常用应用" : "添加到文件分区"
        panel.prompt = "添加入口"
        panel.message = "可以多选文件、文件夹或应用。添加入口后，原文件仍保留在原位置。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.resolvesAliases = true
        panel.level = .modalPanel
        if applications { panel.directoryURL = URL(fileURLWithPath: "/Applications") }
        activePanel = panel

        if let parent {
            parent.makeKeyAndOrderFront(nil)
            panel.beginSheetModal(for: parent) { response in
                finish(panel: panel, response: response, store: store, widgetID: widgetID)
            }
        } else {
            panel.begin { response in
                finish(panel: panel, response: response, store: store, widgetID: widgetID)
            }
        }

        // A floating desktop group must not obscure the picker, even if it was
        // invoked from a nonactivating panel while another app was foreground.
        panel.level = .modalPanel
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private static func finish(panel: NSOpenPanel, response: NSApplication.ModalResponse, store: WorkspaceStore, widgetID: UUID) {
        let urls = response == .OK ? panel.urls : []
        if activePanel === panel { activePanel = nil }
        if !urls.isEmpty { store.addItems(urls: urls, to: widgetID) }
    }
}
