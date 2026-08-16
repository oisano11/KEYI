import AppKit
import Carbon
import Foundation

struct HotKeyConfiguration: Codable, Equatable {
    static let `default` = HotKeyConfiguration(
        keyCode: UInt32(kVK_ANSI_T),
        modifiers: UInt32(optionKey),
        keyName: "T"
    )

    let keyCode: UInt32
    let modifiers: UInt32
    let keyName: String

    var displayName: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyName
    }

    var isValid: Bool {
        let requiredModifiers = UInt32(cmdKey | optionKey | controlKey)
        return modifiers & requiredModifiers != 0 && !keyName.isEmpty
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([
            .command,
            .option,
            .control,
            .shift
        ])
        guard flags.contains(.command)
                || flags.contains(.option)
                || flags.contains(.control),
              let keyName = Self.keyName(for: event.keyCode) else {
            return nil
        }

        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }

        self.init(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            keyName: keyName
        )
    }

    private init(keyCode: UInt32, modifiers: UInt32, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    private static func keyName(for keyCode: UInt16) -> String? {
        switch Int(keyCode) {
        case kVK_ANSI_A: "A"
        case kVK_ANSI_S: "S"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_H: "H"
        case kVK_ANSI_G: "G"
        case kVK_ANSI_Z: "Z"
        case kVK_ANSI_X: "X"
        case kVK_ANSI_C: "C"
        case kVK_ANSI_V: "V"
        case kVK_ANSI_B: "B"
        case kVK_ANSI_Q: "Q"
        case kVK_ANSI_W: "W"
        case kVK_ANSI_E: "E"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_Y: "Y"
        case kVK_ANSI_T: "T"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_6: "6"
        case kVK_ANSI_5: "5"
        case kVK_ANSI_Equal: "="
        case kVK_ANSI_9: "9"
        case kVK_ANSI_7: "7"
        case kVK_ANSI_Minus: "-"
        case kVK_ANSI_8: "8"
        case kVK_ANSI_0: "0"
        case kVK_ANSI_RightBracket: "]"
        case kVK_ANSI_O: "O"
        case kVK_ANSI_U: "U"
        case kVK_ANSI_LeftBracket: "["
        case kVK_ANSI_I: "I"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_J: "J"
        case kVK_ANSI_Quote: "'"
        case kVK_ANSI_K: "K"
        case kVK_ANSI_Semicolon: ";"
        case kVK_ANSI_Backslash: "\\"
        case kVK_ANSI_Comma: ","
        case kVK_ANSI_Slash: "/"
        case kVK_ANSI_N: "N"
        case kVK_ANSI_M: "M"
        case kVK_ANSI_Period: "."
        case kVK_ANSI_Grave: "`"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Space: "Space"
        case kVK_Delete: "⌫"
        case kVK_ForwardDelete: "⌦"
        case kVK_Home: "↖"
        case kVK_End: "↘"
        case kVK_PageUp: "⇞"
        case kVK_PageDown: "⇟"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_DownArrow: "↓"
        case kVK_UpArrow: "↑"
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        case kVK_F13: "F13"
        case kVK_F14: "F14"
        case kVK_F15: "F15"
        case kVK_F16: "F16"
        case kVK_F17: "F17"
        case kVK_F18: "F18"
        case kVK_F19: "F19"
        case kVK_F20: "F20"
        default: nil
        }
    }
}

final class HotKeySettingsStore {
    private let defaults: UserDefaults
    private let key = "hotKeyConfiguration"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var configuration: HotKeyConfiguration {
        guard let data = defaults.data(forKey: key),
              let configuration = try? JSONDecoder().decode(
                  HotKeyConfiguration.self,
                  from: data
              ),
              configuration.isValid else {
            return .default
        }
        return configuration
    }

    func save(_ configuration: HotKeyConfiguration) throws {
        let data = try JSONEncoder().encode(configuration)
        defaults.set(data, forKey: key)
    }
}

@MainActor
enum HotKeyRecorder {
    static func record(current: HotKeyConfiguration) -> HotKeyConfiguration? {
        let alert = NSAlert()
        alert.messageText = "设置全局快捷键"
        alert.informativeText = "请按下新组合键，需包含 ⌘、⌥ 或 ⌃。"

        let currentLabel = NSTextField(
            labelWithString: "当前：\(current.displayName)"
        )
        let recordedLabel = NSTextField(labelWithString: "等待输入…")
        recordedLabel.font = .monospacedSystemFont(ofSize: 18, weight: .medium)
        recordedLabel.alignment = .center

        let stack = NSStackView(views: [currentLabel, recordedLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.widthAnchor.constraint(equalToConstant: 320).isActive = true
        alert.accessoryView = stack
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.buttons[0].isEnabled = false

        var captured: HotKeyConfiguration?
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            event in
            if let configuration = HotKeyConfiguration(event: event) {
                captured = configuration
                recordedLabel.stringValue = configuration.displayName
                recordedLabel.textColor = .labelColor
                alert.buttons[0].isEnabled = true
            } else {
                captured = nil
                recordedLabel.stringValue = "请加入 ⌘、⌥ 或 ⌃"
                recordedLabel.textColor = .systemRed
                alert.buttons[0].isEnabled = false
            }
            return nil
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return captured
    }
}
