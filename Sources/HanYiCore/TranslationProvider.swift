import Foundation

public enum TranslationProviderID: String, CaseIterable, Codable, Sendable {
    case appleSystem
    case deepSeek
    case qwen
    case volcengine
    case xAI
    case relay
    case localModel

    public var displayName: String {
        switch self {
        case .appleSystem: "苹果系统翻译"
        case .deepSeek: "DeepSeek"
        case .qwen: "通义千问"
        case .volcengine: "火山引擎"
        case .xAI: "xAI Grok"
        case .relay: "中转站 API"
        case .localModel: "Gemma 4 本地"
        }
    }

    public var requiresAPIConfiguration: Bool {
        switch self {
        case .deepSeek, .qwen, .volcengine, .xAI, .relay: true
        case .appleSystem, .localModel: false
        }
    }
}

public enum TranslationProviderStatus: String, Codable, Sendable {
    case available
    case planned
}

public struct TranslationProviderDescriptor: Equatable, Identifiable, Sendable {
    public let id: TranslationProviderID
    public let name: String
    public let status: TranslationProviderStatus

    public var isAvailable: Bool {
        status == .available
    }

    public init(
        id: TranslationProviderID,
        name: String? = nil,
        status: TranslationProviderStatus
    ) {
        self.id = id
        self.name = name ?? id.displayName
        self.status = status
    }
}

public enum TranslationProviderCatalog {
    public static let descriptors: [TranslationProviderDescriptor] = [
        TranslationProviderDescriptor(
            id: .appleSystem,
            status: .available
        ),
        TranslationProviderDescriptor(
            id: .deepSeek,
            status: .available
        ),
        TranslationProviderDescriptor(
            id: .qwen,
            status: .available
        ),
        TranslationProviderDescriptor(
            id: .volcengine,
            status: .available
        ),
        TranslationProviderDescriptor(
            id: .xAI,
            status: .available
        ),
        TranslationProviderDescriptor(
            id: .relay,
            status: .available
        ),
        TranslationProviderDescriptor(
            id: .localModel,
            status: .available
        )
    ]

    public static func descriptor(
        for id: TranslationProviderID
    ) -> TranslationProviderDescriptor {
        descriptors.first { $0.id == id }
            ?? TranslationProviderDescriptor(id: id, status: .planned)
    }
}

public struct APITranslationProviderProfile: Equatable, Identifiable, Sendable {
    public var id: TranslationProviderID { providerID }

    public let providerID: TranslationProviderID
    public let defaultEndpoint: String
    public let defaultModel: String

    public init(
        providerID: TranslationProviderID,
        defaultEndpoint: String,
        defaultModel: String
    ) {
        self.providerID = providerID
        self.defaultEndpoint = defaultEndpoint
        self.defaultModel = defaultModel
    }
}

public enum APITranslationProviderCatalog {
    public static let profiles: [APITranslationProviderProfile] = [
        APITranslationProviderProfile(
            providerID: .deepSeek,
            defaultEndpoint: "https://api.deepseek.com/chat/completions",
            defaultModel: "deepseek-chat"
        ),
        APITranslationProviderProfile(
            providerID: .qwen,
            defaultEndpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
            defaultModel: "qwen-plus"
        ),
        APITranslationProviderProfile(
            providerID: .volcengine,
            defaultEndpoint: "https://ark.cn-beijing.volces.com/api/v3/responses",
            defaultModel: "doubao-seed-translation-250915"
        ),
        APITranslationProviderProfile(
            providerID: .xAI,
            defaultEndpoint: "https://api.x.ai/v1/chat/completions",
            defaultModel: "grok-4.5"
        ),
        APITranslationProviderProfile(
            providerID: .relay,
            defaultEndpoint: "",
            defaultModel: "grok-4.5"
        )
    ]

    public static func profile(
        for providerID: TranslationProviderID
    ) -> APITranslationProviderProfile? {
        profiles.first { $0.providerID == providerID }
    }
}

public struct LocalModelProfile: Equatable, Sendable {
    public let defaultEndpoint: String
    public let defaultModel: String
    public let defaultLoadKey: String
    public let completionTokenBudget: Int
    public let idleTTLSeconds: Int

