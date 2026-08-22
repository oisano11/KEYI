using System.Globalization;
using System.Text.RegularExpressions;
using KEYI.Core;

namespace KEYI.Windows;

internal sealed class UiStrings
{
    public static UiStrings Current { get; private set; } = new(
        KEYI.Core.InterfaceLanguage.Automatic);

    private UiStrings(KEYI.Core.InterfaceLanguage language)
    {
        Language = Resolve(language);
    }

    public KEYI.Core.InterfaceLanguage Language { get; }
    public bool IsEnglish => Language == KEYI.Core.InterfaceLanguage.English;

    public static UiStrings For(KEYI.Core.InterfaceLanguage language) => new(language);

    public static void SetCurrent(KEYI.Core.InterfaceLanguage language)
    {
        Current = new UiStrings(language);
    }

    private static KEYI.Core.InterfaceLanguage Resolve(KEYI.Core.InterfaceLanguage language) =>
        language != KEYI.Core.InterfaceLanguage.Automatic
            ? language
            : CultureInfo.CurrentUICulture.TwoLetterISOLanguageName
                .Equals("en", StringComparison.OrdinalIgnoreCase)
                ? KEYI.Core.InterfaceLanguage.English
                : KEYI.Core.InterfaceLanguage.SimplifiedChinese;

    public string AppName => IsEnglish ? "KEYI" : "KEYI 可译";
    public string Ready => IsEnglish ? "Ready" : "就绪";
    public string PermissionRequired => IsEnglish
        ? "Accessibility permission required"
        : "需要辅助功能权限";
    public string TranslateCurrentInput => IsEnglish
        ? "Translate Current Input"
        : "立即翻译";
    public string TranslationMethod => IsEnglish ? "Provider" : "翻译方式";
    public string CurrentLabel => IsEnglish ? "Current" : "当前";
    public string TargetLanguage => IsEnglish ? "Target" : "目标语言";
    public string Scene => IsEnglish ? "Scene" : "场合";
    public string Style => IsEnglish ? "Tone" : "语气";
    public string InterfaceLanguage => IsEnglish ? "Language" : "界面语言";
    public string ApiManagement => IsEnglish ? "Model API" : "模型 API";
    public string LocalModel => IsEnglish ? "Local Model" : "本地模型";
    public string HotKey => IsEnglish ? "Hotkey" : "热键";
    public string HotKeySettings => IsEnglish ? "Hotkey Settings..." : "设置热键...";
    public string RestoreDefault => IsEnglish ? "Restore Default" : "恢复默认";
    public string AccessibilitySettings => IsEnglish
        ? "Accessibility Settings"
        : "辅助设置";
    public string CheckUpdates => IsEnglish ? "Check for Updates..." : "检查更新...";
    public string Exit => IsEnglish ? "Quit KEYI" : "退出 KEYI 可译";
    public string Unavailable => IsEnglish ? "Unavailable" : "待接入";
    public string NotConfigured => IsEnglish ? "Not configured" : "未配置";
    public string Automatic => IsEnglish ? "Automatic" : "自动";
    public string SimplifiedChinese => IsEnglish ? "Simplified Chinese" : "简体中文";
    public string English => "English";
    public string Save => IsEnglish ? "Save" : "保存";
    public string Cancel => IsEnglish ? "Cancel" : "取消";
    public string ApiKey => "API Key";
    public string Endpoint => "Endpoint";
    public string Model => IsEnglish ? "Model" : "模型";
    public string SavedLeaveBlank => IsEnglish
        ? "Saved; leave blank to keep it"
        : "已保存，留空保持不变";
    public string PasteApiKey => IsEnglish ? "Paste API Key" : "粘贴 API Key";
    public string ApiRequiredTitle => IsEnglish ? "Model API required" : "需要配置模型 API";
    public string ConfigureApiHint(ProviderId provider) => IsEnglish
        ? $"Right-click the {AppName} tray icon to configure {ProviderName(provider)} API."
        : $"请右键 {AppName} 托盘图标，配置 {ProviderName(provider)} API。";
    public string InterfaceLanguageUpdated => IsEnglish
        ? "Interface language updated"
        : "界面语言已更新";
    public string VersionAvailable(string tag) => IsEnglish
        ? $"Version {tag} available"
        : $"发现新版本 {tag}";

