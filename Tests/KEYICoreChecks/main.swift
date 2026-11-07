import Foundation
import KEYICore

private var checkCount = 0

@MainActor
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checkCount += 1
    guard condition() else {
        fatalError(message)
    }
}

let value = "你好🙂世界"
let emojiSelection = FocusedTextSelection.translationSelection(
    value: value,
    selectedRange: NSRange(location: 2, length: 2)
)
expect(emojiSelection?.text == "🙂", "应按 UTF-16 范围读取选择文本")
expect(
    emojiSelection?.replacing(in: value, with: "hi") == "你好hi世界",
    "应只替换选择范围"
)

let fullSelection = FocusedTextSelection.translationSelection(
    value: "你好",
    selectedRange: NSRange(location: 1, length: 0)
)
expect(fullSelection?.text == "你好", "无选择时应使用输入框全文")
expect(
    fullSelection?.range == NSRange(location: 0, length: 2),
    "全文范围应覆盖完整 UTF-16 长度"
)

let invalidSelection = FocusedTextSelection.translationSelection(
    value: "你好",
    selectedRange: NSRange(location: 3, length: 1)
)
expect(invalidSelection == nil, "越界选择必须被拒绝")

let terminalValue = "Last login\nuser@host ~/project %   帮我列出所有 Swift 文件  \n\n"
let terminalCommand = "帮我列出所有 Swift 文件"
let terminalCommandStart = (terminalValue as NSString).range(of: terminalCommand).location
let terminalSelection = TerminalCommandSelection.currentLine(
    in: terminalValue,
    cursorRange: NSRange(
        location: terminalCommandStart + (terminalCommand as NSString).length,
        length: 0
    )
)
expect(terminalSelection?.text == terminalCommand, "终端未选中时应只读取当前命令正文")
expect(
    terminalSelection?.replacing(in: terminalValue, with: "list all Swift files")
        == "Last login\nuser@host ~/project %   list all Swift files  \n\n",
    "终端回写应只替换命令正文"
)
expect(
    TerminalCommandSelection.currentLine(
        in: "user@host ~ %    \n",
        cursorRange: NSRange(location: 17, length: 0)
    ) == nil,
    "空终端命令不得发起翻译"
)
expect(
    TerminalCommandSelection.currentLine(
        in: "user@host ~ % 中文命令\n",
        cursorRange: NSRange(location: 4, length: 0)
    ) == nil,
    "光标位于提示符或历史文本时不得翻译当前行命令"
)
expect(
    TerminalCommandSelection.currentLine(
        in: "user@host ~ % 中文命令\n",
        cursorRange: NSRange(location: 16, length: 0)
    ) == nil,
    "光标位于命令正文中间时不得翻译整行命令"
)
expect(
    TerminalCommandSelection.isSafeReplacement("echo hello"),
    "单行终端译文应允许回写"
)
expect(
    !TerminalCommandSelection.isSafeReplacement("echo hello\necho world"),
    "含换行的终端译文不得回写或执行"
)
expect(
    !TerminalCommandSelection.isSafeReplacement("echo\thello"),
    "含控制字符的终端译文不得回写"
)
expect(
    {
        let ambiguousTerminalValue = "user@host ~ $ echo $ 中文\n"
        return TerminalCommandSelection.currentLine(
            in: ambiguousTerminalValue,
            cursorRange: NSRange(
                location: (ambiguousTerminalValue as NSString).length - 1,
                length: 0
            )
        ) == nil
    }(),
    "提示符边界有歧义时不得翻译部分命令"
)

