import Foundation

// 豆包（火山引擎）流式语音识别模型 2.0（契约「2026-11-07 云端语音识别授权」的补充）。
// WebSocket 上跑豆包自己的二进制帧：4 字节头（版本与头长、消息类型与标志、序列化与压缩、保留）
// + 4 字节大端长度 + 负载。连上后先发 full client request（JSON 参数），再一包包发 audio only
// request（16 位单声道 PCM），最后一包的标志设成 0b0010。服务端结果有变化时回 full server
// response（`result.text` 是到此刻的整段），标志带 0b0010 的那包就是定稿；出错回 0b1111 错误帧
// （4 字节错误码 + 4 字节长度 + 信息）。新版控制台鉴权只要 `X-Api-Key`。
// 文档：docs.volcengine.com/docs/doubao-voice/large-model-streaming-automatic-speech-recognition-api-1
// 与 …/bidirectional-streaming-automatic-speech-recognition-websocket（2026-11-07 读）。

public struct DoubaoASRConfiguration: Sendable, Equatable {
    /// 双向流式优化版：只在结果变化时回包；二遍识别只有这条链路支持。
    public static let defaultEndpoint = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    /// 豆包流式语音识别模型 2.0 小时版。
    public static let defaultResourceID = "volc.seedasr.sauc.duration"
    public static let displayName = "豆包语音识别"

    public var apiKey: String
    public var endpoint: URL
    public var resourceID: String

    public init(
        apiKey: String,
        endpoint: URL = URL(string: Self.defaultEndpoint)!,
        resourceID: String = Self.defaultResourceID
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.resourceID = resourceID
    }
}

/// 豆包二进制帧的编解码。整数一律大端。
public enum DoubaoASRFrame {
    public enum ServerMessage: Equatable, Sendable {
        /// full server response；`payload` 已解压，是 JSON。
        case response(sequence: Int32?, isLast: Bool, payload: Data)
        /// 错误帧。
        case error(code: UInt32, message: String)
        /// 其他类型（如 ACK），不用管。
        case other
    }

    static let fullClientRequest: UInt8 = 0b0001
    static let audioOnlyRequest: UInt8 = 0b0010
    static let fullServerResponse: UInt8 = 0b1001
    static let errorResponse: UInt8 = 0b1111
    /// 标志：头后 4 字节是序号。
    static let hasSequence: UInt8 = 0b0001
    /// 标志：最后一包（负包）。
    static let lastPacket: UInt8 = 0b0010

    /// 第一帧：JSON 参数，不压缩。
    public static func clientRequest(_ json: Data) -> Data {
        frame(type: fullClientRequest, flags: 0, serialization: 1, compression: 0, payload: json)
    }

    /// 一包音频（原样 PCM，不压缩）；`last` 时标成最后一包。
    public static func audio(_ pcm16: Data, last: Bool) -> Data {
        frame(type: audioOnlyRequest, flags: last ? lastPacket : 0, serialization: 0, compression: 0, payload: pcm16)
    }

    /// 拼一帧；`prefix` 放在长度之前（服务端回包的序号、错误帧的错误码）。本机检查也用它造服务端的帧。
    public static func frame(
        type: UInt8,
        flags: UInt8,
        serialization: UInt8,
        compression: UInt8,
        prefix: [UInt32] = [],
        payload: Data
    ) -> Data {
        var data = Data([0x11, type << 4 | (flags & 0x0F), serialization << 4 | (compression & 0x0F), 0x00])
        for value in prefix { data.append(contentsOf: bigEndian(value)) }
        data.append(contentsOf: bigEndian(UInt32(payload.count)))
        data.append(payload)
        return data
    }

    public static func parse(_ data: Data) -> ServerMessage? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let headerSize = Int(bytes[0] & 0x0F) * 4
        guard headerSize >= 4, bytes.count >= headerSize else { return nil }
        let type = bytes[1] >> 4
        let flags = bytes[1] & 0x0F
        let compressed = bytes[2] & 0x0F == 1
        var offset = headerSize

