using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace LinuxBroker.Launcher;

internal sealed class PasswordBuffer(char[] characters, int length) : IDisposable
{
    internal char[] Characters { get; } = characters;
    public int Length { get; } = length;
    public void Dispose() => Array.Clear(Characters);
    public override string ToString() => "[workspace password redacted]";
}

internal sealed record RdpTarget(string Server, string CredentialName)
{
    internal static RdpTarget Validate(string hostname, string addressText)
    {
        if (hostname.Length is < 1 or > 253 ||
            hostname.Split('.').Any(label => label.Length is < 1 or > 63 ||
                !char.IsAsciiLetterOrDigit(label[0]) || !char.IsAsciiLetterOrDigit(label[^1]) ||
                label.Any(character => !char.IsAsciiLetterOrDigit(character) && character != '-')) ||
            addressText.Contains('%') || addressText.Contains('[') || addressText.Contains(']') ||
            !IPAddress.TryParse(addressText, out IPAddress? address) ||
            IPAddress.IsLoopback(address) || address.Equals(IPAddress.Any) || address.Equals(IPAddress.IPv6Any) ||
            address.IsIPv4MappedToIPv6 || address.IsIPv6LinkLocal || address.IsIPv6Multicast || address.IsIPv6SiteLocal)
        {
            throw new LauncherException(LauncherError.InvalidResponse);
        }

        string server = address.ToString();
        if (address.AddressFamily == AddressFamily.InterNetwork)
        {
            byte[] octets = address.GetAddressBytes();
            if (server != addressText || octets[0] is 0 or >= 224 ||
                (octets[0] == 169 && octets[1] == 254))
            {
                throw new LauncherException(LauncherError.InvalidResponse);
            }
        }
        else if (address.AddressFamily == AddressFamily.InterNetworkV6)
        {
            server = $"[{server}]";
        }
        else
        {
            throw new LauncherException(LauncherError.InvalidResponse);
        }

        return new RdpTarget(server, $"TERMSRV/{server}");
    }
}

internal sealed partial class WorkspaceConnection : IDisposable
{
    // Shared JSON number bound for JavaScript/jq consumers, not the Int64 storage limit.
    private const long MaximumLeaseGeneration = 9_007_199_254_740_991;

    private WorkspaceConnection(int vmId, string hostname, string username, Guid leaseId, long generation, RdpTarget target, PasswordBuffer password)
    {
        VmId = vmId;
        Hostname = hostname;
        Username = username;
        LeaseId = leaseId;
        LeaseGeneration = generation;
        Target = target;
        Password = password;
    }

    public int VmId { get; }
    public string Hostname { get; }
    public string Username { get; }
    public Guid LeaseId { get; }
    public long LeaseGeneration { get; }
    public RdpTarget Target { get; }
    public PasswordBuffer Password { get; }

    [GeneratedRegex(@"\A[a-zA-Z_][a-zA-Z0-9_.-]{0,31}\z", RegexOptions.CultureInvariant)]
    private static partial Regex LinuxUsername();

    public static WorkspaceConnection Parse(ReadOnlySpan<byte> json)
    {
        PasswordBuffer? password = null;
        bool accepted = false;
        try
        {
            Utf8JsonReader reader = new(json, new JsonReaderOptions { MaxDepth = 4 });
            if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject)
            {
                throw new LauncherException(LauncherError.InvalidResponse);
            }

            int vmId = 0;
            long generation = 0;
            string? hostname = null, address = null, username = null;
            Guid leaseId = Guid.Empty;
            HashSet<string> fields = new(StringComparer.Ordinal);
            while (reader.Read() && reader.TokenType != JsonTokenType.EndObject)
            {
                if (reader.TokenType != JsonTokenType.PropertyName)
                {
                    throw new LauncherException(LauncherError.InvalidResponse);
                }

                string field = reader.GetString()!;
                if (!fields.Add(field) || !reader.Read())
                {
                    throw new LauncherException(LauncherError.InvalidResponse);
                }

                switch (field)
                {
                    case "VMID":
                        vmId = ReadPositiveInt32(ref reader);
                        break;
                    case "Hostname":
                        hostname = ReadString(ref reader, 253);
                        break;
                    case "IPAddress":
                        address = ReadString(ref reader, 45);
                        break;
                    case "Username":
                        username = ReadString(ref reader, 32);
                        break;
                    case "LeaseId":
                        if (!Guid.TryParseExact(ReadString(ref reader, 36), "D", out leaseId) || leaseId == Guid.Empty)
                        {
                            throw new LauncherException(LauncherError.InvalidResponse);
                        }
                        break;
                    case "LeaseGeneration":
                        generation = ReadLeaseGeneration(ref reader);
                        break;
                    case "password":
                        password = ReadPassword(ref reader);
                        break;
                    default:
                        throw new LauncherException(LauncherError.InvalidResponse);
                }
            }

            if (reader.TokenType != JsonTokenType.EndObject || reader.Read() ||
                fields.Count != 7 || vmId <= 0 || generation <= 0 ||
                hostname is null || address is null || username is null || password is null ||
                leaseId == Guid.Empty || !LinuxUsername().IsMatch(username))
            {
                throw new LauncherException(LauncherError.InvalidResponse);
            }

            RdpTarget target = RdpTarget.Validate(hostname, address);
            WorkspaceConnection connection = new(vmId, hostname, username, leaseId, generation, target, password);
            accepted = true;
            return connection;
        }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException)
        {
            throw new LauncherException(LauncherError.InvalidResponse);
        }
        finally
        {
            if (!accepted)
            {
                password?.Dispose();
            }
        }
    }

    private static PasswordBuffer ReadPassword(ref Utf8JsonReader reader)
    {
        if (reader.TokenType != JsonTokenType.String || reader.ValueSpan.Length > 7680)
        {
            throw new LauncherException(LauncherError.InvalidResponse);
        }

        char[] characters = new char[reader.ValueSpan.Length];
        bool accepted = false;
        try
        {
            int length = reader.CopyString(characters);
            if (length is < 1 or > 1280 || characters.Take(length).Any(char.IsControl))
            {
                throw new LauncherException(LauncherError.InvalidResponse);
            }

            PasswordBuffer password = new(characters, length);
            accepted = true;
            return password;
        }
        finally
        {
            if (!accepted)
            {
                Array.Clear(characters);
            }
        }
    }

    private static int ReadPositiveInt32(ref Utf8JsonReader reader)
    {
        if (reader.TokenType != JsonTokenType.Number || !reader.TryGetInt32(out int value) || value <= 0)
        {
            throw new LauncherException(LauncherError.InvalidResponse);
        }

        return value;
    }

    private static long ReadLeaseGeneration(ref Utf8JsonReader reader)
    {
        if (reader.TokenType != JsonTokenType.Number || !reader.TryGetInt64(out long value) ||
            value <= 0 || value > MaximumLeaseGeneration)
        {
            throw new LauncherException(LauncherError.InvalidResponse);
        }

        return value;
    }

    private static string ReadString(ref Utf8JsonReader reader, int maximumLength)
    {
        if (reader.TokenType != JsonTokenType.String || reader.ValueSpan.Length > maximumLength * 6)
        {
            throw new LauncherException(LauncherError.InvalidResponse);
        }

        string value = reader.GetString()!;
        if (value.Length is 0 || value.Length > maximumLength)
        {
            throw new LauncherException(LauncherError.InvalidResponse);
        }

        return value;
    }

    public void Dispose() => Password.Dispose();
    public override string ToString() => "[workspace connection redacted]";
}
