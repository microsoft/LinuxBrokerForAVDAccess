# Broker API

This folder contains the Flask **Broker API** for the Linux Broker for AVD Access solution. It is the control-plane service used by the Service Management Portal, the scheduled scaling task, the AVD host broker, and the Linux host agents. For the full solution architecture and deployment model, see the repository [README](../README.md).

## Purpose

The API brokers Linux host checkouts, records VM state in Azure SQL, manages scaling rules, triggers scaling actions, and delivers the fleet-wide Linux host settings profile. It does not own the database schema; schema and stored procedure changes belong under the [`sql_queries`](../sql_queries/README.md) folder.

## Endpoint Reference

`token_required(...)` grants access when the bearer token carries one of the listed app roles. When a group is listed, membership in that configured group also grants access; the Graph lookup only happens when no role already authorizes the call. Delegated scopes are not permissions: every portal user holds `access_as_user`.

Role groups used below: **READ** = `Reader`, `Operator`, `FullAccess`; **OPERATE** = `Operator`, `FullAccess`; **ADMIN** = `FullAccess`.

| Method | Path | Allowed roles or groups | Description |
| --- | --- | --- | --- |
| GET | `/health` | none | Checks database connectivity and returns API health and version. |
| GET | `/api/version` | none | Returns the API version string. |
| GET | `/api/me` | any valid token | The caller's app roles and `permissions` (`read`, `operate`, `admin`), plus `legacyScopeAccess`. The portal uses it to adapt its interface. |
| GET | `/api/vms` | READ, `ScheduledTask` | Lists all broker VM records, including `ReleasedDate`, `CleanupPending`, `CleanupUsername`, `PowerStateChangedDate`, `DrainRequested`, and `DrainRequestedDate`. With any of `page`, `per_page`, `q`, `status`, `sort` or `dir` it answers one page of the host list instead; see [Host List and Import](#host-list-and-import). |
| GET | `/api/vms/summary` | READ, `ScheduledTask` | Returns dashboard counters: `TotalVMs`, `Available`, `CheckedOut`, `Maintenance`, `Released`, `PoweredOn`, `PoweredOff`, `Unreachable`, `Ready`, `CleanupPending`, and `Draining`. |
| POST | `/api/vms/checkout` | `AvdHost`, `FullAccess`, or `AVD_HOST_GROUP_ID` membership | Checks out a ready Linux host and provisions the user in one SSH session. |
| POST | `/api/vms/<vmid>/update-attributes` | ADMIN, `ScheduledTask` | Repairs the broker's record of a VM's power, network, or broker status. It does not start or stop anything. `ScheduledTask` keeps access for task builds older than `/network-status`. |
| POST | `/api/vms/<vmid>/network-status` | `ScheduledTask`, `FullAccess` | Records a reachability probe result; writes only when the status changes. |
| POST | `/api/vms/<vmid>/maintenance` | OPERATE | Moves an unassigned host between `Available` and `Maintenance`, clearing any drain flag. |
| POST | `/api/vms/<vmid>/cleanup` | OPERATE | Retries removing the returned user from a `CleanupPending` host now. |
| POST | `/api/vms/<vmid>/start` | OPERATE | Records the host as starting and asks Azure to start it. Answers `202`. |
| POST | `/api/vms/<vmid>/stop` | OPERATE; `FullAccess` plus `{"confirm": "<hostname>"}` when a user is assigned | Powers off, or deallocates (`{"mode": "Deallocate"}`, default the scaling rule's stop mode). Stopping an assigned host ends the assignment first. Answers `202`. |
| POST | `/api/vms/<vmid>/restart` | OPERATE; `FullAccess` plus `{"confirm": "<hostname>"}` when a user is assigned | Restarts the host, keeping any assignment. Answers `202`. |
| POST | `/api/vms/<vmid>/drain` | OPERATE | Stops offering the host to new users; the current user keeps it. It moves to `Maintenance` when the assignment ends. |
| POST | `/api/vms/<vmid>/undrain` | OPERATE | Returns a draining or maintenance host to service. |
| POST | `/api/vms/sync` | OPERATE | Corrects every host's recorded power state from Azure now, as scaling does before each run. |
| POST | `/api/vms/<vmid>/delete` | ADMIN | Deletes a VM record; `404` when there is none. |
| POST | `/api/vms/add` | ADMIN | Adds a VM record. |
| GET | `/api/vms/import/candidates` | ADMIN | Linux host VMs in `VM_RESOURCE_GROUP` tagged `broker-role=linux-host` that are not registered, with their power states and DNS-resolved addresses. |
| POST | `/api/vms/import` | ADMIN | Registers tagged hosts by name (`{"hostnames": [...]}`, at most 100), checking each against Azure and DNS again. |
| GET | `/api/vms/<vmid>` | READ | Gets one VM record. |
| POST | `/api/vms/<vmid>/return` | OPERATE | Ends an assignment and removes the user from the host; the VM stays `CleanupPending` until that succeeds. |
| POST | `/api/vms/<hostname>/release` | OPERATE, `LinuxHost`, or `LINUX_HOST_GROUP_ID` membership | Marks a host-side session released, with optional `username` and `leaseId` validation. |
| POST | `/api/vms/released` | `ScheduledTask`, `FullAccess` | Returns Released VMs whose grace period has expired and retries pending cleanups, in parallel. |
| POST | `/api/vms/history` | READ | Returns VM history, optionally paged with `page` and `per_page`. |
| POST | `/api/scaling/log` | READ | Returns scaling activity history, optionally paged with `page` and `per_page`. |
| POST | `/api/scaling/trigger` | `ScheduledTask`, `FullAccess` | Reconciles power states from Azure, runs scaling logic, and starts, powers off, or deallocates VMs as directed by SQL. |
| GET | `/api/scaling/rules` | READ | Lists scaling rules with `StopMode` and `IsActive`; an empty rule set is `[]` with `200`. |
| GET | `/api/scaling/rules/<int:ruleid>` | READ | Gets one scaling rule. |
| POST | `/api/scaling/rules/create` | ADMIN | Creates the scaling rule; `409` when one already exists. |
| POST | `/api/scaling/rules/<int:ruleid>/update` | ADMIN | Updates the scaling rule; the resulting rule is validated. |
| POST | `/api/scaling/rules/<int:ruleid>/delete` | ADMIN | Deletes a scaling rule. |
| POST | `/api/scaling/rules/history` | READ | Returns scaling rule history, optionally paged with `page` and `per_page`. |
| GET | `/api/scaling/policy` | READ | The policy time zone, the default rule, every schedule window, and what applies now and next. |
| POST | `/api/scaling/policy/update` | ADMIN | Sets the time zone every schedule window is read in (`{"timezone": "<Windows zone name>"}`). |
| GET | `/api/scaling/timezones` | READ | The time zones the policy can use, from `sys.time_zone_info`. |
| POST | `/api/scaling/schedules/create` | ADMIN | Adds a schedule window; `409` when it overlaps another enabled window. |
| POST | `/api/scaling/schedules/<int:scheduleid>/update` | ADMIN | Replaces a schedule window. |
| POST | `/api/scaling/schedules/<int:scheduleid>/delete` | ADMIN | Removes a schedule window. |
| GET, POST | `/api/scaling/preview` | READ | A dry run of the next scaling decision and why, optionally at another time (`at`) or, in a POST, with proposed values (`rule`). Changes nothing. |
| GET | `/api/metrics/utilization` | READ | Capacity and checkout health over the last day (`?hours=24`) or week (`?hours=168`). |
| GET | `/api/metrics/attention` | READ | What needs an operator now, most severe first. |
| GET | `/api/sessions` | READ | Every assignment and reported session, with the state an operator acts on (`?q=` matches user or host, `?state=` one state). |
| GET | `/api/users` | READ | Broker users whose name contains `?q=`, exact and prefix matches first. |
| GET | `/api/users/<username>` | READ | One user: where they are now, their sessions, the hosts they had, and recent actions on them. |
| POST | `/api/sessions/<hostname>/<username>/signout` | OPERATE | Ends the user's desktop, then releases the host; `{"returnHost": true}` also ends the assignment. |
| POST | `/api/sessions/<hostname>/<username>/message` | OPERATE | Shows a message in the user's sessions on the host. |
| POST | `/api/sessions/broadcast` | OPERATE | Shows a message in every session, or in every session on the named hosts (`hostnames`). |
| POST | `/api/users/<username>/reset-profile` | ADMIN | Requests a fresh profile at the user's next new assignment. The old profile is kept, renamed. |
| POST | `/api/users/<username>/reset-profile/cancel` | ADMIN | Withdraws a requested profile reset. |
| GET | `/api/maintenance/runs` | READ | Recent maintenance runs, newest first, and the active one with what admission sees now. |
| GET | `/api/maintenance/runs/<int:run_id>` | READ | One run and every host in it, with its progress and live state. |
| POST | `/api/maintenance/runs/create` | ADMIN | Starts a rolling maintenance run over the named hosts; `409` while another run is active. |
| POST | `/api/maintenance/runs/<int:run_id>/pause`, `/resume`, `/cancel` | ADMIN | Pauses, resumes or cancels a run. Hosts mid-step finish their step. |
| POST | `/api/maintenance/advance` | `ScheduledTask`, `FullAccess` | Advances the active run within a deadline. The scheduled task calls it every minute. |
| GET | `/api/hosts/settings` | READ, `LinuxHost`, `ScheduledTask`, or `LINUX_HOST_GROUP_ID` membership | Returns the fleet-wide Linux host settings profile. |
| POST | `/api/hosts/settings/update` | ADMIN | Updates the fleet-wide Linux host settings profile. A portal user is recorded as `UpdatedBy` from their token. |
| POST | `/api/hosts/settings/apply` | OPERATE, `ScheduledTask` | Pushes the current settings profile to reachable hosts over SSH, in parallel. |
| GET | `/api/hosts/settings/history` | READ | Every saved version of the settings profile, newest first, with who saved it (`?limit=`, at most 200). |
| POST | `/api/hosts/<hostname>/settings/ack` | `LinuxHost`, `FullAccess`, or `LINUX_HOST_GROUP_ID` membership | Records the settings version applied by one host. |
| POST | `/api/hosts/<hostname>/heartbeat` | `LinuxHost`, `FullAccess`, or `LINUX_HOST_GROUP_ID` membership | Stores the host agent's latest heartbeat. |
| GET | `/api/hosts/health` | READ | Every host's latest heartbeat with health flags and a fleet summary (`?hostname=` for one host, `?summary=true` for the summary only). |
| GET | `/api/audit` | READ | Audit entries, newest first, paged and filtered. |
| POST | `/api/audit/purge` | `ScheduledTask`, `FullAccess` | Removes audit entries older than `AUDIT_RETENTION_DAYS`. |

`/api/vms/available` is not present in `app.py`; do not add new callers for it.

`api/tests/test_authorization_and_provisioning.py` holds this table as a contract and fails if a route is added, removed, or given different roles without updating it.

## Release Lifecycle

A VM leaves an assignment in one of three ways: the scheduled sweep returns it once its grace period has expired, an operator returns it, or a checkout fails part-way. In every case the procedure marks the VM `CleanupPending`, capturing the user and lease, and the API then removes the user from the host with `manage-lease.sh` and `userdel`. Only when that succeeds does `CompleteVmCleanup` clear the flag, and `CheckoutVm` never selects a pending VM. A user still signed in, an unreachable host, or a failed command leaves the VM pending, and the sweep retries it about every two minutes while the host is on and reachable.

The sweep's threshold is `GracePeriodSeconds + ReconcileIntervalSeconds + 60` from the host settings profile, measured from `ReleasedDate`, which gives the host agent time to sign the user off first.

## Scaling

`/api/scaling/trigger` first reads each registered host's power state from Azure (`virtual_machines.instance_view`, in parallel) and corrects the database through `SyncVmPowerStates`. If Azure cannot be read, the run continues on the recorded states and reports `PowerSyncFailed`. `TriggerScalingLogic` then decides under an application lock, so concurrent runs cannot both act, and returns `PowerOn` and `PowerOff` rows; the API starts, powers off, or deallocates each VM according to the rule's `StopMode`. A power operation Azure refuses restores the VM's recorded state and appends a note to the activity log entry.

Before this release the procedure returned `PoweredOn` and `PoweredOff`, which the API never matched, so no scaling decision ever reached Azure. The API accepts both spellings.

## Consumers

These callers constrain response shapes and endpoint compatibility.

| Consumer | Endpoints |
| --- | --- |
| `front_end` portal | VM, host action, import, scaling policy, host-settings, fleet health, session, user, metrics, maintenance and audit endpoints, and `/api/me` at sign-in. The dashboard prefers `/api/vms/summary` and reads `/api/hosts/health?summary=true` and `/api/metrics/*`; the host list and history pages request `page` and `per_page`. |
| `task\function_app.py` | `/api/vms`, `/api/vms/released`, `/api/vms/<vmid>/network-status` (falling back to `update-attributes` on older APIs), `/api/scaling/trigger`, `/api/maintenance/advance` (every minute), `/api/audit/purge` (daily, which also purges checkout events) |
| Linux host release agent (`linux_host\...\release-session.sh`) | `/api/vms/<hostname>/release`, `/api/hosts/<hostname>/heartbeat` |
| AVD host (`avd_host\...\Connect-LinuxBroker.ps1`) | `/api/vms/checkout` |
| Linux host settings agent | `/api/hosts/settings`, `/api/hosts/<hostname>/settings/ack` |

## Host Actions and Drain

The start, stop and restart endpoints record the intended state in SQL first (`BeginVmPowerAction`), exactly as scaling does, and then ask Azure; they do not wait for Azure to finish. Starting records the host as `On` and `Unreachable` until the reachability probe reaches it, stopping records it as `Off`, and restarting takes it out of rotation until the probe reaches it again. `PowerStateChangedDate` is stamped each time, so the Azure power-state sync does not flip the record back while Azure catches up. If Azure refuses the operation, `RevertVmPowerAction` restores the recorded state, including an assignment that a refused stop ended, and the call answers `502`. The API's existing Desktop Virtualization Power On Off Contributor role already covers start, power off, deallocate and restart.

A host with a user assigned can only be stopped or restarted by `FullAccess`, and only when the request names its hostname in `confirm`; an Operator gets `403` and a missing confirmation `409`, naming the user. The procedure re-checks the assignment, so a host assigned between the check and the action is refused too. Stopping an assigned host ends the assignment first, as a return does: the host is `CleanupPending` until the previous user is removed, which the sweep retries once the host is running again, and the user gets a different, running host when they reconnect. Restart keeps the assignment, and the user can reconnect once the host is back. The scaler may start a stopped idle host again to keep `MinVMs`; drain it to keep it out of rotation.

Drain sets `DrainRequested` rather than a new `VmStatus`, so the lifecycle states and their constraint are unchanged. `CheckoutVm` gives a draining host to no new user but lets its current user reconnect. When the assignment ends and the host is clean, `CompleteVmCleanup` moves it to `Maintenance`, and the sweep's `FinalizeVmDrains` catches any other path to an unassigned, clean host. Draining an idle host moves it to `Maintenance` at once. Drain has no deadline. An operator can sign the user out from Sessions, and a maintenance run can set a deadline after a warning (see [Rolling Maintenance](#rolling-maintenance)). Scaling leaves draining hosts out of its capacity counts and never starts or stops them, so draining a busy pool brings up replacements within `MaxVMs`.

## Heartbeat and Fleet Health

Each Linux host agent posts a heartbeat at the end of every timer run: its agent version and each installed script's version, the applied settings version, OS, kernel, desktop, xrdp version and state, NFS state, load, memory, root disk and uptime, and its sessions. The endpoint caps the body at 32 KB (`413`), drops unknown keys and any value of the wrong type or out of range, and accepts at most 50 sessions. A Linux host's system-assigned identity names its VM in the `xms_mirid` claim, so a heartbeat for a different hostname is refused (`403`, audited). `RecordHostHeartbeat` keeps one current row per registered host (`404` for an unknown host), and records the reported settings version as applied when it changed, so a failed acknowledgement does not leave a host showing drift. Heartbeats are not audited.

`GET /api/hosts/health` flags what needs attention. A powered-off host is expected to be silent and is never flagged for its heartbeat.

| Flag | Meaning |
| --- | --- |
| `no-heartbeat` | Powered on but never reported; the agent predates heartbeats. |
| `stale` | Powered on, but the last heartbeat is older than 3 reconcile intervals (at least 180 seconds). |
| `xrdp-down`, `nfs-unreachable`, `low-disk` | From a current heartbeat: xrdp is not active, mounted homes (or the remembered NFS server) do not answer, or less than 10% of the root disk is free. |
| `agent-outdated` | The agent, or any installed script, is older than `EXPECTED_HOST_AGENT_VERSION`. |
| `settings-drift` | Powered on and has not applied the current settings version. |

Fleet health reports only. Checkout readiness is still decided by the task function's reachability probe, so a broken heartbeat path can never take hosts out of rotation. `HOST_AGENT_VERSION` in [`config.py`](config.py) must match the `LINUXBROKER_AGENT_VERSION` every script in `linux_host/` declares; a unit test fails otherwise.

## Audit Log

`@audited` records every call a portal user or an administrator principal makes to a mutating route, with the outcome taken from the status (`success`, `failure`, or `denied` for `403`), the target (the hostname where known), and a curated detail: the fields changed and their previous values, the result, and the error envelope's message. It never records a response body, so a password or lease ID cannot reach the log. `token_required` records authorization denials on mutating routes from any caller, up to 30 a minute per caller in each worker process; past that it only logs them, so a caller retrying a refused call cannot fill the table. The broker's own changes are recorded where they happen: scaling power actions and their failures, power states corrected from Azure, expired releases, completed cleanups and drains, and each purge. Routine agent calls are not audited: AVD checkouts, Linux host releases, acknowledgements and heartbeats, and the task's probes are high volume, and `VirtualMachinesHistory` already records what they change.

The actor comes from the validated token: a portal user's sign-in name, or for a managed identity the VM or function app named in `xms_mirid`. The correlation ID is the request's OpenTelemetry trace ID when it is traced. Writing an entry never fails the operation: a failure is logged and the call carries on. Every entry is also written to the `linuxbroker.api.audit` logger with `audit_*` attributes, so Application Insights keeps a copy with its own retention, for example for export to a SIEM.

`GET /api/audit` takes `page`, `per_page` (up to 1000), `from` and `to` (a UTC date, `YYYY-MM-DD`, or an ISO-8601 UTC time; a bare `to` date covers that whole day), `actor` (exact object ID or any part of the name), `action` (exact, or a prefix ending in a dot such as `vm.`), `targetType`, `target` (any part), and `outcome`. It answers with the same envelope as the paged history endpoints, and `OccurredAtUtc` is an ISO-8601 UTC string. The scheduled task calls `POST /api/audit/purge` daily. It removes entries older than `AUDIT_RETENTION_DAYS` in batches of up to 2,000 rows and commits each one, so an audit write never waits for more than one batch; a run stops after 90 seconds and the next run finishes a larger backlog. `PurgeAuditLog` clamps the retention to 30–3650 days.

## Sessions and Users

`GET /api/sessions` joins every assignment (checked out, released, or waiting for its user to be cleaned up) with the sessions each host last reported in its heartbeat, and gives each one the state an operator acts on:

| State | Meaning |
| --- | --- |
| `active`, `disconnected` | What a current heartbeat reports for the assigned user. |
| `released` | The user disconnected and the grace period is running (`GraceRemainingSeconds`). |
| `connecting` | Checked out in the last three minutes; the user is still signing in. |
| `not-connected` | Checked out longer ago, and the host does not report the user. |
| `cleanup-pending` | Returned, and the previous user has not been removed yet. |
| `unmanaged` | A session a host reports for a user the broker did not assign there. |
| `unknown` | No current heartbeat, so the host's view is not known. |

Sign-out, messages and profile resets run the allowlisted `session-control.sh` on the host over SSH, and it only acts on accounts the broker created. Sign-out ends the user's desktop and then releases the host through the lease-qualified `ReleaseVm`, so the grace period starts without depending on the agent's own release; `returnHost` also ends the assignment. `POST /api/sessions/broadcast` runs `session-control.sh message-all` on every host in use, or on the named hosts, in parallel within `BROADCAST_CONCURRENCY`, `BROADCAST_HOST_TIMEOUT_SECONDS` and `BROADCAST_DEADLINE_SECONDS`, and reports each host as `Delivered`, `NoSession`, `AgentOutdated` or `Failed`, plus the hosts it had no time to try. Messages are at most 500 characters; the audit keeps the first 200.

A profile reset is requested and then applied at the user's next new assignment, on the assigned host, just before `create-user.sh` mounts the home, so it can never race a sign-in. `BeginProfileReset` allows it only when this is the user's only assignment, no host is still cleaning them up, and no current heartbeat reports them elsewhere; otherwise it stays pending. The old home is renamed `<user>.reset-<UTC timestamp>` on the share and never deleted. A host running an agent older than 1.1.0 answers these actions with `409`, naming `Migrate-LinuxHostReleaseAgent.ps1`.

## Scaling Policy and Schedules

Schedule windows override the default rule on chosen days and times, read in one policy time zone (a Windows zone name, `UTC` until one is chosen): for example Monday to Friday 08:00–18:00 keeping at least five hosts ready. A window may run past midnight; outside every enabled window the default rule applies. Overlapping enabled windows are refused in SQL under a lock, and in the API with a message naming the clash. `TriggerScalingLogic` takes its values from the active phase, and `GET /api/scaling/preview` runs the same decision as a dry run against the current counts, so the portal can show what the next run would do, and why, before anything is saved. `MinVMs` wins over `MaxVMs`: draining and maintenance hosts count toward the maximum, and a scale-down never takes serviceable hosts below the minimum. Windows take effect at the next five-minute scaling run.

## Trends and Attention

Every checkout records its outcome (`Assigned`, `Reused`, `NoneAvailable`, `ProvisionFailed` or `Error`) and duration in `CheckoutEvents`. Recording never fails the checkout, and a missing procedure is logged once. `GET /api/metrics/utilization` combines the five-minute scaling runs with those events: running, in use, serviceable and the scaling maximum per bucket (15 minutes over a day, an hour over a week), denied checkouts, checkout time percentiles, and how long started hosts took to become reachable. `GET /api/metrics/attention` lists what needs an operator now: no ready host, denied checkouts in the last hour, hosts unreachable for 10 minutes, stuck in cleanup for 15, or checked out 30 minutes ago without the user connecting, hosts a maintenance run could not patch, and the fleet health flags, grouped. The daily audit purge also removes events older than `CHECKOUT_EVENT_RETENTION_DAYS`. Both endpoints answer `404` against a database without the procedures, and the portal then hides the charts.

## Rolling Maintenance

A maintenance run patches or restarts hosts a batch at a time while users keep working. Only one run is active at a time. The scheduled task calls `POST /api/maintenance/advance` every minute; each advance holds a lease on the run, records each step before taking it and confirms it once its effect is seen, and every change is a compare-and-set, so an advance that dies part way is picked up by the next. Each host goes:

1. **Pending**, until admitted. Admission holds the scaling application lock and takes a ready host only while more than the minimum are ready (the run's override, or the phase's `MinVMs`). When a ready host waits for a spare, scaling keeps one more host on, never past `MaxVMs`.
2. **Draining**, waiting for the user to leave. With a sign-out deadline, the user is warned first and signed out at the deadline; without one the run waits.
3. **Starting**, if it was powered off, then **Patching** with the allowlisted `patch-host.sh` over SSH (`Security`, `All`, or none for `RebootOnly`), within `MAINTENANCE_PATCH_TIMEOUT_MINUTES`.
4. **Restarting** through Azure, then **Verifying**: reachable, a heartbeat whose boot time is after the restart, and xrdp active.
5. **Succeeded**, and put back the way it was found: in service, or still drained or in maintenance if it was, and stopped again if it was off.

Steps are retried after a timeout a bounded number of times, then the host is **Failed** and stays out of rotation for inspection. The run stops after too many failures and can pause after canary hosts. Pause stops admitting hosts and starting new steps; cancel returns hosts still draining, and hosts mid-step finish. Returning a host to service by hand is refused while a run is patching, restarting or verifying it; before that, a manual return skips it. Patching needs host agent 1.1.0; restart-only runs work with older agents.

## Host List and Import

`GET /api/vms` pages when any of `page`, `per_page` (1–200, default 50), `q`, `status`, `sort` or `dir` is sent; the task's bare list is unchanged. `status` is one of `all`, `ready`, `in-use`, `released`, `maintenance`, `draining`, `unreachable`, `off` or `cleanup`, using the same tests as checkout, and `sort` one of `hostname`, `status`, `power`, `network`, `user`, `ip`, `os`, `agent`, `heartbeat`, `sessions`, `vmid` or `updated`. The envelope adds `counts` for every status, narrowed by the search, and each row carries the host's OS, agent version, settings currency, last heartbeat and the assigned user's session state.

`GET /api/vms/import/candidates` lists the VMs in `VM_RESOURCE_GROUP` tagged `broker-role=linux-host` that are not registered, with their power states, and resolves each as `<hostname>.<DOMAIN_NAME>`, the name every SSH call uses, within 10 seconds. A name that does not resolve is listed but cannot be imported: an address typed in by hand could let the IP-based probe mark a host ready that every SSH call would fail on. `POST /api/vms/import` checks each name against the tagged VMs and DNS again, and registers it through `ImportLinuxHostVm` as `Unreachable` with the power state Azure reports, so no one is given it before the probe reaches it. Both answer `409` until `VM_SUBSCRIPTION_ID` and `VM_RESOURCE_GROUP` are set.
## Authentication and Authorization

Clients send Entra ID bearer tokens in the HTTP `Authorization` header. `token_required()` validates the token signature against the tenant JWKS, accepts audiences `CLIENT_ID` and `api://<CLIENT_ID>`, and accepts issuers:

- `{AUTHORITY_HOST}/{TENANT_ID}/v2.0`
- `{AUTHORITY_HOST}/{TENANT_ID}/`
- `{STS_ISSUER_HOST}/{TENANT_ID}/`

Authorization then checks app roles in `roles`, and optional group membership through Microsoft Graph `checkMemberGroups` using the token `oid`, only when no role already authorizes the call. Group results are cached for five minutes; a Graph failure answers `503` rather than being cached as a denial.

The signing keys are cached for `JWKS_CACHE_SECONDS`, and an unknown key ID forces one refresh at most once a minute, so a key rotation is picked up without letting forged tokens hammer the discovery endpoint. The Graph token is reused until five minutes before it expires. Every outbound call has a timeout.

`ALLOW_LEGACY_SCOPE_ACCESS=true` treats a delegated token carrying `access_as_user` as `FullAccess`, as releases before role enforcement did, and logs a warning at most every five minutes. It exists only to bridge an upgrade while roles are assigned.

Cloud endpoints are resolved in [`config.py`](config.py). `AZURE_CLOUD_NAME=AzurePublic` uses `login.microsoftonline.com`, `graph.microsoft.com`, and `sts.windows.net`. `AzureUSGovernment` uses `login.microsoftonline.us` and `graph.microsoft.us`. Any custom or sovereign cloud without a built-in profile must set `AZURE_AUTHORITY_HOST`, `GRAPH_ENDPOINT`, and `STS_ISSUER_HOST` explicitly.

## Error Responses and Logging

Handler failures use a JSON error envelope:

```json
{"error": "Unable to retrieve virtual machines."}
```

Exception detail must not be returned in the response body. Log details with the `linuxbroker.api` logger; when `APPLICATIONINSIGHTS_CONNECTION_STRING` is set, that logger is configured for Azure Monitor. Authentication middleware and `/health` have their own fixed response shapes, but application handler errors should use the envelope.

## Pagination Contract

`/api/vms/history`, `/api/scaling/log`, and `/api/scaling/rules/history` support opt-in pagination. Supplying either `page` or `per_page` in the query string returns an envelope:

```http
POST /api/vms/history?page=2&per_page=25
Content-Type: application/json

{"startdate":"08/01/2026","enddate":"08/19/2026"}
```

```json
{
  "items": [
    {"VMID": 42, "Hostname": "linux-01"}
  ],
  "page": 2,
  "per_page": 25,
  "total": 91,
  "total_pages": 4
}
```

When neither `page` nor `per_page` is present, the response remains a bare JSON array. Do not remove that default: `task\function_app.py` and older portal builds consume these endpoints as plain lists. The unpaged path also deliberately tolerates `"null"` for `limit`; older portal builds sent that sentinel for **No Limit**, and rolling deployments must not turn it into a SQL `INT` conversion failure.

`GET /api/vms` opts in the same way, with filters, sorting and status counts; see [Host List and Import](#host-list-and-import).

Empty collection responses are arrays with `200`, including `/api/scaling/rules`, `/api/scaling/log`, and `/api/scaling/rules/history`.

## VM Summary

`GET /api/vms/summary` returns fixed-size dashboard counters instead of requiring the portal to fetch every VM. `Ready` uses the same condition as checkout host selection: `VmStatus='Available'`, `PowerState='On'`, `NetworkStatus='Reachable'`, not `CleanupPending`, and not draining. `CleanupPending` counts returned hosts still waiting for their previous user to be removed, and `Draining` counts hosts taking no new users.

## Configuration

The API reads environment variables directly; it does not load `.env` files by itself. [`env.example`](env.example) shows the deployment settings.

| Variable | Required | Purpose |
| --- | --- | --- |
| `SCM_DO_BUILD_DURING_DEPLOYMENT` | deployment | Enables App Service build during deployment. |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | optional | Enables Azure Monitor/OpenTelemetry export for `linuxbroker.api`. |
| `ApplicationInsightsAgent_EXTENSION_VERSION` | optional | App Service Application Insights extension version. |
| `APPLICATIONINSIGHTSAGENT_EXTENSION_ENABLED` | optional | Enables the App Service Application Insights extension. |
| `WEBSITE_HTTPLOGGING_RETENTION_DAYS` | optional | App Service HTTP log retention. |
| `VM_SUBSCRIPTION_ID` | required for scaling | Azure subscription used by `/api/scaling/trigger`. |
| `VM_RESOURCE_GROUP` | required for scaling | Resource group containing Linux host VMs. |
| `AVD_HOST_GROUP_ID` | required for AVD host group auth | Entra group whose members may call checkout. |
| `LINUX_HOST_GROUP_ID` | required for Linux host group auth | Entra group whose members may call the release, heartbeat, and host-settings read and ack endpoints. |
| `LINUX_HOST_ADMIN_LOGIN_NAME` | optional | SSH admin user prefix for remote host commands; defaults to `avdadmin`. |
| `DB_SERVER` | required | Azure SQL Server name or FQDN for `pymssql`. |
| `DB_DATABASE` | required | Azure SQL database name. |
| `DB_USERNAME` | required | SQL login name. |
| `DB_PASSWORD_NAME` | required | Key Vault secret name containing the SQL password. |
| `CLIENT_ID` | required | Broker API app registration client ID and accepted token audience. |
| `TENANT_ID` | required | Entra tenant used for token validation and Graph calls. |
| `AZURE_CLOUD_NAME` | optional | Cloud profile name; defaults to `AzurePublic`. |
| `AZURE_AUTHORITY_HOST` | required for `AzureCustom` | Login authority host override. |
| `GRAPH_ENDPOINT` | required for `AzureCustom` | Microsoft Graph endpoint override. |
| `STS_ISSUER_HOST` | required for `AzureCustom` | STS issuer host override. |
| `GRAPH_API_ENDPOINT` | optional | Legacy Graph scope setting in `config.py`; current token acquisition uses `GRAPH_ENDPOINT`. |
| `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET` | required | Client secret used by the API to call Graph for group checks. |
| `DOMAIN_NAME` | required for SSH actions | DNS suffix used to build `<admin>@<hostname>.<domain>`. The `azd` deployment sets it to its private DNS zone (`linuxbroker.internal`) unless you supply `domainName`. |
| `VAULT_URL` | required | Key Vault URL for SQL password and SSH key retrieval. |
| `KEY_NAME` | required for SSH actions | Key Vault secret name containing the PEM SSH private key. |
| `NFS_SHARE` | required for checkout provisioning | NFS share argument passed to `create-user.sh`; used by code but not currently listed in `env.example`. The `azd` deployment sets it to the Azure Files NFS share it provisions unless you supply `nfsShare` or set `deployNfsShare` to `false`. |
| `ALLOW_LEGACY_SCOPE_ACCESS` | optional | `true` treats the portal's `access_as_user` scope as `FullAccess` while roles are assigned during an upgrade. Defaults to `false`; set through the `allowLegacyScopeAccess` deployment value. |
| `GUNICORN_CMD_ARGS` | optional | Overrides the image default of `--workers 2 --threads 8 --timeout 120 --graceful-timeout 30 --keep-alive 5`. |
| `DB_MAX_CONCURRENCY` | optional | Maximum SQL connections per worker process. Defaults to `6`, which keeps two workers inside the Basic tier's 30 concurrent workers; raise it with the database tier. |
| `DB_ACQUIRE_TIMEOUT_SECONDS` | optional | How long a request waits for a free connection slot before answering `503`. Defaults to `15`. |
| `JWKS_CACHE_SECONDS` | optional | How long token signing keys are cached. Defaults to `3600`. |
| `SSH_KEY_CACHE_SECONDS` | optional | How long the SSH private key read from Key Vault is reused. Defaults to `3600`. |
| `SWEEP_CONCURRENCY`, `SWEEP_DEADLINE_SECONDS` | optional | Parallel cleanups in the released-VM sweep (default `8`), and the time after which it stops starting new ones (default `40`); the rest are retried on the next run. |
| `APPLY_CONCURRENCY`, `APPLY_HOST_TIMEOUT_SECONDS`, `APPLY_DEADLINE_SECONDS` | optional | Parallel pushes for Apply Now (default `10`), the SSH timeout per host (default `30`), and the time after which no new push starts (default `90`); hosts not reached converge on their next reconcile run. |
| `AUDIT_RETENTION_DAYS` | optional | Audit entries older than this are removed by the daily purge. Defaults to `365`; clamped to 30–3650. |
| `CHECKOUT_EVENT_RETENTION_DAYS` | optional | Checkout and host-start events older than this are removed by the same daily purge. Defaults to `90`; 7–3650. |
| `BROADCAST_CONCURRENCY`, `BROADCAST_HOST_TIMEOUT_SECONDS`, `BROADCAST_DEADLINE_SECONDS` | optional | Parallel hosts for a broadcast message (default `10`), the SSH timeout per host (default `20`), and the time after which no new host is tried (default `60`). |
| `MAINTENANCE_ADVANCE_DEADLINE_SECONDS` | optional | How long one maintenance advance may work before it leaves the rest for the next (default `45`, 15–100). |
| `MAINTENANCE_PATCH_TIMEOUT_MINUTES` | optional | How long a host's patch may run before it counts as timed out and is retried (default `90`, 10–600). |
| `EXPECTED_HOST_AGENT_VERSION` | optional | The host agent version fleet health expects. Defaults to `HOST_AGENT_VERSION` in `config.py`; override only to quiet the `agent-outdated` flag during a staged host migration. |

## Database Access

Handlers call stored procedures rather than embedding schema logic in Python. `db_connection()` wraps `get_db_connection()` as a context manager so every acquired connection is closed on success or exception, and bounds the connections each worker process holds at once (`DB_MAX_CONCURRENCY`). Never nest `db_connection()` blocks: a thread holding one slot while waiting for another can starve the pool.

pymssql runs every statement inside its own transaction, so a procedure must never roll that outer transaction back on a normal path: SQL Server then raises error 266 when the procedure returns, and the handler's commit fails. Procedures that need their own transaction either commit what they opened or use a savepoint when `@@TRANCOUNT > 0` (see `059_alter_procedure-TriggerScalingLogic.sql`).

Keep schema and procedure changes in numbered files under [`sql_queries`](../sql_queries/README.md). The deployment bootstrap applies those scripts in filename order and rewrites procedures to `CREATE OR ALTER PROCEDURE` for reruns.

## Local Development and Tests

Install runtime dependencies from this folder:

```powershell
cd .\api
py -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python .\app.py
```

Set the required environment variables first. For local test runs, install the dev requirements and run pytest from the `api` folder:

```powershell
pip install -r requirements.txt -r requirements-dev.txt
pytest
```

`api\tests\` contains the unit tests. They replace pymssql, PyJWT and the Azure SDKs with fakes, and cover the error envelopes, pagination, authorization and the route-to-role contract, caching, the database concurrency limit, provisioning, the release lifecycle, scaling, schedules and the preview, host settings, host actions and drain, heartbeats and fleet health, sessions, messages and profile resets, checkout events and the dashboard metrics, the maintenance state machine tick by tick, the paged host list and import, and the audit log. An autouse fixture captures audit entries in memory (`audit_entries`) instead of sending them to the fake database, and a contract test requires every mutating route to be audited or listed as agent-only.

`api\tests_integration\` runs the handlers against a real SQL Server with every script in `sql_queries` applied, through the real driver, so it catches procedure and handler mismatches the fakes cannot. Run it on its own, because the unit tests load fake modules for the whole process:

```powershell
docker run -d --name lb-sql -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD='<strong password>' -p 14330:1433 mcr.microsoft.com/mssql/server:2022-latest
$env:SQL_TEST_SERVER = 'localhost:14330'
$env:SQL_TEST_PASSWORD = '<strong password>'
pytest tests_integration
```

It is skipped when `SQL_TEST_SERVER` is not set. CI runs it against a SQL Server 2022 service container.
