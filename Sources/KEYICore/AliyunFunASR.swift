import Foundation

// 阿里云百炼 Fun-ASR 实时语音识别（契约「2026-11-07 云端语音识别授权」）。
// WebSocket 双工：连上后发 run-task，收到 task-started 再发二进制音频（16 位单声道 PCM），
// 音频完了发 finish-task，收到 task-finished 结束。识别结果按句（sentence_id）给，
// 句中是中间结果、sentence_end 为 true 时是这句的定稿；整段 = 各句按序拼起来。
// 文档：help.aliyun.com/zh/model-studio/fun-asr-realtime-websocket-api（2026-11-07 读）。

public struct AliyunFunASRConfiguration: Sendable, Equatable {
    /// 北京地域（华北2）。新加坡地域用 `wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference`。
    public static let defaultEndpoint = "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
    public static let defaultModel = "fun-asr-realtime"
    public static let displayName = "阿里云 Fun-ASR"

    public var apiKey: String
    public var endpoint: URL
    public var model: String

    public init(apiKey: String, endpoint: URL, model: String = Self.defaultModel) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
    }

    /// 服务地址只认 ws/wss。
    public static func endpointURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "wss" || scheme == "ws", url.host?.isEmpty == false
        else { return nil }
        return url
    }
}

