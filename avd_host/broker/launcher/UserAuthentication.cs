using Microsoft.Identity.Client;
using Microsoft.Identity.Client.Broker;

namespace LinuxBroker.Launcher;

internal enum ConnectionStage { SigningIn, CheckingOut, RefreshingSignIn, SavingCredential, OpeningRemoteDesktop }

internal interface IUserInteraction
{
    nint WindowHandle { get; }
    void Report(ConnectionStage stage);
    Task ExplainSignInAsync(CancellationToken cancellationToken);
}

internal interface IUserAuthenticator
{
    Task<UserAccessToken> AcquireAsync(bool forceRefresh, CancellationToken cancellationToken);
}

internal sealed class UserAccessToken(string value, Guid tenantId, string accountId)
{
    internal string Value { get; } = value;
    public Guid TenantId { get; } = tenantId;
    public string AccountId { get; } = accountId;
    public override string ToString() => "[user access token redacted]";
}

internal interface IMsalClient
{
    Task<AuthenticationResult> AcquireSilentAsync(string scope, IAccount account, bool forceRefresh, CancellationToken cancellationToken);
    Task<AuthenticationResult> AcquireInteractiveAsync(string scope, IAccount account, nint parentWindow, CancellationToken cancellationToken);
}

internal sealed class MsalClient : IMsalClient
{
    private readonly IPublicClientApplication application;

    public MsalClient(LauncherConfiguration configuration, Func<nint> parentWindow)
    {
        application = CreateApplication(configuration, parentWindow);
    }

    internal static IPublicClientApplication CreateApplication(LauncherConfiguration configuration, Func<nint> parentWindow) =>
        PublicClientApplicationBuilder.Create(configuration.ClientId.ToString("D"))
            .WithAuthority(configuration.Authority.AbsoluteUri, validateAuthority: true)
            .WithRedirectUri(configuration.RedirectUri)
            .WithParentActivityOrWindow(parentWindow)
            .WithBroker(new BrokerOptions(BrokerOptions.OperatingSystems.Windows)
            {
                Title = "Linux workspace",
                ListOperatingSystemAccounts = false
            })
            .Build();

    public Task<AuthenticationResult> AcquireSilentAsync(string scope, IAccount account, bool forceRefresh, CancellationToken cancellationToken) =>
        application.AcquireTokenSilent([scope], account)
            .WithForceRefresh(forceRefresh)
            .ExecuteAsync(cancellationToken);

    public Task<AuthenticationResult> AcquireInteractiveAsync(string scope, IAccount account, nint parentWindow, CancellationToken cancellationToken) =>
        application.AcquireTokenInteractive([scope])
            .WithAccount(account)
            .WithParentActivityOrWindow(parentWindow)
            .ExecuteAsync(cancellationToken);
}

internal sealed class WamUserAuthenticator(
    LauncherConfiguration configuration,
    IMsalClient client,
    IUserInteraction interaction,
    TimeProvider timeProvider) : IUserAuthenticator
{
    private IAccount? authenticatedAccount;

    public async Task<UserAccessToken> AcquireAsync(bool forceRefresh, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        // Never enumerate a shared/cache account list. Retry only the account authenticated by this launch.
        IAccount account = authenticatedAccount ?? PublicClientApplication.OperatingSystemAccount;
        try
        {
            AuthenticationResult result;
            try
            {
                result = await client.AcquireSilentAsync(configuration.Scope, account, forceRefresh, cancellationToken);
            }
            catch (MsalUiRequiredException)
            {
                if (interaction.WindowHandle == nint.Zero)
                {
                    throw new LauncherException(LauncherError.InteractiveSessionRequired);
                }

                await interaction.ExplainSignInAsync(cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();
                result = await client.AcquireInteractiveAsync(configuration.Scope, account, interaction.WindowHandle, cancellationToken);
            }

            cancellationToken.ThrowIfCancellationRequested();
            if (!Guid.TryParse(result.TenantId, out Guid tenantId) || tenantId != configuration.TenantId)
            {
                throw new LauncherException(LauncherError.WrongTenant);
            }

            if (result.Account?.HomeAccountId is null ||
                string.IsNullOrWhiteSpace(result.Account.HomeAccountId.Identifier) ||
                string.IsNullOrWhiteSpace(result.AccessToken) ||
                result.AccessToken.Any(character => char.IsWhiteSpace(character) || char.IsControl(character)) ||
                result.ExpiresOn <= timeProvider.GetUtcNow().AddMinutes(1) ||
                !string.Equals(result.TokenType, "Bearer", StringComparison.OrdinalIgnoreCase) ||
                !result.Scopes.Contains(configuration.Scope, StringComparer.OrdinalIgnoreCase))
            {
                throw new LauncherException(LauncherError.InvalidToken);
            }

            if (authenticatedAccount is not null &&
                !string.Equals(authenticatedAccount.HomeAccountId.Identifier, result.Account.HomeAccountId.Identifier, StringComparison.Ordinal))
            {
                throw new LauncherException(LauncherError.AccountChanged);
            }

            authenticatedAccount = result.Account;
            return new UserAccessToken(result.AccessToken, tenantId, result.Account.HomeAccountId.Identifier);
        }
        catch (MsalException exception) when (exception.ErrorCode is "authentication_canceled" or "user_canceled" or "user_cancelled")
        {
            throw new LauncherException(LauncherError.Cancelled);
        }
        catch (MsalException)
        {
            throw new LauncherException(LauncherError.Authentication);
        }
    }
}
