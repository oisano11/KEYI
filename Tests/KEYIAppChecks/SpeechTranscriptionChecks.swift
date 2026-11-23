import Foundation
import KEYICore
import KEYITranslationClient
import KEYITranslationService
@testable import KEYIUI

// 语音识别经翻译服务转发（契约「2026-11-07 云端语音识别授权」）：真服务端 + 真 socket 客户端，
// 云端换成替身。检查没配好时回 notConfigured、音频原样转发、文字和定稿传回、断开即停掉云端。

private final class SpeechEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TranslationServiceSpeechStream.Event] = []

    func append(_ event: TranslationServiceSpeechStream.Event) {
        lock.lock()
        items.append(event)
        lock.unlock()
    }

    var events: [TranslationServiceSpeechStream.Event] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    var terminal: TranslationServiceSpeechStream.Event? {
        events.last { event in
            switch event {
            case .final, .failed: true
            case .started, .partial: false
            }
        }
    }
}

private final class FakeSpeechSession: SpeechTranscriptionSession, @unchecked Sendable {
    let engineName = "测试云端"
    private let lock = NSLock()
    private let events: @Sendable (SpeechTranscriptionEvent) -> Void
    private let failsOnFinish: Bool
    private var bytes = Data()
    private var partialSent = false
    private var finishedFlag = false
    private var cancelledFlag = false

    init(events: @escaping @Sendable (SpeechTranscriptionEvent) -> Void, failsOnFinish: Bool) {
        self.events = events
        self.failsOnFinish = failsOnFinish
    }

    var received: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return finishedFlag }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelledFlag }

    func append(_ pcm16: Data) {
        lock.lock()
        bytes.append(pcm16)
        let sendPartial = bytes.count >= 6400 && !partialSent
        if sendPartial { partialSent = true }
        lock.unlock()
        if sendPartial { events(.partial("你好")) }
    }

    func finish() {
        lock.lock()
        finishedFlag = true
        lock.unlock()
        events(failsOnFinish ? .failed(.providerFailure("断网了")) : .final("你好世界"))
    }

    func cancel() {
        lock.lock()
        cancelledFlag = true
        lock.unlock()
    }
}

private final class FakeSpeechProvider: SpeechTranscriptionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let rejects: Bool
    private let failsOnFinish: Bool
    private var made: [FakeSpeechSession] = []

    init(rejects: Bool = false, failsOnFinish: Bool = false) {
        self.rejects = rejects
        self.failsOnFinish = failsOnFinish
    }

    var sessions: [FakeSpeechSession] { lock.lock(); defer { lock.unlock() }; return made }

    func startTranscription(
        sampleRate: Int,
        events: @escaping @Sendable (SpeechTranscriptionEvent) -> Void
    ) throws -> any SpeechTranscriptionSession {
        if rejects { throw TranslationServiceResolutionError.notConfigured("没选云端") }
        let session = FakeSpeechSession(events: events, failsOnFinish: failsOnFinish)
        lock.lock()
        made.append(session)
        lock.unlock()
        return session
    }
}

private struct UnusedResolver: TranslationServiceResolving {
    func translate(_ request: TranslationServiceRequest) async throws -> TranslationServiceTranslation {
        throw TranslationServiceResolutionError.notConfigured("语音检查不翻译")
    }

    func status() async -> TranslationServiceStatus {
        TranslationServiceStatus(selectedProviderID: "appleSystem", providerIDs: ["appleSystem"])
    }
}

/// 宿主那一层的事件（服务之前）。
private final class SpeechEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var failed: TranslationServiceResolutionError?

    func append(_ event: SpeechTranscriptionEvent) {
        guard case let .failed(error) = event else { return }
        lock.lock()
        failed = error
        lock.unlock()
    }

    var failure: TranslationServiceResolutionError? {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }
}

