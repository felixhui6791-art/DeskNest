import CoreGraphics
import Testing
@testable import DeskNest

struct MenuBarOrganizerTests {
    @Test func syntheticStatusWindowNumbersNeverOverflowWindowServerIDs() {
        #expect(MenuBarOrganizerGeometry.windowID(for: 3484) == 3484)
        #expect(MenuBarOrganizerGeometry.windowID(for: Int(UInt32.max)) == UInt32.max)
        #expect(MenuBarOrganizerGeometry.windowID(for: Int(UInt32.max) + 1) == nil)
        #expect(MenuBarOrganizerGeometry.windowID(for: Int.max) == nil)
        #expect(MenuBarOrganizerGeometry.windowID(for: -1) == nil)
        #expect(MenuBarOrganizerGeometry.windowID(for: 0) == nil)
    }

    @Test func unrelatedFloatingWindowsDoNotBlockAutoCollapse() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        #expect(MenuBarOrganizerGeometry.isMenuBarPopup(
            CGRect(x: 1000, y: 600, width: 230, height: 484), screen: screen, barHeight: 33))
        #expect(!MenuBarOrganizerGeometry.isMenuBarPopup(
            CGRect(x: 837, y: 338, width: 126, height: 126), screen: screen, barHeight: 33))
        let left = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        #expect(MenuBarOrganizerGeometry.isMenuBarPopup(
            CGRect(x: -400, y: 400, width: 200, height: 276), screen: left, barHeight: 24))
    }

    @Test func hostedStatusIconsAreNotOpenMenus() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        for width in [20.0, 75, 162, 1856] {
            #expect(!MenuBarOrganizerGeometry.isMenuBarPopup(
                CGRect(x: 1201, y: 1084, width: width, height: 33), screen: screen, barHeight: 33))
        }
        #expect(MenuBarOrganizerGeometry.isMenuBarPopup(
            CGRect(x: 1000, y: 840, width: 230, height: 244), screen: screen, barHeight: 33))
    }

    @Test func collapsingRequiresVisibleDividerToLeftOfArrow() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let arrow = CGRect(x: 1300, y: 875, width: 24, height: 24)
        #expect(MenuBarOrganizerGeometry.canCollapse(arrow: arrow,
            divider: CGRect(x: 1270, y: 875, width: 18, height: 24), screens: [screen]))
        #expect(!MenuBarOrganizerGeometry.canCollapse(arrow: arrow,
            divider: CGRect(x: 1340, y: 875, width: 18, height: 24), screens: [screen]))
        #expect(!MenuBarOrganizerGeometry.canCollapse(arrow: arrow,
            divider: CGRect(x: -100, y: 875, width: 18, height: 24), screens: [screen]))
    }

    @Test func controlsMustShareDisplayAndHeight() {
        let left = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let arrow = CGRect(x: 1300, y: 875, width: 24, height: 24)
        #expect(!MenuBarOrganizerGeometry.canCollapse(arrow: arrow,
            divider: CGRect(x: -60, y: 875, width: 18, height: 24), screens: [left, right]))
        #expect(!MenuBarOrganizerGeometry.canCollapse(arrow: arrow,
            divider: CGRect(x: 1270, y: 600, width: 18, height: 24), screens: [right]))
        #expect(MenuBarOrganizerGeometry.canCollapse(
            arrow: CGRect(x: -50, y: 875, width: 24, height: 24),
            divider: CGRect(x: -80, y: 875, width: 18, height: 24), screens: [left, right]))
    }

    @Test func collapseWidthCoversWidestDisplayAndRemainsBounded() {
        #expect(MenuBarOrganizerGeometry.collapsedLength(screenWidths: [1440, 2560]) == 2688)
        #expect(MenuBarOrganizerGeometry.collapsedLength(screenWidths: [100_000]) == 10_000)
        #expect(MenuBarOrganizerGeometry.collapsedLength(screenWidths: [.nan, -1]) == 2048)
    }

    @Test func menuBarGuardHandlesNegativeCoordinatesAndAutoHiddenBar() {
        let screen = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        #expect(MenuBarOrganizerGeometry.menuBarBand(screen: screen, height: 0).contains(CGPoint(x: -500, y: 690)))
        #expect(!MenuBarOrganizerGeometry.menuBarBand(screen: screen, height: 24).contains(CGPoint(x: -500, y: 650)))
    }

    @Test func onlySupportedAutoCollapseDelaysAreAccepted() {
        for delay in [0.0, 5, 15, 30] { #expect(MenuBarOrganizerGeometry.validDelay(delay) == delay) }
        for delay in [Double.nan, -Double.infinity, 1, -5, 100] {
            #expect(MenuBarOrganizerGeometry.validDelay(delay) == 0)
        }
    }

    @Test func notchOcclusionAndPartialNotchOverlapBlockCollapsing() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let usable = [CGRect(x: 0, y: 870, width: 620, height: 30),
                      CGRect(x: 820, y: 870, width: 620, height: 30)]
        let divider = CGRect(x: 550, y: 875, width: 18, height: 24)
        #expect(!MenuBarOrganizerGeometry.canCollapse(
            arrow: CGRect(x: 700, y: 875, width: 24, height: 24), divider: divider,
            screens: [screen], visibleAreas: usable))
        #expect(!MenuBarOrganizerGeometry.canCollapse(
            arrow: CGRect(x: 600, y: 875, width: 24, height: 24), divider: divider,
            screens: [screen], visibleAreas: usable))
        #expect(MenuBarOrganizerGeometry.canCollapse(
            arrow: CGRect(x: 590, y: 875, width: 24, height: 24), divider: divider,
            screens: [screen], visibleAreas: usable))
        #expect(!MenuBarOrganizerGeometry.canCollapse(
            arrow: CGRect(x: 850, y: 875, width: 24, height: 24),
            divider: CGRect(x: 750, y: 875, width: 18, height: 24),
            screens: [screen], visibleAreas: usable))
    }

    @Test func partiallyOffScreenControlsAreNeverConsideredReachable() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(!MenuBarOrganizerGeometry.isOnScreen(
            CGRect(x: 1425, y: 875, width: 24, height: 24), screens: [screen]))
        #expect(!MenuBarOrganizerGeometry.isOnScreen(
            CGRect(x: -5, y: 875, width: 18, height: 24), screens: [screen]))
        #expect(!MenuBarOrganizerGeometry.isOnScreen(
            CGRect(x: 1300, y: 885, width: 24, height: 24), screens: [screen]))
        #expect(!MenuBarOrganizerGeometry.isOnScreen(
            CGRect(x: 1300, y: 875, width: 24, height: 24), screens: [screen], visibleAreas: []))
    }

    @Test func notchRegionsUseGlobalCoordinatesOnNegativeOriginDisplays() {
        let screen = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let usable = [CGRect(x: -1440, y: 670, width: 620, height: 30),
                      CGRect(x: -620, y: 670, width: 620, height: 30)]
        #expect(MenuBarOrganizerGeometry.canCollapse(
            arrow: CGRect(x: -50, y: 675, width: 24, height: 24),
            divider: CGRect(x: -80, y: 675, width: 18, height: 24),
            screens: [screen], visibleAreas: usable))
        #expect(!MenuBarOrganizerGeometry.isOnScreen(
            CGRect(x: -740, y: 675, width: 24, height: 24), screens: [screen], visibleAreas: usable))
    }
}

