import Foundation

public enum LocalTranslationModelTier: String, CaseIterable, Codable, Identifiable, Sendable {
    case light = "hy-mt2-1.8b-q4km"
    case standard = "hy-mt2-1.8b-q8"

    public var id: String { rawValue }
}

public struct LocalTranslationModel: Equatable, Sendable {
    public let tier: LocalTranslationModelTier
    public let displayName: String
    public let summary: String
    public let fileName: String
    public let byteCount: Int64
    public let sha256: String
    /// 按顺序尝试；前一个来源失败或校验不符时换下一个。
    public let downloadURLs: [URL]
    /// 标准档把场景、英语风格和输入框上下文写进提示词；轻量档只直译。
    public let usesSceneContext: Bool

    public init(
        tier: LocalTranslationModelTier,
        displayName: String,
        summary: String,
        fileName: String,
        byteCount: Int64,
        sha256: String,
        downloadURLs: [URL],
        usesSceneContext: Bool
    ) {
        self.tier = tier
        self.displayName = displayName
        self.summary = summary
        self.fileName = fileName
        self.byteCount = byteCount
        self.sha256 = sha256
        self.downloadURLs = downloadURLs
        self.usesSceneContext = usesSceneContext
    }
}

public struct LocalModelSampling: Equatable, Sendable {
    public let temperature: Double
    public let topP: Double
    public let topK: Int
    public let repeatPenalty: Double
    public let maxTokens: Int
}

/// 模型清单只有数据，Windows 版照抄同一份。
public enum LocalTranslationModelCatalog {
    public static let modelName = "腾讯混元 Hy-MT2-1.8B"
    public static let license = "Apache-2.0"
    public static let licenseURL = URL(
        string: "https://github.com/Tencent-Hunyuan/Hy-MT2/blob/main/LICENSE.txt"
    )!
    /// 采用 Hy-MT2 README 对 1.8B 推荐的推理参数，只把温度从 0.7 降到 0.2：
    /// 0.7 时同一句话每次译法不同，还会抽到意思跑偏的译文。
    public static let sampling = LocalModelSampling(
        temperature: 0.2,
        topP: 0.6,
        topK: 20,
        repeatPenalty: 1.05,
        maxTokens: 4096
    )

    private static let modelScopeBase =
        "https://modelscope.cn/models/Tencent-Hunyuan/Hy-MT2-1.8B-GGUF/resolve/ef1d40b8b315575d30d1eb6579996130b8fc0bb2/"
    private static let huggingFaceBase =
        "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/a0c709d9fac510f2c807aa3af52872340dc37a4a/"

    public static let models: [LocalTranslationModel] = [
        makeModel(
            tier: .light,
            displayName: "轻量",
            summary: "只直译",
            fileName: "Hy-MT2-1.8B-Q4_K_M.gguf",
            byteCount: 1_133_080_448,
            sha256: "dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699",
            usesSceneContext: false
        ),
        makeModel(
            tier: .standard,
            displayName: "标准",
            summary: "按场景和风格翻译",
            fileName: "Hy-MT2-1.8B-Q8_0.gguf",
            byteCount: 1_908_528_192,
            sha256: "5c3fe0b1408a5ceb0143184ef247b11b579c525f4b02b060e6c851bb76fef1a4",
            usesSceneContext: true
        )
    ]

    public static func model(for tier: LocalTranslationModelTier) -> LocalTranslationModel {
        models.first { $0.tier == tier }!
    }

    private static func makeModel(
        tier: LocalTranslationModelTier,
        displayName: String,
        summary: String,
        fileName: String,
        byteCount: Int64,
        sha256: String,
        usesSceneContext: Bool
    ) -> LocalTranslationModel {
        LocalTranslationModel(
            tier: tier,
            displayName: displayName,
            summary: summary,
            fileName: fileName,
            byteCount: byteCount,
            sha256: sha256,
            downloadURLs: [modelScopeBase, huggingFaceBase].map {
                URL(string: $0 + fileName)!
            },
            usesSceneContext: usesSceneContext
        )
    }
}

/// Hy-MT2 没有系统提示，只接受一条 user 消息；模板取自官方 README 的中文提示词。
public enum HyMTPromptBuilder {
    static let contextCharacterLimit = 1000

    public static func userMessage(
        for request: TextTranslationRequest,
        model: LocalTranslationModel,
        personal: PersonalGlossary = .standard
    ) -> String {
        let glossary = glossaryBlock(for: request, personal: personal)
        return glossary + translationMessage(for: request, model: model)
    }

    private static func translationMessage(
        for request: TextTranslationRequest,
        model: LocalTranslationModel
    ) -> String {
        let target = request.targetLanguage.displayName
        let background = model.usesSceneContext ? backgroundLines(for: request) : []
        guard !background.isEmpty else {
            return "将以下文本翻译为\(target)，注意只需要输出翻译后的结果，不要额外解释：\n\n\(request.sourceText)"
        }
        return """
        【背景信息】
        \(background.joined(separator: "\n"))

        请结合背景信息将以下文本翻译为\(target)。

        【待翻译文本】
        \(request.sourceText)
        """
    }

