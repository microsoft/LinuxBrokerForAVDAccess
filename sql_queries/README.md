## Database Setup and SQL Procedures

This folder contains the SQL schema and stored procedure scripts used by the Linux Broker for AVD Access solution.

The primary deployment path is now automated through the deployment hooks under `deploy/`, not manual `sqlcmd` execution. This document describes both paths:

- the supported automated path used by `azd up`
- the manual fallback path when you need to apply or verify scripts yourself

For the full deployment workflow around these SQL scripts, see [../deploy/DEPLOYMENT.md](../deploy/DEPLOYMENT.md).

## Current Deployment Model

### Primary path: automated SQL bootstrap

The supported deployment flow runs the SQL scripts automatically during `postprovision`.

The sequence is:

1. [../deploy/Post-Provision.ps1](../deploy/Post-Provision.ps1) runs after infrastructure provisioning.
2. That script calls [../deploy/Initialize-Database.ps1](../deploy/Initialize-Database.ps1).
3. `Initialize-Database.ps1` loads every `*.sql` file in this folder, sorts them by filename, and applies them in order.
4. After the schema and procedures are in place, [../deploy/Register-LinuxHostSqlRecords.ps1](../deploy/Register-LinuxHostSqlRecords.ps1) registers Linux hosts into `dbo.VirtualMachines`.

The automated bootstrap has a few important behaviors:

- It connects to Azure SQL with ADO.NET from the machine running `azd up`.
- It splits scripts on `GO` batch separators.
- It rewrites `CREATE PROCEDURE` and `ALTER PROCEDURE` to `CREATE OR ALTER PROCEDURE` before execution so reruns work cleanly.
- It now fails on SQL errors instead of silently continuing.
- It can be skipped only by setting `SKIP_SQL_BOOTSTRAP=true`.

### Secondary path: manual execution

Manual execution is still available when you want to inspect or repair the database outside the azd workflow.

Use that path when you need to:

- validate objects in an existing environment
- replay the scripts after a partial failure
- troubleshoot SQL connectivity or permissions
- apply the schema without running the full deployment flow

## Objects In This Folder

### Tables

- `001_create_table-vm_scaling_rules.sql`: creates `dbo.VmScalingRules`
- `002_create_table-vm_scaling_activity_log.sql`: creates `dbo.VmScalingActivityLog`
- `003_create_table-virtual_machines.sql`: creates `dbo.VirtualMachines`
- `024_create_table-vmusers.sql`: creates `dbo.VmUsers`
- `026_add_lease_id_to_virtual_machines.sql`: adds `LeaseId` to `dbo.VirtualMachines` for lease-aware checkout and cleanup
- `027_add_unique_index-virtual_machines_hostname.sql`: enforces `Hostname` uniqueness on `dbo.VirtualMachines`
- `028_create_table-linux_host_settings.sql`: creates `dbo.LinuxHostSettings` and seeds the single global profile
- `029_add_settings_tracking_to_virtual_machines.sql`: adds `SettingsVersion` and `SettingsAppliedDate` to `dbo.VirtualMachines` so settings drift is visible
- `067_create_table-audit_log.sql`: creates `dbo.AuditLog`
- `072_add_drain_requested_to_virtual_machines.sql`: adds the drain flag to `dbo.VirtualMachines`
- `083_create_table-host_heartbeats.sql`: creates `dbo.HostHeartbeats`
- `088_add_assignment_dates_to_virtual_machines.sql`: adds `AssignedDate` and `LastCheckoutDate` to `dbo.VirtualMachines`
- `089_add_profile_reset_to_vmusers.sql`: adds the requested profile reset to `dbo.VmUsers`
- `090_add_username_index_to_virtual_machines_history.sql`: indexes `dbo.VirtualMachinesHistory` by user for the user page
- `101_create_table-scaling_policy.sql`: creates `dbo.ScalingPolicy`, the one-row policy holding the schedules' time zone
- `102_create_table-scaling_schedules.sql`: creates `dbo.ScalingSchedules`, the time windows that override the default rule
- `111_add_phase_columns_to_vm_scaling_activity_log.sql`: records the phase, its minimum and maximum, and the serviceable and draining counts on each scaling run
- `112_add_start_requested_at_to_virtual_machines.sql`: adds `StartRequestedAt`, the stamp start-to-ready times are measured from
- `115_create_table-checkout_events.sql`: creates `dbo.CheckoutEvents`, one row per checkout request and its outcome
- `116_create_table-host_start_events.sql`: creates `dbo.HostStartEvents`, how long each start took to become reachable
- `124_create_table-maintenance_runs.sql`: creates `dbo.MaintenanceRuns`
- `125_create_table-maintenance_run_hosts.sql`: creates `dbo.MaintenanceRunHosts`, each host's progress through a run

