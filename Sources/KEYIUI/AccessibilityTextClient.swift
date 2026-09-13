import AppKit
import ApplicationServices
import Carbon
import Foundation
import KEYICore
import OSLog

@MainActor
protocol FocusedTextAccess {
    var isTrusted: Bool { get }
    func requestTrustPrompt()
    func capture() async throws -> AccessibilityTextClient.Snapshot
    func replace(
        snapshot: AccessibilityTextClient.Snapshot,
        with translatedText: String,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws
}

@MainActor
final class AccessibilityTextClient: FocusedTextAccess {
    enum WriteMode: Equatable {
        case value
        case selectedText
        case browserPaste
        case keyboardPaste
        case terminalPaste
    }

    struct TargetIdentity {
        let element: AXUIElement?
        var window: AXUIElement? = nil
        var parent: AXUIElement? = nil
        var identifier: String? = nil
        var role: String? = nil

        func matches(_ current: TargetIdentity, allowsRecreatedElement: Bool = false) -> Bool {
            guard let element, let currentElement = current.element else { return false }
            if let window {
                guard let currentWindow = current.window, CFEqual(window, currentWindow) else { return false }
            }
            if CFEqual(element, currentElement) { return true }
            // A shared value is not identity. Only a stable identifier in the same
            // parent and window can establish continuity after a web rerender.
            guard allowsRecreatedElement,
                  window != nil,
                  let parent, let currentParent = current.parent,
                  CFEqual(parent, currentParent),
                  let identifier, !identifier.isEmpty, identifier == current.identifier,
                  let role, role == current.role else { return false }
            return true
        }
    }

    final class Snapshot {
        let element: AXUIElement?
        let applicationProcessIdentifier: pid_t?
        let originalValue: String
        let originalSelectedRange: NSRange
        let selection: FocusedTextSelection
        let writeMode: WriteMode
        let translationContext: String?
        let target: TargetIdentity
        let isTerminalBuffer: Bool

        init(
            element: AXUIElement?,
            applicationProcessIdentifier: pid_t?,
            originalValue: String,
            originalSelectedRange: NSRange,
            selection: FocusedTextSelection,
            writeMode: WriteMode,
            translationContext: String? = nil,
            target: TargetIdentity? = nil,
            isTerminalBuffer: Bool = false
        ) {
            self.element = element
            self.applicationProcessIdentifier = applicationProcessIdentifier
            self.originalValue = originalValue
            self.originalSelectedRange = originalSelectedRange
            self.selection = selection
            self.writeMode = writeMode
            self.translationContext = translationContext
            self.target = target ?? TargetIdentity(element: element)
            self.isTerminalBuffer = isTerminalBuffer || writeMode == .terminalPaste
        }
    }

    enum Error: LocalizedError {
        case permissionRequired
        case noFocusedText
        case unreadableText
        case invalidSelection
        case readOnlyText
        case terminalSelectionRequired
        case unsafeTerminalTranslation
        case terminalWriteFailed
        case terminalRecoveryRequired(originalText: String)
        case contentChanged
        case browserInputFailed
        case selectionUpdateTimedOut
        case writeFailed(AXError)

        /// Stable diagnostic categories; never include captured or translated text.
        var diagnosticCode: String {
            switch self {
            case .permissionRequired: "permission_required"
            case .noFocusedText: "no_focused_text"
            case .unreadableText: "unreadable_text"
            case .invalidSelection: "invalid_selection"
            case .readOnlyText: "read_only_text"
            case .terminalSelectionRequired: "terminal_selection_required"
            case .unsafeTerminalTranslation: "unsafe_terminal_translation"
            case .terminalWriteFailed: "terminal_write_failed"
            case .terminalRecoveryRequired: "terminal_recovery_required"
            case .contentChanged: "content_changed"
            case .browserInputFailed: "browser_input_failed"
            case .selectionUpdateTimedOut: "selection_update_timed_out"
            case .writeFailed: "ax_write_failed"
            }
        }

