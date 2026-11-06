import AppKit
import Carbon
import KEYICore

/// 取文：找到前台焦点输入框，读出选区或全文；辅助功能读不到时退到键盘复制。
extension AccessibilityTextClient {
    func captureFromAccessibility() async throws -> Snapshot {
        // Only an explicit capture may request Electron's focused AX element.
        // Target revalidation and every write-back path stay read-only here.
        let element = try await focusedElement(allowAccessibilityRecovery: true)
        let target = targetIdentity(for: element)
        let applicationPID = processIdentifier(of: element)
        let bundleIdentifier = applicationPID.flatMap {
            NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
        }
        let terminalRoute = terminalHostRoute(
            for: element,
            bundleIdentifier: bundleIdentifier
        )

        if terminalRoute == .rejectTerminalScreen
            || terminalRoute == .rejectUnclassifiedHybridTarget {
            throw Error.terminalEditorRequired
        }

        var terminalObservation: TerminalDraftObservation?
        var keepTerminalObservation = false
        defer {
            if !keepTerminalObservation {
                terminalObservation?.invalidate()
            }
        }

        if terminalRoute == .editableTerminalDraft {
            guard let applicationPID else { throw Error.terminalEditorRequired }
            do {
                // Subscribe before reading the editable value or its range so
                // changes during this request invalidate the eventual write.
                terminalObservation = try TerminalDraftObservation.begin(
                    element: element,
                    applicationPID: applicationPID
                )
            } catch {
                throw Error.terminalEditorRequired
            }
        }

        guard let value = try copyAttribute(kAXValueAttribute, from: element) as? String else {
            if terminalRoute == .editableTerminalDraft {
                throw Error.terminalEditorRequired
            }
            throw Error.unreadableText
        }
        let selectedRange: NSRange
        do {
            selectedRange = try selectionRange(from: element)
        } catch {
            if terminalRoute == .editableTerminalDraft {
                throw Error.terminalEditorRequired
            }
            throw error
        }

        if terminalRoute == .editableTerminalDraft {
            guard terminalObservation?.isCurrent == true,
                  let selection = FocusedTextSelection.translationSelection(
                    value: value,
                    selectedRange: selectedRange
                  ) else {
                throw Error.terminalEditorRequired
            }
            let verifiedElement = try await requireTarget(
                target,
                processIdentifier: applicationPID
            )
            let verifiedValue = try? copyAttribute(
                kAXValueAttribute,
                from: verifiedElement
            ) as? String
            let verifiedRange = try? selectionRange(from: verifiedElement)
            guard terminalObservation?.isCurrent == true,
                  Self.snapshotStateMatches(
                    originalValue: value,
                    originalRange: selectedRange,
                    currentValue: verifiedValue,
                    currentRange: verifiedRange
                  ) else {
                throw Error.contentChanged
            }
            keepTerminalObservation = true
            return Snapshot(
                element: element,
                applicationProcessIdentifier: applicationPID,
                originalValue: value,
                originalSelectedRange: selectedRange,
                selection: selection,
                writeMode: .value,
                target: target,
                isTerminalBuffer: true,
                isEditableTerminalDraft: true,
                terminalObservation: terminalObservation
            )
        }

        guard let selection = FocusedTextSelection.translationSelection(
            value: value,
            selectedRange: selectedRange
        ) else {
            throw Error.invalidSelection
        }

        let mode: WriteMode
        let browserStrategy = Self.browserWriteStrategy(
            isWebInput: requiresPasteWriteBack(element),
            selectionRangeIsSettable: try isSettable(kAXSelectedTextRangeAttribute, on: element)
        )
        if browserStrategy != .notWeb {
            // An unavailable AX selection setter must use the keyboard fallback,
            // never direct AXValue writes that bypass a controlled editor's input.
            guard browserStrategy == .paste else {
                throw Error.readOnlyText
            }
            mode = .browserPaste
        } else if try isSettable(kAXValueAttribute, on: element) {
            mode = .value
        } else if selectedRange.length > 0,
                  try isSettable(kAXSelectedTextAttribute, on: element) {
            mode = .selectedText
        } else {
            throw Error.readOnlyText
        }

        return Snapshot(
            element: element,
            applicationProcessIdentifier: processIdentifier(of: element),
            originalValue: value,
            originalSelectedRange: selectedRange,
            selection: selection,
            writeMode: mode,
            translationContext: selection.text == value ? nil : value,
            target: target,
            isTerminalBuffer: false
        )
    }

