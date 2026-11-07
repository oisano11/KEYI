import Foundation
import KEYICore
import Network

// 阿里云 Fun-ASR 客户端对着本机的假 WebSocket 服务跑：检查鉴权头、run-task 字段、音频原样送出、
// finish-task、按句拼整段、task-failed 的处理和 verify。真阿里云只在 KEYI_NETWORK_CHECKS=1 时
// 用一把假 Key 试握手被拒（不送音频）。

private final class FakeFunASRServer: @unchecked Sendable {
    enum Behavior {
        case transcribe
        case failTask
    }

    private let queue = DispatchQueue(label: "keyi.checks.fake-fun-asr")
    private let lock = NSLock()
    private let listener: NWListener
    private let behavior: Behavior
    private let headerBox: HeaderBox
    private var runTaskObject: [String: Any]?
    private var audio = Data()
    private var finishReceived = false
    private var partialAfterAudioSent = false
    private var connections: [NWConnection] = []

    init(_ behavior: Behavior) throws {
        self.behavior = behavior
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        // 握手时记下鉴权头（要在建 listener 之前设好）。
        let headerBox = HeaderBox()
        websocket.setClientRequestHandler(queue) { _, headers in
            headerBox.set(headers.first { $0.name.lowercased() == "authorization" }?.value)
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        self.headerBox = headerBox
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.lock()
            self.connections.append(connection)
            self.lock.unlock()
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }
        listener.start(queue: queue)
    }

    var port: UInt16? { listener.port?.rawValue }
    var authorization: String? { headerBox.value }
    var runTask: [String: Any]? { lock.lock(); defer { lock.unlock() }; return runTaskObject }
    var receivedAudio: Data { lock.lock(); defer { lock.unlock() }; return audio }
    var gotFinish: Bool { lock.lock(); defer { lock.unlock() }; return finishReceived }

    func stop() {
        listener.cancel()
        lock.lock()
        let all = connections
        lock.unlock()
        all.forEach { $0.cancel() }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .text?:
                self.handleText(data ?? Data(), on: connection)
            case .binary?:
                self.lock.lock()
                self.audio.append(data ?? Data())
                let first = !self.partialAfterAudioSent
                self.partialAfterAudioSent = true
                self.lock.unlock()
                if first { self.sendSentence(id: 2, text: "hello", end: false, on: connection) }
            default:
                break
            }
            self.receive(on: connection)
        }
    }

    private func handleText(_ data: Data, on connection: NWConnection) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = object["header"] as? [String: Any],
              let action = header["action"] as? String
        else { return }
        let taskID = header["task_id"] as? String ?? ""
        switch action {
        case "run-task":
            lock.lock()
            runTaskObject = object
            lock.unlock()
            if behavior == .failTask {
                send([
                    "header": ["task_id": taskID, "event": "task-failed", "error_code": "InvalidParameter",
                               "error_message": "bad model", "attributes": [String: Any]()],
                    "payload": [String: Any]()
                ], on: connection)
                return
            }
            send(["header": ["task_id": taskID, "event": "task-started", "attributes": [String: Any]()],
                  "payload": [String: Any]()], on: connection)
            sendSentence(id: 1, text: "你好", end: false, on: connection)
            sendSentence(id: 1, text: "你好。", end: true, on: connection)
            // 心跳包不算文字。
            send(["header": ["task_id": taskID, "event": "result-generated", "attributes": [String: Any]()],
                  "payload": ["output": ["sentence": ["heartbeat": true, "sentence_id": 0, "text": "", "sentence_end": false]]]],
                 on: connection)
        case "finish-task":
            lock.lock()
            finishReceived = true
            lock.unlock()
            sendSentence(id: 2, text: "Hello world.", end: true, on: connection)
            send(["header": ["task_id": taskID, "event": "task-finished", "attributes": [String: Any]()],
                  "payload": ["output": [String: Any]()]], on: connection)
        default:
            break
        }
    }

    private func sendSentence(id: Int, text: String, end: Bool, on connection: NWConnection) {
        send([
            "header": ["task_id": "t", "event": "result-generated", "attributes": [String: Any]()],
            "payload": ["output": ["sentence": ["begin_time": 0, "text": text, "heartbeat": false,
                                                "sentence_end": end, "sentence_id": id, "words": [Any]()]]]
        ], on: connection)
    }

    private func send(_ object: [String: Any], on connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}

private final class HeaderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    func set(_ value: String?) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class FunASREventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AliyunFunASRStream.Event] = []

    func append(_ event: AliyunFunASRStream.Event) {
        lock.lock()
        items.append(event)
        lock.unlock()
    }

    var events: [AliyunFunASRStream.Event] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    var terminal: AliyunFunASRStream.Event? {
        events.last { event in
            switch event {
            case .final, .failed: true
            case .started, .partial: false
            }
        }
    }
}