    public string ProviderName(ProviderId provider) => provider switch
    {
        ProviderId.DeepSeek => "DeepSeek",
        ProviderId.Qwen => IsEnglish ? "Qwen" : "通义千问",
        ProviderId.Volcengine => IsEnglish ? "Volcengine" : "火山引擎",
        ProviderId.XAI => "xAI Grok",
        _ => provider.ToString()
    };

    public string ProviderNotConfigured(ProviderId provider) =>
        IsEnglish
            ? $"{ProviderName(provider)} ({NotConfigured})"
            : $"{ProviderName(provider)}（{NotConfigured}）";

    public string SceneName(TranslationScene scene) => scene switch
    {
        TranslationScene.Automatic => Automatic,
        TranslationScene.DailyChat => IsEnglish ? "Chat" : "聊天",
        TranslationScene.SocialMedia => IsEnglish ? "Social" : "发帖",
        TranslationScene.Business => IsEnglish ? "Business" : "商务",
        TranslationScene.Faithful => IsEnglish ? "Faithful" : "贴近原文",
        _ => scene.ToString()
    };

    public string StyleName(EnglishStyle style) => style switch
    {
        EnglishStyle.Automatic => IsEnglish ? "Natural" : "自然",
        EnglishStyle.StandardAmerican => IsEnglish ? "US English" : "美国英语",
        EnglishStyle.WestCoast => IsEnglish ? "West Coast" : "轻松美式",
        EnglishStyle.BlackAmerican => IsEnglish ? "Black American" : "黑人英语",
        EnglishStyle.British => IsEnglish ? "UK English" : "英国英语",
        _ => style.ToString()
    };

    public string LanguageName(TranslationLanguage language) => language switch
    {
        TranslationLanguage.English => English,
        TranslationLanguage.Japanese => IsEnglish ? "Japanese" : "日语",
        TranslationLanguage.Korean => IsEnglish ? "Korean" : "韩语",
        TranslationLanguage.French => IsEnglish ? "French" : "法语",
        TranslationLanguage.German => IsEnglish ? "German" : "德语",
        TranslationLanguage.Spanish => IsEnglish ? "Spanish" : "西班牙语",
        TranslationLanguage.Russian => IsEnglish ? "Russian" : "俄语",
        TranslationLanguage.Portuguese => IsEnglish ? "Portuguese" : "葡萄牙语",
        TranslationLanguage.Italian => IsEnglish ? "Italian" : "意大利语",
        TranslationLanguage.Thai => IsEnglish ? "Thai" : "泰语",
        TranslationLanguage.Vietnamese => IsEnglish ? "Vietnamese" : "越南语",
        TranslationLanguage.Arabic => IsEnglish ? "Arabic" : "阿拉伯语",
        _ => language.ToString()
    };

    public string InterfaceLanguageName(KEYI.Core.InterfaceLanguage language) => language switch
    {
        KEYI.Core.InterfaceLanguage.Automatic => Automatic,
        KEYI.Core.InterfaceLanguage.SimplifiedChinese => SimplifiedChinese,
        KEYI.Core.InterfaceLanguage.English => English,
        _ => language.ToString()
    };

    public string Label(string label, string value) =>
        IsEnglish ? $"{label}: {value}" : $"{label}：{value}";

    public string CurrentProvider(ProviderId provider) =>
        Label(CurrentLabel, ProviderName(provider));

    public string Target(TranslationLanguage language) =>
        Label(TargetLanguage, LanguageName(language));

    public string SceneValue(TranslationScene scene) =>
        Label(Scene, SceneName(scene));

    public string StyleValue(EnglishStyle style) =>
        Label(Style, StyleName(style));

    public string InterfaceLanguageValue(KEYI.Core.InterfaceLanguage language) =>
        Label(InterfaceLanguage, InterfaceLanguageName(language));

    public string SceneStyleHint(
        bool supportsScene,
        bool supportsStyle,
        TranslationScene scene)
    {
        if (!supportsScene)
        {
            return IsEnglish
                ? "Scene and tone apply only to model APIs"
                : "场合与语气仅适用于模型 API";
        }
        if (supportsStyle)
        {
            return "";
        }
        return scene switch
        {
            TranslationScene.Business => IsEnglish
                ? "Business prioritizes accuracy; tone is disabled"
                : "商务优先准确，不使用语气",
            TranslationScene.Faithful => IsEnglish
                ? "Faithful mode keeps the source; tone is disabled"
                : "贴近原文，不使用语气",
            _ => IsEnglish
                ? "Scene supports all target languages; tone applies to English"
                : "场合适用于全部目标语言；语气仅适用于英语"
        };
    }

