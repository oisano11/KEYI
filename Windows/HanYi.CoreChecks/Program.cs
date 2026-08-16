using System.Net;
using System.Text;
using System.Text.Json;
using HanYi.Core;

var checks = new List<(string Name, Func<Task> Run)>
{
    ("provider defaults", CheckProviderDefaults),
    ("target languages", CheckTargetLanguages),
    ("settings round trip", CheckSettingsRoundTrip),
    ("prompt payload escaping", CheckPromptPayload),
    ("successful API request", CheckSuccessfulRequest),
    ("volcengine responses request", CheckVolcengineResponsesRequest),
    ("API error details", CheckApiError),
    ("HTTPS validation", CheckHttpsValidation),
    ("focused text fallback policy", CheckFocusedTextFallbackPolicy),
};

foreach (var check in checks)
{
    await check.Run();
    Console.WriteLine($"PASS {check.Name}");
}
Console.WriteLine($"HanYi Windows core checks passed: {checks.Count}");

static Task CheckProviderDefaults()
{
    Assert(ProviderCatalog.All.Count == 4, "provider count");
    Assert(ProviderCatalog.Get(ProviderId.DeepSeek).DefaultModel == "deepseek-chat", "DeepSeek model");
    Assert(ProviderCatalog.Get(ProviderId.XAI).DefaultEndpoint == "https://api.x.ai/v1/chat/completions", "xAI endpoint");
    Assert(
        ProviderCatalog.Get(ProviderId.Volcengine).DefaultEndpoint == "https://ark.cn-beijing.volces.com/api/v3/responses",
        "volcengine responses endpoint matches macOS");
    Assert(
        ProviderCatalog.Get(ProviderId.Volcengine).DefaultModel == "doubao-seed-translation-250915",
        "volcengine translation model matches macOS");
    Assert(ProviderCatalog.All.All(provider => provider.DefaultEndpoint.StartsWith("https://", StringComparison.Ordinal)), "HTTPS defaults");
    return Task.CompletedTask;
}

static Task CheckTargetLanguages()
{
    var languages = Enum.GetValues<TranslationLanguage>();
    Assert(languages.Length == 12, "language count");
    Assert(languages.Select(language => language.LanguageCode()).Distinct().Count() == 12, "language codes unique");
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

static async Task CheckVolcengineResponsesRequest()
{
    string? capturedBody = null;
    using var http = new HttpClient(new StubHandler(async request =>
    {
        capturedBody = await request.Content!.ReadAsStringAsync();
        return JsonResponse(HttpStatusCode.OK,
            "{\"output\":[{\"content\":[{\"type\":\"output_text\",\"text\":\"  こんにちは。  \"}]}]}");
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
            new Uri("https://ark.cn-beijing.volces.com/api/v3/responses"),
            "doubao-seed-translation-250915"));

    Assert(result == "こんにちは。", "responses result trimmed");
    using var document = JsonDocument.Parse(capturedBody!);
    Assert(!document.RootElement.TryGetProperty("messages", out _), "responses payload has no chat messages");
    var content = document.RootElement.GetProperty("input")[0].GetProperty("content")[0];
    Assert(content.GetProperty("type").GetString() == "input_text", "responses input_text");
    Assert(content.GetProperty("text").GetString() == "你好", "responses source text");
    var options = content.GetProperty("translation_options");
    Assert(options.GetProperty("source_language").GetString() == "zh", "responses source language");
    Assert(options.GetProperty("target_language").GetString() == "ja", "responses target language");
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
        Assert(exception.Message.Contains("401", StringComparison.Ordinal), "status code");
        Assert(exception.Message.Contains("bad key", StringComparison.Ordinal), "error detail");
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
        Assert(exception.Message.Contains("HTTPS", StringComparison.Ordinal), "HTTPS error");
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
