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
        }
    }
}

/// 下载到 `.partial`，支持 HTTP Range 续传，边写边算 sha256。
/// 网络错误保留已下部分并换下一个来源续传；校验不符删掉已下部分，换下一个来源重下。
/// 任务取消时保留已下部分，下次接着下。
struct LocalModelDownloader: Sendable {
    let storage: LocalModelStorage
    let session: URLSession
    let progressStep: Int64

    init(
        storage: LocalModelStorage = .standard,
        session: URLSession = .shared,
        progressStep: Int64 = 1 << 20
    ) {
        self.storage = storage
        self.session = session
        self.progressStep = progressStep
    }

    func download(
        _ model: LocalTranslationModel,
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

        var lastError: Error = LocalModelDownloadError.checksumMismatch
        for source in model.downloadURLs {
            do {
                let digest = try await fetch(source, into: partial, model: model, progress: progress)
                guard storage.partialSize(for: model) == model.byteCount,
                      digest == model.sha256 else {
                    try? FileManager.default.removeItem(at: partial)
                    lastError = LocalModelDownloadError.checksumMismatch
                    continue
                }
                guard rename(partial.path, storage.fileURL(for: model).path) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try storage.markVerified(model)
                progress(model.byteCount)
                return
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                lastError = error
            }
        }
        throw lastError
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

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
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
