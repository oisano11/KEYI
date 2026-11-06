import Foundation
import KEYICore
import KEYITranslationClient

enum InterfaceLanguageStorage {
    static let key = "interface.language"
}

enum InterfaceLanguageResolver {
    static func resolve(
        _ language: InterfaceLanguage,
        locale: Locale = .current
    ) -> InterfaceLanguage {
        guard language == .automatic else { return language }
        let identifier = locale.identifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        return identifier == "en" || identifier.hasPrefix("en-")
            ? .english
            : .simplifiedChinese
    }

    static func current() -> InterfaceLanguage {
        let stored = UserDefaults.standard.string(
            forKey: InterfaceLanguageStorage.key
        )
        let language = stored.flatMap(InterfaceLanguage.init(rawValue:))
            ?? .automatic
        return resolve(language)
    }
}

struct InterfaceStrings: Sendable {
    let language: InterfaceLanguage

    init(language: InterfaceLanguage) {
        self.language = InterfaceLanguageResolver.resolve(language)
    }

    static var current: InterfaceStrings {
        InterfaceStrings(language: InterfaceLanguageResolver.current())
    }

    var isEnglish: Bool { language == .english }

    var appName: String { isEnglish ? "KEYI" : "KEYI 可译" }
    var statusReady: String { isEnglish ? "Ready" : "就绪" }
    var statusPermissionRequired: String {
        isEnglish ? "Accessibility permission required" : "需要辅助功能权限"
    }
    var statusPreparing: String {
        isEnglish ? "Preparing translation" : "正在准备翻译资源"
    }
    var statusTranslating: String { isEnglish ? "Translating" : "正在翻译" }
    var statusSuccess: String { isEnglish ? "Translation complete" : "翻译完成" }

    var translationMethod: String { isEnglish ? "Translation" : "翻译服务" }
    var current: String { isEnglish ? "Current" : "当前" }
    var targetLanguage: String { isEnglish ? "Language" : "目标语言" }
    var scene: String { isEnglish ? "Context" : "使用场景" }
    var style: String { isEnglish ? "Style" : "表达风格" }
    var interfaceLanguage: String { isEnglish ? "Language" : "界面语言" }
    var localModel: String { isEnglish ? "Local Model" : "本地模型" }
    var hotKey: String { isEnglish ? "Keyboard Shortcut" : "快捷键" }
    var hotKeySettings: String {
        isEnglish ? "Edit Shortcut..." : "设置快捷键..."
    }
    var restoreDefault: String { isEnglish ? "Restore Default" : "恢复默认" }
    var grantAccessibility: String {
        isEnglish ? "Grant Permission" : "授予辅助功能权限"
    }
    var openAccessibilitySettings: String {
        isEnglish ? "Open Accessibility Settings..." : "打开辅助功能设置..."
    }
    var exit: String { isEnglish ? "Quit KEYI" : "退出 KEYI 可译" }
    var unavailable: String { isEnglish ? "Unavailable" : "待接入" }
    var automatic: String { isEnglish ? "Automatic" : "自动" }
    var simplifiedChinese: String { isEnglish ? "Simplified Chinese" : "简体中文" }
    var english: String { isEnglish ? "English" : "英语" }
    var save: String { isEnglish ? "Save" : "保存" }
    var cancel: String { isEnglish ? "Cancel" : "取消" }
    var apiKey: String { "API Key" }
    var endpoint: String { "Endpoint" }
    var model: String { isEnglish ? "Model" : "模型" }
    var savedAPIKeyMasked: String { isEnglish ? "Saved ••••" : "已保存 ••••" }
    var replaceAPIKey: String { isEnglish ? "Replace" : "更换" }
    var pasteAPIKey: String { isEnglish ? "Paste API Key" : "粘贴 API Key" }
    var hotKeyWaiting: String { isEnglish ? "Waiting for input..." : "等待输入..." }
    var hotKeyRequiresModifier: String {
        isEnglish ? "Add Cmd, Option, or Control" : "请加入 Command、Option 或 Control"
    }

