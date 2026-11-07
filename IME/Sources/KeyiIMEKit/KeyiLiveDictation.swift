import AVFoundation
import Foundation
import KEYITranslationClient

/// 这次录音用哪个识别引擎（面板底栏写它的名字）；`notice` 是要提示一行的话（云端出错改用本机时）。
struct KeyiDictationEngineInfo: Equatable {
    var name: String
    var isCloud: Bool
    var notice: String?

    static let localName = "本机 SenseVoice"
}

/// 按住右 ⌥ 的一次录音（契约 2026-11-07）。麦克风一开就先问 KEYI 可译的翻译服务接不接云端识别
/// （本机 socket，平时几毫秒）：
/// - 接了（用户在 KEYI 可译里选了阿里云 Fun-ASR 且配好了 Key）：每 100 毫秒把新录的声音转成 16 位 PCM
///   经服务送去云端，云端回来的整段文字就是实时文字，松开后等云端定稿。Key 只在 KEYI 可译里。
/// - 没接（没选云端、没配好、KEYI 可译没运行或太旧）：用自带的 SenseVoice，说话中按已录的整段反复识别，
///   松开识别整段定稿。
/// - 云端中途出错：这次改用本机，已录的声音一点不丢，并提示一行原因。
/// 只在主线程用；云端事件先切回主线程再处理。
final class KeyiLiveDictationEngine: KeyiDictationEngine, @unchecked Sendable {
    /// 本机识别：说话中两次识别开始之间至少隔这么久；整段越长、识别越慢，间隔跟着拉长（上次用时的 2 倍）。
    /// 会话把每次给的整段一个字一个字流出来（`KeyiDictationReveal`），节奏按这个间隔估。
    static let liveInterval: TimeInterval = 0.45
    /// 等服务说接不接云端最多多久；过了就用本机。
    static let cloudDecisionTimeout: TimeInterval = 0.5
    /// 多久看一次（送云端的声音、该不该本机识别）。
    private static let tickInterval: TimeInterval = 0.05
    /// 云端一帧 100 毫秒。
    private static let cloudFrameSamples = Int(KeyiSenseVoice.sampleRate) / 10
    /// 本机识别：新录到不足 0.2 秒的声音不重新识别；不足 0.3 秒的录音不出实时文字。
    private static let minimumNewSamples = Int(KeyiSenseVoice.sampleRate) / 5
    private static let minimumSamples = Int(KeyiSenseVoice.sampleRate) * 3 / 10

    private enum Route {
        case deciding
        case cloud
        case local
    }

    private let audio: KeyiDictationAudioSource
    private let socketPath: String?
    private let checksMicrophonePermission: Bool
    private let recognizer = KeyiSenseVoice.shared
    private var route = Route.deciding
    private var stream: TranslationServiceSpeechStream?
    private var sentSamples = 0
    private var onText: ((String) -> Void)?
    private var onEngine: ((KeyiDictationEngineInfo) -> Void)?
    private var onFailure: ((KeyiDictationFailure) -> Void)?
    private var finishCompletion: ((String) -> Void)?
    private var timer: Timer?
    private var decoding = false
    private var decodedCount = 0
    private var nextLiveAt = Date.distantPast
    private var released = false
    private var cancelled = false

    /// `socketPath` 为 nil 时只用本机识别。诊断时换掉声音来源、服务地址，并跳过麦克风授权。
    init(
        audio: KeyiDictationAudioSource = KeyiMicrophone(),
        socketPath: String? = TranslationServiceSocketPath.defaultPath(),
        checksMicrophonePermission: Bool = true
    ) {
        self.audio = audio
        self.socketPath = socketPath
        self.checksMicrophonePermission = checksMicrophonePermission
    }

