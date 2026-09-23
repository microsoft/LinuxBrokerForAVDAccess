using Microsoft.Identity.Client;
using System.Text.Json;

namespace LinuxBroker.Launcher.Tests;

public sealed class AuthenticationTests
{
    [Fact]
    public async Task First_silent_request_uses_the_OS_account_without_cache_enumeration()
    {
        FakeMsalClient client = new();
        FakeInteraction ui = new();
        WamUserAuthenticator auth = new(TestData.Configuration(), client, ui, TimeProvider.System);
        UserAccessToken token = await auth.AcquireAsync(false, CancellationToken.None);
        var request = Assert.Single(client.SilentCalls);
        Assert.Same(PublicClientApplication.OperatingSystemAccount, request.Account);
        Assert.Equal(TestData.Configuration().Scope, request.Scope);
        Assert.False(request.ForceRefresh);
        Assert.Empty(client.InteractiveCalls);
        Assert.Equal(0, ui.ExplanationCount);
        Assert.Equal(TestData.Token, token.Value);
        Assert.DoesNotContain(TestData.Token, token.ToString());
        Assert.DoesNotContain(TestData.Token, JsonSerializer.Serialize(token));
    }

    [Fact]
    public async Task Interaction_required_explains_prompt_and_uses_a_visible_parent()
    {
        FakeMsalClient client = new()
        {
            SilentResult = () => Task.FromException<AuthenticationResult>(new MsalUiRequiredException("interaction_required", TestData.Token))
        };
        FakeInteraction ui = new();
        WamUserAuthenticator auth = new(TestData.Configuration(), client, ui, TimeProvider.System);
        await auth.AcquireAsync(false, CancellationToken.None);
        var interactive = Assert.Single(client.InteractiveCalls);
        Assert.Same(PublicClientApplication.OperatingSystemAccount, interactive.Account);
        Assert.Equal(ui.WindowHandle, interactive.Parent);
        Assert.Equal(TestData.Configuration().Scope, interactive.Scope);
        Assert.Equal(1, ui.ExplanationCount);
    }

    [Fact]
    public async Task Missing_parent_does_not_open_an_unowned_sign_in()
    {
        FakeMsalClient client = new()
        {
            SilentResult = () => Task.FromException<AuthenticationResult>(new MsalUiRequiredException("interaction_required", "test"))
        };
        FakeInteraction ui = new() { WindowHandle = nint.Zero };
        WamUserAuthenticator auth = new(TestData.Configuration(), client, ui, TimeProvider.System);
        Assert.Equal(LauncherError.InteractiveSessionRequired,
            (await Assert.ThrowsAsync<LauncherException>(() => auth.AcquireAsync(false, CancellationToken.None))).Error);
        Assert.Empty(client.InteractiveCalls);
    }

    [Fact]
    public async Task An_unrelated_silent_failure_never_triggers_interactive_or_machine_fallback()
    {
        FakeMsalClient client = new()
        {
            SilentResult = () => Task.FromException<AuthenticationResult>(new MsalClientException("network_failure", TestData.Token))
        };
        FakeInteraction ui = new();
        WamUserAuthenticator auth = new(TestData.Configuration(), client, ui, TimeProvider.System);
        LauncherException error = await Assert.ThrowsAsync<LauncherException>(() => auth.AcquireAsync(false, CancellationToken.None));
        Assert.Equal(LauncherError.Authentication, error.Error);
        Assert.DoesNotContain(TestData.Token, error.ToString());
        Assert.Null(error.InnerException);
        Assert.Empty(client.InteractiveCalls);
        Assert.Equal(0, ui.ExplanationCount);
        using StringWriter diagnostics = new();
        LauncherDiagnostics.WriteFailure(diagnostics, error);
        Assert.Contains("Microsoft sign-in could not complete", diagnostics.ToString());
        Assert.DoesNotContain(TestData.Token, diagnostics.ToString());
        Assert.DoesNotContain(TestData.Password, diagnostics.ToString());
    }

    [Fact]
    public async Task Unsupported_custom_authority_fails_authentication_without_checkout_or_fallback()
    {
        LauncherConfiguration configuration = LauncherConfiguration.Parse(
            TestData.ConfigJson.Replace("login.microsoftonline.com", "login.custom.example"));
        FakeMsalClient client = new()
        {
            SilentResult = () => Task.FromException<AuthenticationResult>(
                new MsalServiceException("invalid_instance", TestData.Token))
        };
        FakeInteraction ui = new();
        FakeBroker broker = new();
        FakeCredentials credentials = new();
        FakeRemoteDesktop desktop = new();
        ConnectionLauncher launcher = new(new WamUserAuthenticator(configuration, client, ui, TimeProvider.System),
            broker, credentials, desktop, ui);

        LauncherException error = await Assert.ThrowsAsync<LauncherException>(() =>
            launcher.ConnectAsync("desktop", CancellationToken.None));

        Assert.Equal(LauncherError.Authentication, error.Error);
        Assert.DoesNotContain(TestData.Token, error.ToString());
        Assert.Single(client.SilentCalls);
        Assert.Empty(client.InteractiveCalls);
        Assert.Equal(0, ui.ExplanationCount);
        Assert.Empty(broker.Calls);
        Assert.Empty(credentials.Calls);
        Assert.Empty(desktop.Calls);
    }

