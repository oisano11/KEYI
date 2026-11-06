import Foundation
import KEYITranslationClient
import OSLog

/// 雾凇拼音词表更新（约定见 `KEYIDictionaryUpdate`）：每周查一次上游，有新版先说明改了什么，
/// 用户点「更新」才下载；下载后校验、交给 KEYI 拼音试编译，通过才装，装好请正在运行的输入法重新部署。
/// 只从 GitHub 读公开的词表和提交说明，不上传任何内容。
@MainActor
final class DictionaryUpdateModel: ObservableObject {
    /// 一次可装的更新：从哪个版本到哪个版本、上游 diff 估计的增删、上游提交说明。
    struct Offer: Codable, Equatable {
        var from: KEYIDictionaryUpdate.Version
        var to: KEYIDictionaryUpdate.Version
        var change: KEYIDictionaryUpdate.Change
        var notes: [String]
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(Offer)
        case downloading(Int, Int)
        case verifying
        case applying
        /// 装好了；`applied` 为 false 时输入法没在运行，下次打字时生效。
        case installed(KEYIDictionaryUpdate.Change, applied: Bool)
        case restored(applied: Bool)
        case failed(String)
    }

    static let shared = DictionaryUpdateModel()
    static let checkInterval: TimeInterval = 7 * 86_400

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var current: KEYIDictionaryUpdate.Version?
    @Published private(set) var isInstalledUpdate = false
    @Published private(set) var lastCheck: Date?

    private let logger = Logger(subsystem: "com.keyi.input-translator", category: "dictionary-update")
    private let defaults = UserDefaults.standard
    private let locations = KEYIDictionaryUpdate.Locations.standard
    private var timer: Timer?

    private enum Key {
        static let lastCheck = "dictionaryUpdate.lastCheck"
        static let offer = "dictionaryUpdate.offer"
        static let dismissed = "dictionaryUpdate.dismissedCommit"
    }

    nonisolated static let inputMethodExecutable = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Input Methods/KEYIIME.app/Contents/MacOS/KEYIIME")
    nonisolated static var bundledRimeData: URL {
        inputMethodExecutable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/RimeData", isDirectory: true)
    }

    private init() {
        lastCheck = defaults.object(forKey: Key.lastCheck) as? Date
        if let data = defaults.data(forKey: Key.offer), let offer = try? JSONDecoder.iso.decode(Offer.self, from: data) {
            phase = .available(offer)
        }
        refreshCurrent()
    }