private func waitFor(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func readyServer(_ behavior: FakeFunASRServer.Behavior) async throws -> (FakeFunASRServer, URL) {
    let server = try FakeFunASRServer(behavior)
    _ = await waitFor { server.port != nil && server.port != 0 }
    guard let port = server.port, let url = URL(string: "ws://127.0.0.1:\(port)/api-ws/v1/inference") else {
        fatalError("假 Fun-ASR 服务没起来")
    }
    return (server, url)
}

func runAliyunFunASRChecks() async throws -> Int {
    var checks = 0
    func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { fatalError(message) }
    }

    check(AliyunFunASRStream.join(["你好。", "Hello world."]) == "你好。Hello world.", "中文句后接英文不加空格")
    check(AliyunFunASRStream.join(["hello", "world"]) == "hello world", "两句英文之间补一个空格")
    check(AliyunFunASRStream.join(["今天", "", "下午"]) == "今天下午", "空句跳过")
    check(AliyunFunASRConfiguration.endpointURL("https://dashscope.aliyuncs.com") == nil, "地址只认 ws/wss")
    check(AliyunFunASRConfiguration.endpointURL(AliyunFunASRConfiguration.defaultEndpoint) != nil, "默认地址可用")

    // 正常一段：鉴权头、run-task、task-started 前送的音频也到、按句拼整段、finish-task、task-finished。
    do {
        let (server, url) = try await readyServer(.transcribe)
        defer { server.stop() }
        let log = FunASREventLog()
        let stream = AliyunFunASRStream(
            configuration: AliyunFunASRConfiguration(apiKey: "test-key", endpoint: url),
            sampleRate: 16000
        ) { log.append($0) }
        stream.start()
        let early = Data((0..<3200).map { UInt8($0 % 249) })
        stream.append(early)
        _ = await waitFor { log.events.contains(.started) }
        check(log.events.first == .started, "先报 task-started")
        let later = Data((0..<1600).map { UInt8(($0 * 3) % 241) })
        stream.append(later)
        _ = await waitFor { log.events.contains(.partial("你好。hello")) }
        check(log.events.contains(.partial("你好")) && log.events.contains(.partial("你好。hello")),
              "中间结果按句拼成整段")
        stream.finish()
        _ = await waitFor { log.terminal != nil }
        check(log.terminal == .final("你好。Hello world."), "task-finished 后给整段定稿")
        check(server.authorization == "Bearer test-key", "鉴权头是 Bearer <Key>")
        check(server.receivedAudio == early + later, "task-started 前后的音频都按顺序原样送出")
        check(server.gotFinish, "音频完了发 finish-task")
        let header = server.runTask?["header"] as? [String: Any]
        let payload = server.runTask?["payload"] as? [String: Any]
        let parameters = payload?["parameters"] as? [String: Any]
        check(header?["action"] as? String == "run-task" && header?["streaming"] as? String == "duplex",
              "run-task 的 header")
        check((header?["task_id"] as? String)?.count == 32, "task_id 是 32 位")
        check(payload?["model"] as? String == "fun-asr-realtime" && payload?["task"] as? String == "asr"
                && payload?["task_group"] as? String == "audio" && payload?["function"] as? String == "recognition",
              "run-task 的模型与任务")
        check(parameters?["format"] as? String == "pcm" && parameters?["sample_rate"] as? Int == 16000,
              "音频是 16 kHz PCM")
    }

    // 阿里云回 task-failed：报 service 错误和原因。
    do {
        let (server, url) = try await readyServer(.failTask)
        defer { server.stop() }
        let log = FunASREventLog()
        let stream = AliyunFunASRStream(
            configuration: AliyunFunASRConfiguration(apiKey: "test-key", endpoint: url),
            sampleRate: 16000
        ) { log.append($0) }
        stream.start()
        _ = await waitFor { log.terminal != nil }
        check(log.terminal == .failed(.service(code: "InvalidParameter", message: "bad model")), "task-failed 报原因")
        let failure = await AliyunFunASRStream.verify(AliyunFunASRConfiguration(apiKey: "test-key", endpoint: url))
        check(failure == .service(code: "InvalidParameter", message: "bad model"), "验证时如实报阿里云的错")
    }

    // 验证：等到 task-started 就算能用，不送音频。
    do {
        let (server, url) = try await readyServer(.transcribe)
        defer { server.stop() }
        let failure = await AliyunFunASRStream.verify(AliyunFunASRConfiguration(apiKey: "test-key", endpoint: url))
        check(failure == nil, "能接下任务就算验证通过")
        check(server.receivedAudio.isEmpty, "验证不送音频")
    }

    // 连不上：network。
    do {
        let failure = await AliyunFunASRStream.verify(
            AliyunFunASRConfiguration(apiKey: "test-key", endpoint: URL(string: "ws://127.0.0.1:9/none")!)
        )
        if case .network? = failure { check(true, "") } else { check(false, "连不上时报 network") }
    }

    if ProcessInfo.processInfo.environment["KEYI_NETWORK_CHECKS"] == "1" {
        let failure = await AliyunFunASRStream.verify(
            AliyunFunASRConfiguration(
                apiKey: "sk-keyi-invalid-check",
                endpoint: URL(string: AliyunFunASRConfiguration.defaultEndpoint)!
            )
        )
        check(failure == .unauthorized, "真阿里云：假 Key 握手被拒，报 Key 不对（实际 \(String(describing: failure))）")
        print("aliyun network check: invalid key -> \(String(describing: failure))")
    }

    return checks
}