The table scripts above are written to be rerunnable.

The scripts do not contain `USE <database>` statements. The target database comes from the connection, which [../deploy/Initialize-Database.ps1](../deploy/Initialize-Database.ps1) builds from its `-DatabaseName` argument, so a non-default `sqlDatabaseName` works without editing any script.

`Hostname` is the natural key the broker resolves against: `RegisterLinuxHostVm`, `ReleaseVm`, and the Linux host agents all locate a VM by hostname alone. If an existing database already contains duplicate hostnames, `027` reports them and skips creating the index rather than failing the bootstrap. Remove the duplicates and rerun to gain the constraint.

### Stored procedures

- `005_create_procedure-CheckoutVm.sql`: checks out a VM for a user
- `006_create_procedure-DeleteVm.sql`: deletes a VM record
- `007_create_procedure-AddVm.sql`: adds a VM record manually
- `008_create_procedure-GetVmDetails.sql`: gets details for a specific VM
- `009_create_procedure-ReturnVm.sql`: returns a VM to the pool
- `010_create_procedure-GetScalingRules.sql`: gets scaling rules
- `011_create_procedure-UpdateScalingRule.sql`: updates a scaling rule
- `012_create_procedure-TriggerScalingLogic.sql`: runs scaling logic
- `013_create_procedure-GetScalingActivityLog.sql`: gets scaling activity history
- `014_create_procedure-GetVms.sql`: gets the VM list
- `015_create_procedure-CreateScalingRule.sql`: creates a scaling rule
- `016_create_procedure-ReleaseVm.sql`: releases a checked-out VM
- `017_create_procedure-UpdateVmAttributes.sql`: updates VM attributes
- `018_create_procedure-ReturnReleasedVms.sql`: returns released VMs to the pool
- `019_create_procedure-DeleteScalingRule.sql`: deletes a scaling rule
- `020_create_procedure-GetVmHistory.sql`: gets VM history
- `021_create_procedure-GetVmScalingRulesHistory.sql`: gets scaling rule history
- `022_create_procedure-GetScalingRuleDetails.sql`: gets a specific scaling rule
- `023_create_procedure-GetDeletedVirtualMachines.sql`: gets deleted VM history
- `025_create_procedure-RegisterLinuxHostVm.sql`: upserts Linux host records into `dbo.VirtualMachines`
- `030_create_procedure-GetLinuxHostSettings.sql`: reads the global Linux host settings profile
- `031_create_procedure-UpdateLinuxHostSettings.sql`: updates the profile, bumping `SettingsVersion` only when a value actually changed
- `032_create_procedure-RecordHostSettingsApplied.sql`: records the settings version a host has applied
- `033_alter_procedure-GetVms.sql`: redefines `dbo.GetVms` to also return `SettingsVersion` and `SettingsAppliedDate`
- `034_create_procedure-GetVmSummary.sql`: returns one aggregate row for dashboard VM counters
- `035_alter_procedure-GetScalingActivityLog.sql`: redefines `dbo.GetScalingActivityLog` to parse optional `MM/DD/YYYY` date strings explicitly
- `036_alter_procedure-GetVmScalingRulesHistory.sql`: redefines `dbo.GetVmScalingRulesHistory` to parse optional `MM/DD/YYYY` date strings explicitly
- `037_create_procedure-GetVmHistoryPaged.sql`: returns paged VM history rows with `TotalCount`
- `038_create_procedure-GetScalingActivityLogPaged.sql`: returns paged scaling activity rows with `TotalCount`
- `039_create_procedure-GetVmScalingRulesHistoryPaged.sql`: returns paged scaling rule history rows with `TotalCount`
- `040_add_lifecycle_columns_to_virtual_machines.sql`: adds release cleanup and power-state transition tracking to `dbo.VirtualMachines`
- `041_alter_procedure-ReleaseVm.sql`: sets `ReleasedDate` when an active checkout is released
- `042_alter_procedure-CheckoutVm.sql`: clears `ReleasedDate` on reuse and avoids cleanup-pending hosts for new checkouts. When no host is free it commits instead of rolling back: the rollback also unwound the transaction pymssql wraps around every call, so SQL Server raised error 266 and the API answered 500 instead of 409
- `043_alter_procedure-ReturnVm.sql`: returns assigned VMs while claiming Linux-side cleanup metadata
- `044_alter_procedure-ReturnReleasedVms.sql`: expires released leases and claims eligible cleanup retries
- `045_create_procedure-CompleteVmCleanup.sql`: clears cleanup-pending state after lease-safe Linux cleanup succeeds
- `046_create_procedure-BeginVmCleanupRetry.sql`: marks an operator-requested cleanup retry attempt
- `047_alter_procedure-UpdateVmAttributes.sql`: performs no-op-safe admin repairs with lifecycle invariant handling
- `048_create_procedure-SetVmNetworkStatus.sql`: updates VM network status only when it changes
- `049_create_procedure-SetVmMaintenance.sql`: toggles unassigned hosts between Available and Maintenance
- `050_alter_procedure-GetVms.sql`: returns VM lifecycle and cleanup columns in the VM list
- `051_alter_procedure-GetVmDetails.sql`: returns VM lifecycle and cleanup columns for one VM
- `052_alter_procedure-GetVmSummary.sql`: adds cleanup-pending and excludes those hosts from Ready
- `053_add_stop_mode_to_vm_scaling_rules.sql`: adds scaling `StopMode` and write-time scaling rule constraints
- `054_alter_procedure-GetScalingRules.sql`: returns `StopMode` and `IsActive` for scaling rules
- `055_alter_procedure-GetScalingRuleDetails.sql`: returns `StopMode` and `IsActive` for one scaling rule
- `056_alter_procedure-CreateScalingRule.sql`: serializes rule creation and enforces a single active rule
- `057_alter_procedure-UpdateScalingRule.sql`: updates scaling rules including `StopMode` without returning rows
- `058_alter_procedure-GetVmScalingRulesHistoryPaged.sql`: includes `StopMode` in paged rule history
- `059_alter_procedure-TriggerScalingLogic.sql`: implements serialized Phase 1 scaling decisions and action logging
- `060_create_procedure-SyncVmPowerStates.sql`: reconciles VM power state from JSON provider data
- `061_create_procedure-AppendScalingActivityNote.sql`: appends notes to a scaling activity row
- `062_create_sequence-vm_user_uid.sql`: creates the VM user uid sequence seeded from existing users
- `063_create_procedure-GetOrCreateVmUserUid.sql`: allocates unique Linux user ids from the sequence, retrying a duplicate-key collision against a savepoint when called inside the caller's transaction
- `064_add_preserve_sessions_to_linux_host_settings.sql`: adds the preserve-sessions host setting and constraint
- `065_alter_procedure-GetLinuxHostSettings.sql`: returns `PreserveSessionsOnDisconnect`
- `066_alter_procedure-UpdateLinuxHostSettings.sql`: updates `PreserveSessionsOnDisconnect` and bumps versions only on change
- `067_create_table-audit_log.sql`: creates the append-only `dbo.AuditLog` (UTC `OccurredAt`, actor, action, target, outcome, JSON detail, correlation ID) and its indexes
- `068_create_procedure-WriteAuditEntry.sql`: appends one audit entry, truncating over-long values and dropping detail that is not JSON
- `069_create_procedure-GetAuditLogPaged.sql`: returns filtered, paged audit entries with `TotalCount` and an ISO-8601 `OccurredAtUtc`
- `070_create_procedure-PurgeAuditLog.sql`: deletes entries older than the retention in batches of at most 2,000 rows, so a purge never escalates to a table lock, clamping the retention to 30–3650 days
- `071_create_procedure-GetLinuxHostSettingsHistory.sql`: returns every saved version of the host settings profile from the temporal history, newest first
- `072_add_drain_requested_to_virtual_machines.sql`: adds `DrainRequested` and `DrainRequestedDate` to `dbo.VirtualMachines`
- `073_alter_procedure-CheckoutVm.sql`: gives a draining host to no new user, while its current user can still reconnect
- `074_alter_procedure-CompleteVmCleanup.sql`: moves a draining host to Maintenance once its previous user is gone, and reports `DrainCompleted`
- `075_alter_procedure-SetVmMaintenance.sql`: clears the drain flag on either maintenance transition
- `076_create_procedure-SetVmDrain.sql`: starts or ends a drain (`Draining`, `Drained`, `ReturnedToService`, `Unchanged`)
- `077_create_procedure-FinalizeVmDrains.sql`: moves every draining host that has become unassigned and clean to Maintenance
- `078_create_procedure-BeginVmPowerAction.sql`: records a requested start, stop or restart, refuses an assigned host unless allowed, ends the assignment when an assigned host is stopped, and returns the previous state for a revert
- `079_alter_procedure-TriggerScalingLogic.sql`: leaves draining hosts out of capacity and never starts or stops them
- `080_alter_procedure-GetVms.sql`, `081_alter_procedure-GetVmDetails.sql`: return `DrainRequested` and `DrainRequestedDate`
- `082_alter_procedure-GetVmSummary.sql`: adds `Draining` and leaves draining hosts out of `Ready`
- `083_create_table-host_heartbeats.sql`: creates `dbo.HostHeartbeats`, one current row per host agent
- `084_create_procedure-RecordHostHeartbeat.sql`: upserts a registered host's heartbeat from JSON and records a changed settings version as applied
- `085_create_procedure-GetHostHealth.sql`: returns every host with its latest heartbeat, the heartbeat age, and the current settings version and reconcile interval
- `086_alter_procedure-DeleteVm.sql`: returns a row only when a VM was deleted, with its hostname, and removes its heartbeat
- `087_create_procedure-RevertVmPowerAction.sql`: puts back what `BeginVmPowerAction` recorded when Azure refuses the operation, including the assignment a refused stop ended, unless the user has since been given another host
- `091_alter_procedure-CheckoutVm.sql`: stamps the assignment dates and adds `CheckoutType` (`Assigned` or `Reused`) and `ProfileResetRequested` to its result
- `092_create_procedure-GetSessions.sql`: every assignment joined with the sessions each host last reported
- `093_create_procedure-SearchUsers.sql`: finds broker users by any part of the name, exact and prefix matches first
- `094_create_procedure-GetUserDetails.sql`: one user, with the hosts they hold or that are still cleaning them up
- `095_create_procedure-GetUserHostHistory.sql`: the hosts a user had, from the temporal history
- `096_create_procedure-GetVmByHostname.sql`: the registered host a session action names
- `097_create_procedure-RequestProfileReset.sql`, `098_create_procedure-CancelProfileReset.sql`: request or withdraw a fresh profile at the user's next new assignment
- `099_create_procedure-BeginProfileReset.sql`, `100_create_procedure-CompleteProfileReset.sql`: decide during a checkout whether the reset can be applied (only when nothing else can be using the profile), and clear it once applied
- `103_create_function-fnScheduleWeekIntervals.sql`: the minutes of the week a schedule window covers, across midnight and the end of the week
- `104_create_function-fnActiveScalingPhase.sql`: the scaling values in force at a time: the enabled window covering it in the policy's time zone, or the default rule
- `105_create_procedure-GetScalingPolicy.sql`, `106_create_procedure-GetScalingSchedules.sql`: the policy, what is in force now, and every window
- `107_create_procedure-SaveScalingSchedule.sql`, `108_create_procedure-DeleteScalingSchedule.sql`: create, replace or remove a window; overlapping enabled windows are refused under an application lock
- `109_create_procedure-SetScalingPolicyTimeZone.sql`, `110_create_procedure-GetTimeZones.sql`: the policy time zone, from `sys.time_zone_info`
- `113_alter_procedure-TriggerScalingLogic.sql`: takes its values from the active phase, lets `MinVMs` win over `MaxVMs`, waits briefly for the scaling lock, stamps `StartRequestedAt`, logs the phase, and adds a dry run (`@DryRun`, `@AtUtc`, `@OverrideJson`) that changes nothing
- `114_alter_procedure-BeginVmPowerAction.sql`: a stop that names no mode uses the active phase's, and starts are stamped for timing
- `117_create_procedure-RecordCheckoutEvent.sql`: records one checkout outcome; an unknown outcome is stored as `Error`
- `118_alter_procedure-SetVmNetworkStatus.sql`: records a host start's time to reachable in `dbo.HostStartEvents`
- `119_create_procedure-GetUtilizationSeries.sql`, `120_create_procedure-GetCheckoutStats.sql`: the dashboard's capacity series and checkout health
- `121_create_procedure-GetAttentionItems.sql`: what needs an operator now: no ready hosts, denied checkouts, and hosts unreachable, stuck in cleanup or never connected to
- `122_create_procedure-PurgeCheckoutEvents.sql`: removes checkout and host-start events past the retention, in batches
- `123_alter_procedure-GetVmSummary.sql`: adds `Serviceable` and `InUse`, the scaler's definitions
- `126_create_function-fnMaintenanceRunSummary.sql`: every maintenance run with how many hosts are at each stage
- `127_create_procedure-CreateMaintenanceRun.sql`: starts a run; only one is active, paused or stopping at a time
- `128_create_procedure-GetMaintenanceRuns.sql`, `129_create_procedure-GetMaintenanceRun.sql`, `130_create_procedure-GetMaintenanceRunHosts.sql`: the runs, one run with what admission sees now, and its hosts with their live state
- `131_create_procedure-BeginMaintenanceTick.sql`, `132_create_procedure-EndMaintenanceTick.sql`: a lease so two advances never work on a run at once
- `133_create_procedure-ClaimMaintenanceAdmissions.sql`: admits the next hosts under the scaling application lock, taking a ready host only while more than the minimum are ready
- `134_create_procedure-SetMaintenanceHostState.sql`: a compare-and-set on each host's step; a final state never changes
- `135_create_procedure-SetMaintenanceRunStatus.sql`: pause, resume, cancel, fail, complete and finish
- `136_create_procedure-ReturnMaintenanceHost.sql`: puts a host back the way the run found it
- `137_create_procedure-GetMaintenanceAttention.sql`: hosts a run could not patch that are still out of rotation
- `138_alter_procedure-SetVmDrain.sql`, `139_alter_procedure-SetVmMaintenance.sql`: refuse to return a host a run is patching, restarting or verifying (`InvalidState`, `InMaintenanceRun`); before patching starts, a manual return skips it
- `140_alter_procedure-TriggerScalingLogic.sql`: keeps one more host serviceable while a run waits for a spare ready host, never past `MaxVMs`
- `141_create_procedure-GetVmsPaged.sql`, `142_create_procedure-GetVmStatusCounts.sql`: the host list's page, filtered, searched and sorted, and its status counts
- `143_create_procedure-ImportLinuxHostVm.sql`: registers a host found in Azure as `Unreachable` with its Azure power state, or reports `Exists`

