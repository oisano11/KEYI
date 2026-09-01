using System.Net;
using System.Text;
using System.Text.Json;
using KEYI.Core;

var checks = new List<(string Name, Func<Task> Run)>
{
    ("provider defaults", CheckProviderDefaults),
    ("target languages", CheckTargetLanguages),
    ("settings round trip", CheckSettingsRoundTrip),
    ("prompt payload escaping", CheckPromptPayload),
    ("successful API request", CheckSuccessfulRequest),
    ("volcengine chat completions request", CheckVolcengineChatCompletionsRequest),
    ("volcengine settings migration", CheckVolcengineSettingsMigration),
    ("interface labels", CheckInterfaceLabels),
    ("API error details", CheckApiError),
    ("HTTPS validation", CheckHttpsValidation),
    ("legacy settings file migration", CheckLegacySettingsFileMigration),
    ("focused text fallback policy", CheckFocusedTextFallbackPolicy),
};

foreach (var check in checks)
{
    await check.Run();
    Console.WriteLine($"PASS {check.Name}");
}
Console.WriteLine($"KEYI Windows core checks passed: {checks.Count}");

static Task CheckProviderDefaults()
{
    Assert(ProviderCatalog.All.Count == 4, "provider count");
    Assert(ProviderCatalog.Get(ProviderId.DeepSeek).DefaultModel == "deepseek-chat", "DeepSeek model");
    Assert(ProviderCatalog.Get(ProviderId.XAI).DefaultEndpoint == "https://api.x.ai/v1/chat/completions", "xAI endpoint");
    Assert(
        ProviderCatalog.Get(ProviderId.Volcengine).DefaultEndpoint == "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
        "volcengine chat completions endpoint matches macOS");
    Assert(
        ProviderCatalog.Get(ProviderId.Volcengine).DefaultModel == "doubao-seed-1-6-250615",
        "volcengine chat completions model matches macOS");
    Assert(ProviderCatalog.All.All(provider => provider.DefaultEndpoint.StartsWith("https://", StringComparison.Ordinal)), "HTTPS defaults");
    return Task.CompletedTask;
}

static Task CheckTargetLanguages()
{
    var languages = Enum.GetValues<TranslationLanguage>();
    Assert(languages.Length == 13, "language count");
    Assert(languages.Select(language => language.LanguageCode()).Distinct().Count() == 13, "language codes unique");
    Assert(TranslationLanguage.Chinese.DisplayName() == "中文", "Chinese display name");
    Assert(TranslationLanguage.Chinese.LanguageCode() == "zh-Hans", "Chinese language code");
    Assert(TranslationLanguage.Japanese.DisplayName() == "日语", "Japanese display name");
    Assert(TranslationLanguage.Arabic.LanguageCode() == "ar", "Arabic code");
    return Task.CompletedTask;
}

static Task CheckSettingsRoundTrip()
{
    var settings = new AppSettings
    {
        SelectedProvider = ProviderId.Qwen,
        TargetLanguage = TranslationLanguage.Japanese,
        Scene = TranslationScene.SocialMedia,
        EnglishStyle = EnglishStyle.British
    };
    settings.EnsureDefaults();
    var json = SettingsJson.Serialize(settings);
    var restored = SettingsJson.Deserialize(json);
    Assert(restored.SelectedProvider == ProviderId.Qwen, "selected provider");
    Assert(restored.TargetLanguage == TranslationLanguage.Japanese, "target language");
    Assert(restored.Scene == TranslationScene.SocialMedia, "scene");
    Assert(restored.Providers.Count == 4, "provider settings");
    Assert(!json.Contains("apiKey", StringComparison.OrdinalIgnoreCase), "settings contain no API key field");
    var legacy = SettingsJson.Deserialize("{\"SelectedProvider\":\"DeepSeek\"}");
    Assert(legacy.TargetLanguage == TranslationLanguage.English, "legacy language default");
    return Task.CompletedTask;
}

