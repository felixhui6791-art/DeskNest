import Foundation
import Testing
@testable import DeskNest

@MainActor
struct WorkspaceStoreTests {
    @Test
    func initialWorkspaceIsEmptyOfUserFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)

        #expect(store.widgets.map(\.title) == ["进行中的项目", "常用入口"])
        #expect(store.widgets.allSatisfy { $0.kind == .files && $0.items.isEmpty })
        #expect(store.lastError == nil)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("workspace.json").path))
    }

    @Test
    func widgetStateAndSettingsSurviveReload() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let noteID = store.addWidget(kind: .note)
        store.updateTitle(id: noteID, title: "下一步")
        store.updateNote(id: noteID, text: "整理桌面\n开始创作 ✨")
        store.updateTint(id: noteID, tint: .lavender)
        let frame = WidgetFrame(x: -480, y: 120, width: 320, height: 280)
        store.setFrame(id: noteID, frame: frame)
        store.toggleLock(id: noteID)
        store.toggleWidgetVisibility(id: noteID)
        store.panelsVisible = false

        let restored = WorkspaceStore(directory: directory)
        let note = try #require(restored.widgets.first(where: { $0.id == noteID }))
        #expect(note.title == "下一步")
        #expect(note.note == "整理桌面\n开始创作 ✨")
        #expect(note.tint == .lavender)
        #expect(note.frame == frame)
        #expect(note.isLocked)
        #expect(!note.isVisible)
        #expect(!restored.panelsVisible)
        #expect(restored.lastError == nil)
    }

    @Test
    func legacyFloatingPreferenceDoesNotLoseWorkspaceData() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let widgetID = try #require(store.widgets.first?.id)
        let file = directory.appendingPathComponent("工作文档.txt")
        try Data("keep this file".utf8).write(to: file)
        store.addItems(urls: [file], to: widgetID)
        store.updateTitle(id: widgetID, title: "我的资料")
        store.setFrame(id: widgetID, frame: WidgetFrame(x: 120, y: 240, width: 340, height: 300))
        store.toggleLock(id: widgetID)
        let expectedWidgets = store.widgets
        let document = directory.appendingPathComponent("workspace.json")
        var legacy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: document)) as? [String: Any])
        legacy["floatAboveWindows"] = true
        try JSONSerialization.data(withJSONObject: legacy).write(to: document)

        let restored = WorkspaceStore(directory: directory)
        #expect(restored.lastError == nil)
        #expect(restored.widgets == expectedWidgets)
        #expect(restored.panelsVisible)
        restored.panelsVisible = false
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: document)) as? [String: Any])
        #expect(saved["floatAboveWindows"] == nil)
        #expect(WorkspaceStore(directory: directory).widgets == expectedWidgets)
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep this file")
    }

    @Test
    func snappingAndReservedAreasSurviveReload() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        store.snappingEnabled = false
        store.avoidNativeWidgets = false
        let area = WidgetFrame(x: -900, y: 200, width: 180, height: 360)
        store.addReservedArea(frame: area)
        let restored = WorkspaceStore(directory: directory)
        #expect(!restored.snappingEnabled)
        #expect(!restored.avoidNativeWidgets)
        #expect(restored.reservedAreas.count == 1)
        #expect(restored.reservedAreas.first?.frame == area)
        let id = try #require(restored.reservedAreas.first?.id)
        restored.removeReservedArea(id: id)
        #expect(WorkspaceStore(directory: directory).reservedAreas.isEmpty)
    }

    @Test
    func olderWorkspacesReceiveLayoutDefaultsWithoutLosingGroups() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let document = directory.appendingPathComponent("workspace.json")
        var old = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: document)) as? [String: Any])
        for key in ["snappingEnabled", "avoidNativeWidgets", "reservedAreas"] { old.removeValue(forKey: key) }
        try JSONSerialization.data(withJSONObject: old).write(to: document)
        let restored = WorkspaceStore(directory: directory)
        #expect(restored.widgets == store.widgets)
        #expect(restored.snappingEnabled)
        #expect(restored.avoidNativeWidgets)
        #expect(restored.reservedAreas.isEmpty)
        #expect(restored.lastError == nil)
    }

    @Test
    func olderWorkspacesReceiveMenuBarDefaultsWithoutChangingContent() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let widgetID = try #require(store.widgets.first?.id)
        let file = directory.appendingPathComponent("保留资料.txt")
        try Data("original content".utf8).write(to: file)
        store.addItems(urls: [file], to: widgetID)
        store.setFrame(id: widgetID, frame: WidgetFrame(x: -600, y: 200, width: 340, height: 300))
        store.toggleLock(id: widgetID)
        store.addReservedArea(frame: WidgetFrame(x: 20, y: 300, width: 180, height: 180))
        let document = directory.appendingPathComponent("workspace.json")
        var old = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: document)) as? [String: Any])
        old.removeValue(forKey: "menuBarOrganizerEnabled")
        old.removeValue(forKey: "menuBarAutoCollapseDelay")
        let oldData = try JSONSerialization.data(withJSONObject: old)
        try oldData.write(to: document)

        let restored = WorkspaceStore(directory: directory)
        #expect(restored.menuBarOrganizerEnabled)
        #expect(restored.menuBarAutoCollapseDelay == 0)
        #expect(restored.widgets == store.widgets)
        #expect(restored.reservedAreas == store.reservedAreas)
        #expect(restored.lastError == nil)
        #expect(try Data(contentsOf: document) == oldData)
        #expect(try String(contentsOf: file, encoding: .utf8) == "original content")
    }

    @Test(arguments: [0, 5, 15, 30])
    func menuBarPreferencesSurviveReload(delay: Int) throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let expectedWidgets = store.widgets
        store.menuBarOrganizerEnabled = false
        store.menuBarAutoCollapseDelay = delay

        let restored = WorkspaceStore(directory: directory)
        #expect(!restored.menuBarOrganizerEnabled)
        #expect(restored.menuBarAutoCollapseDelay == delay)
        #expect(restored.widgets == expectedWidgets)
        #expect(restored.lastError == nil)
        restored.menuBarOrganizerEnabled = true
        #expect(WorkspaceStore(directory: directory).menuBarOrganizerEnabled)
    }

    @Test
    func invalidStoredMenuBarDelayFallsBackWithoutLosingWorkspace() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let document = directory.appendingPathComponent("workspace.json")
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: document)) as? [String: Any])
        let invalidDelays: [Any] = [-1, 10, 99, 15.5, "15", true, NSNull(), [5]]

        for delay in invalidDelays {
            var invalid = saved
            invalid["menuBarAutoCollapseDelay"] = delay
            let invalidData = try JSONSerialization.data(withJSONObject: invalid)
            try invalidData.write(to: document)
            let restored = WorkspaceStore(directory: directory)
            #expect(restored.menuBarAutoCollapseDelay == 0)
            #expect(restored.widgets == store.widgets)
            #expect(restored.lastError == nil)
            #expect(try Data(contentsOf: document) == invalidData)
            restored.menuBarOrganizerEnabled = false
            let normalized = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: document)) as? [String: Any])
            #expect(normalized["menuBarAutoCollapseDelay"] as? Int == 0)
        }
    }

    @Test
    func invalidAssignedMenuBarDelayIsNormalizedAndSaved() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        for delay in [-100, 1, 10, 60, Int.max] {
            store.menuBarAutoCollapseDelay = 15
            store.menuBarAutoCollapseDelay = delay
            #expect(store.menuBarAutoCollapseDelay == 0)
            #expect(WorkspaceStore(directory: directory).menuBarAutoCollapseDelay == 0)
            #expect(store.lastError == nil)
        }
    }

    @Test
    func fileReferencesDeduplicateAndRemovalPreservesOriginal() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let widgetID = try #require(store.widgets.first?.id)
        let file = directory.appendingPathComponent("original.txt")
        let alias = directory.appendingPathComponent("alias.txt")
        let contents = Data("an original file".utf8)
        try contents.write(to: file)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)

        store.addItems(urls: [file, file, alias], to: widgetID)
        #expect(store.widgets[0].items.count == 1)
        let itemID = try #require(store.widgets[0].items.first?.id)
        store.removeItem(id: itemID, from: widgetID)

        #expect(store.widgets[0].items.isEmpty)
        #expect(try Data(contentsOf: file) == contents)
        let restored = WorkspaceStore(directory: directory)
        #expect(restored.widgets[0].items.isEmpty)
    }

    @Test
    func corruptedWorkspaceNeverGetsOverwritten() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = directory.appendingPathComponent("workspace.json")
        let broken = Data("{ invalid json, preserve me".utf8)
        try broken.write(to: document)

        let store = WorkspaceStore(directory: directory)
        #expect(store.lastError?.contains("暂停自动保存") == true)
        store.addWidget(kind: .note)
        store.panelsVisible = false

        #expect(try Data(contentsOf: document) == broken)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("workspace.corrupt-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == broken)
    }

    @Test
    func futureWorkspaceVersionIsPreserved() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = WorkspaceStore(directory: directory)
        let document = directory.appendingPathComponent("workspace.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: document)) as? [String: Any])
        json["schemaVersion"] = 999
        let futureData = try JSONSerialization.data(withJSONObject: json)
        try futureData.write(to: document)

        let store = WorkspaceStore(directory: directory)
        #expect(store.lastError?.contains("更新版本") == true)
        store.addWidget(kind: .clock)
        #expect(try Data(contentsOf: document) == futureData)
    }

    @Test
    func missingFilesProduceActionableError() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let widgetID = try #require(store.widgets.first?.id)

        store.addItems(urls: [directory.appendingPathComponent("missing.txt")], to: widgetID)

        #expect(store.widgets[0].items.isEmpty)
        #expect(store.lastError?.contains("missing.txt") == true)
    }

    @Test
    func invalidFramesCannotCorruptPersistence() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let widgetID = try #require(store.widgets.first?.id)

        store.setFrame(id: widgetID, frame: WidgetFrame(x: .nan, y: 0, width: 320, height: 240))
        store.setFrame(id: widgetID, frame: WidgetFrame(x: 0, y: 0, width: -1, height: 240))

        #expect(store.widgets[0].frame == nil)
        #expect(WorkspaceStore(directory: directory).lastError == nil)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DeskNestTests-\(UUID().uuidString)", isDirectory: true)
    }
}