        var errorDescription: String? {
            let strings = InterfaceStrings.current
            return switch self {
            case .permissionRequired: strings.statusPermissionRequired
            case .noFocusedText: strings.accessibilityNoFocusedText
            case .unreadableText: strings.accessibilityUnreadableText
            case .invalidSelection: strings.accessibilityInvalidSelection
            case .readOnlyText: strings.accessibilityReadOnly
            case .terminalSelectionRequired: strings.terminalSelectionRequired
            case .unsafeTerminalTranslation: strings.unsafeTerminalTranslation
            case .terminalWriteFailed: strings.terminalWriteFailed
            case .terminalRecoveryRequired: strings.terminalRecoveryRequired
            case .contentChanged: strings.contentChanged
            case .browserInputFailed: strings.browserInputFailed
            case .selectionUpdateTimedOut: strings.browserInputFailed
            case let .writeFailed(error): strings.accessibilityWriteFailed(Int(error.rawValue))
            }
        }
    }

    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    func requestTrustPrompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func capture() async throws -> Snapshot {
        guard isTrusted else { throw Error.permissionRequired }

        do {
            return try await captureFromAccessibility()
        } catch Error.noFocusedText, Error.unreadableText, Error.readOnlyText {
            do {
                return try await captureFromKeyboard()
            } catch Error.noFocusedText {
                if requiresTerminalSelection() {
                    throw Error.terminalSelectionRequired
                }
                throw Error.noFocusedText
            }
        }
    }

    private func captureFromAccessibility() async throws -> Snapshot {
        let element = try await focusedElement()
        let target = targetIdentity(for: element)

        guard let value = try copyAttribute(kAXValueAttribute, from: element) as? String else {
            throw Error.unreadableText
        }
        let selectedRange = try selectionRange(from: element)

        if supportsTerminalCurrentLineCapture(element),
           let terminalSelection = TerminalCommandSelection.currentLine(
               in: value,
               cursorRange: selectedRange
           ),
           try isSettable(kAXSelectedTextRangeAttribute, on: element) {
            return Snapshot(
                element: element,
                applicationProcessIdentifier: processIdentifier(of: element),
                originalValue: value,
                originalSelectedRange: selectedRange,
                selection: terminalSelection,
                writeMode: .terminalPaste,
                target: target,
                isTerminalBuffer: true
            )
        }

        if isTerminalApplication(element), selectedRange.length == 0 {
            throw Error.terminalSelectionRequired
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
            isTerminalBuffer: isTerminalApplication(element)
        )
    }

    private func captureFromKeyboard() async throws -> Snapshot {
        guard let application = frontmostTargetApplication() else {
            throw Error.noFocusedText
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
                throw Error.noFocusedText
            }
            _ = try await requireTarget(target, processIdentifier: application.processIdentifier)
            guard postKeyCombo(virtualKey: CGKeyCode(kVK_ANSI_A)) else {
                throw Error.noFocusedText
            }
            await pause(80)
            guard let wholeText = await readFocusedSelection() else {
                throw Error.noFocusedText
            }
            text = wholeText
        }

        guard !text.isEmpty else { throw Error.noFocusedText }
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