    /// 有一份还没处理的更新，菜单栏据此显示「词库有更新…」。
    var pendingOffer: Offer? {
        if case let .available(offer) = phase { offer } else { nil }
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .verifying, .applying: true
        default: false
        }
    }

    func refreshCurrent() {
        current = KEYIDictionaryUpdate.effectiveVersion(rimeData: Self.bundledRimeData, locations)
        isInstalledUpdate = KEYIDictionaryUpdate.installedVersion(locations) != nil
        // 装好的更新可能已被更新的应用包取代；那份待装的更新也就不再新。
        if let offer = pendingOffer, let current, offer.to.date <= current.date { clearOffer() }
    }

    /// 启动时和之后每隔几小时调用：距上次检查满一周才真正去查。
    func startScheduledChecks() {
        checkIfDue()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { DictionaryUpdateModel.shared.checkIfDue() }
        }
    }

    func checkIfDue() {
        guard FileManager.default.isExecutableFile(atPath: Self.inputMethodExecutable.path) else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.checkInterval { return }
        check(userInitiated: false)
    }

    /// 查上游有没有比现在用的更新的全拼词表。自动检查时，用户点过「暂不」的那一版不再提。
    func check(userInitiated: Bool) {
        guard !isBusy else { return }
        refreshCurrent()
        guard let current else {
            // 读不到现在用的版本（没装输入法，或装的是没有版本记录的旧版）：自动检查不出声。
            phase = userInitiated ? .failed(InterfaceStrings.current.dictionaryNoInputMethod) : .idle
            return
        }
        phase = .checking
        Task {
            do {
                let offer = try await Self.fetchOffer(since: current)
                lastCheck = Date()
                defaults.set(lastCheck, forKey: Key.lastCheck)
                guard let offer else {
                    clearOffer()
                    phase = .upToDate
                    return
                }
                if !userInitiated, defaults.string(forKey: Key.dismissed) == offer.to.commit {
                    phase = .idle
                    return
                }
                defaults.set(try? JSONEncoder.iso.encode(offer), forKey: Key.offer)
                phase = .available(offer)
                logger.notice("dictionary update available \(offer.to.shortCommit, privacy: .public)")
            } catch {
                logger.error("dictionary check failed: \(error.localizedDescription, privacy: .public)")
                phase = userInitiated ? .failed(InterfaceStrings.current.dictionaryCheckFailed) : .idle
            }
        }
    }

    /// 「暂不」：这一版不装，自动检查也不再提它；有更新的版本时再说。
    func dismiss() {
        if let offer = pendingOffer { defaults.set(offer.to.commit, forKey: Key.dismissed) }
        clearOffer()
        phase = .idle
    }

    /// 「更新」：下载五份词表 → 校验 → 试编译 → 装进用户目录 → 请输入法重新部署。
    func install() {
        guard let offer = pendingOffer else { return }
        let strings = InterfaceStrings.current
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyi-rime-ice-\(offer.to.shortCommit)-\(UUID().uuidString)", isDirectory: true)
        Task {
            defer { try? FileManager.default.removeItem(at: staged) }
            do {
                try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
                var change = KEYIDictionaryUpdate.Change()
                for (index, name) in KEYIDictionaryUpdate.tableNames.enumerated() {
                    phase = .downloading(index + 1, KEYIDictionaryUpdate.tableNames.count)
                    let text = try await Self.download(table: name, commit: offer.to.commit)
                    let previous = Self.currentTableText(name, locations: locations) ?? ""
                    let previousCount = KEYIDictionaryUpdate.entries(in: previous)?.count ?? 0
                    guard KEYIDictionaryUpdate.isAcceptable(text, table: name, previousCount: previousCount) else {
                        throw UpdateError.invalidTable(name)
                    }
                    change.merge(KEYIDictionaryUpdate.change(from: previous, to: text))
                    try text.write(to: locations.table(name, in: staged), atomically: true, encoding: .utf8)
                }
                phase = .verifying
                guard await Self.runInputMethod(["--verify-dictionary", staged.path]) else {
                    throw UpdateError.didNotBuild
                }
                try KEYIDictionaryUpdate.install(from: staged, version: offer.to, locations)
                defaults.removeObject(forKey: Key.dismissed)
                clearOffer()
                phase = .applying
                let applied = await Self.requestReload()
                refreshCurrent()
                phase = .installed(change, applied: applied)
                logger.notice("dictionary updated to \(offer.to.shortCommit, privacy: .public) added=\(change.added) removed=\(change.removed)")
            } catch {
                logger.error("dictionary install failed: \(error.localizedDescription, privacy: .public)")
                phase = .failed(strings.dictionaryInstallFailed)
            }
        }
    }

    /// 退回随包版本：删掉用户目录里的副本，请输入法重新部署。
    func restoreBundled() {
        guard !isBusy else { return }
        KEYIDictionaryUpdate.restoreBundled(locations)
        phase = .applying
        Task {
            let applied = await Self.requestReload()
            refreshCurrent()
            phase = .restored(applied: applied)
        }
    }

    private func clearOffer() {
        defaults.removeObject(forKey: Key.offer)
        if pendingOffer != nil { phase = .idle }
    }

    // MARK: 上游

    enum UpdateError: LocalizedError {
        case http(Int)
        case invalidTable(String)
        case didNotBuild

        var errorDescription: String? {
            switch self {
            case let .http(status): "HTTP \(status)"
            case let .invalidTable(name): "invalid table \(name)"
            case .didNotBuild: "staged tables did not build"
            }
        }
    }

    private struct CommitItem: Decodable {
        struct Detail: Decodable {
            struct Person: Decodable { let date: Date }
            let message: String
            let committer: Person
        }
        let sha: String
        let commit: Detail
    }

    private struct Comparison: Decodable {
        struct File: Decodable {
            let filename: String
            let additions: Int
            let deletions: Int
            let patch: String?
        }
        let status: String
        let commits: [CommitItem]
        let files: [File]?
    }

    /// 上游最新一次改动全拼词表的提交比现在用的新，就返回一份更新说明；否则 nil。
    static func fetchOffer(since current: KEYIDictionaryUpdate.Version) async throws -> Offer? {
        let repository = KEYIDictionaryUpdate.repository
        let latest: [CommitItem] = try await fetchJSON("https://api.github.com/repos/\(repository)/commits?path=cn_dicts&per_page=1")
        guard let head = latest.first, head.sha != current.commit, head.commit.committer.date > current.date else {
            return nil
        }
        let comparison: Comparison = try await fetchJSON(
            "https://api.github.com/repos/\(repository)/compare/\(current.commit)...\(head.sha)"
        )
        guard comparison.status == "ahead" || comparison.status == "diverged" else { return nil }
        let wanted = Set(KEYIDictionaryUpdate.tableNames.map { "cn_dicts/\($0).dict.yaml" })
        var change = KEYIDictionaryUpdate.Change()
        for file in comparison.files ?? [] where wanted.contains(file.filename) {
            change.merge(KEYIDictionaryUpdate.change(fromPatch: file.patch, additions: file.additions, deletions: file.deletions))
        }
        let notes = comparison.commits.reversed()
            .map { $0.commit.message.split(separator: "\n").first.map(String.init) ?? "" }
            // 只留中文词表相关的说明；英文词库、Lua、CI 之类与这五份词表无关。
            .filter { $0.hasPrefix("dict") && !$0.hasPrefix("dict(en)") && !$0.contains("英文") }
        return Offer(
            from: current,
            to: KEYIDictionaryUpdate.Version(commit: head.sha, date: head.commit.committer.date),
            change: change,
            notes: Array(notes.prefix(8))
        )
    }

    private static func fetchJSON<T: Decodable>(_ address: String) async throws -> T {
        let data = try await fetch(address, accept: "application/vnd.github+json")
        return try JSONDecoder.iso.decode(T.self, from: data)
    }

    private static func download(table name: String, commit: String) async throws -> String {
        let data = try await fetch(
            "https://raw.githubusercontent.com/\(KEYIDictionaryUpdate.repository)/\(commit)/cn_dicts/\(name).dict.yaml",
            accept: "text/plain"
        )
        return String(decoding: data, as: UTF8.self)
    }

    private static func fetch(_ address: String, accept: String) async throws -> Data {
        guard let url = URL(string: address) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("KEYI-dictionary-update", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.http(status) }
        return data
    }

    // MARK: 本机

    /// 现在生效的那份词表的文字：用户目录里有更新副本就用它，否则用随包的。
    private static func currentTableText(_ name: String, locations: KEYIDictionaryUpdate.Locations) -> String? {
        let installed = locations.table(name)
        let bundled = bundledRimeData.appendingPathComponent("rime_ice/cn_dicts/\(name).dict.yaml")
        let url = FileManager.default.fileExists(atPath: installed.path) ? installed : bundled
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func runInputMethod(_ arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = inputMethodExecutable
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: false)
                    return
                }
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0)
            }
        }
    }

    /// 请正在运行的输入法重新部署，最多等 60 秒（编译要几秒）。输入法没在运行时返回 false，
    /// 它下次启动时会按新词表部署。
    private static func requestReload() async -> Bool {
        await withCheckedContinuation { continuation in
            let center = DistributedNotificationCenter.default()
            let state = ReloadWait(continuation: continuation)
            state.observer = center.addObserver(
                forName: KEYIDictionaryUpdate.reloadFinished,
                object: nil,
                queue: .main
            ) { note in
                let succeeded = note.userInfo?[KEYIDictionaryUpdate.succeededKey] as? String == "1"
                MainActor.assumeIsolated { state.finish(succeeded) }
            }
            center.postNotificationName(KEYIDictionaryUpdate.reloadRequest, object: nil, userInfo: nil, deliverImmediately: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                MainActor.assumeIsolated { state.finish(false) }
            }
        }
    }
}

/// 只回一次：输入法的回应和超时谁先到算谁。
@MainActor
private final class ReloadWait {
    var observer: NSObjectProtocol?
    private var continuation: CheckedContinuation<Bool, Never>?

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ succeeded: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        continuation.resume(returning: succeeded)
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