    [Fact]
    public async Task Declining_the_explanation_stops_before_interactive_and_checkout()
    {
        FakeMsalClient client = new()
        {
            SilentResult = () => Task.FromException<AuthenticationResult>(new MsalUiRequiredException("interaction_required", "test"))
        };
        FakeInteraction ui = new() { CancelSignIn = true };
        WamUserAuthenticator auth = new(TestData.Configuration(), client, ui, TimeProvider.System);
        FakeBroker broker = new();
        FakeCredentials credentials = new();
        FakeRemoteDesktop desktop = new();
        ConnectionLauncher launcher = new(auth, broker, credentials, desktop, ui);
        Assert.Equal(LauncherError.Cancelled,
            (await Assert.ThrowsAsync<LauncherException>(() => launcher.ConnectAsync("desktop", CancellationToken.None))).Error);
        Assert.Empty(client.InteractiveCalls);
        Assert.Empty(broker.Calls);
        Assert.Empty(credentials.Calls);
        Assert.Empty(desktop.Calls);
    }

    [Fact]
    public async Task Wam_cancellation_stops_before_checkout()
    {
        FakeMsalClient client = new()
        {
            SilentResult = () => Task.FromException<AuthenticationResult>(new MsalUiRequiredException("interaction_required", "test")),
            InteractiveResult = () => Task.FromException<AuthenticationResult>(new MsalClientException("authentication_canceled", TestData.Token))
        };
        FakeInteraction ui = new();
        WamUserAuthenticator auth = new(TestData.Configuration(), client, ui, TimeProvider.System);
        FakeBroker broker = new();
        ConnectionLauncher launcher = new(auth, broker, new FakeCredentials(), new FakeRemoteDesktop(), ui);
        LauncherException error = await Assert.ThrowsAsync<LauncherException>(() => launcher.ConnectAsync("desktop", CancellationToken.None));
        Assert.Equal(LauncherError.Cancelled, error.Error);
        Assert.DoesNotContain(TestData.Token, error.ToString());
        Assert.Empty(broker.Calls);
    }

    [Fact]
    public async Task Wrong_tenant_is_rejected_without_checkout_or_another_prompt()
    {
        FakeMsalClient client = new()
        {
            SilentResult = () => Task.FromResult(TestData.Authentication(tenant: "99999999-9999-4999-8999-999999999999"))
        };
        FakeInteraction ui = new();
        FakeBroker broker = new();
        ConnectionLauncher launcher = new(new WamUserAuthenticator(TestData.Configuration(), client, ui, TimeProvider.System),
            broker, new FakeCredentials(), new FakeRemoteDesktop(), ui);
        Assert.Equal(LauncherError.WrongTenant,
            (await Assert.ThrowsAsync<LauncherException>(() => launcher.ConnectAsync("desktop", CancellationToken.None))).Error);
        Assert.Empty(broker.Calls);
        Assert.Empty(client.InteractiveCalls);
    }

    [Theory]
    [InlineData("")]
    [InlineData("bad\r\ntoken")]
    [InlineData("bad token")]
    public async Task Invalid_bearer_content_is_rejected(string token)
    {
        await AssertInvalidResult(TestData.Authentication(token: token));
    }

    [Fact]
    public async Task Missing_connect_scope_or_nearly_expired_token_is_rejected()
    {
        await AssertInvalidResult(TestData.Authentication(scope: $"api://{TestData.Api}/access_as_user"));
        await AssertInvalidResult(TestData.Authentication(expires: DateTimeOffset.UtcNow.AddSeconds(10)));
    }

    [Fact]
    public async Task Refresh_uses_the_previously_authenticated_account_not_another_cached_or_OS_account()
    {
        FakeMsalClient client = new();
        WamUserAuthenticator auth = new(TestData.Configuration(), client, new FakeInteraction(), TimeProvider.System);
        await auth.AcquireAsync(false, CancellationToken.None);
        await auth.AcquireAsync(true, CancellationToken.None);
        Assert.Equal(2, client.SilentCalls.Count);
        Assert.NotSame(PublicClientApplication.OperatingSystemAccount, client.SilentCalls[1].Account);
        Assert.Equal(TestData.AccountIdentifier, client.SilentCalls[1].Account.HomeAccountId.Identifier);
        Assert.True(client.SilentCalls[1].ForceRefresh);
    }

    [Fact]
    public async Task A_different_account_after_refresh_is_not_accepted()
    {
        FakeMsalClient client = new();
        WamUserAuthenticator auth = new(TestData.Configuration(), client, new FakeInteraction(), TimeProvider.System);
        await auth.AcquireAsync(false, CancellationToken.None);
        client.SilentResult = () => Task.FromResult(TestData.Authentication(accountId: "other-account"));
        Assert.Equal(LauncherError.AccountChanged,
            (await Assert.ThrowsAsync<LauncherException>(() => auth.AcquireAsync(true, CancellationToken.None))).Error);
    }

    private static async Task AssertInvalidResult(AuthenticationResult result)
    {
        FakeMsalClient client = new() { SilentResult = () => Task.FromResult(result) };
        WamUserAuthenticator auth = new(TestData.Configuration(), client, new FakeInteraction(), TimeProvider.System);
        Assert.Equal(LauncherError.InvalidToken,
            (await Assert.ThrowsAsync<LauncherException>(() => auth.AcquireAsync(false, CancellationToken.None))).Error);
        Assert.Empty(client.InteractiveCalls);
    }
}
