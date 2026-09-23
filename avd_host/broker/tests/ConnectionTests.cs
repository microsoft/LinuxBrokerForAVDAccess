namespace LinuxBroker.Launcher.Tests;

public sealed class ConnectionTests
{
    [Fact]
    public async Task Successful_connection_saves_only_the_returned_user_and_target_then_erases_the_password_buffer()
    {
        FakeAuthenticator auth = new();
        FakeBroker broker = new();
        FakeCredentials credentials = new();
        FakeRemoteDesktop desktop = new();
        FakeInteraction ui = new();
        ConnectionLauncher launcher = new(auth, broker, credentials, desktop, ui);
        await launcher.ConnectAsync("desktop", CancellationToken.None);
        Assert.Equal([false], auth.Calls);
        Assert.Single(broker.Calls);
        Assert.Equal(("TERMSRV/10.2.3.4", "server_assigned"), Assert.Single(credentials.Calls));
        Assert.Equal("10.2.3.4", Assert.Single(desktop.Calls).Server);
        Assert.All(credentials.Password!.Characters, character => Assert.Equal('\0', character));
        Assert.Equal([ConnectionStage.SigningIn, ConnectionStage.CheckingOut, ConnectionStage.SavingCredential, ConnectionStage.OpeningRemoteDesktop], ui.Stages);
    }

    [Theory]
    [InlineData("xpra")]
    [InlineData("xterm")]
    [InlineData("")]
    public async Task Unsupported_modes_do_not_authenticate_allocate_or_store_credentials(string mode)
    {
        FakeAuthenticator auth = new();
        FakeBroker broker = new();
        FakeCredentials credentials = new();
        FakeRemoteDesktop desktop = new();
        ConnectionLauncher launcher = new(auth, broker, credentials, desktop, new FakeInteraction());
        Assert.Equal(LauncherError.UnsupportedMode,
            (await Assert.ThrowsAsync<LauncherException>(() => launcher.ConnectAsync(mode, CancellationToken.None))).Error);
        Assert.Empty(auth.Calls);
        Assert.Empty(broker.Calls);
        Assert.Empty(credentials.Calls);
        Assert.Empty(desktop.Calls);
    }

    [Fact]
    public async Task A_401_allows_one_refresh_and_one_same_user_retry()
    {
        FakeAuthenticator auth = new() { Result = refresh => Task.FromResult(TestData.UserToken(refresh ? "fresh-test-token" : TestData.Token)) };
        FakeBroker broker = new();
        broker.Failures.Enqueue(LauncherError.Unauthorized);
        FakeRemoteDesktop desktop = new();
        ConnectionLauncher launcher = new(auth, broker, new FakeCredentials(), desktop, new FakeInteraction());
        await launcher.ConnectAsync("desktop", CancellationToken.None);
        Assert.Equal([false, true], auth.Calls);
        Assert.Equal(2, broker.Calls.Count);
        Assert.Equal("fresh-test-token", broker.Calls[1].Value);
        Assert.Single(desktop.Calls);
    }

    [Fact]
    public async Task A_second_401_stops_without_an_authentication_loop()
    {
        FakeAuthenticator auth = new();
        FakeBroker broker = new();
        broker.Failures.Enqueue(LauncherError.Unauthorized);
        broker.Failures.Enqueue(LauncherError.Unauthorized);
        FakeCredentials credentials = new();
        ConnectionLauncher launcher = new(auth, broker, credentials, new FakeRemoteDesktop(), new FakeInteraction());
        Assert.Equal(LauncherError.Unauthorized,
            (await Assert.ThrowsAsync<LauncherException>(() => launcher.ConnectAsync("desktop", CancellationToken.None))).Error);
        Assert.Equal([false, true], auth.Calls);
        Assert.Equal(2, broker.Calls.Count);
        Assert.Empty(credentials.Calls);
    }

    [Theory]
    [InlineData((int)LauncherError.Forbidden)]
    [InlineData((int)LauncherError.Conflict)]
    [InlineData((int)LauncherError.BrokerUnavailable)]
    [InlineData((int)LauncherError.InvalidResponse)]
    public async Task Denial_capacity_transport_and_response_errors_are_not_retried(int failureCode)
    {
        LauncherError failure = (LauncherError)failureCode;
        FakeAuthenticator auth = new();
        FakeBroker broker = new();
        broker.Failures.Enqueue(failure);
        FakeCredentials credentials = new();
        FakeRemoteDesktop desktop = new();
        ConnectionLauncher launcher = new(auth, broker, credentials, desktop, new FakeInteraction());
        Assert.Equal(failure,
            (await Assert.ThrowsAsync<LauncherException>(() => launcher.ConnectAsync("desktop", CancellationToken.None))).Error);
        Assert.Equal([false], auth.Calls);
        Assert.Single(broker.Calls);
        Assert.Empty(credentials.Calls);
        Assert.Empty(desktop.Calls);
    }

    [Fact]
    public async Task Changed_identity_during_refresh_is_not_sent_to_the_broker()
    {
        FakeAuthenticator auth = new() { Result = refresh => Task.FromResult(TestData.UserToken(accountId: refresh ? "different-account" : TestData.AccountIdentifier)) };
        FakeBroker broker = new();
        broker.Failures.Enqueue(LauncherError.Unauthorized);
        ConnectionLauncher launcher = new(auth, broker, new FakeCredentials(), new FakeRemoteDesktop(), new FakeInteraction());
        Assert.Equal(LauncherError.AccountChanged,
            (await Assert.ThrowsAsync<LauncherException>(() => launcher.ConnectAsync("desktop", CancellationToken.None))).Error);
        Assert.Single(broker.Calls);
    }

    [Fact]
    public async Task Cancellation_before_authentication_never_checks_out()
    {
        FakeAuthenticator auth = new();
        FakeBroker broker = new();
        ConnectionLauncher launcher = new(auth, broker, new FakeCredentials(), new FakeRemoteDesktop(), new FakeInteraction());
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => launcher.ConnectAsync("desktop", new CancellationToken(true)));
        Assert.Empty(auth.Calls);
        Assert.Empty(broker.Calls);
    }

    [Fact]
    public async Task Credential_failure_does_not_start_mstsc_and_still_clears_memory()
    {
        FakeCredentials credentials = new() { Fail = true };
        FakeRemoteDesktop desktop = new();
        ConnectionLauncher launcher = new(new FakeAuthenticator(), new FakeBroker(), credentials, desktop, new FakeInteraction());
        Assert.Equal(LauncherError.CredentialStorage,
            (await Assert.ThrowsAsync<LauncherException>(() => launcher.ConnectAsync("desktop", CancellationToken.None))).Error);
        Assert.Empty(desktop.Calls);
        Assert.All(credentials.Password!.Characters, character => Assert.Equal('\0', character));
    }
}
