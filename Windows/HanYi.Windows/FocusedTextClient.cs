using System.Runtime.InteropServices;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using HanYi.Core;
using System.Globalization;
using System.IO;

namespace HanYi.Windows;

internal sealed class FocusedTextClient
{
    private const ushort VirtualKeyA = 0x41;
    private const ushort VirtualKeyC = 0x43;
    private const ushort VirtualKeyV = 0x56;
    private const int ClipboardCopyAttempts = 20;
    private static readonly TimeSpan ClipboardCopyInterval = TimeSpan.FromMilliseconds(25);
    private const int CommitVerificationAttempts = 40;
    private static readonly TimeSpan CommitVerificationInterval = TimeSpan.FromMilliseconds(50);

    public async Task<TextSnapshot> CaptureAsync()
    {
        var foregroundWindow = NativeMethods.GetForegroundWindow();
        if (foregroundWindow == nint.Zero)
        {
            throw new FocusedTextException("没有找到当前输入窗口");
        }

        var element = AutomationElement.FocusedElement
            ?? throw new FocusedTextException("没有找到当前输入框");
        var runtimeId = element.GetRuntimeId();

        var supportsTextPattern = element.TryGetCurrentPattern(
            TextPattern.Pattern,
            out var textPatternObject);
        var supportsValuePattern = element.TryGetCurrentPattern(
            ValuePattern.Pattern,
            out var valuePatternObject);

        switch (FocusedTextReadModePolicy.Select(
            supportsTextPattern,
            supportsValuePattern))
        {
            case FocusedTextReadMode.TextPattern:
                return CaptureTextPattern(
                    foregroundWindow,
                    runtimeId,
                    (TextPattern)textPatternObject!);

            case FocusedTextReadMode.ValuePattern:
                var value = ((ValuePattern)valuePatternObject!).Current.Value;
                EnsureSource(value);
                return new TextSnapshot(
                    foregroundWindow,
                    runtimeId,
                    ReplacementScope.Full,
                    value,
                    null,
                    0,
                    FocusedTextReadMode.ValuePattern);

            case FocusedTextReadMode.ClipboardSelection:
                if (!FocusedTextReadModePolicy.SupportsClipboardSelectionFallback(
                    NativeMethods.GetProcessName(foregroundWindow)))
                {
                    throw new FocusedTextException("当前控件不支持读取文本");
                }
                return await CaptureClipboardSelectionAsync(foregroundWindow, runtimeId);

            default:
                throw new FocusedTextException("当前控件不支持读取文本");
        }
    }

    public async Task ReplaceAsync(TextSnapshot snapshot, string translatedText)
    {
        if (string.IsNullOrWhiteSpace(translatedText))
        {
            throw new FocusedTextException("翻译结果为空，未修改原文本");
        }
        await ValidateAsync(snapshot);

        var clipboard = ClipboardSnapshot.Capture();
        uint translationSequence = 0;
        try
        {
            ClipboardAccess.SetText(translatedText);
            translationSequence = NativeMethods.GetClipboardSequenceNumber();

            if (snapshot.Scope == ReplacementScope.Full)
            {
                NativeMethods.SendControlChord(VirtualKeyA);
            }
            NativeMethods.SendControlChord(VirtualKeyV);
            await VerifyCommittedAsync(snapshot, translatedText);
        }
        finally
        {
            if (translationSequence != 0
                && NativeMethods.GetClipboardSequenceNumber() == translationSequence)
            {
                await clipboard.RestoreAsync(translationSequence);
            }
        }
    }

    private static TextSnapshot CaptureTextPattern(
        nint foregroundWindow,
        int[] runtimeId,
        TextPattern textPattern)
    {
        var documentRange = textPattern.DocumentRange;
        var fullText = documentRange.GetText(-1);
        var selections = textPattern.GetSelection();
        if (selections.Length > 0 && !IsDegenerate(selections[0]))
        {
            var selectedText = selections[0].GetText(-1);
            EnsureSource(selectedText);
            var prefix = documentRange.Clone();
            prefix.MoveEndpointByRange(
                TextPatternRangeEndpoint.End,
                selections[0],
                TextPatternRangeEndpoint.Start);
            return new TextSnapshot(
                foregroundWindow,
                runtimeId,
                ReplacementScope.Selected,
                selectedText,
                fullText,
                prefix.GetText(-1).Length,
                FocusedTextReadMode.TextPattern);
        }

        EnsureSource(fullText);
        return new TextSnapshot(
            foregroundWindow,
            runtimeId,
            ReplacementScope.Full,
            fullText,
            null,
            0,
            FocusedTextReadMode.TextPattern);
    }

