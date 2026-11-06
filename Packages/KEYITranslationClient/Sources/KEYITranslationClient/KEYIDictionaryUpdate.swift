import Foundation

/// 雾凇拼音（rime-ice）全拼词表的更新：KEYI 可译联网查上游、说明更新了什么、用户确认后下载；
/// 输入法本身不联网，只负责试编译、在进程内重新部署，以及启动时让过期的副本让位给随包词表。
///
/// 新词表放进本机 Rime 用户目录的 `rime_ice/cn_dicts/`：Rime 找词表时先找用户目录、再找随包数据，
/// 所以不用改签名的应用包。退回就是删掉这些副本，回到随包版本。
public enum KEYIDictionaryUpdate {
    public static let repository = "iDvel/rime-ice"
    /// 只更新这五份全拼词表，和随包的词表链一致。
    public static let tableNames = ["8105", "base", "ext", "tencent", "others"]

    public static let reloadRequest = Notification.Name("com.keyi.input-method.dictionary.reloadRequest")
    public static let reloadFinished = Notification.Name("com.keyi.input-method.dictionary.reloadFinished")
    /// `reloadFinished` 的 userInfo 里是否成功（"1"/"0"）。
    public static let succeededKey = "succeeded"

    /// 一份词表快照的身份：上游提交和提交时间。
    public struct Version: Codable, Equatable, Sendable {
        public var commit: String
        public var date: Date

        public init(commit: String, date: Date) {
            self.commit = commit
            self.date = date
        }

        public var shortCommit: String { String(commit.prefix(7)) }
    }

    /// 文件位置。默认是真实位置，测试可以整体换到临时目录。
    public struct Locations: Sendable {
        /// Rime 用户目录（`…/com.keyi.input-method/Rime`）。
        public var rimeUserData: URL
        /// 更新记录、上一版备份放这里（`…/com.keyi.input-method/DictionaryUpdate`）。
        public var support: URL

        public init(rimeUserData: URL, support: URL) {
            self.rimeUserData = rimeUserData
            self.support = support
        }

        public static let standard = Locations(
            rimeUserData: KEYIUserDictionaryIPC.inputMethodSupportURL.appendingPathComponent("Rime", isDirectory: true),
            support: KEYIUserDictionaryIPC.inputMethodSupportURL.appendingPathComponent("DictionaryUpdate", isDirectory: true)
        )

        public var tablesDirectory: URL {
            rimeUserData.appendingPathComponent("rime_ice/cn_dicts", isDirectory: true)
        }
        public var installedRecord: URL { support.appendingPathComponent("installed.json") }
        public var previousDirectory: URL { support.appendingPathComponent("previous", isDirectory: true) }

        public func table(_ name: String, in directory: URL? = nil) -> URL {
            (directory ?? tablesDirectory).appendingPathComponent("\(name).dict.yaml")
        }
    }

    // MARK: 版本

    /// 随包词表的版本，写在 `RimeData/rime_ice/KEYI-VERSION.json`。
    public static func bundledVersion(rimeData: URL) -> Version? {
        decodeVersion(from: rimeData.appendingPathComponent("rime_ice/KEYI-VERSION.json"))
    }

    /// 用户目录里装着的更新版本；没装过为 nil（用的是随包词表）。
    public static func installedVersion(_ locations: Locations = .standard) -> Version? {
        guard tableNames.allSatisfy({ FileManager.default.fileExists(atPath: locations.table($0).path) }) else {
            return nil
        }
        return decodeVersion(from: locations.installedRecord)
    }

    /// 现在实际生效的版本。
    public static func effectiveVersion(rimeData: URL, _ locations: Locations = .standard) -> Version? {
        installedVersion(locations) ?? bundledVersion(rimeData: rimeData)
    }

    // MARK: 词条

