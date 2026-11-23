// 只用于 macOS 的界面绘制与按键；iOS 版不编译这一份。
#if canImport(AppKit)
import AppKit

/// 语音输入的说话键（契约 2026-11-08）：按住说话、松开结束。默认右 ⌥，用户在 KEYI 可译设置
/// 「高级 › 语音输入」里点一下再按想用的键自己设定。两种：
///
/// - 单个修饰键（区分左右；⌥、⌘、⌃ 或 Fn）：按下松开照常交给应用，和原来的右 ⌥ 一样。
/// - 修饰键加一个键，或单独的 F1–F20：归输入法，按下和松开都不交给应用；按下开始，
///   松开这个键或松开它的修饰键结束。
///
/// ⇧ 单独不行（Shift 要用来打大写，按住它打字时不能开始录音）；单独的普通键或只加 ⇧ 要用来打字；⌃⌥T 是自动翻译开关；
/// ⌘ 加一个键是应用的快捷键。这些在录的时候当场说明（`problem`）。
public struct KEYIDictationShortcut: Equatable, Sendable {
    /// 键码（kVK_*）。单个修饰键时是这个修饰键自己的键码，左右不同。
    public let keyCode: UInt16
    /// 组合键要同时按住的修饰键，只含 ⌃⌥⇧⌘；单个修饰键时为空。
    public let modifiers: NSEvent.ModifierFlags
    /// 主键上印的字（录下时记下，比如 "V"）；单个修饰键、功能键、方向键等按键码命名，可为空。
    public let keyLabel: String

    public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], keyLabel: String = "") {
        self.keyCode = keyCode
        let isModifierKey = Self.modifierKeys[keyCode] != nil
        self.modifiers = isModifierKey ? [] : modifiers.intersection(Self.comboModifiers)
        self.keyLabel = isModifierKey ? "" : keyLabel
    }

    public static let rightOption = KEYIDictationShortcut(keyCode: 61)
    public static let standard = rightOption

    /// 组合键里算数的修饰键。Fn 不算：功能键和方向键按下时系统自己会带上它。
    public static let comboModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    /// 判断「只按着这一个修饰键」时看的修饰键。
    public static let trackedModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command, .function]

    // MARK: 单个修饰键

    struct ModifierKey {
        let flag: NSEvent.ModifierFlags
        /// NX_DEVICE* 设备位：区分左右。Fn 没有。
        let deviceBit: UInt
        let otherSideBit: UInt
        let chineseName: String
        let englishName: String
    }

    static let modifierKeys: [UInt16: ModifierKey] = [
        54: ModifierKey(flag: .command, deviceBit: 0x10, otherSideBit: 0x08, chineseName: "右 ⌘", englishName: "Right ⌘"),
        55: ModifierKey(flag: .command, deviceBit: 0x08, otherSideBit: 0x10, chineseName: "左 ⌘", englishName: "Left ⌘"),
        56: ModifierKey(flag: .shift, deviceBit: 0x02, otherSideBit: 0x04, chineseName: "左 ⇧", englishName: "Left ⇧"),
        60: ModifierKey(flag: .shift, deviceBit: 0x04, otherSideBit: 0x02, chineseName: "右 ⇧", englishName: "Right ⇧"),
        58: ModifierKey(flag: .option, deviceBit: 0x20, otherSideBit: 0x40, chineseName: "左 ⌥", englishName: "Left ⌥"),
        61: ModifierKey(flag: .option, deviceBit: 0x40, otherSideBit: 0x20, chineseName: "右 ⌥", englishName: "Right ⌥"),
        59: ModifierKey(flag: .control, deviceBit: 0x01, otherSideBit: 0x2000, chineseName: "左 ⌃", englishName: "Left ⌃"),
        62: ModifierKey(flag: .control, deviceBit: 0x2000, otherSideBit: 0x01, chineseName: "右 ⌃", englishName: "Right ⌃"),
        63: ModifierKey(flag: .function, deviceBit: 0, otherSideBit: 0, chineseName: "Fn", englishName: "Fn"),
    ]

    /// 这个键码是不是修饰键（含 ⇧）。
    public static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        modifierKeys[keyCode] != nil
    }

    /// 是单个修饰键（按下松开交给应用），不是组合键或功能键。
    public var isModifierKey: Bool { Self.modifierKeys[keyCode] != nil }

    /// 单个修饰键：开始录音时只能按着它这一类修饰键；组合键：它要求的修饰键。
    public var heldModifiersToStart: NSEvent.ModifierFlags {
        Self.modifierKeys[keyCode]?.flag ?? modifiers
    }

    /// 单个修饰键的 flagsChanged：true 按下，false 松开；不是这个键返回 nil。
    /// 事件带左右设备位时按设备位判断；不带（诊断替身、部分宿主）时只看这类修饰键还在不在。
    public func modifierKeyIsDown(keyCode eventKeyCode: UInt16, rawFlags: UInt) -> Bool? {
        guard eventKeyCode == keyCode, let key = Self.modifierKeys[keyCode] else { return nil }
        if key.deviceBit != 0, rawFlags & (key.deviceBit | key.otherSideBit) != 0 {
            return rawFlags & key.deviceBit != 0
        }
        return NSEvent.ModifierFlags(rawValue: rawFlags).contains(key.flag)
    }

    /// 组合键或功能键的按下：键码相同、⌃⌥⇧⌘ 正好是要求的那几个。
    public func matchesKeyDown(keyCode eventKeyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        !isModifierKey && eventKeyCode == keyCode && flags.intersection(Self.comboModifiers) == modifiers
    }

    // MARK: 能不能用

    public enum Problem: Hashable, Sendable {
        /// 单独的 ⇧：Shift 要用来打大写。
        case shift
        /// 单独的普通键或只加 ⇧：要用来打字。
        case plainKey
        /// ⌃⌥T：自动翻译开关。
        case translationToggle
        /// ⌘ 加一个键：应用的快捷键（复制、粘贴……）。
        case commandShortcut
        /// Caps Lock 等不能按住的键。
        case unsupported
    }

    /// 不能当说话键的原因；能用时为 nil。
    public var problem: Problem? {
        if let key = Self.modifierKeys[keyCode] {
            return key.flag == .shift ? .shift : nil
        }
        if keyCode == Self.capsLock { return .unsupported }
        let significant = modifiers.intersection([.control, .option, .command])
        if significant.isEmpty {
            return Self.functionKeyNames[keyCode] == nil ? .plainKey : nil
        }
        if keyCode == Self.letterT, modifiers == [.control, .option] { return .translationToggle }
        if modifiers == .command, Self.functionKeyNames[keyCode] == nil { return .commandShortcut }
        return nil
    }

    public var isUsable: Bool { problem == nil }

    static let capsLock: UInt16 = 57
    static let letterT: UInt16 = 17

    // MARK: 名字

    /// 设置里和面板上显示的名字：「右 ⌥」「⌃⌥V」「F5」。
    public func displayName(english: Bool = false) -> String {
        if let key = Self.modifierKeys[keyCode] {
            return english ? key.englishName : key.chineseName
        }
        var name = ""
        if modifiers.contains(.control) { name += "⌃" }
        if modifiers.contains(.option) { name += "⌥" }
        if modifiers.contains(.shift) { name += "⇧" }
        if modifiers.contains(.command) { name += "⌘" }
        return name + keyName(english: english)
    }

    private func keyName(english: Bool) -> String {
        if let name = Self.functionKeyNames[keyCode] ?? Self.specialKeyNames[keyCode] { return name }
        if keyCode == Self.space { return english ? "Space" : "空格" }
        let label = keyLabel.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !label.isEmpty { return label }
        return english ? "Key \(keyCode)" : "键 \(keyCode)"
    }

    static let space: UInt16 = 49

    static let functionKeyNames: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    static let specialKeyNames: [UInt16: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]
}