    func replace(
        snapshot: Snapshot,
        with translatedText: String,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws {
        guard isTrusted else { throw Error.permissionRequired }
        try Self.validateReplacement(translatedText, for: snapshot)

        if case .keyboardPaste = snapshot.writeMode {
            try await replaceUsingKeyboardPaste(
                snapshot: snapshot,
                translatedText: translatedText,
                isCurrent: isCurrent
            )
            return
        }
        if case .terminalPaste = snapshot.writeMode {
            try await replaceTerminalCommand(
                snapshot: snapshot,
                translatedText: translatedText,
                isCurrent: isCurrent
            )
            return
        }

        let currentElement = try await requireTarget(
            snapshot.target,
            processIdentifier: snapshot.applicationProcessIdentifier,
            allowsRecreatedElement: snapshot.writeMode == .browserPaste
        )
        let currentValue = try? copyAttribute(
            kAXValueAttribute,
            from: currentElement
        ) as? String
        let currentRange = try? selectionRange(from: currentElement)
        guard currentValue == snapshot.originalValue,
              currentRange == snapshot.originalSelectedRange else {
            throw Error.contentChanged
        }

        guard let updatedValue = snapshot.selection.replacing(
            in: snapshot.originalValue,
            with: translatedText
        ) else {
            throw Error.invalidSelection
        }

        try TranslationWriteBackGate.requireActive(isCurrent)
        let result: AXError
        switch snapshot.writeMode {
        case .value:
            result = AXUIElementSetAttributeValue(
                currentElement,
                kAXValueAttribute as CFString,
                updatedValue as CFString
            )
        case .selectedText:
            result = AXUIElementSetAttributeValue(
                currentElement,
                kAXSelectedTextAttribute as CFString,
                translatedText as CFString
            )
        case .browserPaste:
            try await replaceUsingPaste(
                on: currentElement,
                range: snapshot.selection.range,
                translatedText: translatedText,
                originalValue: snapshot.originalValue,
                expectedValue: updatedValue,
                target: snapshot.target,
                processIdentifier: snapshot.applicationProcessIdentifier,
                isCurrent: isCurrent
            )
            return
        case .keyboardPaste:
            return
        case .terminalPaste:
            return
        }

        guard result == .success else { throw Error.writeFailed(result) }
        moveCaret(
            on: currentElement,
            to: snapshot.selection.range.location + (translatedText as NSString).length
        )
    }

    static func validateReplacement(_ text: String, for snapshot: Snapshot) throws {
        if snapshot.isTerminalBuffer && !TerminalCommandSelection.isSafeReplacement(text) {
            throw Error.unsafeTerminalTranslation
        }
    }

    enum BrowserWriteStrategy {
        case notWeb, paste, keyboardFallback
    }

    static func browserWriteStrategy(
        isWebInput: Bool, selectionRangeIsSettable: Bool
    ) -> BrowserWriteStrategy {
        guard isWebInput else { return .notWeb }
        return selectionRangeIsSettable ? .paste : .keyboardFallback
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

    private func requireTarget(
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

    private func focusedElement() async throws -> AXUIElement {
        let systemWide = AXUIElementCreateSystemWide()
        for attempt in 0..<4 {
            if let element = focusedElement(from: systemWide) {
                return element
            }

            if let focusedApplication = elementAttribute(
                kAXFocusedApplicationAttribute,
                from: systemWide
            ),
               let element = focusedElement(from: focusedApplication) {
                return element
            }

            if let application = frontmostTargetApplication() {
                let applicationElement = AXUIElementCreateApplication(
                    application.processIdentifier
                )
                if let element = focusedElement(from: applicationElement) {
                    return element
                }
            }

            if attempt < 3 {
                await pause(40)
            }
        }

        throw Error.noFocusedText
    }

    private func frontmostTargetApplication() -> NSRunningApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        return application
    }

    private func processIdentifier(of element: AXUIElement) -> pid_t? {
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

    private func readFocusedSelection() async -> String? {
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

    private func readFocusedSelection(
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> String? {
        try TranslationWriteBackGate.requireActive(isCurrent)
        return await readFocusedSelection()
    }

    private func replaceUsingKeyboardPaste(
        snapshot: Snapshot,
        translatedText: String,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws {
        _ = try await requireTarget(snapshot.target, processIdentifier: snapshot.applicationProcessIdentifier)

        let pasteboard = NSPasteboard.general
        let pasteboardScope = ScopedPasteboard(pasteboard: pasteboard)
        defer { pasteboardScope.restoreIfUnchanged() }

        let selectedText = try await readFocusedSelection(
            isCurrent: isCurrent
        )
        guard selectedText == snapshot.selection.text else {
            throw Error.contentChanged
        }

        guard pasteboardScope.isUnchanged else { throw Error.contentChanged }
        pasteboard.clearContents()
        pasteboardScope.trackLatestChange()
        let didWrite = pasteboard.setString(translatedText, forType: .string)
        pasteboardScope.trackLatestChange()
        guard didWrite else {
            throw Error.browserInputFailed
        }
        _ = try await requireTarget(snapshot.target, processIdentifier: snapshot.applicationProcessIdentifier)
        try TranslationWriteBackGate.requireActive(isCurrent)
        guard pasteboardScope.isUnchanged else { throw Error.contentChanged }
        guard postPasteShortcut() else {
            throw Error.browserInputFailed
        }
        await pause(120)
    }

    private func replaceTerminalCommand(
        snapshot: Snapshot,
        translatedText: String,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws {
        guard TerminalCommandSelection.isSafeReplacement(translatedText) else {
            throw Error.unsafeTerminalTranslation
        }
        guard let expectedProcessIdentifier = snapshot.applicationProcessIdentifier,
              frontmostTargetApplication()?.processIdentifier == expectedProcessIdentifier,
              let snapshotElement = snapshot.element,
              let currentElement = try? await focusedElement(),
              CFEqual(currentElement, snapshotElement),
              let currentValue = try? copyAttribute(
                  kAXValueAttribute,
                  from: currentElement
              ) as? String,
              currentValue == snapshot.originalValue,
              let currentRange = try? selectionRange(from: currentElement),
              currentRange == snapshot.originalSelectedRange,
              currentRange.length == 0 else {
            throw Error.contentChanged
        }

        let commandEnd = NSMaxRange(snapshot.selection.range)
        guard currentRange.location >= commandEnd else {
            throw Error.terminalWriteFailed
        }
        let originalText = snapshot.originalValue as NSString
        let trailingRange = NSRange(
            location: commandEnd,
            length: currentRange.location - commandEnd
        )
        let trailingText = originalText.substring(with: trailingRange)
        guard trailingText.rangeOfCharacter(from: .whitespaces.inverted) == nil else {
            throw Error.terminalWriteFailed
        }

        let deletedRange = NSRange(
            location: snapshot.selection.range.location,
            length: currentRange.location - snapshot.selection.range.location
        )
        let deletedText = originalText.substring(with: deletedRange)
        let pasteboard = NSPasteboard.general
        let pasteboardScope = ScopedPasteboard(pasteboard: pasteboard)
        defer { pasteboardScope.restoreIfUnchanged() }
        let replacementText = translatedText + trailingText
        pasteboard.clearContents()
        pasteboardScope.trackLatestChange()
        let didWrite = pasteboard.setString(replacementText, forType: .string)
        pasteboardScope.trackLatestChange()
        guard didWrite else {
            throw Error.terminalWriteFailed
        }
        _ = try await requireTarget(snapshot.target, processIdentifier: expectedProcessIdentifier)
        guard (try? selectionRange(from: snapshotElement)) == currentRange,
              stringAttribute(kAXValueAttribute, from: snapshotElement) == snapshot.originalValue else {
            throw Error.contentChanged
        }
        try TranslationWriteBackGate.requireActive(isCurrent)
        do {
            guard postBackspaces(count: deletedText.count, isSafe: {
                isCurrent() && pasteboardScope.isUnchanged
                    && self.frontmostTargetApplication()?.processIdentifier == expectedProcessIdentifier
                    && self.focusedElement(from: AXUIElementCreateApplication(expectedProcessIdentifier))
                        .map { CFEqual($0, snapshotElement) } == true
            }) else {
                throw Error.terminalWriteFailed
            }

            let clearedRange = NSRange(
                location: snapshot.selection.range.location,
                length: 0
            )
            guard await waitForTerminalState(
                snapshotElement: snapshotElement,
                expectedProcessIdentifier: expectedProcessIdentifier,
                expectedRange: clearedRange,
                expectedText: nil,
                expectedTextLocation: nil
            ) else {
                throw Error.terminalWriteFailed
            }

            guard frontmostTargetApplication()?.processIdentifier == expectedProcessIdentifier,
                  let focusedBeforePaste = try? await focusedElement(),
                  CFEqual(focusedBeforePaste, snapshotElement),
                  let rangeBeforePaste = try? selectionRange(from: focusedBeforePaste),
                  rangeBeforePaste == clearedRange else {
                throw Error.contentChanged
            }
            try TranslationWriteBackGate.requireActive(isCurrent)
            guard pasteboardScope.isUnchanged else { throw Error.contentChanged }
            guard postPasteShortcut() else {
                throw Error.terminalWriteFailed
            }

            let finalRange = NSRange(
                location: clearedRange.location + (replacementText as NSString).length,
                length: 0
            )
            guard await waitForTerminalState(
                snapshotElement: snapshotElement,
                expectedProcessIdentifier: expectedProcessIdentifier,
                expectedRange: finalRange,
                expectedText: translatedText,
                expectedTextLocation: snapshot.selection.range.location
            ) else {
                throw Error.terminalWriteFailed
            }
        } catch {
            // Deletion may be partial; never replay keys into a changed target.
            // The caller retains this original for an explicit recovery action.
            throw Error.terminalRecoveryRequired(originalText: deletedText)
        }
    }

    private func waitForTerminalState(
        snapshotElement: AXUIElement,
        expectedProcessIdentifier: pid_t,
        expectedRange: NSRange,
        expectedText: String?,
        expectedTextLocation: Int?
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(0.8)
        repeat {
            await pause(40)
            guard frontmostTargetApplication()?.processIdentifier
                    == expectedProcessIdentifier,
                  let currentElement = try? await focusedElement(),
                  CFEqual(currentElement, snapshotElement),
                  let currentRange = try? selectionRange(from: currentElement),
                  currentRange == expectedRange else {
                return false
            }

            guard let expectedText,
                  let expectedTextLocation else {
                return true
            }
            if let value = try? copyAttribute(
                kAXValueAttribute,
                from: currentElement
            ) as? String {
                let text = value as NSString
                let expectedTextRange = NSRange(
                    location: expectedTextLocation,
                    length: (expectedText as NSString).length
                )
                if expectedTextRange.location >= 0,
                   NSMaxRange(expectedTextRange) <= text.length,
                   text.substring(with: expectedTextRange) == expectedText {
                    return true
                }
            }
        } while Date() < deadline
        return false
    }

    private func focusedElement(from owner: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            owner,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func copyAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        )
        guard result == .success else {
            throw Error.unreadableText
        }
        return value
    }

    private func selectionRange(from element: AXUIElement) throws -> NSRange {
        guard let rawValue = try copyAttribute(
            kAXSelectedTextRangeAttribute,
            from: element
        ), CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            throw Error.invalidSelection
        }
        let value = unsafeDowncast(rawValue, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else {
            throw Error.invalidSelection
        }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range),
              range.location >= 0,
              range.length >= 0 else {
            throw Error.invalidSelection
        }
        return NSRange(location: range.location, length: range.length)
    }

    private func isSettable(
        _ attribute: String,
        on element: AXUIElement
    ) throws -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(
            element,
            attribute as CFString,
            &settable
        )
        guard result == .success else { return false }
        return settable.boolValue
    }

    private func requiresPasteWriteBack(_ element: AXUIElement) -> Bool {
        // Chromium/Electron 的 contenteditable 会把 AXValue 标记为可写，
        // 但直接写 AXValue 不一定触发应用内部的 input 事件。不要只依赖
        // 应用版本或浏览器名单：只要祖先树包含 AXWebArea，就使用真实粘贴。
        if hasWebAreaAncestor(element) {
            return true
        }

        var pid = pid_t()
        guard AXUIElementGetPid(element, &pid) == .success,
              let bundleIdentifier = NSRunningApplication(
                  processIdentifier: pid
              )?.bundleIdentifier else {
            return false
        }

        return Self.isWebTextInput(bundleIdentifier)
    }

    private func supportsTerminalCurrentLineCapture(
        _ element: AXUIElement
    ) -> Bool {
        guard isTerminalTextBuffer(element) else { return false }
        return terminalBundleIdentifier(for: element).map {
            Self.terminalBundleIdentifiers.contains($0)
        } ?? false
    }

    private func isTerminalApplication(_ element: AXUIElement) -> Bool {
        guard isTerminalTextBuffer(element) else { return false }
        return terminalBundleIdentifier(for: element).map {
            Self.terminalBundleIdentifiers.contains($0)
                || Self.terminalSelectionOnlyBundleIdentifiers.contains($0)
        } ?? false
    }

    static func requiresTerminalOutputGuard(
        bundleIdentifier: String?, role: String?, valueIsSettable: Bool
    ) -> Bool {
        guard let bundleIdentifier,
              terminalBundleIdentifiers.contains(bundleIdentifier)
                || terminalSelectionOnlyBundleIdentifiers.contains(bundleIdentifier) else { return false }
        // Only a positively identified editable field is exempt; opaque terminal
        // controls reached through keyboard fallback still need the guard.
        let isEditableField = (role == "AXTextField" || role == "AXTextArea") && valueIsSettable
        return !isEditableField
    }

    private func isTerminalTextBuffer(_ element: AXUIElement) -> Bool {
        stringAttribute(kAXRoleAttribute, from: element) == "AXTextArea"
            && (try? isSettable(kAXValueAttribute, on: element)) == false
    }

    private func terminalBundleIdentifier(
        for element: AXUIElement
    ) -> String? {
        guard let processIdentifier = processIdentifier(of: element) else {
            return nil
        }
        return NSRunningApplication(
            processIdentifier: processIdentifier
        )?.bundleIdentifier
    }

    private func requiresTerminalSelection() -> Bool {
        guard let bundleIdentifier = frontmostTargetApplication()?.bundleIdentifier else {
            return false
        }
        return Self.terminalBundleIdentifiers.contains(bundleIdentifier)
            || Self.terminalSelectionOnlyBundleIdentifiers.contains(bundleIdentifier)
    }

    private func hasWebAreaAncestor(_ element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<64 {
            if stringAttribute(kAXRoleAttribute, from: current) == "AXWebArea" {
                return true
            }
            guard let parent = elementAttribute(
                kAXParentAttribute,
                from: current
            ) else {
                return false
            }
            current = parent
        }
        return false
    }

    private func stringAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func elementAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func replaceUsingPaste(
        on element: AXUIElement,
        range: NSRange,
        translatedText: String,
        originalValue: String,
        expectedValue: String,
        target: TargetIdentity,
        processIdentifier: pid_t?,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws {
        try TranslationWriteBackGate.requireActive(isCurrent)
        let previousRange = try selectionRange(from: element)
        // AX success acknowledges the request; Chromium/Electron can publish
        // the new selection on a later event-loop turn. Wait for that one
        // request, preserving target/content checks on every observation.
        try await Self.waitForSelectionUpdate(requestSelection: {
            let result = self.setSelectionRange(range, on: element)
            guard result == .success else { throw Error.writeFailed(result) }
        }, isReady: {
            try TranslationWriteBackGate.requireActive(isCurrent)
            let current = try await self.requireTarget(
                target, processIdentifier: processIdentifier, allowsRecreatedElement: true
            )
            guard (try self.copyAttribute(kAXValueAttribute, from: current) as? String) == originalValue else {
                throw Error.contentChanged
            }
            let currentRange = try self.selectionRange(from: current)
            guard currentRange == range || currentRange == previousRange else {
                throw Error.contentChanged
            }
            return currentRange == range
        }, pause: {
            try await Task.sleep(for: .milliseconds(10))
        })

        let pasteboard = NSPasteboard.general
        let pasteboardScope = ScopedPasteboard(pasteboard: pasteboard)
        defer { pasteboardScope.restoreIfUnchanged() }
        pasteboard.clearContents()
        pasteboardScope.trackLatestChange()
        let didWrite = pasteboard.setString(translatedText, forType: .string)
        pasteboardScope.trackLatestChange()
        guard didWrite else {
            throw Error.browserInputFailed
        }

        let focusedBeforePaste = try await requireTarget(
            target, processIdentifier: processIdentifier, allowsRecreatedElement: true
        )
        guard (try? selectionRange(from: focusedBeforePaste)) == range,
              (try? copyAttribute(kAXValueAttribute, from: focusedBeforePaste) as? String) == originalValue else {
            throw Error.contentChanged
        }
        try TranslationWriteBackGate.requireActive(isCurrent)
        guard pasteboardScope.isUnchanged else { throw Error.contentChanged }
        guard postPasteShortcut() else {
            throw Error.browserInputFailed
        }

        let deadline = Date().addingTimeInterval(0.8)
        repeat {
            await pause(40)
            let verificationElement = try await requireTarget(
                target, processIdentifier: processIdentifier, allowsRecreatedElement: true
            )
            if let value = try? copyAttribute(
                kAXValueAttribute,
                from: verificationElement
            ) as? String,
               Self.pasteMatchesExpected(value, expected: expectedValue) {
                return
            }
        } while Date() < deadline

        throw Error.browserInputFailed
    }

    static func pasteMatchesExpected(_ actual: String, expected: String) -> Bool {
        actual == expected
    }

    static func waitForSelectionUpdate(
        requestSelection: () throws -> Void,
        isReady: () async throws -> Bool,
        pause: () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        try requestSelection()
        for attempt in 0..<21 {
            try Task.checkCancellation()
            if try await isReady() {
                if attempt > 0 {
                    Logger(subsystem: "com.keyi.input-translator", category: "WriteBack")
                        .info("Selection update acknowledged after polling; polls=\(attempt)")
                }
                return
            }
            if attempt < 20 { try await pause() }
        }
        throw Error.selectionUpdateTimedOut
    }

    private func setSelectionRange(
        _ range: NSRange,
        on element: AXUIElement
    ) -> AXError {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else {
            return .illegalArgument
        }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        )
    }

    private func postPasteShortcut() -> Bool {
        postKeyCombo(virtualKey: CGKeyCode(kVK_ANSI_V))
    }

    private func pause(_ milliseconds: Int) async {
        // 与 Thread.sleep 同长的等待，但只挂起任务、让出主线程；
        // 吞掉取消信号以保持与旧行为一致的轮询节奏。
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    private func postBackspaces(count: Int, isSafe: () -> Bool) -> Bool {
        guard count > 0,
              let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }
        for _ in 0..<count {
            guard isSafe() else { return false }
            guard let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_Delete),
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_Delete),
                keyDown: false
            ) else {
                return false
            }
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
        return true
    }

    private func postKeyCombo(virtualKey: CGKeyCode) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: virtualKey,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: virtualKey,
                  keyDown: false
              ) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func moveCaret(on element: AXUIElement, to location: Int) {
        var range = CFRange(location: location, length: 0)
        guard let value = AXValueCreate(.cfRange, &range) else { return }
        AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        )
    }

