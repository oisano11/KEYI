//
//  TranslationServiceServer.swift
//  KEYI 可译 — 输入法翻译服务（阶段 02）
//
//  在 KEYI 伴随应用进程内监听 AF_UNIX socket，把输入法进程的翻译请求转给
//  `TranslationServiceResolving`（宿主实现：已保存的提供方 / 语言 / 语气 / 凭据）。
//
//  协议细节见 `Packages/KEYITranslationClient/Sources/KEYITranslationClient/KEYITranslationClient.swift`。
//

import Foundation
import KEYICore
import KEYITranslationClient
import OSLog

public final class TranslationServiceServer: @unchecked Sendable {
    private let socketPath: String
    private let resolver: any TranslationServiceResolving
    /// 云端语音识别；nil 时 `transcribe` 一律回 `notConfigured`。
    fileprivate let speech: (any SpeechTranscriptionProviding)?
    private let maximumConcurrentRequests: Int
    private let logger = Logger(
        subsystem: "com.keyi.input-translator",
        category: "TranslationService"
    )

    private let stateLock = NSLock()
    private var listenerDescriptor: Int32 = -1
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var activeTranslations = 0
    private var running = false

    public init(
        socketPath: String = TranslationServiceSocketPath.defaultPath(),
        resolver: any TranslationServiceResolving,
        speech: (any SpeechTranscriptionProviding)? = nil,
        maximumConcurrentRequests: Int = 4
    ) {
        self.socketPath = socketPath
        self.resolver = resolver
        self.speech = speech
        self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
    }

    // MARK: - 生命周期

    public func start() throws {
        stateLock.lock()
        if running {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        try prepareSocketDirectory()
        let descriptor = try makeListener()

        stateLock.lock()
        listenerDescriptor = descriptor
        running = true
        stateLock.unlock()

        logger.info("Translation service listening at \(self.socketPath, privacy: .public)")
        Thread.detachNewThread { [weak self] in
            self?.acceptLoop(descriptor: descriptor)
        }
    }

    public func stop() {
        stateLock.lock()
        guard running else {
            stateLock.unlock()
            return
        }
        running = false
        let descriptor = listenerDescriptor
        listenerDescriptor = -1
        let openConnections = Array(connections.values)
        connections.removeAll()
        stateLock.unlock()

        if descriptor >= 0 {
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
            _ = Darwin.close(descriptor)
        }
        openConnections.forEach { $0.cancelAll(reason: "服务停止") }
        unlink(socketPath)
        logger.info("Translation service stopped")
    }

    // MARK: - 监听

    private func prepareSocketDirectory() throws {
        let directory = (socketPath as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
        }
        // 只清理确认无人监听的陈旧 socket，避免误删在用的服务。
        guard FileManager.default.fileExists(atPath: socketPath) else { return }
        if probeExistingSocket() {
            throw TranslationServiceResolutionError.unavailableProvider(
                "已有翻译服务在监听 \(socketPath)"
            )
        }
        unlink(socketPath)
    }

    private func probeExistingSocket() -> Bool {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            return false
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.connect(
                    descriptor,
                    socketPointer,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        return result == 0
    }

    private func makeListener() throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw TranslationServiceResolutionError.unavailableProvider(
                "无法创建翻译服务 socket（\(errno)）"
            )
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            _ = Darwin.close(descriptor)
            throw TranslationServiceResolutionError.unavailableProvider(
                "翻译服务 socket 路径过长：\(socketPath)"
            )
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(
                    descriptor,
                    socketPointer,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bindResult == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw TranslationServiceResolutionError.unavailableProvider(
                "无法绑定翻译服务 socket（\(code)）"
            )
        }
        // 权限收紧到当前用户；失败不致命，仅告警。
        if chmod(socketPath, S_IRUSR | S_IWUSR) != 0 {
            logger.warning("翻译服务 socket 权限设置失败（\(errno)），继续运行")
        }
        guard Darwin.listen(descriptor, 16) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            unlink(socketPath)
            throw TranslationServiceResolutionError.unavailableProvider(
                "无法监听翻译服务 socket（\(code)）"
            )
        }
        return descriptor
    }

