import Foundation
import KEYICore
import Network

// 豆包流式语音识别客户端对着本机的假 WebSocket 服务跑：检查二进制帧编解码、鉴权头、参数包、
// 音频按序分包且只有最后一包带标志、gzip 回包、整段文字、错误帧、握手被拒和 verify。
// 真豆包只在 KEYI_NETWORK_CHECKS=1 时用一把假 Key 试握手被拒（不送音频）。

private final class FakeDoubaoServer: @unchecked Sendable {
    enum Behavior {
        case transcribe
        case errorFrame
    }

    struct Packet {
        var flags: UInt8
        var payload: Data
    }

    private let queue = DispatchQueue(label: "keyi.checks.fake-doubao")
    private let lock = NSLock()
    private let listener: NWListener
    private let behavior: Behavior
    private let headerStore: DoubaoHeaderStore
    private var requestHeaderBytes: [UInt8] = []
    private var requestObject: [String: Any]?
    private var packets: [Packet] = []
    private var connections: [NWConnection] = []

    init(_ behavior: Behavior) throws {
        self.behavior = behavior
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        // 握手时记下请求头（要在建 listener 之前设好）。
        let store = DoubaoHeaderStore()
        websocket.setClientRequestHandler(queue) { _, headers in
            store.set(headers)
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        headerStore = store
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
    func header(_ name: String) -> String? { headerStore.value(name) }
    var requestHeader: [UInt8] { lock.lock(); defer { lock.unlock() }; return requestHeaderBytes }
    var request: [String: Any]? { lock.lock(); defer { lock.unlock() }; return requestObject }
    var audioPackets: [Packet] { lock.lock(); defer { lock.unlock() }; return packets }

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
            if metadata?.opcode == .binary, let data {
                self.handle(data, on: connection)
            }
            self.receive(on: connection)
        }
    }

    private func handle(_ data: Data, on connection: NWConnection) {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return }
        let type = bytes[1] >> 4
        let flags = bytes[1] & 0x0F
        let size = bytes[4..<8].reduce(0) { $0 << 8 | Int($1) }
        guard bytes.count >= 8 + size else { return }
        let payload = Data(bytes[8..<(8 + size)])
        switch type {
        case 0b0001:
            lock.lock()
            requestHeaderBytes = Array(bytes[0..<4])
            requestObject = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
            lock.unlock()
            switch behavior {
            case .transcribe:
                // 回应参数包：还没有识别结果。
                respond(sequence: 1, last: false, json: ["audio_info": ["duration": 0]], on: connection)
            case .errorFrame:
                let frame = DoubaoASRFrame.frame(
                    type: 0b1111, flags: 0, serialization: 1, compression: 0,
                    prefix: [45_000_151], payload: Data(#"{"error":"bad audio"}"#.utf8)
                )
                send(frame, on: connection)
            }
        case 0b0010:
            lock.lock()
            packets.append(Packet(flags: flags, payload: payload))
            let count = packets.count
            lock.unlock()
            if flags & 0b0010 != 0 {
                respond(sequence: -Int32(count + 1), last: true,
                        json: ["result": ["text": "你好，Hello world。"]], on: connection)
            } else if count == 1 {
                // 第一包的结果用 gzip 回，检查客户端能解开。
                respond(sequence: 2, last: false, json: ["result": ["text": "你好"]], gzip: true, on: connection)
            } else if count == 2 {
                // result 偶尔是数组。
                respond(sequence: 3, last: false, json: ["result": [["text": "你好，hello"]]], on: connection)
            }
        default:
            break
        }
    }

    private func respond(sequence: Int32, last: Bool, json: [String: Any], gzip: Bool = false, on connection: NWConnection) {
        guard let body = try? JSONSerialization.data(withJSONObject: json) else { return }
        let payload = gzip ? gzipped(body) : body
        let frame = DoubaoASRFrame.frame(
            type: 0b1001, flags: last ? 0b0011 : 0b0001, serialization: 1, compression: gzip ? 1 : 0,
            prefix: [UInt32(bitPattern: sequence)], payload: payload
        )
        send(frame, on: connection)
    }

    private func send(_ data: Data, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}

/// 握手被拒：像真豆包那样回一个非 101 的 HTTP 响应（带 X-Api-Message），然后关掉连接。
private final class RejectingHTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "keyi.checks.fake-doubao-reject")
    private let listener: NWListener

    init(status: String, message: String) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let response = Data(
            "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nX-Api-Message: \(message)\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".utf8
        )
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
    }

    var port: UInt16? { listener.port?.rawValue }

    func stop() { listener.cancel() }
}

/// gzip 头 + 原始 deflate + 8 字节尾（客户端不校验 CRC）。
private func gzipped(_ data: Data) -> Data {
    let deflated = (try? (data as NSData).compressed(using: .zlib) as Data) ?? Data()
    return Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF]) + deflated + Data(count: 8)
}

