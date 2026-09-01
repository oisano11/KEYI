using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace KEYI.Core;

public sealed class OpenAiTranslationClient
{
    private readonly HttpClient _httpClient;

    public OpenAiTranslationClient(HttpClient httpClient)
    {
        _httpClient = httpClient;
    }

    public async Task<string> TranslateAsync(
        TextTranslationRequest request,
        ApiProviderConfiguration configuration,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(request.SourceText))
        {
            throw new TranslationException(
                TranslationErrorKind.EmptySource,
                "No translatable source text");
        }
        ValidateConfiguration(configuration);

        var body = JsonSerializer.Serialize(new
        {
            model = configuration.Model,
            messages = new[]
            {
                new
                {
                    role = "system",
                    content = TranslationPromptBuilder.SystemPrompt(request)
                },
                new
                {
                    role = "user",
                    content = TranslationPromptBuilder.UserPrompt(request)
                }
            },
            temperature = request.Scene == TranslationScene.Faithful ? 0 : 0.2
        });

        using var message = new HttpRequestMessage(HttpMethod.Post, configuration.Endpoint)
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json")
        };
        message.Headers.Authorization = new AuthenticationHeaderValue(
            "Bearer",
            configuration.ApiKey);

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(45));
        using var response = await _httpClient.SendAsync(message, timeout.Token);
        var responseBody = await response.Content.ReadAsStringAsync(timeout.Token);

        if (!response.IsSuccessStatusCode)
        {
            var detail = ReadErrorMessage(responseBody);
            throw new TranslationException(
                TranslationErrorKind.RequestFailed,
                $"HTTP {(int)response.StatusCode}: {detail}",
                configuration.ProviderId,
                (int)response.StatusCode,
                detail);
        }

        try
        {
            using var document = JsonDocument.Parse(responseBody);
            var content = document.RootElement
                .GetProperty("choices")[0]
                .GetProperty("message")
                .GetProperty("content")
                .GetString()
                ?.Trim();
            if (string.IsNullOrEmpty(content))
            {
                throw new TranslationException(
                    TranslationErrorKind.EmptyResponse,
                    "Translation service returned no translation");
            }
            return content;
        }
        catch (TranslationException)
        {
            throw;
        }
        catch (Exception exception) when (
            exception is JsonException or KeyNotFoundException or InvalidOperationException)
        {
            throw new TranslationException(
                TranslationErrorKind.InvalidResponse,
                "Translation service returned an invalid response",
                exception);
        }
    }

    public static void ValidateConfiguration(ApiProviderConfiguration configuration)
    {
        if (configuration.Endpoint.Scheme != Uri.UriSchemeHttps
            || string.IsNullOrWhiteSpace(configuration.Endpoint.Host))
        {
            throw new TranslationException(
                TranslationErrorKind.InvalidEndpoint,
                "Endpoint must be a valid HTTPS URL");
        }
        if (string.IsNullOrWhiteSpace(configuration.ApiKey))
        {
            throw new TranslationException(
                TranslationErrorKind.MissingApiKey,
                "API Key is required");
        }
        if (string.IsNullOrWhiteSpace(configuration.Model))
        {
            throw new TranslationException(
                TranslationErrorKind.MissingModel,
                "Model name is required");
        }
    }

    private static string? ReadErrorMessage(string responseBody)
    {
        try
        {
            using var document = JsonDocument.Parse(responseBody);
            return document.RootElement
                .GetProperty("error")
                .GetProperty("message")
                .GetString();
        }
        catch
        {
            return null;
        }
    }
}

public sealed class TranslationException : Exception
{
    /// 错误类别；用户可见文案由 UI 层按界面语言渲染，
    /// Message 仅保留中性英文兜底描述。
    public TranslationErrorKind Kind { get; }

    public ProviderId? ProviderId { get; }

    public int? StatusCode { get; }

    public string? Detail { get; }

    public TranslationException(TranslationErrorKind kind, string message)
        : base(message)
    {
        Kind = kind;
    }

    public TranslationException(
        TranslationErrorKind kind,
        string message,
        Exception innerException)
        : base(message, innerException)
    {
        Kind = kind;
    }

    public TranslationException(
        TranslationErrorKind kind,
        string message,
        ProviderId providerId,
        int statusCode,
        string? detail)
        : base(message)
    {
        Kind = kind;
        ProviderId = providerId;
        StatusCode = statusCode;
        Detail = detail;
    }
}

public enum TranslationErrorKind
{
    EmptySource,
    InvalidEndpoint,
    MissingApiKey,
    MissingModel,
    RequestFailed,
    EmptyResponse,
    InvalidResponse
}
