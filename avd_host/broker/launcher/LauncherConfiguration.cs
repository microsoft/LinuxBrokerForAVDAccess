using System.Text.Json;

namespace LinuxBroker.Launcher;

internal sealed class LauncherConfiguration
{
    private LauncherConfiguration(Guid tenantId, Uri authorityHost, Guid clientId, Guid apiClientId, Uri apiBaseUrl)
    {
        TenantId = tenantId;
        ClientId = clientId;
        ApiClientId = apiClientId;
        Authority = new Uri(authorityHost, tenantId.ToString("D"));
        ApiBaseUrl = apiBaseUrl;
    }

    public Guid TenantId { get; }
    public Guid ClientId { get; }
    public Guid ApiClientId { get; }
    public Uri Authority { get; }
    public Uri ApiBaseUrl { get; }
    public string Scope => $"api://{ApiClientId:D}/connect_as_user";
    public string RedirectUri => $"ms-appx-web://microsoft.aad.brokerplugin/{ClientId:D}";
    public Uri CheckoutUri => new($"{ApiBaseUrl.AbsoluteUri}/vms/checkout");

    public static LauncherConfiguration Load(string path)
    {
        if (!IsLocalAbsolutePath(path))
        {
            throw new LauncherException(LauncherError.Configuration);
        }

        try
        {
            using FileStream file = new(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (file.Length is <= 0 or > 16384)
            {
                throw new LauncherException(LauncherError.Configuration);
            }

            using StreamReader reader = new(file);
            return Parse(reader.ReadToEnd());
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            throw new LauncherException(LauncherError.Configuration);
        }
    }

    public static LauncherConfiguration Parse(string json)
    {
        try
        {
            using JsonDocument document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 4 });
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                throw new LauncherException(LauncherError.Configuration);
            }

            Dictionary<string, string> values = new(StringComparer.Ordinal);
            foreach (JsonProperty property in document.RootElement.EnumerateObject())
            {
                if (property.Value.ValueKind != JsonValueKind.String ||
                    !values.TryAdd(property.Name, property.Value.GetString()!) ||
                    string.IsNullOrWhiteSpace(values[property.Name]))
                {
                    throw new LauncherException(LauncherError.Configuration);
                }
            }

            string[] keys = ["tenantId", "authorityHost", "clientId", "apiClientId", "apiBaseUrl"];
            if (values.Count != keys.Length || keys.Any(key => !values.ContainsKey(key)))
            {
                throw new LauncherException(LauncherError.Configuration);
            }

            Guid tenantId = ParseId(values["tenantId"]);
            Guid clientId = ParseId(values["clientId"]);
            Guid apiClientId = ParseId(values["apiClientId"]);
            Uri authority = ParseHttpsUri(values["authorityHost"]);
            Uri api = ParseHttpsUri(values["apiBaseUrl"]);
            if (clientId == apiClientId ||
                !IsAuthorityRoot(authority) ||
                !values["apiBaseUrl"].EndsWith("/api", StringComparison.Ordinal) ||
                !api.AbsolutePath.EndsWith("/api", StringComparison.Ordinal) ||
                api.IsLoopback)
            {
                throw new LauncherException(LauncherError.Configuration);
            }

            return new LauncherConfiguration(tenantId, authority, clientId, apiClientId, api);
        }
        catch (JsonException)
        {
            throw new LauncherException(LauncherError.Configuration);
        }
    }

    internal static bool IsLocalAbsolutePath(string path) =>
        !string.IsNullOrWhiteSpace(path) &&
        path.Length >= 3 && char.IsAsciiLetter(path[0]) && path[1] == ':' && path[2] == '\\' &&
        Path.IsPathFullyQualified(path) &&
        !path.Any(character => char.IsControl(character) || character == '"');

    private static Guid ParseId(string value)
    {
        if (!Guid.TryParseExact(value, "D", out Guid id) || id == Guid.Empty)
        {
            throw new LauncherException(LauncherError.Configuration);
        }

        return id;
    }

    private static bool IsAuthorityRoot(Uri authority)
    {
        string hostname = authority.IdnHost.TrimEnd('.');
        if (authority.HostNameType != UriHostNameType.Dns ||
            Uri.CheckHostName(hostname) != UriHostNameType.Dns ||
            authority.IsLoopback ||
            hostname.Equals("localhost", StringComparison.OrdinalIgnoreCase) ||
            hostname.EndsWith(".localhost", StringComparison.OrdinalIgnoreCase) ||
            !authority.IsDefaultPort || authority.AbsolutePath != "/" ||
            authority.OriginalString.Contains('@'))
        {
            return false;
        }

        // Uri normalizes dot segments; only an absent path or one literal root slash is allowed.
        int pathStart = authority.OriginalString.IndexOf('/', Uri.UriSchemeHttps.Length + Uri.SchemeDelimiter.Length);
        return pathStart < 0 || pathStart == authority.OriginalString.Length - 1;
    }

    private static Uri ParseHttpsUri(string value)
    {
        if (value.Any(character => char.IsWhiteSpace(character) || char.IsControl(character) || character == '\\') ||
            !Uri.TryCreate(value, UriKind.Absolute, out Uri? uri) ||
            uri.Scheme != Uri.UriSchemeHttps ||
            !string.IsNullOrEmpty(uri.UserInfo) ||
            value.Contains('?') || value.Contains('#') ||
            uri.HostNameType == UriHostNameType.Unknown)
        {
            throw new LauncherException(LauncherError.Configuration);
        }

        return uri;
    }
}

internal sealed record LauncherArguments(string ConfigPath, string Mode)
{
    public static LauncherArguments Parse(string[] arguments)
    {
        if (arguments.Length != 4)
        {
            throw new LauncherException(LauncherError.Configuration);
        }

        Dictionary<string, string> values = new(StringComparer.Ordinal);
        for (int index = 0; index < arguments.Length; index += 2)
        {
            if (arguments[index] is not ("--config" or "--mode") ||
                !values.TryAdd(arguments[index], arguments[index + 1]))
            {
                throw new LauncherException(LauncherError.Configuration);
            }
        }

        if (!values.TryGetValue("--mode", out string? mode) ||
            !values.TryGetValue("--config", out string? path))
        {
            throw new LauncherException(LauncherError.Configuration);
        }

        ValidateMode(mode);
        if (!LauncherConfiguration.IsLocalAbsolutePath(path))
        {
            throw new LauncherException(LauncherError.Configuration);
        }

        return new LauncherArguments(path, "desktop");
    }

    public static void ValidateMode(string mode)
    {
        if (!string.Equals(mode, "desktop", StringComparison.OrdinalIgnoreCase))
        {
            throw new LauncherException(LauncherError.UnsupportedMode);
        }
    }
}