    private func acceptLoop(descriptor: Int32) {
        while isRunning {
            var address = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                    Darwin.accept(descriptor, socketPointer, &length)
                }
            }
            guard client >= 0 else {
                if errno == EINTR { continue }
                if isRunning {
                    logger.error("翻译服务 accept 失败（\(errno)）")
                }
                break
            }
            // 连接关闭后写入会触发 SIGPIPE；仅对本连接禁用信号，不改全局。
            var noSigPipe: Int32 = 1
            guard setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                logger.error("翻译服务设置 SO_NOSIGPIPE 失败（\(errno)），关闭该连接")
                _ = Darwin.close(client)
                continue
            }
            let connection = Connection(
                descriptor: client,
                server: self
            )
            stateLock.lock()
            connections[ObjectIdentifier(connection)] = connection
            stateLock.unlock()
            Thread.detachNewThread { [weak self] in
                connection.run()
                self?.remove(connection)
            }
        }
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func remove(_ connection: Connection) {
        stateLock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        stateLock.unlock()
    }

    // MARK: - 并发配额

    fileprivate func reserveTranslationSlot() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeTranslations < maximumConcurrentRequests else { return false }
        activeTranslations += 1
        return true
    }

    fileprivate func releaseTranslationSlot() {
        stateLock.lock()
        activeTranslations = max(0, activeTranslations - 1)
        stateLock.unlock()
    }

    fileprivate func handle(_ message: TranslationServiceMessage) async -> TranslationServiceMessage {
        switch message.type {
        case .ping:
            return TranslationServiceMessage(type: .pong, id: message.id)
        case .status:
            let status = await resolver.status()
            return TranslationServiceMessage(
                type: .serviceStatus,
                id: message.id,
                providerIDs: status.providerIDs,
                selectedProviderID: status.selectedProviderID
            )
        case .translate:
            return await translate(message)
        case .cancel, .result, .error, .cancelled, .serviceStatus, .pong,
             .transcribe, .audio, .finishAudio, .transcriptStarted, .transcript:
            return TranslationServiceMessage(
                type: .error,
                id: message.id,
                code: .badRequest,
                message: "服务端不处理该消息类型：\(message.type.rawValue)"
            )
        }
    }

    private func translate(_ message: TranslationServiceMessage) async -> TranslationServiceMessage {
        guard message.version == TranslationServiceProtocol.version else {
            return TranslationServiceMessage(
                type: .error,
                id: message.id,
                code: .badRequest,
                message: "协议版本不匹配：请求 \(message.version)，服务 \(TranslationServiceProtocol.version)"
            )
        }
        // 入口统一规范化超时：非有限值直接拒绝，极大值夹到上限，避免转纳秒溢出。
        guard let timeout = TranslationServiceProtocol.normalizedTimeoutSeconds(
            message.timeoutSeconds
        ) else {
            let rawTimeout = message.timeoutSeconds.map { String($0) } ?? "nil"
            return TranslationServiceMessage(
                type: .error,
                id: message.id,
                code: .badRequest,
                message: "超时值无效：\(rawTimeout)"
            )
        }
        let request = TranslationServiceRequest(
            text: message.text ?? "",
            contextText: message.contextText,
            providerID: message.providerID,
            sourceLanguage: message.sourceLanguage,
            targetLanguage: message.targetLanguage,
            scene: message.scene,
            englishStyle: message.englishStyle,
            timeoutSeconds: timeout,
            id: message.id ?? UUID().uuidString
        )
        do {
            try TranslationServiceRequestValidator.validate(request)
        } catch let error as TranslationServiceResolutionError {
            return TranslationServiceMessage(
                type: .error,
                id: request.id,
                code: error.wireCode,
                message: error.message
            )
        } catch {
            return TranslationServiceMessage(
                type: .error,
                id: request.id,
                code: .badRequest,
                message: error.localizedDescription
            )
        }

        let requestStarted = Date()
        let requestID = TranslationServiceErrorMetadata.safeLogToken(request.id)
        let providerID = TranslationServiceErrorMetadata.safeLogToken(request.providerID ?? "auto")
        let sourceLanguage = TranslationServiceErrorMetadata.safeLogToken(request.sourceLanguage ?? "auto")
        let targetLanguage = TranslationServiceErrorMetadata.safeLogToken(request.targetLanguage ?? "auto")
        logger.info(
            "translation_event=request_started request_id=\(requestID, privacy: .public) provider_id=\(providerID, privacy: .public) source_language=\(sourceLanguage, privacy: .public) target_language=\(targetLanguage, privacy: .public)"
        )

        guard reserveTranslationSlot() else {
            logger.error(
                "translation_event=request_failed request_id=\(requestID, privacy: .public) stage=admission error_type=busy error_domain=KEYITranslationService error_code=0 elapsed_ms=0"
            )
            return TranslationServiceMessage(
                type: .error,
                id: request.id,
                code: .busy,
                message: "翻译服务忙，请稍后再试"
            )
        }
        // 名额只在底层提供方真正退出时释放：超时或取消只是让调用方立即返回，
        // 不响应取消的提供方仍占用名额，避免「看起来结束但底层还在跑」。
        let slot = TranslationSlotRelease { [weak self] in
            self?.releaseTranslationSlot()
        }

        do {
            let result = try await withTimeout(seconds: timeout) {
                defer { slot.releaseOnce() }
                return try await self.resolver.translate(request)
            }
            logger.info(
                "translation_event=request_succeeded request_id=\(requestID, privacy: .public) provider_id=\(TranslationServiceErrorMetadata.safeLogToken(result.providerID), privacy: .public) source_language=\(sourceLanguage, privacy: .public) target_language=\(targetLanguage, privacy: .public) elapsed_ms=\(Int(Date().timeIntervalSince(requestStarted) * 1000), privacy: .public)"
            )
            return TranslationServiceMessage(
                type: .result,
                id: request.id,
                text: result.text,
                providerID: result.providerID
            )
        } catch is TimeoutError {
            let metadata = TranslationServiceErrorMetadata(TimeoutError())
            logger.error(
                "translation_event=request_failed request_id=\(requestID, privacy: .public) stage=service_deadline provider_id=\(providerID, privacy: .public) source_language=\(sourceLanguage, privacy: .public) target_language=\(targetLanguage, privacy: .public) error_type=\(metadata.typeName, privacy: .public) error_domain=\(metadata.domain, privacy: .public) error_code=\(metadata.code, privacy: .public) elapsed_ms=\(Int(Date().timeIntervalSince(requestStarted) * 1000), privacy: .public)"
            )
            return TranslationServiceMessage(
                type: .error,
                id: request.id,
                code: .timeout,
                message: "翻译请求超时（\(Int(timeout)) 秒）"
            )
        } catch {
            let mapped = TranslationServiceErrorMapper.map(error)
            let metadata = TranslationServiceErrorMetadata(error)
            logger.error(
                "translation_event=request_failed request_id=\(requestID, privacy: .public) stage=provider provider_id=\(providerID, privacy: .public) source_language=\(sourceLanguage, privacy: .public) target_language=\(targetLanguage, privacy: .public) error_type=\(metadata.typeName, privacy: .public) error_domain=\(metadata.domain, privacy: .public) error_code=\(metadata.code, privacy: .public) wire_code=\(mapped.0.rawValue, privacy: .public) elapsed_ms=\(Int(Date().timeIntervalSince(requestStarted) * 1000), privacy: .public)"
            )
            return TranslationServiceMessage(
                type: .error,
                id: request.id,
                code: mapped.0,
                message: mapped.1
            )
        }
    }
}

