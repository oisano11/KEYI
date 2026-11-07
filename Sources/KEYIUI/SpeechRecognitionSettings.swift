import Foundation
import KEYICore
import KEYITranslationService

// 语音识别设置（契约「2026-11-07 云端语音识别授权」及其补充）：选本机 SenseVoice（默认）、阿里云
// Fun-ASR 或豆包语音识别。阿里云要百炼 API Key（Keychain）和服务地址，豆包只要豆包语音控制台的
// API Key（Keychain，地址固定）。输入法不读这里：按住右 ⌥ 时它问翻译服务，服务子进程按这里的设置
// 决定接不接、用哪家哪把 Key（`KEYISpeechTranscriptionProvider`）。

public enum SpeechRecognitionEngine: String, CaseIterable, Sendable {
    /// 输入法自带的 SenseVoice，在本机识别。
    case local
    /// 阿里云百炼 Fun-ASR 实时识别。
    case aliyunFunASR
    /// 豆包（火山引擎）流式语音识别模型 2.0。
    case doubao

    var isCloud: Bool { self != .local }
}

/// UserDefaults 可以跨线程读写（系统文档如此），所以整体可以交给服务的线程用。
struct SpeechRecognitionSettings: @unchecked Sendable {
    static let engineKey = "speech.engine"
    static let endpointKey = "speech.aliyun.endpoint"
    static let aliyunAPIKeyAccount = "aliyun-asr.api-key"
    static let doubaoAPIKeyAccount = "doubao-asr.api-key"

    var defaults: UserDefaults = .standard
    /// 读 Keychain 里的 Key；本机检查换成替身。
    var readCredential: @Sendable (String) -> String? = { account in
        (try? CredentialStore.read(account: account)) ?? nil
    }
    /// 豆包的服务地址固定，不让用户填；只有本机检查会换。
    var doubaoEndpoint = DoubaoASRConfiguration.defaultEndpoint

    var engine: SpeechRecognitionEngine {
        defaults.string(forKey: Self.engineKey).flatMap(SpeechRecognitionEngine.init(rawValue:)) ?? .local
    }

    func setEngine(_ engine: SpeechRecognitionEngine) {
        defaults.set(engine.rawValue, forKey: Self.engineKey)
    }

    /// 阿里云：用户改过的服务地址；没改过是北京地域。
    var endpoint: String {
        let stored = defaults.string(forKey: Self.endpointKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? AliyunFunASRConfiguration.defaultEndpoint : stored
    }

    func setEndpoint(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == AliyunFunASRConfiguration.defaultEndpoint {
            defaults.removeObject(forKey: Self.endpointKey)
            return
        }
        guard AliyunFunASRConfiguration.endpointURL(trimmed) != nil else {
            throw SpeechRecognitionSettingsError.invalidEndpoint
        }
        defaults.set(trimmed, forKey: Self.endpointKey)
    }

    static func apiKeyAccount(for engine: SpeechRecognitionEngine) -> String? {
        switch engine {
        case .local: nil
        case .aliyunFunASR: aliyunAPIKeyAccount
        case .doubao: doubaoAPIKeyAccount
        }
    }

    func hasAPIKey(for engine: SpeechRecognitionEngine) -> Bool {
        guard let account = Self.apiKeyAccount(for: engine) else { return false }
        return readCredential(account)?.isEmpty == false
    }

    func saveAPIKey(_ key: String, for engine: SpeechRecognitionEngine) throws {
        guard let account = Self.apiKeyAccount(for: engine) else { return }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpeechRecognitionSettingsError.emptyKey }
        try CredentialStore.save(trimmed, account: account)
    }

    /// Key、地址都在时给出阿里云的连接配置；否则 nil。
    func aliyunConfiguration(apiKey override: String? = nil) -> AliyunFunASRConfiguration? {
        guard let url = AliyunFunASRConfiguration.endpointURL(endpoint) else { return nil }
        let key = override ?? readCredential(Self.aliyunAPIKeyAccount)
        guard let key, !key.isEmpty else { return nil }
        return AliyunFunASRConfiguration(apiKey: key, endpoint: url)
    }

    /// Key 在时给出豆包的连接配置；否则 nil。
    func doubaoConfiguration(apiKey override: String? = nil) -> DoubaoASRConfiguration? {
        guard let url = URL(string: doubaoEndpoint) else { return nil }
        let key = override ?? readCredential(Self.doubaoAPIKeyAccount)
        guard let key, !key.isEmpty else { return nil }
        return DoubaoASRConfiguration(apiKey: key, endpoint: url)
    }
}

enum SpeechRecognitionSettingsError: LocalizedError {
    case emptyKey
    case invalidEndpoint

    var errorDescription: String? {
        switch self {
        case .emptyKey: "API Key 是空的"
        case .invalidEndpoint: "服务地址要以 wss:// 开头"
        }
    }
}

// MARK: - 服务子进程里的云端识别