`033` exists as its own file rather than being folded into `014` because `014` runs before `029` adds those columns, and SQL Server validates column references against existing tables when a procedure is created.

`034` through `039` are also additive/redefinition files so fresh deployments keep procedure validation in numeric schema order. The paged history procedures intentionally omit the legacy `@Limit` parameter: `@Offset` and `@PageSize` are the only result-size controls, and `NULL`/empty/malformed date strings are treated as no date filter.

## Current Runtime Expectations

The current code and deployment flow depend on the following SQL objects being present:

- `dbo.VmScalingRules`
- `dbo.VmScalingActivityLog`
- `dbo.VirtualMachines`
- `dbo.VmUsers`
- `dbo.LinuxHostSettings`
- `dbo.AuditLog`
- `dbo.HostHeartbeats`
- `dbo.ScalingPolicy` and `dbo.ScalingSchedules`
- `dbo.CheckoutEvents` and `dbo.HostStartEvents`
- `dbo.MaintenanceRuns` and `dbo.MaintenanceRunHosts`
- all of the stored procedures and functions above
- especially `dbo.CheckoutVm`, `dbo.ReleaseVm`, `dbo.UpdateVmAttributes`, and `dbo.RegisterLinuxHostVm`

Two current behaviors are worth calling out:

- `dbo.VmUsers` is required by the API path that creates and tracks Linux-side user IDs.
- `dbo.RegisterLinuxHostVm` is the procedure used by post-provision automation to register Linux hosts automatically.
- Released VM lifecycle now uses `ReleasedDate` plus the global grace and reconcile settings. Returned or expired assigned hosts are marked `CleanupPending` with the returned username and lease until Linux-side cleanup completes.
- `dbo.CheckoutVm` never assigns a cleanup-pending host as a new checkout; `dbo.CompleteVmCleanup` clears the pending state only for the matching lease and optional username.
- Scaling is serialized with `sp_getapplock`, treats corrected legacy rule values defensively, logs every acquired run, and emits action rows with `ActionType` exactly `PowerOn` or `PowerOff`.
- Scaling stop behavior is controlled by `StopMode` (`PowerOff` or `Deallocate`), and booting hosts count as serviceable without being selected for stop.
- Linux user ids are allocated through `dbo.VmUserUidSequence`, seeded at the greater of 2000 or the current maximum user id plus one, and collision-skipped for legacy inserts.
- Host settings include `PreserveSessionsOnDisconnect`, which cannot be enabled at the same time as `ScreenLockEnabled`.
- A draining host (`DrainRequested = 1`) is offered to no new user, is left out of scaling capacity, and moves to Maintenance once its assignment has ended and it is clean. `dbo.BeginVmPowerAction` records every operator start, stop and restart the way scaling records its own, and stopping an assigned host ends the assignment exactly as `dbo.ReturnVm` does. If Azure refuses, `dbo.RevertVmPowerAction` restores the power state and gives the assignment back in one transaction.
- `dbo.AuditLog` is append-only and UTC. The API writes it through `dbo.WriteAuditEntry` and purges it through `dbo.PurgeAuditLog`; nothing else updates or deletes it.
- `dbo.HostHeartbeats` keeps only each host's latest heartbeat. `dbo.RecordHostHeartbeat` writes `dbo.VirtualMachines` only when the reported settings version changed, because that table is system-versioned and a write on every heartbeat would add a history row per host per minute.
- Sessions come from `dbo.GetSessions`, which joins each assignment with the sessions the host's heartbeat last reported. A requested profile reset (`dbo.VmUsers.ProfileResetRequestedAt`) is applied only on the user's next new assignment, and only when `dbo.BeginProfileReset` finds nothing else that could be using the profile.
- Scaling reads its values from `dbo.fnActiveScalingPhase`: the enabled `dbo.ScalingSchedules` window covering the current time in `dbo.ScalingPolicy`'s time zone, or else the default rule. Enabled windows never overlap. `MinVMs` wins over `MaxVMs`, so draining and maintenance hosts counting toward the maximum never make scaling stop ready hosts below the minimum. `TriggerScalingLogic @DryRun = 1` makes the same decision and writes nothing.
- `dbo.CheckoutEvents` and `dbo.HostStartEvents` are kept for the API's `CHECKOUT_EVENT_RETENTION_DAYS` and purged with the audit log.
- Only one maintenance run is active, paused or stopping at a time. Admission takes the scaling application lock, so neither admission nor scaling can take ready capacity below the minimum while the other acts, and a run waiting for a spare ready host makes scaling keep one more host on. `dbo.SetMaintenanceHostState` is a compare-and-set, so overlapping advances cannot both act on a step.
- `dbo.GetVmsPaged` and `dbo.GetVmStatusCounts` apply the same status tests as `dbo.CheckoutVm`, so a host the list calls ready is one a checkout could take. Imported hosts start `Unreachable`.

