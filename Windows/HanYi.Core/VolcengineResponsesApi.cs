using System.Text.Json;
using System.Text.Json.Serialization;

namespace HanYi.Core;

/// <summary>
/// 火山引擎 Ark /responses 翻译接口的请求与响应编解码。
/// 请求/响应结构与 macOS 端 VolcengineResponsesAPI.swift 保持一致。
/// </summary>
public static class VolcengineResponsesApi
{
    public static string BuildRequestBody(
        string model,
        string text,
        string targetLanguageCode) =>
        JsonSerializer.Serialize(new RequestPayload(
            model,
            [
                new InputMessage(
                    "user",
                    [
                        new InputContent(
                            "input_text",
                            text,
                            new TranslationOptions("zh", targetLanguageCode))
                    ])
            ]));

    /// <summary>返回第一段非空译文；JSON 解析失败抛出 JsonException，由调用方归一为无效响应。</summary>
    public static string? ReadTranslatedText(string responseBody)
    {
        using var document = JsonDocument.Parse(responseBody);
        var root = document.RootElement;

        if (root.TryGetProperty("output_text", out var outputText))
        {
            var candidate = NonEmptyTrimmed(outputText);
            if (candidate is not null)
            {
                return candidate;
            }
        }

        if (root.TryGetProperty("output", out var output)
            && output.ValueKind == JsonValueKind.Array)
        {
            foreach (var message in output.EnumerateArray())
            {
                if (!message.TryGetProperty("content", out var content)
                    || content.ValueKind != JsonValueKind.Array)
                {
                    continue;
                }
                foreach (var item in content.EnumerateArray())
                {
                    if (item.TryGetProperty("type", out var type)
                        && type.GetString() != "output_text")
                    {
                        continue;
                    }
                    if (!item.TryGetProperty("text", out var text))
                    {
                        continue;
                    }
                    var candidate = NonEmptyTrimmed(text);
                    if (candidate is not null)
                    {
                        return candidate;
                    }
                }
            }
        }

        return null;
    }

    private static string? NonEmptyTrimmed(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.String)
        {
            return null;
        }
        var value = element.GetString()?.Trim();
        return string.IsNullOrEmpty(value) ? null : value;
    }

    private sealed record RequestPayload(
        [property: JsonPropertyName("model")] string Model,
        [property: JsonPropertyName("input")] InputMessage[] Input);

    private sealed record InputMessage(
        [property: JsonPropertyName("role")] string Role,
        [property: JsonPropertyName("content")] InputContent[] Content);

    private sealed record InputContent(
        [property: JsonPropertyName("type")] string Type,
        [property: JsonPropertyName("text")] string Text,
        [property: JsonPropertyName("translation_options")] TranslationOptions TranslationOptions);

    private sealed record TranslationOptions(
        [property: JsonPropertyName("source_language")] string SourceLanguage,
        [property: JsonPropertyName("target_language")] string TargetLanguage);
}
