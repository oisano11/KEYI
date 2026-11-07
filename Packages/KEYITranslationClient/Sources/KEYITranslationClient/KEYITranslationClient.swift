//
//  KEYITranslationClient.swift
//  KEYI 可译
//
//  阶段 02：KEYI 输入法翻译服务的线协议与客户端。
//
//  本文件是线协议的唯一来源，位于共享包 Packages/KEYITranslationClient。
//  KEYI 伴随应用（服务端，仓库根包）与 KEYI 拼音输入法（客户端，IME/ 包）
//  都依赖这个包，使用同一份实现，不再逐字节复制。
//
//  ## 线协议 v1
//
//  - 传输：AF_UNIX / SOCK_STREAM，路径见 `TranslationServiceSocketPath.defaultPath()`。
//  - 编码：UTF-8 JSON，一行一个对象，以 "\n" 结束（NDJSON）。
//  - 流程：客户端连接后发送一条请求；服务端返回 0 个或多个中间事件，
//    最后一条一定是终止事件（result / error / cancelled），随后服务端关闭连接。
//  - 请求类型：`translate`、`cancel`、`status`、`ping`。
//  - 事件类型：`result`、`error`、`cancelled`、`serviceStatus`、`pong`。
//  - 请求标识：`id` 为字符串（UUID）。服务端只处理与当前连接请求 id 一致的结果；
//    连接已断开或 id 已过期时，迟到的提供方结果一律丢弃，不回写、不复用。
//  - 超时：请求可带 `timeoutSeconds`（默认 30，服务端上限 120）。
//    服务端超时返回 error(timeout)；客户端在服务端超时基础上加 2 秒宽限，
//    客户端超时后立即关闭连接，服务端据此取消在途翻译。
//  - 取消：客户端可发送 `cancel`（含同一 id），也可直接断开连接。
//    两种方式都视为取消，服务端返回或记录 `cancelled`，不产生翻译写回。
//  - 凭据：协议内不传任何 API Key；服务端始终读取自身已配置的提供方与 Keychain。
//

import Foundation

// MARK: - 协议常量

public enum TranslationServiceProtocol {
    /// 协议版本；不兼容变更时递增。
    public static let version = 1
    /// 默认请求超时（秒）。
    public static let defaultTimeoutSeconds: Double = 30
    /// 服务端允许的最大请求超时（秒）。
    public static let maximumTimeoutSeconds: Double = 120
    /// 客户端连接服务的超时（秒）。
    public static let connectTimeoutSeconds: Double = 2
    /// 客户端在服务端超时之外额外容忍的时间（秒）。
    public static let clientTimeoutGraceSeconds: Double = 2
    /// 单条消息的长度上限（字节），避免异常输入占满内存。
    public static let maximumMessageBytes = 64 * 1024

    /// 规范化请求超时：缺省用默认值；非有限值视为非法（返回 nil）；
    /// 有限值统一夹到 `1...maximumTimeoutSeconds`，客户端、resolver 与
    /// Apple 会话必须使用同一规则，避免极大值在转纳秒时溢出。
    public static func normalizedTimeoutSeconds(_ raw: Double?) -> Double? {
        guard let raw else { return defaultTimeoutSeconds }
        guard raw.isFinite else { return nil }
        return min(max(raw, 1), maximumTimeoutSeconds)
    }
}

/// 服务端 socket 路径。服务端与客户端必须使用同一规则。
public enum TranslationServiceSocketPath {
    public static let directoryName = "com.keyi.input-translator"
    public static let fileName = "translation-service.sock"

    /// Workbench 之外的兜底路径使用 uid 区分不同用户。
    public static func defaultPath(fileManager: FileManager = .default) -> String {
        let directory = supportDirectory(fileManager: fileManager)
        let preferred = (directory as NSString).appendingPathComponent(fileName)
        if fitsInSunPath(preferred) {
            return preferred
        }
        return "/tmp/keyi-\(getuid())-translation.sock"
    }

    public static func supportDirectory(fileManager: FileManager = .default) -> String {
        if let url = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            return url.appendingPathComponent(directoryName, isDirectory: true).path
        }
        return (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/\(directoryName)")
    }

    /// macOS 的 `sun_path` 为 104 字节（含结尾 NUL）。
    public static func fitsInSunPath(_ path: String) -> Bool {
        path.utf8.count < 104
    }
}

// MARK: - 线协议消息

