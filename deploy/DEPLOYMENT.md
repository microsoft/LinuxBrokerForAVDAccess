# Deployment and authorization migration

The supported fresh deployment is `azd up` from this directory. Existing environments use
`Migrate-ExistingEnvironment.ps1`, not an uncoordinated infrastructure redeployment.
Both paths finish with **checkout paused**. A completed deployment does not by itself prove
tenant SSO, RDP reconnect, or NFS compatibility.

Entra authenticates requests to the broker; it does **not** authenticate users to Linux.
Linux remains non-domain-joined, with temporary local accounts, broker-generated passwords,
stable UIDs, and persistent NFS profiles. Never rename an existing profile to match a UPN.

## Authorization model

| Principal | Required API permission | What it can do |
| --- | --- | --- |
| AVD workspace user | `WorkspaceUser` (User), `connect_as_user`, dedicated launcher client | Connect/reconnect only to the authenticated subject's own workspace. No portal access. |
| Portal administrator | `FullAccess` (User), `access_as_user`, portal client | Manage the fleet. Cannot check out another user's credentials. |
| Linux VM identity | Direct `LinuxHost` (Application) assignment and registered tenant/object/VM binding | Its own host operations, with current lease and generation where required. |
| Function identity | Direct `ScheduledTask` (Application) assignment | Scheduled maintenance only. |
| AVD VM identity | None | Windows Entra login and private artifact download only; cannot authorize checkout. |

An administrator who also needs a Linux workspace must be selected in **both** user sets.
Legacy `AvdHost` claims, VM-group membership, arbitrary usernames, and hostname-only requests
never regain authorization. There is no legacy compatibility switch.

Three separate single-tenant registrations are used:

* The API publishes the four roles above and two distinct delegated scopes.
* The confidential portal requests only `access_as_user`. Its enterprise application requires
  assignment (`appRoleAssignmentRequired=true`) and only explicitly selected administrators
  receive its `BrokerPortalAdministrator` role. API authorization remains independently required.
* The public native launcher requests only `connect_as_user`, has **no client secret**, and has
  the exact WAM redirect `ms-appx-web://microsoft.aad.brokerplugin/<launcher-client-id>`.

Only the matching scope is preauthorized for each intended client. This is targeted API consent,
not permission to sign in as any user or a tenant-wide authorization grant. Application updates
merge existing manifests: unrelated roles, scopes, preauthorizations, required-resource entries,
and redirect URIs are preserved. The selected workspace and administrator lists are authoritative
for the broker user roles and portal access.

The API registration requests the optional **access-token `idtyp` claim**. Workload authorization
requires `idtyp=app` in addition to the application role and host binding; delegated user tokens
cannot substitute for workload tokens. Existing unrelated access-token, ID-token, and SAML
optional claims are retained. Allow Entra assignment/claim propagation and renewal of cached
managed-identity tokens before the pilot; old tokens missing `idtyp` fail closed.
Both normal application setup and early workload staging perform bounded Graph readback of
the saved access-token `idtyp` configuration. Failure to observe it blocks progress. A successful
manifest readback is not token renewal or workload authorization; actual allowed-operation
probes remain mandatory before activating agents/functions.

The API no longer performs runtime directory group checks. Deployment removes only the old API
Graph **application** grants and requested permissions `Directory.Read.All`, `Group.Read.All`,
and `GroupMember.Read.All`, preserving unrelated permissions. No new API client secret is created
or injected. Existing API app credentials are not indiscriminately deleted: review any other
consumers and retire unused credentials after the secured cutover. The portal still needs its
own confidential-client secret.

## Prerequisites

### Deployment workstation

Use Windows, PowerShell 7.4 or later (`pwsh`), Azure CLI, Azure Developer CLI, and access to the
intended tenant/subscription/cloud. The azd hooks in [azure.yaml](azure.yaml) are Windows hooks.
Use OpenSSH Client if deployment should generate a Linux SSH keypair. A partial configured
keypair is an error; deployment never silently replaces the other key.

For the default local native build, install the **exact .NET SDK in
[avd_host\broker\global.json](../avd_host/broker/global.json)** (currently `8.0.425`), with access
to the package source configured in `avd_host\broker\NuGet.Config`. The publisher restores in
locked mode, builds/tests, and publishes a self-contained Windows x64 bundle. No .NET SDK/runtime,
Azure CLI, SqlServer PowerShell module, or CredentialManager module is installed on AVD hosts
for broker authentication. A reviewed prebuilt package can avoid the local SDK prerequisite.

Container images are built remotely using `az acr build`; Docker is not required locally.
The frontend container's build needs its Node base image and the npm registry (or an approved
mirror). Build inputs and lockfiles must be the version being rolled out.
The build hook stages only current tracked/unignored `api`, `front_end`, and `task` inputs,
excluding runtime sessions, local settings, and environment files. Deployment secrets, reviewed
mapping files, native bundles, and rollout receipts never enter the uploaded ACR build context.

### Operator privileges and connectivity

The signed-in deployment operator needs:

* ARM deployment, app configuration/start/stop, VM inventory and Run Command privileges, and
  permission to create the AVD Desktop Virtualization User / VM User Login role assignments.
  Effective Function workload validation also requires Entra-authorized access to that app's
  SCM `/api/command` endpoint. It uses the cloud's ARM audience, not a publishing password.
* Entra application/service-principal read/write and app-role-assignment permissions, plus
  read access to the selected users and security-group membership. Assignment/consent failures
  stop the deployment; they are not warnings followed by a successful result.
* Storage Blob Data Contributor on the artifact storage account for the operator's uploads,
  and ARM permission to assign Storage Blob Data Reader to each AVD VM identity **only at the
  artifact container**. No storage account key or SAS generation is required.
* An encrypted trusted SQL deployment connection with schema/procedure and binding permissions.
  The workstation needs SQL firewall/network access. Take a database backup and preserve
  profile/UID/lease inventories before upgrading.
* Key Vault permission to set the runtime database secret, list its versions, and disable
  superseded versions (for example, a scoped Key Vault Secrets Officer assignment for the
  deployment operator). The API retains read-only secret access, not those management rights.

