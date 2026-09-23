# Broker SQL schema and lifecycle contracts

Apply numbered SQL files in filename order to the selected database. No script contains `USE` or an embedded connection string. `deploy\Initialize-Database.ps1` splits `GO` batches, converts legacy `CREATE PROCEDURE`/`ALTER PROCEDURE` declarations to `CREATE OR ALTER`, and fails on SQL errors. The post-provision hooks also maintain inventory through `RegisterLinuxHostVm`.

Do not apply an incomplete subset while serving traffic. Earlier migrations retain their historical definitions; 040-046 are the final authorization/lifecycle definitions. Pause checkouts during coordinated migration and complete the entire ordered sequence before activating the new API/agents.

## Additive migrations

| Migration | Purpose |
| --- | --- |
| 001-039 | Existing VM, UID catalog, settings, scaling, temporal history and pagination objects |
| `040_add_broker_identity_and_operations.sql` | Bound subjects, lease owners/generations, separate disconnect clock, host registry, operation ledger, persistent host generation counters and transactional state lock |
| `041_create_broker_identity_procedures.sql` | Operator bindings, race-safe new identity allocation, immutable mapping trigger and active-lease migration preflight |
| `042_create_guarded_broker_lease_operations.sql` | Guarded checkout, observation, cleanup, completion/failure and retry candidates; disable unsafe legacy mutations |
| `043_guard_vm_management_and_scaling.sql` | Unowned-only manual mutations, durable power reservations and lease-safe scaling |
| `044_expose_guarded_lease_inventory.sql` | Management generation/operation metadata, matching ready-count predicates and paged lease history |
| `045_define_broker_runtime_permissions.sql` | Least-privilege `BrokerApiRuntime` role; deployment-only binding procedures are not runtime operations |
| `046_bind_host_enrollment_to_verified_inventory.sql` | Exact VM-record/address import receipts, atomic enrollment revocation on delete/endpoint change, and deployment-only re-enrollment |

These additions are rerunnable. Temporal versioning remains enabled and propagates the added VM columns into history. Existing username, UID, profile key and lease identifiers are not renamed. Duplicate hostnames fail 040 explicitly; do not choose an arbitrary duplicate or silently omit the uniqueness guarantee.

`VmUsers` permanently retains each username/UID and any established `(TenantId,ObjectId)` binding. A deleted/recreated Entra account is a new identity, not the old profile's owner. `BrokerHosts` binds a verified managed-identity subject to a hostname and ARM resource, retaining retired identities. `BrokerTenant` pins the tenant from the first approved user/host binding; it must match the API's `TENANT_ID`.

## Trusted deployment interfaces

Use a separate trusted deployment SQL connection. These procedures are not exposed as HTTP self-registration or user-profile claiming endpoints.

### `BindBrokerUser(TenantId, ObjectId, Username, Uid)`

Supply an operator-reviewed identity mapping, including the **existing** `VmUsers.username` and numeric `uid`. This validates tenant consistency, UUIDs, Linux-safe non-reserved names, exact stored username/UID, existing binding conflicts and conflicting legacy assignments. It binds the reviewed active assignment to that immutable owner and preserves its lease ID (creating one only if the approved legacy assignment lacked one). Active lease generations start at 1.

Bindings are idempotent only when every identity/profile field agrees. Existing mappings cannot be renamed, re-UIDed, transferred or deleted. Do not infer ownership from UPNs, email, display names, sanitized Windows names, or a matching profile directory.

UIDs must be in `2000..2147483646` excluding reserved `65534`/`65535`. The transactional allocator skips both, including when resolving name collisions. A bound-user schema constraint and binding validation reject them. Unbound legacy records may remain for operator investigation, but they cannot be claimed, renamed or automatically re-UIDed to bypass the restriction.

Bind all returning users before enabling checkout. Unbound inactive legacy profiles are never automatically claimed, but issuing a genuinely new mapping before reviewing a returning user's old profile would create a different immutable mapping and block a later conflicting bind.

