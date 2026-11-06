import Darwin
import Foundation
import KEYITranslationClient
import OSLog
import Security

enum LocalModelServerError: String, LocalizedError, Equatable {
    case helperMissing
    case runDirectoryUnsafe
    case notRunning
    case failed

    var errorDescription: String? {
        let strings = InterfaceStrings.current
        return switch self {
        case .helperMissing: strings.localModelHelperMissing
        case .runDirectoryUnsafe: strings.localModelRunDirectoryUnsafe
        case .notRunning: strings.localModelUnreachable
        case .failed: strings.localModelServerFailed
        }
    }
}

/// 自带 llama-server 的运行目录：只给当前用户（0700），放 socket、每次启动新生成的密钥、pid、日志，
/// 以及放弃重启时留下的失败原因。主应用和翻译服务子进程都从这里找服务。
struct LocalModelRunDirectory: Sendable {
    static let socketName = "llama.sock"

    let url: URL

    static var standard: LocalModelRunDirectory {
        let preferred = URL(
            fileURLWithPath: TranslationServiceSocketPath.supportDirectory(),
            isDirectory: true
        ).appendingPathComponent("run", isDirectory: true)
        if TranslationServiceSocketPath.fitsInSunPath(preferred.appendingPathComponent(socketName).path) {
            return LocalModelRunDirectory(url: preferred)
        }
        return LocalModelRunDirectory(
            url: URL(fileURLWithPath: "/tmp/keyi-\(getuid())-llama", isDirectory: true)
        )
    }

    var socketURL: URL { url.appendingPathComponent(Self.socketName) }
    var keyURL: URL { url.appendingPathComponent("llama.key") }
    var pidURL: URL { url.appendingPathComponent("llama.pid") }
    var logURL: URL { url.appendingPathComponent("llama.log") }
    var failureURL: URL { url.appendingPathComponent("llama.failed") }

    /// 建好目录并确认它是当前用户自己的真实目录；权限不是 0700 时改回 0700。
    func prepare() throws {
        let path = url.path
        var info = stat()
        if lstat(path, &info) != 0 {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard lstat(path, &info) == 0 else { throw LocalModelServerError.runDirectoryUnsafe }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw LocalModelServerError.runDirectoryUnsafe
        }
        if info.st_mode & 0o777 != 0o700, chmod(path, 0o700) != 0 {
            throw LocalModelServerError.runDirectoryUnsafe
        }
    }

    func endpoint() -> LocalModelEndpoint? {
        guard let data = try? Data(contentsOf: keyURL),
              let key = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }
        return LocalModelEndpoint(socketPath: socketURL.path, apiKey: key)
    }

    func recordedFailure() -> LocalModelServerError? {
        guard let data = try? Data(contentsOf: failureURL),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        return LocalModelServerError(rawValue: raw) ?? .failed
    }

    func recordFailure(_ error: LocalModelServerError) {
        try? Data(error.rawValue.utf8).write(to: failureURL, options: .atomic)
    }

    func clear(_ files: URL...) {
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// 翻译前确认服务可用：服务刚启动、模型还在加载时最多等 `timeout`。
enum LocalModelConnection {
    static func readyEndpoint(
        in runDirectory: LocalModelRunDirectory = .standard,
        waitingUpTo timeout: Duration
    ) async throws -> LocalModelEndpoint {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            if let failure = runDirectory.recordedFailure() {
                throw failure
            }
            if let endpoint = runDirectory.endpoint(),
               let health = try? await LocalModelHTTPClient.send(
                   "GET", "/health", to: endpoint, timeout: .seconds(2)
               ),
               health.status == 200 {
                return endpoint
            }
            guard clock.now < deadline else { throw LocalModelServerError.notRunning }
            try await Task.sleep(for: .milliseconds(200))
        }
    }
}

/// 主应用持有的常驻 llama-server：选中本地模型且模型已下载时运行，
/// 意外退出就重启，连续 `maxConsecutiveFailures` 次没能就绪便停下并记下失败原因。
@MainActor
final class LocalModelServer {
    enum State: Equatable {
        case stopped
        case starting(URL)
        case ready(URL)
        case failed(LocalModelServerError)
    }

    static let maxConsecutiveFailures = 3
    static let contextLength = 8192
    static let shared = LocalModelServer(
        helperURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/llama/llama-server"),
        runDirectory: .standard
    )

    private(set) var state: State = .stopped {
        didSet {
            if state != oldValue { onStateChange?(state) }
        }
    }
    var onStateChange: ((State) -> Void)?

    private let helperURL: URL
    private let runDirectory: LocalModelRunDirectory
    private let readyTimeout: Duration
    private let restartDelay: Duration
    private let logger = Logger(subsystem: "com.keyi.input-translator", category: "local-model-server")
    private var process: Process?
    private var modelURL: URL?
    private var failures = 0
    private var generation = 0
    private var readinessTask: Task<Void, Never>?

    init(
        helperURL: URL,
        runDirectory: LocalModelRunDirectory,
        readyTimeout: Duration = .seconds(120),
        restartDelay: Duration = .seconds(1)
    ) {
        self.helperURL = helperURL
        self.runDirectory = runDirectory
        self.readyTimeout = readyTimeout
        self.restartDelay = restartDelay
    }