Linux host settings are a single fleet-wide profile:

- `dbo.LinuxHostSettings` is a singleton. `SettingsScope` is constrained to `Global` and made unique, so only one active profile can exist.
- The table is seeded with the values that were previously hardcoded in the release agent and the systemd units, so applying the schema changes no behavior.
- The `CHECK` constraints on that table are the last line of defence for values that reach the Linux hosts. The API and `linux_host/apply-host-settings.sh` validate the same bounds, and all three definitions must be kept in agreement.
- `dbo.VirtualMachines.SettingsVersion` and `SettingsAppliedDate` record what each host actually applied, which is what the portal uses to display drift.

The VM checkout lifecycle is now lease-aware:

- `dbo.CheckoutVm` reuses an existing `CheckedOut` or `Released` assignment by `Username` and keeps the same `LeaseId` until the VM is returned to `Available`.
- `dbo.ReleaseVm` can validate `Hostname`, `Username`, and `LeaseId` together while still tolerating older hostname-only callers during rollout. It always returns a `ReleaseStatus` column of `Released`, `NoActiveAssignment`, `LeaseMismatch`, or `NotFound` so the API can answer an already-released host with `200` instead of an error that the host agent would retry every minute.
- `dbo.ReturnVm` and `dbo.ReturnReleasedVms` now preserve the returned username and lease metadata long enough for the API to perform lease-safe Linux-side cleanup.
- `dbo.ReturnReleasedVms` expires released leases with a single set-based `UPDATE ... OUTPUT`, so the sweep is atomic and does not depend on `INSERT ... EXEC`.