public final class AliyunFunASRStream: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// 握手被拒（401/403）：Key 不对或没开通。
        case unauthorized
        /// 连不上、断了。
        case network(String)
        /// 阿里云回了 task-failed。
        case service(code: String, message: String)
        /// 迟迟没有回应。
        case timeout

        public var message: String {
            switch self {
            case .unauthorized: "阿里云拒绝了这个 API Key"
            case let .network(detail): "连不上阿里云（\(detail)）"
            case let .service(code, message): "阿里云报错：\(message.isEmpty ? code : message)"
            case .timeout: "阿里云没有回应"
            }
        }
    }

    public enum Event: Sendable, Equatable {
        /// task-started：可以送音频了。
        case started
        /// 到此刻为止的整段文字。
        case partial(String)
        /// task-finished 后的整段定稿。
        case final(String)
        case failed(Failure)
    }

    /// 连上到 task-started 最多等多久。
    public static let startTimeout: TimeInterval = 8
    /// finish-task 之后等 task-finished 最多多久；超时按已有的文字定稿。
    public static let finishTimeout: TimeInterval = 5

    private let configuration: AliyunFunASRConfiguration
    private let sampleRate: Int
    private let events: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "com.keyi.aliyun-fun-asr")
    private let taskID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var started = false
    private var finishRequested = false
    private var finishSent = false
    private var ended = false
    private var pending: [Data] = []
    private var sentences: [Int: String] = [:]
    private var lastPartial = ""

    /// `events` 在内部串行队列上调用；最后一个必是 `.final` 或 `.failed`，`cancel()` 后不再调用。
    public init(
        configuration: AliyunFunASRConfiguration,
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
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("KEYI", forHTTPHeaderField: "User-Agent")
            let delegateQueue = OperationQueue()
            delegateQueue.underlyingQueue = queue
            delegateQueue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: delegateQueue)
            let task = session.webSocketTask(with: request)
            self.session = session
            self.task = task
            task.resume()
            sendText(runTaskJSON())
            receive()
            queue.asyncAfter(deadline: .now() + Self.startTimeout) { [weak self] in
                guard let self, !self.ended, !self.started else { return }
                self.fail(.timeout)
            }
        }
    }

    /// 一帧 16 位小端单声道 PCM；task-started 之前先排着。
    public func append(_ pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        queue.async { [self] in
            guard !ended, !finishRequested else { return }
            if started {
                task?.send(.data(pcm16)) { _ in }
            } else {
                pending.append(pcm16)
            }
        }
    }

    public func finish() {
        queue.async { [self] in
            guard !ended, !finishRequested else { return }
            finishRequested = true
            if started { sendFinish() }
            queue.asyncAfter(deadline: .now() + Self.startTimeout + Self.finishTimeout) { [weak self] in
                guard let self, !self.ended else { return }
                // 迟迟没有 task-finished：按已经识别出的整段定稿。
                self.end(with: .final(self.transcript()))
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

    /// 只验证 Key 和地址能不能用：等到 task-started 就断开（不送音频，不计费）。
    public static func verify(_ configuration: AliyunFunASRConfiguration) async -> Failure? {
        await withCheckedContinuation { continuation in
            let box = VerifyBox(continuation)
            let stream = AliyunFunASRStream(configuration: configuration, sampleRate: 16000) { event in
                switch event {
                case .started: box.resume(nil)
                case let .failed(failure): box.resume(failure)
                case .partial, .final: break
                }
            }
            box.stream = stream
            stream.start()
        }
    }

    // MARK: - 消息

    private func runTaskJSON() -> String {
        let message: [String: Any] = [
            "header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": configuration.model,
                "parameters": ["format": "pcm", "sample_rate": sampleRate],
                "input": [String: Any]()
            ]
        ]
        return Self.json(message)
    }

    private func sendFinish() {
        guard !finishSent else { return }
        finishSent = true
        let message: [String: Any] = [
            "header": ["action": "finish-task", "task_id": taskID, "streaming": "duplex"],
            "payload": ["input": [String: Any]()]
        ]
        sendText(Self.json(message))
    }

    private func sendText(_ text: String) {
        task?.send(.string(text)) { [weak self] error in
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
                    switch message {
                    case let .string(text): self.handle(Data(text.utf8))
                    case let .data(data): self.handle(data)
                    @unknown default: break
                    }
                    if !self.ended { self.receive() }
                case let .failure(error):
                    self.fail(self.networkFailure(error))
                }
            }
        }
    }

    private func handle(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = object["header"] as? [String: Any],
              let event = header["event"] as? String
        else { return }
        switch event {
        case "task-started":
            guard !started else { return }
            started = true
            events(.started)
            for frame in pending { task?.send(.data(frame)) { _ in } }
            pending.removeAll()
            if finishRequested { sendFinish() }
        case "result-generated":
            guard let payload = object["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any]
            else { return }
            if sentence["heartbeat"] as? Bool == true { return }
            let id = (sentence["sentence_id"] as? Int) ?? sentences.keys.max() ?? 1
            sentences[id] = (sentence["text"] as? String) ?? ""
            let text = transcript()
            guard text != lastPartial else { return }
            lastPartial = text
            events(.partial(text))
        case "task-finished":
            end(with: .final(transcript()))
        case "task-failed":
            let code = header["error_code"] as? String ?? ""
            let message = header["error_message"] as? String ?? ""
            fail(.service(code: code, message: message))
        default:
            break
        }
    }

    /// 各句按序拼起来；两边都是英文字母或数字时中间补一个空格。
    func transcript() -> String {
        Self.join(sentences.keys.sorted().compactMap { sentences[$0] })
    }

    public static func join(_ parts: [String]) -> String {
        var result = ""
        for part in parts where !part.isEmpty {
            if let last = result.last, let first = part.first,
               last.isASCII, first.isASCII, (last.isLetter || last.isNumber), (first.isLetter || first.isNumber) {
                result.append(" ")
            }
            result.append(part)
        }
        return result
    }

    private func networkFailure(_ error: Error) -> Failure {
        if let response = task?.response as? HTTPURLResponse, [401, 403].contains(response.statusCode) {
            return .unauthorized
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
        pending.removeAll()
    }

    // MARK: - URLSessionWebSocketDelegate

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard !ended else { return }
        fail(.network("连接被关闭"))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !ended, let error else { return }
        fail(networkFailure(error))
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}

/// `verify` 用：只放行第一次结果，然后断开。
private final class VerifyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AliyunFunASRStream.Failure?, Never>?
    var stream: AliyunFunASRStream?

    init(_ continuation: CheckedContinuation<AliyunFunASRStream.Failure?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: AliyunFunASRStream.Failure?) {
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
