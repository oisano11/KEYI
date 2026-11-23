import CryptoKit
import Foundation
import KEYICore
@testable import KEYIUI

private indirect enum DownloadStubReply: Sendable {
    case body(status: Int, data: Data)
    case partialThenFail(Data)
    /// 等一会儿再回（测速时显得慢）。
    case delayed(TimeInterval, DownloadStubReply)
    /// 一直不回（测速超时）。
    case silent
}

/// 收到的一个请求：哪个节点、Range、User-Agent。
private struct SeenRequest: Equatable {
    let host: String
    let range: String?
    let userAgent: String?
}

private final class DownloadStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var reply: ((URLRequest) -> DownloadStubReply)?
    nonisolated(unsafe) private static var seen: [SeenRequest] = []

    /// 每个节点最后一次请求的 Range（测速并发时也不乱）。
    static var seenRanges: [String: String?] {
        lock.withLock { Dictionary(seen.map { ($0.host, $0.range) }, uniquingKeysWith: { _, last in last }) }
    }

    static var requests: [SeenRequest] { lock.withLock { seen } }

    static func reset() {
        lock.withLock { seen = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        Self.lock.withLock {
            Self.seen.append(SeenRequest(
                host: request.url?.host() ?? "",
                range: request.value(forHTTPHeaderField: "Range"),
                userAgent: request.value(forHTTPHeaderField: "User-Agent")
            ))
        }
        guard let reply = Self.reply?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        send(reply)
    }

    private func send(_ reply: DownloadStubReply) {
        switch reply {
        case .silent:
            break
        case .delayed(let seconds, let later):
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { self.send(later) }
        case .body(let status, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .partialThenFail(let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            // 立刻报错会让 URLSession 丢掉还没交付的数据，稍等再断开。
            let client = client
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        }
    }

    override func stopLoading() {}
}

private struct DownloadCheckFailure: Error {}

func runLocalModelDownloaderChecks() async throws -> Int {
    var checks = 0
    func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { fatalError(message) }
    }

    let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    let digest = LocalModelDownloader.hex(SHA256.hash(data: payload))
    let model = LocalTranslationModel(
        tier: .light,
        displayName: "测试",
        summary: "测试",
        fileName: "test.gguf",
        byteCount: Int64(payload.count),
        sha256: digest,
        downloadURLs: [URL(string: "https://first.test/test.gguf")!, URL(string: "https://second.test/test.gguf")!],
        usesSceneContext: false
    )
    let first = LocalModelDownloadNode(id: "first", name: "First", baseURL: "https://first.test/")
    let second = LocalModelDownloadNode(id: "second", name: "Second", baseURL: "https://second.test/")
    let third = LocalModelDownloadNode(id: "third", name: "Third", baseURL: "https://third.test/")
    // 原有的两来源检查：按指定顺序试，不测速。
    let twoNodes = LocalModelDownloadPlan(nodes: [first, second], probeFirst: false)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DownloadStubProtocol.self]
    let session = URLSession(configuration: configuration)

    func freshStorage(capacity: Int64? = nil) -> LocalModelStorage {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KEYIDownloaderChecks-\(UUID().uuidString)", isDirectory: true)
        return LocalModelStorage(directory: directory, availableCapacity: { _ in capacity })
    }
    // 「bytes=起-」或「bytes=起-止」（测速）都按 Range 回 206。
    func rangeBody(_ request: URLRequest) -> DownloadStubReply {
        guard let range = request.value(forHTTPHeaderField: "Range") else {
            return .body(status: 200, data: payload)
        }
        let bounds = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard let start = Int(bounds[0]) else { return .body(status: 416, data: Data()) }
        let end = bounds.count > 1 ? Int(bounds[1]).map { min($0 + 1, payload.count) } ?? payload.count : payload.count
        return .body(status: 206, data: payload.subdata(in: start..<end))
    }

    // 首个来源正常：校验通过后改名为正式文件，不留 partial。
    var storage = freshStorage()
    DownloadStubProtocol.reset()
    DownloadStubProtocol.reply = rangeBody
    let reported = ProgressLog()
    try await LocalModelDownloader(storage: storage, session: session, progressStep: 64 * 1024)
        .download(model, plan: twoNodes) { reported.append($0) }
    check(storage.isInstalled(model), "下载完成后应出现正式模型文件")
    check(!FileManager.default.fileExists(atPath: storage.partialURL(for: model).path), "完成后不得残留 partial")
    check(DownloadStubProtocol.seenRanges.keys.sorted() == ["first.test"], "首个来源成功时不应访问备用来源")
    check(reported.values.last == model.byteCount && reported.values == reported.values.sorted(), "进度应单调递增并以总大小结束")

    // 首个来源内容被篡改：删掉 partial，换备用来源从头下。
    storage = freshStorage()
    DownloadStubProtocol.reset()
    DownloadStubProtocol.reply = { request in
        if request.url?.host() == "first.test" {
            var tampered = payload
            tampered[10] ^= 0xFF
            return .body(status: 200, data: tampered)
        }
        return rangeBody(request)
    }
    try await LocalModelDownloader(storage: storage, session: session).download(model, plan: twoNodes) { _ in }
    check(storage.isInstalled(model), "校验失败后应换备用来源完成下载")
    check(DownloadStubProtocol.seenRanges["second.test"] == .some(nil), "校验失败后备用来源应从头下载")

    // 首个来源下到一半断网：保留已下部分，备用来源按 Range 续传。
    storage = freshStorage()
    DownloadStubProtocol.reset()
    let half = payload.count / 2
    DownloadStubProtocol.reply = { request in
        request.url?.host() == "first.test"
            ? .partialThenFail(payload.subdata(in: 0..<half))
            : rangeBody(request)
    }
    try await LocalModelDownloader(storage: storage, session: session).download(model, plan: twoNodes) { _ in }
    check(storage.isInstalled(model), "断网后应在备用来源续传完成")
    check(DownloadStubProtocol.seenRanges["second.test"] == .some("bytes=\(half)-"), "续传应从已下字节处发 Range")

    // 已有 partial 但服务器忽略 Range、返回整份 200：从头覆盖。
    storage = freshStorage()
    try storage.prepareDirectory()
    try payload.subdata(in: 0..<1000).write(to: storage.partialURL(for: model))
    DownloadStubProtocol.reply = { _ in .body(status: 200, data: payload) }
    try await LocalModelDownloader(storage: storage, session: session).download(model, plan: twoNodes) { _ in }
    check(storage.isInstalled(model), "服务器忽略 Range 时应从头覆盖写入")

    // 已安装的文件被同长度的坏文件覆盖或原地改写：登记失效，不再算已安装。
    var tampered = payload
    tampered[10] ^= 0xFF
    try tampered.write(to: storage.fileURL(for: model), options: .atomic)
    check(!storage.isInstalled(model), "正式文件被替换后不应算已安装")
    storage = freshStorage()
    DownloadStubProtocol.reply = rangeBody
    try await LocalModelDownloader(storage: storage, session: session).download(model, plan: twoNodes) { _ in }
    let inPlace = try FileHandle(forWritingTo: storage.fileURL(for: model))
    try inPlace.seek(toOffset: 10)
    try inPlace.write(contentsOf: Data([tampered[10]]))
    try inPlace.close()
    check(!storage.isInstalled(model), "正式文件被原地改写后不应算已安装")

    // 正式位置上有同长度坏文件且没有登记：重算 sha256 后删掉重下。
    DownloadStubProtocol.reset()
    try await LocalModelDownloader(storage: storage, session: session).download(model, plan: twoNodes) { _ in }
    check(storage.isInstalled(model), "坏文件应被删掉并重新下载")
    check(try Data(contentsOf: storage.fileURL(for: model)) == payload, "重新下载后内容应与清单一致")
    check(DownloadStubProtocol.seenRanges["first.test"] == .some(nil), "坏文件不得当作 partial 续传")

    // 正式位置上有内容正确但没有登记的文件：重算 sha256 后直接登记，不发请求。
    storage = freshStorage()
    try storage.prepareDirectory()
    try payload.write(to: storage.fileURL(for: model))
    check(!storage.isInstalled(model), "没有登记的文件不应算已安装")
    DownloadStubProtocol.reset()
    try await LocalModelDownloader(storage: storage, session: session).download(model, plan: twoNodes) { _ in }
    check(storage.isInstalled(model), "内容正确的文件重算后应登记为已安装")
    check(DownloadStubProtocol.seenRanges.isEmpty, "内容正确时不得重新下载")

    // 磁盘不足：不发请求，直接报错。
    storage = freshStorage(capacity: 1000)
    DownloadStubProtocol.reset()
    do {
        try await LocalModelDownloader(storage: storage, session: session).download(model, plan: twoNodes) { _ in }
        throw DownloadCheckFailure()
    } catch let error as LocalModelDownloadError {
        if case .insufficientDiskSpace = error {} else { fatalError("磁盘不足应报 insufficientDiskSpace") }
    }
    check(DownloadStubProtocol.seenRanges.isEmpty, "磁盘不足时不得发起下载")

    // 每个节点都不行：每个节点的原因都报（只报最后一个时，国内连不上 Hugging Face 会盖掉 ModelScope 真正的原因），不出现正式文件。
    storage = freshStorage()
    DownloadStubProtocol.reply = { request in
        .body(status: request.url?.host() == "first.test" ? 403 : 500, data: Data())
    }
    do {
        try await LocalModelDownloader(storage: storage, session: session).download(model, plan: twoNodes) { _ in }
        throw DownloadCheckFailure()
    } catch let error as LocalModelDownloadError {
        guard case .allNodesFailed(let reasons) = error else { fatalError("都不行时应报每个节点的原因") }
        check(reasons.count == 2 && reasons[0].contains("First") && reasons[0].contains("HTTP 403")
              && reasons[1].contains("Second") && reasons[1].contains("HTTP 500"),
              "原因要按节点逐个列出：\(reasons)")
        check((error.errorDescription ?? "").contains("HTTP 403") && (error.errorDescription ?? "").contains("HTTP 500"),
              "界面上的错误要同时看得到两个节点的原因")
    }
    check(!storage.isInstalled(model), "失败后不得出现正式文件")

    // 自动：同时给各节点测速（从 0 取到文件末尾或 2 MB），从最快的下；不能用的写进诊断；请求都带 KEYI 的 User-Agent。
    storage = freshStorage()
    DownloadStubProtocol.reset()
    DownloadStubProtocol.reply = { request in
        switch request.url?.host() {
        case "first.test": .delayed(0.4, rangeBody(request))
        case "third.test": .body(status: 403, data: Data())
        default: rangeBody(request)
        }
    }
    let autoEvents = EventLog()
    try await LocalModelDownloader(storage: storage, session: session)
        .download(model, plan: LocalModelDownloadPlan(nodes: [first, second, third], probeFirst: true), events: autoEvents.append) { _ in }
    check(storage.isInstalled(model), "自动测速后应下完")
    let probeRange = "bytes=0-\(payload.count - 1)"
    check(DownloadStubProtocol.requests.filter { $0.range == probeRange }.map(\.host).sorted() == ["first.test", "second.test", "third.test"],
          "三个节点都要测速：\(DownloadStubProtocol.requests)")
    check(DownloadStubProtocol.requests.filter { $0.range != probeRange }.map(\.host) == ["second.test"],
          "应从测速最快的节点下：\(DownloadStubProtocol.requests)")
    check(DownloadStubProtocol.requests.allSatisfy { $0.userAgent == LocalModelDownloader.userAgent },
          "测速和下载请求都要带 KEYI 的 User-Agent")
    check(autoEvents.events.first == .probing && autoEvents.events.contains(.downloading(from: second)),
          "先报测速中，再报来自哪个节点：\(autoEvents.events)")
    check(autoEvents.notes.contains { $0.hasPrefix("节点测速：") && $0.contains("Third 不能用（HTTP 403）") && $0.hasSuffix("从 Second 下") },
          "测速结果写进诊断：\(autoEvents.notes)")

    // 指定的节点下到一半断了：其余的先测速（从已下的位置往后取），从快的接着下。
    storage = freshStorage()
    DownloadStubProtocol.reset()
    DownloadStubProtocol.reply = { request in
        switch request.url?.host() {
        case "first.test": .partialThenFail(payload.subdata(in: 0..<half))
        case "second.test": .delayed(0.4, rangeBody(request))
        default: rangeBody(request)
        }
    }
    let pickedEvents = EventLog()
    try await LocalModelDownloader(storage: storage, session: session)
        .download(model, plan: LocalModelDownloadPlan(nodes: [first, second, third], probeFirst: false), events: pickedEvents.append) { _ in }
    check(storage.isInstalled(model), "指定的节点断了，应换节点接着下完")
    let resumeProbe = "bytes=\(half)-\(payload.count - 1)"
    check(DownloadStubProtocol.requests.first?.host == "first.test"
          && DownloadStubProtocol.requests.first?.range == nil, "指定的节点先用、不测速")
    check(Set(DownloadStubProtocol.requests.filter { $0.range == resumeProbe }.map(\.host)) == ["second.test", "third.test"],
          "指定的不行再给其余的测速，从已下的位置往后取：\(DownloadStubProtocol.requests)")
    check(DownloadStubProtocol.requests.last == SeenRequest(host: "third.test", range: "bytes=\(half)-", userAgent: LocalModelDownloader.userAgent),
          "从测速快的节点接着已下的部分下：\(DownloadStubProtocol.requests)")
    check(pickedEvents.notes.first == "用指定的节点 First 下" && pickedEvents.notes.contains { $0.hasPrefix("First 没下成") },
          "诊断里写用了指定的节点、它为什么没下成：\(pickedEvents.notes)")
    check(pickedEvents.events.filter { if case .note = $0 { false } else { true } }
            == [.downloading(from: first), .probing, .downloading(from: third)],
          "界面依次看到：来自 First、测速中、来自 Third：\(pickedEvents.events)")

    // 测速时一直不回的节点：到时算连不上，不排进去；不会卡住下载。
    storage = freshStorage()
    DownloadStubProtocol.reset()
    DownloadStubProtocol.reply = { request in
        request.url?.host() == "first.test" ? .silent : rangeBody(request)
    }
    let silentEvents = EventLog()
    let started = Date()
    try await LocalModelDownloader(storage: storage, session: session, probeTimeout: 0.3)
        .download(model, plan: LocalModelDownloadPlan(nodes: [first, second], probeFirst: true), events: silentEvents.append) { _ in }
    check(storage.isInstalled(model) && Date().timeIntervalSince(started) < 5, "测速超时的节点不该拖住下载")
    check(silentEvents.notes.contains { $0.contains("First 不能用") && $0.hasSuffix("从 Second 下") },
          "超时的节点写进诊断：\(silentEvents.notes)")

    // 删除：正式文件、partial 和登记一起删。
    storage = freshStorage()
    try storage.prepareDirectory()
    try payload.write(to: storage.fileURL(for: model))
    try storage.markVerified(model)
    try Data([1]).write(to: storage.partialURL(for: model))
    try storage.delete(model)
    check(
        !storage.isInstalled(model) && storage.partialSize(for: model) == 0
            && !FileManager.default.fileExists(atPath: storage.recordURL(for: model).path),
        "删除应清掉正式文件、partial 和登记"
    )

    DownloadStubProtocol.reply = nil
    return checks
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LocalModelDownloadEvent] = []

    func append(_ event: LocalModelDownloadEvent) {
        lock.withLock { storage.append(event) }
    }

    var events: [LocalModelDownloadEvent] {
        lock.withLock { storage }
    }

    var notes: [String] {
        events.compactMap { if case .note(let text) = $0 { text } else { nil } }
    }
}