    func providerName(_ provider: TranslationProviderID) -> String {
        switch provider {
        case .appleSystem: isEnglish ? "System Translation" : "系统翻译"
        case .deepSeek: "DeepSeek"
        case .qwen: isEnglish ? "Qwen" : "通义千问"
        case .volcengine: isEnglish ? "Volcano Ark" : "火山方舟"
        case .xAI: "Grok"
        case .relay: isEnglish ? "Custom Service" : "自定义服务"
        case .localModel: localModel
        }
    }

    func sceneName(_ scene: TranslationScene) -> String {
        switch scene {
        case .automatic: automatic
        case .dailyChat: isEnglish ? "Chat" : "聊天"
        case .socialMedia: isEnglish ? "Social" : "发帖"
        case .business: isEnglish ? "Business" : "商务"
        case .faithful: isEnglish ? "Faithful" : "贴近原文"
        }
    }

    func styleName(_ style: EnglishStyle) -> String {
        switch style {
        case .automatic: isEnglish ? "Natural" : "自然"
        case .standardAmerican: isEnglish ? "US English" : "美国英语"
        case .westCoast: isEnglish ? "Casual US" : "轻松美式"
        case .blackAmerican: isEnglish ? "Black American" : "黑人英语"
        case .british: isEnglish ? "UK English" : "英国英语"
        }
    }

    func languageName(_ language: TranslationLanguage) -> String {
        switch language {
        case .english: english
        case .chinese: isEnglish ? "Chinese" : "中文"
        case .japanese: isEnglish ? "Japanese" : "日语"
        case .korean: isEnglish ? "Korean" : "韩语"
        case .french: isEnglish ? "French" : "法语"
        case .german: isEnglish ? "German" : "德语"
        case .spanish: isEnglish ? "Spanish" : "西班牙语"
        case .russian: isEnglish ? "Russian" : "俄语"
        case .portuguese: isEnglish ? "Portuguese" : "葡萄牙语"
        case .italian: isEnglish ? "Italian" : "意大利语"
        case .thai: isEnglish ? "Thai" : "泰语"
        case .vietnamese: isEnglish ? "Vietnamese" : "越南语"
        case .arabic: isEnglish ? "Arabic" : "阿拉伯语"
        }
    }

    func interfaceLanguageName(_ language: InterfaceLanguage) -> String {
        switch language {
        case .automatic: automatic
        case .simplifiedChinese: simplifiedChinese
        case .english: english
        }
    }

    func menuLabel(_ label: String, value: String) -> String {
        isEnglish ? "\(label): \(value)" : "\(label)：\(value)"
    }


    func target(_ language: TranslationLanguage) -> String {
        menuLabel(targetLanguage, value: languageName(language))
    }

    func scene(_ value: TranslationScene) -> String {
        menuLabel(scene, value: sceneName(value))
    }

    func style(_ value: EnglishStyle) -> String {
        menuLabel(style, value: styleName(value))
    }

    func interfaceLanguage(_ value: InterfaceLanguage) -> String {
        menuLabel(interfaceLanguage, value: interfaceLanguageName(value))
    }










    var unsupportedProvider: String {
        isEnglish ? "This provider does not support API configuration" : "当前提供方不支持 API 配置"
    }
    var invalidEndpoint: String {
        isEnglish ? "Endpoint must be a valid HTTPS URL" : "Endpoint 必须是有效的 HTTPS 地址"
    }
    var missingAPIKey: String { isEnglish ? "API Key is required" : "API Key 不能为空" }
    var missingModel: String { isEnglish ? "Model name is required" : "模型名不能为空" }
    var emptySource: String { isEnglish ? "There is no text to translate" : "没有可翻译的文本" }
    var invalidAPIResponse: String {
        isEnglish ? "The translation service returned an invalid response" : "翻译服务返回了无效响应"
    }
    func emptyAPIResponse(_ provider: String) -> String {
        isEnglish ? "\(provider) returned no translation" : "\(provider) 没有返回翻译结果"
    }
    func apiRequestFailed(_ provider: String, statusCode: Int, detail: String? = nil) -> String {
        let suffix = detail.map { isEnglish ? ": \($0)" : "：\($0)" } ?? ""
        return isEnglish
            ? "\(provider) request failed (HTTP \(statusCode)\(suffix))"
            : "\(provider) 请求失败（HTTP \(statusCode)\(suffix)）"
    }
    func translationFailed(_ detail: String) -> String {
        isEnglish ? "Translation failed: \(detail)" : "翻译失败：\(detail)"
    }
    func configureProviderFirst(_ provider: String) -> String {
        isEnglish ? "Set up \(provider) first" : "请先配置 \(provider)"
    }
    var hotKeyRegistrationFailed: String {
        isEnglish ? "Global keyboard shortcut registration failed; set it again in Settings."
            : "全局快捷键注册失败，请在设置中重新设置"
    }