    /// 词表里的词条（`词<Tab>拼音<Tab>权重`，`...` 之后、跳过注释）。不是词表格式时为 nil。
    public static func entries(in text: String) -> [(word: Substring, code: Substring)]? {
        guard let body = text.range(of: "\n...\n") else { return nil }
        var result: [(Substring, Substring)] = []
        for line in text[body.upperBound...].split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") { continue }
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard let word = fields.first, !word.isEmpty else { return nil }
            result.append((word, fields.count > 1 ? fields[1] : ""))
        }
        return result
    }

    /// 下载的词表能不能用：是词表格式、名字对得上、词条数不比原来少一成以上（防止下到半截的文件）。
    public static func isAcceptable(_ text: String, table name: String, previousCount: Int) -> Bool {
        guard text.contains("\nname: \(name)\n") || text.contains("\nname: \"\(name)\"\n"),
              let entries = entries(in: text), !entries.isEmpty
        else { return false }
        return entries.count * 10 >= previousCount * 9
    }

    /// 一次更新改了什么。
    public struct Change: Codable, Equatable, Sendable {
        public var added = 0
        public var removed = 0
        /// 新增的词举例（最多 `sampleLimit` 个）。
        public var addedSamples: [String] = []
        public var removedSamples: [String] = []

        public init() {}

        public static let sampleLimit = 8

        public mutating func merge(_ other: Change) {
            added += other.added
            removed += other.removed
            addedSamples = Array((addedSamples + other.addedSamples).prefix(Self.sampleLimit))
            removedSamples = Array((removedSamples + other.removedSamples).prefix(Self.sampleLimit))
        }
    }

    /// 两份词表之间按「词 + 拼音」比较。只改权重的不算增删。
    public static func change(from old: String, to new: String) -> Change {
        func keys(_ text: String) -> (Set<String>, [String]) {
            let list = (entries(in: text) ?? []).map { "\($0.word)\t\($0.code)" }
            return (Set(list), list)
        }
        let (oldKeys, _) = keys(old)
        let (newKeys, newOrder) = keys(new)
        var change = Change()
        for key in newOrder where !oldKeys.contains(key) {
            change.added += 1
            if change.addedSamples.count < Change.sampleLimit { change.addedSamples.append(word(of: key)) }
        }
        let gone = oldKeys.subtracting(newKeys)
        change.removed = gone.count
        change.removedSamples = gone.sorted().prefix(Change.sampleLimit).map(word(of:))
        return change
    }

    /// 从上游的 diff（GitHub compare 的 `patch`）估计改了什么：新增行减去同词同音的删除行。
    /// diff 太大时 GitHub 不给 `patch`，这时只能用行数估计，样例为空。
    public static func change(fromPatch patch: String?, additions: Int, deletions: Int) -> Change {
        var change = Change()
        guard let patch else {
            change.added = max(additions - deletions, 0)
            change.removed = max(deletions - additions, 0)
            return change
        }
        var plus: [String] = []
        var minus = Set<String>()
        for line in patch.split(separator: "\n") {
            guard line.count > 1, let sign = line.first, sign == "+" || sign == "-" else { continue }
            let content = line.dropFirst()
            if content.hasPrefix("#") || content.hasPrefix("++") || content.hasPrefix("--") { continue }
            let fields = content.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            let key = "\(fields[0])\t\(fields[1])"
            if sign == "+" { plus.append(key) } else { minus.insert(key) }
        }
        let plusSet = Set(plus)
        for key in plus where !minus.contains(key) {
            change.added += 1
            if change.addedSamples.count < Change.sampleLimit { change.addedSamples.append(word(of: key)) }
        }
        let gone = minus.subtracting(plusSet)
        change.removed = gone.count
        change.removedSamples = gone.sorted().prefix(Change.sampleLimit).map(word(of:))
        return change
    }

    private static func word(of key: String) -> String {
        String(key.split(separator: "\t", maxSplits: 1).first ?? "")
    }

    // MARK: 安装、退回、让位

    /// 把 `staged` 目录里的五份词表装进用户目录：原有副本先挪到 `previous/`，再写更新记录。
    public static func install(from staged: URL, version: Version, _ locations: Locations = .standard) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: locations.tablesDirectory, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: locations.previousDirectory)
        try fileManager.createDirectory(at: locations.previousDirectory, withIntermediateDirectories: true)
        for name in tableNames where fileManager.fileExists(atPath: locations.table(name).path) {
            try fileManager.moveItem(at: locations.table(name), to: locations.table(name, in: locations.previousDirectory))
        }
        if fileManager.fileExists(atPath: locations.installedRecord.path) {
            try? fileManager.moveItem(
                at: locations.installedRecord,
                to: locations.previousDirectory.appendingPathComponent("installed.json")
            )
        }
        for name in tableNames {
            try fileManager.copyItem(at: locations.table(name, in: staged), to: locations.table(name))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(version).write(to: locations.installedRecord, options: .atomic)
    }

    /// 退回随包版本：删掉用户目录里的副本和更新记录（上一版备份留着）。
    public static func restoreBundled(_ locations: Locations = .standard) {
        for name in tableNames { try? FileManager.default.removeItem(at: locations.table(name)) }
        try? FileManager.default.removeItem(at: locations.installedRecord)
    }

    /// 输入法启动、打开词库前调用：应用包自带的词表不比用户目录里的旧时，用户目录的副本让位。
    /// 返回是否删了副本。
    @discardableResult
    public static func yieldToNewerBundle(rimeData: URL, _ locations: Locations = .standard) -> Bool {
        guard let bundled = bundledVersion(rimeData: rimeData) else { return false }
        let anyCopy = tableNames.contains { FileManager.default.fileExists(atPath: locations.table($0).path) }
        guard anyCopy else { return false }
        if let installed = installedVersion(locations), installed.date > bundled.date { return false }
        restoreBundled(locations)
        return true
    }

    private static func decodeVersion(from url: URL) -> Version? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Version.self, from: data)
    }
}
