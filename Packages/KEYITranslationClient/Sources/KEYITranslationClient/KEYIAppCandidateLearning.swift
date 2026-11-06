import Foundation

/// 按 App 记住用户在某个拼音下选了哪个候选，下次在同一个 App 打同样的拼音时，把选过的词排到
/// 当前一页前面。Rime 的全局用户词库照旧自学习，这里只在它之上做按 App 的页内重排。
/// 只存在本机：App 标识、拼音、选的词、次数和最近时间；清空用户词库时一起清空。
public final class KEYIAppCandidateLearning: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// 按半衰期折算到 `lastUsed` 时刻的次数。
        public var count: Double
        public var lastUsed: TimeInterval
    }

    public static let standardFileURL = KEYIUserDictionaryIPC.inputMethodSupportURL
        .appendingPathComponent("AppLearning", isDirectory: true)
        .appendingPathComponent("app-candidates.json")

    public static let shared = KEYIAppCandidateLearning(fileURL: standardFileURL)

    /// 每个 App 最多记这么多条，超出时先淘汰最久没用的。
    public static let maxEntriesPerApp = 3000
    /// 多久不用，次数减半。
    public static let halfLifeDays: Double = 30

    /// nil：只在内存里（诊断用），不读写磁盘。
    public let fileURL: URL?
    private let lock = NSLock()
    private var apps: [String: [String: Entry]] = [:]
    private var loaded = false
    private var flushScheduled = false
    private let flushDelay: TimeInterval
    private let queue = DispatchQueue(label: "com.keyi.app-candidate-learning", qos: .utility)

    public init(fileURL: URL?, flushDelay: TimeInterval = 2) {
        self.fileURL = fileURL
        self.flushDelay = flushDelay
    }

    /// 用户在 `app` 里、拼音为 `input` 时选了 `word`。
    public func record(app: String, input: String, word: String, date: Date = Date()) {
        guard !app.isEmpty, !input.isEmpty, !word.isEmpty else { return }
        let now = date.timeIntervalSince1970
        let key = Self.key(input: input, word: word)
        let shouldSchedule: Bool = lock.withLock {
            loadIfNeeded()
            var entries = apps[app, default: [:]]
            let previous = entries[key].map { Self.decayed($0, to: now) } ?? 0
            entries[key] = Entry(count: previous + 1, lastUsed: now)
            if entries.count > Self.maxEntriesPerApp {
                let keep = Self.maxEntriesPerApp * 9 / 10
                let newest = entries.sorted { $0.value.lastUsed > $1.value.lastUsed }.prefix(keep)
                entries = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
            }
            apps[app] = entries
            guard fileURL != nil else { return false }
            defer { flushScheduled = true }
            return !flushScheduled
        }
        if shouldSchedule {
            queue.asyncAfter(deadline: .now() + flushDelay) { [weak self] in self?.flush() }
        }
    }

    /// 当前一页的显示顺序：`result[显示位置] = 原页内位置`。在这个 App、这个拼音下选过的词
    /// 按分数排到前面，其余保持 Rime 原顺序；没学过时返回 nil。
    public func order(
        _ candidates: [String],
        app: String,
        input: String,
        date: Date = Date()
    ) -> [Int]? {
        guard candidates.count > 1, !app.isEmpty, !input.isEmpty else { return nil }
        let now = date.timeIntervalSince1970
        let scores: [Double] = lock.withLock {
            loadIfNeeded()
            guard let entries = apps[app] else { return [] }
            return candidates.map { word in
                entries[Self.key(input: input, word: word)].map { Self.decayed($0, to: now) } ?? 0
            }
        }
        guard scores.contains(where: { $0 > 0 }) else { return nil }
        let order = candidates.indices.sorted { a, b in
            scores[a] != scores[b] ? scores[a] > scores[b] : a < b
        }
        return order == Array(candidates.indices) ? nil : order
    }

    /// 已学过的 App 数和条数（统计、测试用）。
    public func summary() -> (apps: Int, entries: Int) {
        lock.withLock {
            loadIfNeeded()
            return (apps.count, apps.values.reduce(0) { $0 + $1.count })
        }
    }

    /// 只读磁盘：记了几个 App、共多少条（KEYI 可译统计页用，不加载进内存）。文件不存在时为 (0, 0)。
    public static func storedSummary(fileURL: URL = standardFileURL) -> (apps: Int, entries: Int) {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([String: [String: Entry]].self, from: data)
        else { return (0, 0) }
        return (stored.count, stored.values.reduce(0) { $0 + $1.count })
    }

    /// 全部清空，连同磁盘上的文件。
    public func reset() {
        lock.withLock {
            apps = [:]
            loaded = true
        }
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// 立即写盘（测试里用；平时攒 `flushDelay` 秒后写一次）。
    public func flush() {
        guard let fileURL else { return }
        let snapshot: [String: [String: Entry]] = lock.withLock {
            flushScheduled = false
            return apps
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 调用方已持锁。
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([String: [String: Entry]].self, from: data)
        else { return }
        apps = stored
    }

    private static func key(input: String, word: String) -> String {
        "\(input)\u{1F}\(word)"
    }

    private static func decayed(_ entry: Entry, to now: TimeInterval) -> Double {
        let days = max(now - entry.lastUsed, 0) / 86_400
        return entry.count * pow(0.5, days / halfLifeDays)
    }
}