### `RegisterBrokerHost(TenantId, ObjectId, Hostname, ResourceId)`

First register inventory with `RegisterLinuxHostVm(Hostname,IPAddress,Description)`, then bind the verified ARM-managed identity with this procedure. Runtime requests cannot self-register or change this binding.

Migration 046 records each trusted inventory import in `BrokerHostInventory`, binding its exact `VMID`, hostname and address. `RegisterBrokerHost` requires that receipt to match the current inventory row before it can activate a host. The frozen four-argument identity-registration interface is unchanged; call the existing inventory-import procedure first with the address verified from ARM, never one accepted from portal input.

`InvalidateBrokerHostInventory` revokes active enrollment and removes the receipt in the same transaction whenever a VM row is deleted or its hostname/address changes. An endpoint cannot change while a lease/power operation is in progress. Manual re-addition under the same hostname, even with the original address, cannot inherit enrollment; returning a changed address to its old value also cannot recreate a receipt.

For legitimate re-enrollment, import the correct ARM inventory again, then call `RegisterBrokerHost` with the verified principal/resource. The same non-retired principal can reactivate that newly verified record. Identity replacement still requires no outstanding lease and permanently retires the old principal; invalidating an endpoint does not by itself retire the unchanged identity. Runtime `BrokerApiRuntime` is explicitly denied both import and enrollment procedures and has no direct table mutation authority.

**First application of 046 is fail-closed:** existing hostname-only active registrations are deactivated, not automatically trusted or backfilled from mutable inventory. Previously inactive/retired identities remain retired. Re-import and re-enroll all intended ARM hosts during the paused cutover before readiness checks or resume. User/profile mappings, owned leases and monotonic `BrokerHostGenerations` are untouched. Reapplying the completed migration preserves valid verified enrollments.

The host name and resource path must agree and neither a principal nor a resource can be transferred to another hostname. A verified identity replacement for the **same** ARM resource is allowed only when the old host has no outstanding assignment or operation; the old subject is retired. Resolve active leases first rather than making a replacement identity implicitly own unknown state.

### `GetBrokerLeaseMigrationState(Hostname)`

Returns no rows for an unassigned host; otherwise returns exactly:

```text
Username, Uid, LeaseId, LeaseGeneration
```

An active/unresolved/conflicting owner, missing mapping/lease, inconsistent status, or operation in progress throws an error. Unknown hosts also fail. Deployment must not silently skip that failure. For a returned row, install version-matched helpers and run the root-only contract:

```text
sudo /usr/local/bin/manage-lease.sh migrate <username> <uid> <lease-id> <generation>
```

The host validates the actual account UID and NFS home plus any legacy/current marker before atomically recording the approved lease. No account creation, reownership or profile renaming occurs during migration.

## Runtime procedure interfaces

All data arguments are bound parameters. The API commits each reservation before contacting a host or Azure; no SQL transaction spans remote work.

| Procedure | Inputs and result |
| --- | --- |
| `GetBrokerHost` | `TenantId,ObjectId`; returns only a registered active hostname |
| `BeginBrokerCheckout` | `TenantId,ObjectId,AvdHost`; on `Outcome=Ok`, returns VM/username/UID/lease/generation/operation and `NewAllocation` |
| `ObserveBrokerSession` | `Hostname,LeaseId,LeaseGeneration,State`; state is `active`, `disconnected`, or `logged_off`; returns only an outcome |
| `BeginBrokerCleanup` | `ExpectedLeaseId,ExpectedLeaseGeneration,Reason,ActorTenantId,ActorObjectId`, and exactly one of `VMID`/`Hostname`; returns reserved host/user/UID/lease/generation/operation |
| `CompleteBrokerOperation` | `VMID,OperationId,LeaseGeneration,Outcome`; compare-and-set finalization only |
| `FailBrokerOperation` | `VMID,OperationId,LeaseGeneration,ErrorCode`; preserves the assignment/reservation and records a fixed non-secret failure code |
| `ReturnReleasedVms` | No inputs; returns at most 20 eligible/retryable candidates, **never clears an assignment** |
| `TriggerScalingLogic` | `ActorTenantId,ActorObjectId`; returns fenced `PowerOn`/`PowerOff` reservations, not completed power changes |