public enum TranslationServiceMessageType: String, Codable, Sendable {
    // 请求
    case translate
    case cancel
    case status
    case ping
    /// 语音识别（2026-11-07）：一个连接一段录音。先发 `transcribe`（带 `sampleRate`），
    /// 再连续发 `audio`（`audio` 是 16 位小端单声道 PCM 的 base64），最后发 `finishAudio`。
    case transcribe
    case audio
    case finishAudio
    // 事件
    case result
    case error
    case cancelled
    case serviceStatus
    case pong
    /// 服务接下了这段语音识别；`message` 是识别引擎的显示名。
    case transcriptStarted
    /// 到此刻为止整段的识别文字（`text`），会被后面的整段覆盖。语音识别的终止事件仍是
    /// `result`（`text` 为定稿）或 `error`。
    case transcript

    public var isRequest: Bool {
        switch self {
        case .translate, .cancel, .status, .ping, .transcribe, .audio, .finishAudio: true
        case .result, .error, .cancelled, .serviceStatus, .pong, .transcriptStarted, .transcript: false
        }
    }
}

public enum TranslationServiceErrorCode: String, Codable, Sendable {
    case serviceUnavailable
    case badRequest
    case notConfigured
    case unavailableProvider
    case busy
    case timeout
    case cancelled
    case providerError
    case internalError
}

/// 双向共用的消息体；编码时省略 nil 字段。
public struct TranslationServiceMessage: Codable, Sendable {
    public var version: Int
    public var type: TranslationServiceMessageType
    public var id: String?
    public var text: String?
    public var contextText: String?
    public var providerID: String?
    public var sourceLanguage: String?
    public var targetLanguage: String?
    public var scene: String?
    public var englishStyle: String?
    public var timeoutSeconds: Double?
    public var code: TranslationServiceErrorCode?
    public var message: String?
    public var providerIDs: [String]?
    public var selectedProviderID: String?
    /// 语音识别：一帧 16 位小端单声道 PCM 的 base64（`audio`）。
    public var audio: String?
    /// 语音识别：采样率（`transcribe`）。
    public var sampleRate: Int?

    public init(
        version: Int = TranslationServiceProtocol.version,
        type: TranslationServiceMessageType,
        id: String? = nil,
        text: String? = nil,
        contextText: String? = nil,
        providerID: String? = nil,
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil,
        scene: String? = nil,
        englishStyle: String? = nil,
        timeoutSeconds: Double? = nil,
        code: TranslationServiceErrorCode? = nil,
        message: String? = nil,
        providerIDs: [String]? = nil,
        selectedProviderID: String? = nil,
        audio: String? = nil,
        sampleRate: Int? = nil
    ) {
        self.version = version
        self.type = type
        self.id = id
        self.text = text
        self.contextText = contextText
        self.providerID = providerID
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.scene = scene
        self.englishStyle = englishStyle
        self.timeoutSeconds = timeoutSeconds
        self.code = code
        self.message = message
        self.providerIDs = providerIDs
        self.selectedProviderID = selectedProviderID
        self.audio = audio
        self.sampleRate = sampleRate
    }
}

/// 客户端发起的翻译请求。
public struct TranslationServiceRequest: Sendable {
    public var id: String
    public var text: String
    public var contextText: String?
    /// 留空表示使用伴随应用里已保存的提供方。
    public var providerID: String?
    public var sourceLanguage: String?
    /// 留空表示使用伴随应用里已保存的目标语言。
    public var targetLanguage: String?
    /// 留空表示使用伴随应用里已保存的语气场景。
    public var scene: String?
    /// 留空表示使用伴随应用里已保存的英文风格。
    public var englishStyle: String?
    public var timeoutSeconds: Double

    public init(
        text: String,
        contextText: String? = nil,
        providerID: String? = nil,
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil,
        scene: String? = nil,
        englishStyle: String? = nil,
        timeoutSeconds: Double = TranslationServiceProtocol.defaultTimeoutSeconds,
        id: String = UUID().uuidString
    ) {
        self.id = id
        self.text = text
        self.contextText = contextText
        self.providerID = providerID
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.scene = scene
        self.englishStyle = englishStyle
        self.timeoutSeconds = timeoutSeconds
    }

    public var message: TranslationServiceMessage {
        TranslationServiceMessage(
            type: .translate,
            id: id,
            text: text,
            contextText: contextText,
            providerID: providerID,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            scene: scene,
            englishStyle: englishStyle,
            timeoutSeconds: timeoutSeconds
        )
    }
}

