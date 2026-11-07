import AVFoundation
import CSherpaOnnx
import Darwin
import OSLog

// 语音输入的本地识别：阿里 FunAudioLLM 的 SenseVoice-Small（int8，普通话与中英混说），经 sherpa-onnx
// 在本机运行（契约「2026-11-07 语音输入最小版授权」补充）。运行库和模型都随 KEYIIME 打包：
// Contents/Frameworks/libsherpa-onnx-c-api.dylib（及 libonnxruntime.dylib）、
// Contents/Resources/SenseVoice/{model.int8.onnx,tokens.txt}。输入法运行时不联网、不下载。
//
// SenseVoice 不是流式模型：说话中按已说的整段反复识别（约每半秒，整段越长间隔越长），
// 松开后再识别一次整段作为定稿。10 秒的话识别一次约 0.1 秒。

let senseVoiceLogger = Logger(subsystem: "com.keyi.inputmethod.keyi", category: "Dictation")

/// sherpa-onnx 的离线识别器。第一次用时在后台加载（运行库 dlopen + 约 230 MB 模型），之后常驻；
/// 闲置 10 分钟卸载模型，释放内存。所有识别都在同一条串行队列上，先来的先做完。
final class KeyiSenseVoice: @unchecked Sendable {
    static let shared = KeyiSenseVoice()
    static let sampleRate: Int32 = 16000
    static let idleUnloadSeconds: TimeInterval = 600

    /// 只用到的 8 个 C 函数（签名照 Vendor/sherpa-onnx 里固定版本的 c-api.h）。
    private struct API {
        typealias CreateType = @convention(c) (UnsafePointer<SherpaOnnxOfflineRecognizerConfig>?) -> OpaquePointer?
        typealias PointerType = @convention(c) (OpaquePointer?) -> Void
        typealias StreamType = @convention(c) (OpaquePointer?) -> OpaquePointer?
        typealias AcceptType = @convention(c) (OpaquePointer?, Int32, UnsafePointer<Float>?, Int32) -> Void
        typealias DecodeType = @convention(c) (OpaquePointer?, OpaquePointer?) -> Void
        typealias ResultType = @convention(c) (OpaquePointer?) -> UnsafePointer<SherpaOnnxOfflineRecognizerResult>?
        typealias DestroyResultType = @convention(c) (UnsafePointer<SherpaOnnxOfflineRecognizerResult>?) -> Void

        let create: CreateType
        let destroy: PointerType
        let createStream: StreamType
        let destroyStream: PointerType
        let acceptWaveform: AcceptType
        let decode: DecodeType
        let result: ResultType
        let destroyResult: DestroyResultType
    }

    private let queue = DispatchQueue(label: "com.keyi.inputmethod.keyi.sensevoice", qos: .userInitiated)
    private var api: API?
    private var recognizer: OpaquePointer?
    private var unloadGeneration = 0

    /// 后台加载（已加载就什么都不做），完成后在主线程回报能不能用。
    func prepare(_ completion: @escaping (Bool) -> Void) {
        queue.async {
            let ready = self.loadLocked()
            DispatchQueue.main.async { completion(ready) }
        }
    }

    /// 识别一段 16 kHz 单声道音频。`text` 为 nil 表示识别器没能加载；`seconds` 是这次识别本身用的时间。
    func transcribe(_ samples: [Float], completion: @escaping (_ text: String?, _ seconds: TimeInterval) -> Void) {
        queue.async {
            let started = Date()
            let text = self.decodeLocked(samples)
            let seconds = Date().timeIntervalSince(started)
            self.scheduleUnloadLocked()
            DispatchQueue.main.async { completion(text, seconds) }
        }
    }