@Suite("Temporary menu expansion restoration")
struct MenuBarFoldRestorationTests {
    @Test func openingGraceAndIdleIntervalMustBothFinish() {
        var state = MenuBarFoldRestoration(startedAt: 100)
        let decision0 = state.shouldRestore(at: 100, isInteracting: false)
        #expect(!decision0)
        let decision1 = state.shouldRestore(at: 100.75, isInteracting: false)
        #expect(!decision1)
        let decision2 = state.shouldRestore(at: 101, isInteracting: false)
        #expect(decision2)
    }

    @Test func openMenuNeverTimesOut() {
        var state = MenuBarFoldRestoration(startedAt: 0)
        for time in [1.0, 15, 30, 300] {
            let decision3 = state.shouldRestore(at: time, isInteracting: true)
            #expect(!decision3)
        }
        let decision4 = state.shouldRestore(at: 301, isInteracting: false)
        #expect(!decision4)
        let decision5 = state.shouldRestore(at: 301.75, isInteracting: false)
        #expect(decision5)
    }

    @Test func returningToMenuResetsIdleInterval() {
        var state = MenuBarFoldRestoration(startedAt: 0)
        let decision6 = state.shouldRestore(at: 10, isInteracting: false)
        #expect(!decision6)
        let decision7 = state.shouldRestore(at: 10.5, isInteracting: true)
        #expect(!decision7)
        let decision8 = state.shouldRestore(at: 11, isInteracting: false)
        #expect(!decision8)
        let decision9 = state.shouldRestore(at: 11.5, isInteracting: false)
        #expect(!decision9)
        let decision10 = state.shouldRestore(at: 11.75, isInteracting: false)
        #expect(decision10)
    }

    @Test func independentPresentationsDoNotInheritIdleTime() {
        var previous = MenuBarFoldRestoration(startedAt: 0)
        let decision11 = previous.shouldRestore(at: 1, isInteracting: false)
        #expect(!decision11)
        let decision12 = previous.shouldRestore(at: 2, isInteracting: false)
        #expect(decision12)
        var next = MenuBarFoldRestoration(startedAt: 10)
        let decision13 = next.shouldRestore(at: 10, isInteracting: false)
        #expect(!decision13)
        let decision14 = next.shouldRestore(at: 10.75, isInteracting: false)
        #expect(!decision14)
        let decision15 = next.shouldRestore(at: 11, isInteracting: false)
        #expect(decision15)
    }
}
