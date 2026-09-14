import Testing
@testable import DeskNest

struct MenuBarAdjustmentSessionTests {
    @Test func adjustmentRemainsActiveAfterCommandAndMouseRelease() {
        var session = MenuBarAdjustmentSession()
        session.begin()
        #expect(session.blocksCollapse(commandDown: true, mouseDown: true))
        #expect(session.blocksCollapse(commandDown: true, mouseDown: false))
        #expect(session.blocksCollapse(commandDown: false, mouseDown: false))
        #expect(session.isActive)
        session.finish()
        #expect(!session.blocksCollapse(commandDown: false, mouseDown: false))
    }

    @Test func pendingCollapseWaitsForHeldCommandOrMouseEvenOutsideAdjustment() {
        let session = MenuBarAdjustmentSession()
        #expect(session.blocksCollapse(commandDown: true, mouseDown: false))
        #expect(session.blocksCollapse(commandDown: false, mouseDown: true))
        #expect(!session.blocksCollapse(commandDown: false, mouseDown: false))
    }

    @Test func onlyCommandClicksInTheMenuBarEnterAdjustment() {
        #expect(MenuBarAdjustmentSession.wantsAdjustment(commandDown: true, pointerInMenuBar: true))
        #expect(!MenuBarAdjustmentSession.wantsAdjustment(commandDown: false, pointerInMenuBar: true))
        #expect(!MenuBarAdjustmentSession.wantsAdjustment(commandDown: true, pointerInMenuBar: false))
    }
}