    var credentialInvalidAccount: String { isEnglish ? "Invalid credential name" : "凭据名称无效" }
    var credentialWriteFailed: String { isEnglish ? "Could not save API Key" : "API Key 保存失败" }

    func localModelInsufficientDiskSpace(_ size: String) -> String {
        isEnglish ? "Not enough disk space; the download needs \(size) free" : "磁盘空间不足，下载需要 \(size) 可用空间"
    }
    var localModelChecksumMismatch: String {
        isEnglish ? "The downloaded model failed verification; try again" : "下载的模型校验失败，请重试"
    }
    var localModelUnreachable: String {
        isEnglish ? "The local model service is not running" : "本地模型服务没有运行"
    }
    var localModelHelperMissing: String {
        isEnglish ? "The bundled model runtime is missing; reinstall KEYI" : "缺少自带的模型运行组件，请重新安装 KEYI"
    }
    var localModelRunDirectoryUnsafe: String {
        isEnglish ? "The local model run folder is not private to this user" : "本地模型运行目录不属于当前用户"
    }
    var localModelServerFailed: String {
        isEnglish ? "The local model stopped repeatedly; check the model in Settings" : "本地模型连续启动失败，请在设置里检查模型"
    }
    func localModelDownloadStatus(_ status: Int) -> String {
        isEnglish ? "Model download failed (HTTP \(status))" : "模型下载失败（HTTP \(status)）"
    }
    var localModelNotInstalled: String {
        isEnglish
            ? "The local model is not downloaded; download it in Settings → Translation → Local Model"
            : "本地模型还没下载，请在 设置 → 翻译 → 本地模型 里下载"
    }
    var localModelLicense: String {
        isEnglish ? "Model license: Apache-2.0" : "模型许可：Apache-2.0"
    }
    var localModelMigrationNotice: String {
        isEnglish
            ? "Local Model now uses KEYI's built-in Hy-MT2; switched back to Apple Translation"
            : "本地模型已改为 KEYI 自带的 Hy-MT2，已切回苹果系统翻译"
    }
    func localModelDownloading(_ done: String, _ total: String) -> String {
        isEnglish ? "Downloading \(done) / \(total)" : "下载中 \(done) / \(total)"
    }
    var localModelLoading: String { isEnglish ? "Loading model…" : "正在加载模型…" }
    var localModelReady: String { isEnglish ? "Model ready" : "模型已就绪" }
    func localModelTierSummary(_ tier: LocalTranslationModelTier) -> String {
        switch tier {
        case .light: isEnglish ? "Light · literal translation" : "轻量 · 只直译"
        case .standard: isEnglish ? "Standard · follows scene and style" : "标准 · 按场景和风格翻译"
        }
    }
    var localModelTimeout: String {
        isEnglish ? "The local model timed out while loading or translating" : "本地模型首次加载或翻译超时"
    }
    var localModelInvalidResponse: String {
        isEnglish ? "The local model returned an invalid response" : "本地模型返回了无效响应"
    }
    var localModelEmptyResponse: String {
        isEnglish ? "The local model returned no translation" : "本地模型没有返回翻译结果"
    }
    var localModelOutputTooLong: String {
        isEnglish ? "The local model output was too long after retrying" : "本地模型输出过长，自动重试后仍未生成完整译文"
    }
    func localModelRequestFailed(_ statusCode: Int, detail: String? = nil) -> String {
        let suffix = detail.map { isEnglish ? ": \($0)" : "：\($0)" } ?? ""
        return isEnglish
            ? "Local model request failed (\(statusCode)\(suffix))"
            : "本地模型请求失败（\(statusCode)\(suffix)）"
    }

    var providerUnavailable: String {
        isEnglish ? "The selected translation service is unavailable" : "当前翻译服务暂不可用"
    }

