import AppKit
import KeyiIMETranslation

/// Translation between AppKit key events and the key codes librime expects.
/// Rime uses the X11 keysym values for non-printing keys.
enum KeyiRimeKeyMapper {
    static let backspace = 0xff08
    static let deleteForward = 0xffff
    static let `return` = 0xff0d
    static let escape = 0xff1b
    static let space = 0x20
    static let tab = 0xff09
    static let leftArrow = 0xff51
    static let upArrow = 0xff52
    static let rightArrow = 0xff53
    static let downArrow = 0xff54
    static let pageUp = 0xff55
    static let pageDown = 0xff56
    static let equal = 0x3d
    static let minus = 0x2d
    /// Hardware key codes that have no Rime mapping today.
    static let homeKeyCode: UInt16 = 115
    static let endKeyCode: UInt16 = 119
    private static let functionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    /// Maps a hardware key code with its characters to a Rime key, or nil when
    /// the key should be left to the client.
    static func rimeKey(keyCode: UInt16, characters: String?) -> Int? {
        switch keyCode {
        case 36, 76:
            return `return`
        case 48:
            return tab
        case 49:
            return space
        case 51:
            return backspace
        case 117:
            // Hardware Delete (fn+Backspace) is forward delete, not backspace.
            return deleteForward
        case 53:
            return escape
        case 123:
            return leftArrow
        case 124:
            return rightArrow
        case 125:
            return downArrow
        case 126:
            return upArrow
        case 116:
            return pageUp
        case 121:
            return pageDown
        default:
            guard let scalar = characters?.unicodeScalars.first,
                  scalar.isASCII
            else {
                return nil
            }
            switch scalar.value {
            case 0x08, 0x7f:
                return backspace
            case 0x09, 0x19:
                return tab
            case 0x0a, 0x0d:
                return `return`
            case 0x1b:
                return escape
            default:
                return Int(scalar.value)
            }
        }
    }

    /// The characters a key event types, for the Rime key. With Shift and no
    /// Command/Control/Option the shifted character counts (Shift+1 types "!"):
    /// real hosts can report the bare digit as `charactersIgnoringModifiers`, which
    /// made Shift+digit type the digit. Squirrel reads `characters` the same way.
    /// Other chords keep the unmodified character so shortcuts stay recognisable.
    static func typedCharacters(
        characters: String?,
        ignoringModifiers: String?,
        flags: NSEvent.ModifierFlags
    ) -> String? {
        guard flags.contains(.shift),
              flags.isDisjoint(with: [.command, .control, .option]),
              let characters,
              let scalar = characters.unicodeScalars.first,
              characters.unicodeScalars.count == 1,
              scalar.value >= 0x21, scalar.value <= 0x7e
        else {
            return ignoringModifiers
        }
        return characters
    }

    /// Bit layout of librime's modifier mask.
    static func rimeModifiers(for flags: NSEvent.ModifierFlags) -> UInt {
        var result: UInt = 0
        if flags.contains(.shift) { result |= 1 << 0 }
        if flags.contains(.capsLock) { result |= 1 << 1 }
        if flags.contains(.control) { result |= 1 << 2 }
        if flags.contains(.option) { result |= 1 << 3 }
        if flags.contains(.command) { result |= 1 << 26 }
        return result
    }

    /// Live modifier flags, normalized the way `handle(event:client:)` reads
    /// them. Used by the callbacks that are not handed an NSEvent, so all three
    /// input paths decide pass-through from the same set of flags.
    static func currentModifierFlags() -> NSEvent.ModifierFlags {
        NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
    }

    /// Command chords and every control/option shortcut belong to the client,
    /// so the input method never swallows them.
    static func shouldPassThrough(_ flags: NSEvent.ModifierFlags) -> Bool {
        if flags.contains(.command) || flags.contains(.control) {
            return true
        }
        if flags.contains(.option) {
            // Option is a legitimate pinyin path separator in Rime ("'"), but
            // it is far more common as an application shortcut on macOS.
            return true
        }
        return false
    }

    /// Classifies a key for the automatic translation controller (used while it
    /// holds text and no pinyin is being typed). Returns nil for ordinary
    /// printable keys, which go through Rime as before.
    ///
    /// `rimeKey` is nil for keys the Rime mapper does not know (Home, End,
    /// function keys, non-ASCII input); those never reach the engine.
    static func automaticKey(
        keyCode: UInt16,
        rimeKey: Int?,
        characters: String? = nil,
        flags: NSEvent.ModifierFlags
    ) -> KeyiAutomaticTranslationKey? {
        let chordFlags = shouldPassThrough(flags)
        // Enter (also Shift/Command/Control/Option + Enter) counts as Enter.
        if rimeKey == `return` { return .enter }
        if chordFlags { return .chord }
        if keyCode == homeKeyCode || keyCode == endKeyCode { return .navigation }
        if functionKeyCodes.contains(keyCode) { return .chord }
        guard let rimeKey else {
            // AppKit function-key characters (U+F700...) when no hardware key code came with them.
            if let value = characters?.unicodeScalars.first?.value {
                switch value {
                case 0xF700...0xF703, 0xF728, 0xF729, 0xF72B, 0xF72C, 0xF72D:
                    return .navigation
                default:
                    break
                }
            }
            return .chord
        }
        switch rimeKey {
        case backspace: return .backspace
        case escape: return .escape
        case tab, leftArrow, rightArrow, upArrow, downArrow, pageUp, pageDown, deleteForward:
            return .navigation
        default:
            return nil
        }
    }
}
