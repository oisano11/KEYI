import Foundation
import KEYICore

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
    var apiManagement: String { isEnglish ? "Translation Services" : "翻译服务" }
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
    var english: String { "English" }
    var save: String { isEnglish ? "Save" : "保存" }
    var cancel: String { isEnglish ? "Cancel" : "取消" }
    var apiKey: String { "API Key" }
    var endpoint: String { "Endpoint" }
    var model: String { isEnglish ? "Model" : "模型" }
    var savedLeaveBlank: String {
        isEnglish ? "Saved; leave blank to keep it" : "已保存，留空保持不变"
    }
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
        case .westCoast: isEnglish ? "West Coast" : "轻松美式"
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

    func currentProvider(_ provider: TranslationProviderID) -> String {
        menuLabel(current, value: providerName(provider))
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

    func localModelValue(_ name: String) -> String {
        menuLabel(localModel, value: name)
    }

    func serviceValue(_ endpoint: String) -> String {
        menuLabel(isEnglish ? "Service" : "服务", value: endpoint)
    }

    func sceneStyleHint(
        supportsScene: Bool,
        supportsStyle: Bool,
        scene: TranslationScene
    ) -> String {
        if !supportsScene {
            return isEnglish
                ? "Context and style are available with model services"
                : "使用场景和表达风格仅适用于模型服务"
        }
        if !supportsStyle {
            switch scene {
            case .business:
                return isEnglish
                    ? "Business prioritizes accuracy; style is unavailable"
                    : "商务优先准确，不使用表达风格"
            case .faithful:
                return isEnglish
                    ? "Faithful mode keeps the source; style is unavailable"
                    : "贴近原文，不使用表达风格"
            default:
                return isEnglish
                    ? "Context supports all languages; style applies to English"
                    : "使用场景适用于全部目标语言；表达风格仅适用于英语"
            }
        }
        return ""
    }

    var apiStorageInfo: String {
        isEnglish
            ? "API Key is stored in this macOS user's private KEYI folder; Endpoint and model are stored in local settings."
            : "API Key 仅保存到当前 macOS 用户的 KEYI 私有目录；Endpoint 和模型名保存到本机设置。"
    }

    func configureAPI(_ provider: TranslationProviderID) -> String {
        isEnglish
            ? "Configure \(providerName(provider)) API"
            : "配置 \(providerName(provider)) API"
    }

    func saveAPIFailed(_ provider: TranslationProviderID, detail: String) -> String {
        isEnglish
            ? "Could not save \(providerName(provider)) API: \(detail)"
            : "保存 \(providerName(provider)) API 失败：\(detail)"
    }

    var configureLocalModel: String {
        isEnglish ? "Local Model" : "本地设置"
    }

    var localModelInfo: String {
        isEnglish
            ? "No API key is required. The 12B model loads on first use and unloads after 3 minutes idle."
            : "无需 API Key。首次翻译会自动加载 12B 模型；闲置 3 分钟后自动卸载并释放内存。"
    }

    var saveLocalModelFailedPrefix: String {
        isEnglish ? "Could not save local model settings: " : "保存本地模型配置失败："
    }

    var unsupportedProvider: String {
        isEnglish ? "This provider does not support API configuration" : "当前提供方不支持 API 配置"
    }
    var invalidEndpoint: String {
        isEnglish ? "Endpoint must be a valid HTTPS URL" : "Endpoint 必须是有效的 HTTPS 地址"
    }
    var invalidLocalEndpoint: String {
        isEnglish
            ? "Local Endpoint must be an HTTP address on localhost or 127.0.0.1"
            : "本地 Endpoint 必须是 localhost 或 127.0.0.1 的 HTTP 地址"
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
    var noFocusedWindow: String {
        isEnglish ? "No recently used input window found" : "没有找到最近使用的输入窗口"
    }
    var readingInput: String { isEnglish ? "Reading current input" : "正在读取当前输入框" }
    func usingProvider(_ provider: String) -> String {
        isEnglish ? "Translating with \(provider)" : "正在使用 \(provider) 翻译"
    }
    var writingInput: String { isEnglish ? "Writing to current input" : "正在写回当前输入框" }
    var translationComplete: String { isEnglish ? "Translation complete" : "翻译完成" }
    func selectedProvider(_ provider: String) -> String {
        isEnglish ? "Using \(provider)" : "正在使用 \(provider)"
    }
    func savedProvider(_ provider: String) -> String {
        isEnglish ? "Saved \(provider)" : "已保存 \(provider)"
    }
    func hotKeyUpdated(_ value: String) -> String {
        isEnglish ? "Keyboard shortcut updated to \(value)" : "快捷键已更新为 \(value)"
    }
    func hotKeyUnavailable(_ value: String) -> String {
        isEnglish
            ? "Keyboard shortcut \(value) could not be registered; another app may be using it."
            : "快捷键 \(value) 无法注册，可能已被其他应用占用。"
    }
    var saveHotKeyFailed: String {
        isEnglish
            ? "Could not save the keyboard shortcut or restore the previous one. Set it again in Settings."
            : "保存快捷键失败，且原快捷键恢复失败，请重新设置"
    }
    var hotKeyRegistrationFailed: String {
        isEnglish ? "Global keyboard shortcut registration failed; set it again in Settings."
            : "全局快捷键注册失败，请在设置中重新设置"
    }
    func fallbackHotKey(_ value: String) -> String {
        isEnglish ? "The previous keyboard shortcut was unavailable; restored \(value)" : "原快捷键不可用，已恢复 \(value)"
    }
    var timeoutOrCancelled: String {
        isEnglish ? "Translation timed out or was cancelled" : "翻译请求超时或已取消"
    }
    var operationFailed: String { isEnglish ? "Operation failed" : "操作失败" }

    var credentialInvalidAccount: String { isEnglish ? "Invalid credential name" : "凭据名称无效" }
    var credentialUnreadable: String {
        isEnglish
            ? "API Key could not be read. Save it again in Translation Services."
            : "API Key 无法读取，请在“翻译服务”中重新保存一次"
    }
    var credentialWriteFailed: String { isEnglish ? "Could not save API Key" : "API Key 保存失败" }

    var localRuntimeUnavailable: String {
        isEnglish ? "LM Studio command not found; install LM Studio first" : "未找到 LM Studio 命令，请先安装 LM Studio"
    }
    var localModelNotInstalled: String {
        isEnglish ? "Gemma 4 12B is not installed; download or load it in LM Studio" : "本机未找到 Gemma 4 12B，请在 LM Studio 下载或加载该模型"
    }
    var localServiceUnavailable: String {
        isEnglish ? "LM Studio local service could not start; enable Local Server in LM Studio" : "LM Studio 本地服务未能启动，请在 LM Studio 中开启 Local Server"
    }
    var localModelServiceUnavailable: String {
        isEnglish ? "Local model service is not running; check LM Studio" : "本地模型服务未启动，请确认 LM Studio 可用"
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
        isEnglish ? "Terminal: select the text to translate first" : "终端命令：请先选中要翻译的内容，再触发翻译"
    }
    var unsafeTerminalTranslation: String {
        isEnglish ? "The terminal translation contains line breaks or control characters; replacement cancelled" : "终端译文包含换行或控制字符，已取消替换"
    }
    var terminalWriteFailed: String {
        isEnglish ? "The terminal command could not safely replace the text" : "终端命令未能安全替换，已停止写入"
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
    var translationTab: String { isEnglish ? "Translation" : "翻译" }
    var providersTab: String { isEnglish ? "Services" : "翻译服务" }
    var hotKeyTab: String { isEnglish ? "Shortcuts" : "快捷键" }
    var generalTab: String { isEnglish ? "General" : "通用" }
    var translationPreferencesDescription: String {
        isEnglish
            ? "Choose the language and writing preferences for your translations."
            : "设置译文语言，以及模型服务的表达偏好。"
    }
    var systemTranslationOptionsInfo: String {
        isEnglish
            ? "System Translation uses the language you choose and keeps its own writing behavior."
            : "系统翻译会使用所选语言，并由系统决定表达方式。"
    }
    var translationServicesDescription: String {
        isEnglish
            ? "Set up the services available for translation."
            : "配置可用于翻译的服务。"
    }
    var localModelEndpointPlaceholder: String {
        "http://127.0.0.1:1234/v1/chat/completions"
    }
    var localModelPlaceholder: String {
        isEnglish ? "Model identifier in LM Studio" : "LM Studio 中的模型标识"
    }
    var shortcutsDescription: String {
        isEnglish
            ? "Use a keyboard shortcut to translate text in the current app."
            : "使用全局快捷键翻译当前应用中的文本。"
    }
    var generalSettingsDescription: String {
        isEnglish
            ? "Manage the app language and required macOS access."
            : "管理界面语言和 KEYI 所需的 macOS 权限。"
    }
    var savedHint: String { isEnglish ? "Saved" : "已保存" }
    var useAsCurrent: String { isEnglish ? "Use for Translation" : "用于翻译" }
    var currentlyUsed: String { isEnglish ? "Used for Translation" : "正在用于翻译" }
    var providerConfiguredSuffix: String { isEnglish ? "Configured" : "已配置" }
    var providerNotConfiguredLabel: String { isEnglish ? "Not configured" : "未配置" }
    var cloudProviderSection: String {
        isEnglish ? "Cloud Services" : "云端翻译服务"
    }
    var localModelSectionLabel: String {
        isEnglish ? "Local model (LM Studio)" : "本地模型（LM Studio）"
    }
    var accessibilityPermissionSection: String {
        isEnglish ? "Accessibility permission" : "辅助功能权限"
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
