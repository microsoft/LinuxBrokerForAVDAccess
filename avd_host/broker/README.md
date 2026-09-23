# Per-user Linux workspace launcher

`Connect-LinuxBroker.ps1 -Mode desktop` starts a Windows user-mode helper that
authenticates the person to the broker, requests only that person's workspace,
stores the returned Linux credential in that person's Windows logon session,
and starts `mstsc.exe`. Linux remains a local-account/password and NFS-profile
system: **no Linux Entra/domain join is involved**.

Xpra/application modes are placeholders, not a supported connection path. Both
the wrapper and helper reject them before authentication or checkout.

## Prerequisites

The **installed host** needs a supported Windows x64 interactive AVD desktop
(the repository's Windows 11 multi-session image is the intended platform),
Windows Web Account Manager (WAM), Windows Credential Manager, and the inbox
Remote Desktop client. The helper checks for Windows build 19041 or later.
Run normally as the signed-in user, not as SYSTEM, a Windows service, an
elevated administrator, or another account using `runas`. No PowerShell
credential module and **no shared .NET runtime installation** are required.

An administrator must configure, outside this launcher:

- A dedicated **single-tenant public/native client**, not the portal client,
  with the **Mobile and desktop applications** redirect URI
  `ms-appx-web://microsoft.aad.brokerplugin/<clientId>`. Do not create/deploy a
  client secret for the launcher.
- The broker API delegated permission
  `api://<apiClientId>/connect_as_user`, consent/preauthorization for the native
  client, and the intended user's `WorkspaceUser` app-role assignment.
  `FullAccess`/portal access is separate and never substitutes for workspace
  entitlement.
- The target tenant/cloud, AVD Entra sign-in and in-session SSO prerequisites,
  applicable consent and Conditional Access policy, and network access to
  Microsoft sign-in and the HTTPS broker. A Windows work account/PRT may permit
  silent sign-in; this is not a promise of zero prompts.
- An administrator-controlled local installation directory. Ordinary users
  need read/execute permission, not permission to replace the executable,
  dependency DLLs, wrapper, or configuration. Use organization-approved
  artifact distribution and application-control/signing policy.

## Installer contract and configuration

The versioned ZIP has **no enclosing directory**. Extract **every file and any
dependency subdirectories**, not just the executable, into the installation
directory. Stable root entries include:

```text
Connect-LinuxBroker.ps1
LinuxBroker.Launcher.exe
LinuxBroker.Launcher.dll
LinuxBroker.Launcher.deps.json
LinuxBroker.Launcher.runtimeconfig.json
Microsoft.Identity.Client.dll
Microsoft.Identity.Client.Broker.dll
coreclr.dll
System.Windows.Forms.dll
... all other self-contained runtime and WAM dependencies ...
README.md
```

The ZIP deliberately contains **no `launcher.json`**. The installer writes that
file beside the executable, with exactly these five string properties.
Replace the placeholders; this example is not a working configuration:

```json
{
  "tenantId": "<tenant GUID>",
  "authorityHost": "https://login.microsoftonline.com",
  "clientId": "<dedicated native launcher application GUID>",
  "apiClientId": "<broker API application GUID>",
  "apiBaseUrl": "https://<broker DNS name>/api"
}
```

The configuration is not a secret. Its **integrity** is important: it determines
where the user authenticates and sends the broker token. GUIDs must be nonempty,
and the native and API client IDs must differ. Unknown fields, including
`clientSecret` or caller-supplied usernames, are rejected.

`authorityHost` is an explicitly configured HTTPS **DNS authority root**,
optionally ending in one `/`, on the standard HTTPS port (implicit or `:443`).
Public, government, China, and explicit custom-cloud endpoints are not
restricted by a built-in cloud-name allowlist. For example, an administrator
can configure the supported endpoint for an `AzureCustom` environment rather
than selecting a hardcoded public-cloud host. The integrity of this deployed
configuration is the trust boundary for endpoint selection.

The helper appends the configured tenant GUID. Localhost (including its
subdomains), IP literals, userinfo, non-root paths (including normalized dot
segments), query strings, fragments, and nonstandard ports are rejected.
An authority containing `/common` or `/organizations` is not accepted.
Accepting a DNS root in configuration **does not establish MSAL/WAM support
for that authority**: MSAL `validateAuthority: true`, authority discovery,
normal TLS verification, and all tenant/account/scope checks remain enabled.
An unknown or unsupported cloud must fail explicitly through authentication;
there is no discovery bypass, insecure TLS option, or alternate-identity
fallback. Actual custom/sovereign-cloud support depends on MSAL, WAM, and the
cloud's identity platform, and requires an authorized cloud-specific AVD/SSO
pilot before production use.

`apiBaseUrl` must use HTTPS, end in `/api` (not `/api/`), and have no userinfo,
query string, fragment, or loopback host.

User entry point:

```powershell
& 'C:\Program Files\LinuxBroker\Connect-LinuxBroker.ps1' -Mode desktop
```

An existing shortcut/wrapper location can point at a separately installed bundle:

```powershell
& 'C:\Tools\Connect-LinuxBroker.ps1' -Mode desktop `
    -LauncherPath 'C:\Program Files\LinuxBroker\LinuxBroker.Launcher.exe' `
    -ConfigPath 'C:\Program Files\LinuxBroker\launcher.json'
```

The exact native interface is:

```powershell
& 'C:\Program Files\LinuxBroker\LinuxBroker.Launcher.exe' `
    --config 'C:\Program Files\LinuxBroker\launcher.json' --mode desktop
```

Executable/config paths must be absolute **local** Windows paths, not UNC paths.
There are no token, password, username, secret, or tenant-override arguments.
The wrapper waits for the helper and preserves its exit status.

## Authentication and checkout behavior

The first silent MSAL request uses
`PublicClientApplication.OperatingSystemAccount`, not the first cached
account. Only `MsalUiRequiredException` permits interactive authentication.
The visible launcher explains why sign-in is needed and owns the WAM prompt
via its HWND. Cancelling before checkout makes no workspace request.
All MSAL calls run in the interactive user's session, with no serialized
application token cache, client credentials, CLI credentials, IMDS,
`DefaultAzureCredential`, device-code flow, or machine/operator fallback.

The helper checks MSAL's returned tenant, account, token type, expiry, and
granted scope before use. It treats access tokens as opaque; **the broker must
cryptographically validate the bearer token and enforce user/client/scope/role
authorization**. The helper's metadata checks are not an authorization boundary.

Checkout is exactly:

```text
POST <apiBaseUrl>/vms/checkout
Authorization: Bearer <in-memory user token>
Content-Type: application/json
Cache-Control: no-store, no-cache

{"avdhost":"<Environment.MachineName>"}
```

`avdhost` is audit metadata, not proof of ownership. No Windows username, UPN,
Entra object ID, lease override, or user-selected target is sent. The helper
consumes this case-sensitive response:

```text
{VMID:int32, Hostname:string, IPAddress:string, Username:string,
 LeaseId:UUID, LeaseGeneration:integer, password:string}
```

`VMID` must be a positive Int32 value. `LeaseGeneration` is stored in a C#
`long` (and SQL BIGINT), but its JSON-number wire value must be positive and
at most **`9007199254740991`**, the shared safe-integer bound for JavaScript
and older jq consumers. The helper reads it exactly with `TryGetInt64`, without
floating-point conversion or Int32 truncation, and rejects values beyond the
shared bound before writing credentials or launching RDP. It never wraps,
rounds, clamps, or automatically retries an out-of-range response. Full Int64
wire values are **not** supported; the field remains a JSON number, not a
string. The UUID must be nonempty.
The hostname must be a valid ASCII DNS/host name. The username must match
`[A-Za-z_][A-Za-z0-9_.-]{0,31}` and is used **exactly as returned**, never
derived from Windows/Entra naming. Duplicate, missing, extra, incorrectly typed,
oversized, and unsafe fields fail before any credential write. Responses are
bounded at 32 KiB, require JSON and `Cache-Control: no-store`, and are never
written to ordinary files. The API remains responsible for enforcing its
no-store response policy.

The returned IP must be canonical unicast IPv4 or valid unscoped IPv6, not
loopback, unspecified, link-local/IMDS, multicast, IPv4-mapped IPv6, or an
option/command. Alternate valid IPv6 spellings (case, leading zeros, or
compression) are parsed and normalized to one canonical target rather than
rejected for their textual spelling.
The helper connects directly to that IP, avoiding a separate DNS target:
`mstsc.exe /v:<IP>` (bracketed for IPv6). It stores **one** generic credential
named `TERMSRV/<same target>` using `CredWriteW`, the **returned `Username`**,
and `CRED_PERSIST_SESSION`. This is protected by Windows for the current
user/logon session and disappears on Windows logoff. It neither enumerates nor
deletes other credentials, nor writes unnecessary hostname aliases or roaming
entries. `mstsc.exe` is resolved from the Windows system directory and started
without a shell. No username, token, or password is in its arguments.

The HTTP handler disables redirects, cookies, and default Windows credentials,
uses normal TLS validation plus certificate-revocation checking, and bounds
checkout to two minutes including response reading. Error bodies and exception
payloads are not displayed or logged. Response-byte, password-character, and
native WinCred staging buffers are cleared after use. WAM manages its own
protected user token cache; managed access-token strings cannot be reliably
zeroed. Protect the Windows session and any OS crash-dump/pagefile collection
according to organizational policy.

An API **401** allows one forced refresh and one checkout retry for the **same
authenticated account**. A second 401 stops. **403** explains missing workspace
entitlement and never triggers another sign-in or checkout. **409** reports
capacity/conflicting lease activity with no automatic retry. Network failures,
timeouts, redirects, and all other HTTP failures stop rather than risking
duplicate allocation/password rotation. Cancelling or losing connectivity
after a request was sent cannot prove the server did not complete it.

Duplicate launches for the same Windows user/session are blocked while the
launcher is open. Exit 0 means **mstsc started**, not that Linux sign-in
succeeded. Token expiry does not close or supervise an open RDP session.
A later launcher invocation obtains a fresh user token and may rotate the
Linux password through authorized checkout. RDP/NFS reconnect/expiry policy
remains the broker/Linux lifecycle's responsibility.

| Exit | Meaning |
| --- | --- |
| 0 | Remote Desktop process started |
| 2 | Invalid arguments, missing/invalid configuration or installed files |
| 3 | Microsoft authentication failed |
| 4 | User cancellation |
| 5 | Broker 403 forbidden |
| 6 | Broker 401 after bounded refresh |
| 7 | Broker 409 capacity/conflict |
| 8 | Unavailable broker, timeout, redirect, or other HTTP failure |
| 9 | Invalid/unsafe credential response |
| 10 | Windows credential storage failed |
| 11 | Executable/Remote Desktop could not start |
| 12 | Unexpected, safely reported failure |
| 13 | Unsupported xpra/application mode |
| 14 | Wrong token tenant |
| 15 | Account changed during refresh |
| 16 | A connection window is already running |
| 17 | Invalid, expired, or incorrectly scoped MSAL result |
| 18 | Unsupported/noninteractive/elevated Windows context |

## Build, tests, and publish

The **build machine**, unlike the installed host, needs Windows x64, PowerShell
5.1 or 7, **.NET SDK 8.0.425** (`global.json`), and package-feed access.
.NET 8 is the installed supported LTS SDK; runtime 8.0.31 and matching
MSAL/Broker 4.84.2 versions are pinned. Before .NET 8's November 2026 support
end, move the build to the supported .NET 10 LTS SDK and repeat the pilot.
Update SDK/runtime/MSAL pins and lock files deliberately for servicing; do not
ship unreviewed floating versions.

`NuGet.Config` uses Microsoft's public `dotnet-public` NuGet mirror. Restores
use the explicit project-owned config rather than inheriting private feeds or
operator credentials. Both projects' `packages.lock.json` pin transitive
versions and content hashes. The publish script requires locked restores and
accepts an explicit `-NuGetConfigPath` for an approved alternative feed config.
No vulnerability warnings are suppressed.

From `avd_host\broker`, validation commands are:

```powershell
$dotnet = 'C:\Program Files\dotnet\dotnet.exe'
& $dotnet restore '.\tests\LinuxBroker.Launcher.Tests.csproj' --runtime win-x64 --locked-mode --configfile '.\NuGet.Config'
& $dotnet build '.\tests\LinuxBroker.Launcher.Tests.csproj' -c Release -r win-x64 --no-restore
& $dotnet test '.\tests\LinuxBroker.Launcher.Tests.csproj' -c Release -r win-x64 --no-build --no-restore
& '.\tests\Test-PowerShell.ps1'
```

For an intentional dependency change, edit the pinned manifest and run restore
without `--locked-mode` once, then review the updated locks and repeat the
locked commands. Do not discard locks to make a failing release pass.

The installer-integration build command (from the repository root) is:

```powershell
$bundle = & '.\avd_host\broker\Publish-Launcher.ps1' `
    -OutputDirectory 'C:\Build\LinuxBroker' -Version '1.0.0' `
    -DotNetPath 'C:\Program Files\dotnet\dotnet.exe'
$bundle.BundlePath
$bundle.Sha256
```

This parses/tests PowerShell, restores with locks, builds with warnings as
errors, runs the unit tests, publishes self-contained `win-x64`, verifies
essential runtime/WAM files, and creates
`C:\Build\LinuxBroker\LinuxBroker.Launcher-1.0.0-win-x64.zip`. The returned
object has `BundlePath`, `Sha256`, `Version`, and `Runtime`. Build logs go to
the host stream, not into that object. **There is no upload, deployment,
sign-in, tenant mutation, or WinCred/RDP operation during publish/tests.**

The underlying publish is:

```powershell
& $dotnet restore '.\launcher\LinuxBroker.Launcher.csproj' -r win-x64 -p:SelfContained=true --locked-mode --configfile '.\NuGet.Config'
& $dotnet publish '.\launcher\LinuxBroker.Launcher.csproj' -c Release -r win-x64 --self-contained true --no-restore --output 'C:\Build\LinuxBroker\published'
```

The script includes the wrapper and README, sorts ZIP entries ordinally, fixes
ZIP timestamps/attributes, and stages each build in a unique child directory
so old files cannot leak into a new bundle. It replaces only the specifically
named output ZIP after success and removes only its own new staging child.
It never cleans the output directory recursively. Repeating a build on the
same pinned toolchain/source/version produces stable bundle contents.
Release signing, if required, must happen before the final archive/hash is
distributed; signing will intentionally change the digest.

## Validation boundary and required pilot

Automated tests exercise OS-account selection, cloud/tenant/scope selection,
silent and conditional interactive flows, cancellation before checkout,
wrong-tenant rejection, bounded 401 refresh, 403/409/no-retry behavior, exact
request bodies, malformed response rejection, response-size/cache policy,
credential scope/persistence, secret-redacted errors, password-buffer cleanup,
and shell-free mstsc arguments. Native authentication, WinCred, process launch,
and HTTP boundaries are injectable. Tests use **no live credentials**, do not
write actual Windows credentials, and do not contact a tenant/broker.

**A headless test pass does not prove WAM, AVD SSO, WinCred consumption, or a
real RDP/NFS session. Production cutover requires an authorized pilot.**
On the actual pooled AVD image and intended cloud:

1. Verify two ordinary users on one host get only their own assignments and
   the correct persistent profiles; confirm silent OS-account SSO when policy
   permits and visible owned consent/MFA when it does not.
2. Cancel before checkout, deny access, and test wrong-tenant/missing-WAM or
   missing-consent cases. Confirm no machine/CLI/operator identity is used and
   403 does not produce an authentication loop.
3. Confirm `TERMSRV/<IP>` credentials are consumed by mstsc (including
   bracketed IPv6 if used), are isolated by Windows logon, disappear on
   Windows logoff, and leave unrelated credentials unchanged. Check RDP
   certificate/credential-delegation policy for the Linux target.
4. Reconnect, including after token expiry and under MFA policy; demonstrate
   that an already-open RDP session is not ended by access-token expiry.
   Verify authorized password rotation does not change username/UID/NFS data.
5. Validate two near-simultaneous clicks, broker conflict/capacity responses,
   timeouts, blocked credential storage, and missing mstsc. Inspect approved
   diagnostics for absence of tokens/passwords without collecting raw HTTP,
   WAM token results, process-memory dumps, or credential values.

No production tenant changes or live SSO/RDP success are implied by the local
build and unit tests.
