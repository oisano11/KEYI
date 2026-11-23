import CryptoKit
import Foundation
import KEYICore

/// 模型文件放在 Application Support 下；正式文件只在字节数和 sha256 都对上后才出现，
/// 并在旁边的 `.verified` 里记下文件身份。
struct LocalModelStorage: Sendable {
    let directory: URL
    private let availableCapacity: @Sendable (URL) -> Int64?

    init(
        directory: URL,
        availableCapacity: @escaping @Sendable (URL) -> Int64? = LocalModelStorage.volumeCapacity
    ) {
        self.directory = directory
        self.availableCapacity = availableCapacity
    }

    static var standard: LocalModelStorage {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LocalModelStorage(
            directory: base
                .appendingPathComponent("com.keyi.input-translator", isDirectory: true)
                .appendingPathComponent("Models", isDirectory: true)
        )
    }

    func fileURL(for model: LocalTranslationModel) -> URL {
        directory.appendingPathComponent(model.fileName)
    }

    func partialURL(for model: LocalTranslationModel) -> URL {
        directory.appendingPathComponent(model.fileName + ".partial")
    }

    func recordURL(for model: LocalTranslationModel) -> URL {
        directory.appendingPathComponent(model.fileName + ".verified")
    }

    /// 只认校验过、之后没被替换或改写的文件；不读文件内容，界面可以随时调用。
    func isInstalled(_ model: LocalTranslationModel) -> Bool {
        guard let data = try? Data(contentsOf: recordURL(for: model)),
              let record = try? JSONDecoder().decode(VerificationRecord.self, from: data),
              record.sha256 == model.sha256 else {
            return false
        }
        return VerificationRecord(sha256: model.sha256, attributesOf: fileURL(for: model)) == record
    }

    /// 翻译用哪一档：用户选过且已下载就用它，否则用已下载的标准档、再轻量档；都没下载为 nil。
    func preferredInstalledModel(preferring tier: LocalTranslationModelTier?) -> LocalTranslationModel? {
        let order = [tier, .standard, .light].compactMap { $0 }
        return order.map(LocalTranslationModelCatalog.model(for:)).first(where: isInstalled)
    }

    /// 正式文件位置上已有文件但没有有效登记时，重新算 sha256：对上就登记，对不上就删掉。
    func adoptExistingFile(_ model: LocalTranslationModel) throws -> Bool {
        let url = fileURL(for: model)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if fileSize(at: url) == model.byteCount, try Self.sha256(ofFileAt: url) == model.sha256 {
            try markVerified(model)
            return true
        }
        for stale in [url, recordURL(for: model)] where FileManager.default.fileExists(atPath: stale.path) {
            try FileManager.default.removeItem(at: stale)
        }
        return false
    }

    func markVerified(_ model: LocalTranslationModel) throws {
        guard let record = VerificationRecord(sha256: model.sha256, attributesOf: fileURL(for: model)) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        try JSONEncoder().encode(record).write(to: recordURL(for: model), options: .atomic)
    }

    func partialSize(for model: LocalTranslationModel) -> Int64 {
        fileSize(at: partialURL(for: model)) ?? 0
    }

    func delete(_ model: LocalTranslationModel) throws {
        for url in [fileURL(for: model), partialURL(for: model), recordURL(for: model)]
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try url.setResourceValues(values)
    }

    func availableBytes() -> Int64? {
        availableCapacity(directory)
    }

    private func fileSize(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    @Sendable static func volumeCapacity(_ url: URL) -> Int64? {
        try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    private static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return LocalModelDownloader.hex(try hashToEnd(handle).hasher.finalize())
    }
}

/// 从当前位置读到文件末尾，返回尚未结束的哈希状态和读到的字节数。
private func hashToEnd(_ handle: FileHandle) throws -> (hasher: SHA256, byteCount: Int64) {
    var hasher = SHA256()
    var byteCount: Int64 = 0
    while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
        byteCount += Int64(chunk.count)
    }
    return (hasher, byteCount)
}

/// 校验通过时记下文件身份；文件被替换（inode 变）或改写（大小、修改时间变）后登记失效。
private struct VerificationRecord: Codable, Equatable {
    let sha256: String
    let byteCount: Int64
    let modified: TimeInterval
    let fileNumber: UInt64

