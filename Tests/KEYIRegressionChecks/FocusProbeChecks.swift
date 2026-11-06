import Foundation
@testable import KEYIUI

private enum FocusPathProbeError: Swift.Error, Equatable {
    case read
    case validation
}

// Handles represent only fake identities; these checks never contact a desktop app.
@MainActor
private final class FocusPathProbeFixture {
    typealias Probe = FocusedElementProbe
    var current = true
    var responses: [Probe.Source: Probe.ReadResult<Int>] = [:]
    var sources: [Probe.Source] = []
    var owners: [Int?] = []
    var windowValidations = 0
    var lastWindowCandidate: Int?
    var lastWindowOwner: Int?
    var currentCheck: (@MainActor () -> Bool)?
    var afterRead: (@MainActor (Probe.Source) throws -> Void)?
    var windowValidation: (@MainActor (Int, Int) throws -> Bool)?

    static func valid(_ element: Int, pid: Int32 = 7) -> Probe.ReadResult<Int> {
        Probe.ReadResult(
            element: element, axResult: 0, valueKind: .axElement,
            pidResult: 0, candidatePID: pid
        )
    }

    static func missing() -> Probe.ReadResult<Int> {
        Probe.ReadResult(
            element: nil, axResult: 0, valueKind: .missing,
            pidResult: nil, candidatePID: nil
        )
    }

    func probe(includeFocusedWindow: Bool = true) throws -> Probe.Result<Int> {
        try Probe.probe(
            expectedPID: 7,
            includeFocusedWindow: includeFocusedWindow,
            isCurrent: { self.currentCheck?() ?? self.current },
            read: { source, owner in
                self.sources.append(source)
                self.owners.append(owner)
                try self.afterRead?(source)
                return self.responses[source] ?? Self.missing()
            },
            isUsableWindowFocus: { candidate, window in
                self.windowValidations += 1
                self.lastWindowCandidate = candidate
                self.lastWindowOwner = window
                return try self.windowValidation?(candidate, window) ?? (candidate != window)
            }
        )
    }

    func prepareWindow(candidate: Int = 41) {
        responses[.focusedWindow] = Self.valid(40)
        responses[.windowFocus] = Self.valid(candidate)
    }
}

@MainActor
private func focusPathError(_ operation: () throws -> Void) -> Swift.Error? {
    do {
        try operation()
        return nil
    } catch {
        return error
    }
}

