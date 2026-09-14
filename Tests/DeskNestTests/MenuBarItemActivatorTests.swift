import CoreGraphics
import ApplicationServices
import Testing
@testable import DeskNest

struct MenuBarItemActivatorTests {
    let target = CGRect(x: 840, y: 1084, width: 26, height: 33)

    @Test func exactAndInsetStatusItemsMatch() {
        #expect(MenuBarItemActivationGeometry.matches(target, target: target))
        #expect(MenuBarItemActivationGeometry.matches(target.insetBy(dx: 2, dy: 3), target: target))
        // macOS 26 proxy windows can be 33 pt high while the centered AX
        // status-item content remains 22 pt high.
        #expect(MenuBarItemActivationGeometry.matches(target.insetBy(dx: 0, dy: 5.5), target: target))
    }

    @Test func neighboringItemsAndStalePositionsAreRejected() {
        #expect(!MenuBarItemActivationGeometry.matches(target.offsetBy(dx: -28, dy: 0), target: target))
        #expect(!MenuBarItemActivationGeometry.matches(target.offsetBy(dx: 3, dy: 0), target: target))
        #expect(!MenuBarItemActivationGeometry.matches(target.offsetBy(dx: 0, dy: 4), target: target))
        #expect(!MenuBarItemActivationGeometry.matches(CGRect(x: 800, y: 1084, width: 106, height: 33), target: target))
    }

    @Test func globalDuplicatesNeverSelectFirstProcess() {
        #expect(MenuBarItemActivationGeometry.uniquelyMatchingIndex(frames: [target, target], target: target) == nil)
        #expect(MenuBarItemActivationGeometry.uniquelyMatchingIndex(frames: [target.offsetBy(dx: -30, dy: 0), target], target: target) == 1)
        #expect(MenuBarItemActivationGeometry.uniquelyMatchingIndex(frames: [], target: target) == nil)
    }

    @Test func negativeDisplayCoordinatesAndOffscreenStatusItemsRemainAddressable() {
        let topLeft = CGRect(x: -1540, y: 217, width: 24, height: 24)
        let converted = MenuBarItemActivationGeometry.appKitFrame(topLeft, mainDisplayHeight: 1117)
        #expect(converted == CGRect(x: -1540, y: 876, width: 24, height: 24))
        #expect(MenuBarItemActivationGeometry.matches(converted, target: converted))
    }

    @Test func invalidFramesAreRejectedBeforeMatching() {
        #expect(!MenuBarItemActivationGeometry.matches(.zero, target: .zero))
        #expect(!MenuBarItemActivationGeometry.isValid(CGRect(x: CGFloat.infinity, y: 0, width: 24, height: 24)))
        #expect(!MenuBarItemActivationGeometry.isValid(CGRect(x: 0, y: 0, width: 2000, height: 33)))
    }

    @Test func onlyDocumentedOpeningActionsAreChosen() {
        #expect(MenuBarItemActivationGeometry.preferredAction(["AXRaise", "AXShowMenu", "AXPress"]) == "AXPress")
        #expect(MenuBarItemActivationGeometry.preferredAction(["AXShowMenu"]) == "AXShowMenu")
        #expect(MenuBarItemActivationGeometry.preferredAction(["AXRaise"]) == nil)
    }

    @Test func synchronousMenuTimeoutDoesNotClaimFailureOrTriggerAnotherAttempt() {
        #expect(MenuBarItemActivationGeometry.actionResult(.success) == .performed)
        switch MenuBarItemActivationGeometry.actionResult(.cannotComplete) {
        case .unconfirmed: break
        default: Issue.record("A menu may already be tracking after AX times out")
        }
        switch MenuBarItemActivationGeometry.actionResult(.actionUnsupported) {
        case .unavailable: break
        default: Issue.record("Unsupported actions must not count as accepted")
        }
    }