/// 翻译服务收到 `transcribe` 时调用：每次现读设置与 Keychain，设置改了下一段就生效。
public struct KEYISpeechTranscriptionProvider: SpeechTranscriptionProviding {
    let settings: SpeechRecognitionSettings

    public init() {
        settings = SpeechRecognitionSettings()
    }

    init(settings: SpeechRecognitionSettings) {
        self.settings = settings
    }

    public func startTranscription(
        sampleRate: Int,
        events: @escaping @Sendable (SpeechTranscriptionEvent) -> Void
    ) throws -> any SpeechTranscriptionSession {
        let session: CloudSpeechSession
        switch settings.engine {
        case .local:
            throw TranslationServiceResolutionError.notConfigured("语音识别用的是本机")
        case .aliyunFunASR:
            guard let configuration = settings.aliyunConfiguration() else {
                throw TranslationServiceResolutionError.notConfigured("还没填阿里云的 API Key")
            }
            session = .aliyun(configuration, sampleRate: sampleRate, events: events)
        case .doubao:
            guard let configuration = settings.doubaoConfiguration() else {
                throw TranslationServiceResolutionError.notConfigured("还没填豆包的 API Key")
            }
            session = .doubao(configuration, sampleRate: sampleRate, events: events)
        }
        session.start()
        return session
    }
}

/// 一段云端识别：把各家的流包成服务要的会话。Key 被拒算没配好，其余算服务出错，输入法都改用本机。
private final class CloudSpeechSession: SpeechTranscriptionSession, @unchecked Sendable {
    let engineName: String
    private let startStream: () -> Void
    private let appendAudio: (Data) -> Void
    private let finishStream: () -> Void
    private let cancelStream: () -> Void

    private init(
        engineName: String,
        start: @escaping () -> Void,
        append: @escaping (Data) -> Void,
        finish: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) {
        self.engineName = engineName
        startStream = start
        appendAudio = append
        finishStream = finish
        cancelStream = cancel
    }

    func start() { startStream() }
    func append(_ pcm16: Data) { appendAudio(pcm16) }
    func finish() { finishStream() }
    func cancel() { cancelStream() }

    static func aliyun(
        _ configuration: AliyunFunASRConfiguration,
        sampleRate: Int,
        events: @escaping @Sendable (SpeechTranscriptionEvent) -> Void
    ) -> CloudSpeechSession {
        let stream = AliyunFunASRStream(configuration: configuration, sampleRate: sampleRate) { event in
            switch event {
            case .started: break
            case let .partial(text): events(.partial(text))
            case let .final(text): events(.final(text))
            case let .failed(failure):
                events(.failed(failure == .unauthorized ? .notConfigured(failure.message) : .providerFailure(failure.message)))
            }
        }
        return CloudSpeechSession(
            engineName: AliyunFunASRConfiguration.displayName,
            start: stream.start, append: stream.append, finish: stream.finish, cancel: stream.cancel
        )
    }

    static func doubao(
        _ configuration: DoubaoASRConfiguration,
        sampleRate: Int,
        events: @escaping @Sendable (SpeechTranscriptionEvent) -> Void
    ) -> CloudSpeechSession {
        let stream = DoubaoASRStream(configuration: configuration, sampleRate: sampleRate) { event in
            switch event {
            case .started: break
            case let .partial(text): events(.partial(text))
            case let .final(text): events(.final(text))
            case let .failed(failure):
                events(.failed(failure == .unauthorized ? .notConfigured(failure.message) : .providerFailure(failure.message)))
            }
        }
        return CloudSpeechSession(
            engineName: DoubaoASRConfiguration.displayName,
            start: stream.start, append: stream.append, finish: stream.finish, cancel: stream.cancel
        )
    }
}

// MARK: - 设置窗口

/// 设置「高级」里「语音输入」一组的状态。
@MainActor
final class SpeechSettingsModel: ObservableObject {
    static let shared = SpeechSettingsModel()

    enum Status: Equatable {
        case none
        case checking
        case ready(String)
        case failed(String)
    }

    @Published private(set) var engine: SpeechRecognitionEngine
    /// 当前所选那一家的 Key 存了没有。
    @Published private(set) var hasAPIKey: Bool
    @Published private(set) var endpoint: String
    @Published var status: Status = .none

    private var settings: SpeechRecognitionSettings

    init(settings: SpeechRecognitionSettings = SpeechRecognitionSettings()) {
        self.settings = settings
        engine = settings.engine
        hasAPIKey = settings.hasAPIKey(for: settings.engine)
        endpoint = settings.endpoint
    }

    func select(_ engine: SpeechRecognitionEngine) {
        settings.setEngine(engine)
        self.engine = engine
        hasAPIKey = settings.hasAPIKey(for: engine)
        status = .none
    }