static Task CheckPromptPayload()
{
    var request = new TextTranslationRequest(
        "他说：\"你好\"",
        "前缀\n他说：\"你好\"",
        TranslationLanguage.English,
        TranslationScene.DailyChat,
        EnglishStyle.StandardAmerican);
    var prompt = TranslationPromptBuilder.UserPrompt(request);
    var json = prompt[(prompt.IndexOf('{'))..];
    using var document = JsonDocument.Parse(json);
    Assert(document.RootElement.GetProperty("source_text").GetString() == request.SourceText, "source payload");
    Assert(!document.RootElement.TryGetProperty("full_input_context", out _), "context must not leave the device");
    return Task.CompletedTask;
}

static async Task CheckSuccessfulRequest()
{
    HttpRequestMessage? captured = null;
    string? capturedBody = null;
    using var http = new HttpClient(new StubHandler(async request =>
    {
        captured = request;
        capturedBody = await request.Content!.ReadAsStringAsync();
        return JsonResponse(HttpStatusCode.OK, "{\"choices\":[{\"message\":{\"content\":\"Hello.\"}}]}");
    }));
    var client = new OpenAiTranslationClient(http);
    var result = await client.TranslateAsync(
        new TextTranslationRequest(
            "你好",
            null,
            TranslationLanguage.Japanese,
            TranslationScene.Automatic,
            EnglishStyle.BlackAmerican),
        new ApiProviderConfiguration(
            ProviderId.DeepSeek,
            "test-secret",
            new Uri("https://example.test/chat/completions"),
            "test-model"));

    Assert(result == "Hello.", "translation result");
    Assert(captured?.Headers.Authorization?.Scheme == "Bearer", "authorization scheme");
    Assert(captured?.Headers.Authorization?.Parameter == "test-secret", "authorization secret");
    using var requestDocument = JsonDocument.Parse(capturedBody!);
    var systemContent = requestDocument.RootElement
        .GetProperty("messages")[0]
        .GetProperty("content")
        .GetString()!;
    Assert(systemContent.Contains("zh-Hans to ja", StringComparison.Ordinal), "target language prompt");
    Assert(!systemContent.Contains("AAVE", StringComparison.Ordinal), "non-English style omitted");
    var userContent = requestDocument.RootElement
        .GetProperty("messages")[1]
        .GetProperty("content")
        .GetString()!;
    using var payloadDocument = JsonDocument.Parse(userContent[userContent.IndexOf('{')..]);
    Assert(
        payloadDocument.RootElement.GetProperty("source_text").GetString() == "你好",
        "source text body");
    Assert(!payloadDocument.RootElement.TryGetProperty("full_input_context", out _), "request must not include full input context");
}

static async Task CheckVolcengineChatCompletionsRequest()
{
    string? capturedBody = null;
    using var http = new HttpClient(new StubHandler(async request =>
    {
        capturedBody = await request.Content!.ReadAsStringAsync();
        return JsonResponse(HttpStatusCode.OK, "{\"choices\":[{\"message\":{\"content\":\"  こんにちは。  \"}}]}");
    }));
    var client = new OpenAiTranslationClient(http);
    var result = await client.TranslateAsync(
        new TextTranslationRequest(
            "你好",
            null,
            TranslationLanguage.Japanese,
            TranslationScene.Automatic,
            EnglishStyle.Automatic),
        new ApiProviderConfiguration(
            ProviderId.Volcengine,
            "test-secret",
            new Uri("https://ark.cn-beijing.volces.com/api/v3/chat/completions"),
            "doubao-seed-1-6-250615"));

    Assert(result == "こんにちは。", "chat completions result trimmed");
    using var document = JsonDocument.Parse(capturedBody!);
    var messages = document.RootElement.GetProperty("messages");
    Assert(messages.GetArrayLength() == 2, "chat completions payload has messages");
    var userContent = messages[1].GetProperty("content").GetString()!;
    using var payload = JsonDocument.Parse(userContent[userContent.IndexOf('{')..]);
    Assert(payload.RootElement.GetProperty("source_text").GetString() == "你好", "chat completions source text");
    Assert(!payload.RootElement.TryGetProperty("full_input_context", out _), "chat completions must not include full input context");
}

