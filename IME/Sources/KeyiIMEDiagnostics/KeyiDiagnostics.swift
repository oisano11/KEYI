import AppKit
import Foundation
import InputMethodKit
import KeyiIMEBridge

/// Mock text client used by the diagnostic bundle test. It records exactly what
/// the input session asks a real client to insert or mark, so session behaviour
/// can be verified without a GUI.
public final class KeyiDiagnosticTextClient: NSObject, IMKTextInput {
    public private(set) var documentText: String
    public private(set) var markedText = ""
    public private(set) var insertedText = ""
    public private(set) var insertTextCallCount = 0
    public private(set) var commandCallCount = 0
    /// Replacement range handed to the most recent `insertText`, so the
    /// session's IMK replacement-range semantics can be asserted.
    public private(set) var lastInsertReplacementRange = NSRange(
        location: NSNotFound,
        length: 0
    )
    /// Called at the start of `insertText`, before any mutation, so a test can
    /// simulate a client that re-enters the input method mid-commit.
    public var reentrancyProbe: (() -> Void)?
    /// Character index the client last reported a line rect for, so candidate
    /// anchoring can be verified without a GUI.
    public private(set) var lastAnchorIndex: Int?
    /// Some clients report no marked range while still holding a selection (for
    /// example while a field is being edited outside the input method). Setting
    /// this makes the mock behave that way so the candidate-anchor fallback can
    /// be exercised.
    public var suppressesMarkedRange = false
    private var selectionRange = NSRange(location: 0, length: 0)
    private var markedDocumentRange = NSRange(location: NSNotFound, length: 0)
    private let caretRect = NSRect(x: 200, y: 600, width: 1, height: 22)

    public init(documentText: String = "") {
        self.documentText = documentText
        selectionRange = NSRange(
            location: (documentText as NSString).length,
            length: 0
        )
        super.init()
    }

    /// Document text outside the marked range, i.e. what the application has
    /// really received. `insertText` replaces the marked range and
    /// `setMarkedText` sets it, the way a real application does.
    public var committedText: String {
        guard markedDocumentRange.location != NSNotFound else { return documentText }
        return (documentText as NSString).replacingCharacters(in: markedDocumentRange, with: "")
    }

    // MARK: - IMKTextInput

    public func insertText(_ string: Any, replacementRange: NSRange) {
        insertTextCallCount += 1
        lastInsertReplacementRange = replacementRange
        reentrancyProbe?()
        let value = Self.plainText(string)
        let target = effectiveRange(replacementRange)
        let mutable = NSMutableString(string: documentText)
        mutable.replaceCharacters(in: target, with: value)
        documentText = mutable as String
        selectionRange = NSRange(
            location: target.location + (value as NSString).length,
            length: 0
        )
        markedDocumentRange = NSRange(location: NSNotFound, length: 0)
        markedText = ""
        insertedText = value
    }

    public func setMarkedText(
        _ string: Any,
        selectionRange: NSRange,
        replacementRange: NSRange
    ) {
        let value = Self.plainText(string)
        let target = effectiveRange(replacementRange)
        let mutable = NSMutableString(string: documentText)
        mutable.replaceCharacters(in: target, with: value)
        documentText = mutable as String
        if value.isEmpty {
            markedDocumentRange = NSRange(location: NSNotFound, length: 0)
            self.selectionRange = NSRange(location: target.location, length: 0)
        } else {
            let length = (value as NSString).length
            markedDocumentRange = NSRange(location: target.location, length: length)
            let location = min(selectionRange.location, length)
            self.selectionRange = NSRange(
                location: target.location + location,
                length: min(selectionRange.length, length - location)
            )
        }
        markedText = value
    }

    public func doCommand(
        bySelector selector: Selector,
        command: UnsafeMutablePointer<ObjCBool>?
    ) {
        commandCallCount += 1
    }

    public func selectedRange() -> NSRange {
        selectionRange
    }

    public func markedRange() -> NSRange {
        if suppressesMarkedRange {
            return NSRange(location: NSNotFound, length: 0)
        }
        return markedDocumentRange
    }

    public func hasMarkedText() -> Bool {
        !markedText.isEmpty
    }