let descriptors = TranslationProviderCatalog.descriptors
expect(descriptors.count == TranslationProviderID.allCases.count, "提供方目录应覆盖所有提供方")
expect(
    TranslationProviderCatalog.descriptor(for: .appleSystem).isAvailable,
    "系统翻译应是当前可用提供方"
)
expect(
    TranslationProviderCatalog.descriptor(for: .deepSeek).isAvailable,
    "DeepSeek 应标记为当前可用提供方"
)
expect(
    TranslationProviderCatalog.descriptor(for: .qwen).isAvailable,
    "通义千问应标记为当前可用提供方"
)
expect(
    TranslationProviderCatalog.descriptor(for: .volcengine).isAvailable,
    "火山方舟应标记为当前可用提供方"
)
expect(
    TranslationProviderCatalog.descriptor(for: .xAI).isAvailable,
    "Grok 应标记为当前可用提供方"
)
expect(
    TranslationProviderCatalog.descriptor(for: .relay).isAvailable,
    "自定义服务应标记为当前可用提供方"
)
expect(
    TranslationProviderCatalog.descriptor(for: .localModel).isAvailable,
    "本地模型应标记为当前可用提供方"
)
expect(
    TranslationProviderCatalog.descriptor(for: .localModel).name == "本地模型",
    "本地提供方应使用通用产品名称"
)
let apiProfiles = APITranslationProviderCatalog.profiles
expect(apiProfiles.count == 5, "应提供五家云模型 API 配置")
expect(
    Set(apiProfiles.map(\.providerID)) == Set([.deepSeek, .qwen, .volcengine, .xAI, .relay]),
    "API 配置目录应覆盖四家云模型和独立中转站"
)
expect(
    apiProfiles
        .filter { $0.providerID != .relay }
        .allSatisfy {
            URL(string: $0.defaultEndpoint)?.scheme == "https" && !$0.defaultModel.isEmpty
        },
    "云模型默认 Endpoint 必须为 HTTPS 且模型名非空"
)
let volcengineProfile = APITranslationProviderCatalog.profile(for: .volcengine)
expect(
    volcengineProfile?.defaultEndpoint == "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
    "火山默认应使用 Chat Completions"
)
expect(
    volcengineProfile?.defaultModel == "doubao-seed-1-6-250615",
    "火山默认模型应能跟随自定义提示词"
)
expect(
    VolcengineChatCompletionsMigration.migratedEndpoint(
        "https://ark.cn-beijing.volces.com/api/v3/responses"
    ) == "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
    "旧火山 Responses 地址应迁到 Chat Completions"
)
expect(
    VolcengineChatCompletionsMigration.migratedModel(
        "doubao-seed-translation-250915"
    ) == "doubao-seed-1-6-250615",
    "旧火山翻译模型应迁到可跟提示词的模型"
)
let relayProfile = APITranslationProviderCatalog.profile(for: .relay)
expect(
    relayProfile?.defaultEndpoint.isEmpty == true,
    "中转站不应内置默认 Endpoint，地址须由用户自行填写"
)
expect(
    relayProfile?.defaultModel == "grok-4.5",
    "中转站默认模型应保持可编辑且有默认值"
)

let preferences = TranslationPreferences(providerID: .localModel)
let encodedPreferences = try! JSONEncoder().encode(preferences)
let decodedPreferences = try! JSONDecoder().decode(
    TranslationPreferences.self,
    from: encodedPreferences
)
expect(decodedPreferences == preferences, "翻译偏好应可稳定编解码")