    public init(
        defaultEndpoint: String,
        defaultModel: String,
        defaultLoadKey: String,
        completionTokenBudget: Int,
        idleTTLSeconds: Int
    ) {
        self.defaultEndpoint = defaultEndpoint
        self.defaultModel = defaultModel
        self.defaultLoadKey = defaultLoadKey
        self.completionTokenBudget = completionTokenBudget
        self.idleTTLSeconds = idleTTLSeconds
    }
}

public enum LocalModelCatalog {
    public static let gemma4 = LocalModelProfile(
        defaultEndpoint: "http://127.0.0.1:1234/v1/chat/completions",
        defaultModel: "hanyi-gemma4",
        defaultLoadKey: "gemma-4-12b-it",
        completionTokenBudget: 1024,
        idleTTLSeconds: 180
    )
}

public enum TranslationScene: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case dailyChat
    case socialMedia
    case business
    case faithful

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: "自动判断"
        case .dailyChat: "日常聊天"
        case .socialMedia: "X / 社交媒体"
        case .business: "商务正式"
        case .faithful: "忠实直译"
        }
    }
}

public enum EnglishStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case standardAmerican
    case westCoast
    case blackAmerican
    case british

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: "自动 / 中性"
        case .standardAmerican: "标准美式"
        case .westCoast: "美国西海岸"
        case .blackAmerican: "Black American / 街头 AAVE"
        case .british: "英式英语"
        }
    }
}

public enum TranslationLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case russian = "ru"
    case portuguese = "pt"
    case italian = "it"
    case thai = "th"
    case vietnamese = "vi"
    case arabic = "ar"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .english: "英语"
        case .japanese: "日语"
        case .korean: "韩语"
        case .french: "法语"
        case .german: "德语"
        case .spanish: "西班牙语"
        case .russian: "俄语"
        case .portuguese: "葡萄牙语"
        case .italian: "意大利语"
        case .thai: "泰语"
        case .vietnamese: "越南语"
        case .arabic: "阿拉伯语"
        }
    }
}

public struct TextTranslationRequest: Sendable {
    public let sourceText: String
    public let contextText: String?
    public let sourceLanguage: String
    public let targetLanguage: TranslationLanguage
    public let scene: TranslationScene
    public let englishStyle: EnglishStyle

    public init(
        sourceText: String,
        contextText: String? = nil,
        sourceLanguage: String = "zh-Hans",
        targetLanguage: TranslationLanguage = .english,
        scene: TranslationScene = .automatic,
        englishStyle: EnglishStyle = .automatic
    ) {
        self.sourceText = sourceText
        self.contextText = contextText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.scene = scene
        self.englishStyle = englishStyle
    }
}

public protocol TranslationProvider: Sendable {
    var id: TranslationProviderID { get }

    func translate(_ request: TextTranslationRequest) async throws -> String
}

public struct TranslationPreferences: Codable, Equatable, Sendable {
    public var providerID: TranslationProviderID
    public var targetLanguage: TranslationLanguage
    public var scene: TranslationScene
    public var englishStyle: EnglishStyle

    public init(
        providerID: TranslationProviderID = .appleSystem,
        targetLanguage: TranslationLanguage = .english,
        scene: TranslationScene = .automatic,
        englishStyle: EnglishStyle = .automatic
    ) {
        self.providerID = providerID
        self.targetLanguage = targetLanguage
        self.scene = scene
        self.englishStyle = englishStyle
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case targetLanguage
        case scene
        case englishStyle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decode(
            TranslationProviderID.self,
            forKey: .providerID
        )
        targetLanguage = try container.decodeIfPresent(
            TranslationLanguage.self,
            forKey: .targetLanguage
        ) ?? .english
        scene = try container.decodeIfPresent(
            TranslationScene.self,
            forKey: .scene
        ) ?? .automatic
        englishStyle = try container.decodeIfPresent(
            EnglishStyle.self,
            forKey: .englishStyle
        ) ?? .automatic
    }
}