    var accessibilityNoFocusedText: String {
        isEnglish ? "There is no editable input field" : "当前没有可编辑的输入框"
    }
    var accessibilityUnreadableText: String {
        isEnglish ? "Could not read the current input field" : "无法读取当前输入框"
    }
    var accessibilityInvalidSelection: String {
        isEnglish ? "The current text selection is invalid" : "当前文本选择范围无效"
    }
    var accessibilityReadOnly: String {
        isEnglish ? "The current input field does not support in-place replacement" : "当前输入框不支持原地替换"
    }
    var terminalSelectionRequired: String {
        isEnglish
            ? "This terminal does not expose a verifiable editable draft; the original text was left unchanged."
            : "当前终端未提供可验证的可编辑草稿接口，原文未改。"
    }
    var terminalEditorRequired: String {
        isEnglish
            ? "This terminal does not expose a verifiable editable draft; the original text was left unchanged."
            : "当前终端未提供可验证的可编辑草稿接口，原文未改。"
    }
    var terminalDraftEditor: String {
        isEnglish ? "New Terminal Translation Draft…" : "通用翻译草稿…"
    }
    var terminalDraftEditorUnavailable: String {
        isEnglish ? "The terminal draft helper is unavailable. Reinstall the complete KEYI app." : "无法打开草稿工具，请重新安装完整的 KEYI 可译应用。"
    }
    var terminalDraftGuide: String {
        isEnglish ? "Terminal draft bridge guide" : "终端草稿桥使用说明"
    }
    var unsafeTerminalTranslation: String {
        isEnglish
            ? "The terminal replacement contains unsupported control characters; replacement cancelled"
            : "终端译文包含不支持的控制字符，已取消替换"
    }
    var terminalWriteFailed: String {
        isEnglish
            ? "Could not verify or safely complete the terminal update. Check the current draft before continuing."
            : "终端内容的写回状态无法确认，请检查当前草稿后再继续。"
    }
    var terminalRecoveryRequired: String {
        isEnglish
            ? "Terminal replacement stopped. Use the KEYI menu to copy or discard the saved original command before translating again."
            : "终端替换已停止，原命令已保留。请先在 KEYI 菜单中复制或丢弃原命令，再继续翻译。"
    }
    var copyOriginalTerminalCommand: String {
        isEnglish ? "Copy Original Command" : "复制原命令"
    }
    var discardOriginalTerminalCommand: String {
        isEnglish ? "Discard Saved Original Command" : "丢弃已保留的原命令"
    }
    var contentChanged: String {
        isEnglish ? "The input or focus changed; replacement cancelled" : "输入内容或焦点已变化，已取消替换"
    }
    var browserInputFailed: String {
        isEnglish ? "The browser input field did not accept the translation" : "浏览器输入框未接受翻译结果"
    }
    func accessibilityWriteFailed(_ code: Int) -> String {
        isEnglish ? "Could not write to the input field (\(code))" : "写入输入框失败（\(code)）"
    }

    func hotKeyListenerError(_ status: Int32) -> String {
        isEnglish
            ? "Keyboard shortcut listener initialization failed (\(status))"
            : "快捷键监听初始化失败（\(status)）"
    }
    func hotKeyConflict(_ displayName: String, status: Int32) -> String {
        isEnglish
            ? "Keyboard shortcut \(displayName) could not be registered (\(status))"
            : "快捷键 \(displayName) 无法注册，可能已被占用（\(status)）"
    }

    // MARK: 设置窗口