// MARK: - 单连接

private final class Connection: @unchecked Sendable {
    private let descriptor: Int32
    private weak var server: TranslationServiceServer?
    private let writeLock = NSLock()
    private let taskLock = NSLock()
    private var requests: [String: RequestContext] = [:]
    /// 这个连接上的一段语音识别（一个连接最多一段）。
    private var speechID: String?
    private var speechSession: (any SpeechTranscriptionSession)?
    private var closed = false
    private var terminated = false
    private let logger = Logger(
        subsystem: "com.keyi.input-translator",
        category: "TranslationService"
    )

    init(
        descriptor: Int32,
        server: TranslationServiceServer
    ) {
        self.descriptor = descriptor
        self.server = server
    }

    /// 读循环：逐行解析请求并派发；`cancel` 随时可打断在途请求。
    func run() {
        defer { terminate(reason: "读循环结束") }
        var buffer = Data()
        while let line = readLine(buffer: &buffer) {
            guard !line.isEmpty else { continue }
            guard let message = try? TranslationServiceWireCodec.decode(line) else {
                _ = write(
                    TranslationServiceMessage(
                        type: .error,
                        code: .badRequest,
                        message: "请求不是合法 JSON"
                    )
                )
                break
            }
            // 版本校验必须在任何分派之前：错误版本的 cancel 也不得先取消任务。
            guard message.version == TranslationServiceProtocol.version else {
                _ = write(
                    TranslationServiceMessage(
                        type: .error,
                        id: message.id,
                        code: .badRequest,
                        message: "协议版本不匹配：请求 \(message.version)，服务 \(TranslationServiceProtocol.version)"
                    )
                )
                break
            }
            switch message.type {
            case .transcribe:
                guard startTranscription(message) else { return }
                continue
            case .audio:
                currentSpeechSession(for: message.id)?.append(Data(base64Encoded: message.audio ?? "") ?? Data())
                continue
            case .finishAudio:
                currentSpeechSession(for: message.id)?.finish()
                continue
            default:
                break
            }
            if message.type == .cancel {
                let id = message.id ?? ""
                taskLock.lock()
                let context = requests.removeValue(forKey: id)
                taskLock.unlock()
                context?.cancel()
                _ = write(
                    TranslationServiceMessage(
                        type: .cancelled,
                        id: id,
                        code: .cancelled,
                        message: "翻译已取消"
                    )
                )
                logger.info("翻译请求已取消")
                break
            }
            guard let server else { break }
            let id = message.id ?? UUID().uuidString
            let context = RequestContext(
                id: id,
                message: message,
                server: server,
                connection: self
            )
            taskLock.lock()
            requests[id] = context
            taskLock.unlock()
            context.start()
        }
    }