    public string ConfigureApi(ProviderId provider) => IsEnglish
        ? $"Configure {ProviderName(provider)} API"
        : $"配置{ProviderName(provider)} API";

    public string ApiStorageInfo => IsEnglish
        ? "API Key is stored in Windows Credential Manager; Endpoint and model are stored in local settings."
        : "API Key 保存到 Windows 凭据管理器；Endpoint 和模型名保存到当前用户设置。";

    public string ConfigureLocalModel => IsEnglish
        ? "Local Model"
        : "本地设置";

    public string LocalModelInfo => IsEnglish
        ? "No API key is required. The 12B model loads on first use and unloads after 3 minutes idle."
        : "无需 API Key。首次翻译会自动加载 12B 模型；闲置 3 分钟后自动卸载并释放内存。";

    public string InvalidEndpoint => IsEnglish
        ? "Endpoint must be a valid HTTPS URL"
        : "Endpoint 必须是有效的 HTTPS 地址";
    public string MissingApiKey => IsEnglish ? "API Key is required" : "API Key 不能为空";
    public string MissingModel => IsEnglish ? "Model name is required" : "模型名不能为空";
    public string InvalidApiResponse => IsEnglish
        ? "The model API returned an invalid response"
        : "模型 API 返回了无效响应";
    public string EmptyApiResponse => IsEnglish
        ? "The model API returned no translation"
        : "模型 API 没有返回翻译结果";
    public string CredentialReadFailed(int code) => IsEnglish
        ? $"Could not read Windows credentials ({code})"
        : $"读取 Windows 凭据失败（{code}）";
    public string CredentialWriteFailed(int code) => IsEnglish
        ? $"Could not save Windows credentials ({code})"
        : $"保存 Windows 凭据失败（{code}）";
    public string InvalidLocalEndpoint => IsEnglish
        ? "Local Endpoint must be an HTTP address on localhost or 127.0.0.1"
        : "本地 Endpoint 必须是 localhost 或 127.0.0.1 的 HTTP 地址";