## Automatic Linux Host Registration

After the SQL scripts are applied, [../deploy/Register-LinuxHostSqlRecords.ps1](../deploy/Register-LinuxHostSqlRecords.ps1) connects to Azure and SQL and runs `dbo.RegisterLinuxHostVm` for every VM tagged with `broker-role=linux-host`.

That automation:

- only registers Linux hosts
- does not register AVD hosts
- uses the VM name and resolved private IP address
- inserts a new record if the host is missing
- updates the existing record if the host already exists

This means future azd deployments no longer depend on a manual UI step just to seed Linux hosts into the database.

## Manual Deployment Steps

If you need to run the SQL setup manually, use the following flow.

### Prerequisites

- an Azure SQL Database instance already exists
- you can connect with an admin or equivalent SQL principal
- the client machine is allowed through the SQL firewall

When using the azd deployment flow, remember that SQL bootstrap runs from the local machine. If the SQL firewall does not allow that client IP, the automated bootstrap will fail.

### Recommended manual order

Run all scripts in filename order.

That means:

1. Run the table scripts.
2. Run the stored procedure scripts.
3. Verify the objects.
4. Optionally register Linux hosts by executing `dbo.RegisterLinuxHostVm` yourself or rerunning the post-provision script.

### Example using `sqlcmd`

