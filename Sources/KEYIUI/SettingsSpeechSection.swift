import KEYICore
import SwiftUI

/// 设置「高级」的「语音输入」组：识别引擎；选云端时多出那一家的 API Key 一行，阿里云另有服务地址一行。
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
            SettingsRow(
                label: strings.speechEngineLabel,
                note: strings.speechEngineNote,
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
