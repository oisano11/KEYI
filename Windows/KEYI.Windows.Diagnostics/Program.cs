using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;

var options = ProbeOptions.Parse(args);
using var writer = new StreamWriter(options.OutputPath, append: false)
{
    AutoFlush = true
};
var gate = new object();

void Record(string reason)
{
    FocusRecord record;
    try
    {
        record = FocusRecord.Capture(reason);
    }
    catch (Exception exception)
    {
        record = FocusRecord.Failure(reason, exception.GetType().Name);
    }

    lock (gate)
    {
        writer.WriteLine(JsonSerializer.Serialize(record));
    }
}

AutomationFocusChangedEventHandler focusChanged = (_, _) => Record("focus-changed");
Automation.AddAutomationFocusChangedEventHandler(focusChanged);
try
{
    Record("start");
    var deadline = DateTimeOffset.UtcNow.AddMilliseconds(options.DurationMilliseconds);
    while (DateTimeOffset.UtcNow < deadline)
    {
        await Task.Delay(options.IntervalMilliseconds);
        Record("poll");
    }
    Record("complete");
}
finally
{
    Automation.RemoveAutomationFocusChangedEventHandler(focusChanged);
}

internal sealed record ProbeOptions(string OutputPath, int DurationMilliseconds, int IntervalMilliseconds)
{
    public static ProbeOptions Parse(string[] args)
    {
        var outputPath = GetRequired(args, "--output");
        var duration = GetPositiveInt(args, "--duration-ms", 20_000);
        var interval = GetPositiveInt(args, "--interval-ms", 250);
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outputPath))!);
        return new ProbeOptions(outputPath, duration, interval);
    }

    private static string GetRequired(string[] args, string name)
    {
        var value = GetValue(args, name);
        return !string.IsNullOrWhiteSpace(value)
            ? value
            : throw new ArgumentException($"Missing required argument: {name}");
    }

    private static int GetPositiveInt(string[] args, string name, int fallback)
    {
        var value = GetValue(args, name);
        return value is not null && int.TryParse(value, out var parsed) && parsed > 0
            ? parsed
            : fallback;
    }

    private static string? GetValue(string[] args, string name)
    {
        var index = Array.IndexOf(args, name);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }
}

internal sealed record FocusRecord(
    DateTimeOffset Timestamp,
    string Reason,
    string ForegroundWindow,
    string? ForegroundProcess,
    string? RuntimeId,
    string? ControlType,
    string? ClassName,
    string? AutomationId,
    bool? NamePresent,
    bool? IsKeyboardFocusable,
    bool? HasKeyboardFocus,
    bool? SupportsTextPattern,
    bool? SupportsTextPattern2,
    bool? SupportsValuePattern,
    bool? SupportsSelectionPattern,
    string? Error)
{
    public static FocusRecord Capture(string reason)
    {
        var foregroundWindow = NativeMethods.GetForegroundWindow();
        var foregroundProcess = NativeMethods.GetProcessName(foregroundWindow);
        var element = AutomationElement.FocusedElement;
        if (element is null)
        {
            return Empty(reason, foregroundWindow, foregroundProcess, "NoFocusedElement");
        }

        var current = element.Current;
        return new FocusRecord(
            DateTimeOffset.UtcNow,
            reason,
            NativeMethods.FormatHandle(foregroundWindow),
            foregroundProcess,
            FormatRuntimeId(element.GetRuntimeId()),
            current.ControlType.ProgrammaticName,
            current.ClassName,
            current.AutomationId,
            !string.IsNullOrEmpty(current.Name),
            current.IsKeyboardFocusable,
            current.HasKeyboardFocus,
            element.TryGetCurrentPattern(TextPattern.Pattern, out _),
            SupportsPattern(element, 10024),
            element.TryGetCurrentPattern(ValuePattern.Pattern, out _),
            element.TryGetCurrentPattern(SelectionPattern.Pattern, out _),
            null);
    }

    public static FocusRecord Failure(string reason, string error) =>
        Empty(reason, nint.Zero, null, error);

    private static FocusRecord Empty(
        string reason,
        nint foregroundWindow,
        string? foregroundProcess,
        string error) => new(
            DateTimeOffset.UtcNow,
            reason,
            NativeMethods.FormatHandle(foregroundWindow),
            foregroundProcess,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            error);

    private static string FormatRuntimeId(IEnumerable<int> runtimeId) =>
        string.Join(".", runtimeId);

    private static bool SupportsPattern(AutomationElement element, int patternId)
    {
        var pattern = AutomationPattern.LookupById(patternId);
        return pattern is not null && element.TryGetCurrentPattern(pattern, out _);
    }
}

internal static class NativeMethods
{
    [DllImport("user32.dll")]
    internal static extern nint GetForegroundWindow();

    [DllImport("user32.dll")]
    internal static extern uint GetWindowThreadProcessId(nint window, out uint processId);

    internal static string FormatHandle(nint handle) => $"0x{handle.ToInt64():X}";

    internal static string? GetProcessName(nint window)
    {
        if (window == nint.Zero)
        {
            return null;
        }

        GetWindowThreadProcessId(window, out var processId);
        if (processId == 0)
        {
            return null;
        }

        try
        {
            return Process.GetProcessById((int)processId).ProcessName;
        }
        catch (ArgumentException)
        {
            return null;
        }
    }
}