@MainActor
func checkFocusedElementProbe(_ expect: (Bool, String) -> Void) throws {
    typealias Probe = FocusedElementProbe
    typealias Fixture = FocusPathProbeFixture

    let direct = Fixture()
    direct.responses[.systemFocus] = Fixture.valid(10)
    let directResult = try direct.probe()
    expect(directResult.element == 10 && directResult.source == .systemFocus,
           "A valid same-PID system focus must win immediately")
    expect(direct.sources == [.systemFocus] && direct.owners == [nil]
           && direct.windowValidations == 0,
           "Direct focus must not read alternative paths or validate a window")
    expect(directResult.observations.count == 1
           && directResult.observations[0].outcome == .accepted
           && !directResult.observations[0].childProbeSkipped,
           "Direct success must produce one metadata-only accepted observation")

    var stringReadWasRoot = false
    let stringResult = try Probe.probe(
        expectedPID: 7, includeFocusedWindow: false,
        isCurrent: { true },
        read: { (source, owner) -> Probe.ReadResult<String> in
            stringReadWasRoot = source == .systemFocus && owner == nil
            return Probe.ReadResult(
                element: "handle", axResult: 0, valueKind: .axElement,
                pidResult: 0, candidatePID: 7
            )
        },
        isUsableWindowFocus: { _, _ in false }
    )
    expect(stringReadWasRoot && stringResult.element == "handle"
           && stringResult.source == .systemFocus,
           "The probe must be generic over fake String handles as well as Int handles")

    let focusedApp = Fixture()
    focusedApp.responses[.focusedApplication] = Fixture.valid(20)
    focusedApp.responses[.focusedApplicationFocus] = Fixture.valid(21)
    let focusedAppResult = try focusedApp.probe()
    expect(focusedAppResult.element == 21 && focusedAppResult.source == .focusedApplicationFocus,
           "A verified focused application's focus must be accepted")
    expect(focusedApp.sources == [.systemFocus, .focusedApplication, .focusedApplicationFocus]
           && focusedApp.owners == [nil, nil, 20],
           "The focused-app child must receive only its verified parent handle")
    expect(focusedAppResult.observations.map(\.outcome) == [.valueMissing, .accepted, .accepted]
           && !focusedAppResult.observations[1].childProbeSkipped,
           "Focused-app success must retain each path's independent diagnostic")

    let appRoot = Fixture()
    appRoot.responses[.applicationFocus] = Fixture.valid(30)
    let appRootResult = try appRoot.probe()
    expect(appRootResult.element == 30 && appRootResult.source == .applicationFocus,
           "The expected application's root focus must remain a fallback")
    expect(appRoot.sources == [.systemFocus, .focusedApplication, .applicationFocus]
           && appRoot.owners == [nil, nil, nil],
           "A missing focused-app parent must not trigger a child query")
    expect(appRootResult.observations[1].childProbeSkipped,
           "A missing parent must explicitly record its skipped child")

    let window = Fixture()
    window.prepareWindow()
    let windowResult = try window.probe()
    expect(windowResult.element == 41 && windowResult.source == .windowFocus,
           "A verified window-only text focus must be accepted")
    expect(window.sources == [.systemFocus, .focusedApplication, .applicationFocus,
                              .focusedWindow, .windowFocus]
           && window.owners == [nil, nil, nil, nil, 40],
           "Window fallback must use the verified focused window, never a tree search")
    expect(window.windowValidations == 1 && window.lastWindowCandidate == 41
           && window.lastWindowOwner == 40,
           "Window validation must receive candidate focus followed by its focused window")
    expect(windowResult.observations.last?.outcome == .accepted,
           "An accepted window focus must retain a success diagnostic")

    let disabledWindow = Fixture()
    disabledWindow.prepareWindow()
    let disabledResult = try disabledWindow.probe(includeFocusedWindow: false)
    expect(disabledResult.element == nil && disabledResult.source == nil
           && disabledResult.observations.count == 3,
           "Disabling window fallback must return no candidate after the existing paths")
    expect(disabledWindow.sources == [.systemFocus, .focusedApplication, .applicationFocus]
           && disabledWindow.windowValidations == 0,
           "Disabling window fallback must never read or validate a window")

    let exhausted = Fixture()
    exhausted.responses[.focusedApplication] = Fixture.valid(20)
    exhausted.responses[.focusedWindow] = Fixture.valid(40)
    let exhaustedResult = try exhausted.probe()
    expect(exhaustedResult.element == nil && exhaustedResult.source == nil,
           "Exhausted paths must return absence, not a parent or window object")
    expect(exhausted.sources == [.systemFocus, .focusedApplication, .focusedApplicationFocus,
                                 .applicationFocus, .focusedWindow, .windowFocus],
           "One probe must perform at most the six explicit focus queries in order")
    expect(exhaustedResult.observations.count == 6 && exhausted.windowValidations == 0
           && exhaustedResult.observations.allSatisfy { !$0.childProbeSkipped },
           "Valid parents with missing children must not be marked as skipped or validated")

    let diagnosticCases: [(Probe.ReadResult<Int>, Probe.Outcome)] = [
        (.init(element: 10, axResult: -25212, valueKind: .axElement,
               pidResult: 0, candidatePID: 7), .focusNotReturned),
        (Fixture.missing(), .valueMissing),
        (.init(element: 10, axResult: 0, valueKind: .other,
               pidResult: 0, candidatePID: 7), .valueTypeMismatch),
        (.init(element: nil, axResult: 0, valueKind: .axElement,
               pidResult: 0, candidatePID: 7), .valueMissing),
        (.init(element: 10, axResult: 0, valueKind: .axElement,
               pidResult: -25202, candidatePID: 7), .pidQueryFailed),
        (.init(element: 10, axResult: 0, valueKind: .axElement,
               pidResult: nil, candidatePID: 7), .pidQueryFailed),
        (.init(element: 10, axResult: 0, valueKind: .axElement,
               pidResult: 0, candidatePID: nil), .pidQueryFailed),
        (Fixture.valid(10, pid: 8), .pidMismatch)
    ]
    for (response, expectedOutcome) in diagnosticCases {
        let fixture = Fixture()
        fixture.responses[.systemFocus] = response
        let result = try fixture.probe(includeFocusedWindow: false)
        expect(result.element == nil && result.source == nil
               && result.observations.first?.outcome == expectedOutcome,
               "AX failure, missing value, wrong type, PID failure, and PID mismatch must stay distinct")
        let observation = result.observations[0]
        expect(observation.source == .systemFocus && observation.axResult == response.axResult
               && observation.valueKind == response.valueKind
               && observation.pidResult == response.pidResult
               && observation.candidatePID == response.candidatePID
               && !observation.childProbeSkipped,
               "Failure observations must preserve only their query and PID metadata")
    }

    let wrongParents = Fixture()
    wrongParents.responses[.focusedApplication] = Fixture.valid(20, pid: 8)
    wrongParents.responses[.focusedWindow] = Fixture.valid(40, pid: 8)
    wrongParents.responses[.focusedApplicationFocus] = Fixture.valid(21)
    wrongParents.responses[.windowFocus] = Fixture.valid(41)
    let wrongParentsResult = try wrongParents.probe()
    expect(wrongParentsResult.element == nil
           && wrongParents.sources == [.systemFocus, .focusedApplication,
                                       .applicationFocus, .focusedWindow],
           "Wrong-PID parent objects must prevent both child focus reads")
    expect(wrongParentsResult.observations[1].outcome == .pidMismatch
           && wrongParentsResult.observations[1].childProbeSkipped
           && wrongParentsResult.observations[3].outcome == .pidMismatch
           && wrongParentsResult.observations[3].childProbeSkipped,
           "Each rejected parent must record a PID mismatch and skipped child")
    expect(wrongParents.windowValidations == 0,
           "An unverified window must never reach input validation")

    let wrongParentFallback = Fixture()
    wrongParentFallback.responses[.focusedApplication] = Fixture.valid(20, pid: 8)
    wrongParentFallback.responses[.applicationFocus] = Fixture.valid(30)
    let parentFallbackResult = try wrongParentFallback.probe()
    expect(parentFallbackResult.element == 30 && parentFallbackResult.source == .applicationFocus,
           "Rejecting another application's parent must not suppress a valid expected-app fallback")
    expect(wrongParentFallback.sources == [.systemFocus, .focusedApplication, .applicationFocus]
           && parentFallbackResult.observations[1].childProbeSkipped,
           "A valid app-root fallback must still never query a rejected parent's child")

    let wrongChild = Fixture()
    wrongChild.responses[.focusedApplication] = Fixture.valid(20)
    wrongChild.responses[.focusedApplicationFocus] = Fixture.valid(21, pid: 8)
    wrongChild.responses[.applicationFocus] = Fixture.valid(30)
    let wrongChildResult = try wrongChild.probe()
    expect(wrongChildResult.element == 30 && wrongChildResult.source == .applicationFocus,
           "A same-PID parent must not authorize a different-PID focus child")
    expect(wrongChildResult.observations[2].outcome == .pidMismatch
           && wrongChild.sources == [.systemFocus, .focusedApplication,
                                     .focusedApplicationFocus, .applicationFocus],
           "A child's independent PID rejection must fall through without accepting it")

    let windowSelf = Fixture()
    windowSelf.prepareWindow(candidate: 40)
    let windowSelfResult = try windowSelf.probe()
    expect(windowSelfResult.element == nil && windowSelfResult.source == nil
           && windowSelfResult.observations.last?.outcome == .nonTextFocus,
           "The focused window itself must never become a text-input candidate")
    expect(windowSelf.windowValidations == 1 && windowSelf.lastWindowCandidate == 40
           && windowSelf.lastWindowOwner == 40,
           "A window/self object must be rejected by the supplied usability check")

    let nonText = Fixture()
    nonText.prepareWindow(candidate: 42)
    nonText.windowValidation = { _, _ in false }
    let nonTextResult = try nonText.probe()
    expect(nonTextResult.element == nil && nonTextResult.observations.last?.outcome == .nonTextFocus,
           "A group or other non-input focus must be rejected despite a valid PID")
    expect(nonText.windowValidations == 1 && nonText.lastWindowCandidate == 42
           && nonText.lastWindowOwner == 40,
           "A non-input object must be checked only against its verified focused window")

    let stale = Fixture()
    stale.current = false
    let staleError = focusPathError { _ = try stale.probe() }
    expect((staleError as? AccessibilityTextClient.Error)?.diagnosticCode == "content_changed"
           && stale.sources.isEmpty && stale.windowValidations == 0,
           "An already changed frontmost target must prevent the first query")

    let changedRead = Fixture()
    changedRead.responses[.systemFocus] = Fixture.valid(10)
    changedRead.afterRead = { _ in changedRead.current = false }
    let changedReadError = focusPathError { _ = try changedRead.probe() }
    expect((changedReadError as? AccessibilityTextClient.Error)?.diagnosticCode == "content_changed"
           && changedRead.sources == [.systemFocus] && changedRead.windowValidations == 0,
           "A frontmost change during a successful read must prevent acceptance")

    let beforeValidation = Fixture()
    beforeValidation.prepareWindow()
    var checksAfterWindowRead = 0
    beforeValidation.currentCheck = {
        if beforeValidation.sources.last == .windowFocus {
            checksAfterWindowRead += 1
            return checksAfterWindowRead < 2
        }
        return true
    }
    let beforeValidationError = focusPathError { _ = try beforeValidation.probe() }
    expect((beforeValidationError as? AccessibilityTextClient.Error)?.diagnosticCode == "content_changed"
           && beforeValidation.sources.count == 5 && beforeValidation.windowValidations == 0,
           "A target change after window read must stop before the extra usability callback")

    let changedValidation = Fixture()
    changedValidation.prepareWindow()
    changedValidation.windowValidation = { _, _ in
        changedValidation.current = false
        return true
    }
    let changedValidationError = focusPathError { _ = try changedValidation.probe() }
    expect((changedValidationError as? AccessibilityTextClient.Error)?.diagnosticCode == "content_changed"
           && changedValidation.windowValidations == 1,
           "A frontmost change during window validation must prevent returning the candidate")

    let failedRead = Fixture()
    failedRead.afterRead = { _ in throw FocusPathProbeError.read }
    let failedReadError = focusPathError { _ = try failedRead.probe() }
    expect(failedReadError as? FocusPathProbeError == .read
           && failedRead.sources == [.systemFocus] && failedRead.windowValidations == 0,
           "A read error must propagate unchanged and stop every later path")

    let changedFailedRead = Fixture()
    changedFailedRead.afterRead = { _ in
        changedFailedRead.current = false
        throw FocusPathProbeError.read
    }
    let changedFailedReadError = focusPathError { _ = try changedFailedRead.probe() }
    expect((changedFailedReadError as? AccessibilityTextClient.Error)?.diagnosticCode == "content_changed"
           && changedFailedRead.sources == [.systemFocus],
           "The target boundary must also be checked when a read throws")

    let failedValidation = Fixture()
    failedValidation.prepareWindow()
    failedValidation.windowValidation = { _, _ in throw FocusPathProbeError.validation }
    let failedValidationError = focusPathError { _ = try failedValidation.probe() }
    expect(failedValidationError as? FocusPathProbeError == .validation
           && failedValidation.windowValidations == 1 && failedValidation.sources.count == 5,
           "A window usability error must propagate without retries or extra reads")

    let cancelledRead = Fixture()
    cancelledRead.afterRead = { _ in throw CancellationError() }
    let cancelledReadError = focusPathError { _ = try cancelledRead.probe() }
    expect(cancelledReadError is CancellationError && cancelledRead.sources == [.systemFocus],
           "A thrown cancellation must stop focus probing immediately")

    let cancelledValidation = Fixture()
    cancelledValidation.prepareWindow()
    cancelledValidation.windowValidation = { _, _ in throw CancellationError() }
    let cancelledValidationError = focusPathError { _ = try cancelledValidation.probe() }
    expect(cancelledValidationError is CancellationError && cancelledValidation.windowValidations == 1,
           "A cancelled window usability callback must never return its candidate")
}

