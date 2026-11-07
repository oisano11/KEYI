import Darwin
import Foundation
import KEYITranslationClient

// `KEYIIME --diagnose-cloud-dictation <音频> <应含文字>`：一次录音怎么选云端或本机。声音来自文件
// （按 8 倍速一点点给出，替掉麦克风），翻译服务换成临时 socket 上的替身。四种情况：
// 接下云端、没配好用本机、云端中途出错改用本机、没有服务用本机。

/// 诊断用的声音来源：按真实时间（可加速）一点点给出文件里的样本。
final class KeyiFileAudioSource: KeyiDictationAudioSource {
    private let all: [Float]
    private let speed: Double
    private var startedAt: Date?
    private var stoppedCount: Int?

    init(samples: [Float], speed: Double) {
        all = samples
        self.speed = speed
    }

    var isDrained: Bool { count >= all.count }

    func start() throws { startedAt = Date() }

    func stop() { stoppedCount = count }

    var count: Int {
        if let stoppedCount { return stoppedCount }
        guard let startedAt else { return 0 }
        let elapsed = Date().timeIntervalSince(startedAt) * speed
        return min(all.count, Int(elapsed * Double(KeyiSenseVoice.sampleRate)))
    }

    func snapshot() -> [Float] { Array(all.prefix(count)) }

    func samples(from index: Int) -> [Float] {
        let end = count
        guard index < end else { return [] }
        return Array(all[max(index, 0)..<end])
    }
}

/// 临时 socket 上的翻译服务替身，只会语音识别那几条消息。
private final class KeyiFakeSpeechService: @unchecked Sendable {
    enum Mode {
        case accept
        case reject
        case failOnFinish
    }

    let path: String
    private let mode: Mode
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var bytes = 0
    private var finished = false

    init(path: String, mode: Mode) throws {
        self.path = path
        self.mode = mode
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw KeyiMicrophoneError.noFormat }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in pathBytes.enumerated() where index < raw.count - 1 { raw[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            close(descriptor)
            throw KeyiMicrophoneError.noFormat
        }
        listener = descriptor
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    var audioBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    var gotFinish: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    func stop() {
        let descriptor = listener
        listener = -1
        if descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }
        unlink(path)
    }

    private func acceptLoop() {
        while true {
            let listening = listener
            guard listening >= 0 else { return }
            let connection = accept(listening, nil, nil)
            guard connection >= 0 else { return }
            var on: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [self] in serve(connection) }
        }
    }

    private func serve(_ connection: Int32) {
        defer { close(connection) }
        var buffer = Data()
        var frames = 0
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            while let range = buffer.range(of: Data([0x0A])) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex...range.lowerBound)
                guard let message = try? TranslationServiceWireCodec.decode(line) else { continue }
                switch message.type {
                case .transcribe:
                    if mode == .reject {
                        write(.init(type: .error, id: message.id, code: .notConfigured, message: "语音识别用的是本机"), to: connection)
                        return
                    }
                    write(.init(type: .transcriptStarted, id: message.id, message: "测试云端"), to: connection)
                case .audio:
                    let count = Data(base64Encoded: message.audio ?? "")?.count ?? 0
                    lock.lock()
                    bytes += count
                    lock.unlock()
                    frames += 1
                    if frames == 3 {
                        write(.init(type: .transcript, id: message.id, text: "云端在听"), to: connection)
                    }
                case .finishAudio:
                    lock.lock()
                    finished = true
                    lock.unlock()
                    if mode == .failOnFinish {
                        write(.init(type: .error, id: message.id, code: .providerError, message: "断网了"), to: connection)
                    } else {
                        write(.init(type: .result, id: message.id, text: "云端定稿"), to: connection)
                    }
                    return
                default:
                    continue
                }
            }
            let count = read(connection, &chunk, chunk.count)
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    private func write(_ message: TranslationServiceMessage, to connection: Int32) {
        guard let data = try? TranslationServiceWireCodec.encode(message) else { return }
        _ = data.withUnsafeBytes { Darwin.write(connection, $0.baseAddress, data.count) }
    }
}

public enum KeyiCloudDictationDiagnostics {
    private struct Outcome {
        var engines: [KeyiDictationEngineInfo] = []
        var texts: [String] = []
        var final: String?
        var failure: KeyiDictationFailure?
    }

