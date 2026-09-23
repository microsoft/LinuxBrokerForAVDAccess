# Broker API

The Flask broker authorizes Entra subjects, reserves Linux leases in SQL, provisions temporary local credentials, and manages inventory, scaling, and host settings. Linux accounts remain non-domain-joined and use their existing persistent NFS profiles.

## Authorization

`authorization.py` verifies RS256 signatures against the configured tenant JWKS, then constructs an immutable typed principal. Every business route has an explicit `Policy`; there is no scope/role/group OR shortcut and no runtime Microsoft Graph authorization.

Malformed JWT headers are authentication failures (401). Signing-key retrieval failures, malformed JWKS JSON and invalid key documents are dependency failures (503), with no token/body detail in the response or logs. Clients must not treat a key-service outage as a reason to force sign-in or token refresh.

Accepted audiences are `CLIENT_ID` and `api://<CLIENT_ID>`. Accepted issuers are `{AZURE_AUTHORITY_HOST}/{TENANT_ID}/v2.0`, `{AZURE_AUTHORITY_HOST}/{TENANT_ID}/`, and `{STS_ISSUER_HOST}/{TENANT_ID}/`. Required claims include `exp`, `nbf`, `iat`, `iss`, `aud`, `sub`, `tid`, `oid`, and `ver`. Identity/client IDs must be nonempty canonical UUID strings; lifetimes must be integers; scopes and roles must have their expected types. Version 1 tokens require `appid`; version 2 tokens require `azp`. Conflicting client claims are rejected.

| Principal | Required authority | Allowed operations |
| --- | --- | --- |
| Workspace user | Delegated `connect_as_user`, `WorkspaceUser`, and `BROKER_LAUNCHER_CLIENT_ID` | Own checkout/reconnect only, plus own capabilities |
| Portal administrator | Delegated `access_as_user`, `FullAccess`, and `PORTAL_CLIENT_ID` | Management; never credential checkout or impersonation |
| Linux host | App-only `idtyp=app`, `LinuxHost`, and registered `(tid, oid)` | Global settings read, own settings acknowledgement, own guarded session observations |
| Scheduled task | App-only `idtyp=app` and `ScheduledTask` | Minimal connectivity inventory, reachability updates, expiry/retry processing, and scaling trigger |
| Unassigned delegated user from an intended client | Valid token but missing entitlement | Own capabilities with false flags |

A user token cannot become a workload by carrying a workload role. An unscoped token is not considered app-only unless `idtyp=app` is present. Configure that optional access-token claim on the API registration. Legacy `AvdHost` roles, AVD/Linux group membership, and a plain delegated scope grant no business authority. An administrator who also connects needs a separately acquired native-client token with workspace scope and entitlement.

### Workload optional claim and cached-token cutover

The **API resource registration**, not just its clients, must request `optionalClaims.accessToken` entry `{"name":"idtyp","source":null,"essential":false,"additionalProperties":[]}`. Deployment must merge this entry idempotently while preserving unrelated access-token, ID-token and SAML optional claims. Both verified v1 (`appid`) and v2 (`azp`) workload tokens require `idtyp=app` and their explicit application role. Delegated native/portal tokens require their scope, role and client; `idtyp` may be absent or `user`, never `app`.

Stage and verify the registration change before enabling the secured workload flow. A manifest update does not modify JWTs already cached by IMDS or Azure Identity. Reacquiring a token or restarting a process can still return that old cached token; do not assume either forces immediate reissuance. During the coordinated paused cutover, revalidate renewed tokens through the actual read-only broker operation: registered Linux hosts use `GET /api/hosts/settings`, and scheduled tasks use `GET /api/vms`. `/api/me` is deliberately delegated-only and is not a workload probe.

An older token without `idtyp=app` remains 401 with no business side effects, even if its roles otherwise match. Keep activation blocked until role assignment/optional-claim propagation and managed-identity cache renewal produce accepted tokens; no role-only, group-only or missing-claim fallback exists. Never print tokens or store them in cutover logs. Live token reissuance/propagation must be checked during authorized deployment, not inferred from local signed-token fixtures.

### Endpoint policies

`Manage` below means the complete portal administrator policy, not just a scope or role.

| Method | Path | Policy |
| --- | --- | --- |
| GET | `/health`, `/api/version` | Public minimal health/version |
| GET | `/api/me` | Intended delegated client; own principal/capabilities only |
| GET | `/api/vms` | Manage or ScheduledTask; scheduled callers receive only VMID, hostname, IP, power and network state |
| GET | `/api/vms/summary`, `/api/vms/<vmid>` | Manage |
| POST | `/api/vms/checkout` | Workspace user |
| POST | `/api/vms/<vmid>/update-attributes` | Manage; ScheduledTask may change only `networkstatus` |
| POST | `/api/vms/add`, `/api/vms/<vmid>/delete` | Manage; unowned inventory only |
| POST | `/api/vms/<vmid>/return`, `/api/vms/<hostname>/release` | Manage with required lease guards |
| POST | `/api/vms/<hostname>/session` | Registered LinuxHost matching the hostname, with required lease guards |
| POST | `/api/vms/released` | Manage or ScheduledTask |
| POST | `/api/vms/history`, `/api/scaling/log`, `/api/scaling/rules/history` | Manage |
| POST | `/api/scaling/trigger` | Manage or ScheduledTask |
| GET | `/api/scaling/rules`, `/api/scaling/rules/<ruleid>` | Manage |
| POST | `/api/scaling/rules/create`, `/api/scaling/rules/<ruleid>/update`, `/api/scaling/rules/<ruleid>/delete` | Manage |
| GET | `/api/hosts/settings` | Manage or registered LinuxHost |
| POST | `/api/hosts/settings/update`, `/api/hosts/settings/apply` | Manage |
| POST | `/api/hosts/<hostname>/settings/ack` | Registered LinuxHost matching the hostname |