private final class DoubaoHeaderStore: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]

    func set(_ headers: [(name: String, value: String)]) {
        lock.lock()
        for header in headers { stored[header.name.lowercased()] = header.value }
        lock.unlock()
    }

    func value(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return stored[name.lowercased()]
    }
}

private final class DoubaoEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DoubaoASRStream.Event] = []

    func append(_ event: DoubaoASRStream.Event) {
        lock.lock()
        items.append(event)
        lock.unlock()
    }

    var events: [DoubaoASRStream.Event] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    var terminal: DoubaoASRStream.Event? {
        events.last { event in
            switch event {
            case .final, .failed: true
            case .started, .partial: false
            }
        }
    }
}

private func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func readyServer(_ behavior: FakeDoubaoServer.Behavior) async throws -> (FakeDoubaoServer, URL) {
    let server = try FakeDoubaoServer(behavior)
    _ = await waitUntil { server.port != nil && server.port != 0 }
    guard let port = server.port, let url = URL(string: "ws://127.0.0.1:\(port)/api/v3/sauc/bigmodel_async") else {
        fatalError("假豆包服务没起来")
    }
    return (server, url)
}

func runDoubaoASRChecks() async throws -> Int {
    var checks = 0
    func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { fatalError(message) }
    }

    // 帧编解码。
    check(DoubaoASRFrame.audio(Data([1, 2]), last: true) == Data([0x11, 0x22, 0x00, 0x00, 0, 0, 0, 2, 1, 2]),
          "最后一包：音频类型、标志 0b0010、原样不压缩、大端长度")
    check(DoubaoASRFrame.audio(Data([7]), last: false).prefix(4) == Data([0x11, 0x20, 0x00, 0x00]), "普通音频包不带标志")
    check(DoubaoASRFrame.clientRequest(Data("{}".utf8)) == Data([0x11, 0x10, 0x10, 0x00, 0, 0, 0, 2]) + Data("{}".utf8),
          "参数包：JSON、不压缩")
    let body = Data(#"{"result":{"text":"好"}}"#.utf8)
    let lastFrame = DoubaoASRFrame.frame(type: 0b1001, flags: 0b0011, serialization: 1, compression: 0,
                                         prefix: [UInt32(bitPattern: -3)], payload: body)
    check(DoubaoASRFrame.parse(lastFrame) == .response(sequence: -3, isLast: true, payload: body), "负序号的最后一包")
    let gzipFrame = DoubaoASRFrame.frame(type: 0b1001, flags: 0b0001, serialization: 1, compression: 1,
                                         prefix: [2], payload: gzipped(body))
    check(DoubaoASRFrame.parse(gzipFrame) == .response(sequence: 2, isLast: false, payload: body), "gzip 回包解得开")
    let errorFrame = DoubaoASRFrame.frame(type: 0b1111, flags: 0, serialization: 1, compression: 0,
                                          prefix: [45_000_002], payload: Data(#"{"error":"empty"}"#.utf8))
    check(DoubaoASRFrame.parse(errorFrame) == .error(code: 45_000_002, message: "empty"), "错误帧：错误码和信息")
    check(DoubaoASRFrame.parse(Data([0x11, 0x90])) == nil, "不完整的帧不认")
    check(DoubaoASRFrame.text(fromResponse: body) == "好", "result 是对象")
    check(DoubaoASRFrame.text(fromResponse: Data(#"{"result":[{"text":"甲"},{"text":"乙"}]}"#.utf8)) == "甲乙", "result 是数组")
    check(DoubaoASRFrame.text(fromResponse: Data(#"{"audio_info":{}}"#.utf8)) == nil, "没有结果的回包不算文字")
    check(DoubaoASRStream.Failure.service(code: 45_000_151, message: "").message.contains("音频格式不正确"), "已知错误码写成中文")

    // 正常一段：鉴权头、参数包、按序分包且只有最后一包带标志、gzip 与数组回包、定稿。
    do {
        let (server, url) = try await readyServer(.transcribe)
        defer { server.stop() }
        let log = DoubaoEventLog()
        let stream = DoubaoASRStream(
            configuration: DoubaoASRConfiguration(apiKey: "test-key", endpoint: url),
            sampleRate: 16000
        ) { log.append($0) }
        stream.start()
        let frames = (0..<4).map { index in Data((0..<3200).map { UInt8(($0 * (index + 3)) % 251) }) }
        stream.append(frames[0])
        stream.append(frames[1])
        _ = await waitUntil { log.events.contains(.started) }
        check(log.events.first == .started, "握手成功先报 started")
        stream.append(frames[2])
        _ = await waitUntil { log.events.contains(.partial("你好，hello")) }
        check(log.events.contains(.partial("你好")), "gzip 回包的文字传出来")
        check(log.events.contains(.partial("你好，hello")), "数组形式的结果也认")
        stream.append(frames[3])
        stream.finish()
        _ = await waitUntil { log.terminal != nil }
        check(log.terminal == .final("你好，Hello world。"), "最后一包的回应就是定稿")
        check(server.header("X-Api-Key") == "test-key", "鉴权头是 X-Api-Key")
        check(server.header("X-Api-Resource-Id") == "volc.seedasr.sauc.duration", "资源 ID 是流式识别 2.0 小时版")
        check(server.header("X-Api-Request-Id")?.count == 36, "请求 ID 是 UUID")
        check(server.requestHeader == [0x11, 0x10, 0x10, 0x00], "参数包的头")
        let audio = server.request?["audio"] as? [String: Any]
        let request = server.request?["request"] as? [String: Any]
        check(audio?["format"] as? String == "pcm" && audio?["rate"] as? Int == 16000
                && audio?["bits"] as? Int == 16 && audio?["channel"] as? Int == 1,
              "音频是 16 kHz 16 位单声道 PCM")
        check(request?["model_name"] as? String == "bigmodel" && request?["enable_nonstream"] as? Bool == true,
              "模型 bigmodel，开二遍识别")
        let packets = server.audioPackets
        check(packets.count == 4, "四帧音频分四包送出（实际 \(packets.count)）")
        check(packets.dropLast().allSatisfy { $0.flags == 0 } && packets.last?.flags == 0b0010, "只有最后一包带标志")
        check(packets.reduce(Data()) { $0 + $1.payload } == frames.reduce(Data(), +), "音频按顺序原样送出")
    }

    // 一点声音都没有：直接定稿为空，不等豆包。
    do {
        let (server, url) = try await readyServer(.transcribe)
        defer { server.stop() }
        let log = DoubaoEventLog()
        let stream = DoubaoASRStream(
            configuration: DoubaoASRConfiguration(apiKey: "test-key", endpoint: url),
            sampleRate: 16000
        ) { log.append($0) }
        stream.start()
        stream.finish()
        _ = await waitUntil { log.terminal != nil }
        check(log.terminal == .final(""), "没声音时定稿为空")
    }

    // 错误帧：报错误码和信息；验证时也如实报。
    do {
        let (server, url) = try await readyServer(.errorFrame)
        defer { server.stop() }
        let log = DoubaoEventLog()
        let stream = DoubaoASRStream(
            configuration: DoubaoASRConfiguration(apiKey: "test-key", endpoint: url),
            sampleRate: 16000
        ) { log.append($0) }
        stream.start()
        _ = await waitUntil { log.terminal != nil }
        check(log.terminal == .failed(.service(code: 45_000_151, message: "bad audio")), "错误帧报错误码和信息")
        let failure = await DoubaoASRStream.verify(DoubaoASRConfiguration(apiKey: "test-key", endpoint: url))
        check(failure == .service(code: 45_000_151, message: "bad audio"), "验证时如实报豆包的错")
    }

    // 验证：握手成功、没有错误帧就算能用，不送音频。
    do {
        let (server, url) = try await readyServer(.transcribe)
        defer { server.stop() }
        let failure = await DoubaoASRStream.verify(DoubaoASRConfiguration(apiKey: "test-key", endpoint: url))
        check(failure == nil, "握手成功、没有错误就算验证通过")
        check(server.audioPackets.isEmpty, "验证不送音频")
    }

    // 握手被拒（不是 401）：带上 X-Api-Message。
    do {
        let server = try RejectingHTTPServer(status: "403 Forbidden", message: "resource not granted")
        defer { server.stop() }
        _ = await waitUntil { server.port != nil && server.port != 0 }
        let url = URL(string: "ws://127.0.0.1:\(server.port ?? 9)/api/v3/sauc/bigmodel_async")!
        let failure = await DoubaoASRStream.verify(DoubaoASRConfiguration(apiKey: "test-key", endpoint: url))
        if case let .rejected(status, message)? = failure {
            check(status == 403 && message == "resource not granted", "握手被拒时带上豆包给的原因（\(status) \(message)）")
        } else {
            check(false, "握手被拒应报 rejected（实际 \(String(describing: failure))）")
        }
    }

    // 连不上：network。
    do {
        let failure = await DoubaoASRStream.verify(
            DoubaoASRConfiguration(apiKey: "test-key", endpoint: URL(string: "ws://127.0.0.1:9/none")!)
        )
        if case .network? = failure { check(true, "") } else { check(false, "连不上时报 network") }
    }

    if ProcessInfo.processInfo.environment["KEYI_NETWORK_CHECKS"] == "1" {
        let failure = await DoubaoASRStream.verify(
            DoubaoASRConfiguration(apiKey: "00000000-0000-4000-8000-000000000000")
        )
        check(failure == .unauthorized, "真豆包：假 Key 握手被拒，报 Key 不对（实际 \(String(describing: failure))）")
        print("doubao network check: invalid key -> \(String(describing: failure))")
    }

    return checks
}
