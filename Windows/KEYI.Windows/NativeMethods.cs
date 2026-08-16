using System.Diagnostics;
using System.Runtime.InteropServices;

namespace KEYI.Windows;

internal static class NativeMethods
{
    internal const int WmHotKey = 0x0312;
    internal const uint ModNoRepeat = 0x4000;
    private const uint InputKeyboard = 1;
    private const uint KeyEventKeyUp = 0x0002;

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool RegisterHotKey(
        nint window,
        int id,
        uint modifiers,
        uint virtualKey);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool UnregisterHotKey(nint window, int id);

    [DllImport("user32.dll")]
    internal static extern nint GetForegroundWindow();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetForegroundWindow(nint window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool IsWindow(nint window);

    [DllImport("user32.dll")]
    internal static extern uint GetWindowThreadProcessId(nint window, out uint processId);

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

    [DllImport("user32.dll")]
    internal static extern uint GetClipboardSequenceNumber();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(
        uint inputCount,
        Input[] inputs,
        int inputSize);

    internal static void SendControlChord(ushort virtualKey)
    {
        const ushort control = 0x11;
        var inputs = new[]
        {
            CreateKeyboardInput(control, false),
            CreateKeyboardInput(virtualKey, false),
            CreateKeyboardInput(virtualKey, true),
            CreateKeyboardInput(control, true)
        };
        var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>());
        if (sent != inputs.Length)
        {
            throw new InvalidOperationException("无法向当前输入框发送粘贴命令");
        }
    }

    internal static void SendShiftLeft(int count)
    {
        if (count <= 0)
        {
            return;
        }

        const ushort shift = 0x10;
        const ushort left = 0x25;
        var inputs = new List<Input>(2 + count * 2)
        {
            CreateKeyboardInput(shift, false)
        };
        for (var index = 0; index < count; index++)
        {
            inputs.Add(CreateKeyboardInput(left, false));
            inputs.Add(CreateKeyboardInput(left, true));
        }
        inputs.Add(CreateKeyboardInput(shift, true));

        var sent = SendInput((uint)inputs.Count, inputs.ToArray(), Marshal.SizeOf<Input>());
        if (sent != inputs.Count)
        {
            throw new InvalidOperationException("无法向当前输入框发送写回验证命令");
        }
    }

    private static Input CreateKeyboardInput(ushort virtualKey, bool keyUp) => new()
    {
        Type = InputKeyboard,
        Union = new InputUnion
        {
            Keyboard = new KeyboardInput
            {
                VirtualKey = virtualKey,
                Flags = keyUp ? KeyEventKeyUp : 0
            }
        }
    };

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type;
        public InputUnion Union;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MouseInput Mouse;
        [FieldOffset(0)] public KeyboardInput Keyboard;
        [FieldOffset(0)] public HardwareInput Hardware;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int X;
        public int Y;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public nuint ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public nuint ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HardwareInput
    {
        public uint Message;
        public ushort ParameterLow;
        public ushort ParameterHigh;
    }
}
