import AppKit
import CoreGraphics
import Testing
@testable import DeskNest

@MainActor
struct MenuBarItemCatalogTests {
    private func context(divider: CGRect = CGRect(x: 1200, y: 1084, width: 18, height: 33),
                         expanded: Bool = true,
                         screen: CGRect = CGRect(x: 0, y: 0, width: 1728, height: 1117),
                         excluded: Set<CGWindowID> = [], capture: Bool = false) -> MenuBarCatalogContext {
        MenuBarCatalogContext(dividerFrame: divider, isExpanded: expanded, screenFrame: screen,
                              mainDisplayHeight: 1117, excludedProcessID: 999,
                              captureIcons: capture, excludedWindowIDs: excluded)
    }

    private func row(_ id: CGWindowID, x: CGFloat, y: CGFloat = 0, width: CGFloat = 24,
                     height: CGFloat = 33, level: Int = 25, pid: pid_t = 55,
                     title: String? = nil, alpha: Double = 1,
                     onScreen: Bool = true) -> [String: Any] {
        var result: [String: Any] = [
            kCGWindowNumber as String: id,
            kCGWindowOwnerPID as String: pid,
            kCGWindowOwnerName as String: "Example",
            kCGWindowLayer as String: level,
            kCGWindowAlpha as String: alpha,
            kCGWindowIsOnscreen as String: onScreen,
            kCGWindowBounds as String: CGRect(x: x, y: y, width: width, height: height).dictionaryRepresentation
        ]
        if let title { result[kCGWindowName as String] = title }
        return result
    }

    @Test func listsOnlyLeftSectionInVisualOrder() {
        let rows = [row(1, x: 1150), row(2, x: 1225), row(3, x: 1100), row(4, x: 1190)]
        let result = MenuBarItemCatalog.candidates(from: rows, in: context())
        #expect(result.map(\.windowID) == [3, 1])
        #expect(result.allSatisfy { $0.frame.minY == 1084 })
    }

    @Test func foldedWindowsRemainEligibleOffScreen() {
        let divider = CGRect(x: -1000, y: 1084, width: 2218, height: 33)
        let rows = [row(1, x: -1100, onScreen: false), row(2, x: -1060, onScreen: false),
                    row(3, x: 1250), row(4, x: -1010)]
        let result = MenuBarItemCatalog.candidates(from: rows, in: context(divider: divider, expanded: false))
        #expect(result.map(\.windowID) == [1, 2])
        #expect(result.first?.frame.minX == -1100)
    }