    public func attributedSubstring(
        from range: NSRange
    ) -> NSAttributedString? {
        let length = (documentText as NSString).length
        guard range.location != NSNotFound,
              NSMaxRange(range) <= length
        else {
            return nil
        }
        return NSAttributedString(
            string: (documentText as NSString).substring(with: range)
        )
    }

    public func validAttributesForMarkedText() -> [Any]? {
        []
    }

    public func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        actualRange?.pointee = range
        return caretRect
    }

    public func characterIndex(
        for point: NSPoint,
        tracking mappingMode: IMKLocationToOffsetMappingMode,
        inMarkedRange: UnsafeMutablePointer<ObjCBool>?
    ) -> Int {
        inMarkedRange?.pointee = false
        return NSNotFound
    }

    public func attributes(
        forCharacterIndex index: Int,
        lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!
    ) -> [AnyHashable: Any]! {
        lastAnchorIndex = index
        lineRect?.pointee = caretRect
        return [:]
    }

    public func length() -> Int {
        (documentText as NSString).length
    }

    public func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String) {}
    public func selectMode(_ modeIdentifier: String) {}
    public func supportsUnicode() -> Bool { true }
    /// Pretends to be another app, so per-app candidate learning can be checked.
    /// The default identity is never learned from (see `InputSession.learningApp`).
    public var bundleIdentifierOverride: String?
    public func bundleIdentifier() -> String? {
        bundleIdentifierOverride ?? KeyiDiagnosticTextClient.diagnosticBundleIdentifier
    }

    private static let diagnosticBundleIdentifier =
        "com.keyi.inputmethod.keyi.diagnostic"
    public func windowLevel() -> CGWindowLevel { kCGNormalWindowLevel }
    public func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool {
        false
    }
    public func uniqueClientIdentifierString() -> String {
        "KEYI-Diagnostic-Client"
    }

    public func string(
        from range: NSRange,
        actualRange: NSRangePointer?
    ) -> String? {
        let length = (documentText as NSString).length
        guard range.location != NSNotFound,
              NSMaxRange(range) <= length
        else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return nil
        }
        actualRange?.pointee = range
        return (documentText as NSString).substring(with: range)
    }

    // MARK: - Helpers

    private static func plainText(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString {
            return attributed.string
        }
        return String(describing: value)
    }

    private func effectiveRange(_ replacementRange: NSRange) -> NSRange {
        let length = (documentText as NSString).length
        if replacementRange.location != NSNotFound,
           NSMaxRange(replacementRange) <= length
        {
            return replacementRange
        }
        if markedDocumentRange.location != NSNotFound,
           NSMaxRange(markedDocumentRange) <= length
        {
            return markedDocumentRange
        }
        if selectionRange.location != NSNotFound,
           NSMaxRange(selectionRange) <= length
        {
            return selectionRange
        }
        return NSRange(location: length, length: 0)
    }
}

/// Helpers that drive a real `InputSession` the way InputMethodKit does, used
/// by the bundle diagnostic and by the smoke test.
public enum KeyiSessionDiagnostics {
    /// The throwaway Rime user data directory diagnostics are pointed at, or nil
    /// when the process would fall back to the real user location.
    public static var userDataOverride: String? {
        ProcessInfo.processInfo.environment["KEYI_IME_USER_DATA_DIR"]
    }

    public static func sessionClass() -> AnyObject? {
        guard let sessionClass = NSClassFromString("KeyiInputSession")
            as? NSObject.Type
        else {
            return nil
        }
        return sessionClass.init()
    }