static Task CheckVolcengineSettingsMigration()
{
    var settings = new AppSettings();
    settings.EnsureDefaults();
    settings.Providers[ProviderId.Volcengine] = new ProviderSettings
    {
        Endpoint = "https://ark.cn-beijing.volces.com/api/v3/responses",
        Model = "doubao-seed-translation-250915"
    };
    settings.EnsureDefaults();
    Assert(
        settings.Providers[ProviderId.Volcengine].Endpoint == "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
        "legacy volcengine endpoint migrates");
    Assert(
        settings.Providers[ProviderId.Volcengine].Model == "doubao-seed-1-6-250615",
        "legacy volcengine model migrates");
    return Task.CompletedTask;
}

static Task CheckInterfaceLabels()
{
    Assert(TranslationScene.DailyChat.DisplayName() == "聊天", "daily chat label");
    Assert(TranslationScene.SocialMedia.DisplayName() == "发帖", "social label");
    Assert(TranslationScene.Faithful.DisplayName() == "贴近原文", "faithful label");
    Assert(EnglishStyle.Automatic.DisplayName() == "自然", "natural tone label");
    Assert(EnglishStyle.BlackAmerican.DisplayName() == "黑人英语", "black american label");
    Assert(
        !TranslationPromptBuilder.UsesEnglishStyle(TranslationLanguage.Japanese, TranslationScene.DailyChat),
        "tone disabled for non-English");
    Assert(
        !TranslationPromptBuilder.UsesEnglishStyle(TranslationLanguage.English, TranslationScene.Faithful),
        "tone disabled for faithful");
    var prompt = TranslationPromptBuilder.SystemPrompt(new TextTranslationRequest(
        "兄弟，这也太离谱了",
        null,
        TranslationLanguage.English,
        TranslationScene.SocialMedia,
        EnglishStyle.BlackAmerican));
    Assert(prompt.Contains("not a slang quota", StringComparison.Ordinal), "black american is not a slang quota");
    Assert(!prompt.Contains("finna", StringComparison.Ordinal), "black american must not force slang");
    var chinesePrompt = TranslationPromptBuilder.SystemPrompt(new TextTranslationRequest(
        "Hello",
        null,
        TranslationLanguage.Chinese,
        TranslationScene.Automatic,
        EnglishStyle.Automatic));
    Assert(
        chinesePrompt.Contains("Detect the source language and translate to zh-Hans", StringComparison.Ordinal),
        "Chinese target detects source language");
    return Task.CompletedTask;
}

static async Task CheckApiError()
{
    using var http = new HttpClient(new StubHandler(_ => Task.FromResult(
        JsonResponse(HttpStatusCode.Unauthorized, "{\"error\":{\"message\":\"bad key\"}}"))));
    var client = new OpenAiTranslationClient(http);
    try
    {
        await client.TranslateAsync(
            new TextTranslationRequest(
                "你好",
                null,
                TranslationLanguage.English,
                TranslationScene.Automatic,
                EnglishStyle.Automatic),
            new ApiProviderConfiguration(
                ProviderId.Qwen,
                "invalid",
                new Uri("https://example.test/chat/completions"),
                "qwen"));
        throw new Exception("expected API failure");
    }
    catch (TranslationException exception)
    {
        Assert(exception.Kind == TranslationErrorKind.RequestFailed, "error kind");
        Assert(exception.ProviderId == ProviderId.Qwen, "error provider");
        Assert(exception.StatusCode == 401, "status code");
        Assert(exception.Detail == "bad key", "error detail");
    }
}