    /// 存当前所选那一家的 Key（阿里云还有改过的地址；`endpoint` 为 nil 不动地址），再连一次看能不能用。
    func save(apiKey: String, endpoint endpointText: String?, strings: InterfaceStrings) {
        do {
            if engine == .aliyunFunASR, let endpointText {
                // 地址留空就是默认（北京）。
                try settings.setEndpoint(endpointText)
            }
            if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try settings.saveAPIKey(apiKey, for: engine)
            }
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        hasAPIKey = settings.hasAPIKey(for: engine)
        endpoint = settings.endpoint
        verify(strings: strings)
    }

    func verify(strings: InterfaceStrings) {
        switch engine {
        case .local:
            status = .none
        case .aliyunFunASR:
            guard let configuration = settings.aliyunConfiguration() else {
                status = .failed(strings.speechKeyMissing)
                return
            }
            check(ready: strings.speechReady) { await AliyunFunASRStream.verify(configuration)?.message }
        case .doubao:
            guard let configuration = settings.doubaoConfiguration() else {
                status = .failed(strings.speechKeyMissing)
                return
            }
            check(ready: strings.speechReady) { await DoubaoASRStream.verify(configuration)?.message }
        }
    }

    /// `attempt` 返回失败原因，nil 表示能用。
    private func check(ready: String, _ attempt: @escaping @Sendable () async -> String?) {
        status = .checking
        Task { [weak self] in
            let failure = await attempt()
            await MainActor.run {
                guard let self else { return }
                self.status = failure.map { .failed($0) } ?? .ready(ready)
            }
        }
    }
}

extension InterfaceStrings {
    var speechSection: String { isEnglish ? "Voice input" : "语音输入" }
    var speechEngineLabel: String { isEnglish ? "Recognition" : "语音识别" }
    var speechEngineNote: String { isEnglish ? "hold right ⌥ to talk" : "按住右 ⌥ 说话" }
    var speechEngineDetail: String {
        isEnglish
            ? "Local SenseVoice runs on this Mac and never sends audio out. Aliyun Fun-ASR and Doubao recognize in the cloud and are more accurate on mixed Chinese and English; while you hold right ⌥ the audio goes to the one you pick, billed by duration (Aliyun about ¥1.2/hour; Doubao gives 20 free trial hours, then about ¥1/hour)."
            : "本机 SenseVoice 在这台 Mac 上识别，声音不出本机。阿里云 Fun-ASR 和豆包语音识别在云端识别，中英混说更准；按住右 ⌥ 期间的声音发给所选的那一家，按时长计费（阿里云约 1.2 元/小时；豆包新开通送 20 小时试用，之后约 1 元/小时）。"
    }
    func speechEngineName(_ engine: SpeechRecognitionEngine) -> String {
        switch engine {
        case .local: isEnglish ? "Local SenseVoice" : "本机 SenseVoice"
        case .aliyunFunASR: isEnglish ? "Aliyun Fun-ASR" : AliyunFunASRConfiguration.displayName
        case .doubao: isEnglish ? "Doubao ASR" : DoubaoASRConfiguration.displayName
        }
    }
    func speechAPIKeyLabel(_ engine: SpeechRecognitionEngine) -> String {
        switch engine {
        case .doubao: isEnglish ? "Doubao API Key" : "豆包 API Key"
        case .local, .aliyunFunASR: isEnglish ? "Bailian API Key" : "百炼 API Key"
        }
    }
    func speechAPIKeyDetail(_ engine: SpeechRecognitionEngine) -> String {
        switch engine {
        case .doubao:
            isEnglish
                ? "In the Doubao Voice console (console.volcengine.com/speech/new), turn on Streaming ASR 2.0 and click Trial, then copy a key from API Key management. The 20 trial hours last half a year; switching to the paid plan voids what is left of the trial."
                : "在豆包语音控制台（console.volcengine.com/speech/new）开通「流式语音识别 2.0」并点「试用」，再到「API Key 管理」复制 Key。试用 20 小时、半年内有效；开通正式版后剩下的试用额度会作废。"
        case .local, .aliyunFunASR:
            isEnglish
                ? "Create one in the Aliyun Bailian (Model Studio) console; it is the same kind of key as Qwen."
                : "在阿里云百炼控制台创建，和通义千问是同一种 Key。"
        }
    }
    var speechEndpointLabel: String { isEnglish ? "Endpoint" : "服务地址" }
    var speechEndpointDetail: String {
        isEnglish
            ? "Beijing by default. For a Singapore key use wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference"
            : "默认北京地域。新加坡地域的 Key 改成 wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference"
    }
    func speechChecking(_ engine: SpeechRecognitionEngine) -> String {
        switch engine {
        case .doubao: isEnglish ? "Checking with Doubao…" : "正在连豆包验证…"
        case .local, .aliyunFunASR: isEnglish ? "Checking with Aliyun…" : "正在连阿里云验证…"
        }
    }
    var speechReady: String { isEnglish ? "Ready. Hold right ⌥ to talk." : "可以用了，按住右 ⌥ 说话" }
    var speechKeyMissing: String { isEnglish ? "Fill in the API Key first" : "先填 API Key" }
    var speechCheckAgain: String { isEnglish ? "Check" : "验证" }
}