    init?(sha256: String, attributesOf url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date,
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            return nil
        }
        self.sha256 = sha256
        self.byteCount = size
        self.modified = modified.timeIntervalSinceReferenceDate
        self.fileNumber = fileNumber
    }
}

enum LocalModelDownloadError: LocalizedError, Equatable {
    case insufficientDiskSpace(requiredBytes: Int64)
    case checksumMismatch
    case badStatus(Int)
    /// 每个节点都没下成：各自的原因（「节点名：原因」），一个不漏地报
    /// （只报最后一个时，国内连不上 Hugging Face 会盖掉 ModelScope 真正的原因）。
    case allNodesFailed([String])

    var errorDescription: String? {
        let strings = InterfaceStrings.current
        return switch self {
        case .insufficientDiskSpace(let requiredBytes):
            strings.localModelInsufficientDiskSpace(
                ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
            )
        case .checksumMismatch:
            strings.localModelChecksumMismatch
        case .badStatus(let status):
            strings.localModelDownloadStatus(status)
        case .allNodesFailed(let reasons):
            strings.localModelAllNodesFailed(reasons)
        }
    }
}

/// 下载过程中报给界面和诊断记录的事。
enum LocalModelDownloadEvent: Equatable, Sendable {
    /// 正在给节点测速（界面写「正在给各下载节点测速…」）。
    case probing
    /// 开始或换到从这个节点下。
    case downloading(from: LocalModelDownloadNode)
    /// 测速结果、选了哪个节点、换节点的原因（写进诊断记录）。
    case note(String)
}

/// 多个下载节点（`LocalModelDownloadNodes`，PRODUCT_SCOPE 变更记录 2026-11-11），规则与 C# 版 `ModelDownloader` 一致：
/// 默认先给各节点各取 2 MB 测速，从最快的下；指定了节点就先用它，不行再给其余的测速。
/// 下载到 `.partial`，支持 HTTP Range 续传，边写边算 sha256；断了（含 60 秒收不到数据，URLSession 的
/// `timeoutIntervalForRequest`）就换下一个节点接着已下的部分下；校验不符删掉已下部分，换下一个节点重下。
/// 请求都带 KEYI 的 User-Agent。任务取消时保留已下部分，下次接着下。
struct LocalModelDownloader: Sendable {
    static let userAgent = "KEYI-IME/1.0"
    static let probeByteCount: Int64 = 2 << 20

    let storage: LocalModelStorage
    let session: URLSession
    let progressStep: Int64
    /// 测速时每个节点最多等多久；到时取到一些就按取到的算，一点没取到算连不上。
    let probeTimeout: TimeInterval

    init(
        storage: LocalModelStorage = .standard,
        session: URLSession = .shared,
        progressStep: Int64 = 1 << 20,
        probeTimeout: TimeInterval = 12
    ) {
        self.storage = storage
        self.session = session
        self.progressStep = progressStep
        self.probeTimeout = probeTimeout
    }

    func download(
        _ model: LocalTranslationModel,
        plan: LocalModelDownloadPlan = .automatic,
        events: @escaping @Sendable (LocalModelDownloadEvent) -> Void = { _ in },
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        if storage.isInstalled(model) {
            progress(model.byteCount)
            return
        }
        try storage.prepareDirectory()
        if try storage.adoptExistingFile(model) {
            progress(model.byteCount)
            return
        }
        let partial = storage.partialURL(for: model)
        if storage.partialSize(for: model) > model.byteCount {
            try FileManager.default.removeItem(at: partial)
        }
        let required = model.byteCount - storage.partialSize(for: model) + model.byteCount / 10
        if let available = storage.availableBytes(), available < required {
            throw LocalModelDownloadError.insufficientDiskSpace(requiredBytes: required)
        }

        let strings = InterfaceStrings.current
        var failures: [String] = []
        var queue = plan.nodes
        var probed = plan.probeFirst
        if probed {
            events(.probing)
            queue = try await ranked(model, nodes: plan.nodes, failures: &failures, events: events)
        }
        var index = 0
        while index < queue.count {
            let node = queue[index]
            if index == 0, !plan.probeFirst {
                events(.note("用指定的节点 \(node.name) 下"))
            }
            events(.downloading(from: node))
            do {
                let digest = try await fetch(node.url(for: model), into: partial, model: model, progress: progress)
                if storage.partialSize(for: model) == model.byteCount, digest == model.sha256 {
                    guard rename(partial.path, storage.fileURL(for: model).path) == 0 else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try storage.markVerified(model)
                    progress(model.byteCount)
                    return
                }
                try? FileManager.default.removeItem(at: partial)
                failures.append(strings.localModelNodeFailure(node.name, strings.localModelNodeChecksumMismatch))
                events(.note("\(node.name) 下来的文件校验不符，删掉换下一个节点重下"))
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                let reason = Self.reason(for: error)
                failures.append(strings.localModelNodeFailure(node.name, reason))
                events(.note(
                    "\(node.name) 没下成（\(reason)），已下 \(storage.partialSize(for: model) / 1_048_576) MB，换下一个节点接着下"
                ))
            }
            // 指定的节点不行：其余的先测速，从快的接着下。
            if !probed, index == 0, queue.count > 1 {
                probed = true
                events(.probing)
                queue = [node] + (try await ranked(model, nodes: Array(queue.dropFirst()), failures: &failures, events: events))
            }
            index += 1
        }
        throw LocalModelDownloadError.allNodesFailed(failures)
    }

