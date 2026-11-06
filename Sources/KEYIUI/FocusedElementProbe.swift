import Foundation

/// One bounded focus-path probe. All desktop operations are supplied by the caller.
@MainActor
enum FocusedElementProbe {
    enum Source: String, Sendable {
        case systemFocus = "system_focus"
        case focusedApplication = "focused_app"
        case focusedApplicationFocus = "focused_app_focus"
        case applicationFocus = "app_root"
        case focusedWindow = "app_window"
        case windowFocus = "window_focus"
    }

    enum ValueKind: String, Sendable {
        case missing
        case axElement = "ax_element"
        case other
    }

    enum Outcome: String, Sendable {
        case accepted
        case focusNotReturned = "ax_focus_not_returned"
        case valueMissing = "ax_value_missing"
        case valueTypeMismatch = "ax_value_type_mismatch"
        case pidQueryFailed = "ax_pid_query_failed"
        case pidMismatch = "ax_focus_pid_mismatch"
        case nonTextFocus = "non_text_focus"
    }

    struct ReadResult<Element> {
        let element: Element?
        let axResult: Int32
        let valueKind: ValueKind
        let pidResult: Int32?
        let candidatePID: Int32?
    }

    /// Deliberately excludes element handles, strings from controls, and window titles.
    struct Observation: Equatable, Sendable {
        let source: Source
        let axResult: Int32
        let valueKind: ValueKind
        let pidResult: Int32?
        let candidatePID: Int32?
        var outcome: Outcome
        let childProbeSkipped: Bool
    }

    struct Result<Element> {
        let element: Element?
        let source: Source?
        let observations: [Observation]
    }

    static func probe<Element>(
        expectedPID: Int32,
        includeFocusedWindow: Bool,
        isCurrent: @MainActor () -> Bool,
        read: @MainActor (Source, Element?) throws -> ReadResult<Element>,
        isUsableWindowFocus: @MainActor (Element, Element) throws -> Bool
    ) throws -> Result<Element> {
        var observations: [Observation] = []

        @MainActor
        func checkBoundary() throws {
            try Task.checkCancellation()
            let current = isCurrent()
            try Task.checkCancellation()
            guard current else { throw AccessibilityTextClient.Error.contentChanged }
        }

        @MainActor
        func query(
            _ source: Source,
            owner: Element? = nil,
            isParent: Bool = false
        ) throws -> Element? {
            try checkBoundary()
            let result: ReadResult<Element>
            do {
                result = try read(source, owner)
            } catch {
                try checkBoundary()
                throw error
            }
            try checkBoundary()
            let outcome = classify(result, expectedPID: expectedPID)
            observations.append(Observation(
                source: source,
                axResult: result.axResult,
                valueKind: result.valueKind,
                pidResult: result.pidResult,
                candidatePID: result.candidatePID,
                outcome: outcome,
                childProbeSkipped: isParent && outcome != .accepted
            ))
            return outcome == .accepted ? result.element : nil
        }

        @MainActor
        func finish(_ element: Element? = nil, source: Source? = nil) throws -> Result<Element> {
            try checkBoundary()
            return Result(element: element, source: source, observations: observations)
        }

        if let element = try query(.systemFocus) {
            return try finish(element, source: .systemFocus)
        }
        if let application = try query(.focusedApplication, isParent: true),
           let element = try query(.focusedApplicationFocus, owner: application) {
            return try finish(element, source: .focusedApplicationFocus)
        }
        if let element = try query(.applicationFocus) {
            return try finish(element, source: .applicationFocus)
        }
        if includeFocusedWindow,
           let window = try query(.focusedWindow, isParent: true),
           let element = try query(.windowFocus, owner: window) {
            try checkBoundary()
            let usable: Bool
            do {
                // Argument order is (candidate focus, the verified focused window).
                usable = try isUsableWindowFocus(element, window)
            } catch {
                try checkBoundary()
                throw error
            }
            try checkBoundary()
            if usable {
                return try finish(element, source: .windowFocus)
            }
            observations[observations.count - 1].outcome = .nonTextFocus
        }
        return try finish()
    }

    private static func classify<Element>(
        _ result: ReadResult<Element>, expectedPID: Int32
    ) -> Outcome {
        guard result.axResult == 0 else { return .focusNotReturned }
        guard result.valueKind != .other else { return .valueTypeMismatch }
        guard result.valueKind == .axElement, result.element != nil else {
            return .valueMissing
        }
        guard result.pidResult == 0, let candidatePID = result.candidatePID else {
            return .pidQueryFailed
        }
        guard candidatePID == expectedPID else { return .pidMismatch }
        return .accepted
    }
}