let legacyPreferencesData = Data(#"{"providerID":"deepSeek"}"#.utf8)
let legacyPreferences = try! JSONDecoder().decode(
    TranslationPreferences.self,
    from: legacyPreferencesData
)
expect(legacyPreferences.scene == .automatic, "旧偏好应默认使用自动场景")
expect(legacyPreferences.englishStyle == .automatic, "旧偏好应默认使用中性风格")
expect(legacyPreferences.targetLanguage == .english, "旧偏好应默认翻译为英语")
expect(legacyPreferences.interfaceLanguage == .automatic, "旧偏好应默认跟随系统界面语言")
expect(TranslationScene.dailyChat.displayName == "聊天", "场合短标签应为聊天")
expect(TranslationScene.socialMedia.displayName == "发帖", "场合短标签应为发帖")
expect(TranslationScene.faithful.displayName == "贴近原文", "场合短标签应为贴近原文")
expect(EnglishStyle.automatic.displayName == "自然", "语气短标签应为自然")
expect(EnglishStyle.blackAmerican.displayName == "黑人英语", "语气短标签应为黑人英语")
expect(
    !TranslationPromptBuilder.usesEnglishStyle(language: .japanese, scene: .dailyChat),
    "语气仅适用于英语"
)
expect(
    !TranslationPromptBuilder.usesEnglishStyle(language: .english, scene: .faithful),
    "贴近原文不得使用语气"
)

expect(TranslationLanguage.allCases.count == 13, "国内版应提供十三种常用目标语言")
expect(
    Set(TranslationLanguage.allCases.map(\.rawValue)).count
        == TranslationLanguage.allCases.count,
    "目标语言代码不得重复"
)
expect(TranslationLanguage(rawValue: "zh-Hans") == .chinese, "中文目标语言应使用 zh-Hans")
let chinesePrompt = TranslationPromptBuilder.systemPrompt(
    for: TextTranslationRequest(
        sourceText: "Hello",
        sourceLanguage: "auto",
        targetLanguage: .chinese
    )
)
expect(
    chinesePrompt.contains("Detect the source language and translate to zh-Hans"),
    "中文目标语言应自动识别源语言"
)
let japanesePreferences = TranslationPreferences(
    providerID: .qwen,
    targetLanguage: .japanese
)
let persistedJapanesePreferences = try! JSONDecoder().decode(
    TranslationPreferences.self,
    from: JSONEncoder().encode(japanesePreferences)
)
expect(
    persistedJapanesePreferences.targetLanguage == .japanese,
    "目标语言选择应可持久化"
)

let styledRequest = TextTranslationRequest(
    sourceText: "这也太离谱了",
    contextText: "回复：这也太离谱了",
    scene: .socialMedia,
    englishStyle: .british
)
let systemPrompt = TranslationPromptBuilder.systemPrompt(for: styledRequest)
let userPrompt = TranslationPromptBuilder.userPrompt(for: styledRequest)
let localSystemPrompt = TranslationPromptBuilder.localSystemPrompt(for: styledRequest)
let localUserPrompt = TranslationPromptBuilder.localUserPrompt(for: styledRequest)
expect(systemPrompt.contains("public social-media posts and replies"), "提示词应包含社交媒体场景")
expect(systemPrompt.contains("British English"), "提示词应包含英式英语风格")
expect(systemPrompt.contains("contextual examples, not mandatory translations"), "多义表达示例必须按上下文理解")
expect(systemPrompt.contains("I broke down") && systemPrompt.contains("That's unreasonable"), "应区分悲伤和严肃投诉")
expect(!userPrompt.contains("full_input_context"), "云端请求不得包含未选中的输入框上下文")
expect(userPrompt.contains("这也太离谱了"), "请求应包含待翻译文本")
expect(localSystemPrompt.count < systemPrompt.count, "本地模型应使用更紧凑的提示词降低输出延迟")
expect(localSystemPrompt.contains("public social-media posts and replies") && localSystemPrompt.contains("British English"), "本地提示词应保留场景和风格")
expect(localUserPrompt.contains("full_input_context") && localUserPrompt.contains("这也太离谱了"), "本地请求应保留正文和本地上下文")

let expressiveBlackAmericanRequest = TextTranslationRequest(
    sourceText: "兄弟，这也太离谱了",
    scene: .socialMedia,
    englishStyle: .blackAmerican
)
let expressiveBlackAmericanPrompt = TranslationPromptBuilder.systemPrompt(for: expressiveBlackAmericanRequest)
expect(expressiveBlackAmericanPrompt.contains("not a slang quota"), "Black American 默认不得变成俚语配额")
expect(expressiveBlackAmericanPrompt.contains("a neutral message can be understated without erasing the voice"), "中性原文可以克制，但不应抹掉所选语气")
expect(expressiveBlackAmericanPrompt.contains("syntax, rhythm"), "Black American 应优先节奏和句法")
expect(!expressiveBlackAmericanPrompt.contains("street"), "Black American 不应被定义为街头表达")
expect(!expressiveBlackAmericanPrompt.contains("at least one or two"), "Black American 不得要求每句塞标记")

let japaneseRequest = TextTranslationRequest(
    sourceText: "你好",
    targetLanguage: .japanese,
    scene: .dailyChat,
    englishStyle: .blackAmerican
)
let japanesePrompt = TranslationPromptBuilder.systemPrompt(for: japaneseRequest)
expect(japanesePrompt.contains("zh-Hans to ja"), "非英语提示词应传入目标语言代码")
expect(japanesePrompt.contains("everyday messages between people"), "非英语提示词应保留全语种场景")
expect(japanesePrompt.contains("Scene guidance"), "非英语翻译仍应使用场景")
expect(!japanesePrompt.contains("English voice guidance"), "非英语翻译不得注入英语风格段落")
expect(!japanesePrompt.contains("Black American"), "非英语翻译不得注入英语风格")

let businessRequest = TextTranslationRequest(
    sourceText: "请确认订单数量为 1200 件，单价 3.5 美元。",
    scene: .business,
    englishStyle: .blackAmerican
)
let businessPrompt = TranslationPromptBuilder.systemPrompt(for: businessRequest)
expect(businessPrompt.contains("business or trade register"), "商务场景应使用商务/贸易语域")
expect(businessPrompt.contains("exact meaning"), "商务场景应优先准确表达")
expect(businessPrompt.contains("commercial misunderstanding"), "商务场景应避免商业误解")
expect(!businessPrompt.contains("Black American"), "商务场景不得注入黑人美式风格")

let businessLocalPrompt = TranslationPromptBuilder.localSystemPrompt(for: businessRequest)
expect(businessLocalPrompt.contains("Prioritise exact meaning over style"), "本地商务提示词应优先准确表达")
expect(!businessLocalPrompt.contains("Black American"), "本地商务提示词不得注入黑人美式风格")

// These checks validate prompt contracts, not model output or native-speaker quality.
let englishStyleMarkers: [(EnglishStyle, String)] = [
    (.automatic, "Use neutral, contemporary native English"),
    (.standardAmerican, "Use contemporary standard American English"),
    (.westCoast, "Use relaxed contemporary American conversational English"),
    (.blackAmerican, "The user chose contemporary Black American conversational English"),
    (.british, "Use natural contemporary British English")
]
expect(englishStyleMarkers.count == EnglishStyle.allCases.count, "风格测试应覆盖全部选项")
let sharedMeaningRules = [
    "Judge the whole utterance by idiom, rhythm, register, and emotional effect",
    "Preserve facts, referents, time, habituality, negation, certainty, commitments, relationships, and communicative intent.",
    "Reshape syntax, word order, sentence boundaries, grammatical tense",
    "An idiomatic or colloquial equivalent does not need a matching word in the source.",
    "Plain sentences can be plain; expressive sentences should keep their personality.",
    "Preserve profanity already present in the source with equivalent force and target.",
    "Never add profanity the source does not have.",
    "Do not invent slurs, threats, or personal attacks.",
    "Use punctuation natural to English."
]
let addedProfanityPermission = "you may add idiomatic profanity even when the source has no literal swear word"
let blackAmericanConstraints = [
    "not a slang quota",
    "not synonymous with slang or profanity",
    "Authentic dialect grammar is valid English, not an error to automatically standardise away",
    "habitual forms express recurring behaviour, not an action happening only now",
    "never through added swearing: if the source has no swear word, the translation has none",
    "never as \"You up?\"",
    "Keep situational frustration aimed at the situation, not a new personal target"
]
let otherEnglishStyleRules: [EnglishStyle: [String]] = [
    .automatic: [
        "warm stays warm, blunt stays blunt, playful stays playful",
        "widely understood wording and a consistent variety",
        "Natural does not mean formal, bland, or stripped of personality"
    ],
    .standardAmerican: [
        "consistent US spelling and vocabulary",
        "Everyday contractions, phrasal verbs, conversational idioms, and natural short replies belong here",
        "Prefer conventional written forms, with the source's personality intact"
    ],
    .westCoast: [
        "rhythm of a real text message",
        "they are options, not a checklist",
        "Casual does not mean less precise about plans, duties, uncertainty, or promises"
    ],
    .british: [
        "consistent UK spelling, vocabulary, and conversational grammar",
        "they are neither required nor forbidden",
        "British does not automatically mean posh, reserved, more polite, or less enthusiastic"
    ]
]
for scene in TranslationScene.allCases {
    let styleEnabled = scene != .business && scene != .faithful
    for (style, _) in englishStyleMarkers {
        let request = TextTranslationRequest(
            sourceText: "今天下午3点开会。",
            scene: scene,
            englishStyle: style
        )
        let cloud = TranslationPromptBuilder.systemPrompt(for: request)
        let local = TranslationPromptBuilder.localSystemPrompt(for: request)
        expect(local.count < cloud.count, "本地包装仍应比云端精简")
        for prompt in [cloud, local] {
            for rule in sharedMeaningRules {
                expect(prompt.contains(rule), "云端和本地都应保留共同语义约束: \(rule)")
            }
            for (candidate, marker) in englishStyleMarkers {
                expect(
                    prompt.contains(marker) == (styleEnabled && candidate == style),
                    "风格段启停不正确: \(scene)/\(style)/\(candidate)"
                )
            }
            expect(!prompt.contains(addedProfanityPermission), "任何风格都不得允许原文没有的脏话")
            if styleEnabled && style == .blackAmerican {
                for constraint in blackAmericanConstraints {
                    expect(prompt.contains(constraint), "黑人英语风格必须保留边界: \(constraint)")
                }
            }
            for (candidate, rules) in otherEnglishStyleRules {
                for rule in rules {
                    expect(
                        prompt.contains(rule) == (styleEnabled && style == candidate),
                        "风格规则不得遗漏或串档: \(scene)/\(style)/\(candidate)/\(rule)"
                    )
                }
            }
            expect(!prompt.contains("Do not change tense"), "语义保真不得冻结英语时态形式")
            expect(!prompt.contains("Do not add slang or profanity unless"), "自然口语不需要原文逐词许可")
            if scene == .automatic {
                expect(prompt.contains("ignore the conversational voice"), "自动商务和措辞敏感场景必须覆盖口语风格")
                expect(prompt.contains("Ordinary factual text can retain the selected variety's natural vocabulary and spelling"), "普通事实不能一律抹掉英美用词差异")
                expect(prompt.contains("If uncertain, choose neutral natural English"), "不确定时不得默认强行聊天化")
            }
        }
        for language in TranslationLanguage.allCases where language != .english {
            let nonEnglish = TextTranslationRequest(
                sourceText: "你好",
                targetLanguage: language,
                scene: scene,
                englishStyle: style
            )
            for prompt in [
                TranslationPromptBuilder.systemPrompt(for: nonEnglish),
                TranslationPromptBuilder.localSystemPrompt(for: nonEnglish)
            ] {
                expect(!prompt.contains(addedProfanityPermission), "非英语不得获得额外脏话许可")
                expect(!englishStyleMarkers.contains { prompt.contains($0.1) }, "非英语不得注入任何英语风格段")
                expect(!prompt.contains("An idiomatic or colloquial equivalent"), "非英语不得注入英语表达合同")
            }
        }
    }
}


// MARK: - OpenAI 兼容提供方 HTTP 语义（URLProtocol 桩）

private let stubSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}()

