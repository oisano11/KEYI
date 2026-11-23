import AppKit
import Carbon.HIToolbox
import KEYICore
import KEYITranslationClient
import SwiftUI

/// 设置「高级」的「语音输入」组：说话键、识别引擎；选云端时多出那一家的 API Key 一行，阿里云另有服务地址一行。
/// 保存 Key 时连一次验证（只确认 Key 能用就断开，不送音频）。
struct SpeechServiceRows: View {
    @ObservedObject var model: AppModel
    @ObservedObject var speech: SpeechSettingsModel = .shared
    @State private var apiKey = ""
    @State private var replacingAPIKey = false
    @State private var endpointText = ""

    var body: some View {
        let strings = model.strings
        VStack(alignment: .leading, spacing: 0) {
            DictationKeyRow(model: model, speech: speech)
            SettingsDivider()
            SettingsRow(
                label: strings.speechEngineLabel,
                help: strings.speechEngineDetail
            ) {
                Picker(
                    strings.speechEngineLabel,
                    selection: Binding(get: { speech.engine }, set: { select($0) })
                ) {
                    ForEach(SpeechRecognitionEngine.allCases, id: \.self) { engine in
                        Text(strings.speechEngineName(engine)).tag(engine)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if speech.engine.isCloud {
                SettingsDivider()
                apiKeyRow(strings)
            }
            if speech.engine == .aliyunFunASR {
                SettingsDivider()
                SettingsRow(label: strings.speechEndpointLabel, help: strings.speechEndpointDetail) {
                    HStack(spacing: 8) {
                        TextField(
                            strings.speechEndpointLabel,
                            text: $endpointText,
                            prompt: Text(AliyunFunASRConfiguration.defaultEndpoint)
                        )
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 300)
                        .onSubmit { saveEndpoint(strings) }
                        if endpointChanged {
                            Button(strings.save) { saveEndpoint(strings) }
                        }
                    }
                }
            }
        }
        .onAppear { endpointText = speech.endpoint }
    }

    @ViewBuilder
    private func apiKeyRow(_ strings: InterfaceStrings) -> some View {
        let editing = !speech.hasAPIKey || replacingAPIKey
        SettingsRow(
            label: strings.speechAPIKeyLabel(speech.engine),
            detail: statusText(strings),
            detailColor: statusIsError ? KEYIPalette.danger : KEYIPalette.ink2,
            help: strings.speechAPIKeyDetail(speech.engine)
        ) {
            HStack(spacing: 8) {
                if editing {
                    SecureField(strings.apiKey, text: $apiKey, prompt: Text(strings.pasteAPIKey))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onSubmit { saveKey(strings) }
                    if replacingAPIKey {
                        Button(strings.cancel) {
                            apiKey = ""
                            replacingAPIKey = false
                        }
                    }
                    Button(strings.save) { saveKey(strings) }
                        .buttonStyle(.borderedProminent)
                        .tint(KEYIPalette.cloud)
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Label(strings.savedAPIKeyMasked, systemImage: "key.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(KEYIPalette.ink2)
                    Button(strings.speechCheckAgain) { speech.verify(strings: strings) }
                        .disabled(speech.status == .checking)
                    Button(strings.replaceAPIKey) { replacingAPIKey = true }
                }
            }
        }
    }

    private var endpointChanged: Bool {
        let trimmed = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? AliyunFunASRConfiguration.defaultEndpoint : trimmed) != speech.endpoint
    }

    private var statusIsError: Bool {
        if case .failed = speech.status { return true }
        return false
    }

    private func statusText(_ strings: InterfaceStrings) -> String? {
        switch speech.status {
        case .none: nil
        case .checking: strings.speechChecking(speech.engine)
        case let .ready(text), let .failed(text): text
        }
    }

    /// 换一家时，没存的 Key 输入框清空。
    private func select(_ engine: SpeechRecognitionEngine) {
        apiKey = ""
        replacingAPIKey = false
        speech.select(engine)
    }

    private func saveKey(_ strings: InterfaceStrings) {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        speech.save(
            apiKey: apiKey,
            endpoint: speech.engine == .aliyunFunASR ? endpointText : nil,
            strings: strings
        )
        if !statusIsError {
            apiKey = ""
            replacingAPIKey = false
        }
    }

    private func saveEndpoint(_ strings: InterfaceStrings) {
        speech.save(apiKey: "", endpoint: endpointText, strings: strings)
        if !statusIsError { endpointText = speech.endpoint }
    }
}

/// 说话键一行（契约 2026-11-08）：点按钮后按想用的键——单个修饰键按下又松开、或带修饰键的一个键——
/// 当场检查能不能用，能用就存下，输入法收到通知马上换上；不能用就说明原因、接着等。Esc 取消。
struct DictationKeyRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var speech: SpeechSettingsModel
    @State private var recording = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var capture = DictationKeyCapture()

    var body: some View {
        let strings = model.strings
        let current = speech.dictationShortcut
        SettingsRow(
            label: strings.speechKeyLabel,
            note: recording ? strings.speechKeyRecordingNote : strings.speechKeyNote,
            detail: message,
            detailColor: messageIsError ? KEYIPalette.danger : KEYIPalette.ink2,
            help: strings.speechKeyDetail
        ) {
            HStack(spacing: 8) {
                Button {
                    recording ? stop() : start(strings)
                } label: {
                    Text(recording ? strings.speechKeyRecording : strings.speechKeyName(current))
                        .font(.system(size: 12.5, weight: .medium))
                        .monospacedDigit()
                        .frame(minWidth: 72)
                }
                .buttonStyle(.bordered)
                .tint(recording ? KEYIPalette.controlTint : nil)
                .accessibilityLabel(strings.speechKeyLabel)
                .accessibilityValue(strings.speechKeyName(current))
                if !recording, current != .standard {
                    Button(strings.speechKeyReset(.standard)) {
                        apply(.standard, strings)
                    }
                }
            }
        }
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            // 切到别处就不再录，免得之后按的键被这里吞掉。
            if recording { stop() }
        }
    }

