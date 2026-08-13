namespace HanYi.Core;

public enum FocusedTextReadMode
{
    TextPattern,
    ValuePattern,
    ClipboardSelection
}

public static class FocusedTextReadModePolicy
{
    public static FocusedTextReadMode Select(
        bool supportsTextPattern,
        bool supportsValuePattern) =>
        supportsTextPattern
            ? FocusedTextReadMode.TextPattern
            : supportsValuePattern
                ? FocusedTextReadMode.ValuePattern
                : FocusedTextReadMode.ClipboardSelection;

    public static bool SupportsClipboardSelectionFallback(string? processName) =>
        string.Equals(processName, "Weixin", StringComparison.OrdinalIgnoreCase)
        || string.Equals(processName, "WhatsApp.Root", StringComparison.OrdinalIgnoreCase);
}