    /// 同时给这些节点测速（从已下的位置往后取 2 MB），返回能用的、从快到慢；不能用的原因记进 failures。
    private func ranked(
        _ model: LocalTranslationModel,
        nodes: [LocalModelDownloadNode],
        failures: inout [String],
        events: @Sendable (LocalModelDownloadEvent) -> Void
    ) async throws -> [LocalModelDownloadNode] {
        let offset = storage.partialSize(for: model)
        guard offset < model.byteCount else { return nodes }
        let probes = await withTaskGroup(of: (Int, LocalModelNodeProbe).self) { group in
            for (position, node) in nodes.enumerated() {
                group.addTask { (position, await probe(model, node: node, offset: offset)) }
            }
            var results: [(Int, LocalModelNodeProbe)] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        try Task.checkCancellation()
        let ranked = LocalModelDownloadNodes.rank(probes)
        let strings = InterfaceStrings.current
        failures += probes.filter { !$0.isUsable }.map {
            strings.localModelNodeFailure($0.node.name, $0.error ?? strings.localModelProbeNoData)
        }
        events(.note(
            "节点测速：" + probes.map(\.summary).joined(separator: "；")
                + (ranked.first.map { "。从 \($0.name) 下" } ?? "。没有能用的节点")
        ))
        return ranked
    }

    private func probe(
        _ model: LocalTranslationModel,
        node: LocalModelDownloadNode,
        offset: Int64
    ) async -> LocalModelNodeProbe {
        let clock = ContinuousClock()
        let started = clock.now
        let last = min(offset + Self.probeByteCount, model.byteCount) - 1
        var request = URLRequest(url: node.url(for: model))
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=\(offset)-\(last)", forHTTPHeaderField: "Range")
        let receiver = ProbeReceiver(limit: last - offset + 1)
        let task = session.dataTask(with: request)
        task.delegate = receiver
        let timeout = probeTimeout
        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled { receiver.timeOut(task) }
        }
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                receiver.start(task: task, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
        timer.cancel()
        let elapsed = clock.now - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let strings = InterfaceStrings.current
        let error: String? = switch outcome.ending {
        case .finished, .reachedLimit:
            outcome.byteCount > 0 ? nil : strings.localModelProbeNoData
        case .timedOut:
            // 测速时间到：取到一些就按取到的算（慢的节点排后面），一点没取到算连不上。
            outcome.byteCount > 0 ? nil : strings.localModelProbeTimeout(Int(timeout.rounded()))
        case .status(let status):
            "HTTP \(status)"
        case .failed(let message):
            outcome.byteCount > 0 ? nil : message
        }
        return LocalModelNodeProbe(node: node, byteCount: outcome.byteCount, elapsed: seconds, error: error)
    }

    private func fetch(
        _ source: URL,
        into partial: URL,
        model: LocalTranslationModel,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> String {
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forUpdating: partial)
        defer { try? handle.close() }

        let (hasher, offset) = try hashToEnd(handle)
        if offset == model.byteCount {
            return Self.hex(hasher.finalize())
        }

        var request = URLRequest(url: source)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        let receiver = DownloadReceiver(
            handle: handle,
            hasher: hasher,
            offset: offset,
            progressStep: progressStep,
            progress: progress
        )
        let task = session.dataTask(with: request)
        task.delegate = receiver
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receiver.start(task: task, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// 某个节点没下成的原因，给界面和诊断记录：HTTP 状态只写「HTTP 403」，网络错误用系统的说明。
    static func reason(for error: Error) -> String {
        switch error {
        case LocalModelDownloadError.badStatus(let status): "HTTP \(status)"
        default: error.localizedDescription
        }
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// 测速：数收到的字节，够了就断开；不写文件。
private final class ProbeReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Ending: Sendable {
        case finished
        case reachedLimit
        case timedOut
        case status(Int)
        case failed(String)
    }

    struct Outcome: Sendable {
        let byteCount: Int64
        let ending: Ending
    }

    private let lock = NSLock()
    private let limit: Int64
    private var byteCount: Int64 = 0
    private var ending: Ending?
    private var continuation: CheckedContinuation<Outcome, Never>?

    init(limit: Int64) {
        self.limit = limit
    }

    func start(task: URLSessionDataTask, continuation: CheckedContinuation<Outcome, Never>) {
        lock.withLock { self.continuation = continuation }
        task.resume()
    }

    func timeOut(_ task: URLSessionTask) {
        let cancel: Bool = lock.withLock {
            guard ending == nil else { return false }
            ending = .timedOut
            return true
        }
        if cancel { task.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let accepted: Bool = lock.withLock {
            guard status == 200 || status == 206 else {
                if ending == nil { ending = .status(status) }
                return false
            }
            return true
        }
        completionHandler(accepted ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let enough: Bool = lock.withLock {
            guard ending == nil else { return false }
            byteCount += Int64(data.count)
            guard byteCount >= limit else { return false }
            ending = .reachedLimit
            return true
        }
        if enough { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, outcome): (CheckedContinuation<Outcome, Never>?, Outcome) = lock.withLock {
            defer { self.continuation = nil }
            if ending == nil {
                ending = error.map { .failed($0.localizedDescription) } ?? .finished
            }
            return (self.continuation, Outcome(byteCount: byteCount, ending: ending ?? .finished))
        }
        continuation?.resume(returning: outcome)
    }
}

private final class DownloadReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var hasher: SHA256
    private var offset: Int64
    private let resumeOffset: Int64
    private var lastReported: Int64
    private let progressStep: Int64
    private let progress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<String, Error>?
    private var failure: Error?

    init(
        handle: FileHandle,
        hasher: SHA256,
        offset: Int64,
        progressStep: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) {
        self.handle = handle
        self.hasher = hasher
        self.offset = offset
        self.resumeOffset = offset
        self.lastReported = offset
        self.progressStep = progressStep
        self.progress = progress
    }

    func start(task: URLSessionDataTask, continuation: CheckedContinuation<String, Error>) {
        lock.withLock { self.continuation = continuation }
        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let accepted: Bool = lock.withLock {
            switch status {
            case 206 where resumeOffset > 0:
                return true
            case 200:
                // 服务器没理会 Range，就从头写。
                if offset > 0 {
                    do {
                        try handle.truncate(atOffset: 0)
                        hasher = SHA256()
                        offset = 0
                        lastReported = 0
                    } catch {
                        failure = error
                        return false
                    }
                }
                return true
            default:
                failure = LocalModelDownloadError.badStatus(status)
                return false
            }
        }
        completionHandler(accepted ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let report: Int64? = lock.withLock {
            guard failure == nil else { return nil }
            do {
                try handle.write(contentsOf: data)
            } catch {
                failure = error
                dataTask.cancel()
                return nil
            }
            hasher.update(data: data)
            offset += Int64(data.count)
            guard offset - lastReported >= progressStep else { return nil }
            lastReported = offset
            return offset
        }
        if let report {
            progress(report)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, result): (CheckedContinuation<String, Error>?, Result<String, Error>) = lock.withLock {
            defer { self.continuation = nil }
            if let failure {
                return (self.continuation, .failure(failure))
            }
            if let error {
                let cancelled = (error as? URLError)?.code == .cancelled
                return (self.continuation, .failure(cancelled ? CancellationError() : error))
            }
            return (self.continuation, .success(LocalModelDownloader.hex(hasher.finalize())))
        }
        continuation?.resume(with: result)
    }
}
