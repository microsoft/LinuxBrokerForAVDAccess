using System.Net;
using System.Net.Http.Headers;
using System.Text;
using Microsoft.Identity.Client;

namespace LinuxBroker.Launcher.Tests;

internal static class TestData
{
    public const string Tenant = "11111111-1111-4111-8111-111111111111";
    public const string Client = "22222222-2222-4222-8222-222222222222";
    public const string Api = "33333333-3333-4333-8333-333333333333";
    public const string AccountIdentifier = "44444444-4444-4444-8444-444444444444." + Tenant;
    public const string Token = "TEST_TOKEN_DO_NOT_LOG";
    public const string Password = "TEST_PASSWORD_DO_NOT_LOG!42";
    public const string ConfigJson = """
        {
          "tenantId": "11111111-1111-4111-8111-111111111111",
          "authorityHost": "https://login.microsoftonline.com",
          "clientId": "22222222-2222-4222-8222-222222222222",
          "apiClientId": "33333333-3333-4333-8333-333333333333",
          "apiBaseUrl": "https://broker.example.test/api"
        }
        """;
    public const string ResponseJson = """
        {
          "VMID": 42,
          "Hostname": "linux-42.internal.example",
          "IPAddress": "10.2.3.4",
          "Username": "server_assigned",
          "LeaseId": "55555555-5555-4555-8555-555555555555",
          "LeaseGeneration": 7,
          "password": "TEST_PASSWORD_DO_NOT_LOG!42"
        }
        """;

    public static LauncherConfiguration Configuration() => LauncherConfiguration.Parse(ConfigJson);
    public static WorkspaceConnection Connection() => WorkspaceConnection.Parse(Encoding.UTF8.GetBytes(ResponseJson));
    public static UserAccessToken UserToken(string token = Token, string accountId = AccountIdentifier) => new(token, Guid.Parse(Tenant), accountId);

    public static AuthenticationResult Authentication(
        string tenant = Tenant,
        string token = Token,
        string scope = "api://" + Api + "/connect_as_user",
        string accountId = AccountIdentifier,
        DateTimeOffset? expires = null) =>
        new(token, false, "44444444-4444-4444-8444-444444444444",
            expires ?? DateTimeOffset.UtcNow.AddHours(1), DateTimeOffset.UtcNow.AddHours(1),
            tenant, new TestAccount(accountId), "unused-test-id-token", [scope], Guid.NewGuid());

    public static HttpResponseMessage Response(HttpStatusCode status = HttpStatusCode.OK, string body = ResponseJson)
    {
        HttpResponseMessage response = new(status)
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json")
        };
        response.Headers.CacheControl = new CacheControlHeaderValue { NoStore = true };
        return response;
    }
}

internal sealed class TestAccount(string identifier) : IAccount
{
    public string Username => "not_the_linux_user@example.test";
    public string Environment => "login.microsoftonline.com";
    public AccountId HomeAccountId { get; } = new(identifier, "44444444-4444-4444-8444-444444444444", TestData.Tenant);
}

internal sealed class FakeInteraction : IUserInteraction
{
    public nint WindowHandle { get; set; } = new(123);
    public List<ConnectionStage> Stages { get; } = [];
    public int ExplanationCount { get; private set; }
    public bool CancelSignIn { get; set; }
    public void Report(ConnectionStage stage) => Stages.Add(stage);
    public Task ExplainSignInAsync(CancellationToken cancellationToken)
    {
        ExplanationCount++;
        return CancelSignIn
            ? Task.FromException(new LauncherException(LauncherError.Cancelled))
            : Task.CompletedTask;
    }
}

internal sealed class FakeMsalClient : IMsalClient
{
    public List<(string Scope, IAccount Account, bool ForceRefresh)> SilentCalls { get; } = [];
    public List<(string Scope, IAccount Account, nint Parent)> InteractiveCalls { get; } = [];
    public Func<Task<AuthenticationResult>> SilentResult { get; set; } = () => Task.FromResult(TestData.Authentication());
    public Func<Task<AuthenticationResult>> InteractiveResult { get; set; } = () => Task.FromResult(TestData.Authentication());
    public Task<AuthenticationResult> AcquireSilentAsync(string scope, IAccount account, bool forceRefresh, CancellationToken cancellationToken)
    {
        SilentCalls.Add((scope, account, forceRefresh));
        return SilentResult();
    }

    public Task<AuthenticationResult> AcquireInteractiveAsync(string scope, IAccount account, nint parentWindow, CancellationToken cancellationToken)
    {
        InteractiveCalls.Add((scope, account, parentWindow));
        return InteractiveResult();
    }
}

internal sealed class FakeAuthenticator : IUserAuthenticator
{
    public List<bool> Calls { get; } = [];
    public Func<bool, Task<UserAccessToken>> Result { get; set; } = _ => Task.FromResult(TestData.UserToken());
    public Task<UserAccessToken> AcquireAsync(bool forceRefresh, CancellationToken cancellationToken)
    {
        Calls.Add(forceRefresh);
        return Result(forceRefresh);
    }
}

internal sealed class FakeBroker : IWorkspaceBroker
{
    public List<UserAccessToken> Calls { get; } = [];
    public Queue<LauncherError> Failures { get; } = new();
    public Task<WorkspaceConnection> CheckoutAsync(UserAccessToken token, CancellationToken cancellationToken)
    {
        Calls.Add(token);
        return Failures.TryDequeue(out LauncherError failure)
            ? Task.FromException<WorkspaceConnection>(new LauncherException(failure))
            : Task.FromResult(TestData.Connection());
    }
}

internal sealed class FakeCredentials : ICredentialStore
{
    public List<(string Target, string Username)> Calls { get; } = [];
    public PasswordBuffer? Password { get; private set; }
    public bool Fail { get; set; }
    public void Save(WorkspaceConnection connection)
    {
        Calls.Add((connection.Target.CredentialName, connection.Username));
        Password = connection.Password;
        if (Fail)
        {
            throw new LauncherException(LauncherError.CredentialStorage);
        }
    }
}

internal sealed class FakeRemoteDesktop : IRemoteDesktop
{
    public List<RdpTarget> Calls { get; } = [];
    public void Start(RdpTarget target) => Calls.Add(target);
}

internal sealed class FakeHttpHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
{
    public int Calls { get; private set; }
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Calls++;
        return send(request, cancellationToken);
    }
}