    var settings: String { isEnglish ? "Settings..." : "设置..." }
    var settingsTitle: String { isEnglish ? "Settings" : "设置" }
    var translationStyle: String { isEnglish ? "Translation Style" : "翻译风格" }
    /// 卡片里的示例译文：同一句中文按各风格的写法，手写的示例，不是实时翻译。
    func translationStyleExample(_ style: KEYITranslationStyle) -> String {
        switch style {
        case .natural: "I really can’t get this done today — let’s pick it up tomorrow."
        case .business: "I won’t be able to complete this today. Could we revisit it tomorrow?"
        case .faithful: "I really can’t handle this today; let’s talk about it tomorrow."
        case .americanCasual: "No way I’m getting this done today. Let’s circle back tomorrow."
        case .blackAmerican: "Ain’t no way I’m finishing this today — we can get to it tomorrow."
        case .british: "I honestly can’t get this sorted today — shall we leave it till tomorrow?"
        }
    }
    var desktopHotKey: String { isEnglish ? "Desktop Shortcut" : "桌面快捷键" }
    func localModelTierShort(_ tier: LocalTranslationModelTier) -> String {
        switch tier {
        case .light: isEnglish ? "Light" : "轻量档"
        case .standard: isEnglish ? "Standard" : "标准档"
        }
    }
    var localEngineMissing: String {
        isEnglish
            ? "These 3 styles need Hy-MT2, which isn't downloaded yet. Apple Translation stands in until it is."
            : "这 3 种风格要用 Hy-MT2，还没下载；下载好之前暂用苹果翻译。"
    }
    var cloudEngineMissing: String {
        isEnglish
            ? "These 3 styles need an LLM API key. Until you add one, they translate in the Natural style."
            : "这 3 种风格要用大模型 API，还没填 Key；填好之前按「自然」翻。"
    }
    var styleExampleSource: String { "这事我今天真搞不定了，明天再说吧。" }
    func localModelTierName(_ tier: LocalTranslationModelTier) -> String {
        switch tier {
        case .light: isEnglish ? "Light" : "轻量"
        case .standard: isEnglish ? "Standard" : "标准"
        }
    }
    func downloadTierLabel(_ name: String) -> String {
        isEnglish ? "\(name) · Download" : "\(name) · 下载"
    }
    func deleteLocalModelTier(_ tier: String, _ size: String) -> String {
        isEnglish ? "Delete \(tier) model (\(size))" : "删除\(tier)模型（\(size)）"
    }
    var accessibilityShort: String { isEnglish ? "Accessibility" : "辅助功能" }
    var advancedSettings: String { isEnglish ? "Advanced" : "高级" }
    /// 风格旁边显示的引擎：本机模型写模型名，大模型 API 写服务名。
    func engineName(_ provider: TranslationProviderID) -> String {
        switch provider {
        case .localModel: "Hy-MT2"
        case .appleSystem: isEnglish ? "Apple Translation" : "苹果翻译"
        default: providerName(provider)
        }
    }
    var engineNeedsAPIKey: String { isEnglish ? "needs API key" : "需 API Key" }
    func translationStyleName(_ style: KEYITranslationStyle) -> String {
        isEnglish ? style.englishName : style.chineseName
    }
    func translationStyleSummary(_ style: KEYITranslationStyle) -> String {
        isEnglish ? style.englishSummary : style.chineseSummary
    }
    /// 首页两组风格的组名和隐私说明。
    var localStylesGroup: String { isEnglish ? "On This Mac" : "本机翻译" }
    var cloudStylesGroup: String { isEnglish ? "LLM API" : "大模型 API" }
    var downloadLocalModelButton: String { isEnglish ? "Download" : "下载" }
    var addAPIKey: String { isEnglish ? "Add API Key…" : "填写 API Key…" }
    var shortcutsDescription: String {
        isEnglish
            ? "Use a keyboard shortcut to translate text in the current app."
            : "使用全局快捷键翻译当前应用中的文本。"
    }
    var moreMenu: String { isEnglish ? "More" : "更多" }
    func localModelDownloadingMenu(_ percent: Int) -> String {
        isEnglish ? "Downloading local model… \(percent)%" : "正在下载本地模型… \(percent)%"
    }
    var savedHint: String { isEnglish ? "Saved" : "已保存" }
    var providerNotConfiguredLabel: String { isEnglish ? "Not configured" : "未配置" }
    func menuValue(_ title: String, _ value: String) -> String {
        isEnglish ? "\(title): \(value)" : "\(title)：\(value)"
    }
    var accessibilityGranted: String {
        isEnglish ? "Granted" : "已授权"
    }
    var accessibilityNotGranted: String {
        isEnglish ? "Not granted" : "未授权"
    }

}

