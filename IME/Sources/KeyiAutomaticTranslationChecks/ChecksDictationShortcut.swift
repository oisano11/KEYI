//
//  ChecksDictationShortcut.swift
//  说话键（契约 2026-11-08）：哪些键能用、怎么命名、怎么判断按下松开、存取格式。
//  只测共享包里的纯逻辑，不读写用户的偏好。
//

import AppKit
import KEYITranslationClient

func checkDictationShortcut() {
    section("dictation shortcut")
    typealias Shortcut = KEYIDictationShortcut
    let ctrlOpt: NSEvent.ModifierFlags = [.control, .option]

    expect(Shortcut.standard == Shortcut(keyCode: 61) && Shortcut.standard.displayName() == "右 ⌥",
           "voice key: the default is right ⌥")
    expect(Shortcut.standard.displayName(english: true) == "Right ⌥", "voice key: English name of the default")

    // 能用的
    for code: UInt16 in [54, 55, 58, 61, 59, 62, 63] {
        expect(Shortcut(keyCode: code).isUsable, "voice key: single modifier \(code) is usable")
    }
    expect(Shortcut(keyCode: 9, modifiers: ctrlOpt, keyLabel: "v").isUsable, "voice key: ⌃⌥V is usable")
    expect(Shortcut(keyCode: 9, modifiers: [.command, .shift], keyLabel: "v").isUsable, "voice key: ⇧⌘V is usable")
    expect(Shortcut(keyCode: 96).isUsable && Shortcut(keyCode: 96, modifiers: .shift).isUsable,
           "voice key: F5 alone or with ⇧ is usable")
    expect(Shortcut(keyCode: 96, modifiers: .command).isUsable, "voice key: ⌘F5 is usable")

    // 不能用的，各有原因
    expect(Shortcut(keyCode: 56).problem == .shift && Shortcut(keyCode: 60).problem == .shift,
           "voice key: Shift alone is refused (Shift types capitals)")
    expect(Shortcut(keyCode: 9).problem == .plainKey, "voice key: a plain letter is refused")
    expect(Shortcut(keyCode: 9, modifiers: .shift, keyLabel: "v").problem == .plainKey,
           "voice key: Shift plus a letter is refused (that is typing)")
    expect(Shortcut(keyCode: 49).problem == .plainKey && Shortcut(keyCode: 36).problem == .plainKey
           && Shortcut(keyCode: 53).problem == .plainKey,
           "voice key: Space, Return and Esc alone are refused")
    expect(Shortcut(keyCode: 17, modifiers: ctrlOpt, keyLabel: "t").problem == .translationToggle,
           "voice key: ⌃⌥T is refused (automatic translation toggle)")
    expect(Shortcut(keyCode: 8, modifiers: .command, keyLabel: "c").problem == .commandShortcut,
           "voice key: ⌘C is refused (an application shortcut)")
    expect(Shortcut(keyCode: 57).problem == .unsupported, "voice key: Caps Lock is refused")
    expect(Shortcut(keyCode: 9, modifiers: [.control, .function], keyLabel: "v").modifiers == .control
           && Shortcut(keyCode: 9, modifiers: .function, keyLabel: "v").problem == .plainKey,
           "voice key: Fn does not count as a combination modifier")

    // 名字
    expectEqual(Shortcut(keyCode: 9, modifiers: [.command, .shift, .control, .option], keyLabel: "v").displayName(),
                "⌃⌥⇧⌘V", "voice key: modifiers are named in the system order")
    expectEqual(Shortcut(keyCode: 96).displayName(), "F5", "voice key: function keys are named by key code")
    expectEqual(Shortcut(keyCode: 49, modifiers: ctrlOpt).displayName(), "⌃⌥空格", "voice key: Space has a name")
    expectEqual(Shortcut(keyCode: 49, modifiers: ctrlOpt).displayName(english: true), "⌃⌥Space",
                "voice key: Space has an English name")
    expectEqual(Shortcut(keyCode: 54).displayName(), "右 ⌘", "voice key: right ⌘")
    expectEqual(Shortcut(keyCode: 63).displayName(), "Fn", "voice key: Fn")
    expect(Shortcut(keyCode: 54, modifiers: .command, keyLabel: "x").modifiers.isEmpty
           && Shortcut(keyCode: 54, modifiers: .command, keyLabel: "x").keyLabel.isEmpty,
           "voice key: a single modifier carries no combination modifiers or label")

    // 按下松开
    let rightCommand = Shortcut(keyCode: 54)
    expect(rightCommand.modifierKeyIsDown(keyCode: 54, rawFlags: NSEvent.ModifierFlags.command.rawValue | 0x10) == true,
           "voice key: right ⌘ down by its device bit")
    expect(rightCommand.modifierKeyIsDown(keyCode: 54, rawFlags: NSEvent.ModifierFlags.command.rawValue | 0x08) == false,
           "voice key: right ⌘ is up while only left ⌘ is held")
    expect(rightCommand.modifierKeyIsDown(keyCode: 54, rawFlags: NSEvent.ModifierFlags.command.rawValue) == true
           && rightCommand.modifierKeyIsDown(keyCode: 54, rawFlags: 0) == false,
           "voice key: without device bits the ⌘ flag decides")
    expect(rightCommand.modifierKeyIsDown(keyCode: 55, rawFlags: NSEvent.ModifierFlags.command.rawValue) == nil,
           "voice key: left ⌘ is another key")
    expect(rightCommand.heldModifiersToStart == .command, "voice key: right ⌘ starts with only ⌘ held")
    expect(Shortcut(keyCode: 63).modifierKeyIsDown(keyCode: 63, rawFlags: NSEvent.ModifierFlags.function.rawValue) == true,
           "voice key: Fn down by its flag")
    let combo = Shortcut(keyCode: 9, modifiers: ctrlOpt, keyLabel: "v")
    expect(combo.matchesKeyDown(keyCode: 9, flags: ctrlOpt) && combo.matchesKeyDown(keyCode: 9, flags: ctrlOpt.union(.capsLock)),
           "voice key: ⌃⌥V matches its own press (Caps Lock ignored)")
    expect(!combo.matchesKeyDown(keyCode: 9, flags: .control) && !combo.matchesKeyDown(keyCode: 9, flags: ctrlOpt.union(.command))
           && !combo.matchesKeyDown(keyCode: 11, flags: ctrlOpt),
           "voice key: fewer, more or other keys do not match")
    expect(Shortcut(keyCode: 96).matchesKeyDown(keyCode: 96, flags: .function), "voice key: F5 matches with the system's Fn flag")
    expect(!rightCommand.matchesKeyDown(keyCode: 54, flags: .command), "voice key: a single modifier never matches a key press")

    // 存取
    let stored = KEYIDictationShortcutSettings.encode(combo)
    expect(KEYIDictationShortcutSettings.decode(stored) == combo, "voice key: a stored combination reads back the same")
    expect(KEYIDictationShortcutSettings.decode(KEYIDictationShortcutSettings.encode(Shortcut(keyCode: 56))) == nil,
           "voice key: a stored Shift is not used")
    expect(KEYIDictationShortcutSettings.decode(["keyCode": 70000]) == nil && KEYIDictationShortcutSettings.decode(nil) == nil
           && KEYIDictationShortcutSettings.decode(["label": "x"]) == nil,
           "voice key: broken stored values are not used")
}