/// 服务可用性报告。
public struct TranslationServiceStatus: Sendable, Equatable {
    public let selectedProviderID: String
    public let providerIDs: [String]

    public init(selectedProviderID: String, providerIDs: [String]) {
        self.selectedProviderID = selectedProviderID
        self.providerIDs = providerIDs
    }
}

// MARK: - 错误

public enum TranslationServiceClientError: Error, LocalizedError, Sendable, Equatable {
    case serviceUnavailable(String)
    case invalidResponse(String)
    case timeout(requestID: String, seconds: Double)
    case cancelled(requestID: String)
    case rejected(code: TranslationServiceErrorCode, message: String)

    public var errorDescription: String? {
        switch self {
        case let .serviceUnavailable(detail):
            "翻译服务未运行或无法连接（\(detail)）"
        case let .invalidResponse(detail):
            "翻译服务返回了无法解析的响应（\(detail)）"
        case let .timeout(_, seconds):
            "翻译请求超时（超过 \(Int(seconds)) 秒）"
        case .cancelled:
            "翻译请求已取消"
        case let .rejected(code, message):
            switch code {
            case .notConfigured: "翻译提供方尚未配置：\(message)"
            case .unavailableProvider: "翻译提供方不可用：\(message)"
            case .busy: "翻译服务忙：\(message)"
            case .badRequest: "翻译请求无效：\(message)"
            default: message
            }
        }
    }
}

// MARK: - 客户端

/// KEYI 翻译服务客户端。
///
/// 每次 `translate` 调用使用独立连接，可安全并发调用。
/// 任务取消时会关闭该连接，服务端据此取消在途翻译。
public final class TranslationServiceClient: @unchecked Sendable {
    public let socketPath: String
    private static let queue = DispatchQueue(
        label: "com.keyi.input-translator.translation-service-client",
        qos: .userInitiated,
        attributes: .concurrent
    )

    public init(socketPath: String = TranslationServiceSocketPath.defaultPath()) {
        self.socketPath = socketPath
    }