    /// 结束连接：标记终止、取消全部在途请求并关闭 socket。
    ///
    /// 幂等：重复调用不重复取请求、不重复关闭 fd。并发名额由各请求
    /// `translate()` 的 `defer` 在底层任务真正退出时释放。
    func terminate(reason: String) {
        taskLock.lock()
        let alreadyTerminated = terminated
        terminated = true
        let inFlight = Array(requests.values)
        requests.removeAll()
        let speech = speechSession
        speechSession = nil
        taskLock.unlock()
        speech?.cancel()
        if !alreadyTerminated {
            inFlight.forEach { $0.cancel() }
            if !inFlight.isEmpty {
                logger.info("翻译服务取消在途请求：\(reason, privacy: .public)")
            }
        }
        close()
    }

    /// 取消该连接上全部在途翻译（客户端断开或服务停止）。
    func cancelAll(reason: String) {
        terminate(reason: reason)
    }

    /// 在途请求结束时调用：写回结果；终止事件写出后关闭连接。
    fileprivate func deliver(_ reply: TranslationServiceMessage, requestID: String) {
        taskLock.lock()
        let context = requests.removeValue(forKey: requestID)
        let alreadyTerminated = terminated
        taskLock.unlock()
        guard !alreadyTerminated, let context, context.claimDelivery() else { return }
        guard write(reply) else {
            terminate(reason: "写回结果失败")
            return
        }
        switch reply.type {
        case .result, .error, .cancelled:
            terminate(reason: "已交付终止事件")
        case .serviceStatus, .pong, .translate, .cancel, .status, .ping,
             .transcribe, .audio, .finishAudio, .transcriptStarted, .transcript:
            break
        }
    }