    /// 让服务加载 `modelURL`；传 nil 即停止。同一模型已在运行或启动时不做任何事。
    func run(modelAt modelURL: URL?) {
        guard let modelURL else {
            stop()
            return
        }
        if modelURL == self.modelURL, process?.isRunning == true {
            return
        }
        stop()
        self.modelURL = modelURL
        failures = 0
        launch()
    }

    func stop() {
        generation += 1
        readinessTask?.cancel()
        readinessTask = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        modelURL = nil
        terminateRecordedHelper()
        runDirectory.clear(
            runDirectory.keyURL, runDirectory.pidURL, runDirectory.socketURL, runDirectory.failureURL
        )
        state = .stopped
    }

    private func launch() {
        guard let modelURL else { return }
        generation += 1
        let launchGeneration = generation
        runDirectory.clear(runDirectory.failureURL)
        do {
            guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
                throw LocalModelServerError.helperMissing
            }
            try runDirectory.prepare()
            terminateRecordedHelper()
            runDirectory.clear(runDirectory.socketURL, runDirectory.keyURL)
            try writeKey()
            FileManager.default.createFile(
                atPath: runDirectory.logURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
            let log = try FileHandle(forWritingTo: runDirectory.logURL)

            let process = Process()
            process.executableURL = helperURL
            process.currentDirectoryURL = runDirectory.url
            process.arguments = [
                "-m", modelURL.path,
                "--host", runDirectory.socketURL.path,
                "--api-key-file", runDirectory.keyURL.path,
                "-c", String(Self.contextLength),
                "-np", "1",
                "-ngl", "99",
                "--jinja",
                "--no-webui",
                "--offline",
                "--no-slots",
                "--cache-ram", "0"
            ]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = log
            process.standardError = log
            process.terminationHandler = { [weak self] exited in
                let status = exited.terminationStatus
                Task { @MainActor in
                    self?.processExited(generation: launchGeneration, status: status)
                }
            }
            try process.run()
            try? log.close()
            self.process = process
            try? Data(String(process.processIdentifier).utf8)
                .write(to: runDirectory.pidURL, options: .atomic)
            state = .starting(modelURL)
            waitUntilReady(generation: launchGeneration, modelURL: modelURL)
        } catch {
            let failure = error as? LocalModelServerError ?? .failed
            logger.error("local_model_server=launch_failed reason=\(failure.rawValue, privacy: .public)")
            giveUp(failure)
        }
    }

    private func waitUntilReady(generation launchGeneration: Int, modelURL: URL) {
        let runDirectory = runDirectory
        let readyTimeout = readyTimeout
        readinessTask = Task { [weak self] in
            let clock = ContinuousClock()
            let deadline = clock.now + readyTimeout
            while !Task.isCancelled, clock.now < deadline {
                if let endpoint = runDirectory.endpoint(),
                   let health = try? await LocalModelHTTPClient.send(
                       "GET", "/health", to: endpoint, timeout: .seconds(2)
                   ),
                   health.status == 200 {
                    self?.becameReady(generation: launchGeneration, modelURL: modelURL)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled, let self, self.generation == launchGeneration else { return }
            self.logger.error("local_model_server=ready_timeout")
            self.process?.terminate()
        }
    }

    private func becameReady(generation launchGeneration: Int, modelURL: URL) {
        guard generation == launchGeneration else { return }
        failures = 0
        state = .ready(modelURL)
    }

    private func processExited(generation exitedGeneration: Int, status: Int32) {
        guard generation == exitedGeneration else { return }
        readinessTask?.cancel()
        readinessTask = nil
        process = nil
        failures += 1
        logger.error(
            "local_model_server=exited status=\(status, privacy: .public) failures=\(self.failures, privacy: .public)"
        )
        guard failures < Self.maxConsecutiveFailures else {
            giveUp(.failed)
            return
        }
        let restartDelay = restartDelay
        Task { [weak self] in
            try? await Task.sleep(for: restartDelay)
            guard let self, self.generation == exitedGeneration else { return }
            self.launch()
        }
    }

    private func giveUp(_ failure: LocalModelServerError) {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        runDirectory.clear(runDirectory.keyURL, runDirectory.pidURL, runDirectory.socketURL)
        runDirectory.recordFailure(failure)
        state = .failed(failure)
    }

    private func writeKey() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LocalModelServerError.failed
        }
        let key = bytes.map { String(format: "%02x", $0) }.joined()
        guard FileManager.default.createFile(
            atPath: runDirectory.keyURL.path,
            contents: Data((key + "\n").utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw LocalModelServerError.runDirectoryUnsafe
        }
    }

    /// pid 文件记下的进程可能是上次 KEYI 异常退出时留下的 llama-server，仍占着内存；
    /// 删 pid 文件前先结束它，但只结束确实是自带 helper 的进程。
    private func terminateRecordedHelper() {
        guard let data = try? Data(contentsOf: runDirectory.pidURL),
              let text = String(data: data, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else {
            return
        }
        runDirectory.clear(runDirectory.pidURL)
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let helperPath = helperURL.resolvingSymlinksInPath().path
        guard path == helperPath || path.hasSuffix("/Contents/Helpers/llama/llama-server") else {
            return
        }
        kill(pid, SIGTERM)
    }
}
