import AppKit
import KEYICore

/// 终端宿主：判断焦点属于哪种终端路由，终端命令行的写回与写后核对。
extension AccessibilityTextClient {
    static func verifyTerminalDraftPostWriteState(
        expectedValue: String,
        currentValue: String?,
        expectedRange: NSRange,
        currentRange: NSRange?
    ) throws {
        guard currentValue == expectedValue, currentRange == expectedRange else {
            throw Error.terminalWriteFailed
        }
    }

    func requireTerminalObservationCurrent(_ snapshot: Snapshot) throws {
        if snapshot.isEditableTerminalDraft {
            guard snapshot.terminalObservation?.isCurrent == true else {
                throw Error.contentChanged
            }
        } else if snapshot.terminalObservation?.isCurrent == false {
            throw Error.contentChanged
        }
    }

    func replaceTerminalCommand(
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

    private struct FocusedAXStructure {
        let role: String?
        let subrole: String?
        let identifiers: Set<String>
        let domClassNames: Set<String>
        let isInWebArea: Bool
    }

    func terminalHostRoute(
        for element: AXUIElement,
        bundleIdentifier: String?
    ) -> TerminalHostCapabilities.Route? {
        guard let host = TerminalHostCapabilities.host(for: bundleIdentifier) else {
            return nil
        }

        let structure: FocusedAXStructure
        if host == .visualStudioCode {
            structure = focusedAXStructure(for: element, parentLimit: 8)
        } else {
            let identifier = stringAttribute(kAXIdentifierAttribute, from: element)
            structure = FocusedAXStructure(
                role: stringAttribute(kAXRoleAttribute, from: element),
                subrole: stringAttribute(kAXSubroleAttribute, from: element),
                identifiers: Set(identifier.map { [$0] } ?? []),
                domClassNames: [],
                isInWebArea: false
            )
        }

        // This preflight reads structure metadata and setter capabilities only.
        // Terminal AXValue and selected range are not fetched unless the route
        // positively identifies an editable draft/editor field.
        return TerminalHostCapabilities.route(
            bundleIdentifier: bundleIdentifier,
            role: structure.role,
            subrole: structure.subrole,
            identifiers: structure.identifiers,
            domClassNames: structure.domClassNames,
            isInWebArea: structure.isInWebArea,
            valueIsSettable: (try? isSettable(kAXValueAttribute, on: element)) == true,
            selectedRangeIsSettable: (try? isSettable(
                kAXSelectedTextRangeAttribute,
                on: element
            )) == true
        )
    }

    /// Reads only role/identifier/class metadata on the focused control and a
    /// bounded parent chain. It never visits children or reads text/value,
    /// titles, or terminal history.
    private func focusedAXStructure(
        for element: AXUIElement,
        parentLimit: Int
    ) -> FocusedAXStructure {
        let focusedRole = stringAttribute(kAXRoleAttribute, from: element)
        var identifiers: Set<String> = []
        var domClassNames: Set<String> = []
        var isInWebArea = false
        var current: AXUIElement? = element

        for _ in 0..<parentLimit {
            guard let node = current else { break }
            if let identifier = stringAttribute(kAXIdentifierAttribute, from: node) {
                identifiers.insert(identifier)
            }
            if stringAttribute(kAXRoleAttribute, from: node) == "AXWebArea" {
                isInWebArea = true
            }
            if let classes = try? copyAttribute("AXDOMClassList", from: node) as? [String] {
                domClassNames.formUnion(classes)
            }
            current = elementAttribute(kAXParentAttribute, from: node)
        }

        return FocusedAXStructure(
            role: focusedRole,
            subrole: stringAttribute(kAXSubroleAttribute, from: element),
            identifiers: identifiers,
            domClassNames: domClassNames,
            isInWebArea: isInWebArea
        )
    }

    static func requiresTerminalOutputGuard(
        bundleIdentifier: String?, role: String?, valueIsSettable: Bool
    ) -> Bool {
        guard !TerminalHostCapabilities.allowsKeyboardFallback(
            bundleIdentifier: bundleIdentifier
        ) else { return false }
        let isEditableField = (role == "AXTextField" || role == "AXTextArea") && valueIsSettable
        return !isEditableField
    }

    func hasWebAreaAncestor(_ element: AXUIElement) -> Bool {
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
}