    // MARK: 语音识别

    /// 接下一段识别：宿主说没配好就回 `error` 并结束连接（返回 false）。
    private func startTranscription(_ message: TranslationServiceMessage) -> Bool {
        let id = message.id ?? UUID().uuidString
        taskLock.lock()
        let busy = speechID != nil
        taskLock.unlock()
        guard !busy else {
            _ = write(TranslationServiceMessage(type: .error, id: id, code: .badRequest, message: "一个连接只能识别一段"))
            return false
        }
        guard let provider = server?.speech else {
            _ = write(TranslationServiceMessage(type: .error, id: id, code: .notConfigured, message: "没有配置云端语音识别"))
            return false
        }
        let sampleRate = message.sampleRate ?? 16000
        guard (8000...48000).contains(sampleRate) else {
            _ = write(TranslationServiceMessage(type: .error, id: id, code: .badRequest, message: "采样率不支持：\(sampleRate)"))
            return false
        }
        taskLock.lock()
        speechID = id
        taskLock.unlock()
        do {
            let session = try provider.startTranscription(sampleRate: sampleRate) { [weak self] event in
                self?.deliverSpeech(event, id: id)
            }
            taskLock.lock()
            let alreadyTerminated = terminated
            if !alreadyTerminated { speechSession = session }
            taskLock.unlock()
            guard !alreadyTerminated else {
                session.cancel()
                return false
            }
            logger.info("语音识别开始 engine=\(session.engineName, privacy: .public)")
            return write(TranslationServiceMessage(type: .transcriptStarted, id: id, message: session.engineName))
        } catch {
            let (code, text) = TranslationServiceErrorMapper.map(error)
            _ = write(TranslationServiceMessage(type: .error, id: id, code: code, message: text))
            return false
        }
    }

    private func currentSpeechSession(for id: String?) -> (any SpeechTranscriptionSession)? {
        taskLock.lock()
        defer { taskLock.unlock() }
        guard let speechID, id == nil || id == speechID else { return nil }
        return speechSession
    }

    /// 云端的文字转成事件；定稿或失败后结束连接。
    private func deliverSpeech(_ event: SpeechTranscriptionEvent, id: String) {
        guard !isTerminated else { return }
        switch event {
        case let .partial(text):
            if !write(TranslationServiceMessage(type: .transcript, id: id, text: text)) {
                terminate(reason: "写回识别文字失败")
            }
        case let .final(text):
            taskLock.lock()
            speechSession = nil
            taskLock.unlock()
            _ = write(TranslationServiceMessage(type: .result, id: id, text: text))
            terminate(reason: "语音识别已定稿")
        case let .failed(error):
            taskLock.lock()
            speechSession = nil
            taskLock.unlock()
            logger.error("语音识别失败 code=\(error.wireCode.rawValue, privacy: .public)")
            _ = write(TranslationServiceMessage(type: .error, id: id, code: error.wireCode, message: error.message))
            terminate(reason: "语音识别失败")
        }
    }

    fileprivate var isTerminated: Bool {
        taskLock.lock()
        defer { taskLock.unlock() }
        return terminated
    }

