using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace LinuxBroker.Launcher.Tests;

public sealed class BrokerTests
{
    [Fact]
    public async Task Checkout_sends_only_machine_audit_metadata_and_a_bearer_token_to_the_exact_API()
    {
        using FakeHttpHandler handler = new(async (request, _) =>
        {
            Assert.Equal(HttpMethod.Post, request.Method);
            Assert.Equal("https://broker.example.test/api/vms/checkout", request.RequestUri!.AbsoluteUri);
            Assert.Equal("Bearer", request.Headers.Authorization!.Scheme);
            Assert.Equal(TestData.Token, request.Headers.Authorization.Parameter);
            Assert.True(request.Headers.CacheControl!.NoStore);
            using JsonDocument body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync());
            JsonProperty field = Assert.Single(body.RootElement.EnumerateObject());
            Assert.Equal("avdhost", field.Name);
            Assert.Equal(Environment.MachineName, field.Value.GetString());
            return TestData.Response();
        });
        using HttpClient http = new(handler);
        using WorkspaceConnection connection = await new BrokerClient(TestData.Configuration(), http).CheckoutAsync(TestData.UserToken(), CancellationToken.None);
        Assert.Equal("server_assigned", connection.Username);
        Assert.Equal(1, handler.Calls);
        Assert.Null(http.DefaultRequestHeaders.Authorization);
    }

    [Fact]
    public void Transport_disallows_redirects_cookies_and_default_operator_credentials()
    {
        using SocketsHttpHandler handler = BrokerClient.CreateHttpHandler();
        Assert.False(handler.AllowAutoRedirect);
        Assert.False(handler.UseCookies);
        Assert.Null(handler.Credentials);
        Assert.Equal(System.Security.Cryptography.X509Certificates.X509RevocationMode.Online, handler.SslOptions.CertificateRevocationCheckMode);
    }

    [Theory]
    [InlineData(401, (int)LauncherError.Unauthorized)]
    [InlineData(403, (int)LauncherError.Forbidden)]
    [InlineData(409, (int)LauncherError.Conflict)]
    [InlineData(500, (int)LauncherError.BrokerUnavailable)]
    [InlineData(429, (int)LauncherError.BrokerUnavailable)]
    [InlineData(302, (int)LauncherError.BrokerUnavailable)]
    [InlineData(204, (int)LauncherError.BrokerUnavailable)]
    public async Task Http_errors_are_explicit_and_never_echo_secret_response_bodies(int status, int expected)
    {
        using FakeHttpHandler handler = new((_, _) => Task.FromResult(TestData.Response((HttpStatusCode)status, TestData.Token + TestData.Password)));
        using HttpClient http = new(handler);
        LauncherException error = await Assert.ThrowsAsync<LauncherException>(() =>
            new BrokerClient(TestData.Configuration(), http).CheckoutAsync(TestData.UserToken(), CancellationToken.None));
        Assert.Equal((LauncherError)expected, error.Error);
        Assert.DoesNotContain(TestData.Token, error.ToString());
        Assert.DoesNotContain(TestData.Password, error.ToString());
        Assert.Equal(1, handler.Calls);
    }

    [Theory]
    [InlineData(false, "application/json", TestData.ResponseJson)]
    [InlineData(true, "text/html", TestData.ResponseJson)]
    [InlineData(true, "application/json", "not-json")]
    public async Task Invalid_content_or_missing_no_store_does_not_reach_credentials(bool noStore, string mediaType, string body)
    {
        using FakeHttpHandler handler = new((_, _) =>
        {
            HttpResponseMessage response = TestData.Response(body: body);
            response.Headers.CacheControl = new CacheControlHeaderValue { NoStore = noStore };
            response.Content.Headers.ContentType = new MediaTypeHeaderValue(mediaType);
            return Task.FromResult(response);
        });
        using HttpClient http = new(handler);
        FakeCredentials credentials = new();
        FakeRemoteDesktop desktop = new();
        ConnectionLauncher launcher = new(new FakeAuthenticator(), new BrokerClient(TestData.Configuration(), http), credentials, desktop, new FakeInteraction());
        Assert.Equal(LauncherError.InvalidResponse,
            (await Assert.ThrowsAsync<LauncherException>(() => launcher.ConnectAsync("desktop", CancellationToken.None))).Error);
        Assert.Empty(credentials.Calls);
        Assert.Empty(desktop.Calls);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task Oversized_response_is_bounded_even_without_a_content_length(bool knownLength)
    {
        using FakeHttpHandler handler = new((_, _) =>
        {
            HttpResponseMessage response = TestData.Response();
            response.Content = new SizedContent(knownLength);
            return Task.FromResult(response);
        });
        using HttpClient http = new(handler);
        Assert.Equal(LauncherError.InvalidResponse,
            (await Assert.ThrowsAsync<LauncherException>(() =>
                new BrokerClient(TestData.Configuration(), http).CheckoutAsync(TestData.UserToken(), CancellationToken.None))).Error);
    }

    [Fact]
    public async Task Network_failure_does_not_echo_upstream_exception_or_retry()
    {
        using FakeHttpHandler handler = new((_, _) => Task.FromException<HttpResponseMessage>(new HttpRequestException(TestData.Password)));
        using HttpClient http = new(handler);
        LauncherException error = await Assert.ThrowsAsync<LauncherException>(() =>
            new BrokerClient(TestData.Configuration(), http).CheckoutAsync(TestData.UserToken(), CancellationToken.None));
        Assert.Equal(LauncherError.BrokerUnavailable, error.Error);
        Assert.DoesNotContain(TestData.Password, error.ToString());
        Assert.Null(error.InnerException);
        Assert.Equal(1, handler.Calls);
    }

    [Fact]
    public async Task Timeout_is_distinct_from_user_cancellation()
    {
        using FakeHttpHandler handler = new((_, _) => Task.FromException<HttpResponseMessage>(new TaskCanceledException()));
        using HttpClient http = new(handler);
        BrokerClient broker = new(TestData.Configuration(), http);
        Assert.Equal(LauncherError.BrokerUnavailable,
            (await Assert.ThrowsAsync<LauncherException>(() => broker.CheckoutAsync(TestData.UserToken(), CancellationToken.None))).Error);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => broker.CheckoutAsync(TestData.UserToken(), new CancellationToken(true)));
    }

    [Theory]
    [InlineData("VMID")]
    [InlineData("Hostname")]
    [InlineData("IPAddress")]
    [InlineData("Username")]
    [InlineData("LeaseId")]
    [InlineData("LeaseGeneration")]
    [InlineData("password")]
    public void Every_response_field_is_required(string field)
    {
        JsonObject response = JsonNode.Parse(TestData.ResponseJson)!.AsObject();
        response.Remove(field);
        AssertInvalid(response.ToJsonString());
    }

    [Theory]
    [InlineData("Hostname", "host /admin")]
    [InlineData("Hostname", "-bad-host")]
    [InlineData("Hostname", "host..example")]
    [InlineData("Hostname", "host\" & calc.exe")]
    [InlineData("IPAddress", "10.2.3.4 /admin")]
    [InlineData("IPAddress", "127.0.0.1")]
    [InlineData("IPAddress", "127.1")]
    [InlineData("IPAddress", "169.254.169.254")]
    [InlineData("IPAddress", "0.0.0.0")]
    [InlineData("IPAddress", "255.255.255.255")]
    [InlineData("IPAddress", "224.1.2.3")]
    [InlineData("IPAddress", "10.02.3.4")]
    [InlineData("IPAddress", "::")]
    [InlineData("IPAddress", "::1")]
    [InlineData("IPAddress", "fe80::1%3")]
    [InlineData("IPAddress", "ff02::1")]
    [InlineData("IPAddress", "::ffff:127.0.0.1")]
    [InlineData("Username", "other\\user")]
    [InlineData("Username", "claimed@tenant.example")]
    [InlineData("Username", "user /admin")]
    [InlineData("Username", "-user")]
    [InlineData("Username", "")]
    [InlineData("LeaseId", "not-a-uuid")]
    [InlineData("LeaseId", "00000000-0000-0000-0000-000000000000")]
    [InlineData("password", "")]
    [InlineData("password", "has\0nul")]
    [InlineData("password", "has\nnewline")]
    public void Invalid_targets_identity_and_password_are_rejected(string field, string value)
    {
        JsonNode response = JsonNode.Parse(TestData.ResponseJson)!;
        response[field] = value;
        AssertInvalid(response.ToJsonString());
    }

    [Theory]
    [InlineData("VMID", "0")]
    [InlineData("VMID", "-1")]
    [InlineData("VMID", "2147483648")]
    [InlineData("VMID", "1.5")]
    [InlineData("VMID", "\"42\"")]
    [InlineData("LeaseGeneration", "0")]
    [InlineData("LeaseGeneration", "-1")]
    [InlineData("LeaseGeneration", "9007199254740992")]
    [InlineData("LeaseGeneration", "9007199254740993")]
    [InlineData("LeaseGeneration", "9223372036854775807")]
    [InlineData("LeaseGeneration", "9223372036854775808")]
    [InlineData("LeaseGeneration", "1.5")]
    [InlineData("LeaseGeneration", "\"9223372036854775807\"")]
    [InlineData("password", "null")]
    [InlineData("Username", "false")]
    public void Exact_integer_and_string_types_are_enforced(string field, string value)
    {
        JsonNode response = JsonNode.Parse(TestData.ResponseJson)!;
        response[field] = JsonNode.Parse(value);
        AssertInvalid(response.ToJsonString());
    }

    [Theory]
    [InlineData(1L)]
    [InlineData(7L)]
    [InlineData(2147483647L)]
    [InlineData(2147483648L)]
    [InlineData(9007199254740990L)]
    [InlineData(9007199254740991L)]
    public void Lease_generation_uses_long_storage_within_the_shared_safe_JSON_range(long generation)
    {
        JsonNode response = JsonNode.Parse(TestData.ResponseJson)!;
        response["LeaseGeneration"] = generation;
        using WorkspaceConnection connection = WorkspaceConnection.Parse(Encoding.UTF8.GetBytes(response.ToJsonString()));
        Assert.Equal(generation, connection.LeaseGeneration);
    }

    [Theory]
    [InlineData(9007199254740992L)]
    [InlineData(9007199254740993L)]
    [InlineData(long.MaxValue)]
    public async Task Unsafe_JSON_generation_is_rejected_before_credentials_or_RDP_without_retry(long generation)
    {
        JsonNode response = JsonNode.Parse(TestData.ResponseJson)!;
        response["LeaseGeneration"] = generation;
        using FakeHttpHandler handler = new((_, _) => Task.FromResult(TestData.Response(body: response.ToJsonString())));
        using HttpClient http = new(handler);
        FakeAuthenticator auth = new();
        FakeCredentials credentials = new();
        FakeRemoteDesktop desktop = new();
        ConnectionLauncher launcher = new(auth, new BrokerClient(TestData.Configuration(), http),
            credentials, desktop, new FakeInteraction());

        LauncherException error = await Assert.ThrowsAsync<LauncherException>(() =>
            launcher.ConnectAsync("desktop", CancellationToken.None));

        Assert.Equal(LauncherError.InvalidResponse, error.Error);
        Assert.Equal([false], auth.Calls);
        Assert.Equal(1, handler.Calls);
        Assert.Empty(credentials.Calls);
        Assert.Empty(desktop.Calls);
    }

    [Fact]
    public void VMID_retains_the_positive_Int32_range()
    {
        JsonNode response = JsonNode.Parse(TestData.ResponseJson)!;
        response["VMID"] = int.MaxValue;
        using WorkspaceConnection connection = WorkspaceConnection.Parse(Encoding.UTF8.GetBytes(response.ToJsonString()));
        Assert.Equal(int.MaxValue, connection.VmId);
    }

    [Fact]
    public void Duplicate_extra_trailing_and_oversized_password_fields_are_rejected()
    {
        AssertInvalid(TestData.ResponseJson.Replace("{", """{"VMID":99,"""));
        AssertInvalid(TestData.ResponseJson.Replace("{", """{"unknown":"value","""));
        AssertInvalid(TestData.ResponseJson + "{}");
        AssertInvalid(TestData.ResponseJson[..^1]);
        JsonNode response = JsonNode.Parse(TestData.ResponseJson)!;
        response["password"] = new string('a', 1281);
        AssertInvalid(response.ToJsonString());
    }

    [Theory]
    [InlineData("server_assigned", "\\uD800")]
    [InlineData(TestData.Password, "\\uD800")]
    [InlineData("Hostname", "\\uD800")]
    public void Invalid_unicode_is_reported_as_a_malformed_response(string original, string invalid)
    {
        AssertInvalid(TestData.ResponseJson.Replace(original, invalid));
    }

    [Fact]
    public void Invalid_utf8_is_reported_as_a_malformed_response()
    {
        byte[] bytes = Encoding.UTF8.GetBytes(TestData.ResponseJson);
        int index = Encoding.UTF8.GetString(bytes).IndexOf("server_assigned", StringComparison.Ordinal);
        bytes[index] = 0xFF;
        Assert.Equal(LauncherError.InvalidResponse,
            Assert.Throws<LauncherException>(() => WorkspaceConnection.Parse(bytes)).Error);
    }

    [Fact]
    public void Escaped_password_is_decoded_without_creating_a_secret_string_in_the_parser()
    {
        string json = TestData.ResponseJson.Replace(TestData.Password, @"with\u0022quote\\backslash");
        using WorkspaceConnection connection = WorkspaceConnection.Parse(Encoding.UTF8.GetBytes(json));
        Assert.Equal("with\"quote\\backslash",
            new string(connection.Password.Characters, 0, connection.Password.Length));
    }

    [Theory]
    [InlineData("2001:db8:0:0:0:0:0:42")]
    [InlineData("2001:0DB8:0000:0000:0000:0000:0000:0042")]
    [InlineData("2001:DB8::42")]
    [InlineData("2001:db8::0042")]
    public void Alternate_IPv6_spellings_normalize_to_the_same_RDP_and_WinCred_target(string address)
    {
        using WorkspaceConnection connection = WorkspaceConnection.Parse(Encoding.UTF8.GetBytes(
            TestData.ResponseJson.Replace("10.2.3.4", address)));
        Assert.Equal("[2001:db8::42]", connection.Target.Server);
        Assert.Equal("TERMSRV/[2001:db8::42]", connection.Target.CredentialName);
    }

    [Fact]
    public void Password_is_not_a_serializable_record_and_is_zeroed_on_dispose()
    {
        using WorkspaceConnection connection = TestData.Connection();
        Assert.DoesNotContain(TestData.Password, connection.ToString());
        Assert.DoesNotContain(TestData.Password, connection.Password.ToString());
        Assert.Equal(TestData.Password, new string(connection.Password.Characters, 0, connection.Password.Length));
        connection.Dispose();
        Assert.All(connection.Password.Characters, character => Assert.Equal('\0', character));
    }

    private static void AssertInvalid(string json) =>
        Assert.Equal(LauncherError.InvalidResponse,
            Assert.Throws<LauncherException>(() => WorkspaceConnection.Parse(Encoding.UTF8.GetBytes(json))).Error);

    private sealed class SizedContent : HttpContent
    {
        private readonly bool knownLength;
        private readonly byte[] bytes = new byte[BrokerClient.MaximumResponseBytes + 1];
        public SizedContent(bool knownLength)
        {
            this.knownLength = knownLength;
            Headers.ContentType = new MediaTypeHeaderValue("application/json");
        }

        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) => stream.WriteAsync(bytes).AsTask();
        protected override bool TryComputeLength(out long length)
        {
            length = bytes.Length;
            return knownLength;
        }
    }
}