    private async Task<TextSnapshot> CaptureClipboardSelectionAsync(
        nint foregroundWindow,
        int[] runtimeId)
    {
        var clipboard = ClipboardSnapshot.Capture();
        var originalSequence = NativeMethods.GetClipboardSequenceNumber();
        uint copiedSequence = 0;
        try
        {
            NativeMethods.SendControlChord(VirtualKeyC);
            copiedSequence = await WaitForClipboardChangeAsync(originalSequence);
            if (copiedSequence == 0)
            {
                throw new FocusedTextException("当前控件不支持读取文本；请先选中要翻译的文本");
            }

            var selectedText = ClipboardAccess.GetUnicodeText();
            EnsureSource(selectedText);
            return new TextSnapshot(
                foregroundWindow,
                runtimeId,
                ReplacementScope.Selected,
                selectedText!,
                null,
                0,
                FocusedTextReadMode.ClipboardSelection);
        }
        finally
        {
            if (copiedSequence != 0
                && NativeMethods.GetClipboardSequenceNumber() == copiedSequence)
            {
                await clipboard.RestoreAsync(copiedSequence);
            }
        }
    }

    private static async Task<uint> WaitForClipboardChangeAsync(uint originalSequence)
    {
        for (var attempt = 0; attempt < ClipboardCopyAttempts; attempt++)
        {
            await Task.Delay(ClipboardCopyInterval);
            var currentSequence = NativeMethods.GetClipboardSequenceNumber();
            if (currentSequence != originalSequence)
            {
                return currentSequence;
            }
        }
        return 0;
    }

    private async Task ValidateAsync(TextSnapshot snapshot)
    {
        if (NativeMethods.GetForegroundWindow() != snapshot.ForegroundWindow)
        {
            throw new FocusedTextException("输入焦点已改变，已取消回写");
        }

        var current = await CaptureAsync();
        if (!snapshot.RuntimeId.SequenceEqual(current.RuntimeId)
            || snapshot.Scope != current.Scope
            || snapshot.ReadMode != current.ReadMode
            || snapshot.SelectionStart != current.SelectionStart
            || !string.Equals(snapshot.SourceText, current.SourceText, StringComparison.Ordinal))
        {
            throw new FocusedTextException("输入内容或选区已改变，已取消回写");
        }
    }

    private async Task VerifyCommittedAsync(
        TextSnapshot snapshot,
        string translatedText)
    {
        if (snapshot.ReadMode == FocusedTextReadMode.ClipboardSelection)
        {
            await VerifyClipboardSelectionCommitAsync(snapshot, translatedText);
            return;
        }

        var expected = snapshot.Scope == ReplacementScope.Full
            ? translatedText
            : BuildSelectedReplacement(snapshot, translatedText);

        for (var attempt = 0; attempt < CommitVerificationAttempts; attempt++)
        {
            if (NativeMethods.GetForegroundWindow() != snapshot.ForegroundWindow)
            {
                throw new FocusedTextException("写回后输入焦点已改变，请检查当前输入框");
            }

            try
            {
                var actual = ReadFocusedText();
                if (string.Equals(
                        NormalizeLineEndings(actual),
                        NormalizeLineEndings(expected),
                        StringComparison.Ordinal))
                {
                    return;
                }
            }
            catch (ElementNotAvailableException)
            {
                // Dynamic web editors can briefly replace the focused UIA element.
            }

            if (attempt < CommitVerificationAttempts - 1)
            {
                await Task.Delay(CommitVerificationInterval);
            }
        }

        throw new FocusedTextException("输入框未确认写入翻译结果，请检查目标应用是否允许粘贴");
    }

    private async Task VerifyClipboardSelectionCommitAsync(
        TextSnapshot snapshot,
        string translatedText)
    {
        if (NativeMethods.GetForegroundWindow() != snapshot.ForegroundWindow)
        {
            throw new FocusedTextException("写回后输入焦点已改变，请检查当前输入框");
        }

        await Task.Delay(CommitVerificationInterval);
        NativeMethods.SendShiftLeft(StringInfo.ParseCombiningCharacters(translatedText).Length);
        var current = await CaptureAsync();
        if (current.ReadMode != FocusedTextReadMode.ClipboardSelection
            || !string.Equals(current.SourceText, translatedText, StringComparison.Ordinal))
        {
            throw new FocusedTextException("输入框未确认写入翻译结果，请检查目标应用是否允许粘贴");
        }
    }

