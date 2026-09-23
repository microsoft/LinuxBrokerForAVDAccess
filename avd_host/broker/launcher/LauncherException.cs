namespace LinuxBroker.Launcher;

internal enum LauncherError
{
    Configuration = 2,
    Authentication = 3,
    Cancelled = 4,
    Forbidden = 5,
    Unauthorized = 6,
    Conflict = 7,
    BrokerUnavailable = 8,
    InvalidResponse = 9,
    CredentialStorage = 10,
    RemoteDesktop = 11,
    Unexpected = 12,
    UnsupportedMode = 13,
    WrongTenant = 14,
    AccountChanged = 15,
    AlreadyRunning = 16,
    InvalidToken = 17,
    InteractiveSessionRequired = 18
}

// Only fixed, non-secret diagnostics cross the UI/console boundary.
internal sealed class LauncherException(LauncherError error) : Exception(MessageFor(error))
{
    public LauncherError Error { get; } = error;
    public int ExitCode => (int)Error;

    private static string MessageFor(LauncherError error) => error switch
    {
        LauncherError.Configuration =>
            "Launcher configuration or arguments are invalid. Ask your administrator to verify the installed launcher.json and shortcut.",
        LauncherError.Authentication =>
            "Microsoft sign-in could not complete. Check your connection, Windows work account, WAM registration, consent, and sign-in policy with your administrator. No alternate machine or operator identity will be used.",
        LauncherError.Cancelled =>
            "Connection cancelled. If a workspace request had already started, its outcome may be uncertain. Run the launcher again when you are ready; an existing RDP session is not closed.",
        LauncherError.Forbidden =>
            "Workspace access was denied (403). Your account needs the broker WorkspaceUser entitlement and the launcher connect_as_user permission. Portal administrator access alone is not enough. Contact your administrator.",
        LauncherError.Unauthorized =>
            "The broker rejected sign-in after one token refresh (401). Check the tenant, native client, API audience, and delegated permission with your administrator.",
        LauncherError.Conflict =>
            "No workspace can be checked out now (409): capacity may be unavailable or a lease operation may be in progress. No automatic retry was made. Wait before trying again, or contact your administrator.",
        LauncherError.BrokerUnavailable =>
            "The broker could not complete the request. Check the network or contact your administrator. The request was not automatically retried because a workspace or password change may already have occurred.",
        LauncherError.InvalidResponse =>
            "The broker returned an invalid or unsafe workspace response. No credentials were stored and Remote Desktop was not started. Contact your administrator.",
        LauncherError.CredentialStorage =>
            "Windows could not save the workspace credential in your sign-in session. Remote Desktop was not started. Check your Windows profile and credential-storage policy with your administrator.",
        LauncherError.RemoteDesktop =>
            "Remote Desktop could not be started. The workspace credential was stored only in your Windows sign-in session. Check that the Windows Remote Desktop client is available.",
        LauncherError.UnsupportedMode =>
            "Only desktop mode is supported. Xpra/application modes are not implemented; no sign-in or workspace request was made.",
        LauncherError.WrongTenant =>
            "Microsoft sign-in returned an account outside the configured tenant. No workspace request was made with that token. Use your organization's account or contact your administrator.",
        LauncherError.AccountChanged =>
            "The account changed during token refresh. The connection was stopped without retrying checkout for a different user. Start the launcher again to choose the intended account.",
        LauncherError.AlreadyRunning =>
            "A Linux workspace connection is already in progress in this Windows session. Finish or cancel that window before starting another.",
        LauncherError.InvalidToken =>
            "Microsoft sign-in did not return a current user token for the required broker permission. No workspace request was made with that token. Contact your administrator.",
        LauncherError.InteractiveSessionRequired =>
            "Run the launcher normally inside your own supported Windows AVD desktop. Services, SYSTEM, elevated sessions, and run-as/impersonation are not supported.",
        _ =>
            "The connection stopped because of an unexpected launcher error. No diagnostic secrets were logged. Contact your administrator."
    };
}

internal static class LauncherDiagnostics
{
    public static void WriteFailure(TextWriter writer, LauncherException exception) =>
        writer.WriteLine($"Linux workspace: {exception.Message} (status {exception.ExitCode})");
}
