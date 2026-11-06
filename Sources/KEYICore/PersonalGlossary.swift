import Foundation

/// 个人术语表：把大模型风格翻译时的固定译法（专有名词、技术词、固定说法）留在本机，
/// 本地 Hy-MT2 翻译英文时按官方「参考下面的翻译」写法附上。默认关闭，用户打开才收集。
///
/// 设置窗口和翻译服务在不同进程，所以状态全在文件里：`glossary.json`（开关和词条）、
/// `pending.json`（还没提炼的整句，提炼一次即删）。每次读都按文件修改时间决定要不要重读。
public final class PersonalGlossary: @unchecked Sendable {
    public struct Term: Codable, Equatable, Sendable {
        public var source: String
        public var target: String
        /// 提炼时出现过几次（同一译法再次出现加一）。
        public var count: Int
        public var lastSeen: Date

        public init(source: String, target: String, count: Int = 1, lastSeen: Date = Date()) {
            self.source = source
            self.target = target
            self.count = count
            self.lastSeen = lastSeen
        }
    }

    /// 一次大模型翻译：原文和译文。
    public struct Sample: Codable, Equatable, Sendable {
        public var source: String
        public var translation: String

        public init(source: String, translation: String) {
            self.source = source
            self.translation = translation
        }
    }

    private struct State: Codable {
        var enabled = false
        var terms: [Term] = []
    }

    public static let standard = PersonalGlossary(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.keyi.input-translator", isDirectory: true)
            .appendingPathComponent("Glossary", isDirectory: true)
    )

    /// 攒够这么多句才提炼一次。
    public static let batchSize = 20
    /// 暂存最多这么多句；超出丢最早的。
    public static let pendingLimit = 60
    /// 术语表最多这么多条；超出先删最久没出现的。
    public static let termLimit = 500
    /// 一次翻译最多附这么多条个人术语，免得提示太长。
    public static let promptLimit = 8

    public let directory: URL
    private let lock = NSLock()
    private var cached = State()
    private var cachedDate: Date?

    public init(directory: URL) {
        self.directory = directory
    }

    private var stateURL: URL { directory.appendingPathComponent("glossary.json") }
    private var pendingURL: URL { directory.appendingPathComponent("pending.json") }

    // MARK: 开关与词条

    public var isEnabled: Bool { lock.withLock { state().enabled } }

    public var terms: [Term] { lock.withLock { state().terms } }

    /// 关闭时停止收集并清掉暂存的整句；已提炼的词条留着（用户可另行清空）。
    public func setEnabled(_ enabled: Bool) {
        lock.withLock {
            var current = state()
            current.enabled = enabled
            save(current)
            if !enabled { try? FileManager.default.removeItem(at: pendingURL) }
        }
    }

    public func remove(source: String) {
        lock.withLock {
            var current = state()
            current.terms.removeAll { $0.source == source }
            save(current)
        }
    }

    /// 清空词条和暂存，开关不变。
    public func clear() {
        lock.withLock {
            var current = state()
            current.terms = []
            save(current)
            try? FileManager.default.removeItem(at: pendingURL)
        }
    }

    /// 原文里出现的个人术语，长的优先、互不重叠，最多 `promptLimit` 条。关闭时为空。
    public func entries(in text: String) -> [Term] {
        let all: [Term] = lock.withLock {
            let current = state()
            return current.enabled ? current.terms : []
        }
        var picked: [Term] = []
        for term in all.sorted(by: { $0.source.count > $1.source.count }) where text.contains(term.source) {
            if picked.contains(where: { $0.source.contains(term.source) }) { continue }
            picked.append(term)
            if picked.count == Self.promptLimit { break }
        }
        return picked
    }

    // MARK: 收集与提炼

