using System.Globalization;
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
    public string TranslationMethod => IsEnglish ? "Translation" : "翻译服务";
    public string CurrentLabel => IsEnglish ? "Current" : "当前";
    public string TargetLanguage => IsEnglish ? "Language" : "目标语言";
    public string Scene => IsEnglish ? "Context" : "使用场景";
    public string Style => IsEnglish ? "Style" : "表达风格";
    public string InterfaceLanguage => IsEnglish ? "Language" : "界面语言";
    public string ApiManagement => IsEnglish ? "Translation Services" : "翻译服务";
    public string LocalModel => IsEnglish ? "Local Model" : "本地模型";
    public string HotKey => IsEnglish ? "Keyboard Shortcut" : "快捷键";
    public string HotKeySettings => IsEnglish ? "Edit Shortcut..." : "设置快捷键...";
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
    public string ApiRequiredTitle => IsEnglish ? "Translation service required" : "需要配置翻译服务";
    public string ConfigureApiHint(ProviderId provider) => IsEnglish
        ? $"Open {AppName} Settings to set up {ProviderName(provider)}."
        : $"请打开 {AppName} 设置，配置 {ProviderName(provider)}。";
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
        ProviderId.Volcengine => IsEnglish ? "Volcano Ark" : "火山方舟",
        ProviderId.XAI => "Grok",
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
        TranslationLanguage.Chinese => IsEnglish ? "Chinese" : "中文",
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
                ? "Context and style are available with model services"
                : "使用场景和表达风格仅适用于模型服务";
        }
        if (supportsStyle)
        {
            return "";
        }
        return scene switch
        {
            TranslationScene.Business => IsEnglish
                ? "Business prioritizes accuracy; style is unavailable"
                : "商务优先准确，不使用表达风格",
            TranslationScene.Faithful => IsEnglish
                ? "Faithful mode keeps the source; style is unavailable"
                : "贴近原文，不使用表达风格",
            _ => IsEnglish
                ? "Context supports all languages; style applies to English"
                : "使用场景适用于全部目标语言；表达风格仅适用于英语"
        };
    }

    public string ConfigureApi(ProviderId provider) => IsEnglish
        ? $"Set Up {ProviderName(provider)}"
        : $"配置 {ProviderName(provider)}";

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
        ? "The translation service returned an invalid response"
        : "翻译服务返回了无效响应";
    public string EmptyApiResponse => IsEnglish
        ? "The translation service returned no translation"
        : "翻译服务没有返回翻译结果";
    public string EmptySource => IsEnglish
        ? "There is no text to translate"
        : "没有可翻译的文本";

    /// 云端请求失败文案；提供方名与语言在显示时才解析。
    public string ApiRequestFailed(ProviderId provider, int statusCode, string? detail)
    {
        var suffix = string.IsNullOrWhiteSpace(detail)
            ? ""
            : IsEnglish ? $": {detail}" : $"：{detail}";
        return IsEnglish
            ? $"{ProviderName(provider)} request failed (HTTP {statusCode}{suffix})"
            : $"{ProviderName(provider)} 请求失败（HTTP {statusCode}{suffix}）";
    }

    /// 云端提供方错误按类别渲染；不再依赖异常原文做字符串匹配。
    public string TranslationFailure(TranslationException exception) => exception.Kind switch
    {
        TranslationErrorKind.EmptySource => EmptySource,
        TranslationErrorKind.InvalidEndpoint => InvalidEndpoint,
        TranslationErrorKind.MissingApiKey => MissingApiKey,
        TranslationErrorKind.MissingModel => MissingModel,
        TranslationErrorKind.RequestFailed => ApiRequestFailed(
            exception.ProviderId ?? ProviderId.DeepSeek,
            exception.StatusCode ?? 0,
            exception.Detail),
        TranslationErrorKind.EmptyResponse => EmptyApiResponse,
        TranslationErrorKind.InvalidResponse => InvalidApiResponse,
        _ => exception.Message
    };

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
        ? $"Set up {ProviderName(provider)} first"
        : $"请先配置 {ProviderName(provider)}";
    public string SelectedProvider(ProviderId provider) => IsEnglish
        ? $"Using {ProviderName(provider)}"
        : $"正在使用 {ProviderName(provider)}";
    public string SavedProvider(ProviderId provider) => IsEnglish
        ? $"Saved {ProviderName(provider)}"
        : $"已保存 {ProviderName(provider)}";
    public string HotKeyUpdated(string value) => IsEnglish
        ? $"Keyboard shortcut updated to {value}"
        : $"快捷键已更新为 {value}";
    public string HotKeyUnavailable(string value) => IsEnglish
        ? $"Keyboard shortcut {value} could not be registered; another app may be using it."
        : $"快捷键 {value} 无法注册，可能已被其他应用占用。";
    public string SaveHotKeyFailed => IsEnglish
        ? "Could not save the hotkey, and the previous hotkey could not be restored. Please set it again."
        : "保存快捷键失败，且原快捷键恢复失败，请重新设置";
    public string FallbackHotKey(string value) => IsEnglish
        ? $"The previous hotkey was unavailable; restored {value}"
        : $"原快捷键不可用，已恢复 {value}";
    public string HotKeyRegistrationFailed => IsEnglish
        ? "Global keyboard shortcut registration failed; set it again in Settings."
        : "全局快捷键注册失败，请在设置中重新设置";

    // MARK: 设置窗口

    public string Settings => IsEnglish ? "Settings..." : "设置...";
    public string SettingsTitle => IsEnglish ? "Settings" : "设置";
    public string TranslationTab => IsEnglish ? "Translation" : "翻译";
    public string ProvidersTab => IsEnglish ? "Services" : "翻译服务";
    public string HotKeyTab => IsEnglish ? "Shortcuts" : "快捷键";
    public string GeneralTab => IsEnglish ? "General" : "通用";
    public string SavedHint => IsEnglish ? "Saved" : "已保存";
    public string UseAsCurrent => IsEnglish ? "Use for Translation" : "用于翻译";
    public string CurrentlyUsed => IsEnglish ? "Used for Translation" : "正在用于翻译";
    public string ConfiguredSuffix => IsEnglish ? "Configured" : "已配置";

    public string UpdateChecking => IsEnglish ? "Checking for updates" : "正在检查更新";    public string UpToDate => IsEnglish ? "You are up to date" : "当前已是最新版本";
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

        if (exception is TranslationException translation)
        {
            return TranslationFailure(translation);
        }

        var message = exception.Message;
        return message switch
        {
            _ when string.IsNullOrWhiteSpace(message) => OperationFailed,
            _ => message.Replace("HanYi", AppName, StringComparison.Ordinal)
        };
    }
}
