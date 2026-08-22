namespace KEYI.Core;

public static class VolcengineChatCompletionsMigration
{
    public const string ChatCompletionsEndpoint =
        "https://ark.cn-beijing.volces.com/api/v3/chat/completions";
    public const string ChatCompletionsModel = "doubao-seed-1-6-250615";
    public const string LegacyTranslationModel = "doubao-seed-translation-250915";

    public static string MigratedEndpoint(string? stored)
    {
        var trimmed = stored?.Trim() ?? "";
        if (string.IsNullOrEmpty(trimmed))
        {
            return ChatCompletionsEndpoint;
        }

        if (!Uri.TryCreate(trimmed, UriKind.Absolute, out var uri)
            || !uri.AbsolutePath.EndsWith("/responses", StringComparison.Ordinal))
        {
            return trimmed;
        }

        var builder = new UriBuilder(uri)
        {
            Path = uri.AbsolutePath[..^"responses".Length] + "chat/completions"
        };
        return builder.Uri.ToString().TrimEnd('/');
    }

    public static string MigratedModel(string? stored)
    {
        var trimmed = stored?.Trim() ?? "";
        if (string.IsNullOrEmpty(trimmed) || trimmed == LegacyTranslationModel)
        {
            return ChatCompletionsModel;
        }

        return trimmed;
    }
}