static Task CheckHttpsValidation()
{
    try
    {
        OpenAiTranslationClient.ValidateConfiguration(new ApiProviderConfiguration(
            ProviderId.DeepSeek,
            "secret",
            new Uri("http://example.test"),
            "model"));
        throw new Exception("expected HTTPS validation failure");
    }
    catch (TranslationException exception)
    {
        Assert(exception.Kind == TranslationErrorKind.InvalidEndpoint, "HTTPS error kind");
        Assert(
            exception.Message.Contains("HTTPS", StringComparison.Ordinal),
            "HTTPS fallback message");
    }
    return Task.CompletedTask;
}

static Task CheckLegacySettingsFileMigration()
{
    var root = Path.Combine(Path.GetTempPath(), $"KEYI.CoreChecks-{Guid.NewGuid():N}");
    var currentPath = Path.Combine(root, "KEYI", "settings.json");
    var legacyPath = Path.Combine(root, "HanYi", "settings.json");

    try
    {
        var legacy = new AppSettings
        {
            SelectedProvider = ProviderId.Qwen,
            TargetLanguage = TranslationLanguage.Japanese,
            Scene = TranslationScene.Business,
            EnglishStyle = EnglishStyle.British
        };
        legacy.EnsureDefaults();
        legacy.Providers[ProviderId.Qwen] = new ProviderSettings
        {
            Endpoint = "https://legacy.example.test/chat/completions",
            Model = "legacy-model"
        };
        SettingsFileStore.Save(legacyPath, legacy);

        var migrated = SettingsFileStore.Load(currentPath, legacyPath);
        Assert(migrated.SelectedProvider == ProviderId.Qwen, "legacy provider migrated");
        Assert(migrated.TargetLanguage == TranslationLanguage.Japanese, "legacy language migrated");
        Assert(
            migrated.Providers[ProviderId.Qwen].Endpoint == "https://legacy.example.test/chat/completions",
            "legacy endpoint migrated");
        Assert(File.Exists(currentPath), "legacy settings persisted at KEYI path");

        var current = new AppSettings { SelectedProvider = ProviderId.XAI };
        current.EnsureDefaults();
        SettingsFileStore.Save(currentPath, current);
        var currentWins = SettingsFileStore.Load(currentPath, legacyPath);
        Assert(currentWins.SelectedProvider == ProviderId.XAI, "existing KEYI settings win");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, true);
        }
    }

    return Task.CompletedTask;
}

static Task CheckFocusedTextFallbackPolicy()
{
    Assert(
        FocusedTextReadModePolicy.Select(true, true) == FocusedTextReadMode.TextPattern,
        "TextPattern preferred");
    Assert(
        FocusedTextReadModePolicy.Select(false, true) == FocusedTextReadMode.ValuePattern,
        "ValuePattern fallback");
    Assert(
        FocusedTextReadModePolicy.Select(false, false) == FocusedTextReadMode.ClipboardSelection,
        "WeChat-style UIA window uses selected clipboard fallback");
    Assert(
        FocusedTextReadModePolicy.SupportsClipboardSelectionFallback("Weixin"),
        "Weixin enables selected clipboard fallback");
    Assert(
        FocusedTextReadModePolicy.SupportsClipboardSelectionFallback("WhatsApp.Root"),
        "WhatsApp Desktop enables selected clipboard fallback");
    Assert(
        !FocusedTextReadModePolicy.SupportsClipboardSelectionFallback("Notepad"),
        "other controls keep the UIA-only boundary");
    return Task.CompletedTask;
}

static HttpResponseMessage JsonResponse(HttpStatusCode status, string json) => new(status)
{
    Content = new StringContent(json, Encoding.UTF8, "application/json")
};

static void Assert(bool condition, string message)
{
    if (!condition)
    {
        throw new Exception($"Assertion failed: {message}");
    }
}

sealed class StubHandler(Func<HttpRequestMessage, Task<HttpResponseMessage>> response)
    : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken) => response(request);
}