    /// 发送翻译请求并等待终止事件。
    public func translate(_ request: TranslationServiceRequest) async throws -> String {
        guard let timeout = TranslationServiceProtocol.normalizedTimeoutSeconds(
            request.timeoutSeconds
        ) else {
            throw TranslationServiceClientError.rejected(
                code: .badRequest,
                message: "超时值无效：\(request.timeoutSeconds)"
            )
        }
        let deadline = Date().timeIntervalSince1970
            + timeout
            + TranslationServiceProtocol.clientTimeoutGraceSeconds
        let connection = try TranslationServiceTransport.connect(
            path: socketPath,
            timeoutSeconds: TranslationServiceProtocol.connectTimeoutSeconds
        )
        let cancellation = TranslationServiceCancellation()
        let payload = try TranslationServiceTransport.encode(request.message)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    defer { connection.close() }
                    do {
                        guard !cancellation.isCancelled else {
                            throw TranslationServiceClientError.cancelled(
                                requestID: request.id
                            )
                        }
                        try TranslationServiceTransport.writeAll(
                            descriptor: connection.descriptor,
                            data: payload,
                            requestID: request.id,
                            cancellation: cancellation
                        )
                        var buffer = Data()
                        while true {
                            if cancellation.isCancelled {
                                throw TranslationServiceClientError.cancelled(
                                    requestID: request.id
                                )
                            }
                            let line = try TranslationServiceTransport.readLine(
                                descriptor: connection.descriptor,
                                buffer: &buffer,
                                deadline: deadline,
                                requestID: request.id,
                                timeout: timeout,
                                cancellation: cancellation
                            )
                            guard let line else {
                                if cancellation.isCancelled {
                                    throw TranslationServiceClientError.cancelled(
                                        requestID: request.id
                                    )
                                }
                                throw TranslationServiceClientError.invalidResponse(
                                    "服务端在返回结果前关闭了连接"
                                )
                            }
                            guard let event = try? TranslationServiceTransport.decode(
                                TranslationServiceMessage.self,
                                from: line
                            ) else {
                                throw TranslationServiceClientError.invalidResponse(
                                    "事件不是合法 JSON"
                                )
                            }
                            try TranslationServiceTransport.validateVersion(event.version)
                            // 过期结果：id 不匹配的事件直接丢弃。
                            guard event.id == nil || event.id == request.id else {
                                continue
                            }
                            switch event.type {
                            case .result:
                                guard let text = event.text else {
                                    throw TranslationServiceClientError.invalidResponse(
                                        "result 事件缺少 text"
                                    )
                                }
                                continuation.resume(returning: text)
                                return
                            case .error:
                                throw TranslationServiceClientError.rejected(
                                    code: event.code ?? .internalError,
                                    message: event.message ?? "未提供错误描述"
                                )
                            case .cancelled:
                                throw TranslationServiceClientError.cancelled(
                                    requestID: request.id
                                )
                            case .serviceStatus, .pong, .translate, .cancel, .status, .ping,
                                 .transcribe, .audio, .finishAudio, .transcriptStarted, .transcript:
                                continue
                            }
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
            connection.shutdown()
        }
    }

    /// 查询服务状态；可用来判断伴随应用是否在运行。
    public func status(timeoutSeconds: Double = 3) async throws -> TranslationServiceStatus {
        let connection = try TranslationServiceTransport.connect(
            path: socketPath,
            timeoutSeconds: TranslationServiceProtocol.connectTimeoutSeconds
        )
        let cancellation = TranslationServiceCancellation()
        let deadline = Date().timeIntervalSince1970 + max(timeoutSeconds, 1)
        let payload = try TranslationServiceTransport.encode(
            TranslationServiceMessage(type: .status)
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    defer { connection.close() }
                    do {
                        try TranslationServiceTransport.writeAll(
                            descriptor: connection.descriptor,
                            data: payload,
                            requestID: "status",
                            cancellation: cancellation
                        )
                        var buffer = Data()
                        while true {
                            let line = try TranslationServiceTransport.readLine(
                                descriptor: connection.descriptor,
                                buffer: &buffer,
                                deadline: deadline,
                                requestID: "status",
                                timeout: timeoutSeconds,
                                cancellation: cancellation
                            )
                            guard let line else {
                                if cancellation.isCancelled {
                                    throw TranslationServiceClientError.cancelled(
                                        requestID: "status"
                                    )
                                }
                                throw TranslationServiceClientError.invalidResponse(
                                    "服务端在返回状态前关闭了连接"
                                )
                            }
                            guard let event = try? TranslationServiceTransport.decode(
                                TranslationServiceMessage.self,
                                from: line
                            ) else {
                                continue
                            }
                            switch event.type {
                            case .serviceStatus:
                                continuation.resume(
                                    returning: TranslationServiceStatus(
                                        selectedProviderID: event.selectedProviderID ?? "",
                                        providerIDs: event.providerIDs ?? []
                                    )
                                )
                                return
                            case .error:
                                throw TranslationServiceClientError.rejected(
                                    code: event.code ?? .internalError,
                                    message: event.message ?? "未提供错误描述"
                                )
                            default:
                                continue
                            }
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
            connection.shutdown()
        }
    }
}

/// 线协议编解码入口：客户端与服务端共用同一份实现。
///
/// `TranslationServiceTransport` 内部同时包含连接与读写逻辑（仅客户端使用），
/// 这里只暴露纯数据的编解码，避免服务端复制一遍 JSON 规则。
public enum TranslationServiceWireCodec {
    public static func encode(_ message: TranslationServiceMessage) throws -> Data {
        try TranslationServiceTransport.encode(message)
    }

    public static func decode(_ data: Data) throws -> TranslationServiceMessage {
        try TranslationServiceTransport.decode(TranslationServiceMessage.self, from: data)
    }

    /// 校验对端协议版本；不匹配时抛 `invalidResponse`。
    public static func validateVersion(_ version: Int) throws {
        try TranslationServiceTransport.validateVersion(version)
    }
}

final class TranslationServiceCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// 连接句柄：关闭只发生在工作线程，取消路径只做 `shutdown`。
final class TranslationServiceTransportConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32
    private var closed = false

    init(descriptor: Int32) {
        value = descriptor
    }

    var descriptor: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func shutdown() {
        lock.lock()
        let descriptor = value
        let isClosed = closed
        lock.unlock()
        guard !isClosed, descriptor >= 0 else { return }
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let descriptor = value
        value = -1
        lock.unlock()
        _ = Darwin.close(descriptor)
    }
}

enum TranslationServiceTransport {
    static let newline = Data([0x0A])

    static func encode(_ message: TranslationServiceMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        var data = try encoder.encode(message)
        guard data.count + 1 <= TranslationServiceProtocol.maximumMessageBytes else {
            throw TranslationServiceClientError.invalidResponse("请求超过长度上限")
        }
        data.append(newline)
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    static func validateVersion(_ version: Int) throws {
        guard version == TranslationServiceProtocol.version else {
            throw TranslationServiceClientError.invalidResponse(
                "协议版本不匹配：服务端 \(version)，客户端 \(TranslationServiceProtocol.version)"
            )
        }
    }

    static func connect(path: String, timeoutSeconds: Double) throws -> TranslationServiceTransportConnection {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            throw TranslationServiceClientError.serviceUnavailable("socket 路径过长")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw TranslationServiceClientError.serviceUnavailable("socket() 失败")
        }
        // 对端已关闭时写入会抛 SIGPIPE 直接终止输入法进程；只在本连接上禁用信号，
        // 不使用全局 signal(SIGPIPE, SIG_IGN)，避免影响输入法其他组件。
        var noSigPipe: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw TranslationServiceClientError.serviceUnavailable(
                "设置 SO_NOSIGPIPE 失败（\(code)）"
            )
        }

        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.connect(
                    descriptor,
                    socketPointer,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        if result != 0 {
            let code = errno
            guard code == EINPROGRESS else {
                _ = Darwin.close(descriptor)
                throw TranslationServiceClientError.serviceUnavailable(
                    String(cString: strerror(code))
                )
            }
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLOUT),
                revents: 0
            )
            let milliseconds = Int32(max(1, timeoutSeconds * 1000))
            let pollResult = Darwin.poll(&pollDescriptor, 1, milliseconds)
            guard pollResult > 0 else {
                _ = Darwin.close(descriptor)
                throw TranslationServiceClientError.serviceUnavailable("连接超时")
            }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            _ = getsockopt(
                descriptor,
                SOL_SOCKET,
                SO_ERROR,
                &socketError,
                &length
            )
            guard socketError == 0 else {
                _ = Darwin.close(descriptor)
                throw TranslationServiceClientError.serviceUnavailable(
                    String(cString: strerror(socketError))
                )
            }
        }
        _ = fcntl(descriptor, F_SETFL, flags)
        return TranslationServiceTransportConnection(descriptor: descriptor)
    }