        func readUInt32() -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            let value = bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            offset += 4
            return value
        }

        func readPayload() -> Data? {
            guard let size = readUInt32(), offset + Int(size) <= bytes.count else { return nil }
            let raw = Data(bytes[offset..<offset + Int(size)])
            offset += Int(size)
            return compressed ? gunzip(raw) : raw
        }

        switch type {
        case fullServerResponse:
            var sequence: Int32?
            if flags & hasSequence != 0 {
                guard let raw = readUInt32() else { return nil }
                sequence = Int32(bitPattern: raw)
            }
            guard let payload = readPayload() else { return nil }
            let isLast = flags & lastPacket != 0 || (sequence ?? 0) < 0
            return .response(sequence: sequence, isLast: isLast, payload: payload)
        case errorResponse:
            guard let code = readUInt32(), let payload = readPayload() else { return nil }
            return .error(code: code, message: errorText(payload))
        default:
            return .other
        }
    }

    /// 回包里到此刻为止的整段文字；没有 `result` 时为 nil。
    public static func text(fromResponse payload: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        if let result = object["result"] as? [String: Any] {
            return result["text"] as? String
        }
        if let results = object["result"] as? [[String: Any]] {
            return results.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }

    /// 错误信息可能是 JSON（`error` / `message`），也可能是纯文字。
    static func errorText(_ payload: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
            for key in ["error", "message", "msg"] {
                if let text = object[key] as? String, !text.isEmpty { return text }
            }
        }
        return String(decoding: payload, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 服务端按客户端的压缩方式回包（我们不压缩）；万一回了 gzip 也能解开。
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {
            guard index + 2 <= bytes.count else { return nil }
            index += 2 + (Int(bytes[index]) | (Int(bytes[index + 1]) << 8))
        }
        if flags & 0x08 != 0 {
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x10 != 0 {
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 }
        guard index <= bytes.count - 8 else { return nil }
        let deflated = Data(bytes[index..<(bytes.count - 8)])
        return try? (deflated as NSData).decompressed(using: .zlib) as Data
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}

public final class DoubaoASRStream: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// 握手被拒 401：Key 不对。
        case unauthorized
        /// 握手被拒的其他情况（多半是没开通流式语音识别 2.0 或额度用完）；`message` 来自 `X-Api-Message`。
        case rejected(status: Int, message: String)
        /// 连不上、断了。
        case network(String)
        /// 豆包回了错误帧。
        case service(code: UInt32, message: String)
        /// 迟迟没有回应。
        case timeout

        public var message: String {
            switch self {
            case .unauthorized:
                "豆包拒绝了这个 API Key"
            case let .rejected(status, message):
                "豆包拒绝了请求（\(message.isEmpty ? "HTTP \(status)" : message)），看看控制台里流式语音识别 2.0 开通了没有、额度还有没有"
            case let .network(detail):
                "连不上豆包（\(detail)）"
            case let .service(code, message):
                "豆包报错：\(Self.describe(code: code, fallback: message))"
            case .timeout:
                "豆包没有回应"
            }
        }

        /// 文档列出的错误码（2026-08-06 版）。
        static func describe(code: UInt32, fallback: String) -> String {
            let known: [UInt32: String] = [
                45_000_001: "请求参数无效",
                45_000_002: "空音频",
                45_000_081: "等包超时",
                45_000_151: "音频格式不正确",
                55_000_031: "服务器繁忙"
            ]
            if let text = known[code] { return fallback.isEmpty ? text : "\(text)（\(fallback)）" }
            return fallback.isEmpty ? "错误码 \(code)" : "\(fallback)（\(code)）"
        }
    }

    public enum Event: Sendable, Equatable {
        /// 握手成功，Key 被接受。
        case started
        /// 到此刻为止的整段文字。
        case partial(String)
        /// 最后一包的回应：整段定稿。
        case final(String)
        case failed(Failure)
    }

    /// 连上（握手完成）最多等多久。
    public static let startTimeout: TimeInterval = 8
    /// 发出最后一包之后等定稿最多多久；超时按已有的文字定稿。
    public static let finishTimeout: TimeInterval = 5
    /// 验证时连上后再等这么久看有没有错误帧；豆包只在结果变化时回包，没回包也算能用。
    static let verifyGrace: TimeInterval = 1.5

    private let configuration: DoubaoASRConfiguration
    private let sampleRate: Int
    private let events: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "com.keyi.doubao-asr")
    private let requestID = UUID().uuidString.lowercased()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var opened = false
    private var finishRequested = false
    private var ended = false
    /// 最后一包要带标志，所以总扣着最新的一包，下一包来了才把它送出去。
    private var held: Data?
    private var sentAudio = false
    private var latestText = ""

    /// `events` 在内部串行队列上调用；最后一个必是 `.final` 或 `.failed`，`cancel()` 后不再调用。
    public init(
        configuration: DoubaoASRConfiguration,
        sampleRate: Int,
        events: @escaping @Sendable (Event) -> Void
    ) {
        self.configuration = configuration
        self.sampleRate = sampleRate
        self.events = events
    }

    public func start() {
        queue.async { [self] in
            guard !ended, task == nil else { return }
            var request = URLRequest(url: configuration.endpoint, timeoutInterval: Self.startTimeout)
            request.setValue(configuration.apiKey, forHTTPHeaderField: "X-Api-Key")
            request.setValue(configuration.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
            request.setValue(requestID, forHTTPHeaderField: "X-Api-Request-Id")
            request.setValue(requestID, forHTTPHeaderField: "X-Api-Connect-Id")
            request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
            request.setValue("KEYI", forHTTPHeaderField: "User-Agent")
            let delegateQueue = OperationQueue()
            delegateQueue.underlyingQueue = queue
            delegateQueue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: delegateQueue)
            let task = session.webSocketTask(with: request)
            self.session = session
            self.task = task
            task.resume()
            // 握手完成前发的帧由 URLSession 排着，顺序不变。
            send(DoubaoASRFrame.clientRequest(requestJSON()))
            receive()
            queue.asyncAfter(deadline: .now() + Self.startTimeout) { [weak self] in
                guard let self, !self.ended, !self.opened else { return }
                self.fail(.timeout)
            }
        }
    }

    /// 一帧 16 位小端单声道 PCM。
    public func append(_ pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        queue.async { [self] in
            guard !ended, !finishRequested else { return }
            if let held { sendAudio(held, last: false) }
            held = pcm16
        }
    }

    public func finish() {
        queue.async { [self] in
            guard !ended, !finishRequested else { return }
            finishRequested = true
            if let held {
                sendAudio(held, last: true)
                self.held = nil
            } else if sentAudio {
                sendAudio(Data(), last: true)
            } else {
                // 一点声音都没有：不用等豆包。
                end(with: .final(""))
                return
            }
            queue.asyncAfter(deadline: .now() + Self.startTimeout + Self.finishTimeout) { [weak self] in
                guard let self, !self.ended else { return }
                // 迟迟没有定稿：按已经识别出的整段定稿。
                self.end(with: .final(self.latestText))
            }
        }
    }

    public func cancel() {
        queue.async { [self] in
            guard !ended else { return }
            ended = true
            close()
        }
    }

    /// 只验证 Key 能不能用：握手成功后再等一会儿看有没有错误帧，然后断开（不送音频，不计费）。
    public static func verify(_ configuration: DoubaoASRConfiguration) async -> Failure? {
        await withCheckedContinuation { continuation in
            let box = DoubaoVerifyBox(continuation)
            let stream = DoubaoASRStream(configuration: configuration, sampleRate: 16000) { event in
                switch event {
                case .started:
                    DispatchQueue.global().asyncAfter(deadline: .now() + verifyGrace) { box.resume(nil) }
                case .partial, .final:
                    box.resume(nil)
                case let .failed(failure):
                    box.resume(failure)
                }
            }
            box.stream = stream
            stream.start()
        }
    }

    // MARK: - 帧

    private func requestJSON() -> Data {
        let object: [String: Any] = [
            "user": ["uid": "keyi"],
            "audio": ["format": "pcm", "codec": "raw", "rate": sampleRate, "bits": 16, "channel": 1],
            "request": [
                "model_name": "bigmodel",
                // 二遍识别：说完一句（静音 800 毫秒）后整句重认一遍，定稿更准。
                "enable_nonstream": true,
                "enable_itn": true,
                "enable_punc": true,
                "result_type": "full"
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private func sendAudio(_ pcm16: Data, last: Bool) {
        sentAudio = true
        send(DoubaoASRFrame.audio(pcm16, last: last))
    }

    private func send(_ frame: Data) {
        task?.send(.data(frame)) { [weak self] error in
            guard let error, let self else { return }
            self.queue.async { self.fail(self.networkFailure(error)) }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.ended else { return }
                switch result {
                case let .success(message):
                    if case let .data(data) = message { self.handle(data) }
                    if !self.ended { self.receive() }
                case let .failure(error):
                    self.fail(self.networkFailure(error))
                }
            }
        }
    }

    private func handle(_ data: Data) {
        switch DoubaoASRFrame.parse(data) {
        case let .response(_, isLast, payload)?:
            if let text = DoubaoASRFrame.text(fromResponse: payload), text != latestText {
                latestText = text
                if !isLast { events(.partial(text)) }
            }
            if isLast { end(with: .final(latestText)) }
        case let .error(code, message)?:
            fail(.service(code: code, message: message))
        case .other?, nil:
            break
        }
    }

    private func networkFailure(_ error: Error) -> Failure {
        if let response = task?.response as? HTTPURLResponse, response.statusCode != 101 {
            if response.statusCode == 401 { return .unauthorized }
            let message = response.value(forHTTPHeaderField: "X-Api-Message") ?? ""
            return .rejected(status: response.statusCode, message: message)
        }
        return .network(error.localizedDescription)
    }

    private func fail(_ failure: Failure) {
        end(with: .failed(failure))
    }

    private func end(with event: Event) {
        guard !ended else { return }
        ended = true
        events(event)
        close()
    }

    private func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        held = nil
    }

    // MARK: - URLSessionWebSocketDelegate

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        guard !ended, !opened else { return }
        opened = true
        events(.started)
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard !ended else { return }
        // 发完最后一包后对方关了连接：按已有的文字定稿。
        if finishRequested {
            end(with: .final(latestText))
        } else {
            fail(.network("连接被关闭"))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !ended, let error else { return }
        fail(networkFailure(error))
    }
}

/// `verify` 用：只放行第一次结果，然后断开。
private final class DoubaoVerifyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DoubaoASRStream.Failure?, Never>?
    var stream: DoubaoASRStream?

    init(_ continuation: CheckedContinuation<DoubaoASRStream.Failure?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: DoubaoASRStream.Failure?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let stream = self.stream
        self.stream = nil
        lock.unlock()
        stream?.cancel()
        continuation?.resume(returning: value)
    }
}