// 检查程序串行执行，桩的状态只在"设置响应 → 发起请求 → 读取记录"之间
// 流转，不存在并发访问；nonisolated(unsafe) 仅用于满足 Swift 6 检查。
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var respond: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) private(set) static var lastRequest: URLRequest?
    nonisolated(unsafe) private(set) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let respond = Self.respond else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        Self.lastRequest = request
        Self.lastBody = Self.readBody(of: request)
        let (status, payload) = respond(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://stub.test")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    // URLSession 会把 httpBody 挪进 httpBodyStream，需要从流里读回。
    static func readBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let capacity = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: capacity)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private func stubBodyJSON() -> [String: Any] {
    try! JSONSerialization.jsonObject(with: StubURLProtocol.lastBody ?? Data()) as! [String: Any]
}

StubURLProtocol.respond = { _ in
    (200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"  Hello.  \"}}]}")
}
let stubChatProvider = OpenAICompatibleTranslationProvider(
    configuration: APIProviderConfiguration(
        providerID: .deepSeek,
        apiKey: "test-secret",
        endpoint: URL(string: "https://example.test/chat/completions")!,
        model: "deepseek-chat"
    ),
    session: stubSession
)
let stubChatResult = try await stubChatProvider.translate(
    TextTranslationRequest(
        sourceText: "你好",
        targetLanguage: .english,
        scene: .faithful
    )
)
expect(stubChatResult == "Hello.", "Chat 译文应去除首尾空白")
expect(StubURLProtocol.lastRequest?.httpMethod == "POST", "翻译请求应为 POST")
expect(
    StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization")
        == "Bearer test-secret",
    "应携带 Bearer API Key"
)
expect(
    StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type")
        == "application/json",
    "应声明 JSON Content-Type"
)
let chatBodyText = String(data: StubURLProtocol.lastBody ?? Data(), encoding: .utf8) ?? ""
expect(chatBodyText.contains("\"model\":\"deepseek-chat\""), "请求体应包含模型名")
expect(chatBodyText.contains("\"temperature\":0"), "忠实直译应使用 0 温度")
let chatMessages = stubBodyJSON()["messages"] as! [[String: Any]]
expect(
    (chatMessages[0]["content"] as! String).contains("zh-Hans to en"),
    "系统提示词应包含语言对"
)
let chatUserContent = chatMessages[1]["content"] as! String
let chatPayload = try! JSONSerialization.jsonObject(
    with: Data(chatUserContent[chatUserContent.firstIndex(of: "{")!...].utf8)
) as! [String: Any]
expect(chatPayload["source_text"] as? String == "你好", "用户负载应携带待翻译文本")
expect(chatPayload["full_input_context"] == nil, "云端请求不得携带完整输入框上下文")

