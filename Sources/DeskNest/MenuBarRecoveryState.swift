/// User intent is independent of the temporary, system-hosted status-item layout.
struct MenuBarRecoveryState {
    enum Suspension: Hashable { case system, screens, session }
    private(set) var wantsFold = false
    private var suspensions: Set<Suspension> = []
    var isSuspended: Bool { !suspensions.isEmpty }

    mutating func requestFold() { wantsFold = true }
    mutating func requestExpansion() { wantsFold = false }
    mutating func suspend(_ reason: Suspension) { suspensions.insert(reason) }
    mutating func resume(_ reason: Suspension) { suspensions.remove(reason) }
    mutating func reset() { self = Self() }

    func shouldRestore(isAdjusting: Bool) -> Bool {
        wantsFold && !isSuspended && !isAdjusting
    }
}