    func start(
        onText: @escaping (String) -> Void,
        onEngine: @escaping (KeyiDictationEngineInfo) -> Void,
        onFailure: @escaping (KeyiDictationFailure) -> Void
    ) {
        if checksMicrophonePermission {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                break
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    senseVoiceLogger.notice("microphone access granted=\(granted, privacy: .public)")
                }
                onFailure(.microphonePending)
                return
            default:
                onFailure(.microphoneDenied)
                return
            }
        }
        do {
            try audio.start()
        } catch {
            senseVoiceLogger.error("microphone did not start: \(error.localizedDescription, privacy: .public)")
            onFailure(.unavailable)
            return
        }
        senseVoiceLogger.notice("dictation started")
        self.onText = onText
        self.onEngine = onEngine
        self.onFailure = onFailure
        connectCloud()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func finish(_ completion: @escaping (String) -> Void) {
        stopAudio()
        switch route {
        case .cloud:
            finishCompletion = completion
            sendCloudAudio(all: true)
            stream?.finish()
        case .deciding:
            // 还没定用哪个：定了再收尾（云端会把全部声音一次送去）。
            finishCompletion = completion
        case .local:
            decodeLocally(completion)
        }
    }

    func cancel() {
        cancelled = true
        finishCompletion = nil
        stopAudio()
        dropStream()
    }

    // MARK: - 选路

    private func connectCloud() {
        guard let socketPath, FileManager.default.fileExists(atPath: socketPath) else {
            useLocal(reason: "no translation service", notice: nil)
            return
        }
        let id = UUID().uuidString
        let stream = TranslationServiceSpeechStream(
            socketPath: socketPath,
            sampleRate: Int(KeyiSenseVoice.sampleRate),
            id: id
        ) { [weak self] event in
            DispatchQueue.main.async { self?.handle(event, streamID: id) }
        }
        self.stream = stream
        stream.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cloudDecisionTimeout) { [weak self] in
            guard let self, !self.cancelled, self.stream?.id == id, self.route == .deciding else { return }
            self.dropStream()
            self.useLocal(reason: "service did not answer", notice: nil)
        }
    }

    private func handle(_ event: TranslationServiceSpeechStream.Event, streamID: String) {
        guard !cancelled, stream?.id == streamID else { return }
        switch event {
        case let .started(engine):
            guard route == .deciding else { return }
            route = .cloud
            senseVoiceLogger.notice("dictation route=cloud engine=\(engine, privacy: .public)")
            onEngine?(KeyiDictationEngineInfo(name: engine.isEmpty ? "云端识别" : engine, isCloud: true))
            if released {
                sendCloudAudio(all: true)
                stream?.finish()
            } else {
                sendCloudAudio(all: false)
            }
        case let .partial(text):
            guard route == .cloud else { return }
            onText?(text)
        case let .final(text):
            guard route == .cloud else { return }
            stream = nil
            if let completion = finishCompletion {
                finishCompletion = nil
                senseVoiceLogger.notice("dictation final route=cloud audio=\(Double(self.audio.count) / Double(KeyiSenseVoice.sampleRate), privacy: .public)")
                completion(text)
            } else {
                fallBackToLocal(notice: "云端识别提前结束了，这次改用本机识别")
            }
        case let .failed(code, message):
            stream = nil
            switch route {
            case .deciding:
                useLocal(reason: "cloud not used code=\(code.rawValue)", notice: nil)
            case .cloud:
                senseVoiceLogger.error("cloud dictation failed code=\(code.rawValue, privacy: .public)")
                let reason = message.isEmpty ? "云端识别出错了" : message
                fallBackToLocal(notice: "\(reason)，这次改用本机识别")
            case .local:
                break
            }
        }
    }

    private func useLocal(reason: String, notice: String?) {
        route = .local
        senseVoiceLogger.notice("dictation route=local reason=\(reason, privacy: .public)")
        onEngine?(KeyiDictationEngineInfo(name: KeyiDictationEngineInfo.localName, isCloud: false, notice: notice))
        // 第一次用时在后台加载模型；声音照录，加载好后整段一起识别。
        recognizer.prepare { [weak self] ready in
            guard let self, !ready, !self.cancelled else { return }
            let onFailure = self.onFailure
            self.cancel()
            onFailure?(.modelUnavailable)
        }
        nextLiveAt = .distantPast
        decodedCount = 0
        if released, let completion = finishCompletion {
            finishCompletion = nil
            decodeLocally(completion)
        }
    }

    private func fallBackToLocal(notice: String) {
        dropStream()
        useLocal(reason: "cloud failed", notice: notice)
    }

    private func dropStream() {
        stream?.cancel()
        stream = nil
    }

    private func stopAudio() {
        guard !released else { return }
        released = true
        timer?.invalidate()
        timer = nil
        audio.stop()
    }

    // MARK: - 说话中

    private func tick() {
        guard !released, !cancelled else { return }
        switch route {
        case .deciding:
            return
        case .cloud:
            sendCloudAudio(all: false)
        case .local:
            liveDecode()
        }
    }

    /// 把还没送的声音按 100 毫秒一帧送去；`all` 时连不满一帧的尾巴也送。
    private func sendCloudAudio(all: Bool) {
        guard let stream else { return }
        let fresh = audio.samples(from: sentSamples)
        let usable = all ? fresh.count : fresh.count / Self.cloudFrameSamples * Self.cloudFrameSamples
        guard usable > 0 else { return }
        var index = 0
        while index < usable {
            let end = min(index + Self.cloudFrameSamples, usable)
            stream.send(pcm16: Self.pcm16(fresh[index..<end]))
            index = end
        }
        sentSamples += usable
    }

    private func liveDecode() {
        guard !decoding, Date() >= nextLiveAt else { return }
        let samples = audio.snapshot()
        guard samples.count >= Self.minimumSamples, samples.count - decodedCount >= Self.minimumNewSamples else { return }
        decoding = true
        let began = Date()
        recognizer.transcribe(samples) { [weak self] text, seconds in
            guard let self else { return }
            self.decoding = false
            self.decodedCount = samples.count
            self.nextLiveAt = began.addingTimeInterval(max(Self.liveInterval, seconds * 2))
            guard !self.released, !self.cancelled, self.route == .local, let text else { return }
            self.onText?(text)
        }
    }

    private func decodeLocally(_ completion: @escaping (String) -> Void) {
        let samples = audio.snapshot()
        // 同一条串行队列：还在做的实时识别做完后，再识别整段。
        recognizer.transcribe(samples) { [weak self] text, seconds in
            guard let self, !self.cancelled else { return }
            senseVoiceLogger.notice("dictation final seconds=\(seconds, privacy: .public) audio=\(Double(samples.count) / Double(KeyiSenseVoice.sampleRate), privacy: .public)")
            completion(text ?? "")
        }
    }

    /// Float32 [-1, 1] → 16 位小端 PCM。
    static func pcm16(_ samples: ArraySlice<Float>) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        return data
    }
}
