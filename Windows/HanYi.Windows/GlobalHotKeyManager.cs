using HanYi.Core;

namespace HanYi.Windows;

internal sealed class GlobalHotKeyManager : NativeWindow, IDisposable
{
    private int _nextId = 1;
    private int? _currentId;

    public event EventHandler? Pressed;

    public GlobalHotKeyManager()
    {
        CreateHandle(new CreateParams());
    }

    public bool TryReplace(HotKeySettings settings)
    {
        var candidateId = _nextId++;
        var modifiers = (uint)settings.Modifiers | NativeMethods.ModNoRepeat;
        if (!NativeMethods.RegisterHotKey(
                Handle,
                candidateId,
                modifiers,
                (uint)settings.VirtualKey))
        {
            return false;
        }

        if (_currentId is int previousId)
        {
            NativeMethods.UnregisterHotKey(Handle, previousId);
        }
        _currentId = candidateId;
        return true;
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == NativeMethods.WmHotKey
            && _currentId is int currentId
            && message.WParam.ToInt32() == currentId)
        {
            Pressed?.Invoke(this, EventArgs.Empty);
        }
        base.WndProc(ref message);
    }

    public void Dispose()
    {
        if (_currentId is int currentId)
        {
            NativeMethods.UnregisterHotKey(Handle, currentId);
            _currentId = null;
        }
        DestroyHandle();
    }
}
