using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;

namespace LinuxBroker.Launcher;

internal interface IWorkspaceBroker
{
    Task<WorkspaceConnection> CheckoutAsync(UserAccessToken token, CancellationToken cancellationToken);
}

internal sealed class BrokerClient(LauncherConfiguration configuration, HttpClient httpClient) : IWorkspaceBroker
{
    internal const int MaximumResponseBytes = 32768;

    internal static SocketsHttpHandler CreateHttpHandler() => new()
    {
        AllowAutoRedirect = false,
        UseCookies = false,
        Credentials = null,
        ConnectTimeout = TimeSpan.FromSeconds(15),
        MaxResponseHeadersLength = 16,
        SslOptions = new() { CertificateRevocationCheckMode = System.Security.Cryptography.X509Certificates.X509RevocationMode.Online }
    };

    internal static HttpClient CreateHttpClient() => new(CreateHttpHandler())
    {
        Timeout = Timeout.InfiniteTimeSpan
    };

    public async Task<WorkspaceConnection> CheckoutAsync(UserAccessToken token, CancellationToken cancellationToken)
    {
        using CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromMinutes(2));
        try
        {
            using HttpRequestMessage request = new(HttpMethod.Post, configuration.CheckoutUri);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Value);
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            request.Headers.CacheControl = new CacheControlHeaderValue { NoStore = true, NoCache = true };
            request.Content = JsonContent.Create(new { avdhost = Environment.MachineName });
            using HttpResponseMessage response = await httpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);

            if (response.StatusCode != HttpStatusCode.OK)
            {
                // Error bodies can contain credentials or upstream diagnostics. Do not read or display them.
                throw new LauncherException(response.StatusCode switch
                {
                    HttpStatusCode.Unauthorized => LauncherError.Unauthorized,
                    HttpStatusCode.Forbidden => LauncherError.Forbidden,
                    HttpStatusCode.Conflict => LauncherError.Conflict,
                    _ => LauncherError.BrokerUnavailable
                });
            }

            if (!string.Equals(response.Content.Headers.ContentType?.MediaType, "application/json", StringComparison.OrdinalIgnoreCase) ||
                response.Content.Headers.ContentLength > MaximumResponseBytes ||
                response.Headers.CacheControl?.NoStore != true)
            {
                throw new LauncherException(LauncherError.InvalidResponse);
            }

            byte[] buffer = new byte[MaximumResponseBytes + 1];
            try
            {
                await using Stream body = await response.Content.ReadAsStreamAsync(timeout.Token);
                int length = 0;
                while (length < buffer.Length)
                {
                    int count = await body.ReadAsync(buffer.AsMemory(length), timeout.Token);
                    if (count == 0)
                    {
                        return WorkspaceConnection.Parse(buffer.AsSpan(0, length));
                    }
                    length += count;
                }

                throw new LauncherException(LauncherError.InvalidResponse);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(buffer);
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new LauncherException(LauncherError.BrokerUnavailable);
        }
        catch (Exception exception) when (exception is HttpRequestException or IOException)
        {
            throw new LauncherException(LauncherError.BrokerUnavailable);
        }
    }
}
