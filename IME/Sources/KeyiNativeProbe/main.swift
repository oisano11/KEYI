import AppKit
import Carbon.HIToolbox
import Foundation

// Native routing probe for the KEYI input method.
//
// Automated checks can only reach a real input method through the text input
// pipeline. Posting synthetic key events is not enough: an application that
// has not established its text input context yet simply receives the raw
// characters, which looks exactly like an input method that never engaged.
//
// This probe therefore uses the same path a physical keyboard takes: a real
// `NSTextView` inside a real key window, with HID-level key events posted to the
// system event tap. It waits until the view's `NSTextInputContext` is the active
// one before typing, because keys sent before that point are inserted as raw
// characters and look like a routing failure that is really a race.
//
// The report distinguishes
//
//   * the input method engaged (marked text, committed text)
//   * the source declined and the text view inserted raw characters
//   * the text input context was not active at all
//
// It never registers, enables, or selects an input source. By default it
// refuses to type unless the current input source is KEYI, so a pass can never
// be attributed to the wrong input method.

private struct Options {
    var keyScript = "nihao{space}"
    var expected: String?
    var outputPath: String?
    var settleDelay: TimeInterval = 1.5
    var probeOnly = false
    var allowOtherSource = false
    var requiredSourcePrefix = "com.keyi.inputmethod.keyi"
    var waitForSource: TimeInterval = 0
}