    func captureFromKeyboard() async throws -> Snapshot {
        guard let application = frontmostTargetApplication() else {
            logger.error("Focused text unavailable; phase=keyboard_target_unavailable")
            throw Error.noFocusedText
        }
        guard TerminalHostCapabilities.allowsKeyboardFallback(
            bundleIdentifier: application.bundleIdentifier
        ) else {
            throw Error.terminalEditorRequired
        }
        let element = try await focusedElement()
        let target = targetIdentity(for: element)
        let isTerminalBuffer = Self.requiresTerminalOutputGuard(
            bundleIdentifier: application.bundleIdentifier,
            role: stringAttribute(kAXRoleAttribute, from: element),
            valueIsSettable: (try? isSettable(kAXValueAttribute, on: element)) == true
        )

        let selectedText = await readFocusedSelection()
        let text: String
        if let selectedText {
            text = selectedText
        } else {
            guard allowsWholeTextKeyboardFallback(application) else {
                logger.error("Focused text unavailable; phase=selection_unavailable")
                throw Error.noFocusedText
            }
            _ = try await requireTarget(target, processIdentifier: application.processIdentifier)
            guard postKeyCombo(virtualKey: CGKeyCode(kVK_ANSI_A)) else {
                logger.error("Focused text unavailable; phase=selection_shortcut_unavailable")
                throw Error.noFocusedText
            }
            await pause(80)
            guard let wholeText = await readFocusedSelection() else {
                logger.error("Focused text unavailable; phase=selection_text_unavailable")
                throw Error.noFocusedText
            }
            text = wholeText
        }

        guard !text.isEmpty else {
            logger.error("Focused text unavailable; phase=empty_text")
            throw Error.noFocusedText
        }
        _ = try await requireTarget(target, processIdentifier: application.processIdentifier)
        let range = NSRange(location: 0, length: (text as NSString).length)
        return Snapshot(
            element: element,
            applicationProcessIdentifier: application.processIdentifier,
            originalValue: text,
            originalSelectedRange: range,
            selection: FocusedTextSelection(text: text, range: range),
            writeMode: .keyboardPaste,
            target: target,
            isTerminalBuffer: isTerminalBuffer
        )
    }

    private func targetIdentity(for element: AXUIElement) -> TargetIdentity {
        TargetIdentity(
            element: element,
            window: elementAttribute(kAXWindowAttribute, from: element),
            parent: elementAttribute(kAXParentAttribute, from: element),
            identifier: stringAttribute(kAXIdentifierAttribute, from: element),
            role: stringAttribute(kAXRoleAttribute, from: element)
        )
    }

    func requireTarget(
        _ target: TargetIdentity,
        processIdentifier: pid_t?,
        allowsRecreatedElement: Bool = false
    ) async throws -> AXUIElement {
        guard let processIdentifier,
              frontmostTargetApplication()?.processIdentifier == processIdentifier else {
            throw Error.contentChanged
        }
        let currentElement = try await focusedElement()
        guard frontmostTargetApplication()?.processIdentifier == processIdentifier,
              target.matches(targetIdentity(for: currentElement),
                             allowsRecreatedElement: allowsRecreatedElement) else {
            throw Error.contentChanged
        }
        return currentElement
    }