`ResolveBrokerUser` is used inside checkout. It serializes subject/name/UID allocation and skips names already present in the legacy catalog; it cannot claim an unbound profile. `LockBrokerState` and `AdvanceBrokerGeneration` are internal helpers. The transaction-owned application lock serializes short state mutations across all API workers; unique subject/owner indexes are additional database invariants.

### States, clocks and fencing

Public `VmStatus` stays `Available`, `CheckedOut`, `Released`, or `Maintenance`. Internal operation state is `Running`, `Failed`, `Completed`, or `Superseded`. Provisioning/reclamation retain the owner and are never allocatable.

Each reservation increments the host's generation and records a distinct operation ID. Reconnect retains the same lease ID, username, UID and owner. `BrokerHostGenerations` keeps the counter even if an unowned inventory row is deleted/recreated; never reset this table or a host marker to make a stale operation pass.

Generations remain `BIGINT` in storage, with a shared JSON-safe maximum of `9007199254740991`; 0 is reserved for unassigned inventory/counter initialization. Schema constraints reject out-of-range stored values, and advancement explicitly fails on exhaustion before arithmetic or mutation. Exhausted unowned hosts are not ready or eligible for new scaling reservations. Migration refuses inconsistent existing counters rather than clamping them or weakening fencing.

First disconnect sets `DisconnectedAt` once. Repeated disconnects and unrelated health/settings updates do not move it. Active observations restore `CheckedOut` and clear it. Expiry uses the singleton global `GracePeriodSeconds` (seeded 1200, permitted 60-86400) and is eligible at or beyond the boundary. No cleanup uses `LastUpdateDate` or a fixed 30-minute rule.

Cleanup reasons are `expired`, `logged_off`, and `admin`. The host must recheck actual XRDP state behind its reconnect gate and acknowledge the matching generation/operation before SQL can clear anything. An active session cancels expiry/logoff cleanup. A logoff observation racing a surviving disconnected desktop is deferred to the normal grace period.

Failed cleanup remains owned and appears in the maintenance retry candidates. Failed provisioning can be retried by that same subject or cleaned up by an administrator. An abandoned running operation is retryable only after 300 seconds, with a new generation; it is not made available on timeout. Old operation completion/failure cannot alter a newer lease.

`CheckoutVm`, `ReturnVm`, and `ReleaseVm` deliberately throw instead of supporting username-only, hostname-only, or unguarded legacy callers. Administrative return/release go through the new API with required lease ID and generation.

### Management and scaling

Manual inventory creation allows only unassigned `Available`/`Maintenance` hosts and does **not** make them trusted or checkout-eligible. An operator must perform trusted ARM inventory import and managed-identity enrollment before use. Manual power/status changes and deletion reject any owner, username, lease or operation. Health updates cannot change assignment state or disconnect time. Deleting inventory revokes its host enrollment but preserves generation tombstones and immutable username/UID mappings.

Scaling reserves only unowned registered hosts and includes outstanding power intentions in its capacity calculation. Occupied/released hosts count as in use. No power-on path overwrites `VmStatus` or a lease. SQL power completion follows confirmed Azure completion and sets reachability to `Unreachable` until the normal probe confirms it. `GetVmSummary.Ready` matches checkout's full registered/unowned/no-operation predicate.

## Runtime permissions

Provision a dedicated database user for the API, assign it to `BrokerApiRuntime`, and use that user's credential for `DB_USERNAME`/the configured Key Vault password secret. Do not use the deployment administrator as the runtime login or also grant runtime `db_owner`, schema-wide DML, or binding privileges.

