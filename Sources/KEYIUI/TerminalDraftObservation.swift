import AppKit
import ApplicationServices
import Foundation

/// A monotonic invalidation latch, not a copy of the user's input. Notification
/// callbacks never read text. Returning to the original value/focus cannot
/// reactivate an outstanding translation.
final class TerminalDraftChangeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    private var invalidationHandlers: [UUID: @Sendable () -> Void] = [:]

    var isCurrent: Bool { lock.withLock { current } }

    func observeInvalidation(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let callImmediately = lock.withLock {
            guard current else { return true }
            invalidationHandlers[id] = handler
            return false
        }
        if callImmediately { handler() }
        return id
    }

    func removeInvalidationObserver(_ id: UUID) {
        _ = lock.withLock { invalidationHandlers.removeValue(forKey: id) }
    }

    func invalidate() {
        let handlers: [@Sendable () -> Void] = lock.withLock {
            guard current else { return [] }
            current = false
            let pending = Array(invalidationHandlers.values)
            invalidationHandlers.removeAll()
            return pending
        }
        handlers.forEach { $0() }
    }
}

/// Lives only as long as one explicitly requested terminal draft snapshot.
/// Watches the captured object and its owning application's focus; never
/// installs an input/event tap or enumerates windows, panes, or screen text.
///
/// Registration support is necessary, not proof of a host's notification
/// fidelity. Final PID/window/object/value/range checks are still required.
/// AX has no atomic revisioned compare-and-set; native draft providers should
/// use their own CAS protocol when available.
final class TerminalDraftObservation {
    enum Error: Swift.Error { case notificationsUnavailable }

    struct Subscription {
        let element: AXUIElement
        let notification: String
    }

    private let gate: TerminalDraftChangeGate
    private var observer: AXObserver?
    private var subscriptions: [Subscription] = []
    private var workspaceToken: (any NSObjectProtocol)?
    private let center: NotificationCenter

    var isCurrent: Bool { gate.isCurrent }

    private init(gate: TerminalDraftChangeGate, center: NotificationCenter) {
        self.gate = gate
        self.center = center
    }

    @MainActor
    static func begin(element: AXUIElement, applicationPID: pid_t) throws -> TerminalDraftObservation {
        let gate = TerminalDraftChangeGate()
        let center = NSWorkspace.shared.notificationCenter
        let observation = TerminalDraftObservation(gate: gate, center: center)
        var observer: AXObserver?
        let result = AXObserverCreate(applicationPID, { _, _, _, context in
            guard let context else { return }
            Unmanaged<TerminalDraftChangeGate>.fromOpaque(context)
                .takeUnretainedValue().invalidate()
        }, &observer)
        guard result == .success, let observer else { throw Error.notificationsUnavailable }
        observation.observer = observer
        let application = AXUIElementCreateApplication(applicationPID)
        let requested = [
            Subscription(element: element, notification: kAXValueChangedNotification),
            Subscription(element: element, notification: kAXSelectedTextChangedNotification),
            Subscription(element: application, notification: kAXFocusedUIElementChangedNotification),
            Subscription(element: application, notification: kAXFocusedWindowChangedNotification)
        ]
        for subscription in requested {
            let result = AXObserverAddNotification(
                observer, subscription.element, subscription.notification as CFString,
                Unmanaged.passUnretained(gate).toOpaque()
            )
            guard result == .success else {
                observation.invalidate()
                throw Error.notificationsUnavailable
            }
            observation.subscriptions.append(subscription)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observation.workspaceToken = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { notification in
            // The short-lived request is invalidated on activation away from
            // its captured app. No app contents or input events are observed.
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  application.processIdentifier == applicationPID else {
                gate.invalidate()
                return
            }
        }
        return observation
    }

    /// Idempotent; called on write completion and when a snapshot is discarded.
    func invalidate() {
        gate.invalidate()
        if let workspaceToken {
            center.removeObserver(workspaceToken)
            self.workspaceToken = nil
        }
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            for subscription in subscriptions {
                AXObserverRemoveNotification(
                    observer, subscription.element, subscription.notification as CFString
                )
            }
            subscriptions.removeAll()
            self.observer = nil
        }
    }

    deinit { invalidate() }
}
