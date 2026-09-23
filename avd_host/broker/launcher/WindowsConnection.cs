using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace LinuxBroker.Launcher;

internal interface ICredentialStore
{
    void Save(WorkspaceConnection connection);
}

internal interface IRemoteDesktop
{
    void Start(RdpTarget target);
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
internal struct NativeCredential
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

internal interface IWindowsCredentialApi
{
    bool Write(ref NativeCredential credential);
}

internal sealed class WindowsCredentialApi : IWindowsCredentialApi
{
    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredWrite(ref NativeCredential credential, uint flags);

    public bool Write(ref NativeCredential credential) => CredWrite(ref credential, 0);
}

internal sealed class WindowsCredentialStore(IWindowsCredentialApi native) : ICredentialStore
{
    public void Save(WorkspaceConnection connection)
    {
        PasswordBuffer password = connection.Password;
        nint blob = Marshal.AllocCoTaskMem(checked((password.Length + 1) * sizeof(char)));
        try
        {
            Marshal.Copy(password.Characters, 0, blob, password.Length);
            Marshal.WriteInt16(blob, password.Length * sizeof(char), 0);
            NativeCredential credential = new()
            {
                Type = 1, // CRED_TYPE_GENERIC, as consumed by mstsc's TERMSRV target.
                TargetName = connection.Target.CredentialName,
                UserName = connection.Username,
                CredentialBlob = blob,
                CredentialBlobSize = checked((uint)(password.Length * sizeof(char))),
                Persist = 1 // CRED_PERSIST_SESSION: this user/logon session only, not roaming.
            };
            if (!native.Write(ref credential))
            {
                throw new LauncherException(LauncherError.CredentialStorage);
            }
        }
        finally
        {
            Marshal.ZeroFreeCoTaskMemUnicode(blob);
        }
    }
}

internal interface IProcessStarter
{
    void Start(ProcessStartInfo startInfo);
}

internal sealed class ProcessStarter : IProcessStarter
{
    public void Start(ProcessStartInfo startInfo)
    {
        using Process? process = Process.Start(startInfo);
        if (process is null)
        {
            throw new LauncherException(LauncherError.RemoteDesktop);
        }
    }
}

internal sealed class RemoteDesktop(IProcessStarter processStarter) : IRemoteDesktop
{
    internal static ProcessStartInfo CreateStartInfo(RdpTarget target)
    {
        ProcessStartInfo startInfo = new()
        {
            FileName = Path.Combine(Environment.SystemDirectory, "mstsc.exe"),
            WorkingDirectory = Environment.SystemDirectory,
            UseShellExecute = false
        };
        startInfo.ArgumentList.Add($"/v:{target.Server}");
        return startInfo;
    }

    public void Start(RdpTarget target)
    {
        try
        {
            processStarter.Start(CreateStartInfo(target));
        }
        catch (Exception exception) when (exception is Win32Exception or InvalidOperationException or IOException)
        {
            throw new LauncherException(LauncherError.RemoteDesktop);
        }
    }
}