    /// `charactersIgnoringModifiers` defaults to `characters`. Real hosts can hand the
    /// input method a Shift+digit event whose ignoring-modifiers string is the bare
    /// digit ("1") while `characters` is the symbol ("!"); checks pass both.
    public static func keyEvent(
        characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        charactersIgnoringModifiers: String? = nil
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    /// Typing uses the text callback because that is what most clients use for
    /// plain letters; named keys go through the key event path.
    public static func typeText(
        _ text: String,
        into session: AnyObject,
        client: KeyiDiagnosticTextClient
    ) -> Bool {
        let selector = NSSelectorFromString("keyiInputText:client:")
        guard let object = session as? NSObject,
              object.responds(to: selector)
        else {
            return false
        }
        typealias Function = @convention(c) (
            AnyObject, Selector, NSString?, AnyObject?
        ) -> Bool
        let implementation = object.method(for: selector)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(object, selector, text as NSString, client)
    }

    public static func sendKey(
        _ keyCode: UInt16,
        characters: String,
        into session: AnyObject,
        client: KeyiDiagnosticTextClient,
        modifiers: NSEvent.ModifierFlags = [],
        charactersIgnoringModifiers: String? = nil
    ) -> Bool {
        let selector = NSSelectorFromString("keyiHandleEvent:client:")
        guard let object = session as? NSObject,
              object.responds(to: selector),
              let event = keyEvent(
                  characters: characters,
                  keyCode: keyCode,
                  modifiers: modifiers,
                  charactersIgnoringModifiers: charactersIgnoringModifiers
              )
        else {
            return false
        }
        typealias Function = @convention(c) (
            AnyObject, Selector, NSEvent?, AnyObject?
        ) -> Bool
        let implementation = object.method(for: selector)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(object, selector, event, client)
    }

    /// A modifier press or release (`flagsChanged`), e.g. tapping Shift: keyCode 56 with
    /// `[.shift]` presses the left Shift, keyCode 56 with `[]` releases it.
    @discardableResult
    public static func sendFlags(
        _ keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        into session: AnyObject,
        client: KeyiDiagnosticTextClient
    ) -> Bool {
        let selector = NSSelectorFromString("keyiHandleEvent:client:")
        guard let object = session as? NSObject,
              object.responds(to: selector),
              let event = NSEvent.keyEvent(
                  with: .flagsChanged,
                  location: .zero,
                  modifierFlags: modifiers,
                  timestamp: 0,
                  windowNumber: 0,
                  context: nil,
                  characters: "",
                  charactersIgnoringModifiers: "",
                  isARepeat: false,
                  keyCode: keyCode
              )
        else {
            return false
        }
        typealias Function = @convention(c) (
            AnyObject, Selector, NSEvent?, AnyObject?
        ) -> Bool
        let implementation = object.method(for: selector)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(object, selector, event, client)
    }

    public static func activate(
        _ session: AnyObject,
        client: KeyiDiagnosticTextClient
    ) {
        callSession(
            session,
            selectorName: "keyiActivateWithClient:",
            arguments: [client]
        )
    }

    public static func deactivate(
        _ session: AnyObject,
        client: KeyiDiagnosticTextClient
    ) {
        callSession(
            session,
            selectorName: "keyiDeactivateWithClient:",
            arguments: [client]
        )
    }

    public static func hidePalettes(_ session: AnyObject) {
        callSession(
            session,
            selectorName: "keyiHidePalettes",
            arguments: []
        )
    }

    /// Diagnostics-only: injects a controlled engine snapshot so the session's
    /// commit-and-remaining-preedit ordering can be covered even though this
    /// schema never produces both in one real snapshot.
    public static func inject(
        _ result: KeyiRimeResult,
        into session: AnyObject
    ) {
        let selector = NSSelectorFromString("keyiDiagnosticInjectResult:")
        guard let object = session as? NSObject,
              object.responds(to: selector)
        else {
            return
        }
        typealias Function = @convention(c) (
            AnyObject, Selector, AnyObject?
        ) -> Void
        let implementation = object.method(for: selector)
        let function = unsafeBitCast(implementation, to: Function.self)
        function(object, selector, result)
    }

    /// Diagnostics-only: drives the named-command callback
    /// (`didCommandBySelector:client:`) the way AppKit does for menu shortcuts.
    public static func sendCommand(
        _ selectorName: String,
        into session: AnyObject,
        client: KeyiDiagnosticTextClient
    ) -> Bool {
        let selector = NSSelectorFromString("keyiCommandNamed:client:")
        guard let object = session as? NSObject,
              object.responds(to: selector)
        else {
            return false
        }
        typealias Function = @convention(c) (
            AnyObject, Selector, NSString?, AnyObject?
        ) -> Bool
        let implementation = object.method(for: selector)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(object, selector, selectorName as NSString, client)
    }

    /// Diagnostics-only: reads back the last text this session handed to automatic
    /// translation. Lets a check prove a real confirmed Han commit reaches the
    /// automatic path — the wiring in `apply` cannot silently drift away from the
    /// engine while this stays empty.
    public static func lastConfirmedCommit(_ session: AnyObject) -> String? {
        let selector = NSSelectorFromString("keyiDiagnosticLastConfirmedCommit")
        guard let object = session as? NSObject,
              object.responds(to: selector)
        else {
            return nil
        }
        typealias Function = @convention(c) (
            AnyObject, Selector
        ) -> NSString?
        let implementation = object.method(for: selector)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(object, selector) as String?
    }

    /// Diagnostics-only: the candidates as the panel shows them, in display order.
    public static func visibleCandidates(_ session: AnyObject) -> [String] {
        let selector = NSSelectorFromString("keyiDiagnosticCandidatePresentation")
        guard let object = session as? NSObject,
              object.responds(to: selector)
        else {
            return []
        }
        typealias Function = @convention(c) (
            AnyObject, Selector
        ) -> NSArray
        let implementation = object.method(for: selector)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(object, selector) as? [String] ?? []
    }

    /// Diagnostics-only: clears the recorded confirmed commit between checks.
    public static func resetConfirmedCommit(_ session: AnyObject) {
        let selector = NSSelectorFromString("keyiDiagnosticResetConfirmedCommit")
        guard let object = session as? NSObject,
              object.responds(to: selector)
        else {
            return
        }
        typealias Function = @convention(c) (
            AnyObject, Selector
        ) -> Void
        let implementation = object.method(for: selector)
        let function = unsafeBitCast(implementation, to: Function.self)
        function(object, selector)
    }

    /// Diagnostics-only: drives the session's fake-translation seam (`install`,
    /// `hold`, `release`, `secure:0|1`, `auto:0|1`, `requests`). The session
    /// refuses every command unless `KEYI_IME_DIAGNOSTIC_FAKE_TRANSLATION=1` is set.
    @discardableResult
    public static func fakeTranslation(_ command: String, in session: AnyObject) -> String {
        let selector = NSSelectorFromString("keyiDiagnosticFakeCommand:")
        guard let object = session as? NSObject,
              object.responds(to: selector)
        else {
            return "unavailable"
        }
        typealias Function = @convention(c) (
            AnyObject, Selector, NSString
        ) -> NSString
        let implementation = object.method(for: selector)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(object, selector, command as NSString) as String
    }

    /// Diagnostics-only: IMK `commitComposition:` (the host clicked away).
    public static func commitComposition(
        _ session: AnyObject,
        client: KeyiDiagnosticTextClient
    ) {
        callSession(
            session,
            selectorName: "keyiCommitWithClient:",
            arguments: [client]
        )
    }

    /// Diagnostics-only: shows a "translating" preview owned by `session`.
    public static func showPreview(_ source: String, in session: AnyObject) {
        callSession(
            session,
            selectorName: "keyiDiagnosticShowPreview:",
            arguments: [source as NSString]
        )
    }

    /// Diagnostics-only: whether the translation preview panel is on screen,
    /// asked through any live session.
    public static func previewPanelVisible(_ session: AnyObject) -> Bool {
        let selector = NSSelectorFromString("keyiDiagnosticPreviewPanelVisible")
        guard let object = session as? NSObject,
              object.responds(to: selector)
        else {
            return false
        }
        typealias Function = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = object.method(for: selector)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(object, selector)
    }

    public static func ownsComposition(
        _ session: AnyObject,
        client: KeyiDiagnosticTextClient
    ) -> Bool {
        let selector = NSSelectorFromString(
            "keyiDiagnosticOwnsCompositionForClient:"
        )
        guard let object = session as? NSObject,
              object.responds(to: selector)
        else {
            return false
        }
        typealias Function = @convention(c) (
            AnyObject, Selector, AnyObject?
        ) -> Bool
        let implementation = object.method(for: selector)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(object, selector, client)
    }

    private static func callSession(
        _ session: AnyObject,
        selectorName: String,
        arguments: [AnyObject]
    ) {
        let selector = NSSelectorFromString(selectorName)
        guard let object = session as? NSObject,
              object.responds(to: selector)
        else {
            return
        }
        switch arguments.count {
        case 0:
            object.perform(selector)
        case 1:
            object.perform(selector, with: arguments[0])
        default:
            break
        }
    }
}
