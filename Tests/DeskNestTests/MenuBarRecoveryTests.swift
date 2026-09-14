import CoreGraphics
import Testing
@testable import DeskNest

struct MenuBarRecoveryTests {
    @Test func overlappingSleepAndScreenWakeKeepFoldIntent() {
        var state = MenuBarRecoveryState()
        state.requestFold()
        state.suspend(.screens)
        state.suspend(.system)
        state.suspend(.session)
        state.resume(.screens)
        #expect(state.wantsFold)
        #expect(!state.shouldRestore(isAdjusting: false))
        state.resume(.system)
        #expect(!state.shouldRestore(isAdjusting: false))
        state.resume(.session)
        #expect(state.shouldRestore(isAdjusting: false))
        state.resume(.system)
        state.resume(.screens)
        #expect(state.shouldRestore(isAdjusting: false))
    }

    @Test func displaySleepAloneAndRepeatedWakeDoNotLoseIntent() {
        var state = MenuBarRecoveryState()
        state.requestFold()
        for _ in 0..<3 {
            state.suspend(.screens)
            #expect(!state.shouldRestore(isAdjusting: false))
            state.resume(.screens)
            #expect(state.shouldRestore(isAdjusting: false))
        }
        // Multiple screen/Space relayout checks may temporarily expose the divider;
        // none are a new user request to leave the icons expanded.
        for _ in 0..<5 { #expect(state.shouldRestore(isAdjusting: false)) }
    }

    @Test func manualArrangementDuringPendingRecoveryRemainsExpanded() {
        var state = MenuBarRecoveryState()
        state.requestFold()
        state.suspend(.system)
        state.requestExpansion()
        state.resume(.system)
        #expect(!state.shouldRestore(isAdjusting: false))
        state.requestFold()
        #expect(!state.shouldRestore(isAdjusting: true))
        #expect(state.shouldRestore(isAdjusting: false))
    }

    @Test func launchingAndDisablingNeverCreateAnImplicitFold() {
        var state = MenuBarRecoveryState()
        state.suspend(.screens)
        state.resume(.screens)
        #expect(!state.shouldRestore(isAdjusting: false))
        state.requestFold()
        state.suspend(.system)
        state.reset()
        state.resume(.system)
        #expect(!state.wantsFold)
        #expect(!state.isSuspended)
    }

    @Test func hostedViewResetIsDetectedEvenWhenRequestedLengthIsUnchanged() {
        let width = MenuBarOrganizerGeometry.collapsedLength(screenWidths: [1728])
        let collapsed = CGRect(x: -500, y: 1084, width: width, height: 33)
        #expect(MenuBarOrganizerGeometry.hasFoldedLayout(requestedLength: width, divider: collapsed, screenWidths: [1728]))
        let reset = CGRect(x: 1200, y: 1084, width: 18, height: 33)
        #expect(!MenuBarOrganizerGeometry.hasFoldedLayout(requestedLength: width, divider: reset, screenWidths: [1728]))
        #expect(!MenuBarOrganizerGeometry.hasFoldedLayout(requestedLength: 18, divider: collapsed, screenWidths: [1728]))
        #expect(!MenuBarOrganizerGeometry.hasFoldedLayout(requestedLength: width, divider: collapsed, screenWidths: [3008]))
        #expect(!MenuBarOrganizerGeometry.hasFoldedLayout(requestedLength: width, divider: nil, screenWidths: [1728]))
        #expect(!MenuBarOrganizerGeometry.hasFoldedLayout(requestedLength: .nan, divider: collapsed, screenWidths: [1728]))
    }

    @Test func transientUnavailableLayoutMustSettleBeforeRetry() {
        var idle = MenuBarFoldRestoration(startedAt: 0)
        // The controller treats unavailable geometry exactly like interaction.
        let decision0 = !idle.shouldRestore(at: 5, isInteracting: true)
        #expect(decision0)
        let decision1 = !idle.shouldRestore(at: 10, isInteracting: false)
        #expect(decision1)
        let decision2 = !idle.shouldRestore(at: 10.5, isInteracting: true)
        #expect(decision2)
        let decision3 = !idle.shouldRestore(at: 11, isInteracting: false)
        #expect(decision3)
        let decision4 = !idle.shouldRestore(at: 11.5, isInteracting: false)
        #expect(decision4)
        let decision5 = idle.shouldRestore(at: 11.75, isInteracting: false)
        #expect(decision5)
    }
}