    @Test func matchesInsetStatusButtonToTallerSystemProxyWindow() {
        let insetButton = CGRect(x: 1200, y: 1089.5, width: 18, height: 22)
        let rows = [row(1, x: 1150)]
        #expect(MenuBarItemCatalog.candidates(from: rows, in: context(divider: insetButton)).map(\.windowID) == [1])
        let foldedButton = CGRect(x: -1000, y: 1089.5, width: 2218, height: 22)
        #expect(MenuBarItemCatalog.candidates(from: [row(2, x: -1050, onScreen: false)],
                                             in: context(divider: foldedButton, expanded: false)).map(\.windowID) == [2])
    }

    @Test func ignoresVisibleItemsOnAnotherDisplayWithTheSameBaseline() {
        let divider = CGRect(x: -1000, y: 1084, width: 2218, height: 33)
        let rows = [row(1, x: -1100, onScreen: true), row(2, x: -1150, onScreen: false)]
        #expect(MenuBarItemCatalog.candidates(from: rows, in: context(divider: divider, expanded: false)).map(\.windowID) == [2])
        #expect(MenuBarItemCatalog.candidates(from: rows, in: context()).isEmpty)
    }

    @Test func skipsForeignLevelsPopupsBackgroundsAndTransparentWindows() {
        let rows = [row(1, x: 1000, level: 24), row(2, x: 1000, level: 101),
                    row(3, x: 0, width: 1000), row(4, x: 1000, y: 100),
                    row(5, x: 1000, height: 150), row(6, x: 1000, alpha: 0),
                    row(7, x: 1000)]
        #expect(MenuBarItemCatalog.candidates(from: rows, in: context()).map(\.windowID) == [7])
    }

    @Test func excludesOwnProcessAndProxyItemsAndExplicitWindowIDs() {
        let rows = [row(1, x: 1000, pid: 999), row(2, x: 1030, title: "DeskNest.Main"),
                    row(3, x: 1060, title: "DeskNest.MenuBarOrganizer.Toggle"),
                    row(4, x: 1090), row(5, x: 1120)]
        #expect(MenuBarItemCatalog.candidates(from: rows, in: context(excluded: [4])).map(\.windowID) == [5])
    }

    @Test func convertsNegativeOriginDisplayUsingPrimaryCoordinateHeight() {
        let screen = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let divider = CGRect(x: -100, y: 676, width: 18, height: 24)
        let rows = [row(1, x: -160, y: 417, height: 24), row(2, x: -160, y: 0)]
        let result = MenuBarItemCatalog.candidates(from: rows, in: context(divider: divider, screen: screen))
        #expect(result.map(\.windowID) == [1])
        #expect(result.first?.frame == CGRect(x: -160, y: 676, width: 24, height: 24))
    }

    @Test func deduplicatesAndIgnoresMissingOrInvalidMetadata() {
        var missingPID = row(2, x: 900)
        missingPID.removeValue(forKey: kCGWindowOwnerPID as String)
        let rows = [row(1, x: 1000), row(1, x: 1000), missingPID, row(3, x: 950, width: 0),
                    row(4, x: 950, pid: 0), row(0, x: 950)]
        #expect(MenuBarItemCatalog.candidates(from: rows, in: context()).map(\.windowID) == [1])
        #expect(MenuBarItemCatalog.candidates(from: rows, in: context(divider: .zero)).isEmpty)
    }

    @Test func genericHostTitlesDoNotPretendToIdentifyAnApplication() {
        let result = MenuBarItemCatalog.candidates(from: [row(1, x: 1000, title: "Item-0"),
                                                         row(2, x: 1030, title: "WiFi")], in: context())
        #expect(result[0].displayName == "菜单栏项目")
        #expect(result[1].displayName == "Wi-Fi")
        #expect(result.allSatisfy { !$0.isActualIcon && $0.icon == nil })
    }

    @Test func transparentCapturesDoNotReplaceFallbackIcons() throws {
        let canvas = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let empty = try #require(canvas.makeImage())
        #expect(!MenuBarItemCatalog.containsVisiblePixels(empty))
        canvas.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.5))
        canvas.fill(CGRect(x: 3, y: 3, width: 2, height: 2))
        let filled = try #require(canvas.makeImage())
        #expect(MenuBarItemCatalog.containsVisiblePixels(filled))
    }

    @Test func visibleRegionUsesOnlyTheVerifiedItemsQuartzRectangle() throws {
        let rows = [row(1, x: 1150)]
        let allowed = context(capture: true)
        let item = try #require(MenuBarItemCatalog.candidates(from: rows, in: allowed).first)
        #expect(MenuBarItemCatalog.visibleCaptureRegion(for: item, in: allowed, metadata: rows)
                == CGRect(x: 1150, y: 0, width: 24, height: 33))
        #expect(MenuBarItemCatalog.visibleCaptureRegion(for: item, in: context(), metadata: rows) == nil)
        #expect(MenuBarItemCatalog.visibleCaptureRegion(for: item, in: context(expanded: false, capture: true), metadata: rows) == nil)
    }

    @Test func visibleRegionRejectsAnyTargetChangeOrDisappearance() throws {
        let allowed = context(capture: true)
        let item = try #require(MenuBarItemCatalog.candidates(from: [row(1, x: 1150)], in: allowed).first)
        let invalidRows: [[[String: Any]]] = [
            [], [row(2, x: 1150)], [row(1, x: 1150, pid: 56)],
            [row(1, x: 1151)], [row(1, x: 1150, width: 25)],
            [row(1, x: 1150, onScreen: false)], [row(1, x: 1150, level: 0)],
            [row(1, x: 1150, alpha: 0)]
        ]
        for rows in invalidRows {
            #expect(MenuBarItemCatalog.visibleCaptureRegion(for: item, in: allowed, metadata: rows) == nil)
        }
    }

    @Test func visibleRegionNeverCapturesPartiallyOffscreenOrNonMenuContent() {
        let allowed = context(capture: true)
        let cases = [row(1, x: -5), row(2, x: 1000, y: 40), row(3, x: 1000, width: 600),
                     row(4, x: -1100, onScreen: false)]
        for data in cases {
            let id = data[kCGWindowNumber as String] as! UInt32
            let quartz = CGRect(dictionaryRepresentation: data[kCGWindowBounds as String] as! CFDictionary)!
            let item = FoldedMenuBarItem(windowID: id, pid: 55, ownerName: "Example", title: nil,
                                        frame: CGRect(x: quartz.minX, y: 1117 - quartz.maxY,
                                                      width: quartz.width, height: quartz.height),
                                        icon: nil, isActualIcon: false)
            #expect(MenuBarItemCatalog.visibleCaptureRegion(for: item, in: allowed, metadata: [data]) == nil)
        }
    }

    @Test func visibleRegionPreservesGlobalCoordinatesOnANegativeOriginDisplay() throws {
        let screen = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let divider = CGRect(x: -100, y: 676, width: 18, height: 24)
        let allowed = context(divider: divider, screen: screen, capture: true)
        let rows = [row(1, x: -160, y: 417, height: 24)]
        let item = try #require(MenuBarItemCatalog.candidates(from: rows, in: allowed).first)
        #expect(MenuBarItemCatalog.visibleCaptureRegion(for: item, in: allowed, metadata: rows)
                == CGRect(x: -160, y: 417, width: 24, height: 24))
    }
}
