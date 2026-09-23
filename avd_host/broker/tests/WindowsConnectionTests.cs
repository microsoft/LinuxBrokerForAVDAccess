using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace LinuxBroker.Launcher.Tests;

public sealed class WindowsConnectionTests
{
    [Fact]
    public void WinCred_writes_only_one_generic_TERMSRV_entry_for_the_current_logon_session()
    {
        RecordingCredentialApi native = new();
        using WorkspaceConnection connection = TestData.Connection();
        WindowsCredentialStore store = new(native);
        store.Save(connection);
        Assert.Equal(1, native.Calls);
        Assert.Equal("server_assigned", native.Credential.UserName);
        Assert.Equal("TERMSRV/10.2.3.4", native.Credential.TargetName);
        Assert.Equal(1u, native.Credential.Type);
        Assert.Equal(1u, native.Credential.Persist);
        Assert.Equal(0u, native.Credential.Flags);
        Assert.Equal(0u, native.Credential.AttributeCount);
        Assert.Equal(TestData.Password, native.Password);
        Assert.Equal((uint)(TestData.Password.Length * sizeof(char)), native.Credential.CredentialBlobSize);
        Assert.Equal("untouched-test-value", native.UnrelatedCredential);
    }

    [Fact]
    public void Native_credential_failure_is_not_reported_as_success()
    {
        using WorkspaceConnection connection = TestData.Connection();
        RecordingCredentialApi native = new() { Succeed = false };
        Assert.Equal(LauncherError.CredentialStorage,
            Assert.Throws<LauncherException>(() => new WindowsCredentialStore(native).Save(connection)).Error);
    }

    [Fact]
    public void Mstsc_is_a_trusted_system_binary_with_one_target_argument_and_no_secrets()
    {
        using WorkspaceConnection connection = TestData.Connection();
        RecordingProcess process = new();
        new RemoteDesktop(process).Start(connection.Target);
        ProcessStartInfo start = Assert.IsType<ProcessStartInfo>(process.StartInfo);
        Assert.Equal(Path.Combine(Environment.SystemDirectory, "mstsc.exe"), start.FileName);
        Assert.Equal(Environment.SystemDirectory, start.WorkingDirectory);
        Assert.False(start.UseShellExecute);
        Assert.Equal("/v:10.2.3.4", Assert.Single(start.ArgumentList));
        Assert.Equal(string.Empty, start.Arguments);
        string arguments = string.Join(" ", start.ArgumentList);
        Assert.DoesNotContain(TestData.Password, arguments);
        Assert.DoesNotContain(TestData.Token, arguments);
        Assert.DoesNotContain("server_assigned", arguments);
    }

    [Fact]
    public void Mstsc_failure_is_explicit_and_does_not_echo_an_exception_payload()
    {
        RecordingProcess process = new() { Fail = true };
        using WorkspaceConnection connection = TestData.Connection();
        LauncherException error = Assert.Throws<LauncherException>(() => new RemoteDesktop(process).Start(connection.Target));
        Assert.Equal(LauncherError.RemoteDesktop, error.Error);
        Assert.DoesNotContain(TestData.Password, error.ToString());
        Assert.Null(error.InnerException);
    }

    private sealed class RecordingCredentialApi : IWindowsCredentialApi
    {
        public int Calls { get; private set; }
        public bool Succeed { get; set; } = true;
        public NativeCredential Credential { get; private set; }
        public string? Password { get; private set; }
        public string UnrelatedCredential { get; } = "untouched-test-value";
        public bool Write(ref NativeCredential credential)
        {
            Calls++;
            Credential = credential;
            Password = Marshal.PtrToStringUni(credential.CredentialBlob, (int)credential.CredentialBlobSize / sizeof(char));
            return Succeed;
        }
    }

    private sealed class RecordingProcess : IProcessStarter
    {
        public ProcessStartInfo? StartInfo { get; private set; }
        public bool Fail { get; set; }
        public void Start(ProcessStartInfo startInfo)
        {
            if (Fail)
            {
                throw new Win32Exception(TestData.Password);
            }
            StartInfo = startInfo;
        }
    }
}