private func waitUntil(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

func runSpeechTranscriptionChecks() async throws -> Int {
    var checks = 0
    func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { fatalError(message) }
    }

    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("keyi-speech-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    func serve(_ speech: (any SpeechTranscriptionProviding)?, name: String) async throws -> (TranslationServiceServer, String) {
        let path = directory.appendingPathComponent("\(name).sock").path
        let server = TranslationServiceServer(socketPath: path, resolver: UnusedResolver(), speech: speech)
        try server.start()
        let ready = await waitUntil { TranslationServiceSocketProbe.isServiceRunning(at: path) }
        check(ready, "语音检查：服务没起来")
        return (server, path)
    }

    func open(_ path: String, _ log: SpeechEventLog) -> TranslationServiceSpeechStream {
        let stream = TranslationServiceSpeechStream(socketPath: path, sampleRate: 16000) { log.append($0) }
        stream.start()
        return stream
    }

    // 1. 服务没有云端识别：回 notConfigured，输入法据此用本机。
    do {
        let (server, path) = try await serve(nil, name: "none")
        defer { server.stop() }
        let log = SpeechEventLog()
        _ = open(path, log)
        _ = await waitUntil { log.terminal != nil }
        if case let .failed(code, _)? = log.terminal {
            check(code == .notConfigured, "没有云端识别时应回 notConfigured")
        } else {
            check(false, "没有云端识别时应以失败结束")
        }
    }

    // 2. 宿主说没选云端：同样 notConfigured，带宿主的原因。
    do {
        let (server, path) = try await serve(FakeSpeechProvider(rejects: true), name: "reject")
        defer { server.stop() }
        let log = SpeechEventLog()
        _ = open(path, log)
        _ = await waitUntil { log.terminal != nil }
        check(log.terminal == .failed(code: .notConfigured, message: "没选云端"), "没选云端时回 notConfigured 和原因")
        check(!log.events.contains { if case .started = $0 { true } else { false } }, "没接下时不回 started")
    }

    // 3. 接下：先回引擎名，音频原样转发，文字传回，finishAudio 后回定稿。
    do {
        let provider = FakeSpeechProvider()
        let (server, path) = try await serve(provider, name: "accept")
        defer { server.stop() }
        let log = SpeechEventLog()
        let stream = open(path, log)
        // 连上之前就送的帧也不丢。
        let first = Data((0..<3200).map { UInt8($0 % 251) })
        let second = Data((0..<3200).map { UInt8(($0 * 7) % 253) })
        stream.send(pcm16: first)
        _ = await waitUntil { log.events.first != nil }
        check(log.events.first == .started(engine: "测试云端"), "接下时先回引擎名")
        stream.send(pcm16: second)
        _ = await waitUntil { log.events.contains(.partial("你好")) }
        check(log.events.contains(.partial("你好")), "云端的整段文字传回输入法")
        stream.finish()
        _ = await waitUntil { log.terminal != nil }
        check(log.terminal == .final("你好世界"), "finishAudio 后回定稿")
        let session = provider.sessions.first
        check(session?.received == first + second, "音频按顺序原样转给云端")
        check(session?.finished == true && session?.cancelled == false, "定稿的那段不算取消")
    }

    // 4. 输入法中途断开：服务停掉云端，不再写回。
    do {
        let provider = FakeSpeechProvider()
        let (server, path) = try await serve(provider, name: "cancel")
        defer { server.stop() }
        let log = SpeechEventLog()
        let stream = open(path, log)
        _ = await waitUntil { log.events.first != nil }
        stream.cancel()
        let stopped = await waitUntil { provider.sessions.first?.cancelled == true }
        check(stopped, "输入法断开后服务停掉云端识别")
        try? await Task.sleep(for: .milliseconds(100))
        check(log.terminal == nil, "取消之后不再回调")
    }

    // 5. 云端出错：回 providerError 和原因，输入法据此改用本机。
    do {
        let (server, path) = try await serve(FakeSpeechProvider(failsOnFinish: true), name: "fail")
        defer { server.stop() }
        let log = SpeechEventLog()
        let stream = open(path, log)
        _ = await waitUntil { log.events.first != nil }
        stream.finish()
        _ = await waitUntil { log.terminal != nil }
        check(log.terminal == .failed(code: .providerError, message: "断网了"), "云端出错回 providerError 和原因")
    }

    // 6. 连不上服务（KEYI 可译没运行）：serviceUnavailable。
    do {
        let log = SpeechEventLog()
        _ = open(directory.appendingPathComponent("missing.sock").path, log)
        _ = await waitUntil { log.terminal != nil }
        if case let .failed(code, _)? = log.terminal {
            check(code == .serviceUnavailable, "连不上服务时回 serviceUnavailable")
        } else {
            check(false, "连不上服务时应以失败结束")
        }
    }

    // 7. 设置：默认本机；地址只认 ws/wss，留空回到北京；宿主没选云端时不接。
    let suiteName = "keyi.speech.checks.\(UUID().uuidString)"
    guard let suite = UserDefaults(suiteName: suiteName) else {
        fatalError("语音检查：建不了临时设置")
    }
    let settings = SpeechRecognitionSettings(defaults: suite)
    check(settings.engine == .local, "语音识别默认用本机")
    check(settings.endpoint == AliyunFunASRConfiguration.defaultEndpoint, "服务地址默认北京")
    settings.setEngine(.aliyunFunASR)
    check(settings.engine == .aliyunFunASR, "能改选阿里云")
    var rejected = false
    do { try settings.setEndpoint("https://example.com") } catch { rejected = true }
    check(rejected && settings.endpoint == AliyunFunASRConfiguration.defaultEndpoint, "非 ws/wss 地址不收")
    try settings.setEndpoint(" wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference ")
    check(settings.endpoint == "wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference", "改过的地址去掉空白后存下")
    check(settings.aliyunConfiguration(apiKey: "k")?.endpoint.host == "dashscope-intl.aliyuncs.com", "连接配置用改过的地址")
    try settings.setEndpoint("")
    check(settings.endpoint == AliyunFunASRConfiguration.defaultEndpoint, "地址留空回到北京")

    // 8. 豆包：地址和模型固定；各家的 Key 分开存；没 Key 时不接；有 Key 时引擎名是豆包，连不上回 providerError。
    settings.setEngine(.doubao)
    check(settings.engine == .doubao, "能改选豆包")
    let doubaoConfiguration = settings.doubaoConfiguration(apiKey: "k")
    check(doubaoConfiguration?.endpoint.absoluteString == DoubaoASRConfiguration.defaultEndpoint
            && doubaoConfiguration?.resourceID == DoubaoASRConfiguration.defaultResourceID,
          "豆包地址与模型固定")
    var noKey = SpeechRecognitionSettings(defaults: suite, readCredential: { _ in nil })
    noKey.setEngine(.doubao)
    check(!noKey.hasAPIKey(for: .doubao) && !noKey.hasAPIKey(for: .local), "没存 Key")
    var missingKey = ""
    do {
        _ = try KEYISpeechTranscriptionProvider(settings: noKey).startTranscription(sampleRate: 16000) { _ in }
    } catch let error as TranslationServiceResolutionError {
        missingKey = error.wireCode == .notConfigured ? error.message : ""
    }
    check(missingKey == "还没填豆包的 API Key", "选了豆包没填 Key 时不接（实际「\(missingKey)」）")
    var withKey = noKey
    withKey.readCredential = { $0 == SpeechRecognitionSettings.doubaoAPIKeyAccount ? "k" : nil }
    withKey.doubaoEndpoint = "ws://127.0.0.1:9/none"
    check(withKey.hasAPIKey(for: .doubao) && !withKey.hasAPIKey(for: .aliyunFunASR), "两家的 Key 分开存")
    let doubaoEvents = SpeechEventBox()
    let doubaoSession = try KEYISpeechTranscriptionProvider(settings: withKey).startTranscription(sampleRate: 16000) {
        doubaoEvents.append($0)
    }
    check(doubaoSession.engineName == DoubaoASRConfiguration.displayName, "引擎名是豆包语音识别")
    _ = await waitUntil(10) { doubaoEvents.failure != nil }
    check(doubaoEvents.failure?.wireCode == .providerError && doubaoEvents.failure?.message.contains("连不上豆包") == true,
          "连不上豆包时回 providerError，输入法改用本机（实际 \(String(describing: doubaoEvents.failure))）")
    suite.removePersistentDomain(forName: suiteName)
    if UserDefaults.standard.string(forKey: SpeechRecognitionSettings.engineKey) == nil {
        var notConfigured = false
        do {
            _ = try KEYISpeechTranscriptionProvider().startTranscription(sampleRate: 16000) { _ in }
        } catch let error as TranslationServiceResolutionError {
            notConfigured = error.wireCode == .notConfigured
        }
        check(notConfigured, "没选云端时宿主不接，输入法用本机")
    }

    // 9. 说话键（契约 2026-11-08）：文案跟着设的键走；和 KEYI 可译的翻译快捷键相同的组合键不收。
    let zh = InterfaceStrings(language: .simplifiedChinese)
    let en = InterfaceStrings(language: .english)
    let rightCommand = KEYIDictationShortcut(keyCode: 54)
    check(zh.speechReady(key: .standard) == "可以用了，按住右 ⌥ 说话"
            && zh.speechReady(key: rightCommand) == "可以用了，按住右 ⌘ 说话",
          "「可以用了」写的是设的说话键")
    check(en.speechReady(key: rightCommand) == "Ready. Hold Right ⌘ to talk.", "英文提示也跟着说话键")
    check(!zh.speechEngineDetail.contains("右 ⌥") && !en.speechEngineDetail.contains("right ⌥"),
          "识别说明里不再写死右 ⌥")
    let problems: [KEYIDictationShortcut.Problem] = [.shift, .plainKey, .translationToggle, .commandShortcut, .unsupported]
    check(problems.allSatisfy { !zh.speechKeyProblem($0, key: KEYIDictationShortcut(keyCode: 56)).isEmpty
              && !en.speechKeyProblem($0, key: KEYIDictationShortcut(keyCode: 56)).isEmpty },
          "每种不能用的键都有说明")
    let optionT = KEYIDictationShortcut(keyCode: 17, modifiers: .option, keyLabel: "t")
    check(DictationKeyRow.isDesktopHotKey(optionT, .default), "⌥T 和默认的翻译快捷键相同，不收")
    check(!DictationKeyRow.isDesktopHotKey(KEYIDictationShortcut(keyCode: 17, modifiers: [.option, .shift], keyLabel: "t"), .default)
            && !DictationKeyRow.isDesktopHotKey(.standard, .default),
          "别的键不算和翻译快捷键冲突")

    return checks
}
