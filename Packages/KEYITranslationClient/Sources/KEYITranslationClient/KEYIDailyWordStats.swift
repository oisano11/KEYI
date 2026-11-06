import Foundation

/// 每天用 KEYI 拼音确认的汉字数和上屏的译文词数。输入法写、KEYI 可译设置窗口读；
/// 只存两个数，不存任何文字。
public struct KEYIDailyWordCounts: Codable, Equatable, Sendable {
    public var hanzi: Int = 0
    public var translatedWords: Int = 0

    public init(hanzi: Int = 0, translatedWords: Int = 0) {
        self.hanzi = hanzi
        self.translatedWords = translatedWords
    }
}

public final class KEYIDailyWordStats: @unchecked Sendable {
    /// 输入法 Application Support 下的统计文件；输入法与伴随应用都用这个位置。
    public static let standardFileURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.keyi.input-method", isDirectory: true)
        .appendingPathComponent("Statistics", isDirectory: true)
        .appendingPathComponent("daily-words.json")

    public static let shared = KEYIDailyWordStats(fileURL: standardFileURL)
    public static let retainedDays = 120

    public let fileURL: URL
    private let lock = NSLock()
    private var pending: [String: KEYIDailyWordCounts] = [:]
    private var flushScheduled = false
    private let flushDelay: TimeInterval
    private let queue = DispatchQueue(label: "com.keyi.daily-word-stats", qos: .utility)

    /// 计数先攒在内存里，`flushDelay` 秒后一次写盘，避免每个字都碰磁盘。
    public init(fileURL: URL, flushDelay: TimeInterval = 3) {
        self.fileURL = fileURL
        self.flushDelay = flushDelay
    }

    public func record(hanzi: Int = 0, translatedWords: Int = 0, date: Date = Date()) {
        guard hanzi > 0 || translatedWords > 0 else { return }
        let day = Self.dayKey(for: date)
        let shouldSchedule: Bool = lock.withLock {
            pending[day, default: KEYIDailyWordCounts()].hanzi += hanzi
            pending[day, default: KEYIDailyWordCounts()].translatedWords += translatedWords
            defer { flushScheduled = true }
            return !flushScheduled
        }
        if shouldSchedule {
            queue.asyncAfter(deadline: .now() + flushDelay) { [weak self] in self?.flush() }
        }
    }

    /// 立即写盘（退出前、测试里用）。
    public func flush() {
        let batch: [String: KEYIDailyWordCounts] = lock.withLock {
            defer { pending = [:]; flushScheduled = false }
            return pending
        }
        guard !batch.isEmpty else { return }
        var days = Self.load(from: fileURL)
        for (day, counts) in batch {
            days[day, default: KEYIDailyWordCounts()].hanzi += counts.hanzi
            days[day, default: KEYIDailyWordCounts()].translatedWords += counts.translatedWords
        }
        if let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retainedDays, to: Date()) {
            let oldest = Self.dayKey(for: cutoff)
            days = days.filter { $0.key >= oldest }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(days) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    /// "yyyy-MM-dd"（本地时区）→ 计数。
    public static func load(from fileURL: URL = standardFileURL) -> [String: KEYIDailyWordCounts] {
        guard let data = try? Data(contentsOf: fileURL),
              let days = try? JSONDecoder().decode([String: KEYIDailyWordCounts].self, from: data) else {
            return [:]
        }
        return days
    }

    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 文字里的汉字个数。
    public static func hanziCount(in text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F: count + 1
            default: count
            }
        }
    }

    /// 译文的词数，按系统分词（英文按空格分，日文等不靠空格的语言也能分）。
    public static func wordCount(in text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }
}

/// KEYI 可译设置窗口与输入法之间关于用户词库的约定。
/// 学到的词数和导出：伴随应用运行 `KEYIIME --export-user-dict <文件>`，在独立进程里从词库副本导出，
/// 不打断正在用的输入法。清空：伴随应用发 `resetRequest`，正在运行的输入法清空后回 `resetFinished`；
/// 输入法没在运行时改写 `pendingResetMarkerURL`，输入法下次启动、打开词库前清空。
public enum KEYIUserDictionaryIPC {
    public static let dictionaryName = "keyi_user"
    public static let resetRequest = Notification.Name("com.keyi.input-method.userDictionary.resetRequest")
    public static let resetFinished = Notification.Name("com.keyi.input-method.userDictionary.resetFinished")
    /// `resetFinished` 的 userInfo 里是否成功（"1"/"0"）。
    public static let succeededKey = "succeeded"

    public static let inputMethodSupportURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.keyi.input-method", isDirectory: true)
    public static let pendingResetMarkerURL = inputMethodSupportURL
        .appendingPathComponent("reset-user-dictionary.request")
    public static let liveDatabaseURL = inputMethodSupportURL
        .appendingPathComponent("Rime", isDirectory: true)
        .appendingPathComponent("\(dictionaryName).userdb", isDirectory: true)
}