```powershell
$server = "your_server.database.windows.net"
$database = "LinuxBroker"
$username = "your_username"
$password = "your_password"

Get-ChildItem -Path .\sql_queries -Filter *.sql |
    Sort-Object Name |
    ForEach-Object {
        Write-Host "Applying $($_.Name)"
        sqlcmd -S $server -d $database -U $username -P $password -i $_.FullName
    }
```

Manual execution is useful, but it does not automatically perform the newer post-provision Linux host registration unless you run that step separately.


## Testing

The integration harness under `sql_queries/tests/` applies every top-level SQL script using the same filename sort, `GO` splitting, CRLF normalization, and procedure rewrite rules as `deploy/Initialize-Database.ps1`. It applies the full script set twice to prove rerunnability, creates a throwaway database with `READ_COMMITTED_SNAPSHOT ON`, and resets test data between scenarios.

Local run example:

```powershell
docker run -d --name lb-sqltest -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD=<strong-password> -p 14330:1433 mcr.microsoft.com/mssql/server:2022-latest
python -m venv sql_queries\tests\.venv
.\sql_queries\tests\.venv\Scripts\python -m pip install -r sql_queries\tests\requirements.txt
$env:SQL_TEST_SERVER = 'localhost:14330'
$env:SQL_TEST_USER = 'sa'
$env:SQL_TEST_PASSWORD = '<strong-password>'
.\sql_queries\tests\.venv\Scripts\python -m pytest sql_queries\tests -q
docker rm -f lb-sqltest
```