Generated `bicep\main.parameters.json` and azd environment files contain deployment secrets.
They are local, gitignored operational files: do not attach them to tickets, publish them,
print all environment values, or include them in build artifacts.

### Windows/tenant SSO preflight

The declared AVD platform is Entra-joined Windows 11 multi-session with `AADLoginForWindows`.
Verify the actual host pool, in-session account/PRT availability, WAM policy, authority/cloud,
application assignments, consent, and Conditional Access before production activation.
Review the host pool's `enablerdsaadauth` configuration against the
[AVD single sign-on documentation](https://learn.microsoft.com/azure/virtual-desktop/configure-single-sign-on)
and the [MSAL WAM requirements](https://learn.microsoft.com/entra/msal/dotnet/acquiring-tokens/desktop-mobile/wam).

Deployment does **not** change tenant-wide Conditional Access or promise zero prompts.
The launcher must run in the actual interactive user's session. It tries the Windows operating
system account, then supported interactive authentication when required; cancellation/denial
stops before checkout. SYSTEM/Run Command installs files only; it never signs a user in.

### Linux host prerequisites

**RHEL7/8 remain intended deployment targets; dropping them or requiring an OS upgrade is not
part of the approved redesign.** The modern gate uses systemd >=246, unified cgroup v2, and
both active XRDP service control groups. Stock legacy systems need the core's equivalently
verified cgroup-v1 freezer backend, not a relaxed per-lease check or an immediate-kill fallback.

The pinned `broker-freezer.py` companion and deployment-only
`configure-broker-xrdp-gate.py` support controlled startup enrollment for RHEL7/8-style legacy
systems. They require a separate, complete cgroup-v1 `freezer` hierarchy and the `name=systemd`
hierarchy, both root-controlled and visible in the host mount namespace. Shared resource
controllers, ambiguous mounts, and unknown cgroup state are rejected rather than converted.
No OS/systemd upgrade or cgroup hierarchy conversion is performed.

The legacy helper enrolls XRDP and sesman **at startup** through
`manage-lease.sh run-xrdp <unit> <original-daemon> <original-args>`. The installer writes only its
named `50-linuxbroker-freezer.conf` drop-in, preserving the existing supported daemon path,
arguments, environment-file settings, service type, and other unit configuration. Shell-wrapped,
multiline, prefixed, or conflicting custom starts require explicit operator review. The installer
does not move a live PID tree, issue freeze/thaw, or weaken lease/generation checks.
An existing later-sorted drop-in such as `override.conf` that resets `ExecStart` is rejected
**before any service/configuration mutation** rather than being overwritten or silently
winning over `50-linuxbroker-freezer.conf`. Unrelated later drop-ins are preserved.

Fresh bootstrap enrolls only an actually empty/drained host and then requires `gate-status`
to verify the running daemon hierarchy. **Existing, un-enrolled legacy hosts require a planned
drain with connection admission closed** and the explicit `-EnrollDrainedLegacyHosts` migration
switch. The switch does not override safety checks: SQL must report no active assignment or
operation, the absent/cleaned marker must match trusted SQL evidence, and the host must have no
logind sessions, Xorg/Xvnc/Xwayland processes, workspace accounts, RDP/sesman connections, or
mounted homes. It stages the startup wrappers, reloads systemd, and reads back both effective
`ExecStart` commands **before stopping or starting either service**. A changed/masked wrapper
blocks further action. Only then may it stop the empty daemons, repeat the drain/effective-command
checks, start clean daemons, and use the core's bounded `wait_ready()` check. A successful
`systemctl start` alone is not proof that a `Type=simple`/`exec` wrapper has self-enrolled.
Only classified transient startup state is waited for; ownership/enrollment mismatches remain
failures and are never converted into readiness.

An interrupted first installation after wrapper publication/reload but before any daemon
start is rerunnable only with the explicit drained switch, both units inactive/failed with
`MainPID=0`, and a missing **initial** `linuxbroker-xrdp` hierarchy beneath the still-protected
controller. The installer still repeats all SQL-idle/marker/drain checks. Missing unrelated
files, an absent/changed controller, permission errors, ownership mismatches, and unresolved
existing hierarchies are not swallowed as a recoverable first-start condition.

```powershell
# After an authorized drain and closing host connection admission:
.\Test-BrokerHostPrerequisites.ps1 -EnvironmentName <environment-name> -AllowDrainedLegacyEnrollment
.\Migrate-ExistingEnvironment.ps1 -EnvironmentName <environment-name> -EnrollDrainedLegacyHosts
```

The first command only verifies platform/controller availability; it does not certify startup
enrollment or change services. Without the migration switch, un-enrolled hosts block explicitly.
An active SQL lease never receives restart permission even when the switch is present.
Already-enrolled legacy hosts with a verified gate rerun without restarting XRDP, preserving
their desktops and profiles. An un-enrolled host with a live session remains a migration
blocker until the operator drains it; deployment never forces a logoff to conceal that limit.

Run the guest's read-only prerequisite check ahead of a maintenance window:

```powershell
.\Test-BrokerHostPrerequisites.ps1 -EnvironmentName <environment-name>
```

It uses ARM Run Command to inspect the applicable cgroup platform and, for the modern gate,
systemd version and each XRDP unit's
control-group/freezer state. It also rejects non-root, linked, or group/world-writable
`/usr`, `/usr/local`, and `/usr/local/bin` directories, without rewriting unrelated directory
permissions. It does **not** freeze, thaw, start, stop, or kill live services.
The applicable verified gate check is mandatory before actual migration stops apps or changes SQL/host state,
and again before host activation. `-DryRun` does not run guest commands; use the explicit
prerequisite command when remote read-only inspection is authorized. A failed preflight makes
no guest/service changes; pause the existing broker explicitly if the failed cutover must not
continue serving its old binaries.

A consistently frozen modern control group is reported but left untouched: it can be evidence of
interrupted cleanup. The root helper's durable `gateClosed` marker and guarded cleanup retry,
not deployment preflight, own thaw recovery. Unsupported, transitioning, missing, or conflicting
freezer state blocks activation. Cleanup is not acknowledged to SQL until both XRDP groups
have been thawed and verified running. Keep uncertain leases unavailable; never delete their
markers, clear the generation fence, or thaw services as a deployment shortcut.
On the legacy backend, `gateRestartRequired`/`gateTerminated` likewise belong to guarded
cleanup recovery. The enrollment installer refuses occupied/frozen freezer groups or an
unresolved wrapped service; it is not a general-purpose recovery/reset operation.
`gateBackend` and `gateBootId` are also durable recovery metadata, not deployment configuration.
Deployment preserves them unchanged. Only the core's guarded recovery can use a verified new
kernel boot to discard obsolete task state; deployment never edits a boot ID or replays a PID.
The helper itself checks gate readiness before provisioning or active-lease migration can
change an account/mount. Successful package installation alone is never gate readiness.

Every bootstrap and migration installs `broker-lease.py`, the shell entrypoints, the shared
release agent, watcher, and host-settings helper, with root ownership. The core wrappers select
**`/usr/local/libexec/linuxbroker/python3 -I`**, not whichever `python3` happens to be on PATH.
Deployment installs that private interpreter before running any broker helper.

[linux-python.lock.json](linux-python.lock.json) pins CPython **3.11.16**, build **20260901**,
baseline `x86_64-unknown-linux-gnu`, with a fixed SHA256. It is a
[python-build-standalone distribution](https://gregoryszorc.com/docs/python-build-standalone/main/running.html)
whose documented minimum glibc is **2.17**, including RHEL/CentOS 7. The standard-library
installer itself uses stock Python **3.6+** and no pip packages. It verifies the download hash,
rejects unsafe tar paths/links, installs a root-controlled immutable runtime version, tests the
required stdlib, then atomically selects it. It does not change system Python, alternatives,
PATH, yum/dnf, or the OS package database. Licenses shipped in the runtime archive are retained.

Set `linuxPythonRuntimeUri` only for an approved **byte-identical** HTTPS mirror; version/hash
remain pinned by the checked-in lock. No floating runtime version or unpinned pip install is
permitted. Required `jq`, `flock`, `findmnt`, the distro NFS mount helper, `ss`/iproute, procps, shadow account tools, and
checksum utilities are installed from the distro repositories when missing.

RHEL 7's stock `findmnt` does not support modern JSON/FSROOT introspection; installing the same
`util-linux` package is not a compatibility fix. The core lease helper now parses the stable
`/proc/self/mountinfo` ABI, preserving mount roots and kernel path escaping and refusing
stacked/nested mounts, visible-device mismatches, and incomplete/read-error state.
[Test-HostCompatibility.py](tests/Test-HostCompatibility.py) covers legacy RHEL7-format records,
RHEL8 optional fields, RHEL9/Ubuntu exports, escaped whitespace/backslashes, and safe-failure
cases without invoking `findmnt`. Package repositories/subscriptions must be available.
Host-side failures leave the environment paused rather than falling back to unsafe cleanup.

The existing NFS export, mount ownership, local account UID, and XRDP session must match the
reviewed mapping. No migration step recursively deletes a home/profile or changes its UID.

## Separate runtime database identity

Schema/mapping/host enrollment use `sqlAdminLogin` and `sqlAdminPassword` on the trusted
deployment connection. **The API must not use that administrator or a `db_owner` member.**
Preprovision generates/reuses a separate `sqlRuntimeLogin` (default `brokerapi`) and
`sqlRuntimePassword`. Both are preserved across reruns; never reuse the administrator's
password or add the deployment user to `BrokerApiRuntime`.

After applying all ordered SQL files through **`046`**, [Initialize-BrokerRuntimeDatabaseUser.ps1](Initialize-BrokerRuntimeDatabaseUser.ps1)
creates the contained database user through the deployment connection and assigns only
`BrokerApiRuntime`. A rerun may update the password only for an existing contained SQL user
already designated by that role, with no other role memberships, direct grants, or owned
schemas/objects. Conflicting users are rejected rather than silently repurposed or stripped of
unrelated permissions. Password/name values are SQL parameters; generated identifiers/literals
are quoted on the server, not interpolated into logged commands.

The script then opens a **separate connection using the runtime credentials** and checks the
effective SQL identity and permissions. It requires the runtime role and its allowed inventory
procedure while denying `db_owner`, database control, direct VM table updates, and all four
deployment-only procedures: `BindBrokerUser`, `RegisterBrokerHost`, `RegisterLinuxHostVm`, and
`GetBrokerLeaseMigrationState`. Failed isolation blocks activation.

Bicep and existing migration configure `DB_USERNAME=sqlRuntimeLogin` and keep
`DB_PASSWORD_NAME=db-password`; that Key Vault secret now holds **only the runtime password**.
Migration disables all superseded versions of this one secret because older versions can
contain the administrator credential and would otherwise remain readable by the API identity.
No other Key Vault secret is altered, and no secret value is printed or put into command-line
arguments. The administrator credential remains confined to protected deployment inputs.

The completed rollout receipt records runtime-isolation verification and the runtime username.
Checkout resume rejects old/unverified receipts or an API still configured with the deployment
administrator. Contained-user creation requires Azure SQL Database, or a properly configured
contained disposable SQL database for local integration verification.

## Explicit access selection

Copy [broker-access.example.json](broker-access.example.json) to a local `broker-access.json`
and replace **every** example ID with reviewed values:

```json
{
  "version": 1,
  "tenantId": "<tenant-guid>",
  "workspaceUserGroupIds": ["<existing-avd-user-security-group-object-id>"],
  "workspaceUserIds": [],
  "portalAdminGroupIds": ["<administrator-security-group-object-id>"],
  "portalAdminUserIds": []
}
```

Select the existing groups/direct users authorized to use your AVD application group, **not**
the legacy `avd-hosts-sg` / `linux-hosts-sg` managed-identity groups. No group is created to
represent all tenant users, and the deployment operator is not automatically made an admin.
The supplied tenant, GUIDs, enabled users, and security groups are checked against Graph.
Workload-containing groups are rejected. Nested-group app-role inheritance is not supported:
select the actual direct user groups or explicitly reviewed direct users.

For fresh AVD infrastructure, the same selected users/groups receive Desktop Virtualization User
on the desktop application group and VM User Login on the AVD VMs. Existing AVD RBAC assignments
are not broadly rewritten by migration; verify the selected existing access before cutover.
Assigning a broker role alone does not establish an AVD entitlement.

Direct users/groups previously assigned `AvdHost`, `LinuxHost`, or `ScheduledTask` must appear
in the reviewed workspace/admin selections. New user permissions are assigned **before** their
legacy permissions are retired. An unreviewed assignment blocks migration rather than silently
dropping a person or elevating them to administrator. Legacy VM groups may have their broker
role removed only when they contain no people; mixed groups require explicit operator cleanup.
The group objects and unrelated group memberships are not deleted.

### Workload permission propagation and token caches

**Graph assignment success is not effective runtime authorization.** Managed identity and
permission caches can retain tokens minted before a role or optional claim was present.
Restarting an agent, recreating an SDK credential, or requesting the same resource again
does not guarantee a fresh role-bearing token. Follow the target cloud's documented propagation
window; this can take hours. Do not decode an unverified JWT, use group membership as proof,
switch to an operator's token, or restore a legacy caller while waiting.

For an existing environment, stage direct roles and the API's `idtyp` optional claim **ahead of
the planned cutover**, allowing propagation before stopping services:

```powershell
.\Stage-BrokerWorkloadPermissions.ps1 -EnvironmentName <environment-name>
```

This narrow stage uses verified ARM identities and the existing API role IDs. It does not
modify user assignments, change role member types, enroll hosts from request bodies, mint API
tokens, or claim readiness. If the existing roles are mixed User/Application roles, they remain
unchanged until the coordinated migration safely moves reviewed users and makes workloads
application-only. The full migration is still mandatory.

Fresh Bicep sets `AzureWebJobs.ReturnReleasedVMs.Disabled`,
`AzureWebJobs.TestVMConnectivity.Disabled`, and `AzureWebJobs.ScalingVMs.Disabled` to `true`,
so their `run_on_startup` callbacks cannot mint premature API tokens. Linux bootstraps stage
disabled timers/watchers and never request a broker token. Cutover stops existing apps/agents
and explicitly disables scheduled callbacks before installing or starting the new images.
Intentional operator-disabled functions are preserved in an ignored local pending-workload
state file, including across failed migration reruns.

After direct role grants, trusted SQL enrollment, and secure API activation, deployment starts
the Function platform with **all scheduled callbacks still disabled** and performs actual
read-only operations:

| Workload context | Required successful operation |
| --- | --- |
| Each registered Linux VM, root-selected Python and its system-assigned IMDS identity | `GET /api/hosts/settings` returning a valid settings profile; API policy verifies the application role and registered VM binding. |
| The Function App's SCM command process, using its own `IDENTITY_ENDPOINT` and `IDENTITY_HEADER` | `GET /api/vms` returning the authorized scheduled-workload inventory. |

The in-process probe [Test-BrokerWorkloadAccess.py](Test-BrokerWorkloadAccess.py) holds tokens
only in memory, disables token-endpoint proxies and all redirects, validates HTTP success and
response shape, and emits only a fixed readiness marker. Neither tokens nor response bodies
are printed or returned to deployment. The SCM command requires `python3` and access to the
same app's platform identity endpoint; a restricted SCM environment that lacks those facilities
**blocks activation** and must be resolved, not bypassed with different credentials.

HTTP 401/403, missing identity endpoints, incomplete guest execution, or invalid API responses
leave scheduled functions disabled, stop the Function App, quiesce agent services, omit the
completed rollout receipt, and keep checkout paused. Retry the coordinated migration after
propagation/environment repair. Only successful real-operation probes permit timers/watchers
and intended scheduled callbacks to activate. Resume also rejects a changed scheduled identity
or an older receipt lacking workload-readiness evidence.

Set the local configuration path:

```powershell
Set-Location .\deploy
azd env set brokerAccessConfigPath (Resolve-Path .\broker-access.json).Path
```

## Existing profile ownership mapping

Copy [broker-user-mapping.example.json](broker-user-mapping.example.json) into a local
`broker-user-mapping.json`. Review it against the intended tenant user objects, SQL `VmUsers`,
the actual local UID, and NFS profile metadata:

```json
{
  "version": 1,
  "tenantId": "<tenant-guid>",
  "users": [
    {
      "objectId": "<immutable-entra-user-object-id>",
      "expectedUserPrincipalName": "reviewed.user@example.org",
      "username": "ExistingProfile",
      "uid": 10001
    }
  ]
}
```

The UPN is a **review cross-check**, never the source of a Linux name. If a UPN changes, update
that cross-check after review while preserving the same object ID, exact-case username, and UID.
New/recreated Entra objects cannot take an old binding. Existing broker names must match
`[A-Za-z_][A-Za-z0-9_-]{0,31}` and be non-reserved. **Dotted names are rejected explicitly**,
even though the native credential-response parser accepts them. They require a reviewed
compatibility decision; migration never silently strips dots or renames a profile.
UIDs must satisfy the SQL/helper contract (`2000..2147483646`, excluding reserved nobody IDs in
the deployment validator). Duplicate object IDs, names, or UIDs fail validation.

`Bind-BrokerUserMappings.ps1` calls the trusted parameterized
`dbo.BindBrokerUser(@TenantId,@ObjectId,@Username,@Uid)` in one transaction. SQL must accept the
existing name/UID and immutable binding; the script cannot overwrite a conflicting owner.
`-DryRun` executes the binding validation and rolls back. These procedures must already be
installed for that standalone SQL dry run.

`Register-LinuxHostSqlRecords.ps1` reads actual ARM VM resource IDs, computer names, private IPs,
tenant IDs, and system-assigned identity principal IDs. After the inventory record exists, it
calls `dbo.RegisterBrokerHost(@TenantId,@ObjectId,@Hostname,@ResourceId)`. No client request or
mapping-file host field can self-register a workload. Host-identity replacement with an
outstanding lease is deliberately blocked by SQL.

**SQL `046` intentionally deactivates prior hostname-only enrollments on first application.**
Every intended host must pass `RegisterLinuxHostVm` using the current verified ARM address,
then `RegisterBrokerHost` using that VM's actual identity/resource ID, in that order. Deployment
does this for **every host on every run**, even when its row and address appear unchanged.
Schema bootstrap/enrollment refuse to continue without the `046` trusted-receipt structures.

The receipt is bound to the exact current VMID, hostname, and IP. Deleting/recreating inventory
or changing its hostname/IP revokes trust transactionally; a portal administrator cannot regain
checkout readiness by reusing a hostname or setting Available/On/Reachable. Manual **Add VM**
remains a legitimate unowned inventory operation, but it does not enroll an endpoint.
`RegisterBrokerHost` alone cannot repair a changed record. Re-run the trusted ARM import and
enrollment path; do not edit the receipt table or grant the runtime user access to repair it.
Retired/replaced identities remain retired, while host-generation tombstones and profile
mappings are preserved.

Every existing SQL host record must reconcile with the tagged Linux ARM inventory in the
configured subscription/resource group. Missing tags, moved VMs, and retired/orphan records
block preflight; they cannot hide unresolved leases from migration. Review/retire obsolete
inventory explicitly rather than silently excluding it.

For **every** Linux host, migration then calls
`dbo.GetBrokerLeaseMigrationState(@Hostname)`, expecting either no active lease or exactly
`Username, Uid, LeaseId, LeaseGeneration`. Unresolved active owners or operations fail the
whole rollout. The root helper is invoked only with those validated values:

```text
/usr/local/bin/manage-lease.sh migrate <username> <uid> <lease-id> <generation>
```

Lease generations use positive **Int64**, bounded to the shared SQL/JSON exact-integer range
`1..9007199254740991`. SQL stores them as `BIGINT`; the native launcher uses Int64 rather than
Int32. Migration preserves values above Int32 unchanged, but rejects strings, fractions,
negative values, and anything beyond the SQL/helper ceiling without truncating or resetting
the concurrency fence. `VMID` remains Int32.

It verifies the account/profile and any existing marker under the host lock. Migration supports
matching legacy per-user UUID markers and reruns with a matching ready root `lease.json`.
An older active account without a structured/legacy marker can be migrated only from the
authoritative bound SQL values plus the helper's exact account-UID/NFS ownership checks; no
marker is fabricated from a caller's name. Unknown, conflicting, or interrupted markers are
not deleted or skipped.

For an idle SQL host, **a protected `phase=cleaned` marker is a durable fencing tombstone,
not stale residue**. `Test-BrokerIdleLease.py` first reads bounded candidate metadata without
printing the full marker or lease/operation IDs. Through the privileged deployment connection,
`Broker.IdleLease.ps1` verifies its case-exact username and UID against retained `VmUsers` and
reads the greater of the VM's generation and retained `BrokerHostGenerations.Generation`.
The tombstone generation must be **less than or equal to** that SQL fence; a later power
operation can legitimately have advanced SQL beyond the cleanup marker.

After installing the approved helpers, the private runtime rechecks the fingerprint and full
marker under the shared root lease lock. A valid tombstone requires a non-null operation UUID,
`gateClosed=false`, no corresponding local account or UID reuse, and no remaining mounted bind
home. It is left byte-for-byte unchanged. Ready/provisioning/cleanup markers, any legacy
`*.lease`, malformed or unprotected files, missing/conflicting retained mappings, a lower SQL
fence, or a marker changed during migration all block/quarantine the host. Outstanding SQL
operations still fail the frozen `GetBrokerLeaseMigrationState` call before this path.
The migration procedure's four-column response is unchanged.

An absent marker is handled separately and must remain absent through the locked recheck.
`lease.lock`, `reconcile.lock`, settings, and idle-warning files are not lease markers.
Raw bootstrap is still not an existing-host upgrade path; use the SQL-verified migration
for ordinary secure reruns after cleanup.
Unmatched live logind sessions and a guest hostname that differs from the trusted ARM
registration also block activation. The configured SSH administrator is never a workspace
mapping candidate.
Quarantine/repair ambiguous ownership through an explicit operator procedure; do not invent a
mapping or use an administrative password reset as a migration shortcut.

## Native bundle distribution

The supported post-provision step actually builds and distributes the native helper:

1. Invoke `avd_host\broker\Publish-Launcher.ps1 -Version <x.y.z> -OutputDirectory <local-path>`.
   It returns `BundlePath`, `Sha256`, `Version`, and `Runtime`. Local outputs are under
   `deploy\.artifacts\launcher\<version>`.
2. Upload the bundle into the provisioned private `broker-artifacts` container using the
   operator's Entra login. Blob names contain the version and SHA256.
3. Upload the checked-in installer under its own content hash and assign each AVD VM identity
   Storage Blob Data Reader at that container, not subscription/account write access.
4. Configure Windows Custom Script Extension **after staging**, with protected `fileUris` and
   `managedIdentity: {}`. The extension downloads both private files without secrets/SAS in a
   guest script. A small command verifies the installer's SHA256 before executing it; the
   installer independently verifies the bundle SHA256. Extension completion is checked, with
   bounded reruns for storage-RBAC propagation. Existing and new hosts follow the same path.

This use of managed identity is solely for artifact download, never broker checkout. It uses the
documented [Windows extension managed-identity support](https://learn.microsoft.com/azure/virtual-machines/extensions/custom-script-windows#property-managedidentity)
in extension version 1.10 or later. AVD hosts need their existing system-assigned identity.

There is no fictitious GitHub release URL, no unpinned PowerShell-only fallback, and no
Bicep extension that tries to install a bundle before it has been built/staged. Bicep applies
`broker-role=avd-host` tags to new VMs. Older VMs that lack those tags are discovered through
their configured host pool's registered ARM resource IDs, not guessed computer names.

For an independently reviewed prebuilt bundle:

```powershell
azd env set launcherVersion 1.0.0
azd env set launcherPackageUri https://your-approved-store.example/launcher-1.0.0-win-x64.zip
azd env set launcherPackageSha256 <64-hex-sha256>
```

All three values are required together. The prebuilt URI must be directly, anonymously
downloadable over HTTPS, without query strings, credentials, or redirects, and reachable from
every AVD VM. This alternative uses checked ARM Run Command and the same verified installer;
it does not embed a secret in guest-script logs. For a **private** prebuilt bundle, set
`launcherPackagePath` to a reviewed local zip instead; it is staged using the managed-identity
path above. No publication is performed merely by building or running the offline tests.

`Configure-AVD-Host.ps1` requires administrator/SYSTEM and 64-bit PowerShell. It verifies the
SHA256 **before extraction**, rejects traversal/duplicate/Windows alias/symlink entries,
checks self-contained/WAM dependencies, and refuses a package containing prefilled
`launcher.json`. The installation layout is:

```text
%ProgramFiles%\LinuxBroker\Connect-LinuxBroker.ps1
%ProgramFiles%\LinuxBroker\Launcher\<version>\Connect-LinuxBroker.ps1
%ProgramFiles%\LinuxBroker\Launcher\<version>\LinuxBroker.Launcher.exe
%ProgramFiles%\LinuxBroker\Launcher\<version>\launcher.json
```

Only SYSTEM/Administrators can write the installation; ordinary users have read/execute
access. Directory junctions/reparse paths are refused. Existing versions are immutable:
the same version must have the same package digest and installed files. Use a new version
for changed binaries. A stable wrapper and public **Linux Broker** desktop shortcut preserve
`Connect-LinuxBroker.ps1 -Mode desktop`. Repoint any independently configured RemoteApps or
old pinned `C:\Temp` shortcuts to the supported entrypoint. Old machine-token clients fail
closed even if an old shortcut remains.

The installer writes only this nonsecret sibling configuration:

```json
{
  "tenantId": "<tenant-guid>",
  "authorityHost": "https://login.microsoftonline.com",
  "clientId": "<native-launcher-client-guid>",
  "apiClientId": "<api-client-guid>",
  "apiBaseUrl": "https://your-api.example/api"
}
```

Tokens, passwords, client secrets, and user/profile selectors do not belong in this file.

## Fresh deployment

```powershell
Set-Location .\deploy
azd auth login
az login
azd env new <environment-name>
azd env set appName linuxbroker
azd env set AZURE_LOCATION <region>
azd env set brokerAccessConfigPath (Resolve-Path .\broker-access.json).Path
azd env set deployLinuxHosts true
azd env set deployAvdHosts true
azd env set linuxHostCount 2
azd env set avdSessionHostCount 1
azd env set launcherVersion 1.0.0
azd up
```

Preprovision creates/reuses the three applications and selected assignments, configures cloud
endpoints, preserves/generates complete SSH keys and deployment secrets, and writes the local
parameter file. It refuses to silently use this greenfield path against an existing API.
After an interrupted provision that already created apps, use the coordinated migration path.
An existing environment with no profiles still supplies a reviewed mapping with `"users":[]`.

Bicep creates ACR, SQL, Key Vault, storage, observability/network resources, apps, and optionally
the VM fleets. Preprovision computes `linuxAgentFileHashes` from the approved checkout's
LF/UTF-8 bootstrap and helper sources. The Linux extension downloads the selected distro
bootstrap and all required shell/Python files, then validates **all** SHA256 hashes before
running any bootstrap code. A stale mirror or changed shared helper fails provisioning, not
an eventual user checkout. Bootstrap installs from that verified stage as root:root, `0755`,
and does not redownload an unpinned helper later.

Linux bootstrap stages root helpers and disabled agent services; it cannot
reconcile against an unbound or not-yet-deployed API. Post-provision performs the coordinated
sequence below. Its container tags are unique to the secured rollout, not an unverified old
`latest` tag. Bicep references the unique upcoming tag, so no broker container is expected to
serve traffic until post-provision builds and pins the secured images. It cannot briefly start
an old `latest` API that ignores the checkout-pause setting.

## Existing deployment and cutover

Back up SQL and profile metadata and review the user, UID, lease, host-identity, AVD, and
administrator inventories first. Keep the reviewed files outside version control.

```powershell
Set-Location .\deploy
azd env set brokerAccessConfigPath (Resolve-Path .\broker-access.json).Path
azd env set brokerUserMappingPath (Resolve-Path .\broker-user-mapping.json).Path

.\Migrate-ExistingEnvironment.ps1 -EnvironmentName <environment-name> -DryRun
.\Migrate-ExistingEnvironment.ps1 -EnvironmentName <environment-name>
```

The dry run validates input/Graph/ARM and, if the binding schema is installed, tests mappings in
a rolled-back SQL transaction. It reports when schema/guest checks remain outstanding. It
does not install schema, stop apps, grant permissions, upload packages, or run guest commands.

The actual fresh/existing post-provision sequence is:

1. Verify host systemd/cgroup/XRDP freezer prerequisites without changing service state, then
   stop the API, maintenance worker, and portal; persist `BROKER_CHECKOUT_ENABLED=false`.
   An old API ignores that setting, so stopping it is mandatory during legacy cutover.
2. Quiesce release timers/watchers and exact legacy agent processes, without terminating RDP
   sessions or modifying profiles. Invalidate the previous rollout receipt.
3. Stage application/assignment changes, ordered additive SQL, the isolated runtime database
   user and secret, Graph-verified user bindings, trusted ARM host registration, direct
   workload roles, and the native artifact.
4. Verify every host's SQL lease state. Install the version-matched **local checkout's** Linux
   helpers and migrate root markers. Services remain stopped. Migrations no longer fetch an
   unrelated moving GitHub `main` agent revision.
5. Build/pin the secured API, administrator portal, and maintenance images; install the
   verified native bundle on the entire AVD inventory.
6. Start the secured API/portal with checkout still paused and require health readiness. Start
   the Function platform with callbacks disabled, verify allowed operations from the actual
   Function and Linux managed identities, then activate compatible agents and intended
   scheduled callbacks. Write a nonsecret local rollout receipt only after those probes succeed.
7. Validate the controlled pilot and explicitly resume checkout.

There are no `SkipPostProvision` / `SkipLinuxHostReleaseAgentMigration` shortcuts. Standalone
helpers are available for diagnostics, but a partial upgrade cannot produce the receipt needed
to resume. Known errors, missing identities, missing hosts, unknown owners, and guest failures
are blockers, not successful skips. No rollback automatically reenables a legacy component.

All distributions install the guarded Python helper and shared release agent. Sudo permits only
`create-user.sh *`, `manage-lease.sh cleanup *`, and `apply-host-settings.sh ""` (no argv,
settings on stdin); it does not permit
raw `userdel`, password tools, mounts, filesystem writes, or deployment-only `migrate`.
Existing settings profiles are preserved rather than reseeded. Optional idle detection and
screen-lock behavior remain controlled by the fleet settings profile.

## Pausing, resuming, and recovery

```powershell
.\Set-BrokerCheckoutState.ps1 -EnvironmentName <environment-name> -State Paused
.\Set-BrokerCheckoutState.ps1 -EnvironmentName <environment-name> -State Enabled -SecuredRolloutValidated
```

Resume requires a completed version-1 rollout receipt, matching tenant/client settings, matching
pinned secured images, and the same verified ARM host identities/inventory. It never changes
authorization rules. A pause against an unverified/legacy image stops the API/worker because
those binaries might ignore the new setting.
Resume additionally runs the read-only **ready** gate check on the current Linux inventory.
Both backends must pass the installed helper's `gate-status`; a frozen modern group is not
treated as ready merely because it can be safely inspected. Missing helpers, changed controller
capabilities, or pending thaw recovery block enabling checkout without changing service state.
The receipt must also record `046` trusted-inventory enrollment. Resume repeats the actual
LinuxHost settings and ScheduledTask inventory authorization probes, so a later SQL migration,
endpoint edit, or deleted/recreated inventory cannot be hidden by an old successful receipt.
Failed host trust must be repaired through the verified ARM import/enrollment, never a fallback.

Pilot with at least two ordinary users sharing a pooled AVD host, an administrator who has
both independent permissions, and an unassigned user. Confirm no portal access for ordinary
users, no admin credential checkout, correct scoped Credential Manager entries, account-switch
behavior, disconnect/reconnect without application loss, the configured grace boundary, stale
lease/host denial, and unchanged NFS sentinel data/ownership after cleanup. Use only authorized
test accounts/profiles, not live customer profiles.

If a step fails, keep checkout paused and fix forward using compatible secured components.
Do not restore the vulnerable API/launcher, a scope-or-group bypass, username-only checkout,
or hostname-only release. Retain uncertain leases as unavailable. A failed mapping does not
authorize profile renaming, UID changes, or marker deletion. Review the concrete SQL/guest
failure with the operator, repair the authoritative state, and rerun the idempotent sequence.
The old RDP session can continue where its identity/profile can be verified.

## Cloud and configuration reference

| Setting | Purpose |
| --- | --- |
| `tenantId` / runtime `TENANT_ID` | One authoritative tenant for API, portal, launcher, and trusted bindings. |
| `apiClientId` / API runtime `CLIENT_ID` | Broker token audience, also supplied as native `apiClientId`. |
| `frontendClientId` / API runtime `PORTAL_CLIENT_ID` | Only intended delegated management client. |
| `brokerLauncherClientId` / API runtime `BROKER_LAUNCHER_CLIENT_ID` | Only intended delegated checkout client. |
| `azureAuthorityHost` / `AZURE_AUTHORITY_HOST` | Cloud login authority, also supplied to native configuration. |
| `brokerCheckoutEnabled` / `BROKER_CHECKOUT_ENABLED` | False pauses checkout only. Pre/post-provision always set false. |
| `containerImageTag` | Generated unique secured rollout tag. An old mutable `latest` tag is never used during provisioning. |
| `brokerAccessConfigPath`, `brokerUserMappingPath` | Reviewed operator inputs; never caller-supplied runtime identity. |
| `launcherVersion`, `launcherPackageUri`, `launcherPackageSha256`, `launcherPackagePath` | Versioned native build or reviewed prebuilt artifact. |
| `storageAccountName` | Provisioned private artifact staging account. Older deployments resolve it from the function's existing storage configuration without printing that connection string; otherwise set it explicitly. |
| `avdHostPoolName` | Existing untagged AVD hosts are resolved through this actual host pool. |
| `vmHostResourceGroup`, `vmSubscriptionId` | Trusted Linux inventory scope; defaults to the deployment subscription/group. |
| `linuxHostSshPublicKey`, `linuxHostSshPrivateKey` | Matching broker SSH keys. Private key is stored as the `linux-host` Key Vault secret. |
| `sqlAdminLogin`, `sqlAdminPassword`, `sqlDatabaseName` | Trusted schema/mapping deployment connection only; never the API runtime credentials. |
| `sqlRuntimeLogin`, `sqlRuntimePassword` | Dedicated contained `BrokerApiRuntime` SQL user; API username and `db-password` secret. |
| `linuxHostAdminLoginName` | Root-helper sudo identity, default `avdadmin`; propagated to every bootstrap/migration. |
| `linuxAgentFileHashes` | Preprovision-generated source-relative SHA256 map for all distro bootstraps and Linux helpers. Required for new Linux VMs. |
| `linuxPythonRuntimeUri` | Optional byte-identical mirror of the CPython archive pinned in `linux-python.lock.json`; system Python is not replaced. |
| `domainName`, `nfsShare` | Existing Linux/NFS configuration; do not change profile ownership during authorization cutover. |
| `linuxHostDisableScreenLock` | Initial RHEL screen-lock posture. Existing fleet profiles are preserved on migration. |
| `appServicePlanSku` | App Service plan default `P2mv3`; confirm regional/cloud availability. |

`AzurePublic` and `AzureUSGovernment` profiles retain their Graph and App Service endpoints:

| Cloud | Deployment Graph | App Service suffix |
| --- | --- | --- |
| `AzurePublic` | `https://graph.microsoft.com` | `azurewebsites.net` |
| `AzureUSGovernment` | `https://graph.microsoft.us` | `azurewebsites.us` |

The authority defaults to the selected Azure CLI/ARM cloud login endpoint. API legacy STS
issuer configuration remains explicit. `AzureCustom` requires `graphEndpoint`,
`appServiceDomain`, `stsIssuerHost`, and an appropriate `azureAuthorityHost`. Select/register
the matching Azure CLI cloud before deployment. Storage and registry endpoints are read from
actual resource metadata rather than hardcoded commercial DNS suffixes.

`scriptSourceRoot` controls **fresh bootstrap** downloads. In production use the matching
immutable release/commit or a trusted reachable mirror preserving the repository layout,
including `broker-lease.py` and `release-session-common.sh`. Downloaded bytes must match the
preprovision-generated hashes; the mirror must preserve LF/UTF-8 source bytes. The `{}` value
in the manual parameter example is not a usable hash manifest: use preprovision, or obtain the
map with `Get-BrokerLinuxArtifactHashes` from the exact approved checkout. Raw distro scripts
are no longer an unverified download entrypoint; they require the extension's verified local
stage through `LINUXBROKER_LOCAL_AGENT_DIRECTORY`.

Existing-agent migration instead
ships the reviewed local checkout through checked ARM Run Command. Cloud/SKU/AVD/WAM and OS
availability must be verified in the intended environment.

Local migration staging normalizes CRLF to LF before endpoint substitution and UTF-8
encoding. The resulting single byte array supplies both the payload's SHA256 and its base64
transport; the guest verifies that exact digest before installing the decoded bytes. This also
protects preexisting Windows checkouts that have not yet reapplied the repository LF attributes.

The complete parameter chain and checked-in generated ARM template are under `bicep\`.
[main.parameters.example.json](bicep/main.parameters.example.json) contains no actual secrets.
Native artifact installation is deliberately post-provision; it is not hidden in an early VM
extension or a nonexistent hosted release.

## Offline validation

From the repository root:

```powershell
pwsh -NoProfile -File .\deploy\tests\Test-Deployment.ps1
pwsh -NoProfile -File .\deploy\tests\Test-DatabaseRuntime.ps1
pwsh -NoProfile -File .\deploy\tests\Test-IdleLease.ps1
pwsh -NoProfile -File .\deploy\tests\Test-HostRegistration.ps1
python .\deploy\tests\Test-HostCompatibility.py
python .\deploy\tests\Test-IdleLease.py
python .\deploy\tests\Test-HostPrerequisites.py
python .\deploy\tests\Test-LegacyGateEnrollment.py
python .\deploy\tests\Test-WorkloadReadiness.py
az bicep build --file .\deploy\bicep\main.bicep --outfile .\deploy\bicep\main.json
```

Invoke these Python files explicitly. `unittest discover -p 'Test-*.py'` can silently run
**zero tests** because the hyphenated filenames are not importable discovery identifiers;
an exit code of zero from such discovery is not validation evidence. `Test-PrivateRuntime.py`
is a separate archive-validation CLI requiring `--archive`, not a unittest-discovery module.

The regression harness parses deployment/installer PowerShell and mocks Azure/Graph/VM
boundaries. It covers role/scope separation, manifest preservation, repeat/interrupted
assignment updates, reviewed mapping rejection, retired machine authority, guest completion,
archive integrity/traversal checks, cloud/audience propagation, and fresh/existing ordering.
Workload tests additionally reject cached role-less tokens, failed actual operations, missing
platform identity, wrong response shapes, and attempts to use token claims as readiness proof.
The main PowerShell entrypoint also invokes `Test-DatabaseRuntime.ps1`, `Test-IdleLease.ps1`, `Test-HostRegistration.ps1`,
`Test-LegacyGateEnrollment.py`, and `Test-HostPrerequisites.py`, so guarded-user,
SQL permission, secret transport, and superseded-secret-version checks run in the existing
deployment CI entrypoint alongside retained identity/fence and both-backend gate checks without
a root CI change. This test entrypoint requires Python 3.9+ and Bash in addition to PowerShell;
it uses only standard libraries and synthetic service/cgroup fixtures.
SQL and Key Vault boundaries are mocked;
the deployment script itself verifies effective permissions using the real contained-user
connection before activation.

Freezer prerequisite tests use synthetic cgroup files and a systemctl stub that rejects every
mutating command; they never freeze/thaw or stop a real service.
Legacy enrollment tests separately stub all service/process operations, asserting an explicit
drain requirement, unchanged active leases and terminal markers, preserved original startup
arguments, no PID adoption/freezer writes, read-only idempotent reruns, and no start after a
failed post-stop recheck. Actual RHEL/Ubuntu kernel/XRDP validation still requires the authorized
pilot; these tests are not evidence of a production drain or service restart.
These checks make no live deployment or publication. Native publisher tests, real SQL
concurrency, per-distro helper tests, and the authorized SSO/RDP/NFS pilot remain separate
requirements; mocks do not substitute for them.

`tests\Test-PrivateRuntime.py --archive <local-locked-tar.gz>` can additionally run on local
Linux x86_64 (including WSL) with `readelf`: it verifies the archive hash, executes the extracted
interpreter and required stdlib, and checks every ELF object's referenced glibc symbols against
the RHEL7 2.17 baseline. It extracts only into a temporary deployment-artifact child and neither
installs a system runtime nor changes the broker selector.
For a Windows checkout mounted into WSL, use `--staging-parent` pointing to a native
case-sensitive Linux temporary directory; the runtime includes case-distinct terminfo files
that cannot be extracted faithfully onto ordinary case-insensitive NTFS.