    private func close() {
        writeLock.lock()
        let alreadyClosed = closed
        closed = true
        writeLock.unlock()
        guard !alreadyClosed else { return }
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        _ = Darwin.close(descriptor)
    }

    // MARK: IO

    private func readLine(buffer: inout Data) -> Data? {
        while true {
            if let range = buffer.range(of: Data([0x0A])) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex...range.lowerBound)
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                guard buffer.count <= TranslationServiceProtocol.maximumMessageBytes else {
                    logger.error("翻译服务请求超过长度上限，关闭连接")
                    return nil
                }
            } else if count == 0 {
                return nil
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }
    }

    private func write(_ message: TranslationServiceMessage) -> Bool {
        guard let data = try? TranslationServiceWireCodec.encode(message) else {
            return false
        }
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return false }
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

/// 一次在途请求：持有的 Task 可被 `cancel` 消息取消。
private final class RequestContext: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false
    private var delivered = false
    private var completed = false

    private let id: String
    private let message: TranslationServiceMessage
    private weak var server: TranslationServiceServer?
    private weak var connection: Connection?

    init(
        id: String,
        message: TranslationServiceMessage,
        server: TranslationServiceServer,
        connection: Connection
    ) {
        self.id = id
        self.message = message
        self.server = server
        self.connection = connection
    }

    /// 登记完成后才启动任务，避免快速完成时登记状态错乱。
    func start() {
        lock.lock()
        let shouldCancel = cancelled
        let shouldStart = task == nil && !shouldCancel
        if shouldStart {
            task = Task { [weak self] in
                guard let self else { return }
                await self.run()
            }
        }
        lock.unlock()
        if shouldCancel {
            task?.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    /// 一次性取得交付资格；已取消或已交付的请求不得再写回。
    fileprivate func claimDelivery() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, !delivered else { return false }
        delivered = true
        return true
    }

    private func run() async {
        guard let server, let connection else { return }
        let reply = await server.handle(message)
        let shouldDeliver = shouldDeliverResult()
        if shouldDeliver {
            connection.deliver(reply, requestID: id)
        }
        markCompleted()
    }

    private func shouldDeliverResult() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled && !Task.isCancelled
    }

    private func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }
}

// MARK: - 超时

public struct TimeoutError: Error, Sendable {
    public init() {}
}

/// 一次性释放并发名额：只有底层提供方真正退出时才释放，重复调用无副作用。
/// 超时 / 取消后仍不响应的提供方继续持有名额，下一次请求会得到 `busy`。
final class TranslationSlotRelease: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private let release: @Sendable () -> Void

    init(release: @escaping @Sendable () -> Void) {
        self.release = release
    }

    func releaseOnce() {
        lock.lock()
        let shouldRelease = !released
        released = true
        lock.unlock()
        if shouldRelease {
            release()
        }
    }
}

/// 超时后仍未结束的底层操作；用于区分「已按时返回超时」与「底层工作仍在跑」。
///
/// 不响应取消的提供方会在这里累积，便于排错（Logger 会记录积压数量）。
public final class TranslationServiceBackgroundWorkTracker: @unchecked Sendable {
    public static let shared = TranslationServiceBackgroundWorkTracker()

    private let lock = NSLock()
    private var outstanding = 0
    private let logger = Logger(
        subsystem: "com.keyi.input-translator",
        category: "TranslationTimeout"
    )

    private init() {}

    public var outstandingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return outstanding
    }

    func track(_ task: Task<Void, Never>, label: String) {
        let count = increment()
        logger.warning(
            "超时后底层提供方仍在运行：\(label, privacy: .public)，积压=\(count, privacy: .public)"
        )
        Task { [weak self] in
            _ = await task.value
            guard let self else { return }
            let remaining = self.decrement()
            self.logger.info(
                "超时后的底层提供方已结束：\(label, privacy: .public)，剩余=\(remaining, privacy: .public)"
            )
        }
    }

    private func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        outstanding += 1
        return outstanding
    }

    private func decrement() -> Int {
        lock.lock()
        defer { lock.unlock() }
        outstanding = max(0, outstanding - 1)
        return outstanding
    }
}