/// 「下载节点」的设置：默认自动，选了就存、认不出的按自动，自建节点地址不对时按自动下。
@MainActor
func runLocalModelNodeSettingsChecks() -> Int {
    var checks = 0
    func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { fatalError(message) }
    }
    let suite = "KEYILocalModelNodeChecks-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = TranslationSettingsStore(defaults: defaults)
    let storage = LocalModelStorage(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("KEYILocalModelNodeChecks-\(UUID().uuidString)", isDirectory: true)
    )
    let model = AppModel(settings: settings, hotKeySettings: HotKeySettingsStore(defaults: defaults), localModelStorage: storage)
    check(model.localModelDownloadNode == LocalModelDownloadNodes.automatic && model.localModelDownloadPlan == .automatic,
          "没选过时按自动测速")
    model.selectLocalModelDownloadNode(LocalModelDownloadNodes.hfMirror.id)
    check(TranslationSettingsStore(defaults: defaults).localModelDownloadNode() == "hf-mirror", "选的节点要存下来")
    check(model.localModelDownloadPlan.nodes.first == LocalModelDownloadNodes.hfMirror && !model.localModelDownloadPlan.probeFirst,
          "指定的节点排第一、不先测速")
    model.selectLocalModelDownloadNode("cloudflare")
    check(model.localModelDownloadNode == LocalModelDownloadNodes.automatic, "认不出的节点按自动")
    model.selectLocalModelDownloadNode(LocalModelDownloadNodes.custom)
    model.setLocalModelDownloadCustomURL("  http://cdn.example.com/keyi  ")
    check(model.localModelDownloadCustomURL == "http://cdn.example.com/keyi" && model.localModelDownloadPlan == .automatic,
          "自建节点不是 https 时按自动下")
    model.setLocalModelDownloadCustomURL("https://cdn.example.com/keyi")
    let custom = model.localModelDownloadPlan
    check(custom.nodes.first?.url(for: LocalTranslationModelCatalog.model(for: .light)).absoluteString
            == "https://cdn.example.com/keyi/Hy-MT2-1.8B-Q4_K_M.gguf"
          && custom.nodes.dropFirst().map(\.id) == LocalModelDownloadNodes.builtIn.map(\.id) && !custom.probeFirst,
          "自建节点排第一，内置节点按清单接在后面")
    check(TranslationSettingsStore(defaults: defaults).localModelDownloadCustomURL() == "https://cdn.example.com/keyi",
          "自建节点地址要存下来")
    return checks
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int64] = []

    func append(_ value: Int64) {
        lock.withLock { storage.append(value) }
    }

    var values: [Int64] {
        lock.withLock { storage }
    }
}
