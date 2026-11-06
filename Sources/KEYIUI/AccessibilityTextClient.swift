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
    let logger = Logger(
        subsystem: "com.keyi.input-translator",
        category: "Capture"
    )

    enum WriteMode: Equatable {
        case value
        case selectedText
        case browserPaste
        case keyboardPaste
        case terminalPaste
        case zshDraft
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
        let isEditableTerminalDraft: Bool
        let terminalObservation: TerminalDraftObservation?
        let zshTicket: ZshDraftTicket?

        init(
            element: AXUIElement?,
            applicationProcessIdentifier: pid_t?,
            originalValue: String,
            originalSelectedRange: NSRange,
            selection: FocusedTextSelection,
            writeMode: WriteMode,
            translationContext: String? = nil,
            target: TargetIdentity? = nil,
            isTerminalBuffer: Bool = false,
            isEditableTerminalDraft: Bool = false,
            terminalObservation: TerminalDraftObservation? = nil,
            zshTicket: ZshDraftTicket? = nil
        ) {
            self.element = element
            self.applicationProcessIdentifier = applicationProcessIdentifier
            self.originalValue = originalValue
            self.originalSelectedRange = originalSelectedRange
            self.selection = selection
            self.writeMode = writeMode
            self.translationContext = translationContext
            self.target = target ?? TargetIdentity(element: element)
            self.isTerminalBuffer = isTerminalBuffer
                || writeMode == .terminalPaste
                || writeMode == .zshDraft
            self.isEditableTerminalDraft = isEditableTerminalDraft
            self.terminalObservation = terminalObservation
            self.zshTicket = zshTicket
        }
    }

    enum Error: LocalizedError {
        case permissionRequired
        case noFocusedText
        case unreadableText
        case invalidSelection
        case readOnlyText
        case terminalSelectionRequired
        case terminalEditorRequired
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
            case .terminalEditorRequired: "terminal_editor_required"
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
            case .terminalEditorRequired: strings.terminalEditorRequired
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
        if let application = frontmostTargetApplication(),
           Self.supportsZshDraft(bundleIdentifier: application.bundleIdentifier) {
            return try await captureZshDraft(for: application)
        }
        let bundleIdentifier = frontmostTargetApplication()?.bundleIdentifier

        do {
            return try await captureFromAccessibility()
        } catch Error.noFocusedText, Error.unreadableText, Error.readOnlyText {
            guard TerminalHostCapabilities.allowsKeyboardFallback(
                bundleIdentifier: bundleIdentifier
            ) else {
                throw Error.terminalEditorRequired
            }
            do {
                return try await captureFromKeyboard()
            } catch Error.noFocusedText {
                throw Error.noFocusedText
            }
        }
    }

    func replace(
        snapshot: Snapshot,
        with translatedText: String,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws {
        defer { snapshot.terminalObservation?.invalidate() }
        defer { snapshot.zshTicket?.focusObservation.invalidate() }
        guard isTrusted else { throw Error.permissionRequired }
        try requireTerminalObservationCurrent(snapshot)
        try Self.validateReplacement(translatedText, for: snapshot)

        if snapshot.writeMode == .zshDraft {
            try await replaceZshDraft(
                snapshot: snapshot,
                translatedText: translatedText,
                isCurrent: isCurrent
            )
            return
        }

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
        guard Self.snapshotStateMatches(
            originalValue: snapshot.originalValue,
            originalRange: snapshot.originalSelectedRange,
            currentValue: currentValue,
            currentRange: currentRange
        ) else {
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
            try requireTerminalObservationCurrent(snapshot)
            result = AXUIElementSetAttributeValue(
                currentElement,
                kAXValueAttribute as CFString,
                updatedValue as CFString
            )
        case .selectedText:
            try requireTerminalObservationCurrent(snapshot)
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
        case .zshDraft:
            return
        }

        guard result == .success else {
            if snapshot.isEditableTerminalDraft {
                throw Error.terminalWriteFailed
            }
            throw Error.writeFailed(result)
        }

        let caretLocation = snapshot.selection.range.location
            + (translatedText as NSString).length
        if snapshot.isEditableTerminalDraft {
            guard let capturedElement = snapshot.element,
                  CFEqual(currentElement, capturedElement),
                  let writtenValue = try? copyAttribute(
                    kAXValueAttribute,
                    from: capturedElement
                  ) as? String,
                  writtenValue == updatedValue else {
                throw Error.terminalWriteFailed
            }

            // Writing the value may itself invalidate the observation. Verify
            // the concrete AX state instead of treating that notification as
            // an external edit; never retry or roll back an uncertain write.
            moveCaret(on: capturedElement, to: caretLocation)
            let expectedCaretRange = NSRange(location: caretLocation, length: 0)
            let finalValue = try? copyAttribute(
                kAXValueAttribute,
                from: capturedElement
            ) as? String
            let finalRange = try? selectionRange(from: capturedElement)
            try Self.verifyTerminalDraftPostWriteState(
                expectedValue: updatedValue,
                currentValue: finalValue,
                expectedRange: expectedCaretRange,
                currentRange: finalRange
            )
            return
        }

        moveCaret(on: currentElement, to: caretLocation)
    }

    static func validateReplacement(_ text: String, for snapshot: Snapshot) throws {
        if snapshot.isEditableTerminalDraft {
            guard isSafeEditableDraftReplacement(text) else {
                throw Error.unsafeTerminalTranslation
            }
        } else if snapshot.isTerminalBuffer && !TerminalCommandSelection.isSafeReplacement(text) {
            throw Error.unsafeTerminalTranslation
        }
    }

    static func isSafeEditableDraftReplacement(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
        }
    }

    static func snapshotStateMatches(
        originalValue: String,
        originalRange: NSRange,
        currentValue: String?,
        currentRange: NSRange?
    ) -> Bool {
        currentValue == originalValue && currentRange == originalRange
    }
}