/// 给任意异步操作加真超时：到期立即抛 `TimeoutError`，不等待 operation 结束。
///
/// 超时或外部取消时只 cancel 底层任务，不 await；不响应取消的 operation 交由
/// `TranslationServiceBackgroundWorkTracker` 跟踪，避免悄悄留下无限增长的任务。
public func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    // 先夹紧再转纳秒，避免极大值转换溢出或崩溃。
    let clampedSeconds = min(max(seconds.isFinite ? seconds : 0.05, 0.05), 86_400)
    let nanoseconds = UInt64(clampedSeconds * 1_000_000_000)
    let box = TimeoutRaceBox<T>()

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            box.install(continuation)
            let operationTask = Task {
                do {
                    let value = try await operation()
                    box.markOperationFinished()
                    box.resume(with: .success(value))
                } catch {
                    box.markOperationFinished()
                    box.resume(with: .failure(error))
                }
            }
            let timerTask = Task {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                let stillRunning = !box.operationDidFinish
                let won = box.resume(with: .failure(TimeoutError()))
                // 已经按时返回超时：通知调用方，但底层 Task 不能 await。
                operationTask.cancel()
                if won, stillRunning {
                    TranslationServiceBackgroundWorkTracker.shared.track(
                        operationTask,
                        label: "withTimeout(\(clampedSeconds)s)"
                    )
                }
            }
            box.setTasks(operation: operationTask, timer: timerTask)
        }
    } onCancel: {
        // 外部取消：立即恢复外层等待（否则不响应取消的提供方会挂住调用方），
        // 底层任务只 cancel、不登记为超时积压。
        box.cancelAll()
        // 不响应取消的底层操作必须继续追踪，避免悄悄留下无限增长的任务。
        if let operation = box.operationTaskOrNil, !box.operationDidFinish {
            TranslationServiceBackgroundWorkTracker.shared.track(
                operation,
                label: "cancelled withTimeout"
            )
        }
        box.resume(with: .failure(CancellationError()))
    }
}

/// 超时竞速的一次性恢复盒子：保证 operation、计时器与取消只有一个能恢复 continuation。
private final class TimeoutRaceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var operationTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<T, Error>?
    private var operationFinished = false

    var operationDidFinish: Bool {
        lock.lock()
        defer { lock.unlock() }
        return operationFinished
    }

    var operationTaskOrNil: Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return operationTask
    }

    func markOperationFinished() {
        lock.lock()
        operationFinished = true
        lock.unlock()
    }

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        let alreadyFinished = finished
        if !alreadyFinished {
            self.continuation = continuation
        }
        lock.unlock()
        if alreadyFinished {
            continuation.resume(throwing: CancellationError())
        }
    }

    func setTasks(operation: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.lock()
        let alreadyFinished = finished
        if !alreadyFinished {
            operationTask = operation
            timerTask = timer
        }
        lock.unlock()
        if alreadyFinished {
            operation.cancel()
            timer.cancel()
            if !operationDidFinish {
                TranslationServiceBackgroundWorkTracker.shared.track(
                    operation,
                    label: "cancelled withTimeout"
                )
            }
        }
    }

    @discardableResult
    func resume(with result: Result<T, Error>) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let operationTask = self.operationTask
        let timerTask = self.timerTask
        lock.unlock()
        operationTask?.cancel()
        timerTask?.cancel()
        // 只取消，不 await：不响应取消的 operation 由跟踪器负责。
        continuation?.resume(with: result)
        return true
    }

    func cancelAll() {
        lock.lock()
        let shouldCancel = !finished
        let tasks = (operationTask, timerTask)
        lock.unlock()
        if shouldCancel {
            tasks.0?.cancel()
            tasks.1?.cancel()
        }
    }
}
