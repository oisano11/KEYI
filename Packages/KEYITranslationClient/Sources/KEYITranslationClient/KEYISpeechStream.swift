//
//  KEYISpeechStream.swift
//  KEYI 翻译线协议 — 语音识别（2026-11-07）
//
//  一段录音用一个连接：`transcribe` → 若干 `audio` → `finishAudio`；服务端先回
//  `transcriptStarted`（接下了，带引擎名）或 `error`（没选云端、没配好），之后回若干
//  `transcript`（整段文字），最后是终止事件 `result`（定稿）或 `error`。
//  协议里没有密钥：服务端用自己读到的配置去连云端。
//

import Foundation

public final class TranslationServiceSpeechStream: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        /// 服务接下了这段识别，`engine` 是显示名。
        case started(engine: String)
        /// 到此刻为止的整段文字。
        case partial(String)
        /// 定稿（终止）。
        case final(String)
        /// 没接下或中途失败（终止）。连不上服务时 `code` 为 `serviceUnavailable`。
        case failed(code: TranslationServiceErrorCode, message: String)
    }

    /// 整段录音（含松开后等定稿）最长多久。
    public static let maximumSeconds: Double = 150

    public let id: String
    private let socketPath: String
    private let sampleRate: Int
    private let handler: @Sendable (Event) -> Void
    private let cancellation = TranslationServiceCancellation()
    /// 连上并发出 `transcribe` 之前不放行，之后按顺序写；关闭也在这条队列上，写不会碰到复用的 fd。
    private let writeQueue: DispatchQueue
    private let lock = NSLock()
    private var connection: TranslationServiceTransportConnection?
    private var ended = false

    /// `handler` 在后台线程调用；最后一个事件必是 `final` 或 `failed`，`cancel()` 之后不再调用。
    public init(
        socketPath: String = TranslationServiceSocketPath.defaultPath(),
        sampleRate: Int,
        id: String = UUID().uuidString,
        handler: @escaping @Sendable (Event) -> Void
    ) {
        self.socketPath = socketPath
        self.sampleRate = sampleRate
        self.id = id
        self.handler = handler
        writeQueue = DispatchQueue(
            label: "com.keyi.input-translator.speech-stream.write",
            qos: .userInitiated,
            attributes: .initiallyInactive
        )
    }

    /// 在后台连上服务并发出 `transcribe`，之后一直读到终止事件。
    public func start() {
        Thread.detachNewThread { [self] in run() }
    }

    /// 送一帧 16 位小端单声道 PCM。没连上前先排着。
    public func send(pcm16 data: Data) {
        guard !data.isEmpty else { return }
        enqueue(TranslationServiceMessage(type: .audio, id: id, audio: data.base64EncodedString()))
    }

    /// 音频送完了，等定稿。
    public func finish() {
        enqueue(TranslationServiceMessage(type: .finishAudio, id: id))
    }

    /// 立即断开，之后不再回调。服务端据此停掉云端识别。
    public func cancel() {
        cancellation.cancel()
        lock.lock()
        let connection = connection
        lock.unlock()
        connection?.shutdown()
        activateWrites()
    }

    // MARK: - 内部

    private func enqueue(_ message: TranslationServiceMessage) {
        guard let payload = try? TranslationServiceTransport.encode(message) else { return }
        writeQueue.async { [self] in
            lock.lock()
            let descriptor = ended ? -1 : (connection?.descriptor ?? -1)
            lock.unlock()
            guard descriptor >= 0, !cancellation.isCancelled else { return }
            // 写失败（服务端已关）不在这里报：读循环会读到关闭并报一次。
            try? TranslationServiceTransport.writeAll(
                descriptor: descriptor,
                data: payload,
                requestID: id,
                cancellation: cancellation
            )
        }
    }

    private var writesActivated = false

    private func activateWrites() {
        lock.lock()
        let first = !writesActivated
        writesActivated = true
        lock.unlock()
        if first { writeQueue.activate() }
    }

    private func run() {
        let connection: TranslationServiceTransportConnection
        do {
            connection = try TranslationServiceTransport.connect(
                path: socketPath,
                timeoutSeconds: TranslationServiceProtocol.connectTimeoutSeconds
            )
            let request = TranslationServiceMessage(type: .transcribe, id: id, sampleRate: sampleRate)
            try TranslationServiceTransport.writeAll(
                descriptor: connection.descriptor,
                data: TranslationServiceTransport.encode(request),
                requestID: id,
                cancellation: cancellation
            )
        } catch {
            endWithoutConnection(error)
            return
        }
        lock.lock()
        self.connection = connection
        lock.unlock()
        if cancellation.isCancelled { connection.shutdown() }
        activateWrites()

        let deadline = Date().timeIntervalSince1970 + Self.maximumSeconds
        var buffer = Data()
        var terminal: Event?
        do {
            while terminal == nil {
                guard let line = try TranslationServiceTransport.readLine(
                    descriptor: connection.descriptor,
                    buffer: &buffer,
                    deadline: deadline,
                    requestID: id,
                    timeout: Self.maximumSeconds,
                    cancellation: cancellation
                ) else {
                    terminal = .failed(code: .serviceUnavailable, message: "翻译服务提前关闭了连接")
                    break
                }
                guard let event = try? TranslationServiceTransport.decode(TranslationServiceMessage.self, from: line),
                      event.version == TranslationServiceProtocol.version
                else {
                    terminal = .failed(code: .badRequest, message: "翻译服务的回应看不懂（可能要更新 KEYI 可译）")
                    break
                }
                guard event.id == nil || event.id == id else { continue }
                switch event.type {
                case .transcriptStarted:
                    deliver(.started(engine: event.message ?? ""))
                case .transcript:
                    deliver(.partial(event.text ?? ""))
                case .result:
                    terminal = .final(event.text ?? "")
                case .error, .cancelled:
                    terminal = .failed(code: event.code ?? .internalError, message: event.message ?? "")
                case .translate, .cancel, .status, .ping, .transcribe, .audio, .finishAudio, .serviceStatus, .pong:
                    continue
                }
            }
        } catch let error as TranslationServiceClientError {
            terminal = Self.failure(error)
        } catch {
            terminal = .failed(code: .internalError, message: error.localizedDescription)
        }
        lock.lock()
        ended = true
        lock.unlock()
        writeQueue.async { connection.close() }
        if let terminal { deliver(terminal) }
    }

    private func endWithoutConnection(_ error: Error) {
        lock.lock()
        ended = true
        lock.unlock()
        activateWrites()
        if let error = error as? TranslationServiceClientError {
            deliver(Self.failure(error))
        } else {
            deliver(.failed(code: .serviceUnavailable, message: error.localizedDescription))
        }
    }

    private func deliver(_ event: Event) {
        guard !cancellation.isCancelled else { return }
        handler(event)
    }

    private static func failure(_ error: TranslationServiceClientError) -> Event {
        switch error {
        case let .serviceUnavailable(detail):
            .failed(code: .serviceUnavailable, message: detail)
        case let .invalidResponse(detail):
            .failed(code: .badRequest, message: detail)
        case .timeout:
            .failed(code: .timeout, message: "语音识别超时")
        case .cancelled:
            .failed(code: .cancelled, message: "语音识别已取消")
        case let .rejected(code, message):
            .failed(code: code, message: message)
        }
    }
}