    private static let browserBundleIdentifiers: Set<String> = [
        "app.zen-browser.zen",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser",
        "org.mozilla.firefox"
    ]

    /// 网页编辑器与浏览器一律视为"网页输入"：键盘兜底全选和真实粘贴回写
    /// 共用同一份判定，避免两处名单漂移。
    private static func isWebTextInput(_ bundleIdentifier: String) -> Bool {
        webEditorBundleIdentifiers.contains(bundleIdentifier)
            || browserBundleIdentifiers.contains(bundleIdentifier)
            || bundleIdentifier.hasPrefix("com.google.Chrome")
            || bundleIdentifier.hasPrefix("com.microsoft.edgemac")
    }

    private static let webEditorBundleIdentifiers: Set<String> = [
        "com.openai.codex",
        "com.anthropic.claudefordesktop",
        "com.tencent.xinWeChat"
    ]

    private static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable"
    ]

    private static let terminalSelectionOnlyBundleIdentifiers: Set<String> = [
        "com.mitchellh.ghostty"
    ]
}

private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        let restoredItems = items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }
}

/// 借用系统剪贴板的统一出口：进入作用域时快照原内容，退出时若期间
/// 剪贴板没有出现我们之外的新变化就恢复快照，尽量不污染用户剪贴板。
final class ScopedPasteboard {
    private let pasteboard: NSPasteboard
    private let snapshot: PasteboardSnapshot
    private var trackedChangeCount: Int

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        trackedChangeCount = pasteboard.changeCount
    }

    /// 在每次由当前流程完成的读取或写入之后调用，把基准推进到最新变化。
    func trackLatestChange() {
        trackedChangeCount = pasteboard.changeCount
    }

    var isUnchanged: Bool { pasteboard.changeCount == trackedChangeCount }

    /// 在 defer 中调用：没有新变化才恢复，避免覆盖目标应用已读取的新内容。
    func restoreIfUnchanged() {
        if pasteboard.changeCount == trackedChangeCount {
            snapshot.restore(to: pasteboard)
        }
    }
}
