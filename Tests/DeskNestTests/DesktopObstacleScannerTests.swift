import AppKit
import CoreGraphics
import Testing
@testable import DeskNest

@MainActor
struct DesktopObstacleScannerTests {
    private let desktopIconLevel = -2_147_483_603
    private let mainScreen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    @Test
    func observedDesktopWidgetsUseAppKitCoordinatesAndRemainBestEffort() {
        let result = analyze([
            window(id: 71, frame: CGRect(x: 8, y: 41, width: 180, height: 180)),
            window(id: 70, frame: CGRect(x: 8, y: 221, width: 360, height: 180))
        ])
        #expect(result.obstacles.map(\.frame) == [
            CGRect(x: 8, y: 896, width: 180, height: 180),
            CGRect(x: 8, y: 716, width: 360, height: 180)
        ])
        #expect(result.isLimited)
        #expect(result.message.contains("2 个"))
    }

    @Test
    func ignoresBackgroundsNotificationsMenusOrdinaryAppsAndOwnWindows() {
        let square = CGRect(x: 10, y: 50, width: 180, height: 180)
        let result = analyze([
            window(id: 1, frame: mainScreen, bundle: "com.apple.finder", layer: desktopIconLevel),
            window(id: 2, frame: mainScreen, bundle: "com.apple.dock", layer: 20),
            window(id: 3, frame: square, layer: 0),
            window(id: 4, frame: CGRect(x: 1350, y: 0, width: 378, height: 1117), layer: 0),
            window(id: 5, frame: square, layer: 101),
            window(id: 6, frame: square, bundle: "com.example.desktop-app"),
            window(id: 7, frame: square, owner: 999),
            window(id: 8, frame: mainScreen),
            window(id: 9, frame: square, bundle: nil)
        ])
        #expect(result.obstacles.isEmpty)
        #expect(result.isLimited)
        #expect(result.message.contains("不能据此判断桌面为空"))
    }

    @Test
    func rejectsHiddenOffscreenInvalidAndImplausibleSurfaces() {
        let square = CGRect(x: 10, y: 50, width: 180, height: 180)
        let result = analyze([
            window(id: 1, frame: square, onScreen: false),
            window(id: 2, frame: square, alpha: 0),
            window(id: 3, frame: CGRect(x: 5000, y: 50, width: 180, height: 180)),
            window(id: 4, frame: CGRect(x: 10, y: 50, width: 30, height: 30)),
            window(id: 5, frame: CGRect(x: 10, y: 50, width: 901, height: 300)),
            window(id: 6, frame: CGRect(x: CGFloat.nan, y: 50, width: 180, height: 180)),
            window(id: 7, frame: CGRect(x: 10, y: 50, width: -180, height: 180)),
            window(id: 8, frame: CGRect(x: 10, y: 50, width: 700, height: 100))
        ])
        #expect(result.obstacles.isEmpty)
    }

    @Test
    func translatesDisplaysToTheLeftAboveAndBelowTheMainDisplay() {
        let screens = [
            mainScreen,
            CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: 1117, width: 1920, height: 1080),
            CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        ]
        let result = DesktopObstacleScanner.analyze([
            window(id: 1, frame: CGRect(x: -1800, y: 80, width: 180, height: 180)),
            window(id: 2, frame: CGRect(x: 100, y: -1000, width: 180, height: 180)),
            window(id: 3, frame: CGRect(x: 100, y: 1300, width: 180, height: 180))
        ], screenFrames: screens, primaryScreenHeight: 1117, ownPID: 999, desktopIconLevel: desktopIconLevel)
        #expect(result.obstacles.map(\.frame) == [
            CGRect(x: -1800, y: 857, width: 180, height: 180),
            CGRect(x: 100, y: 1937, width: 180, height: 180),
            CGRect(x: 100, y: -363, width: 180, height: 180)
        ])
    }

    @Test
    func duplicateSurfacesDoNotReserveTheSameWidgetTwice() {
        let frame = CGRect(x: 10, y: 50, width: 180, height: 180)
        let result = analyze([window(id: 1, frame: frame), window(id: 2, frame: frame)])
        #expect(result.obstacles.count == 1)
    }

    private func analyze(_ windows: [DesktopObstacleScanner.WindowMetadata]) -> DesktopScanResult {
        DesktopObstacleScanner.analyze(
            windows, screenFrames: [mainScreen], primaryScreenHeight: mainScreen.height,
            ownPID: 999, desktopIconLevel: desktopIconLevel
        )
    }

    private func window(
        id: CGWindowID, frame: CGRect, bundle: String? = "com.apple.notificationcenterui",
        layer: Int? = nil, owner: pid_t = 588, alpha: CGFloat = 1, onScreen: Bool = true
    ) -> DesktopObstacleScanner.WindowMetadata {
        .init(
            id: id, ownerPID: owner, bundleIdentifier: bundle, cgFrame: frame,
            layer: layer ?? desktopIconLevel + 2, alpha: alpha, isOnScreen: onScreen
        )
    }
}
