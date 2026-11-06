import AppKit
import KEYICore

/// Terminal / Ghostty 里 zsh 行编辑器草稿的取文与写回（走 KEYITerminal 的 ZLE 租约，不读屏幕）。
extension AccessibilityTextClient {
    func captureZshDraft(for application: NSRunningApplication) async throws -> Snapshot {
        let processIdentifier = application.processIdentifier
        let (window, element) = try focusedZshTerminalTarget(for: application)
        let focusObservation = try ZshDraftFocusObservation.begin(applicationPID: processIdentifier)
        do {
            let capture = try await ZshDraftProcessClient.capture(hostPID: processIdentifier)
            guard focusObservation.isCurrent,
                  capture.hostPID == processIdentifier,
                  let currentApplication = frontmostTargetApplication(),
                  currentApplication.processIdentifier == processIdentifier,
                  currentApplication.bundleIdentifier == application.bundleIdentifier else {
                throw Error.contentChanged
            }
            let (currentWindow, currentElement) = try focusedZshTerminalTarget(for: application)
            guard CFEqual(window, currentWindow), CFEqual(element, currentElement) else {
                throw Error.contentChanged
            }
            let range = NSRange(location: 0, length: (capture.buffer as NSString).length)
            let ticket = ZshDraftTicket(capture: capture, focusObservation: focusObservation)
            return Snapshot(
                element: element,
                applicationProcessIdentifier: processIdentifier,
                originalValue: capture.buffer,
                originalSelectedRange: range,
                selection: FocusedTextSelection(text: capture.buffer, range: range),
                writeMode: .zshDraft,
                target: TargetIdentity(element: element, window: window, role: kAXTextAreaRole),
                isTerminalBuffer: true,
                zshTicket: ticket
            )
        } catch Error.contentChanged {
            focusObservation.invalidate()
            throw Error.contentChanged
        } catch {
            focusObservation.invalidate()
            throw Error.terminalEditorRequired
        }
    }

    private func focusedZshTerminalTarget(
        for expectedApplication: NSRunningApplication
    ) throws -> (window: AXUIElement, element: AXUIElement) {
        guard Self.supportsZshDraft(bundleIdentifier: expectedApplication.bundleIdentifier),
              let frontmost = frontmostTargetApplication(),
              frontmost.processIdentifier == expectedApplication.processIdentifier,
              frontmost.bundleIdentifier == expectedApplication.bundleIdentifier else {
            throw Error.contentChanged
        }
        let applicationElement = AXUIElementCreateApplication(expectedApplication.processIdentifier)
        guard let window = elementAttribute(kAXFocusedWindowAttribute, from: applicationElement),
              let element = elementAttribute(kAXFocusedUIElementAttribute, from: applicationElement),
              processIdentifier(of: window) == expectedApplication.processIdentifier,
              processIdentifier(of: element) == expectedApplication.processIdentifier,
              stringAttribute(kAXRoleAttribute, from: element) == kAXTextAreaRole,
              let elementWindow = elementAttribute(kAXWindowAttribute, from: element),
              CFEqual(window, elementWindow),
              stringAttribute(kAXRoleAttribute, from: window) == "AXWindow",
              stringAttribute(kAXSubroleAttribute, from: window) == "AXStandardWindow" else {
            throw Error.terminalEditorRequired
        }
        if let modal = try? copyAttribute(kAXModalAttribute, from: window) as? Bool, modal {
            throw Error.terminalEditorRequired
        }
        return (window, element)
    }

    func replaceZshDraft(
        snapshot: Snapshot,
        translatedText: String,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws {
        guard let ticket = snapshot.zshTicket,
              let processIdentifier = snapshot.applicationProcessIdentifier,
              ticket.capture.buffer == snapshot.originalValue,
              ticket.focusObservation.isCurrent,
              isCurrent(),
              let application = frontmostTargetApplication(),
              application.processIdentifier == processIdentifier else {
            throw Error.contentChanged
        }
        let (window, currentElement) = try focusedZshTerminalTarget(for: application)
        guard ticket.focusObservation.isCurrent,
              snapshot.target.matches(TargetIdentity(element: currentElement, window: window)) else {
            throw Error.contentChanged
        }
        try TranslationWriteBackGate.requireActive(isCurrent)
        guard ticket.focusObservation.isCurrent else { throw Error.contentChanged }
        do {
            let acknowledgement = try await ZshDraftProcessClient.commit(
                capture: ticket.capture,
                translatedText: translatedText,
                focusObservation: ticket.focusObservation
            )
            guard acknowledgement.ticketID == ticket.capture.ticketID,
                  acknowledgement.committed else {
                throw Error.terminalWriteFailed
            }
        } catch {
            if error is CancellationError { throw error }
            throw Error.terminalWriteFailed
        }
    }

    static func supportsZshDraft(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.apple.Terminal" || bundleIdentifier == "com.mitchellh.ghostty"
    }
}
