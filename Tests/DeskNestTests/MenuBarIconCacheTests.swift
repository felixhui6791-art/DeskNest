import CoreGraphics
import Testing
@testable import DeskNest

struct MenuBarIconCacheTests {
    private func item(id: CGWindowID = 7, pid: Int32 = 40, title: String = "Item-1",
                      width: CGFloat = 20, x: CGFloat = 100) -> FoldedMenuBarItem {
        FoldedMenuBarItem(windowID: id, pid: pid, ownerName: "Control Center", title: title,
                         frame: CGRect(x: x, y: 1084, width: width, height: 33), icon: nil, isActualIcon: false)
    }

    @Test func oldPreviewStaysVisibleWhileDueForRefresh() {
        var cache = MenuBarIconCache<String>()
        let identity = MenuBarIconCache<String>.Identity(item())
        cache.insert("last good icon", for: identity, at: 100)
        #expect(!cache.needsRefresh(identity, at: 114.9))
        #expect(cache.needsRefresh(identity, at: 115))
        #expect(cache.needsRefresh(identity, at: 3600))
        #expect(cache.image(for: identity) == "last good icon")
        cache.insert("updated icon", for: identity, at: 3600)
        #expect(cache.image(for: identity) == "updated icon")
        #expect(!cache.needsRefresh(identity, at: 3601))
    }

    @Test func reusedWindowOrChangedShapeCannotBorrowOldImage() {
        var cache = MenuBarIconCache<String>()
        cache.insert("original", for: .init(item()), at: 0)
        for changed in [item(pid: 41), item(title: "Item-2"), item(width: 40)] {
            #expect(cache.image(for: .init(changed)) == nil)
            #expect(cache.needsRefresh(.init(changed), at: 1))
        }
    }

    @Test func foldingPositionDoesNotInvalidatePreview() {
        var cache = MenuBarIconCache<String>()
        cache.insert("original", for: .init(item(x: 1201)), at: 0)
        #expect(cache.image(for: .init(item(x: -637))) == "original")
    }

    @Test func closedApplicationsAndRevokedPermissionDiscardCache() {
        var cache = MenuBarIconCache<String>()
        cache.insert("one", for: .init(item()), at: 0)
        cache.insert("two", for: .init(item(id: 8, pid: 41)), at: 0)
        cache.retainWindows([7: 40])
        #expect(cache.image(for: .init(item())) == "one")
        #expect(cache.image(for: .init(item(id: 8, pid: 41))) == nil)
        cache.removeAll()
        #expect(cache.image(for: .init(item())) == nil)
    }

    @Test func cacheIsBoundedAcrossManyStatusWindows() {
        var cache = MenuBarIconCache<String>()
        for id in 1...257 {
            cache.insert("icon", for: .init(item(id: UInt32(id))), at: Double(id))
        }
        #expect(cache.image(for: .init(item(id: 1))) == nil)
        #expect(cache.image(for: .init(item(id: 257))) == "icon")
    }
}
