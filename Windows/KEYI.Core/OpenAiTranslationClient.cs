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
            throw new TranslationException("没有可翻译的文本");
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
            var providerName = ProviderCatalog.Get(configuration.ProviderId).DisplayName;
            var suffix = string.IsNullOrWhiteSpace(detail) ? "" : $"：{detail}";
            throw new TranslationException(
                $"{providerName} 请求失败（HTTP {(int)response.StatusCode}{suffix}）");
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
                throw new TranslationException("模型 API 没有返回翻译结果");
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
            throw new TranslationException("模型 API 返回了无效响应", exception);
        }
    }

    public static void ValidateConfiguration(ApiProviderConfiguration configuration)
    {
        if (configuration.Endpoint.Scheme != Uri.UriSchemeHttps
            || string.IsNullOrWhiteSpace(configuration.Endpoint.Host))
        {
            throw new TranslationException("Endpoint 必须是有效的 HTTPS 地址");
        }
        if (string.IsNullOrWhiteSpace(configuration.ApiKey))
        {
            throw new TranslationException("API Key 不能为空");
        }
        if (string.IsNullOrWhiteSpace(configuration.Model))
        {
            throw new TranslationException("模型名不能为空");
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
    public TranslationException(string message) : base(message) { }

    public TranslationException(string message, Exception innerException)
        : base(message, innerException) { }
}