Settings update attribution comes from the verified subject, not a supplied `updatedBy`. Generic VM add/update cannot supply usernames, owners, leases, or manufacture `CheckedOut`/`Released` state. Power/status edits and deletion refuse owned or in-progress hosts.

**Manual Add VM creates inventory, not trust.** A manually added or recreated hostname is not checkout-ready until the trusted deployment connection imports its verified ARM address with `RegisterLinuxHostVm` and enrolls its managed identity with `RegisterBrokerHost`. Deletion or an endpoint change revokes previous enrollment atomically; matching an old hostname, setting `Available`/`On`/`Reachable`, or restoring an old IP does not restore it. Portal administrators and scheduled tasks cannot execute either trusted enrollment procedure. This prevents management from redirecting a user's RDP credential to an administrator-supplied endpoint.

### Capability and checkout contracts

`GET /api/me` returns exactly:

```json
{
  "subject": {"tenantId": "<verified tid>", "objectId": "<verified oid>"},
  "capabilities": {"manage": false, "connect": true}
}
```

`POST /api/vms/checkout` accepts only `{"avdhost":"avd-01"}`. The hostname is audit metadata, not identity proof. Target usernames, tenant/object IDs, UIDs, lease overrides, unknown fields, and query parameters are rejected before allocation. SQL resolves the authenticated `(tid, oid)` to its immutable username/UID; UPN and display-name changes have no effect.

Broker UIDs are `2000..2147483646`, excluding reserved `65534` and `65535`. New allocation skips those values; existing reserved mappings are rejected for operator recovery, never silently assigned a different UID or profile.

Successful checkout returns exactly `VMID`, `Hostname`, `IPAddress`, `Username`, `LeaseId`, `LeaseGeneration`, and `password`. The password is generated per authorized operation and passed through SSH stdin inside a single locked provisioning operation. Never log that response, the bearer token, SSH stdin, or host command output. Every `/api/` response, including denials, has `Cache-Control: no-store`.

## Lease lifecycle and recovery

Apply [SQL migrations 040-046](../sql_queries/README.md) and install the version-matched [Linux helpers](../linux_host/README.md) before activation. There is no vulnerable compatibility mode. The first application of 046 quarantines existing host enrollments until the normal trusted ARM import/enrollment sequence runs again; it preserves user mappings, active leases and generation tombstones.

RHEL 7/8-style hosts can use the dedicated cgroup-v1 XRDP freezer backend with pre-exec service enrollment; newer unified-cgroup hosts use the systemd-v2 gate. Host `gate-status` must pass before provisioning/migration. Existing unenrolled desktops are left owned and pending a controlled drain/enrollment restart, not forcibly logged off or silently excluded by an OS upgrade requirement. See the Linux installation contract for `broker-freezer.py`, service wrappers and durable restart recovery.

1. `BeginBrokerCheckout` resolves the immutable subject, reuses that subject's live lease or reserves one ready registered host, and creates a durable operation. The SQL transaction commits before SSH.
2. The host validates the username/UID, generation, and operation under a root-owned lock, mounts/verifies the persistent profile, sets groups and rotates the password. SQL completion is a compare-and-set on the exact operation and generation.
3. Host `active`, `disconnected`, and `logged_off` observations require a registered host identity and exact `leaseId`/integer `leaseGeneration`. Initial disconnect does not terminate Xorg. Automatic mstsc reconnect restores `CheckedOut` without relaunching the launcher or issuing credentials.
4. `DisconnectedAt` is set once per disconnect and cleared by an active observation. Expiry reads the global `LinuxHostSettings.GracePeriodSeconds` (default 1200), never `LastUpdateDate` or a separate 30-minute constant.
5. Cleanup reserves a new fenced operation while retaining ownership. The host gates XRDP reconnect, rechecks actual state, ends only the mapped UID's sessions, verifies a non-lazy home unmount, removes the local account without recursive home deletion, and preserves NFS files/UID.
6. Only acknowledged cleanup and guarded SQL completion make the host available. Active sessions found during expiry/logoff cancel cleanup. Power operations likewise retain a reservation until Azure completion is confirmed; powering on never clears a lease.

Both administrative return and release require a JSON object containing exactly `leaseId` and integer `leaseGeneration` from the current management record. Return forces guarded cleanup; release only marks disconnection and can be cancelled by the host observing an active session.

