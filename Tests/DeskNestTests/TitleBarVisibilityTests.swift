import Foundation
import Testing
@testable import DeskNest

struct TitleBarVisibilityTests {
    @Test func legacyWidgetsKeepTheirTitleBars() throws {
        for kind in [WidgetKind.files, .systemMonitor] {
            let original = DesktopWidget(title: kind.title, kind: kind)
            let data = try JSONEncoder().encode(original)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["titleBarVisible"] == nil)
            #expect(try JSONDecoder().decode(DesktopWidget.self, from: data).showsTitleBar)
        }
    }

    @Test @MainActor func titleBarChoicePersistsIndependentlyAndCanBeRestored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let firstID = try #require(store.widgets.first?.id)
        let monitorID = store.addWidget(kind: .systemMonitor)
        let before = store.widgets
        store.setTitleBarVisible(id: firstID, visible: false)
        let restored = WorkspaceStore(directory: directory)
        #expect(restored.widgets.first { $0.id == firstID }?.showsTitleBar == false)
        #expect(restored.widgets.first { $0.id == monitorID }?.showsTitleBar == true)
        for old in before {
            var expected = old
            if old.id == firstID { expected.titleBarVisible = false }
            #expect(restored.widgets.first { $0.id == old.id } == expected)
        }
        restored.setTitleBarVisible(id: firstID, visible: true)
        restored.setTitleBarVisible(id: monitorID, visible: false)
        let final = WorkspaceStore(directory: directory)
        #expect(final.widgets.first { $0.id == firstID }?.showsTitleBar == true)
        #expect(final.widgets.first { $0.id == monitorID }?.showsTitleBar == false)
    }
}