private func usage() -> Never {
    let text = """
    usage: keyi-native-probe [options]

      --keys <script>          keys to send; default "nihao{space}".
                               Characters are sent literally; special keys use
                               braces: {space} {return} {esc} {delete}
                               {forward-delete} {left} {right} {up} {down}
                               {tab} {pageup} {pagedown} {cmd-c} {ctrl-a}
      --expect <text>          require this substring in the document
      --output <path>          also write the report to this file
      --settle <seconds>       wait before reading the document (default 1.5)
      --probe-only             print the current input source and exit
      --allow-other-source     type even when the source is not KEYI
      --source <identifier>    required current source prefix
      --wait-source <seconds>  wait this long for the required source to appear
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

private func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    func next(_ name: String) -> String {
        guard !arguments.isEmpty else { usage() }
        let value = arguments.removeFirst()
        guard !value.hasPrefix("--") else {
            FileHandle.standardError.write(
                Data("missing value for \(name)\n".utf8)
            )
            usage()
        }
        return value
    }
    while !arguments.isEmpty {
        switch arguments.removeFirst() {
        case "--keys":
            options.keyScript = next("--keys")
        case "--expect":
            options.expected = next("--expect")
        case "--output":
            options.outputPath = next("--output")
        case "--settle":
            options.settleDelay = TimeInterval(next("--settle")) ?? options.settleDelay
        case "--probe-only":
            options.probeOnly = true
        case "--allow-other-source":
            options.allowOtherSource = true
        case "--source":
            options.requiredSourcePrefix = next("--source")
        case "--wait-source":
            options.waitForSource = TimeInterval(next("--wait-source")) ?? 0
        default:
            usage()
        }
    }
    return options
}

// MARK: - Text input source (read-only)

private func inputSourceIdentifier(_ source: TISInputSource) -> String? {
    guard
        let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
    else { return nil }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

private func currentInputSourceIdentifier() -> String? {
    guard
        let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
        let identifier = inputSourceIdentifier(source)
    else { return nil }
    return identifier
}

// MARK: - Key script

private let ansiKeyCodes: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
    "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
    "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
    "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
    "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
    "n": 45, "m": 46, ".": 47,
]

private let specialKeys: [String: (CGKeyCode, String)] = [
    "space": (49, " "),
    "return": (36, "\r"),
    "enter": (36, "\r"),
    "tab": (48, "\t"),
    "esc": (53, "\u{1b}"),
    "escape": (53, "\u{1b}"),
    "delete": (51, "\u{7f}"),
    "backspace": (51, "\u{7f}"),
    "forward-delete": (117, "\u{f728}"),
    "left": (123, "\u{f702}"),
    "right": (124, "\u{f703}"),
    "down": (125, "\u{f701}"),
    "up": (126, "\u{f700}"),
    "pageup": (116, "\u{f72c}"),
    "pagedown": (121, "\u{f72d}"),
]

private struct PlannedKey {
    let keyCode: CGKeyCode
    let characters: String
    let flags: NSEvent.ModifierFlags
    let label: String
}

private func parseKeyScript(_ script: String) -> [PlannedKey] {
    var planned: [PlannedKey] = []
    var literal = ""
    func appendLiteral() {
        for character in literal {
            guard let keyCode = ansiKeyCodes[character] else { continue }
            planned.append(
                PlannedKey(
                    keyCode: keyCode,
                    characters: String(character),
                    flags: [],
                    label: String(character)
                )
            )
        }
        literal = ""
    }
    var index = script.startIndex
    while index < script.endIndex {
        let character = script[index]
        if character != "{" {
            literal.append(character)
            index = script.index(after: index)
            continue
        }
        appendLiteral()
        guard let closing = script[index...].firstIndex(of: "}") else { break }
        let token = String(script[script.index(after: index)..<closing])
        index = script.index(after: closing)
        var flags: NSEvent.ModifierFlags = []
        var name = token
        for (prefix, flag) in [
            ("cmd-", NSEvent.ModifierFlags.command),
            ("ctrl-", NSEvent.ModifierFlags.control),
            ("opt-", NSEvent.ModifierFlags.option),
            ("shift-", NSEvent.ModifierFlags.shift),
        ] where name.hasPrefix(prefix) {
            flags.insert(flag)
            name.removeFirst(prefix.count)
            break
        }
        let lowercased = name.lowercased()
        if let special = specialKeys[lowercased] {
            planned.append(
                PlannedKey(
                    keyCode: special.0,
                    characters: special.1,
                    flags: flags,
                    label: token
                )
            )
        } else if name.count == 1, let character = name.first,
                  let keyCode = ansiKeyCodes[character]
        {
            planned.append(
                PlannedKey(
                    keyCode: keyCode,
                    characters: String(character),
                    flags: flags,
                    label: token
                )
            )
        } else {
            FileHandle.standardError.write(
                Data("unknown key token {\(token)}\n".utf8)
            )
        }
    }
    appendLiteral()
    return planned
}

// MARK: - Recording text view

private final class ProbeTextView: NSTextView {
    private(set) var markedHistory: [String] = []
    private(set) var insertHistory: [String] = []

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        markedHistory.append(Self.plainText(string))
        super.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        insertHistory.append(Self.plainText(string))
        super.insertText(string, replacementRange: replacementRange)
    }

    private static func plainText(_ value: Any) -> String {
        if let attributed = value as? NSAttributedString {
            return attributed.string
        }
        return value as? String ?? ""
    }
}

// MARK: - Probe run

private final class ProbeRunner: NSObject, NSApplicationDelegate {
    private let options: Options
    private var window: NSWindow!
    private var textView: ProbeTextView!
    private var lines: [String] = []

    init(options: Options) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let source = currentInputSourceIdentifier() else {
            record("RESULT=REFUSED")
            record("REASON=no current keyboard input source")
            finish(.failure)
        }
        record("current_source=\(source)")

        if options.probeOnly {
            record("RESULT=PASS")
            record("REASON=probe-only")
            finish(.success)
        }

        guard options.allowOtherSource
            || source.hasPrefix(options.requiredSourcePrefix)
        else {
            if options.waitForSource > 0 {
                record(
                    "waiting_for=\(options.requiredSourcePrefix) up_to=\(options.waitForSource)s"
                )
                waitForSource(
                    deadline: Date().addingTimeInterval(options.waitForSource)
                )
                return
            }
            record("RESULT=REFUSED")
            record(
                "REASON=current source \(source) is not \(options.requiredSourcePrefix)"
            )
            finish(.failure)
        }

        runProbe()
    }

    private func waitForSource(deadline: Date) {
        guard Date() < deadline else {
            record("RESULT=REFUSED")
            record("REASON=required input source never became current")
            finish(.failure)
        }
        if let source = currentInputSourceIdentifier(),
           source.hasPrefix(options.requiredSourcePrefix)
        {
            record("current_source=\(source)")
            runProbe()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.waitForSource(deadline: deadline)
        }
    }

    private func runProbe() {
        let frame = NSRect(x: 240, y: 240, width: 520, height: 240)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "KEYI native probe"
        textView = ProbeTextView(frame: frame)
        textView.isEditable = true
        textView.font = .monospacedSystemFont(ofSize: 18, weight: .regular)
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)

        waitForFocus(deadline: Date().addingTimeInterval(5)) {
            self.sendKeys()
        }
    }

    private var textInputContext: NSTextInputContext? {
        textView.inputContext
    }

    private var textInputContextIsActive: Bool {
        guard let context = textInputContext else { return false }
        return NSTextInputContext.current === context
    }

    private func waitForFocus(deadline: Date, completion: @escaping () -> Void) {
        if NSApp.isActive, window.isKeyWindow,
           window.firstResponder === textView
        {
            let contextActive = textInputContextIsActive
            record("focus=ready text_input_context_active=\(contextActive)")
            if contextActive {
                completion()
                return
            }
            // Focus alone is not enough: the text input context must be active
            // before the system will route keys through the active input
            // source. Typing into that gap inserts raw characters and looks
            // like an input method routing failure that is really a race.
            textInputContext?.activate()
        }
        guard Date() < deadline else {
            record("RESULT=REFUSED")
            record("REASON=text input context never became active")
            finish(.failure)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.waitForFocus(deadline: deadline, completion: completion)
        }
    }

    private func event(for key: PlannedKey, isDown: Bool) -> NSEvent? {
        NSEvent.keyEvent(
            with: isDown ? .keyDown : .keyUp,
            location: .zero,
            modifierFlags: key.flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: key.characters,
            charactersIgnoringModifiers: key.characters
                .folding(options: .diacriticInsensitive, locale: nil)
                .lowercased(),
            isARepeat: false,
            keyCode: key.keyCode
        )
    }

    private func sendKeys() {
        let planned = parseKeyScript(options.keyScript)
        guard !planned.isEmpty else {
            record("RESULT=FAIL")
            record("REASON=no sendable keys in script")
            finish(.failure)
        }
        record("keys=\(planned.map(\.label).joined())")
        let source = CGEventSource(stateID: .hidSystemState)
        for key in planned {
            for isDown in [true, false] {
                guard
                    let event = CGEvent(
                        keyboardEventSource: source,
                        virtualKey: key.keyCode,
                        keyDown: isDown
                    )
                else {
                    record("RESULT=FAIL")
                    record("REASON=could not create event for \(key.label)")
                    finish(.failure)
                }
                event.flags = CGEventFlags(rawValue: UInt64(key.flags.rawValue))
                event.post(tap: .cghidEventTap)
                usleep(25_000)
            }
            usleep(20_000)
        }
        record("posted_events=\(planned.count * 2)")
        DispatchQueue.main.asyncAfter(deadline: .now() + options.settleDelay) {
            self.report()
        }
    }

    private func report() {
        let document = textView.string
        record("marked=\(textView.markedHistory)")
        record("inserted=\(textView.insertHistory)")
        record("document=\(document.debugDescription)")

        var failures: [String] = []
        if !textView.markedHistory.contains(where: { !$0.isEmpty }) {
            failures.append("input method never set marked text")
        }
        if let expected = options.expected, !document.contains(expected) {
            failures.append("document does not contain \(expected.debugDescription)")
        }
        if failures.isEmpty {
            record("RESULT=PASS")
        } else {
            record("RESULT=FAIL")
            for failure in failures { record("REASON=\(failure)") }
        }
        finish(failures.isEmpty ? .success : .failure)
    }

    private enum Exit {
        case success
        case failure
    }

    private func record(_ line: String) {
        lines.append(line)
        print(line)
        fflush(stdout)
    }

    private func finish(_ outcome: Exit) -> Never {
        if let outputPath = options.outputPath {
            let text = lines.joined(separator: "\n") + "\n"
            try? text.write(
                toFile: outputPath,
                atomically: true,
                encoding: .utf8
            )
        }
        NSApp.terminate(nil)
        Darwin.exit(outcome == .success ? 0 : 1)
    }
}

private let options = parseOptions()
let application = NSApplication.shared
private let runner = ProbeRunner(options: options)
application.delegate = runner
application.setActivationPolicy(.regular)
application.run()
