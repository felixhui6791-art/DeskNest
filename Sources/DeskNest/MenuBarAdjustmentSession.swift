/// Manual icon arrangement is an explicit mode. Releasing Command or the mouse
/// does not finish it; only an explicit finish or browsing action does.
struct MenuBarAdjustmentSession {
    private(set) var isActive = false

    mutating func begin() { isActive = true }
    mutating func finish() { isActive = false }

    func blocksCollapse(commandDown: Bool, mouseDown: Bool) -> Bool {
        isActive || commandDown || mouseDown
    }

    static func wantsAdjustment(commandDown: Bool, pointerInMenuBar: Bool) -> Bool {
        commandDown && pointerInMenuBar
    }
}
