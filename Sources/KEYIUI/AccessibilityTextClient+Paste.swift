import AppKit
import Carbon
import OSLog

/// 粘贴式写回：浏览器和网页编辑器里用剪贴板加模拟按键替换文字，事后恢复剪贴板。
extension AccessibilityTextClient {
    enum BrowserWriteStrategy {
        case notWeb, paste, keyboardFallback
    }

    static func browserWriteStrategy(
        isWebInput: Bool, selectionRangeIsSettable: Bool
    ) -> BrowserWriteStrategy {
        guard isWebInput else { return .notWeb }
        return selectionRangeIsSettable ? .paste : .keyboardFallback
    }

    func replaceUsingKeyboardPaste(
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

    func replaceUsingPaste(
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

    func postPasteShortcut() -> Bool {
        postKeyCombo(virtualKey: CGKeyCode(kVK_ANSI_V))
    }

    func pause(_ milliseconds: Int) async {
        // 与 Thread.sleep 同长的等待，但只挂起任务、让出主线程；
        // 吞掉取消信号以保持与旧行为一致的轮询节奏。
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    func postBackspaces(count: Int, isSafe: () -> Bool) -> Bool {
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

    func postKeyCombo(virtualKey: CGKeyCode) -> Bool {
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

    func moveCaret(on element: AXUIElement, to location: Int) {
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
    static func isWebTextInput(_ bundleIdentifier: String) -> Bool {
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
}