// Real task cancellation is isolated from the regression executable's main task.
@MainActor
func checkFocusedElementProbeCancellation(_ expect: (Bool, String) -> Void) async throws {
    let preCancelled = FocusPathProbeFixture()
    let preCancelledStopped = await Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        let error = focusPathError { _ = try preCancelled.probe() }
        return error is CancellationError && preCancelled.sources.isEmpty
            && preCancelled.windowValidations == 0
    }.value
    expect(preCancelledStopped, "An already cancelled task must perform no focus operations")

    let cancelledByBoundary = FocusPathProbeFixture()
    cancelledByBoundary.currentCheck = {
        withUnsafeCurrentTask { $0?.cancel() }
        return true
    }
    let boundaryStopped = await Task { @MainActor in
        let error = focusPathError { _ = try cancelledByBoundary.probe() }
        return error is CancellationError && cancelledByBoundary.sources.isEmpty
    }.value
    expect(boundaryStopped, "Cancellation inside the target predicate must prevent the first query")

    let cancelledDuringRead = FocusPathProbeFixture()
    cancelledDuringRead.responses[.systemFocus] = FocusPathProbeFixture.valid(10)
    cancelledDuringRead.afterRead = { _ in withUnsafeCurrentTask { $0?.cancel() } }
    let readStopped = await Task { @MainActor in
        let error = focusPathError { _ = try cancelledDuringRead.probe() }
        return error is CancellationError && cancelledDuringRead.sources == [.systemFocus]
            && cancelledDuringRead.windowValidations == 0
    }.value
    expect(readStopped, "Cancellation during a successful read must prevent returning its focus")

    let cancelledBeforeValidation = FocusPathProbeFixture()
    cancelledBeforeValidation.prepareWindow()
    var checksAfterWindowRead = 0
    cancelledBeforeValidation.currentCheck = {
        if cancelledBeforeValidation.sources.last == .windowFocus {
            checksAfterWindowRead += 1
            if checksAfterWindowRead == 2 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        return true
    }
    let beforeValidationStopped = await Task { @MainActor in
        let error = focusPathError { _ = try cancelledBeforeValidation.probe() }
        return error is CancellationError && cancelledBeforeValidation.sources.count == 5
            && cancelledBeforeValidation.windowValidations == 0
    }.value
    expect(beforeValidationStopped,
           "Cancellation before the extra usability callback must prevent that callback")

    let cancelledDuringValidation = FocusPathProbeFixture()
    cancelledDuringValidation.prepareWindow()
    cancelledDuringValidation.windowValidation = { _, _ in
        withUnsafeCurrentTask { $0?.cancel() }
        return true
    }
    let validationStopped = await Task { @MainActor in
        let error = focusPathError { _ = try cancelledDuringValidation.probe() }
        return error is CancellationError && cancelledDuringValidation.windowValidations == 1
    }.value
    expect(validationStopped, "Cancellation during window validation must prevent returning its focus")

    let cancelledFailedRead = FocusPathProbeFixture()
    cancelledFailedRead.afterRead = { _ in
        withUnsafeCurrentTask { $0?.cancel() }
        throw FocusPathProbeError.read
    }
    let failedReadStopped = await Task { @MainActor in
        let error = focusPathError { _ = try cancelledFailedRead.probe() }
        return error is CancellationError && cancelledFailedRead.sources == [.systemFocus]
    }.value
    expect(failedReadStopped, "The cancellation boundary must be checked even when a read throws")
    expect(!Task.isCancelled, "Cancellation checks must never cancel the regression main task")
}
