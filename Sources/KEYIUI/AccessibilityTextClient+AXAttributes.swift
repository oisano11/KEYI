import AppKit

/// 辅助功能属性的读写小工具：焦点元素、属性值、选区范围、可写性。
extension AccessibilityTextClient {
    func focusedElement(from owner: AXUIElement) -> AXUIElement? {
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

    func copyAttribute(
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

    func selectionRange(from element: AXUIElement) throws -> NSRange {
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

    func isSettable(
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

    func requiresPasteWriteBack(_ element: AXUIElement) -> Bool {
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

    func stringAttribute(
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

    func elementAttribute(
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
}
