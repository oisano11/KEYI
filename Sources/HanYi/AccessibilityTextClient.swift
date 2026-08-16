import AppKit
import ApplicationServices
import Carbon
import Foundation
import HanYiCore

@MainActor
final class AccessibilityTextClient {
    enum WriteMode {
        case value
        case selectedText
        case browserPaste
        case keyboardPaste
        case terminalPaste
    }

    final class Snapshot {
        let element: AXUIElement?
        let applicationProcessIdentifier: pid_t?
        let originalValue: String
        let originalSelectedRange: NSRange
        let selection: FocusedTextSelection
        let writeMode: WriteMode
        let translationContext: String?

        init(
            element: AXUIElement?,
            applicationProcessIdentifier: pid_t?,
            originalValue: String,
            originalSelectedRange: NSRange,
            selection: FocusedTextSelection,
            writeMode: WriteMode,
            translationContext: String? = nil
        ) {
            self.element = element
            self.applicationProcessIdentifier = applicationProcessIdentifier
            self.originalValue = originalValue
            self.originalSelectedRange = originalSelectedRange
            self.selection = selection
            self.writeMode = writeMode
            self.translationContext = translationContext
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
        case contentChanged
        case browserInputFailed
        case writeFailed(AXError)

        var errorDescription: String? {
            switch self {
            case .permissionRequired: "需要辅助功能权限"
            case .noFocusedText: "当前没有可编辑的输入框"
            case .unreadableText: "无法读取当前输入框"
            case .invalidSelection: "当前文本选择范围无效"
            case .readOnlyText: "当前输入框不支持原地替换"
            case .terminalSelectionRequired: "终端命令：请先选中要翻译的内容，再触发翻译"
            case .unsafeTerminalTranslation: "终端译文包含换行或控制字符，已取消替换"
            case .terminalWriteFailed: "终端命令未能安全替换，已停止写入"
            case .contentChanged: "输入内容或焦点已变化，已取消替换"
            case .browserInputFailed: "浏览器输入框未接受翻译结果"
            case let .writeFailed(error): "写入输入框失败（\(error.rawValue)）"
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
                writeMode: .terminalPaste
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
        if requiresPasteWriteBack(element),
           try isSettable(kAXSelectedTextRangeAttribute, on: element) {
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
            translationContext: selection.text == value ? nil : value
        )
    }

    private func captureFromKeyboard() async throws -> Snapshot {
        guard let application = frontmostTargetApplication() else {
            throw Error.noFocusedText
        }

        let pasteboard = NSPasteboard.general
        let pasteboardScope = ScopedPasteboard(pasteboard: pasteboard)
        defer { pasteboardScope.restoreIfUnchanged() }

        let selectedText = await copyFocusedText(using: pasteboard)
        pasteboardScope.trackLatestChange()
        let text: String
        if let selectedText {
            text = selectedText
        } else {
            guard allowsWholeTextKeyboardFallback(application) else {
                throw Error.noFocusedText
            }
            guard postKeyCombo(virtualKey: CGKeyCode(kVK_ANSI_A)) else {
                throw Error.noFocusedText
            }
            await pause(80)
            guard let wholeText = await copyFocusedText(using: pasteboard) else {
                throw Error.noFocusedText
            }
            pasteboardScope.trackLatestChange()
            text = wholeText
        }

        guard !text.isEmpty else { throw Error.noFocusedText }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return Snapshot(
            element: nil,
            applicationProcessIdentifier: application.processIdentifier,
            originalValue: text,
            originalSelectedRange: range,
            selection: FocusedTextSelection(text: text, range: range),
            writeMode: .keyboardPaste
        )
    }

    func replace(snapshot: Snapshot, with translatedText: String) async throws {
        guard isTrusted else { throw Error.permissionRequired }

        if case .keyboardPaste = snapshot.writeMode {
            try await replaceUsingKeyboardPaste(
                snapshot: snapshot,
                translatedText: translatedText
            )
            return
        }
        if case .terminalPaste = snapshot.writeMode {
            try await replaceTerminalCommand(
                snapshot: snapshot,
                translatedText: translatedText
            )
            return
        }

        let currentElement: AXUIElement
        do {
            currentElement = try await focusedElement()
        } catch Error.noFocusedText {
            if case .browserPaste = snapshot.writeMode {
                try await replaceUsingKeyboardPaste(
                    snapshot: snapshot,
                    translatedText: translatedText
                )
                return
            }
            throw Error.noFocusedText
        }
        guard let snapshotElement = snapshot.element,
              CFEqual(currentElement, snapshotElement) else {
            if case .browserPaste = snapshot.writeMode {
                try await replaceUsingKeyboardPaste(
                    snapshot: snapshot,
                    translatedText: translatedText
                )
                return
            }
            throw Error.contentChanged
        }
        let currentValue = try? copyAttribute(
            kAXValueAttribute,
            from: currentElement
        ) as? String
        let currentRange = try? selectionRange(from: currentElement)
        guard currentValue == snapshot.originalValue,
              currentRange == snapshot.originalSelectedRange else {
            if case .browserPaste = snapshot.writeMode {
                try await replaceUsingKeyboardPaste(
                    snapshot: snapshot,
                    translatedText: translatedText
                )
                return
            }
            throw Error.contentChanged
        }

        guard let updatedValue = snapshot.selection.replacing(
            in: snapshot.originalValue,
            with: translatedText
        ) else {
            throw Error.invalidSelection
        }

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
                expectedValue: updatedValue
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

    private func copyFocusedText(using pasteboard: NSPasteboard) async -> String? {
        let previousChangeCount = pasteboard.changeCount
        guard postKeyCombo(virtualKey: CGKeyCode(kVK_ANSI_C)) else {
            return nil
        }
        await pause(80)
        guard pasteboard.changeCount != previousChangeCount else {
            return nil
        }
        let value = pasteboard.string(forType: .string)
        return value?.isEmpty == false ? value : nil
    }

    private func replaceUsingKeyboardPaste(
        snapshot: Snapshot,
        translatedText: String
    ) async throws {
        guard let expectedProcessIdentifier = snapshot.applicationProcessIdentifier,
              frontmostTargetApplication()?.processIdentifier == expectedProcessIdentifier else {
            throw Error.contentChanged
        }

        let pasteboard = NSPasteboard.general
        let pasteboardScope = ScopedPasteboard(pasteboard: pasteboard)
        defer { pasteboardScope.restoreIfUnchanged() }

        let selectionMatches = await restoreExpectedKeyboardSelection(
            snapshot: snapshot,
            using: pasteboard
        )
        pasteboardScope.trackLatestChange()
        guard selectionMatches else {
            throw Error.contentChanged
        }

        pasteboard.clearContents()
        guard pasteboard.setString(translatedText, forType: .string) else {
            throw Error.browserInputFailed
        }
        pasteboardScope.trackLatestChange()
        guard frontmostTargetApplication()?.processIdentifier
                == expectedProcessIdentifier else {
            throw Error.contentChanged
        }
        guard postPasteShortcut() else {
            throw Error.browserInputFailed
        }
        await pause(120)
    }

    private func restoreExpectedKeyboardSelection(
        snapshot: Snapshot,
        using pasteboard: NSPasteboard
    ) async -> Bool {
        if await copyFocusedText(using: pasteboard) == snapshot.selection.text {
            return true
        }

        // X 等受控编辑器重渲染后，原 AX 元素身份会变化。只要新版元素
        // 仍暴露相同全文，就在新版元素上恢复原选区，再走真实粘贴事件。
        if let element = try? await focusedElement(),
           let currentValue = try? copyAttribute(
               kAXValueAttribute,
               from: element
           ) as? String,
           currentValue == snapshot.originalValue,
           setSelectionRange(snapshot.selection.range, on: element) == .success {
            await pause(40)
            if await copyFocusedText(using: pasteboard) == snapshot.selection.text {
                return true
            }
        }

        // 新版 Chromium 可能短暂不暴露 AX 输入框。仅当原任务确实是翻译
        // 整个输入框时才重新全选；复制结果必须与原文完全一致才能回写。
        let originalLength = (snapshot.originalValue as NSString).length
        guard snapshot.selection.range == NSRange(location: 0, length: originalLength),
              snapshot.selection.text == snapshot.originalValue,
              postKeyCombo(virtualKey: CGKeyCode(kVK_ANSI_A)) else {
            return false
        }
        await pause(80)
        return await copyFocusedText(using: pasteboard) == snapshot.originalValue
    }

    private func replaceTerminalCommand(
        snapshot: Snapshot,
        translatedText: String
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
        guard postBackspaces(count: deletedText.count) else {
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

        let pasteboard = NSPasteboard.general
        let pasteboardScope = ScopedPasteboard(pasteboard: pasteboard)
        defer { pasteboardScope.restoreIfUnchanged() }

        let replacementText = translatedText + trailingText
        pasteboard.clearContents()
        guard pasteboard.setString(replacementText, forType: .string) else {
            throw Error.terminalWriteFailed
        }
        pasteboardScope.trackLatestChange()

        guard frontmostTargetApplication()?.processIdentifier == expectedProcessIdentifier,
              let focusedBeforePaste = try? await focusedElement(),
              CFEqual(focusedBeforePaste, snapshotElement),
              let rangeBeforePaste = try? selectionRange(from: focusedBeforePaste),
              rangeBeforePaste == clearedRange else {
            throw Error.contentChanged
        }
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
        expectedValue: String
    ) async throws {
        let selectionResult = setSelectionRange(range, on: element)
        guard selectionResult == .success else {
            throw Error.writeFailed(selectionResult)
        }

        let pasteboard = NSPasteboard.general
        let pasteboardScope = ScopedPasteboard(pasteboard: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(translatedText, forType: .string) else {
            throw Error.browserInputFailed
        }
        pasteboardScope.trackLatestChange()
        defer { pasteboardScope.restoreIfUnchanged() }

        guard postPasteShortcut() else {
            throw Error.browserInputFailed
        }

        let deadline = Date().addingTimeInterval(0.8)
        repeat {
            await pause(40)
            if let value = try? copyAttribute(
                kAXValueAttribute,
                from: element
            ) as? String,
               value == expectedValue
                || (value != originalValue && value.contains(translatedText)) {
                return
            }
        } while Date() < deadline

        throw Error.browserInputFailed
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

    private func postBackspaces(count: Int) -> Bool {
        guard count > 0,
              let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }
        for _ in 0..<count {
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
private final class ScopedPasteboard {
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

    /// 在 defer 中调用：没有新变化才恢复，避免覆盖目标应用已读取的新内容。
    func restoreIfUnchanged() {
        if pasteboard.changeCount == trackedChangeCount {
            snapshot.restore(to: pasteboard)
        }
    }
}