extension APITranslationError {
    /// 云端提供方错误的用户可见文案；语言跟随当前界面设置。
    public var localizedMessage: String {
        let strings = InterfaceStrings.current
        switch self {
        case .emptySource:
            return strings.emptySource
        case .invalidResponse:
            return strings.invalidAPIResponse
        case let .emptyResponse(providerID):
            return strings.emptyAPIResponse(strings.providerName(providerID))
        case let .truncatedResponse(providerID):
            let provider = strings.providerName(providerID)
            return strings.isEnglish
                ? "\(provider) returned an incomplete translation; the source was not changed. Translate a shorter selection."
                : "\(provider) 返回的译文不完整，原文未修改。请缩短选区后重试。"
        case let .httpFailure(providerID, statusCode, message):
            let detail = message.flatMap {
                $0.isEmpty ? nil : $0
            }
            return strings.apiRequestFailed(
                strings.providerName(providerID),
                statusCode: statusCode,
                detail: detail
            )
        }
    }
}

/// 按设计稿重做的设置三页（翻译风格、统计、高级）与菜单栏的文案。
extension InterfaceStrings {
    // MARK: 翻译风格页

    var styleQuestion: String { isEnglish ? "What kind of English do you want?" : "想要什么样的英文？" }
    var styleIntro: String { isEnglish ? "Pick a style; KEYI decides which model to use." : "选一种风格，KEYI 自己决定用哪个模型。" }
    var sampleSourceLabel: String { isEnglish ? "Sample" : "示例原文" }
    func localGroupDetail(_ engine: String) -> String {
        isEnglish ? "\(engine) · text stays on this Mac" : "\(engine) · 文字不出本机"
    }
    func cloudGroupDetail(_ engine: String) -> String {
        isEnglish ? "\(engine) · only the text being translated is sent" : "\(engine) · 只发送这一段待译文字"
    }
    /// 风格卡片底部的一句用途说明。
    func styleCardNote(_ style: KEYITranslationStyle) -> String {
        switch style {
        case .natural: isEnglish ? "Default · everyday chat" : "默认 · 日常聊天"
        case .business: isEnglish ? "Email, work messages" : "邮件、工作沟通"
        case .faithful: isEnglish ? "One-to-one meaning, no polish" : "意思一对一，不润色"
        case .americanCasual: isEnglish ? "Like an American coworker" : "像美国同事那样说"
        case .blackAmerican: isEnglish ? "No swearing unless the original has it" : "原文没有粗口就不加"
        case .british: isEnglish ? "How Brits say it" : "英国人的说法"
        }
    }
    func targetLanguageFooter(_ language: String) -> String {
        isEnglish
            ? "Target language: \(language). If the LLM service isn't set up, KEYI uses Natural instead and tells you once."
            : "目标语言：\(language)。大模型服务没配好时，会先用「自然」代替并告诉你一次。"
    }
    var changeInAdvanced: String { isEnglish ? "Change in Advanced" : "在高级里修改" }

    // MARK: 高级页

    var targetLanguageDetail: String { isEnglish ? "The language translations are written in." : "译文写成哪种语言。" }
    var languageLabel: String { isEnglish ? "Language" : "语言" }
    var appearanceSection: String { isEnglish ? "Appearance" : "外观" }
    var themeLabel: String { isEnglish ? "Theme" : "主题" }
    var themeDetail: String { isEnglish ? "Light and dark follow the system appearance." : "亮色、暗色跟随系统外观自动切换。" }
    func themeName(_ theme: KEYITheme) -> String { isEnglish ? theme.englishName : theme.chineseName }
    var localModelRowDetail: String {
        isEnglish
            ? "Light (1.13 GB) favours speed; Standard (1.91 GB) reads better."
            : "轻量（1.13 GB）速度优先；标准（1.91 GB）质量更好。"
    }
    var localModelInUse: String { isEnglish ? "In use" : "正在使用" }
    var cloudServiceDetail: String {
        isEnglish
            ? "Used by Casual American, Black American Casual and British Casual. It only receives the text being translated."
            : "美式、黑人英语、英式口语用它。只收到这一段待译文字。"
    }
    var generalSection: String { isEnglish ? "General" : "通用" }
    var dictionaryRowDetail: String {
        isEnglish
            ? "Checked once a week; you're told what changed before anything is installed. The input method itself never goes online."
            : "每周检查一次上游，发现新版先说明再问你。输入法本身不联网。"
    }
    var dictionaryReview: String { isEnglish ? "Review update…" : "查看新版…" }

