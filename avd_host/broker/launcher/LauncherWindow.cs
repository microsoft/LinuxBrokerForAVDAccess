namespace LinuxBroker.Launcher;

internal sealed class LauncherWindow : Form, IUserInteraction
{
    private readonly Label status;
    private readonly Button closeButton;
    private readonly CancellationTokenSource cancellation = new();
    private readonly LauncherConfiguration configuration;
    private bool completed;

    public LauncherWindow(LauncherConfiguration configuration)
    {
        this.configuration = configuration;
        Text = "Linux workspace";
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(600, 310);
        MinimumSize = new Size(540, 340);
        MaximizeBox = false;

        TableLayoutPanel layout = new() { Dock = DockStyle.Fill, Padding = new Padding(24), RowCount = 3, ColumnCount = 1 };
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        Label heading = new() { Text = "Connect to your Linux workspace", AutoSize = true, Margin = new Padding(0, 0, 0, 14) };
        status = new Label { Dock = DockStyle.Fill, AutoSize = true, MaximumSize = new Size(850, 0), AccessibleName = "Connection status" };
        closeButton = new Button { Text = "Cancel", AutoSize = true, Anchor = AnchorStyles.Right, Margin = new Padding(0, 14, 0, 0) };
        closeButton.Click += (_, _) => Close();
        layout.Controls.Add(heading);
        layout.Controls.Add(status);
        layout.Controls.Add(closeButton);
        Controls.Add(layout);
        CancelButton = closeButton;
    }

    public int ExitCode { get; private set; } = (int)LauncherError.Cancelled;
    public nint WindowHandle => Visible && IsHandleCreated ? Handle : nint.Zero;

    protected override async void OnShown(EventArgs e)
    {
        base.OnShown(e);
        try
        {
            using HttpClient http = BrokerClient.CreateHttpClient();
            WamUserAuthenticator authenticator = new(configuration, new MsalClient(configuration, () => WindowHandle), this, TimeProvider.System);
            ConnectionLauncher launcher = new(authenticator, new BrokerClient(configuration, http),
                new WindowsCredentialStore(new WindowsCredentialApi()), new RemoteDesktop(new ProcessStarter()), this);
            await launcher.ConnectAsync("desktop", cancellation.Token);
            completed = true;
            ExitCode = 0;
            Close();
        }
        catch (LauncherException exception)
        {
            ShowFailure(exception);
        }
        catch (OperationCanceledException)
        {
            ShowFailure(new LauncherException(LauncherError.Cancelled));
        }
        catch (Exception)
        {
            // Final UI boundary: never render exception messages/stacks that may contain upstream secrets.
            ShowFailure(new LauncherException(LauncherError.Unexpected));
        }
    }

    public void Report(ConnectionStage stage)
    {
        status.Text = stage switch
        {
            ConnectionStage.SigningIn => "Checking your Windows work account. Microsoft sign-in will open only if your organization needs more information.",
            ConnectionStage.CheckingOut => "Requesting your own workspace from the broker. Please wait; this can take up to two minutes.",
            ConnectionStage.RefreshingSignIn => "The broker needs a fresh sign-in token. Refreshing the same account once.",
            ConnectionStage.SavingCredential => "Saving the workspace credential in your Windows sign-in session.",
            _ => "Opening Remote Desktop. Your Entra token's expiry will not close an established RDP session."
        };
    }

    public Task ExplainSignInAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Activate();
        status.Text = "Microsoft sign-in is required to verify that this is your workspace.";
        DialogResult result = MessageBox.Show(this,
            "Windows could not sign you in silently. Your organization may require sign-in, consent, or multifactor authentication.\n\nContinue to Microsoft sign-in for your own Linux workspace. Cancelling will stop this connection. Linux itself still uses the broker's local account, not an Entra/domain login.",
            "Microsoft sign-in required", MessageBoxButtons.OKCancel, MessageBoxIcon.Information, MessageBoxDefaultButton.Button1);
        if (result != DialogResult.OK)
        {
            throw new LauncherException(LauncherError.Cancelled);
        }

        cancellationToken.ThrowIfCancellationRequested();
        return Task.CompletedTask;
    }

    private void ShowFailure(LauncherException exception)
    {
        completed = true;
        ExitCode = exception.ExitCode;
        status.Text = $"{exception.Message}\n\nLauncher status: {exception.ExitCode}.";
        LauncherDiagnostics.WriteFailure(Console.Error, exception);
        closeButton.Text = "Close";
        closeButton.Enabled = true;
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!completed)
        {
            e.Cancel = true;
            cancellation.Cancel();
            status.Text = "Cancelling the connection. A request already sent to the broker may still complete.";
            closeButton.Enabled = false;
        }
        base.OnFormClosing(e);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            cancellation.Dispose();
        }
        base.Dispose(disposing);
    }
}
