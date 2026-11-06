import Foundation
@testable import KEYIUI

private final class InvalidationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// Pure notification-latch checks. No AX observer, real app, draft or keyboard.
func runTerminalDraftObservationChecks() -> Int {
    var count = 0
    func expect(_ condition: Bool, _ message: String) {
        count += 1
        precondition(condition, message)
    }
    let events = ["value", "selection", "focusedObject", "focusedWindow", "application"]
    for event in events {
        let gate = TerminalDraftChangeGate()
        expect(gate.isCurrent, "Fresh \(event) request must start current")
        gate.invalidate()
        expect(!gate.isCurrent, "\(event) change invalidates old request")
        // No reset operation exists, so change-then-restore stays invalid.
        gate.invalidate()
        expect(!gate.isCurrent, "Repeated \(event) notification cannot reactivate request")
        let newRequest = TerminalDraftChangeGate()
        expect(newRequest.isCurrent && !gate.isCurrent, "New request cannot renew old ticket")
    }
    let observedGate = TerminalDraftChangeGate()
    let probe = InvalidationProbe()
    let observerID = observedGate.observeInvalidation { probe.increment() }
    observedGate.invalidate()
    expect(probe.count == 1, "Live lease revoker fires immediately when request gate invalidates")
    observedGate.invalidate()
    expect(probe.count == 1, "Gate invalidation revokes a live lease only once")
    observedGate.removeInvalidationObserver(observerID)

    let removedGate = TerminalDraftChangeGate()
    let removedProbe = InvalidationProbe()
    let removedObserverID = removedGate.observeInvalidation { removedProbe.increment() }
    removedGate.removeInvalidationObserver(removedObserverID)
    removedGate.invalidate()
    expect(removedProbe.count == 0, "Finished commit removes its lease revoker")
    return count
}
