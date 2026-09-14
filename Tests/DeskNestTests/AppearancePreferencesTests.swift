import Foundation
import Testing
@testable import DeskNest

@MainActor
struct AppearancePreferencesTests {
    @Test
    func newWorkspacePersistsBothAppearanceDefaults() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let saved = try document(in: directory)

        #expect(store.partitionTransparency == AppearanceSettings.defaultPartitionTransparency)
        #expect(store.menuBarTransparency == AppearanceSettings.defaultMenuBarTransparency)
        #expect(saved["partitionTransparency"] as? Double == store.partitionTransparency)
        #expect(saved["menuBarTransparency"] as? Double == store.menuBarTransparency)
        #expect(store.lastError == nil)
    }

    @Test
    func legacyAppearanceMigrationPreservesFilesLayoutAndOriginalDocument() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let widgetID = try #require(store.widgets.first?.id)
        let original = directory.appendingPathComponent("original.txt")
        let originalData = Data("keep my original content".utf8)
        try originalData.write(to: original)
        store.addItems(urls: [original], to: widgetID)
        store.setFrame(id: widgetID, frame: WidgetFrame(x: -500, y: 100, width: 320, height: 280))
        store.addReservedArea(frame: WidgetFrame(x: 80, y: 200, width: 180, height: 180))
        store.menuBarAutoCollapseDelay = 15
        store.panelsVisible = false
        var legacy = try document(in: directory)
        legacy.removeValue(forKey: "partitionTransparency")
        legacy.removeValue(forKey: "menuBarTransparency")
        let data = try write(legacy, in: directory)

        let restored = WorkspaceStore(directory: directory)
        #expect(restored.partitionTransparency == AppearanceSettings.defaultPartitionTransparency)
        #expect(restored.menuBarTransparency == AppearanceSettings.defaultMenuBarTransparency)
        #expect(restored.widgets == store.widgets)
        #expect(restored.reservedAreas == store.reservedAreas)
        #expect(restored.menuBarAutoCollapseDelay == 15)
        #expect(!restored.panelsVisible)
        #expect(restored.lastError == nil)
        #expect(try Data(contentsOf: directory.appendingPathComponent("workspace.json")) == data)

        restored.partitionTransparency = 0.60
        let reopened = WorkspaceStore(directory: directory)
        #expect(reopened.widgets == store.widgets)
        #expect(reopened.reservedAreas == store.reservedAreas)
        #expect(reopened.partitionTransparency == 0.60)
        #expect(reopened.menuBarTransparency == AppearanceSettings.defaultMenuBarTransparency)
        #expect(try Data(contentsOf: original) == originalData)
    }

    @Test(arguments: [0.0, 0.35, 0.85])
    func appearanceChangesPersistIndependently(value: Double) throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let expectedWidgets = store.widgets
        store.partitionTransparency = value
        var restored = WorkspaceStore(directory: directory)
        #expect(restored.partitionTransparency == value)
        #expect(restored.menuBarTransparency == AppearanceSettings.defaultMenuBarTransparency)

        restored.menuBarTransparency = value
        restored = WorkspaceStore(directory: directory)
        #expect(restored.partitionTransparency == value)
        #expect(restored.menuBarTransparency == value)
        #expect(restored.widgets == expectedWidgets)
        #expect(restored.lastError == nil)
    }

    @Test
    func malformedOptionalAppearanceFieldsDoNotDiscardOtherPreferences() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let baseline = try document(in: directory)
        let malformedValues: [Any] = ["0.4", true, NSNull(), [0.4], ["value": 0.4], "NaN", "Infinity"]

        for key in ["partitionTransparency", "menuBarTransparency"] {
            for malformed in malformedValues {
                var invalid = baseline
                invalid["partitionTransparency"] = 0.40
                invalid["menuBarTransparency"] = 0.60
                invalid[key] = malformed
                let invalidData = try write(invalid, in: directory)
                let restored = WorkspaceStore(directory: directory)
                #expect(restored.partitionTransparency == (key == "partitionTransparency"
                    ? AppearanceSettings.defaultPartitionTransparency : 0.40))
                #expect(restored.menuBarTransparency == (key == "menuBarTransparency"
                    ? AppearanceSettings.defaultMenuBarTransparency : 0.60))
                #expect(restored.widgets == store.widgets)
                #expect(restored.lastError == nil)
                #expect(try Data(contentsOf: directory.appendingPathComponent("workspace.json")) == invalidData)
                restored.panelsVisible = false
                #expect(WorkspaceStore(directory: directory).lastError == nil)
            }
        }
    }

    @Test(arguments: [-Double.greatestFiniteMagnitude, -0.1, 0.9, Double.greatestFiniteMagnitude])
    func outOfRangeStoredValuesClampWithoutCorruptingWorkspace(value: Double) throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        var invalid = try document(in: directory)
        invalid["partitionTransparency"] = value
        invalid["menuBarTransparency"] = value
        try write(invalid, in: directory)
        let restored = WorkspaceStore(directory: directory)
        let expected = value < 0 ? 0.0 : 0.85

        #expect(restored.partitionTransparency == expected)
        #expect(restored.menuBarTransparency == expected)
        #expect(restored.widgets == store.widgets)
        #expect(restored.lastError == nil)
        restored.panelsVisible = false
        let saved = try document(in: directory)
        #expect(saved["partitionTransparency"] as? Double == expected)
        #expect(saved["menuBarTransparency"] as? Double == expected)
    }

    @Test
    func invalidAssignmentsCannotMakeTheWorkspaceUnencodable() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let values = [Double.nan, .infinity, -.infinity, -1, 1]

        for value in values {
            store.partitionTransparency = 0.50
            store.menuBarTransparency = 0.50
            store.partitionTransparency = value
            store.menuBarTransparency = value
            let expectedPartition = value.isFinite
                ? (value < 0 ? 0.0 : 0.85) : AppearanceSettings.defaultPartitionTransparency
            let expectedMenuBar = value.isFinite
                ? (value < 0 ? 0.0 : 0.85) : AppearanceSettings.defaultMenuBarTransparency
            #expect(store.partitionTransparency == expectedPartition)
            #expect(store.menuBarTransparency == expectedMenuBar)
            #expect(store.lastError == nil)
            let restored = WorkspaceStore(directory: directory)
            #expect(restored.partitionTransparency == expectedPartition)
            #expect(restored.menuBarTransparency == expectedMenuBar)
            #expect(restored.widgets == store.widgets)
            #expect(restored.lastError == nil)
        }
    }

    @Test
    func appearanceChangesRespectPausedSavingForUnknownWorkspaceVersions() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = WorkspaceStore(directory: directory)
        var future = try document(in: directory)
        future["schemaVersion"] = 999
        let originalData = try write(future, in: directory)
        let store = WorkspaceStore(directory: directory)
        store.partitionTransparency = 0.55
        store.menuBarTransparency = 0.65

        #expect(store.lastError?.contains("更新版本") == true)
        #expect(try Data(contentsOf: directory.appendingPathComponent("workspace.json")) == originalData)
    }

    @Test func glassColorsPersistIndependentlyAndAllowPerPartitionOverride() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let id = try #require(store.widgets.first?.id)
        let originalWidgets = store.widgets
        store.partitionTransparency = 0.34
        store.menuBarTransparency = 0.57
        store.partitionGlassTone = .lightGray
        store.menuBarGlassTone = .spaceGray
        for tone in GlassTone.allCases {
            store.updateGlassTone(id: id, tone: tone)
            let restored = WorkspaceStore(directory: directory)
            #expect(restored.widgets.first?.glassTone == tone)
            #expect(restored.partitionGlassTone == .lightGray)
            #expect(restored.menuBarGlassTone == .spaceGray)
            #expect(restored.partitionTransparency == 0.34)
            #expect(restored.menuBarTransparency == 0.57)
            #expect(restored.widgets.first?.frame == originalWidgets.first?.frame)
            #expect(restored.widgets.first?.items == originalWidgets.first?.items)
        }
        store.updateGlassTone(id: id, tone: nil)
        let restored = WorkspaceStore(directory: directory)
        #expect(restored.widgets == originalWidgets)
        #expect(restored.partitionGlassTone == .lightGray)
    }

    @Test func legacyWorkspaceWithoutGlassColorsLoadsWithoutRewriting() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        store.menuBarTransparency = 0.57
        var legacy = try document(in: directory)
        legacy.removeValue(forKey: "partitionGlassTone")
        legacy.removeValue(forKey: "menuBarGlassTone")
        let original = try write(legacy, in: directory)
        let restored = WorkspaceStore(directory: directory)
        #expect(restored.partitionGlassTone == .frost)
        #expect(restored.menuBarGlassTone == .frost)
        #expect(restored.widgets == store.widgets)
        #expect(restored.menuBarTransparency == 0.57)
        #expect(try Data(contentsOf: directory.appendingPathComponent("workspace.json")) == original)
    }

    @Test func unknownGlassColorsFallBackWithoutDiscardingPartitions() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        var saved = try document(in: directory)
        saved["partitionGlassTone"] = "future-color"
        saved["menuBarGlassTone"] = ["invalid": true]
        var widgets = try #require(saved["widgets"] as? [[String: Any]])
        widgets[0]["glassTone"] = "retired-color"
        saved["widgets"] = widgets
        let original = try write(saved, in: directory)
        let restored = WorkspaceStore(directory: directory)
        #expect(restored.partitionGlassTone == .frost)
        #expect(restored.menuBarGlassTone == .frost)
        #expect(restored.widgets.first?.glassTone == .frost)
        #expect(restored.widgets.map(\.id) == store.widgets.map(\.id))
        #expect(restored.lastError == nil)
        #expect(try Data(contentsOf: directory.appendingPathComponent("workspace.json")) == original)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "DeskNestAppearanceTests-\(UUID().uuidString)", isDirectory: true
        )
    }

    private func document(in directory: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("workspace.json"))) as? [String: Any])
    }

    @discardableResult
    private func write(_ document: [String: Any], in directory: URL) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: document)
        try data.write(to: directory.appendingPathComponent("workspace.json"))
        return data
    }
}