    private static string? ReadFocusedText()
    {
        var element = AutomationElement.FocusedElement;
        if (element is null)
        {
            return null;
        }
        if (element.TryGetCurrentPattern(TextPattern.Pattern, out var textPatternObject)
            && textPatternObject is TextPattern textPattern)
        {
            return textPattern.DocumentRange.GetText(-1);
        }
        if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var valuePatternObject)
            && valuePatternObject is ValuePattern valuePattern)
        {
            return valuePattern.Current.Value;
        }
        return null;
    }

    private static string BuildSelectedReplacement(
        TextSnapshot snapshot,
        string translatedText)
    {
        var context = snapshot.ContextText
            ?? throw new FocusedTextException("缺少选区上下文，已取消回写");
        if (snapshot.SelectionStart < 0
            || snapshot.SelectionStart + snapshot.SourceText.Length > context.Length)
        {
            throw new FocusedTextException("选区范围无效，已取消回写");
        }
        return context.Remove(snapshot.SelectionStart, snapshot.SourceText.Length)
            .Insert(snapshot.SelectionStart, translatedText);
    }

    private static string? NormalizeLineEndings(string? value) =>
        value?.Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n');

    private static bool IsDegenerate(TextPatternRange range) =>
        range.CompareEndpoints(
            TextPatternRangeEndpoint.Start,
            range,
            TextPatternRangeEndpoint.End) == 0;

    private static void EnsureSource(string? source)
    {
        if (string.IsNullOrWhiteSpace(source))
        {
            throw new FocusedTextException("当前输入框没有可翻译的文本");
        }
    }
}

internal enum ReplacementScope
{
    Selected,
    Full
}

internal sealed record TextSnapshot(
    nint ForegroundWindow,
    int[] RuntimeId,
    ReplacementScope Scope,
    string SourceText,
    string? ContextText,
    int SelectionStart,
    FocusedTextReadMode ReadMode);

internal sealed class FocusedTextException : Exception
{
    public FocusedTextException(string message) : base(message) { }
}

internal static class ClipboardAccess
{
    public static T Retry<T>(Func<T> action)
    {
        for (var attempt = 0; attempt < 6; attempt++)
        {
            try
            {
                return action();
            }
            catch (ExternalException) when (attempt < 5)
            {
                Thread.Sleep(30);
            }
        }
        throw new InvalidOperationException("剪贴板正被其他应用占用");
    }

    public static void Retry(Action action) => Retry(() =>
    {
        action();
        return true;
    });

    public static void SetText(string text) =>
        Retry(() => Clipboard.SetDataObject(text, false));

    public static string? GetUnicodeText() =>
        Retry(() => Clipboard.ContainsText(TextDataFormat.UnicodeText)
            ? Clipboard.GetText(TextDataFormat.UnicodeText)
            : null);
}

internal sealed class ClipboardSnapshot
{
    private readonly DataObject? _data;

    private ClipboardSnapshot(DataObject? data)
    {
        _data = data;
    }

    public static ClipboardSnapshot Capture()
    {
        return ClipboardAccess.Retry(() =>
        {
            var source = Clipboard.GetDataObject();
            if (source is null)
            {
                return new ClipboardSnapshot(null);
            }

            var copy = new DataObject();
            foreach (var format in source.GetFormats(false).Distinct())
            {
                var value = source.GetData(format, false);
                if (value is null)
                {
                    throw new FocusedTextException(
                        "无法完整保存当前剪贴板，未执行翻译");
                }
                copy.SetData(format, false, Materialize(value));
            }
            return new ClipboardSnapshot(copy);
        });
    }

    public async Task RestoreAsync(uint expectedSequence)
    {
        const int restoreAttempts = 100;
        for (var attempt = 0; attempt < restoreAttempts; attempt++)
        {
            if (NativeMethods.GetClipboardSequenceNumber() != expectedSequence)
            {
                return;
            }

            try
            {
                if (_data is null)
                {
                    Clipboard.Clear();
                }
                else
                {
                    Clipboard.SetDataObject(_data, true);
                }
                return;
            }
            catch (ExternalException)
            {
                if (attempt == restoreAttempts - 1)
                {
                    break;
                }
                await Task.Delay(50);
            }
        }

        throw new FocusedTextException("翻译已写入，但未能恢复剪贴板，请检查剪贴板占用程序");
    }

    private static object Materialize(object value)
    {
        return value switch
        {
            byte[] bytes => bytes.ToArray(),
            MemoryStream memory => new MemoryStream(memory.ToArray()),
            Stream stream => CopyStream(stream),
            System.Drawing.Image image => image.Clone(),
            string[] paths => paths.ToArray(),
            _ => value
        };
    }

    private static MemoryStream CopyStream(Stream source)
    {
        var originalPosition = source.CanSeek ? source.Position : 0;
        var target = new MemoryStream();
        source.CopyTo(target);
        target.Position = 0;
        if (source.CanSeek)
        {
            source.Position = originalPosition;
        }
        return target;
    }
}