    private func loadLocked() -> Bool {
        if recognizer != nil { return true }
        guard let frameworks = Bundle.main.privateFrameworksURL,
              let resources = Bundle.main.resourceURL
        else { return false }
        let library = frameworks.appendingPathComponent("libsherpa-onnx-c-api.dylib").path
        let model = resources.appendingPathComponent("SenseVoice/model.int8.onnx").path
        let tokens = resources.appendingPathComponent("SenseVoice/tokens.txt").path
        guard FileManager.default.fileExists(atPath: model), FileManager.default.fileExists(atPath: tokens) else {
            senseVoiceLogger.error("SenseVoice model files are missing from the bundle")
            return false
        }
        if api == nil {
            guard let handle = dlopen(library, RTLD_NOW | RTLD_LOCAL) else {
                let reason = dlerror().map { String(cString: $0) } ?? "?"
                senseVoiceLogger.error("sherpa-onnx did not load: \(reason, privacy: .public)")
                return false
            }
            func symbol<T>(_ name: String, _: T.Type) -> T? {
                dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
            }
            guard let create = symbol("SherpaOnnxCreateOfflineRecognizer", API.CreateType.self),
                  let destroy = symbol("SherpaOnnxDestroyOfflineRecognizer", API.PointerType.self),
                  let createStream = symbol("SherpaOnnxCreateOfflineStream", API.StreamType.self),
                  let destroyStream = symbol("SherpaOnnxDestroyOfflineStream", API.PointerType.self),
                  let acceptWaveform = symbol("SherpaOnnxAcceptWaveformOffline", API.AcceptType.self),
                  let decode = symbol("SherpaOnnxDecodeOfflineStream", API.DecodeType.self),
                  let result = symbol("SherpaOnnxGetOfflineStreamResult", API.ResultType.self),
                  let destroyResult = symbol("SherpaOnnxDestroyOfflineRecognizerResult", API.DestroyResultType.self)
            else {
                senseVoiceLogger.error("sherpa-onnx is missing an expected symbol")
                return false
            }
            api = API(
                create: create, destroy: destroy, createStream: createStream, destroyStream: destroyStream,
                acceptWaveform: acceptWaveform, decode: decode, result: result, destroyResult: destroyResult
            )
        }
        guard let api else { return false }
        let started = Date()
        // 配置里的字符串只在创建时读（库内部拷走），创建完就释放。
        let strings = [model, tokens, "auto", "cpu", "greedy_search"].map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = Self.sampleRate
        config.feat_config.feature_dim = 80
        config.model_config.sense_voice.model = UnsafePointer(strings[0])
        config.model_config.tokens = UnsafePointer(strings[1])
        config.model_config.sense_voice.language = UnsafePointer(strings[2])
        config.model_config.sense_voice.use_itn = 1
        config.model_config.provider = UnsafePointer(strings[3])
        config.model_config.num_threads = 4
        config.model_config.debug = 0
        config.decoding_method = UnsafePointer(strings[4])
        recognizer = withUnsafePointer(to: &config) { api.create($0) }
        guard recognizer != nil else {
            senseVoiceLogger.error("SenseVoice recognizer was not created")
            return false
        }
        senseVoiceLogger.notice("SenseVoice loaded seconds=\(Date().timeIntervalSince(started), privacy: .public)")
        return true
    }

    private func decodeLocked(_ samples: [Float]) -> String? {
        guard loadLocked(), let api, let recognizer else { return nil }
        guard !samples.isEmpty, let stream = api.createStream(recognizer) else { return "" }
        defer { api.destroyStream(stream) }
        samples.withUnsafeBufferPointer { buffer in
            api.acceptWaveform(stream, Self.sampleRate, buffer.baseAddress, Int32(buffer.count))
        }
        api.decode(recognizer, stream)
        guard let result = api.result(stream) else { return "" }
        defer { api.destroyResult(result) }
        return result.pointee.text.map { String(cString: $0) } ?? ""
    }

    private func scheduleUnloadLocked() {
        unloadGeneration &+= 1
        let generation = unloadGeneration
        queue.asyncAfter(deadline: .now() + Self.idleUnloadSeconds) {
            guard generation == self.unloadGeneration, let recognizer = self.recognizer, let api = self.api else { return }
            api.destroy(recognizer)
            self.recognizer = nil
            senseVoiceLogger.notice("SenseVoice unloaded after being idle")
        }
    }
}

// MARK: - 麦克风

/// 一次录音的声音来源：麦克风，或诊断用的文件（按真实时间一点点给出）。
protocol KeyiDictationAudioSource: AnyObject {
    func start() throws
    func stop()
    /// 到此刻录到的样本数。
    var count: Int { get }
    /// 到此刻录到的全部样本（16 kHz 单声道 Float32）。
    func snapshot() -> [Float]
    /// 从第 `index` 个样本起到此刻的部分。
    func samples(from index: Int) -> [Float]
}

/// 麦克风 → 16 kHz 单声道 Float32，只存在内存里（最长约 130 秒），不写盘。
final class KeyiMicrophone: KeyiDictationAudioSource, @unchecked Sendable {
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(KeyiSenseVoice.sampleRate),
        channels: 1,
        interleaved: false
    )!
    private static let maximumSamples = Int(KeyiSenseVoice.sampleRate) * 130

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var running = false

    func start() throws {
        let input = engine.inputNode
        let natural = input.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, natural.channelCount > 0,
              let converter = AVAudioConverter(from: natural, to: Self.format)
        else { throw KeyiMicrophoneError.noFormat }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 1024, format: natural) { [weak self] buffer, _ in
            self?.receive(buffer)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    func samples(from index: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard index < samples.count else { return [] }
        return Array(samples[max(index, 0)...])
    }

    private func receive(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let floats = Self.convert(buffer, with: converter) else { return }
        lock.lock()
        defer { lock.unlock() }
        let room = Self.maximumSamples - samples.count
        guard room > 0 else { return }
        samples.append(contentsOf: floats.prefix(room))
    }

    /// 读一个音频文件（诊断用），转成同样的 16 kHz 单声道。
    static func samples(fromFile url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw KeyiMicrophoneError.noFormat
        }
        var result: [Float] = []
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
            try file.read(into: buffer, frameCount: 4096)
            if buffer.frameLength == 0 { break }
            if let floats = convert(buffer, with: converter) { result.append(contentsOf: floats) }
        }
        return result
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Float]? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

enum KeyiMicrophoneError: Error {
    case noFormat
}