StubURLProtocol.respond = { _ in
    (200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"  こんにちは。  \"}}]}")
}
let stubVolcResult = try await OpenAICompatibleTranslationProvider(
    configuration: APIProviderConfiguration(
        providerID: .volcengine,
        apiKey: "test-secret",
        endpoint: URL(string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")!,
        model: "doubao-seed-1-6-250615"
    ),
    session: stubSession
).translate(TextTranslationRequest(sourceText: "你好", targetLanguage: .japanese))
expect(stubVolcResult == "こんにちは。", "火山 Chat Completions 译文应去除首尾空白")
let volcBodyJSON = stubBodyJSON()
let volcMessages = volcBodyJSON["messages"] as! [[String: Any]]
let volcUserContent = volcMessages[1]["content"] as! String
let volcPayload = try! JSONSerialization.jsonObject(
    with: Data(volcUserContent[volcUserContent.firstIndex(of: "{")!...].utf8)
) as! [String: Any]
expect(volcPayload["source_text"] as? String == "你好", "火山请求应发送原始待翻译文本")
expect(volcPayload["full_input_context"] == nil, "火山请求不得携带完整输入框上下文")

// 费用统计：返回里的 usage 交给记录器，按天累计并按单价估算。
final class UsageBox: @unchecked Sendable { var calls: [(TranslationProviderID, APITokenUsage)] = [] }
let usageBox = UsageBox()
StubURLProtocol.respond = { _ in
    (200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Hi\"}}],\"usage\":{\"prompt_tokens\":120,\"completion_tokens\":8,\"total_tokens\":128}}")
}
_ = try await OpenAICompatibleTranslationProvider(
    configuration: APIProviderConfiguration(
        providerID: .qwen,
        apiKey: "test-secret",
        endpoint: URL(string: "https://example.test/chat/completions")!,
        model: "qwen-plus"
    ),
    session: stubSession,
    usageRecorder: { usageBox.calls.append(($0, $1)) }
).translate(TextTranslationRequest(sourceText: "你好", targetLanguage: .english))
expect(usageBox.calls.count == 1, "有 usage 的返回应记一次用量")
expect(usageBox.calls.first?.0 == .qwen, "用量应记在发出请求的服务名下")
expect(usageBox.calls.first?.1 == APITokenUsage(inputTokens: 120, outputTokens: 8), "应读出输入/输出 token")
_ = try await stubChatProvider.translate(TextTranslationRequest(sourceText: "你好", targetLanguage: .english))
expect(usageBox.calls.count == 1, "没传记录器的提供方不记用量")

let ledgerURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("keyi-usage-\(UUID().uuidString).json")
defer { try? FileManager.default.removeItem(at: ledgerURL) }
let ledger = APIUsageLedger(fileURL: ledgerURL)
let usageDay = Date(timeIntervalSince1970: 1_800_000_000)
ledger.record(providerID: .deepSeek, usage: APITokenUsage(inputTokens: 1_000_000, outputTokens: 500_000), date: usageDay)
ledger.record(providerID: .deepSeek, usage: APITokenUsage(inputTokens: 0, outputTokens: 500_000), date: usageDay)
ledger.record(providerID: .xAI, usage: APITokenUsage(inputTokens: 500_000, outputTokens: 0), date: usageDay)
let usageKey = APIUsageLedger.dayKey(for: usageDay)
let usageSnapshot = APIUsageLedger(fileURL: ledgerURL).snapshot()
expect(usageSnapshot.totals(on: usageKey)[.deepSeek] == APIUsageTotals(requests: 2, inputTokens: 1_000_000, outputTokens: 1_000_000), "同一天同一服务应累加")
expect(usageSnapshot.cost(on: usageKey)[.cny] == 5, "DeepSeek 默认单价 ¥2/¥3 每百万应估算为 ¥5")
expect(usageSnapshot.cost(on: usageKey)[.usd] == 1, "xAI 默认 $2 每百万输入应估算为 $1")
ledger.setPrice(APIPrice(inputPerMillion: 4, outputPerMillion: 0, currency: .cny), for: .deepSeek)
expect(ledger.snapshot().cost(on: usageKey)[.cny] == 4, "改过的单价应覆盖默认值")
ledger.record(providerID: .qwen, usage: APITokenUsage(inputTokens: 1, outputTokens: 1),
              date: usageDay.addingTimeInterval(Double(APIUsageLedger.retainedDays + 1) * 86_400))
expect(ledger.snapshot().days[usageKey] == nil, "超过保留天数的记录应删掉")
expect(APIPriceCatalog.defaultPrice(for: .appleSystem) == nil && APIPriceCatalog.defaultPrice(for: .localModel) == nil, "苹果翻译和本地模型不计费")

StubURLProtocol.respond = { _ in (401, "{\"error\":{\"message\":\"bad key\"}}") }
var httpFailure: (
    providerID: TranslationProviderID,
    statusCode: Int,
    message: String?
)?
do {
    _ = try await stubChatProvider.translate(
        TextTranslationRequest(sourceText: "你好", targetLanguage: .english)
    )
} catch let error as APITranslationError {
    if case let .httpFailure(providerID, statusCode, message) = error {
        httpFailure = (providerID, statusCode, message)
    }
} catch {
}
expect(httpFailure?.statusCode == 401, "错误应携带状态码")
expect(httpFailure?.message == "bad key", "错误应携带服务端原因")
expect(httpFailure?.providerID == .deepSeek, "错误应点名提供方")

StubURLProtocol.respond = { _ in (200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"   \"}}]}") }
var emptyResponseCaptured = false
do {
    _ = try await stubChatProvider.translate(
        TextTranslationRequest(sourceText: "你好", targetLanguage: .english)
    )
} catch let error as APITranslationError {
    if case .emptyResponse = error {
        emptyResponseCaptured = true
    }
} catch {
}
expect(emptyResponseCaptured, "空译文应报无结果")

StubURLProtocol.respond = { _ in (200, "not-json") }
var invalidResponseCaptured = false
do {
    _ = try await stubChatProvider.translate(
        TextTranslationRequest(sourceText: "你好", targetLanguage: .english)
    )
} catch let error as APITranslationError {
    if case .invalidResponse = error {
        invalidResponseCaptured = true
    }
} catch {
}
expect(invalidResponseCaptured, "非法 JSON 应报无效响应")

StubURLProtocol.respond = { _ in
    (200, "{\"choices\":[{\"finish_reason\":\"length\",\"message\":{\"role\":\"assistant\",\"content\":\"An unfinished translation\"}}]}")
}
var truncatedResponseRejected = false
do {
    _ = try await stubChatProvider.translate(TextTranslationRequest(sourceText: "长文本"))
} catch APITranslationError.truncatedResponse {
    truncatedResponseRejected = true
}
expect(truncatedResponseRejected, "截断且非空的译文不得作为成功结果返回")

expect(
    LocalTranslationModelCatalog.models.map(\.tier) == LocalTranslationModelTier.allCases,
    "本地模型清单应恰好列出两档"
)
for model in LocalTranslationModelCatalog.models {
    expect(model.sha256.count == 64 && model.byteCount > 1_000_000_000, "每档都应有完整的 sha256 和字节数: \(model.tier)")
    expect(
        model.downloadURLs.map { $0.host() } == ["modelscope.cn", "huggingface.co"],
        "下载来源应先 ModelScope 后 Hugging Face: \(model.tier)"
    )
    expect(
        model.downloadURLs.allSatisfy { $0.lastPathComponent == model.fileName && $0.scheme == "https" },
        "下载地址应指向固定版本里的同名文件: \(model.tier)"
    )
}
let lightModel = LocalTranslationModelCatalog.model(for: .light)
let standardModel = LocalTranslationModelCatalog.model(for: .standard)
expect(!lightModel.usesSceneContext && standardModel.usesSceneContext, "只有标准档写入场景和上下文")
let hyMTSampling = LocalTranslationModelCatalog.sampling
expect(
    hyMTSampling.temperature == 0.2 && hyMTSampling.topP == 0.6 && hyMTSampling.topK == 20
        && hyMTSampling.repeatPenalty == 1.05 && hyMTSampling.maxTokens == 4096,
    "采样参数按 Hy-MT2 README 对 1.8B 的推荐值，只把温度降到 0.2 求稳定"
)

let hyStyledRequest = TextTranslationRequest(
    sourceText: "这也太离谱了",
    contextText: "回复：外卖送错楼了\n这也太离谱了",
    scene: .socialMedia,
    englishStyle: .british
)
let hyLightPrompt = HyMTPromptBuilder.userMessage(for: hyStyledRequest, model: lightModel)
expect(
    hyLightPrompt == "将以下文本翻译为英语，注意只需要输出翻译后的结果，不要额外解释：\n\n这也太离谱了",
    "轻量档应使用官方默认翻译模板"
)
let hyStandardPrompt = HyMTPromptBuilder.userMessage(for: hyStyledRequest, model: standardModel)
expect(hyStandardPrompt.hasPrefix("【背景信息】\n场景：社交媒体"), "标准档应先写场景背景")
expect(!hyStandardPrompt.contains("风格："), "本地模型不写英语风格")
expect(hyStandardPrompt.contains("输入框全文（只作参考，不要翻译）：\n回复：外卖送错楼了"), "标准档应把输入框全文作为参考")
expect(hyStandardPrompt.hasSuffix("请结合背景信息将以下文本翻译为英语。\n\n【待翻译文本】\n这也太离谱了"), "标准档应使用官方背景信息模板")

let hyBusinessPrompt = HyMTPromptBuilder.userMessage(
    for: TextTranslationRequest(sourceText: "请确认数量", scene: .business, englishStyle: .blackAmerican),
    model: standardModel
)
expect(hyBusinessPrompt.contains("场景：商务") && !hyBusinessPrompt.contains("风格："), "商务场景不得写入英语风格")
let hyJapanesePrompt = HyMTPromptBuilder.userMessage(
    for: TextTranslationRequest(sourceText: "你好", targetLanguage: .japanese, scene: .dailyChat, englishStyle: .british),
    model: standardModel
)
expect(hyJapanesePrompt.contains("翻译为日语") && !hyJapanesePrompt.contains("风格："), "非英语目标不得写入英语风格")
let hyPlainStandardPrompt = HyMTPromptBuilder.userMessage(
    for: TextTranslationRequest(sourceText: "你好", contextText: "你好"),
    model: standardModel
)
expect(hyPlainStandardPrompt.hasPrefix("将以下文本翻译为英语"), "没有背景可写时标准档也用默认模板")
let hyLongContextPrompt = HyMTPromptBuilder.userMessage(
    for: TextTranslationRequest(sourceText: "好", contextText: String(repeating: "长", count: 3000) + "结尾", scene: .dailyChat),
    model: standardModel
)
expect(hyLongContextPrompt.contains("结尾") && hyLongContextPrompt.count < 1300, "过长的输入框全文只保留结尾部分")

let hyGlossaryPrompt = HyMTPromptBuilder.userMessage(
    for: TextTranslationRequest(sourceText: "在吗？地铁坐过站了", scene: .dailyChat),
    model: lightModel
)
expect(
    hyGlossaryPrompt == "参考下面的翻译：\n在吗 翻译成 you around?\n坐过站 翻译成 missed my stop\n\n将以下文本翻译为英语，注意只需要输出翻译后的结果，不要额外解释：\n\n在吗？地铁坐过站了",
    "原文里出现的常用词应按术语干预模板放在最前面"
)
let hyGlossaryStandardPrompt = HyMTPromptBuilder.userMessage(
    for: TextTranslationRequest(sourceText: "我在楼下", scene: .dailyChat),
    model: standardModel
)
expect(
    hyGlossaryStandardPrompt.hasPrefix("参考下面的翻译：\n楼下 翻译成 downstairs\n\n【背景信息】"),
    "标准档的术语放在背景信息之前"
)
expect(!hyLightPrompt.contains("参考下面的翻译"), "没有命中常用词时不加术语")
let hyJapaneseGlossaryPrompt = HyMTPromptBuilder.userMessage(
    for: TextTranslationRequest(sourceText: "在吗", targetLanguage: .japanese),
    model: lightModel
)
expect(!hyJapaneseGlossaryPrompt.contains("参考下面的翻译"), "英语术语表不用于其他目标语言")
expect(
    HyMTGlossary.englishEntries(in: "我帮你问问老王，小李也在").map(\.target) == ["Lao Wang", "Xiao Li"],
    "老/小 + 常见姓保留拼音称呼"
)
expect(
    HyMTGlossary.englishEntries(in: "老师说小米手机老黄历").isEmpty,
    "不是常见姓的「老/小」词不当称呼"
)
expect(
    HyMTGlossary.englishEntries(in: "老王老王").count == 1,
    "同一称呼只写一次"
)
expect(
    Set(HyMTGlossary.english.map(\.source)).count == HyMTGlossary.english.count,
    "术语表不得有重复词条"
)

// MARK: - 个人术语表（临时目录，不碰用户真实文件）

let glossaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("keyi-glossary-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: glossaryDirectory) }
let personalGlossary = PersonalGlossary(directory: glossaryDirectory)
let gitSample = PersonalGlossary.Sample(source: "把可译的灰度发布推到雾凇仓库", translation: "Push the KEYI canary release to the rime-ice repo")
personalGlossary.collect(gitSample)
expect(personalGlossary.pendingCount == 0, "术语表关闭时什么都不暂存")
personalGlossary.setEnabled(true)
expect(personalGlossary.collect(gitSample) == 1, "打开后暂存大模型译过的整句")
expect(personalGlossary.collect(gitSample) == 1, "同一原文只留一句")
expect(personalGlossary.collect(.init(source: "hello", translation: "hello")) == 1, "没有汉字的句子不暂存")
expect(
    PersonalGlossary.parseExtraction("```json\n[{\"zh\":\"灰度发布\",\"en\":\"canary release\"}]\n```").count == 1,
    "提炼结果包在代码块里也能解析"
)
let mergedCount = personalGlossary.merge(
    [("灰度发布", "canary release"), ("可译", "KEYI"), ("编出来的词", "made up"), ("仓库", "warehouse"), ("推", "push")],
    from: [gitSample]
)
expect(mergedCount == 2, "只收原句里出现、译文里也出现的词对，单字和编造的不收")
expect(personalGlossary.terms.map(\.source) == ["可译", "灰度发布"], "术语按原文排序存下")
personalGlossary.merge([("灰度发布", "canary release")], from: [gitSample])
expect(personalGlossary.terms.first { $0.source == "灰度发布" }?.count == 2, "同一译法再出现时次数加一")
let glossaryRequest = TextTranslationRequest(sourceText: "灰度发布前在吗", targetLanguage: .english)
let glossaryPrompt = HyMTPromptBuilder.userMessage(for: glossaryRequest, model: standardModel, personal: personalGlossary)
expect(
    glossaryPrompt.contains("灰度发布 翻译成 canary release") && glossaryPrompt.contains("在吗 翻译成 you around?"),
    "本地模型提示里固定词表和个人术语一起附上"
)
expect(
    !HyMTPromptBuilder.userMessage(
        for: TextTranslationRequest(sourceText: "灰度发布", targetLanguage: .chinese), model: standardModel, personal: personalGlossary
    ).contains("canary"),
    "目标不是英文时不附个人术语"
)
personalGlossary.setEnabled(false)
expect(personalGlossary.entries(in: "灰度发布").isEmpty, "关闭后不再附个人术语")
expect(personalGlossary.pendingCount == 0, "关闭时清掉暂存的整句")
expect(personalGlossary.terms.count == 2, "关闭不删已整理的术语")
personalGlossary.setEnabled(true)

// 包装的大模型提供方：攒够一批在后台提炼（这里直接调提炼，桩区分翻译和提炼两种请求）。
StubURLProtocol.respond = { request in
    let body = String(decoding: StubURLProtocol.readBody(of: request), as: UTF8.self)
    if body.contains("术语表") {
        return (200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"[{\\\"zh\\\":\\\"雾凇\\\",\\\"en\\\":\\\"rime-ice\\\"}]\"}}]}")
    }
    return (200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Updated rime-ice.\"}}]}")
}
let collecting = GlossaryCollectingProvider(inner: stubChatProvider, glossary: personalGlossary)
let collectedTranslation = try await collecting.translate(TextTranslationRequest(sourceText: "更新了雾凇", targetLanguage: .english))
expect(collectedTranslation == "Updated rime-ice.", "包装不改译文")
expect(personalGlossary.pendingCount == 1, "包装把译过的整句交给术语表暂存")
let extractedCount = try await GlossaryCollectingProvider.extract(with: stubChatProvider, into: personalGlossary)
expect(extractedCount == 1 && personalGlossary.terms.contains { $0.source == "雾凇" && $0.target == "rime-ice" },
       "提炼后新词条进入术语表")
expect(personalGlossary.pendingCount == 0, "提炼一次即删除暂存的整句")
personalGlossary.clear()
expect(personalGlossary.terms.isEmpty && personalGlossary.isEnabled, "清空删词条、开关不变")

checkCount += try await runAliyunFunASRChecks()
checkCount += try await runDoubaoASRChecks()
print("KEYICore checks passed: \(checkCount)")
