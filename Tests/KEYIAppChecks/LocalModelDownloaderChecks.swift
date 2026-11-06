import CryptoKit
import Foundation
import KEYICore
@testable import KEYIUI

private enum DownloadStubReply {
    case body(status: Int, data: Data)
    case partialThenFail(Data)
}

private final class DownloadStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reply: ((URLRequest) -> DownloadStubReply)?
    nonisolated(unsafe) static var seenRanges: [String: String?] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        Self.seenRanges[host] = request.value(forHTTPHeaderField: "Range")
        guard let reply = Self.reply?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch reply {
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
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DownloadStubProtocol.self]
    let session = URLSession(configuration: configuration)

    func freshStorage(capacity: Int64? = nil) -> LocalModelStorage {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KEYIDownloaderChecks-\(UUID().uuidString)", isDirectory: true)
        return LocalModelStorage(directory: directory, availableCapacity: { _ in capacity })
    }
    func rangeBody(_ request: URLRequest) -> DownloadStubReply {
        guard let range = request.value(forHTTPHeaderField: "Range"),
              let start = Int(range.dropFirst("bytes=".count).dropLast()) else {
            return .body(status: 200, data: payload)
        }
        return .body(status: 206, data: payload.subdata(in: start..<payload.count))
    }

    // 首个来源正常：校验通过后改名为正式文件，不留 partial。
    var storage = freshStorage()
    DownloadStubProtocol.seenRanges = [:]
    DownloadStubProtocol.reply = rangeBody
    let reported = ProgressLog()
    try await LocalModelDownloader(storage: storage, session: session, progressStep: 64 * 1024)
        .download(model) { reported.append($0) }
    check(storage.isInstalled(model), "下载完成后应出现正式模型文件")
    check(!FileManager.default.fileExists(atPath: storage.partialURL(for: model).path), "完成后不得残留 partial")
    check(DownloadStubProtocol.seenRanges.keys.sorted() == ["first.test"], "首个来源成功时不应访问备用来源")
    check(reported.values.last == model.byteCount && reported.values == reported.values.sorted(), "进度应单调递增并以总大小结束")

    // 首个来源内容被篡改：删掉 partial，换备用来源从头下。
    storage = freshStorage()
    DownloadStubProtocol.seenRanges = [:]
    DownloadStubProtocol.reply = { request in
        if request.url?.host() == "first.test" {
            var tampered = payload
            tampered[10] ^= 0xFF
            return .body(status: 200, data: tampered)
        }
        return rangeBody(request)
    }
    try await LocalModelDownloader(storage: storage, session: session).download(model) { _ in }
    check(storage.isInstalled(model), "校验失败后应换备用来源完成下载")
    check(DownloadStubProtocol.seenRanges["second.test"] == .some(nil), "校验失败后备用来源应从头下载")

    // 首个来源下到一半断网：保留已下部分，备用来源按 Range 续传。
    storage = freshStorage()
    DownloadStubProtocol.seenRanges = [:]
    let half = payload.count / 2
    DownloadStubProtocol.reply = { request in
        request.url?.host() == "first.test"
            ? .partialThenFail(payload.subdata(in: 0..<half))
            : rangeBody(request)
    }
    try await LocalModelDownloader(storage: storage, session: session).download(model) { _ in }
    check(storage.isInstalled(model), "断网后应在备用来源续传完成")
    check(DownloadStubProtocol.seenRanges["second.test"] == .some("bytes=\(half)-"), "续传应从已下字节处发 Range")

    // 已有 partial 但服务器忽略 Range、返回整份 200：从头覆盖。
    storage = freshStorage()
    try storage.prepareDirectory()
    try payload.subdata(in: 0..<1000).write(to: storage.partialURL(for: model))
    DownloadStubProtocol.reply = { _ in .body(status: 200, data: payload) }
    try await LocalModelDownloader(storage: storage, session: session).download(model) { _ in }
    check(storage.isInstalled(model), "服务器忽略 Range 时应从头覆盖写入")

    // 已安装的文件被同长度的坏文件覆盖或原地改写：登记失效，不再算已安装。
    var tampered = payload
    tampered[10] ^= 0xFF
    try tampered.write(to: storage.fileURL(for: model), options: .atomic)
    check(!storage.isInstalled(model), "正式文件被替换后不应算已安装")
    storage = freshStorage()
    DownloadStubProtocol.reply = rangeBody
    try await LocalModelDownloader(storage: storage, session: session).download(model) { _ in }
    let inPlace = try FileHandle(forWritingTo: storage.fileURL(for: model))
    try inPlace.seek(toOffset: 10)
    try inPlace.write(contentsOf: Data([tampered[10]]))
    try inPlace.close()
    check(!storage.isInstalled(model), "正式文件被原地改写后不应算已安装")

    // 正式位置上有同长度坏文件且没有登记：重算 sha256 后删掉重下。
    DownloadStubProtocol.seenRanges = [:]
    try await LocalModelDownloader(storage: storage, session: session).download(model) { _ in }
    check(storage.isInstalled(model), "坏文件应被删掉并重新下载")
    check(try Data(contentsOf: storage.fileURL(for: model)) == payload, "重新下载后内容应与清单一致")
    check(DownloadStubProtocol.seenRanges["first.test"] == .some(nil), "坏文件不得当作 partial 续传")

    // 正式位置上有内容正确但没有登记的文件：重算 sha256 后直接登记，不发请求。
    storage = freshStorage()
    try storage.prepareDirectory()
    try payload.write(to: storage.fileURL(for: model))
    check(!storage.isInstalled(model), "没有登记的文件不应算已安装")
    DownloadStubProtocol.seenRanges = [:]
    try await LocalModelDownloader(storage: storage, session: session).download(model) { _ in }
    check(storage.isInstalled(model), "内容正确的文件重算后应登记为已安装")
    check(DownloadStubProtocol.seenRanges.isEmpty, "内容正确时不得重新下载")

    // 磁盘不足：不发请求，直接报错。
    storage = freshStorage(capacity: 1000)
    DownloadStubProtocol.seenRanges = [:]
    do {
        try await LocalModelDownloader(storage: storage, session: session).download(model) { _ in }
        throw DownloadCheckFailure()
    } catch let error as LocalModelDownloadError {
        if case .insufficientDiskSpace = error {} else { fatalError("磁盘不足应报 insufficientDiskSpace") }
    }
    check(DownloadStubProtocol.seenRanges.isEmpty, "磁盘不足时不得发起下载")

    // 两个来源都返回 500：报最后一个错误，不出现正式文件。
    storage = freshStorage()
    DownloadStubProtocol.reply = { _ in .body(status: 500, data: Data()) }
    do {
        try await LocalModelDownloader(storage: storage, session: session).download(model) { _ in }
        throw DownloadCheckFailure()
    } catch let error as LocalModelDownloadError {
        check(error == .badStatus(500), "两个来源都失败时应报 HTTP 状态")
    }
    check(!storage.isInstalled(model), "失败后不得出现正式文件")

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