    private static func backgroundLines(for request: TextTranslationRequest) -> [String] {
        var lines: [String] = []
        if let scene = sceneLine(request.scene) {
            lines.append("场景：\(scene)")
        }
        // 不写英语风格：1.8B 模型基本不按「黑人英语」「英式」这类描述改写，反而更容易跑偏。
        if let context = request.contextText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !context.isEmpty,
           context != request.sourceText {
            lines.append("输入框全文（只作参考，不要翻译）：\n\(String(context.suffix(contextCharacterLimit)))")
        }
        return lines
    }

    /// 原文里出现的常用词按 Hy-MT2 官方「术语干预」模板放在最前面；没有命中时不加。
    /// 固定词表在前；个人术语表（用户打开时）补上固定词表没覆盖的词。
    private static func glossaryBlock(for request: TextTranslationRequest, personal: PersonalGlossary) -> String {
        guard request.targetLanguage == .english else { return "" }
        var hits = HyMTGlossary.englishEntries(in: request.sourceText)
        for term in personal.entries(in: request.sourceText)
        where !hits.contains(where: { $0.source.contains(term.source) || term.source.contains($0.source) }) {
            hits.append(HyMTGlossary.Entry(source: term.source, target: term.target))
        }
        guard !hits.isEmpty else { return "" }
        let lines = hits.map { "\($0.source) 翻译成 \($0.target)" }
        return "参考下面的翻译：\n\(lines.joined(separator: "\n"))\n\n"
    }

    private static func sceneLine(_ scene: TranslationScene) -> String? {
        switch scene {
        case .automatic:
            nil
        case .dailyChat:
            "日常聊天消息，语气自然、口语化，短回复保持简短。"
        case .socialMedia:
            "社交媒体上的帖子或回复，简洁自然，保留原文的幽默和情绪。"
        case .business:
            "商务或贸易沟通，礼貌、准确、专业；数字、日期、价格、数量和条款必须准确，不用俚语。"
        case .faithful:
            "忠实翻译，贴近原文的措辞和顺序，不意译，不润色。"
        }
    }
}

/// 本地模型常翻错的口语、网络用语和商务词。只收意思固定、放进任何句子都通顺的完整说法；
/// 含义随上下文变的（如「绷不住」单用的「笑死」）不收。数据与 Windows 版共用。
public enum HyMTGlossary {
    public struct Entry: Equatable, Sendable {
        public let source: String
        public let target: String

        public init(source: String, target: String) {
            self.source = source
            self.target = target
        }
    }

    public static let english: [Entry] = [
        ("在吗", "you around?"),
        ("阴阳怪气", "snide"),
        ("yyds", "the best ever"),
        ("笑死我了", "I can't stop laughing"),
        ("坐过站", "missed my stop"),
        ("就差你了", "we're just waiting on you"),
        ("太卷了", "such a workaholic"),
        ("抢钱", "highway robbery"),
        ("长点心", "get their act together"),
        ("楼下", "downstairs"),
        ("晚点回你", "I'll get back to you later"),
        ("求推荐", "looking for recommendations"),
        ("降噪", "noise cancellation"),
        ("单号", "tracking number"),
        ("预付", "upfront payment"),
        ("我靠", "damn")
    ].map { Entry(source: $0.0, target: $0.1) }

    /// 「老王」「小李」这类称呼保留拼音（Lao Wang、Xiao Li），不译成 Old Wang。
    /// 只收常见、不易与普通词混淆的姓（不收黄、高、马、白等）。
    static let surnames: [Character: String] = [
        "王": "Wang", "李": "Li", "张": "Zhang", "刘": "Liu", "陈": "Chen", "杨": "Yang",
        "赵": "Zhao", "周": "Zhou", "吴": "Wu", "徐": "Xu", "孙": "Sun", "胡": "Hu",
        "朱": "Zhu", "林": "Lin", "何": "He", "郭": "Guo", "罗": "Luo", "梁": "Liang",
        "宋": "Song", "郑": "Zheng", "谢": "Xie", "韩": "Han", "唐": "Tang", "冯": "Feng",
        "董": "Dong", "曹": "Cao", "袁": "Yuan", "邓": "Deng", "彭": "Peng", "蔡": "Cai"
    ]

    /// 原文里出现的词条：固定词表加「老/小 + 姓」称呼，按出现先后去重。
    public static func englishEntries(in text: String) -> [Entry] {
        var entries = english.filter { text.contains($0.source) }
        let characters = Array(text)
        for (prefix, surname) in zip(characters, characters.dropFirst()) {
            guard let pinyin = surnames[surname] else { continue }
            let title = switch prefix {
            case "老": "Lao"
            case "小": "Xiao"
            default: ""
            }
            guard !title.isEmpty else { continue }
            let entry = Entry(source: "\(prefix)\(surname)", target: "\(title) \(pinyin)")
            if !entries.contains(entry) { entries.append(entry) }
        }
        return entries
    }
}
