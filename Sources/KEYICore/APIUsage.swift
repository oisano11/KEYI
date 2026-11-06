import Foundation

/// 一次大模型请求的 token 用量，取自 OpenAI 兼容返回里的 `usage`。
public struct APITokenUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// 某天某个服务的累计：请求数和输入/输出 token。
public struct APIUsageTotals: Codable, Equatable, Sendable {
    public var requests: Int = 0
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0

    public init(requests: Int = 0, inputTokens: Int = 0, outputTokens: Int = 0) {
        self.requests = requests
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    mutating func add(_ usage: APITokenUsage) {
        requests += 1
        inputTokens += usage.inputTokens
        outputTokens += usage.outputTokens
    }
}

/// 每百万 token 的单价。中国大陆服务按人民币，xAI 与中转按美元，两种货币分开合计、不换算。
public struct APIPrice: Codable, Equatable, Sendable {
    public enum Currency: String, Codable, CaseIterable, Sendable {
        case cny
        case usd

        public var symbol: String { self == .cny ? "¥" : "$" }
    }

    public var inputPerMillion: Double
    public var outputPerMillion: Double
    public var currency: Currency

    public init(inputPerMillion: Double, outputPerMillion: Double, currency: Currency) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.currency = currency
    }

    public func cost(of totals: APIUsageTotals) -> Double {
        (Double(totals.inputTokens) * inputPerMillion
            + Double(totals.outputTokens) * outputPerMillion) / 1_000_000
    }
}

public enum APIPriceCatalog {
    /// 默认单价按各家默认模型的公开标价（2026-11 整理，缓存命中按未命中算，宁高勿低），
    /// 只用于估算，用户可在设置里改；中转站价格各不相同，默认 0，由用户自己填。
    public static func defaultPrice(for providerID: TranslationProviderID) -> APIPrice? {
        switch providerID {
        case .deepSeek: APIPrice(inputPerMillion: 2, outputPerMillion: 3, currency: .cny)
        case .qwen: APIPrice(inputPerMillion: 0.8, outputPerMillion: 2, currency: .cny)
        case .volcengine: APIPrice(inputPerMillion: 0.8, outputPerMillion: 2, currency: .cny)
        case .xAI: APIPrice(inputPerMillion: 2, outputPerMillion: 6, currency: .usd)
        case .relay: APIPrice(inputPerMillion: 0, outputPerMillion: 0, currency: .usd)
        case .appleSystem, .localModel: nil
        }
    }

    public static var billedProviders: [TranslationProviderID] {
        TranslationProviderID.allCases.filter { defaultPrice(for: $0) != nil }
    }
}

/// 按天记大模型用量和用户改过的单价，存成一个 JSON 文件。只存计数，不存原文或译文。
/// 同一进程内加锁；主应用和 KEYITerminal 偶尔同时写时最多丢一次计数，不影响翻译。
public final class APIUsageLedger: @unchecked Sendable {
    public struct Snapshot: Codable, Equatable, Sendable {
        /// "yyyy-MM-dd"（本地时区）→ 服务 → 累计。
        public var days: [String: [String: APIUsageTotals]] = [:]
        /// 服务 → 用户改过的单价；没有的用默认值。
        public var prices: [String: APIPrice] = [:]

        public init() {}

        public func price(for providerID: TranslationProviderID) -> APIPrice? {
            prices[providerID.rawValue] ?? APIPriceCatalog.defaultPrice(for: providerID)
        }

        public func totals(on day: String) -> [TranslationProviderID: APIUsageTotals] {
            var result: [TranslationProviderID: APIUsageTotals] = [:]
            for (key, value) in days[day] ?? [:] {
                if let id = TranslationProviderID(rawValue: key) { result[id] = value }
            }
            return result
        }

        /// 某天按货币合计的估算费用。
        public func cost(on day: String) -> [APIPrice.Currency: Double] {
            var result: [APIPrice.Currency: Double] = [:]
            for (id, totals) in self.totals(on: day) {
                guard let price = price(for: id) else { continue }
                result[price.currency, default: 0] += price.cost(of: totals)
            }
            return result
        }
    }

    /// 保留天数，旧的记录写入时顺手删掉。
    public static let retainedDays = 120

    public static let standard = APIUsageLedger(
        fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.keyi.input-translator", isDirectory: true)
            .appendingPathComponent("Statistics", isDirectory: true)
            .appendingPathComponent("api-usage.json")
    )

    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func snapshot() -> Snapshot {
        lock.withLock { load() }
    }

    public func record(
        providerID: TranslationProviderID,
        usage: APITokenUsage,
        date: Date = Date()
    ) {
        lock.withLock {
            var snapshot = load()
            let day = Self.dayKey(for: date)
            snapshot.days[day, default: [:]][providerID.rawValue, default: APIUsageTotals()].add(usage)
            prune(&snapshot, today: date)
            save(snapshot)
        }
    }

    public func setPrice(_ price: APIPrice?, for providerID: TranslationProviderID) {
        lock.withLock {
            var snapshot = load()
            snapshot.prices[providerID.rawValue] = price
            save(snapshot)
        }
    }

    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func load() -> Snapshot {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return Snapshot()
        }
        return snapshot
    }

    private func save(_ snapshot: Snapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    private func prune(_ snapshot: inout Snapshot, today: Date) {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retainedDays, to: today) else {
            return
        }
        let oldest = Self.dayKey(for: cutoff)
        snapshot.days = snapshot.days.filter { $0.key >= oldest }
    }
}