    public string NoFocusedWindow => IsEnglish
        ? "No recently used input window found"
        : "没有找到最近使用的输入窗口";
    public string ReadingInput => IsEnglish ? "Reading current input" : "正在读取当前输入框";
    public string WritingInput => IsEnglish ? "Writing to current input" : "正在写回当前输入框";
    public string TranslationComplete => IsEnglish ? "Translation complete" : "翻译完成";
    public string NoCurrentWindow => IsEnglish ? "No current input window found" : "没有找到当前输入窗口";
    public string NoCurrentInput => IsEnglish ? "No current input field found" : "没有找到当前输入框";
    public string ControlDoesNotSupportText => IsEnglish
        ? "The current control does not support reading text"
        : "当前控件不支持读取文本";
    public string EmptyTranslation => IsEnglish
        ? "The translation was empty; the source was not changed"
        : "翻译结果为空，未修改原文本";
    public string ClipboardSelectionRequired => IsEnglish
        ? "The current control does not support reading text; select text to translate first"
        : "当前控件不支持读取文本；请先选中要翻译的文本";
    public string FocusChanged => IsEnglish
        ? "Input focus changed; replacement cancelled"
        : "输入焦点已改变，已取消回写";
    public string InputChanged => IsEnglish
        ? "Input or selection changed; replacement cancelled"
        : "输入内容或选区已改变，已取消回写";
    public string WriteBackFocusChanged => IsEnglish
        ? "Input focus changed after write-back; check the current input field"
        : "写回后输入焦点已改变，请检查当前输入框";
    public string WriteBackNotConfirmed => IsEnglish
        ? "The input field did not confirm the translation; check whether the target app allows paste"
        : "输入框未确认写入翻译结果，请检查目标应用是否允许粘贴";
    public string MissingSelectionContext => IsEnglish
        ? "Selection context is missing; replacement cancelled"
        : "缺少选区上下文，已取消回写";
    public string InvalidSelectionRange => IsEnglish
        ? "The selection range is invalid; replacement cancelled"
        : "选区范围无效，已取消回写";
    public string NoTranslatableText => IsEnglish
        ? "The current input field has no translatable text"
        : "当前输入框没有可翻译的文本";
    public string ClipboardBusy => IsEnglish
        ? "The clipboard is being used by another app"
        : "剪贴板正被其他应用占用";
    public string ClipboardSaveFailed => IsEnglish
        ? "Could not fully save the current clipboard; translation cancelled"
        : "无法完整保存当前剪贴板，未执行翻译";
    public string ClipboardRestoreFailed => IsEnglish
        ? "Translation was written, but the clipboard could not be restored; check apps using the clipboard"
        : "翻译已写入，但未能恢复剪贴板，请检查剪贴板占用程序";
    public string PasteCommandFailed => IsEnglish
        ? "Could not send the paste command to the current input field"
        : "无法向当前输入框发送粘贴命令";
    public string WriteVerificationCommandFailed => IsEnglish
        ? "Could not send the write-back verification command"
        : "无法向当前输入框发送写回验证命令";
    public string UsingProvider(ProviderId provider) => IsEnglish
        ? $"Translating with {ProviderName(provider)}"
        : $"正在使用 {ProviderName(provider)} 翻译";
    public string ConfigureProviderFirst(ProviderId provider) => IsEnglish
        ? $"Configure {ProviderName(provider)} API first"
        : $"请先配置 {ProviderName(provider)} API";
    public string SelectedProvider(ProviderId provider) => IsEnglish
        ? $"Selected {ProviderName(provider)}"
        : $"已选择 {ProviderName(provider)}";
    public string SavedProvider(ProviderId provider) => IsEnglish
        ? $"Saved {ProviderName(provider)} API"
        : $"已保存 {ProviderName(provider)} API";
    public string HotKeyUpdated(string value) => IsEnglish
        ? $"Hotkey updated to {value}"
        : $"快捷键已更新为 {value}";
    public string HotKeyUnavailable(string value) => IsEnglish
        ? $"Hotkey {value} could not be registered; another app may be using it."
        : $"快捷键 {value} 无法注册，可能已被其他应用占用。";
    public string SaveHotKeyFailed => IsEnglish
        ? "Could not save the hotkey, and the previous hotkey could not be restored. Please set it again."
        : "保存快捷键失败，且原快捷键恢复失败，请重新设置";
    public string FallbackHotKey(string value) => IsEnglish
        ? $"The previous hotkey was unavailable; restored {value}"
        : $"原快捷键不可用，已恢复 {value}";
    public string HotKeyRegistrationFailed => IsEnglish
        ? "Global hotkey registration failed; set it again from the tray menu"
        : "全局快捷键注册失败，请从托盘菜单重新设置";

    public string UpdateChecking => IsEnglish ? "Checking for updates" : "正在检查更新";
    public string UpToDate => IsEnglish ? "You are up to date" : "当前已是最新版本";
    public string UpToDateDetail(string version) => IsEnglish
        ? $"You are up to date (v{version})."
        : $"当前已是最新版本（v{version}）。";
    public string UpdateFound(string tag) => IsEnglish
        ? $"A new version {tag} is available. Upgrade now?\n\nThe app will close and restart automatically."
        : $"发现新版本 {tag}，是否立即升级？\n\n升级将自动关闭并重新启动 KEYI。";
    public string UpdateTitle => IsEnglish ? "KEYI Update" : "KEYI 更新";
    public string Downloading(string tag) => IsEnglish ? $"Downloading {tag}" : $"正在下载 {tag}";
    public string UpdateFailed(string detail) => IsEnglish
        ? $"Update failed: {detail}"
        : $"更新失败：{detail}";

    public string TimeoutOrCancelled => IsEnglish
        ? "Translation timed out or was cancelled"
        : "翻译请求超时或已取消";
    public string OperationFailed => IsEnglish ? "Operation failed" : "操作失败";
    public string SaveSettingsFailed(string detail) => IsEnglish
        ? $"Could not save settings: {detail}"
        : $"保存设置失败：{detail}";
    public string TranslationFailed(string detail) => IsEnglish
        ? $"Translation failed: {detail}"
        : $"翻译失败：{detail}";