Generations increase on reservations, including reconnects and cleanup; the lease ID remains stable until cleanup completes. A failed reconnect **never** returns the existing assignment. Failed operations retain ownership and are explicitly retryable. The same subject may retry failed provisioning; the maintenance sweep retries failed cleanup. An interrupted `Running` operation becomes retryable after 300 seconds with a new generation, not by clearing its guard. Stale host commands/finalizations cannot supersede newer generations.

Lease generations use Int64 storage but the shared JSON domain is `1..9007199254740991`, so JavaScript, jq and native clients all retain exact values. They are not restricted to Int32. Request guards, issued credentials, root markers and SQL reservations enforce that bound; invalid values are never clamped or rounded. Unassigned inventory may use generation 0. Counter exhaustion fails closed and removes an unowned host from ready/scaling selection rather than wrapping its fence.

Administrators must refresh the VM record before retrying an uncertain return; a stale request receives 409 without the current lease being disclosed. `OperationId`, `OperationKind`, `OperationState`, `OperationError`, and `OperationStartedAt` make pending recovery visible. Host unreachability, busy mounts, unsupported/unverified XRDP gates, and uncertain SSH or SQL completion remain unavailable. Never repair these by forcing `Available` or resetting a marker/generation.

## Configuration

The API reads environment variables directly; see [env.example](env.example).

| Variable | Purpose |
| --- | --- |
| `TENANT_ID`, `CLIENT_ID` | Single Entra tenant and broker API audience |
| `PORTAL_CLIENT_ID`, `BROKER_LAUNCHER_CLIENT_ID` | Separate intended delegated clients |
| `BROKER_CHECKOUT_ENABLED` | Defaults to `true`; `false` pauses checkout without weakening policy |
| `AZURE_CLOUD_NAME` | `AzurePublic` (default), `AzureUSGovernment`, or `AzureCustom` |
| `AZURE_AUTHORITY_HOST`, `STS_ISSUER_HOST` | Authentication endpoint overrides; both required for AzureCustom |
| `DB_SERVER`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD_NAME` | Runtime SQL connection and Key Vault password secret name; use a dedicated `BrokerApiRuntime` database user |
| `VAULT_URL`, `KEY_NAME` | Key Vault and SSH private key secret |
| `LINUX_HOST_ADMIN_LOGIN_NAME`, `DOMAIN_NAME` | SSH admin (default `avdadmin`) and host DNS suffix |
| `NFS_SHARE` | Required export for safe provisioning; empty/unverifiable storage fails closed |
| `VM_SUBSCRIPTION_ID`, `VM_RESOURCE_GROUP` | Azure scaling target |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | Optional telemetry; do not enable credential/header/body capture |

The API no longer uses `AVD_HOST_GROUP_ID`, `LINUX_HOST_GROUP_ID`, Graph scopes, or a Graph client secret. Deployment still uses Graph for trusted app/role configuration; that is a separate identity and permission boundary.

## Existing collection contracts

History POSTs preserve opt-in `page`/`per_page` pagination: paged responses contain `items`, `page`, `per_page`, `total`, and `total_pages`; otherwise they remain arrays. The maximum page size is 200. Empty collections remain `[]` with 200. Existing nullable `limit` and date-filter normalization is retained.

`GET /api/vms/summary` retains its public counters. `Ready` additionally requires no owner, username, lease, or operation and an active registered host, matching checkout eligibility.

## Validation

Use isolated environments. From the repository root, after restoring `api\requirements.txt` and `api\requirements-dev.txt`:

```powershell
python -m pytest api\tests -q
python -m pytest api\authorization_tests -q
python sql_queries\tests\run_sql_integration.py --docker
```

The default `python -m pytest` with working directory `api` also discovers both suites; do not restrict CI to `tests` alone. Keep API and frontend Python suites in separate processes. Regression fixtures inject an explicit administrator principal but keep policy decorators intact and no longer install a fake JWT module. `authorization_tests` has independent fixtures, signs RSA tokens with real PyJWT/cryptography, checks that neither authentication nor decorators were replaced, mocks only infrastructure, and checks all routes, cross-subject/host denials, capabilities, side-effect ordering, and secret handling. Its standalone command above also runs independently of the regression conftest.

The SQL harness only creates a disposable loopback-bound local SQL Server container; it cannot accept a live connection string. It tests actual migration/rerun and competing SQL transactions. An unavailable Docker/SQL runtime is a limitation, not a passing transaction test. Host tests and installation prerequisites are documented in [linux_host/README.md](../linux_host/README.md).

Windows CI can instead use `sql_queries\tests\Run-LocalDbIntegration.ps1 -InstanceName LinuxBrokerAuth_<unique-suffix> -DatabaseName LinuxBrokerAuthorizationTests_<unique-suffix>` against an already-running isolated SQL LocalDB instance and initially empty dedicated test database. It uses native PowerShell `System.Data.SqlClient`, resets only its marked test schema inside that one supplied database, and synchronizes genuinely competing connections at the database lock. It never creates/drops databases or connects to default databases. The caller owns instance/database startup and cleanup; the harness never starts LocalDB or changes Docker Desktop. See the [SQL validation contract](../sql_queries/README.md).