/// 说话键存在 KEYI 可译偏好域（和外观、翻译风格同一个），改了以后发分布式通知，输入法当场换上。
public enum KEYIDictationShortcutSettings {
    public static let preferencesDomain = KEYITranslationStyle.preferencesDomain
    public static let storageKey = "dictation.shortcut"
    public static let didChangeNotification = Notification.Name("com.keyi.dictation-shortcut.changed")

    private static let keyCodeField = "keyCode"
    private static let modifiersField = "modifiers"
    private static let labelField = "label"

    /// 现在的说话键；没设过或存的不能用时是右 ⌥。
    public static var shortcut: KEYIDictationShortcut {
        CFPreferencesAppSynchronize(preferencesDomain as CFString)
        let value = CFPreferencesCopyAppValue(storageKey as CFString, preferencesDomain as CFString)
        return decode(value as? [String: Any]) ?? .standard
    }

    /// 存一个说话键。右 ⌥ 就删掉存的值（回到默认）；不能用的键不存。
    @discardableResult
    public static func store(_ shortcut: KEYIDictationShortcut) -> Bool {
        guard shortcut.isUsable else { return false }
        let value: CFPropertyList? = shortcut == .standard ? nil : encode(shortcut) as CFDictionary
        CFPreferencesSetAppValue(storageKey as CFString, value, preferencesDomain as CFString)
        CFPreferencesAppSynchronize(preferencesDomain as CFString)
        DistributedNotificationCenter.default().postNotificationName(
            didChangeNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        return true
    }

    public static func encode(_ shortcut: KEYIDictationShortcut) -> [String: Any] {
        [
            keyCodeField: Int(shortcut.keyCode),
            modifiersField: Int(shortcut.modifiers.rawValue),
            labelField: shortcut.keyLabel,
        ]
    }

    /// 读回存的值；缺字段、键码越界或不能用时返回 nil。
    public static func decode(_ dictionary: [String: Any]?) -> KEYIDictationShortcut? {
        guard let dictionary,
              let code = (dictionary[keyCodeField] as? NSNumber)?.intValue,
              (0...0xFFFF).contains(code)
        else { return nil }
        let modifiers = (dictionary[modifiersField] as? NSNumber)?.uintValue ?? 0
        let shortcut = KEYIDictationShortcut(
            keyCode: UInt16(code),
            modifiers: NSEvent.ModifierFlags(rawValue: modifiers),
            keyLabel: dictionary[labelField] as? String ?? ""
        )
        return shortcut.isUsable ? shortcut : nil
    }
}
#endif
