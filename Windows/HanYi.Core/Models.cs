using System.Text.Json;
using System.Text.Json.Serialization;

namespace HanYi.Core;

public enum ProviderId
{
    DeepSeek,
    Qwen,
    Volcengine,
    XAI
}

public sealed record ProviderDefinition(
    ProviderId Id,
    string DisplayName,
    string DefaultEndpoint,
    string DefaultModel);

public static class ProviderCatalog
{
    public static IReadOnlyList<ProviderDefinition> All { get; } =
    [
        new(
            ProviderId.DeepSeek,
            "DeepSeek",
            "https://api.deepseek.com/chat/completions",
            "deepseek-chat"),
        new(
            ProviderId.Qwen,
            "通义千问",
            "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
            "qwen-plus"),
        new(
            ProviderId.Volcengine,
            "火山引擎",
            "https://ark.cn-beijing.volces.com/api/v3/responses",
            "doubao-seed-translation-250915"),
        new(
            ProviderId.XAI,
            "xAI Grok",
            "https://api.x.ai/v1/chat/completions",
            "grok-4.5")
    ];

    public static ProviderDefinition Get(ProviderId id) =>
        All.First(provider => provider.Id == id);
}

public enum TranslationScene
{
    Automatic,
    DailyChat,
    SocialMedia,
    Business,
    Faithful
}

public enum EnglishStyle
{
    Automatic,
    StandardAmerican,
    WestCoast,
    BlackAmerican,
    British
}

public enum TranslationLanguage
{
    English,
    Japanese,
    Korean,
    French,
    German,
    Spanish,
    Russian,
    Portuguese,
    Italian,
    Thai,
    Vietnamese,
    Arabic
}

public static class TranslationOptionNames
{
    public static string DisplayName(this TranslationScene scene) => scene switch
    {
        TranslationScene.Automatic => "自动判断",
        TranslationScene.DailyChat => "日常聊天",
        TranslationScene.SocialMedia => "X / 社交媒体",
        TranslationScene.Business => "商务正式",
        TranslationScene.Faithful => "忠实直译",
        _ => scene.ToString()
    };

    public static string DisplayName(this EnglishStyle style) => style switch
    {
        EnglishStyle.Automatic => "自动 / 中性",
        EnglishStyle.StandardAmerican => "标准美式",
        EnglishStyle.WestCoast => "美国西海岸",
        EnglishStyle.BlackAmerican => "Black American / 街头 AAVE",
        EnglishStyle.British => "英式英语",
        _ => style.ToString()
    };

    public static string DisplayName(this TranslationLanguage language) => language switch
    {
        TranslationLanguage.English => "英语",
        TranslationLanguage.Japanese => "日语",
        TranslationLanguage.Korean => "韩语",
        TranslationLanguage.French => "法语",
        TranslationLanguage.German => "德语",
        TranslationLanguage.Spanish => "西班牙语",
        TranslationLanguage.Russian => "俄语",
        TranslationLanguage.Portuguese => "葡萄牙语",
        TranslationLanguage.Italian => "意大利语",
        TranslationLanguage.Thai => "泰语",
        TranslationLanguage.Vietnamese => "越南语",
        TranslationLanguage.Arabic => "阿拉伯语",
        _ => language.ToString()
    };

    public static string LanguageCode(this TranslationLanguage language) => language switch
    {
        TranslationLanguage.English => "en",
        TranslationLanguage.Japanese => "ja",
        TranslationLanguage.Korean => "ko",
        TranslationLanguage.French => "fr",
        TranslationLanguage.German => "de",
        TranslationLanguage.Spanish => "es",
        TranslationLanguage.Russian => "ru",
        TranslationLanguage.Portuguese => "pt",
        TranslationLanguage.Italian => "it",
        TranslationLanguage.Thai => "th",
        TranslationLanguage.Vietnamese => "vi",
        TranslationLanguage.Arabic => "ar",
        _ => throw new ArgumentOutOfRangeException(nameof(language))
    };
}

public sealed record TextTranslationRequest(
    string SourceText,
    string? ContextText,
    TranslationLanguage TargetLanguage,
    TranslationScene Scene,
    EnglishStyle EnglishStyle);

public sealed record ApiProviderConfiguration(
    ProviderId ProviderId,
    string ApiKey,
    Uri Endpoint,
    string Model);

[Flags]
public enum HotKeyModifiers : uint
{
    None = 0,
    Alt = 0x0001,
    Control = 0x0002,
    Shift = 0x0004,
    Win = 0x0008
}

public sealed class HotKeySettings
{
    public HotKeyModifiers Modifiers { get; set; } = HotKeyModifiers.Alt;
    public int VirtualKey { get; set; } = 0x54;
}

public sealed class ProviderSettings
{
    public string Endpoint { get; set; } = "";
    public string Model { get; set; } = "";
}

public sealed class AppSettings
{
    public ProviderId SelectedProvider { get; set; } = ProviderId.DeepSeek;
    public TranslationLanguage TargetLanguage { get; set; } = TranslationLanguage.English;
    public TranslationScene Scene { get; set; } = TranslationScene.Automatic;
    public EnglishStyle EnglishStyle { get; set; } = EnglishStyle.Automatic;
    public HotKeySettings HotKey { get; set; } = new();
    public Dictionary<ProviderId, ProviderSettings> Providers { get; set; } = [];

    public void EnsureDefaults()
    {
        HotKey ??= new HotKeySettings();
        Providers ??= [];
        foreach (var provider in ProviderCatalog.All)
        {
            if (!Providers.TryGetValue(provider.Id, out var settings))
            {
                Providers[provider.Id] = new ProviderSettings
                {
                    Endpoint = provider.DefaultEndpoint,
                    Model = provider.DefaultModel
                };
                continue;
            }

            if (string.IsNullOrWhiteSpace(settings.Endpoint))
            {
                settings.Endpoint = provider.DefaultEndpoint;
            }
            if (string.IsNullOrWhiteSpace(settings.Model))
            {
                settings.Model = provider.DefaultModel;
            }
        }
    }
}

public static class SettingsJson
{
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() }
    };

    public static string Serialize(AppSettings settings) =>
        JsonSerializer.Serialize(settings, Options);

    public static AppSettings Deserialize(string json)
    {
        var settings = JsonSerializer.Deserialize<AppSettings>(json, Options)
            ?? new AppSettings();
        settings.EnsureDefaults();
        return settings;
    }
}