    public string UserMessage(Exception exception)
    {
        if (exception is OperationCanceledException)
        {
            return TimeoutOrCancelled;
        }

        var message = exception.Message;
        var providerFailure = Regex.Match(
            message,
            @"^(?<provider>.+) 请求失败（HTTP (?<status>\d+)(?:：(?<detail>.*))?）$",
            RegexOptions.CultureInvariant);
        if (providerFailure.Success
            && int.TryParse(providerFailure.Groups["status"].Value, out var statusCode))
        {
            var provider = providerFailure.Groups["provider"].Value switch
            {
                "通义千问" => IsEnglish ? "Qwen" : "通义千问",
                "火山引擎" => IsEnglish ? "Volcengine" : "火山引擎",
                "xAI Grok" => "xAI Grok",
                "DeepSeek" => "DeepSeek",
                _ => providerFailure.Groups["provider"].Value
            };
            var detail = providerFailure.Groups["detail"].Success
                ? providerFailure.Groups["detail"].Value
                : null;
            var suffix = detail is null
                ? ""
                : IsEnglish ? $": {detail}" : $"：{detail}";
            return IsEnglish
                ? $"{provider} request failed (HTTP {statusCode}{suffix})"
                : $"{provider} 请求失败（HTTP {statusCode}{suffix}）";
        }

        return message switch
        {
            "没有可翻译的文本" => IsEnglish ? "There is no text to translate" : message,
            "翻译结果为空，未修改原文本" => IsEnglish ? "The translation was empty; the source was not changed" : message,
            "当前没有可编辑的输入框" => IsEnglish ? "There is no editable input field" : message,
            "无法读取当前输入框" => IsEnglish ? "Could not read the current input field" : message,
            "当前控件不支持读取文本" => IsEnglish ? "The current control does not support reading text" : message,
            "输入焦点已改变，已取消回写" => IsEnglish ? "Input focus changed; replacement cancelled" : message,
            "输入内容或选区已改变，已取消回写" => IsEnglish ? "Input or selection changed; replacement cancelled" : message,
            "输入框未确认写入翻译结果，请检查目标应用是否允许粘贴" => IsEnglish ? "The input field did not confirm the translation; check whether the target app allows paste" : message,
            "API Key 不能为空" => MissingApiKey,
            "模型名不能为空" => MissingModel,
            "Endpoint 必须是有效的 HTTPS 地址" => InvalidEndpoint,
            "模型 API 返回了无效响应" => InvalidApiResponse,
            "模型 API 没有返回翻译结果" => EmptyApiResponse,
            _ when message.StartsWith("读取 Windows 凭据失败（", StringComparison.Ordinal)
                => IsEnglish
                    ? message.Replace("读取 Windows 凭据失败（", "Could not read Windows credentials (", StringComparison.Ordinal)
                        .Replace("）", ")", StringComparison.Ordinal)
                    : message,
            _ when message.StartsWith("保存 Windows 凭据失败（", StringComparison.Ordinal)
                => IsEnglish
                    ? message.Replace("保存 Windows 凭据失败（", "Could not save Windows credentials (", StringComparison.Ordinal)
                        .Replace("）", ")", StringComparison.Ordinal)
                    : message,
            "没有找到当前输入窗口" => IsEnglish ? "No current input window found" : message,
            "没有找到当前输入框" => IsEnglish ? "No current input field found" : message,
            "无法向当前输入框发送粘贴命令" => IsEnglish ? "Could not send the paste command to the current input field" : message,
            "无法向当前输入框发送写回验证命令" => IsEnglish ? "Could not send the write-back verification command" : message,
            "剪贴板正被其他应用占用" => IsEnglish ? "The clipboard is being used by another app" : message,
            "更新服务返回了无效响应" => IsEnglish ? "The update service returned an invalid response" : message,
            "升级包校验失败，请稍后重试" => IsEnglish ? "The update package checksum failed; try again later" : message,
            "更新地址必须使用 HTTPS" => IsEnglish ? "The update URL must use HTTPS" : message,
            "更新版本号无效" => IsEnglish ? "The update version is invalid" : message,
            "升级包校验文件无效" => IsEnglish ? "The update checksum file is invalid" : message,
            _ when string.IsNullOrWhiteSpace(message) => OperationFailed,
            _ => message.Replace("HanYi", AppName, StringComparison.Ordinal)
        };
    }
}