CI runs the same pytest command on `ubuntu-latest` with Python 3.13 against a `mcr.microsoft.com/mssql/server:2022-latest` service container, and then runs the Broker API against that database (`api/tests_integration`), which exercises every procedure through the real pymssql driver the way production does. See [../api/README.md](../api/README.md#local-development-and-tests).

pymssql runs every statement inside its own transaction. A procedure that rolls back on a normal path unwinds that transaction too, and SQL Server raises error 266 when the procedure returns, so the API's commit fails. Commit what the procedure opened, or roll back to a savepoint when `@@TRANCOUNT > 0`.

## Verification

After bootstrap, verify both tables and procedures.

### Check tables

```sql
SELECT name
FROM sys.tables
WHERE name IN ('VmScalingRules', 'VmScalingActivityLog', 'VirtualMachines', 'VmUsers', 'LinuxHostSettings', 'AuditLog', 'HostHeartbeats',
               'ScalingPolicy', 'ScalingSchedules', 'CheckoutEvents', 'HostStartEvents', 'MaintenanceRuns', 'MaintenanceRunHosts')
ORDER BY name;
```

### Check procedures

```sql
SELECT name
FROM sys.procedures
WHERE name IN (
    'CheckoutVm',
    'DeleteVm',
    'AddVm',
    'GetVmDetails',
    'ReturnVm',
    'GetScalingRules',
    'UpdateScalingRule',
    'TriggerScalingLogic',
    'GetScalingActivityLog',
    'GetVms',
    'CreateScalingRule',
    'ReleaseVm',
    'UpdateVmAttributes',
    'ReturnReleasedVms',
    'DeleteScalingRule',
    'GetVmHistory',
    'GetVmScalingRulesHistory',
    'GetScalingRuleDetails',
    'GetDeletedVirtualMachines',
    'RegisterLinuxHostVm',
    'GetLinuxHostSettings',
    'UpdateLinuxHostSettings',
    'RecordHostSettingsApplied',
    'GetVmSummary',
    'GetVmHistoryPaged',
    'GetScalingActivityLogPaged',
    'GetVmScalingRulesHistoryPaged',
    'CompleteVmCleanup',
    'BeginVmCleanupRetry',
    'SetVmNetworkStatus',
    'SetVmMaintenance',
    'SyncVmPowerStates',
    'AppendScalingActivityNote',
    'GetOrCreateVmUserUid',
    'WriteAuditEntry',
    'GetAuditLogPaged',
    'PurgeAuditLog',
    'GetLinuxHostSettingsHistory',
    'SetVmDrain',
    'FinalizeVmDrains',
    'BeginVmPowerAction',
    'RevertVmPowerAction',
    'RecordHostHeartbeat',
    'GetHostHealth',
    'GetSessions',
    'SearchUsers',
    'GetUserDetails',
    'GetUserHostHistory',
    'GetVmByHostname',
    'RequestProfileReset',
    'CancelProfileReset',
    'BeginProfileReset',
    'CompleteProfileReset',
    'GetScalingPolicy',
    'GetScalingSchedules',
    'SaveScalingSchedule',
    'DeleteScalingSchedule',
    'SetScalingPolicyTimeZone',
    'GetTimeZones',
    'RecordCheckoutEvent',
    'GetUtilizationSeries',
    'GetCheckoutStats',
    'GetAttentionItems',
    'PurgeCheckoutEvents',
    'CreateMaintenanceRun',
    'GetMaintenanceRuns',
    'GetMaintenanceRun',
    'GetMaintenanceRunHosts',
    'BeginMaintenanceTick',
    'EndMaintenanceTick',
    'ClaimMaintenanceAdmissions',
    'SetMaintenanceHostState',
    'SetMaintenanceRunStatus',
    'ReturnMaintenanceHost',
    'GetMaintenanceAttention',
    'GetVmsPaged',
    'GetVmStatusCounts',
    'ImportLinuxHostVm'
)
ORDER BY name;
```

### Check functions

```sql
SELECT name
FROM sys.objects
WHERE type IN ('FN', 'IF', 'TF')
  AND name IN ('fnScheduleWeekIntervals', 'fnActiveScalingPhase', 'fnMaintenanceRunSummary')
ORDER BY name;
```

### Check Linux host rows

```sql
SELECT Hostname, IPAddress, PowerState, NetworkStatus, VmStatus, LastUpdateDate
FROM dbo.VirtualMachines
ORDER BY Hostname;
```

## Rerun Paths

If the database bootstrap needs to be rerun, the preferred path is to rerun the deployment script rather than manually replaying only a subset of files.

From the `deploy/` directory:

```powershell
.\Initialize-Database.ps1 `
  -SqlServerFqdn <server>.database.windows.net `
  -DatabaseName LinuxBroker `
  -SqlAdminLogin <login> `
  -SqlAdminPassword <password> `
  -ScriptsPath ..\sql_queries
```

If you also want to refresh Linux host records after the schema run:

```powershell
.\Register-LinuxHostSqlRecords.ps1 `
  -ResourceGroupName <resource-group> `
  -SqlServerFqdn <server>.database.windows.net `
  -DatabaseName LinuxBroker `
  -SqlAdminLogin <login> `
  -SqlAdminPassword <password>
```

## Troubleshooting

### SQL bootstrap failed during `azd up`

Common causes:

- the local client IP is not allowed through the SQL firewall
- the SQL admin credentials are wrong
- an earlier script failed and blocked a later dependency

The automated bootstrap now stops at the first SQL error, so the failing file name and batch number are the first place to look.

### `VmUsers` is missing

This table is now part of the supported schema and is required by the API user-creation path. Rerun the bootstrap or apply `024_create_table-vmusers.sql` manually.

### Linux hosts were deployed but are not in `dbo.VirtualMachines`

Rerun [../deploy/Register-LinuxHostSqlRecords.ps1](../deploy/Register-LinuxHostSqlRecords.ps1), or rerun [../deploy/Post-Provision.ps1](../deploy/Post-Provision.ps1) if you want the full post-provision sequence.

### You only changed a stored procedure

Keep the change in the numbered SQL file in source control, then rerun the bootstrap. The deployment script converts procedure creation statements into `CREATE OR ALTER PROCEDURE`, so reruns are supported.

## Summary

Treat this folder as the source of truth for the broker database schema and procedure layer.

For new environments:

- let `azd up` drive the SQL bootstrap automatically
- use the deployment scripts under `deploy/` to rerun or troubleshoot
- expect Linux hosts to be auto-registered into SQL after bootstrap

For manual intervention:

- execute the scripts in filename order
- verify `VmUsers` and `RegisterLinuxHostVm` in addition to the older objects
- rerun the deployment scripts when you want behavior that matches the supported automated path