    static func writeAll(
        descriptor: Int32,
        data: Data,
        requestID: String,
        cancellation: TranslationServiceCancellation
    ) throws {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            if cancellation.isCancelled {
                throw TranslationServiceClientError.cancelled(requestID: requestID)
            }
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
                continue
            }
            if written < 0, errno == EINTR { continue }
            if cancellation.isCancelled {
                throw TranslationServiceClientError.cancelled(requestID: requestID)
            }
            throw TranslationServiceClientError.serviceUnavailable(
                "写入服务请求失败（\(String(cString: strerror(errno)))）"
            )
        }
    }

    /// 读取一行；超时、连接关闭或取消分别抛出对应错误。
    static func readLine(
        descriptor: Int32,
        buffer: inout Data,
        deadline: TimeInterval,
        requestID: String,
        timeout: Double,
        cancellation: TranslationServiceCancellation
    ) throws -> Data? {
        while true {
            if let range = buffer.range(of: newline) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex...range.lowerBound)
                if let line = line.isEmpty ? nil : line { return line }
                continue
            }
            if cancellation.isCancelled {
                throw TranslationServiceClientError.cancelled(requestID: requestID)
            }
            let remaining = deadline - Date().timeIntervalSince1970
            guard remaining > 0 else {
                throw TranslationServiceClientError.timeout(
                    requestID: requestID,
                    seconds: timeout
                )
            }
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            // 最多等 1 秒，让取消信号能及时生效。
            let milliseconds = Int32(min(max(remaining, 0.05) * 1000, 1000))
            let pollResult = Darwin.poll(&pollDescriptor, 1, milliseconds)
            if pollResult == 0 { continue }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw TranslationServiceClientError.serviceUnavailable(
                    "读取服务响应失败"
                )
            }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                guard buffer.count <= TranslationServiceProtocol.maximumMessageBytes else {
                    throw TranslationServiceClientError.invalidResponse("响应超过长度上限")
                }
            } else if count == 0 {
                return nil
            } else if errno != EINTR {
                if cancellation.isCancelled {
                    throw TranslationServiceClientError.cancelled(requestID: requestID)
                }
                throw TranslationServiceClientError.serviceUnavailable(
                    "读取服务响应失败"
                )
            }
        }
    }
}