    @Test func onlyDefiniteUnsupportedPressPermitsAdvertisedShowMenuFallback() {
        #expect(MenuBarItemActivationGeometry.shouldTryShowMenu(after: .actionUnsupported,
            attemptedAction: "AXPress", advertisedActions: ["AXPress", "AXShowMenu"]))
        #expect(!MenuBarItemActivationGeometry.shouldTryShowMenu(after: .actionUnsupported,
            attemptedAction: "AXPress", advertisedActions: ["AXPress"]))
        #expect(!MenuBarItemActivationGeometry.shouldTryShowMenu(after: .actionUnsupported,
            attemptedAction: "AXShowMenu", advertisedActions: ["AXShowMenu"]))
        for error in [AXError.cannotComplete, .failure, .success, .invalidUIElement] {
            #expect(!MenuBarItemActivationGeometry.shouldTryShowMenu(after: error,
                attemptedAction: "AXPress", advertisedActions: ["AXPress", "AXShowMenu"]))
        }
    }

    @Test func hitTestRequiresEntireVisibleStatusWindow() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        #expect(MenuBarItemActivationGeometry.canHitTest(target, isOnScreen: true, visibleAreas: [screen]))
        #expect(!MenuBarItemActivationGeometry.canHitTest(target, isOnScreen: false, visibleAreas: [screen]))
        #expect(!MenuBarItemActivationGeometry.canHitTest(CGRect(x: -10, y: 1084, width: 26, height: 33),
            isOnScreen: true, visibleAreas: [screen]))
        #expect(!MenuBarItemActivationGeometry.canHitTest(target, isOnScreen: true,
            visibleAreas: [CGRect(x: 0, y: 1084, width: 830, height: 33),
                           CGRect(x: 900, y: 1084, width: 828, height: 33)]))
    }

    @Test func hitTestUsesQuartzCenterIncludingNegativeDisplays() {
        #expect(MenuBarItemActivationGeometry.quartzCenter(of: target, mainDisplayHeight: 1117)
            == CGPoint(x: 853, y: 16.5))
        let left = CGRect(x: -1440, y: 876, width: 24, height: 24)
        #expect(MenuBarItemActivationGeometry.quartzCenter(of: left, mainDisplayHeight: 1117)
            == CGPoint(x: -1428, y: 229))
        #expect(MenuBarItemActivationGeometry.canHitTest(left, isOnScreen: true,
            visibleAreas: [CGRect(x: -1440, y: 0, width: 1440, height: 900)]))
    }

    @Test func thirtyThreePointProxyFitsTopAlignedThirtyTwoPointAuxiliaryStrip() {
        let rightArea = CGRect(x: 956, y: 1085, width: 772, height: 32)
        let q2 = CGRect(x: 1127, y: 1084, width: 30, height: 33)
        #expect(MenuBarItemActivationGeometry.canHitTest(q2, isOnScreen: true, visibleAreas: [rightArea]))
        #expect(!MenuBarItemActivationGeometry.canHitTest(q2, isOnScreen: false, visibleAreas: [rightArea]))
        for rejected in [
            CGRect(x: 955, y: 1084, width: 30, height: 33), // crosses into the notch
            CGRect(x: 1699, y: 1084, width: 30, height: 33), // outside the screen's right edge
            q2.offsetBy(dx: 0, dy: 1), // outside the screen's top edge
            q2.offsetBy(dx: 0, dy: -1), // top must remain aligned
            CGRect(x: 1127, y: 1083, width: 30, height: 34) // more than one point below
        ] {
            #expect(!MenuBarItemActivationGeometry.canHitTest(rejected, isOnScreen: true,
                visibleAreas: [rightArea]))
        }
    }

    @Test func hitTestRejectsImagesWindowsAndGenericGroupsAsActionTargets() {
        #expect(MenuBarItemActivationGeometry.isStatusItemRole("AXMenuBarItem"))
        #expect(MenuBarItemActivationGeometry.isStatusItemRole("AXButton"))
        for role in ["AXImage", "AXWindow", "AXGroup", "AXMenuBar", "AXMenuItem"] {
            #expect(!MenuBarItemActivationGeometry.isStatusItemRole(role))
        }
    }
}