    private func start(_ strings: InterfaceStrings) {
        message = nil
        recording = true
        capture.start(
            onCapture: { shortcut in apply(shortcut, strings) },
            onCancel: { stop() }
        )
    }

    private func stop() {
        capture.stop()
        recording = false
    }

    /// 检查并存下。不能用时提示原因，录键继续。
    private func apply(_ shortcut: KEYIDictationShortcut, _ strings: InterfaceStrings) {
        if let problem = shortcut.problem {
            message = strings.speechKeyProblem(problem, key: shortcut)
            messageIsError = true
            return
        }
        if Self.isDesktopHotKey(shortcut, model.hotKeyConfiguration) {
            message = strings.speechKeyTakenByHotKey(shortcut)
            messageIsError = true
            return
        }
        stop()
        let changed = shortcut != speech.dictationShortcut
        guard speech.setDictationShortcut(shortcut) else { return }
        message = changed ? strings.speechKeySaved(shortcut) : nil
        messageIsError = false
    }

    /// 和 KEYI 可译自己的全局翻译快捷键一样：那个键被系统先拿走，输入法收不到。
    nonisolated static func isDesktopHotKey(_ shortcut: KEYIDictationShortcut, _ hotKey: HotKeyConfiguration) -> Bool {
        guard !shortcut.isModifierKey, UInt32(shortcut.keyCode) == hotKey.keyCode else { return false }
        var carbon: UInt32 = 0
        if shortcut.modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if shortcut.modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if shortcut.modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        if shortcut.modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon == hotKey.modifiers
    }
}

/// 录说话键时临时接管本应用的按键（本地事件监视），录完或取消就撤掉；录的时候按的键都不往下传。
/// 单个修饰键：按下时只按着它这一个，松开时什么都没按着，才算选了它；中途按了别的键就是组合键。
@MainActor
final class DictationKeyCapture {
    private var monitor: Any?
    private var pendingModifier: UInt16?
    private var onCapture: (KEYIDictationShortcut) -> Void = { _ in }
    private var onCancel: () -> Void = {}

    func start(onCapture: @escaping (KEYIDictationShortcut) -> Void, onCancel: @escaping () -> Void) {
        stop()
        self.onCapture = onCapture
        self.onCancel = onCancel
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pendingModifier = nil
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            let code = event.keyCode
            guard KEYIDictationShortcut.isModifierKeyCode(code) else {
                // Caps Lock 之类：交给检查说明不能用。
                pendingModifier = nil
                onCapture(KEYIDictationShortcut(keyCode: code))
                return
            }
            let candidate = KEYIDictationShortcut(keyCode: code)
            let held = event.modifierFlags.intersection(KEYIDictationShortcut.trackedModifiers)
            if candidate.modifierKeyIsDown(keyCode: code, rawFlags: event.modifierFlags.rawValue) == true {
                pendingModifier = pendingModifier == nil && held == candidate.heldModifiersToStart ? code : nil
            } else if pendingModifier == code, held.isEmpty {
                pendingModifier = nil
                onCapture(candidate)
            } else if held.isEmpty {
                pendingModifier = nil
            }
        case .keyDown:
            pendingModifier = nil
            guard !event.isARepeat else { return }
            let modifiers = event.modifierFlags.intersection(KEYIDictationShortcut.comboModifiers)
            if event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
                onCancel()
                return
            }
            onCapture(KEYIDictationShortcut(
                keyCode: event.keyCode,
                modifiers: modifiers,
                keyLabel: event.charactersIgnoringModifiers ?? ""
            ))
        default:
            break
        }
    }
}