    // MARK: 统计页

    var statsConfirmedHanzi: String { isEnglish ? "Confirmed characters" : "确认汉字" }
    var statsEnglishWords: String { isEnglish ? "English words sent" : "上屏英文词" }
    var statsLLMTokens: String { isEnglish ? "LLM tokens" : "大模型 tokens" }
    var statsEstimatedCost: String { isEnglish ? "Estimated API cost" : "API 估算费用" }
    var statsWeekChart: String { isEnglish ? "Confirmed characters, last 7 days" : "近 7 天确认汉字" }
    func statsDailyAverage(_ value: String) -> String { isEnglish ? "Daily avg \(value)" : "日均 \(value)" }
    var statsCostAndPrices: String { isEnglish ? "Cost and prices" : "费用与单价" }
    var statsEditPrices: String { isEnglish ? "Edit prices" : "改单价" }
    var statsDoneEditing: String { isEnglish ? "Done" : "完成" }
    var statsServiceColumn: String { isEnglish ? "Service" : "服务" }
    var statsPerMillionColumn: String { isEnglish ? "Per M tokens" : "每百万 tokens" }
    var statsFree: String { isEnglish ? "Free" : "免费" }
    var statsTodayTotal: String { isEnglish ? "Today, total" : "今天合计" }
    var statsWordsUnit: String { isEnglish ? "words" : "个词" }
    func statsAppSpread(_ count: Int) -> String { isEnglish ? "across \(count) apps" : "分在 \(count) 个 App" }
    var statsCostNote: String {
        isEnglish ? "Estimated from the token usage each service reports; fill in your relay's own price." : "按服务返回的 token 用量估算；中转站可自填单价。"
    }
    var statsDailyDetails: String { isEnglish ? "Daily details" : "每日明细" }
    var statsUserDictionaryDetail: String {
        isEnglish
            ? "Learned on this Mac, offline. Learned per app: words you picked in an app move to the front of the page next time."
            : "本机自学习，不联网。按 App 分开学：同一个 App 里选过的词，下次排在前面。"
    }

    // MARK: 菜单栏

    var menuServiceRunning: String { isEnglish ? "Translation service running" : "翻译服务运行中" }
    var menuLocalModelLoaded: String { isEnglish ? "local model loaded" : "本地模型已加载" }
    var menuLocalModelLoading: String { isEnglish ? "local model loading" : "本地模型加载中" }
    var menuLocalModelMissing: String { isEnglish ? "local model not downloaded" : "本地模型未下载" }
    var menuLocalModelFailed: String { isEnglish ? "local model failed to load" : "本地模型加载失败" }
    var menuLocalModelIdle: String { isEnglish ? "local model idle" : "本地模型待命" }
    var menuTodayHanzi: String { isEnglish ? "Characters today" : "今天确认汉字" }
    var menuEstimatedCost: String { isEnglish ? "Estimated API cost" : "API 估算费用" }
    var quitApp: String { isEnglish ? "Quit KEYI" : "退出 KEYI 可译" }

    // MARK: 词库更新对话框

    var dictionarySheetTitle: String { isEnglish ? "New rime-ice dictionary" : "雾凇拼音有新词库" }
    func dictionarySheetVersions(_ to: KEYIDictionaryUpdate.Version, _ from: KEYIDictionaryUpdate.Version?) -> String {
        let new = isEnglish ? to.date.formatted(date: .long, time: .omitted) : chineseDate(to.date)
        guard let from else { return isEnglish ? "Version \(new)" : "\(new)版" }
        let old = isEnglish ? from.date.formatted(date: .long, time: .omitted) : chineseDate(from.date)
        return isEnglish ? "Version \(new) · current \(old)" : "\(new)版 · 当前 \(old)版"
    }
    var dictionaryAddedLabel: String { isEnglish ? "Words added" : "新增词条" }
    var dictionaryRemovedLabel: String { isEnglish ? "Words removed" : "删除词条" }
    var dictionaryAddedSamples: String { isEnglish ? "New words, e.g." : "新词示例" }
    var dictionaryRemovedSamples: String { isEnglish ? "Removed, e.g." : "删除示例" }
}