Migration 045 grants the API's actual stored procedures, not arbitrary table access. It explicitly denies runtime execution of `BindBrokerUser`, `RegisterBrokerHost`, `RegisterLinuxHostVm`, and `GetBrokerLeaseMigrationState`. The trusted deployment connection must not be a member of the runtime role.

## Disposable validation

### Windows LocalDB

Use an already-running, separately owned instance named `LinuxBrokerAuth_<unique-suffix>` and an initially empty, dedicated database named `LinuxBrokerAuthorizationTests_<unique-suffix>`:

```powershell
.\sql_queries\tests\Run-LocalDbIntegration.ps1 `
    -InstanceName LinuxBrokerAuth_fa1a4bc7 `
    -DatabaseName LinuxBrokerAuthorizationTests_fa1a4bc7
```

The harness uses `System.Data.SqlClient`, integrated Windows authentication and the exact instance's existing local named pipe. Pinning the pipe prevents an implicit LocalDB start. It refuses default instance names, stopped instances, remote SQL endpoints and non-test database names. The parent/CI setup owns instance/database creation, startup and deletion; the harness does none of those and never changes Docker Desktop.

**Only the supplied database is used**, including runtime identification; there is no connection to `master` or another database. The harness first requires an empty database and records an instance/database-specific extended-property ownership marker. It resets only that marked test schema between cases, including disabling temporal versioning before dropping test tables. The marker permits intentional reruns after a failed case without adopting a nonempty application database. Reserve this database exclusively for the harness. Its final test state is left for parent/CI cleanup or inspection.

`SqlLocalDbExe` defaults to the SQL Server 2019 LocalDB tooling path under `C:\Program Files\Microsoft SQL Server\150\Tools\Binn`; pass that parameter if Windows CI installs it elsewhere. Use PowerShell 7.4+ (matching deployment); no Python packages or Pester modules are needed for this harness. `-Case fresh` or another validated case name can select a focused scenario while fixing a failure; omit `-Case` in CI to run the full suite.

Concurrency tests open independent asynchronous SqlClient connections, hold the actual `LockBrokerState` application lock, verify through SQL lock DMVs that **every** contender is waiting, and then release them together. This exercises genuine competing SQL transactions rather than only sequential calls or source checks. A successful run reports both executed case and synchronized race counts.

The Windows `idle-tombstone-evidence` case imports the deployment's actual `Get-BrokerIdleLeaseEvidence` reader and executes its parameterized query against this database, without invoking Azure or host inspection. It verifies the exact username/UID, retained fence after inventory recreation, rerunnable fingerprint-only evidence, and rejection of future generations or occupied/in-progress hosts.

### Linux Docker / Python

From the repository root, with the API's declared `pymssql` dependency installed:

```powershell
python -m sql_queries.tests.run_sql_integration --docker
```

The harness refuses remote Docker endpoints and accepts no external SQL connection string. It creates its own local SQL Server 2022 container bound only to loopback, chooses random test-only credentials/databases, applies every real script, opens independent SQL connections for races, and removes only its owned test container/databases.

Coverage includes fresh install/rerun/temporal history, approved legacy bindings, immutable UID/name allocation, simultaneous same/different-owner checkouts, failed reconnect, release/reconnect/grace boundaries, return/checkout races, stale completion, cleanup retries, the 300-second abandoned-operation boundary, cleanup cancellation, manual-state guards, power-on/off scaling, host-generation continuity and actual runtime-role permission denials. Endpoint-binding cases execute the runtime delete/re-add attacker-IP path, verify denial, reject runtime attempts to repair registration, prove legitimate trusted re-enrollment, exercise endpoint-change rollback and delete/checkout races, and verify fail-closed upgrade without changing active leases or profile identifiers.

An absent Docker engine or a stopped/missing isolated LocalDB instance produces an explicit failure rather than a passing or silently skipped test. Python/PowerShell parsing or source-text inspection is **not** evidence that transactions passed. Actual XRDP/NFS/SSO compatibility still requires the separately authorized deployment pilot, not tests against live profiles.