    func focusedElement(
        allowAccessibilityRecovery: Bool = false
    ) async throws -> AXUIElement {
        guard let application = frontmostTargetApplication() else {
            logger.error("Focused element unavailable; phase=frontmost_target_unavailable")
            throw Error.noFocusedText
        }
        let expectedPID = application.processIdentifier
        let expectedBundle = application.bundleIdentifier
        let systemWide = AXUIElementCreateSystemWide()
        let applicationElement = AXUIElementCreateApplication(expectedPID)
        let isCurrent: @MainActor () -> Bool = { [self] in
            guard let current = frontmostTargetApplication() else { return false }
            return current.processIdentifier == expectedPID
                && current.bundleIdentifier == expectedBundle
        }
        let checkBoundary: @MainActor () throws -> Void = {
            try Task.checkCancellation()
            let current = isCurrent()
            try Task.checkCancellation()
            guard current else { throw Error.contentChanged }
        }
        var observations: [FocusedElementProbe.Observation] = []
        var resolvedSource: FocusedElementProbe.Source?
        let read: @MainActor () throws -> AXUIElement? = {
            let probe: FocusedElementProbe.Result<AXUIElement> = try FocusedElementProbe.probe(
                expectedPID: expectedPID,
                includeFocusedWindow: expectedBundle == "com.openai.codex"
                    || TerminalHostCapabilities.isDedicatedTerminal(expectedBundle),
                isCurrent: isCurrent,
                read: { (source, owner) -> FocusedElementProbe.ReadResult<AXUIElement> in
                    let root: AXUIElement
                    let attribute: String
                    switch source {
                    case .systemFocus:
                        root = systemWide
                        attribute = kAXFocusedUIElementAttribute
                    case .focusedApplication:
                        root = systemWide
                        attribute = kAXFocusedApplicationAttribute
                    case .applicationFocus:
                        root = applicationElement
                        attribute = kAXFocusedUIElementAttribute
                    case .focusedWindow:
                        root = applicationElement
                        attribute = kAXFocusedWindowAttribute
                    case .focusedApplicationFocus, .windowFocus:
                        guard let owner else {
                            return .init(
                                element: nil, axResult: AXError.illegalArgument.rawValue,
                                valueKind: .missing, pidResult: nil, candidatePID: nil
                            )
                        }
                        root = owner
                        attribute = kAXFocusedUIElementAttribute
                    }

                    try checkBoundary()
                    var value: CFTypeRef?
                    let result = AXUIElementCopyAttributeValue(root, attribute as CFString, &value)
                    try checkBoundary()
                    let kind: FocusedElementProbe.ValueKind
                    let element: AXUIElement?
                    if let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                        kind = .axElement
                        element = result == .success ? unsafeDowncast(value, to: AXUIElement.self) : nil
                    } else {
                        kind = value == nil ? .missing : .other
                        element = nil
                    }
                    var pid = pid_t()
                    let pidResult: AXError?
                    if let element {
                        try checkBoundary()
                        pidResult = AXUIElementGetPid(element, &pid)
                        try checkBoundary()
                    } else {
                        pidResult = nil
                    }
                    return .init(
                        element: element, axResult: result.rawValue, valueKind: kind,
                        pidResult: pidResult?.rawValue,
                        candidatePID: pidResult == .success ? pid : nil
                    )
                },
                isUsableWindowFocus: { element, window in
                    // A window/root/group is not a draft. Never descend into it
                    // or let the keyboard fallback select its whole contents.
                    let sameWindow = CFEqual(element, window)
                    let sameApplication = CFEqual(element, applicationElement)
                    guard !sameWindow, !sameApplication else {
                        return false
                    }
                    try checkBoundary()
                    var roleValue: CFTypeRef?
                    let result = AXUIElementCopyAttributeValue(
                        element, kAXRoleAttribute as CFString, &roleValue
                    )
                    try checkBoundary()
                    guard result == .success, let role = roleValue as? String else { return false }
                    return Self.allowsWindowFocusedInput(
                        isSameAsWindow: sameWindow, isSameAsApplication: sameApplication, role: role
                    )
                }
            )
            observations = probe.observations
            resolvedSource = probe.source
            return probe.element
        }
        // Electron's standard application AXRole getter initializes basic native
        // accessibility. Use that read-only entry point once, not private
        // Manual/Enhanced setters with screen-reader side effects. Only a user
        // capture may initialize it; revalidation must never do so.
        let recovery: (@MainActor () -> Bool)?
        if Self.allowsInitialFocusRecovery(
            bundleIdentifier: expectedBundle,
            isInitialCapture: allowAccessibilityRecovery,
            isTrusted: isTrusted
        ) {
            recovery = { [self] in
                guard isCurrent(), isTrusted else { return false }
                var roleValue: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(
                    applicationElement, kAXRoleAttribute as CFString, &roleValue
                )
                let kind: String
                if let roleValue {
                    kind = CFGetTypeID(roleValue) == CFStringGetTypeID() ? "string" : "other"
                } else {
                    kind = "missing"
                }
                logger.notice("Focused element initialization read; method=standard_role; axResult=\(result.rawValue, privacy: .public); valueKind=\(kind, privacy: .public)")
                return result == .success && kind == "string"
            }
        } else {
            recovery = nil
        }
        do {
            let element = try await FocusedElementResolver.resolve(
                isCurrent: isCurrent,
                read: read,
                recover: recovery,
                wait: { try await Task.sleep(for: .milliseconds(40)) }
            )
            if allowAccessibilityRecovery {
                logger.notice("Focused element resolved; source=\(resolvedSource?.rawValue ?? "none", privacy: .public); bundle=\(expectedBundle ?? "none", privacy: .public)")
            }
            return element
        } catch Error.noFocusedText {
            let stable = isCurrent()
            for observation in observations {
                let pidResult = observation.pidResult.map { String($0) } ?? "not_checked"
                let candidatePID = observation.candidatePID.map { String($0) } ?? "none"
                let pidMatch = observation.candidatePID == expectedPID && observation.pidResult == 0
                logger.error("Focused element probe observed; source=\(observation.source.rawValue, privacy: .public); phase=\(observation.outcome.rawValue, privacy: .public); axResult=\(observation.axResult, privacy: .public); valueKind=\(observation.valueKind.rawValue, privacy: .public); pidResult=\(pidResult, privacy: .public); expectedPID=\(expectedPID, privacy: .public); candidatePID=\(candidatePID, privacy: .public); pidMatch=\(pidMatch, privacy: .public); childProbeSkipped=\(observation.childProbeSkipped, privacy: .public); frontmostStable=\(stable, privacy: .public)")
            }
            logger.error("Focused element unavailable; phase=focused_element_unavailable; bundle=\(expectedBundle ?? "none", privacy: .public); recoveryAllowed=\(recovery != nil, privacy: .public)")
            throw Error.noFocusedText
        }
    }

    static func allowsInitialFocusRecovery(
        bundleIdentifier: String?, isInitialCapture: Bool, isTrusted: Bool
    ) -> Bool {
        isInitialCapture && isTrusted && bundleIdentifier == "com.openai.codex"
    }

    static func allowsWindowFocusedInput(
        isSameAsWindow: Bool, isSameAsApplication: Bool, role: String?
    ) -> Bool {
        !isSameAsWindow && !isSameAsApplication
            && (role == kAXTextFieldRole || role == kAXTextAreaRole)
    }

    func frontmostTargetApplication() -> NSRunningApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        return application
    }

    func processIdentifier(of element: AXUIElement) -> pid_t? {
        var pid = pid_t()
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    private func allowsWholeTextKeyboardFallback(
        _ application: NSRunningApplication
    ) -> Bool {
        guard let bundleIdentifier = application.bundleIdentifier else {
            return false
        }
        return Self.isWebTextInput(bundleIdentifier)
    }

    func readFocusedSelection() async -> String? {
        // NSPasteboard has no public writer-identity API. Read the selection
        // from its AX owner instead of treating an unrelated clipboard update
        // as the result of Cmd-C. Unsupported controls fail closed.
        guard let element = try? await focusedElement() else { return nil }
        return Self.verifiedSelectionText(
            selectedText: stringAttribute(kAXSelectedTextAttribute, from: element),
            value: stringAttribute(kAXValueAttribute, from: element),
            range: try? selectionRange(from: element)
        )
    }

    static func verifiedSelectionText(selectedText: String?, value: String?, range: NSRange?) -> String? {
        if let selectedText, !selectedText.isEmpty { return selectedText }
        guard let value, let range, range.length > 0, range.location >= 0,
              range.location <= (value as NSString).length,
              range.length <= (value as NSString).length - range.location else { return nil }
        return (value as NSString).substring(with: range)
    }

    func readFocusedSelection(
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> String? {
        try TranslationWriteBackGate.requireActive(isCurrent)
        return await readFocusedSelection()
    }
}
