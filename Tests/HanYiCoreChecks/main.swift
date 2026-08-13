import Foundation
import HanYiCore

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
    "苹果系统翻译应是当前可用提供方"
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
    "火山引擎应标记为当前可用提供方"
)
expect(
    TranslationProviderCatalog.descriptor(for: .xAI).isAvailable,
    "xAI Grok 应标记为当前可用提供方"
)
expect(
    TranslationProviderCatalog.descriptor(for: .relay).isAvailable,
    "中转站 API 应标记为当前可用提供方"
)
expect(
    TranslationProviderCatalog.descriptor(for: .localModel).isAvailable,
    "Gemma 4 本地模型应标记为当前可用提供方"
)
expect(
    TranslationProviderCatalog.descriptor(for: .localModel).name == "Gemma 4 本地",
    "本地提供方应明确显示 Gemma 4"
)
expect(
    LocalModelCatalog.gemma4.defaultEndpoint == "http://127.0.0.1:1234/v1/chat/completions",
    "Gemma 4 默认 Endpoint 应指向 LM Studio 本地服务"
)
expect(
    LocalModelCatalog.gemma4.defaultModel == "hanyi-gemma4"
        && LocalModelCatalog.gemma4.defaultLoadKey == "gemma-4-12b-it",
    "Gemma 4 应有稳定的本地服务模型标识和加载键"
)
expect(
    LocalModelCatalog.gemma4.completionTokenBudget == 1024,
    "Gemma 4 非推理翻译应使用紧凑输出预算"
)
expect(
    LocalModelCatalog.gemma4.idleTTLSeconds == 180,
    "Gemma 4 应在闲置 3 分钟后自动卸载"
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
    volcengineProfile?.defaultEndpoint == "https://ark.cn-beijing.volces.com/api/v3/responses",
    "火山翻译模型应使用 Responses API"
)
expect(
    volcengineProfile?.defaultModel == "doubao-seed-translation-250915",
    "火山翻译模型名应使用用户指定版本"
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

let volcengineRequestData = try! VolcengineResponsesAPI.requestBody(
    model: "doubao-seed-translation-250915",
    text: "你好",
    sourceLanguage: "zh-Hans",
    targetLanguage: "en"
)
let volcengineRequest = try! JSONSerialization.jsonObject(
    with: volcengineRequestData
) as! [String: Any]
let volcengineInput = (volcengineRequest["input"] as! [[String: Any]])[0]
let volcengineContent = (volcengineInput["content"] as! [[String: Any]])[0]
let translationOptions = volcengineContent["translation_options"] as! [String: String]
expect(volcengineContent["type"] as? String == "input_text", "火山请求必须使用 input_text")
expect(volcengineContent["text"] as? String == "你好", "火山请求必须发送原始待翻译文本")
expect(translationOptions["source_language"] == "zh", "火山中文语言代码应为 zh")
expect(translationOptions["target_language"] == "en", "火山目标语言代码应为 en")

let volcengineResponse = Data(#"""
{
    "output": [{
        "type": "message",
        "content": [{"type": "output_text", "text": "Hello."}]
    }]
}
"""#.utf8)
expect(
    try! VolcengineResponsesAPI.translatedText(from: volcengineResponse) == "Hello.",
    "应从火山 Responses API 输出中提取译文"
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

expect(TranslationLanguage.allCases.count == 12, "国内版应提供十二种常用目标语言")
expect(
    Set(TranslationLanguage.allCases.map(\.rawValue)).count
        == TranslationLanguage.allCases.count,
    "目标语言代码不得重复"
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
expect(systemPrompt.contains("I literally can't"), "提示词应明确禁止网络用语直译")
expect(!userPrompt.contains("full_input_context"), "云端请求不得包含未选中的输入框上下文")
expect(userPrompt.contains("这也太离谱了"), "请求应包含待翻译文本")
expect(localSystemPrompt.count < systemPrompt.count, "本地模型应使用更紧凑的提示词降低输出延迟")
expect(localSystemPrompt.contains("social-media register") && localSystemPrompt.contains("British English"), "本地提示词应保留场景和风格")
expect(localUserPrompt.contains("full_input_context") && localUserPrompt.contains("这也太离谱了"), "本地请求应保留正文和本地上下文")

let streetAAVERequest = TextTranslationRequest(
    sourceText: "兄弟，这也太离谱了",
    scene: .socialMedia,
    englishStyle: .blackAmerican
)
let streetAAVEPrompt = TranslationPromptBuilder.systemPrompt(for: streetAAVERequest)
expect(streetAAVEPrompt.contains("finna") && streetAAVEPrompt.contains("no cap"), "街头 AAVE 应提供自然俚语词汇")
expect(streetAAVEPrompt.contains("recognisably street cadence"), "街头 AAVE 应明确避免退回中性美式英语")
expect(streetAAVEPrompt.contains("Bro, this wild as hell, no cap"), "街头 AAVE 应提供足够强度的自然改写示例")
expect(streetAAVEPrompt.contains("spoken, clipped, and alive"), "街头 AAVE 应强调真实口语节奏")
expect(streetAAVEPrompt.contains("do not fall back to neutral American English"), "街头 AAVE 禁止退回中性美式")

let japaneseRequest = TextTranslationRequest(
    sourceText: "你好",
    targetLanguage: TranslationLanguage.japanese.rawValue,
    scene: .dailyChat,
    englishStyle: .blackAmerican
)
let japanesePrompt = TranslationPromptBuilder.systemPrompt(for: japaneseRequest)
expect(japanesePrompt.contains("zh-Hans to ja"), "非英语提示词应传入目标语言代码")
expect(japanesePrompt.contains("everyday messages between people"), "非英语提示词应保留全语种场景")
expect(japanesePrompt.contains("Scene guidance"), "非英语翻译仍应使用场景")
expect(!japanesePrompt.contains("English voice guidance"), "非英语翻译不得注入英语风格段落")
expect(!japanesePrompt.contains("AAVE"), "非英语翻译不得注入英语风格")

let businessRequest = TextTranslationRequest(
    sourceText: "请确认订单数量为 1200 件，单价 3.5 美元。",
    scene: .business,
    englishStyle: .blackAmerican
)
let businessPrompt = TranslationPromptBuilder.systemPrompt(for: businessRequest)
expect(businessPrompt.contains("business or trade register"), "商务场景应使用商务/贸易语域")
expect(businessPrompt.contains("exact business meaning"), "商务场景应优先准确表达")
expect(businessPrompt.contains("commercial misunderstanding"), "商务场景应避免商业误解")
expect(!businessPrompt.contains("AAVE"), "商务场景不得注入街头风格")
expect(!businessPrompt.contains("finna"), "商务场景不得注入街头俚语")

let businessLocalPrompt = TranslationPromptBuilder.localSystemPrompt(for: businessRequest)
expect(businessLocalPrompt.contains("exact meaning first"), "本地商务提示词应优先准确表达")
expect(!businessLocalPrompt.contains("AAVE"), "本地商务提示词不得注入街头风格")

let japaneseVolcengineRequestData = try! VolcengineResponsesAPI.requestBody(
    model: "doubao-seed-translation-250915",
    text: "你好",
    sourceLanguage: "zh-Hans",
    targetLanguage: TranslationLanguage.japanese.rawValue
)
let japaneseVolcengineRequest = try! JSONSerialization.jsonObject(
    with: japaneseVolcengineRequestData
) as! [String: Any]
let japaneseInput = (japaneseVolcengineRequest["input"] as! [[String: Any]])[0]
let japaneseContent = (japaneseInput["content"] as! [[String: Any]])[0]
let japaneseOptions = japaneseContent["translation_options"] as! [String: String]
expect(japaneseOptions["target_language"] == "ja", "火山请求应透传非英语目标语言")

print("HanYiCore checks passed: \(checkCount)")