    /// 大模型翻译成功后调用。关闭时什么都不存；同一原文只留最新译文。返回暂存句数。
    @discardableResult
    public func collect(_ sample: Sample) -> Int {
        guard sample.source.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }),
              !sample.translation.isEmpty
        else { return pendingCount }
        return lock.withLock {
            guard state().enabled else { return 0 }
            var pending = loadPending().filter { $0.source != sample.source }
            pending.append(sample)
            if pending.count > Self.pendingLimit { pending.removeFirst(pending.count - Self.pendingLimit) }
            savePending(pending)
            return pending.count
        }
    }

    public var pendingCount: Int { lock.withLock { loadPending().count } }

    /// 取走全部暂存的整句（同时删除），交给提炼。
    public func takePending() -> [Sample] {
        lock.withLock {
            let pending = loadPending()
            try? FileManager.default.removeItem(at: pendingURL)
            return pending
        }
    }

    /// 合并提炼结果：只收在某句原文里原样出现、且译法出现在该句译文里的词对（防止模型编造）。
    /// 返回新增或更新的条数。
    @discardableResult
    public func merge(_ candidates: [(source: String, target: String)], from samples: [Sample], now: Date = Date()) -> Int {
        let accepted = candidates.compactMap { candidate -> Term? in
            let source = candidate.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = candidate.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2...12).contains(source.count), (1...40).contains(target.count),
                  source.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }),
                  samples.contains(where: {
                      $0.source.contains(source) && $0.translation.localizedCaseInsensitiveContains(target)
                  })
            else { return nil }
            return Term(source: source, target: target, lastSeen: now)
        }
        guard !accepted.isEmpty else { return 0 }
        return lock.withLock {
            var current = state()
            for term in accepted {
                if let index = current.terms.firstIndex(where: { $0.source == term.source }) {
                    if current.terms[index].target == term.target {
                        current.terms[index].count += 1
                    } else {
                        current.terms[index].target = term.target
                        current.terms[index].count = 1
                    }
                    current.terms[index].lastSeen = now
                } else {
                    current.terms.append(term)
                }
            }
            if current.terms.count > Self.termLimit {
                current.terms.sort { $0.lastSeen > $1.lastSeen }
                current.terms.removeLast(current.terms.count - Self.termLimit)
            }
            current.terms.sort { $0.source < $1.source }
            save(current)
            return accepted.count
        }
    }

    // MARK: 提炼提示

    public static let extractionSystemPrompt = """
    你从中译英的句子对里整理一份术语表。只收与语气、风格无关、换个场合也该这样翻的固定译法：\
    人名、地名、品牌、产品名、项目名、技术词、行业术语、固定说法。不收俚语、粗口、语气词、表情、\
    整句或常见普通词（如「今天」「我们」）。中文必须是原句里原样出现的 2 到 12 个字，英文必须是对应译文里原样出现的写法。\
    只输出 JSON 数组，每项形如 {"zh":"中文","en":"English"}；没有合适的就输出 []。
    """

    public static func extractionUserPrompt(_ samples: [Sample]) -> String {
        samples.enumerated().map { index, sample in
            "\(index + 1). 中文：\(sample.source)\n   英文：\(sample.translation)"
        }.joined(separator: "\n")
    }

    /// 解析模型返回的 JSON 数组；外面包了代码块或说明文字也能找出数组。
    public static func parseExtraction(_ text: String) -> [(source: String, target: String)] {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return items.compactMap { item in
            guard let zh = item["zh"] as? String, let en = item["en"] as? String else { return nil }
            return (zh, en)
        }
    }

    // MARK: 文件（调用方已持锁）

    private func state() -> State {
        let modified = (try? FileManager.default.attributesOfItem(atPath: stateURL.path))?[.modificationDate] as? Date
        if modified != cachedDate {
            cachedDate = modified
            cached = (try? Data(contentsOf: stateURL)).flatMap { try? Self.decoder.decode(State.self, from: $0) } ?? State()
        }
        return cached
    }

    private func save(_ state: State) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? Self.encoder.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
        cached = state
        cachedDate = (try? FileManager.default.attributesOfItem(atPath: stateURL.path))?[.modificationDate] as? Date
    }

    private func loadPending() -> [Sample] {
        (try? Data(contentsOf: pendingURL)).flatMap { try? Self.decoder.decode([Sample].self, from: $0) } ?? []
    }

    private func savePending(_ pending: [Sample]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? Self.encoder.encode(pending) else { return }
        try? data.write(to: pendingURL, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
