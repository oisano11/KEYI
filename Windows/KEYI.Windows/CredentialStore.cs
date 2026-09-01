using System.Runtime.InteropServices;
using System.Text;
using KEYI.Core;

namespace KEYI.Windows;

internal sealed class CredentialStore
{
    private const uint CredTypeGeneric = 1;
    private const uint CredPersistLocalMachine = 2;

    public string? Read(ProviderId providerId)
    {
        if (!CredRead(Target(providerId), CredTypeGeneric, 0, out var pointer))
        {
            var error = Marshal.GetLastWin32Error();
            if (error == 1168)
            {
                return null;
            }
            throw new InvalidOperationException(UiStrings.Current.CredentialReadFailed(error));
        }

        try
        {
            var credential = Marshal.PtrToStructure<Credential>(pointer);
            if (credential.CredentialBlob == nint.Zero
                || credential.CredentialBlobSize == 0)
            {
                return null;
            }
            var bytes = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
            return Encoding.Unicode.GetString(bytes).TrimEnd('\0');
        }
        finally
        {
            CredFree(pointer);
        }
    }

    public bool HasSecret(ProviderId providerId)
    {
        try
        {
            return !string.IsNullOrWhiteSpace(Read(providerId));
        }
        catch
        {
            return false;
        }
    }

    public void Save(ProviderId providerId, string secret)
    {
        var normalized = secret.Trim();
        if (normalized.Length == 0)
        {
            throw new InvalidOperationException(UiStrings.Current.MissingApiKey);
        }

        var bytes = Encoding.Unicode.GetBytes(normalized);
        var blob = Marshal.AllocCoTaskMem(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var credential = new Credential
            {
                Type = CredTypeGeneric,
                TargetName = Target(providerId),
                CredentialBlobSize = (uint)bytes.Length,
                CredentialBlob = blob,
                Persist = CredPersistLocalMachine,
                UserName = Environment.UserName
            };
            if (!CredWrite(ref credential, 0))
            {
                throw new InvalidOperationException(
                    UiStrings.Current.CredentialWriteFailed(Marshal.GetLastWin32Error()));
            }
        }
        finally
        {
            Marshal.Copy(new byte[bytes.Length], 0, blob, bytes.Length);
            Array.Clear(bytes);
            Marshal.FreeCoTaskMem(blob);
        }
    }

    private static string Target(ProviderId providerId) => $"KEYI/{providerId}";

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredRead(
        string target,
        uint type,
        uint flags,
        out nint credential);

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredWrite(ref Credential credential, uint flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(nint buffer);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential
    {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string? Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public nint CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public nint Attributes;
        public string? TargetAlias;
        public string UserName;
    }
}
