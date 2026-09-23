using System.Diagnostics;
using System.Security.Principal;

namespace LinuxBroker.Launcher;

internal static class Program
{
    [STAThread]
    private static int Main(string[] arguments)
    {
        try
        {
            LauncherArguments options = LauncherArguments.Parse(arguments);
            using WindowsIdentity identity = WindowsIdentity.GetCurrent();
            if (!Environment.UserInteractive ||
                !OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041) ||
                Process.GetCurrentProcess().SessionId == 0 ||
                identity.IsSystem ||
                identity.ImpersonationLevel is TokenImpersonationLevel.Impersonation or TokenImpersonationLevel.Delegation ||
                new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))
            {
                throw new LauncherException(LauncherError.InteractiveSessionRequired);
            }

            LauncherConfiguration configuration = LauncherConfiguration.Load(options.ConfigPath);
            using Mutex mutex = new(true, $"Local\\LinuxBroker.Launcher.{identity.User?.Value}", out bool created);
            if (!created)
            {
                throw new LauncherException(LauncherError.AlreadyRunning);
            }

            Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            using LauncherWindow window = new(configuration);
            Application.Run(window);
            return window.ExitCode;
        }
        catch (LauncherException exception)
        {
            return ReportFailure(exception);
        }
        catch (Exception)
        {
            return ReportFailure(new LauncherException(LauncherError.Unexpected));
        }
    }

    private static int ReportFailure(LauncherException exception)
    {
        LauncherDiagnostics.WriteFailure(Console.Error, exception);
        if (Environment.UserInteractive)
        {
            MessageBox.Show(exception.Message, "Linux workspace", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        return exception.ExitCode;
    }
}
