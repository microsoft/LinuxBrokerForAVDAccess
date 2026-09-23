namespace LinuxBroker.Launcher;

internal sealed class ConnectionLauncher(
    IUserAuthenticator authenticator,
    IWorkspaceBroker broker,
    ICredentialStore credentials,
    IRemoteDesktop remoteDesktop,
    IUserInteraction interaction)
{
    public async Task ConnectAsync(string mode, CancellationToken cancellationToken)
    {
        LauncherArguments.ValidateMode(mode);
        cancellationToken.ThrowIfCancellationRequested();
        interaction.Report(ConnectionStage.SigningIn);
        UserAccessToken token = await authenticator.AcquireAsync(false, cancellationToken);
        WorkspaceConnection connection;
        try
        {
            interaction.Report(ConnectionStage.CheckingOut);
            connection = await broker.CheckoutAsync(token, cancellationToken);
        }
        catch (LauncherException exception) when (exception.Error == LauncherError.Unauthorized)
        {
            interaction.Report(ConnectionStage.RefreshingSignIn);
            UserAccessToken refreshed = await authenticator.AcquireAsync(true, cancellationToken);
            if (refreshed.TenantId != token.TenantId || refreshed.AccountId != token.AccountId)
            {
                throw new LauncherException(LauncherError.AccountChanged);
            }

            interaction.Report(ConnectionStage.CheckingOut);
            connection = await broker.CheckoutAsync(refreshed, cancellationToken);
        }

        using (connection)
        {
            cancellationToken.ThrowIfCancellationRequested();
            interaction.Report(ConnectionStage.SavingCredential);
            credentials.Save(connection);
            cancellationToken.ThrowIfCancellationRequested();
            interaction.Report(ConnectionStage.OpeningRemoteDesktop);
            remoteDesktop.Start(connection.Target);
        }
    }
}
