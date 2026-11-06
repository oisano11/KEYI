import AppKit
import Foundation
import KEYICore
import KEYITranslationClient

/// 「统计」栏目的数据：读输入法写的每日字数、本应用记的大模型用量，
/// 用户词库的词数和导出由已安装的 KEYIIME 在独立进程里完成，清空交给正在运行的输入法。
@MainActor
final class StatisticsModel: ObservableObject {
    struct Day: Identifiable, Equatable {
        let key: String
        let words: KEYIDailyWordCounts
        let requests: Int
        let inputTokens: Int
        let outputTokens: Int
        let cost: [APIPrice.Currency: Double]

        var id: String { key }
    }

    static let shared = StatisticsModel()

    @Published private(set) var days: [Day] = []
    @Published private(set) var usage = APIUsageLedger.Snapshot()
    /// nil：还在数；-1：没装输入法或导出失败。
    @Published private(set) var learnedWords: Int?
    /// 按 App 学到的选词：记了几个 App、共多少条。
    @Published private(set) var appLearning: (apps: Int, entries: Int)?
    @Published private(set) var dictionaryMessage: String?
    @Published private(set) var dictionaryBusy = false

    private let ledger = APIUsageLedger.standard

    static let backupDirectory = KEYIUserDictionaryIPC.inputMethodSupportURL
        .appendingPathComponent("backups", isDirectory: true)

    var inputMethodInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: DictionaryUpdateModel.inputMethodExecutable.path)
    }

    func reload() {
        usage = ledger.snapshot()
        let words = KEYIDailyWordStats.load()
        let calendar = Calendar.current
        let today = Date()
        days = (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = APIUsageLedger.dayKey(for: date)
            let totals = usage.totals(on: key).values
            return Day(
                key: key,
                words: words[key] ?? KEYIDailyWordCounts(),
                requests: totals.reduce(0) { $0 + $1.requests },
                inputTokens: totals.reduce(0) { $0 + $1.inputTokens },
                outputTokens: totals.reduce(0) { $0 + $1.outputTokens },
                cost: usage.cost(on: key)
            )
        }
    }

    func price(for providerID: TranslationProviderID) -> APIPrice? {
        usage.price(for: providerID)
    }

    func setPrice(_ price: APIPrice?, for providerID: TranslationProviderID) {
        ledger.setPrice(price, for: providerID)
        reload()
    }

    // MARK: 用户词库

    func countLearnedWords() {
        guard inputMethodInstalled else {
            learnedWords = -1
            appLearning = nil
            return
        }
        appLearning = KEYIAppCandidateLearning.storedSummary()
        Task {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("keyi-user-dict-count-\(UUID().uuidString).txt")
            let count = await Self.exportDictionary(to: file)
            try? FileManager.default.removeItem(at: file)
            learnedWords = count
        }
    }

    func exportDictionary(strings: InterfaceStrings) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "KEYI-用户词库-\(Self.stamp()).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dictionaryBusy = true
        Task {
            let count = await Self.exportDictionary(to: url)
            dictionaryBusy = false
            dictionaryMessage = count >= 0 ? strings.statsExported(count) : strings.statsExportFailed
            if count >= 0 { learnedWords = count }
        }
    }

    /// 先导出备份；备份成功才请正在运行的输入法清空，输入法没回应就留下请求，下次启动时清空。
    func clearDictionary(strings: InterfaceStrings) {
        dictionaryBusy = true
        Task {
            try? FileManager.default.createDirectory(at: Self.backupDirectory, withIntermediateDirectories: true)
            let backup = Self.backupDirectory.appendingPathComponent("user-dictionary-\(Self.stamp()).txt")
            guard await Self.exportDictionary(to: backup) >= 0 else {
                dictionaryBusy = false
                dictionaryMessage = strings.statsClearFailed
                return
            }
            let succeeded = await Self.requestRunningInputMethodReset()
            if succeeded {
                dictionaryMessage = strings.statsCleared
                learnedWords = 0
                appLearning = (0, 0)
            } else {
                FileManager.default.createFile(
                    atPath: KEYIUserDictionaryIPC.pendingResetMarkerURL.path,
                    contents: Data()
                )
                dictionaryMessage = strings.statsClearPending
            }
            dictionaryBusy = false
        }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// 运行 `KEYIIME --export-user-dict`，返回词条数，失败为 -1。
    private static func exportDictionary(to file: URL) async -> Int {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = DictionaryUpdateModel.inputMethodExecutable
                process.arguments = ["--export-user-dict", file.path]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: -1)
                    return
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                let count = text.split(separator: "\n")
                    .first { $0.hasPrefix("entries=") }
                    .flatMap { Int($0.dropFirst("entries=".count)) }
                continuation.resume(returning: process.terminationStatus == 0 ? (count ?? -1) : -1)
            }
        }
    }

    /// 发清空请求，最多等 3 秒回应。
    private static func requestRunningInputMethodReset() async -> Bool {
        await withCheckedContinuation { continuation in
            let center = DistributedNotificationCenter.default()
            let state = ResetWait(continuation: continuation)
            state.observer = center.addObserver(
                forName: KEYIUserDictionaryIPC.resetFinished,
                object: nil,
                queue: .main
            ) { note in
                let succeeded = note.userInfo?[KEYIUserDictionaryIPC.succeededKey] as? String == "1"
                MainActor.assumeIsolated { state.finish(succeeded) }
            }
            center.postNotificationName(
                KEYIUserDictionaryIPC.resetRequest,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                MainActor.assumeIsolated { state.finish(false) }
            }
        }
    }
}

/// 只回一次：输入法的回应和 3 秒超时谁先到算谁。
@MainActor
private final class ResetWait {
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