    /// 在主线程调用；返回 PASS 行，失败时返回 nil 和原因。
    public static func run(file: URL, expected: String) -> (passes: [String], failure: String?) {
        let samples: [Float]
        do {
            samples = try KeyiMicrophone.samples(fromFile: file)
        } catch {
            return ([], "audio file unreadable: \(error.localizedDescription)")
        }
        var passes: [String] = []
        let socketPath = "/tmp/keyi-cloud-diag-\(UUID().uuidString.prefix(8)).sock"

        func record(_ mode: KeyiFakeSpeechService.Mode?) -> (Outcome, KeyiFakeSpeechService?)? {
            let service: KeyiFakeSpeechService?
            if let mode {
                guard let made = try? KeyiFakeSpeechService(path: socketPath, mode: mode) else { return nil }
                service = made
            } else {
                service = nil
            }
            defer { service?.stop() }
            let source = KeyiFileAudioSource(samples: samples, speed: 8)
            let engine = KeyiLiveDictationEngine(
                audio: source,
                socketPath: mode == nil ? socketPath + ".missing" : socketPath,
                checksMicrophonePermission: false
            )
            var outcome = Outcome()
            engine.start(
                onText: { outcome.texts.append($0) },
                onEngine: { outcome.engines.append($0) },
                onFailure: { outcome.failure = $0 }
            )
            let drainDeadline = Date().addingTimeInterval(10)
            while !source.isDrained, outcome.failure == nil, Date() < drainDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            engine.finish { outcome.final = $0 }
            let finishDeadline = Date().addingTimeInterval(15)
            while outcome.final == nil, outcome.failure == nil, Date() < finishDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return (outcome, service)
        }

        // 1. 服务接下云端：引擎名来自服务，实时文字和定稿都是云端的，声音全部送出。
        guard let (cloud, cloudService) = record(.accept) else { return (passes, "fake service did not start") }
        guard cloud.engines.first == KeyiDictationEngineInfo(name: "测试云端", isCloud: true) else {
            return (passes, "cloud: engine \(cloud.engines)")
        }
        passes.append("cloud dictation: the service's engine name goes to the panel")
        guard cloud.texts.contains("云端在听"), cloud.final == "云端定稿" else {
            return (passes, "cloud: texts \(cloud.texts) final \(String(describing: cloud.final))")
        }
        passes.append("cloud dictation: live text and the final text come from the cloud")
        guard cloudService?.audioBytes == samples.count * 2, cloudService?.gotFinish == true else {
            return (passes, "cloud: sent \(cloudService?.audioBytes ?? -1) of \(samples.count * 2) bytes")
        }
        passes.append("cloud dictation: every sample goes out as 16-bit PCM, then finishAudio")

        // 2. 服务说没配好：本机 SenseVoice，不提示。
        guard let (rejected, _) = record(.reject) else { return (passes, "fake service did not start") }
        guard rejected.engines == [KeyiDictationEngineInfo(name: KeyiDictationEngineInfo.localName, isCloud: false)],
              rejected.final?.contains(expected) == true
        else {
            return (passes, "not configured: engines \(rejected.engines) final \(String(describing: rejected.final))")
        }
        passes.append("cloud not configured: local SenseVoice, no notice")

        // 3. 云端中途出错：改用本机并提示原因，说的话不丢。
        guard let (failed, _) = record(.failOnFinish) else { return (passes, "fake service did not start") }
        guard failed.engines.count == 2, failed.engines.first?.isCloud == true,
              failed.engines.last?.isCloud == false, failed.engines.last?.notice?.contains("断网了") == true,
              failed.final?.contains(expected) == true
        else {
            return (passes, "cloud failure: engines \(failed.engines) final \(String(describing: failed.final))")
        }
        passes.append("cloud failure: falls back to local SenseVoice with a notice; nothing said is lost")

        // 4. 没有翻译服务：本机。
        guard let (missing, _) = record(nil) else { return (passes, "no service run failed") }
        guard missing.engines.first?.isCloud == false, missing.final?.contains(expected) == true else {
            return (passes, "no service: engines \(missing.engines) final \(String(describing: missing.final))")
        }
        passes.append("no translation service: local SenseVoice")
        return (passes, nil)
    }
}
