# Linux Broker for AVD: roadmap

This document records the improvements planned for the Linux Broker for AVD Access solution
after the Phase 1 correctness, access-control and performance work. It is written so that
each item can be picked up on its own, without re-deriving the analysis behind it.

Each item states why it matters, the proposed design across the database, the Broker API,
the host agents and the portal, what it depends on, the open questions, and what "done"
means. Code references point at the files that motivated each item.

| Status | Meaning |
| --- | --- |
| Planned | Designed here, not started |
| In progress | Being implemented |
| Done | Merged |

## Contents

- [Constraints every item must respect](#constraints-every-item-must-respect)
- [Phase 1: correctness, access control and performance](#phase-1-correctness-access-control-and-performance)
- [Phase 2: admin console](#phase-2-admin-console)
- [Phase 3: operating system and desktop support](#phase-3-operating-system-and-desktop-support)
- [Phase 4: strategic scale](#phase-4-strategic-scale)
- [Security hardening backlog](#security-hardening-backlog)
- [Decisions log](#decisions-log)
- [Glossary](#glossary)

## Constraints every item must respect

These are properties of the current design. A change that breaks one of them needs an
explicit decision, not an accident.

- **Stored procedures are the data contract.** Schema and procedure changes go in new,
  numbered, rerunnable files under `sql_queries/`. Never edit an already-applied file. The
  bootstrap (`deploy/Initialize-Database.ps1`) applies every file in name order and rewrites
  `CREATE PROCEDURE` to `CREATE OR ALTER PROCEDURE`, so a redefinition must come *after* the
  script that adds any column it references (see `033_alter_procedure-GetVms.sql`).
- **Rolling upgrades.** The API, portal, task function and Linux host scripts are updated
  at different times. `Migrate-LinuxHostReleaseAgent.ps1` updates existing hosts
  separately. Every API change must tolerate hosts running the previous scripts, and every
  procedure change must keep working for the previous API build.
- **No CDN at runtime.** The portal must render in Government, sovereign and air-gapped
  clouds. Everything is bundled, fonts are the system stack, and icons are inline SVG (see
  `front_end/README.md`). Chart libraries are fine if Vite bundles them.
- **Sovereign clouds.** Every endpoint comes from `config.py` cloud profiles or explicit
  settings. Don't hard-code `*.microsoft.com` hosts. Air-gapped hosts download their scripts
  from `scriptSourceRoot`.
- **Pull converges, push accelerates.** Hosts fetch their settings on every reconcile run,
  and the API's SSH push is only a fast path. New host-facing features should follow the
  same model, so a host that was off or unreachable converges on its own.
- **Validate at every layer.** Host settings are bounded by SQL `CHECK` constraints, API
  validation, and `apply-host-settings.sh` clamps, and all three must agree. Apply the same
  discipline to new settings.
- **The error envelope never leaks internals.** Every error is
  `{"error": "<curated message>"}`. Exceptions go to Application Insights, never into a
  response body.

---

## Phase 1: correctness, access control and performance

**Status: Done.** Summary of what it changed:

| Area | Change |
| --- | --- |
| Scaling actually runs | **Live bug:** `TriggerScalingLogic` returned `PoweredOn`/`PoweredOff`, but the API checked for `PowerOn`/`PowerOff`, so scaling only flipped database flags and never started or stopped a VM in Azure. Fixed. Scaling is active immediately after the upgrade. |
| Scaling correctness | A deterministic single active rule, serialized with an application lock. `MinVMs ≥ 1` is enforced, including recovery from zero running VMs. Released hosts count as in use. Booting hosts count as pending capacity and are never stopped. Maintenance, assigned and cleanup-pending hosts are never touched. Power state is reconciled from Azure before each run. Requested and failed operations are logged. |
| Stop mode | Power-off stays the default. Admins can choose **Deallocate** per scaling rule in the portal, with the cost, start-latency and capacity risks explained and confirmed before saving. |
| Released-VM sweep | `ReturnReleasedVms` honors `GracePeriodSeconds` plus a reconcile buffer, measured from a dedicated `ReleasedDate`, instead of a hard-coded 30 minutes from `LastUpdateDate`. |
| Cleanup before reuse | A returned host is `CleanupPending` until the previous user's account and mount are really gone. Checkout never picks a pending host, cleanup is retried automatically, and `manage-lease.sh` keeps the lease while a user is still signed in. |
| Session resume (opt-in) | The host agent used to kill the desktop the moment a user disconnected, so "resume within the grace period" only returned the same VM and profile. The new Host Setting **Keep sessions alive during the grace period** (off by default) preserves the session until grace expires, which also makes idle disconnects resumable. |
| Host readiness | The connectivity probe runs every 2 minutes in parallel, through a narrow network-status endpoint, and only writes changes. |
| API throughput | Gunicorn workers, threads and timeouts, with a DB concurrency limit sized for the SQL tier (new `sqlDatabaseSkuName` parameter). JWKS and Graph tokens are cached, every outbound call has a timeout, the group check is skipped when a role already authorizes, the SSH key is cached, and UIDs come from a SQL sequence. |
| Checkout | One SSH session instead of six to eight. `create-user.sh --password-stdin` handles the groups and the password, with a fallback for hosts running the older script. |
| Apply Now | Parallel, bounded, and deadline-limited. Hosts it doesn't reach converge on their next reconcile. |
| Access control | Reader, Operator and Admin (`FullAccess`) roles are enforced in the API. The bare `access_as_user` scope no longer grants access, except through the temporary `ALLOW_LEGACY_SCOPE_ACCESS` toggle. The portal is role-aware and never receives Linux passwords. Raw "Update attributes" is Admin-only. Operators get Maintenance on/off and Retry cleanup. |
| Checkout when the pool is full | `CheckoutVm` rolled back the database driver's own transaction when no host was free, so SQL Server raised error 266 and the API answered 500 instead of 409. Fixed in `042`. |
| Rollout | The schema is migrated before new images start. Apps restart in the order API → task → front end. |
| Tests | SQL contract tests against SQL Server 2022 with `READ_COMMITTED_SNAPSHOT` on, Broker API tests against that database through the real driver (`api/tests_integration`), host script tests in an Ubuntu container, and task function tests, all in CI. |

Schema and procedure changes are `sql_queries/040`–`066`; see `sql_queries/README.md`.

---

## Phase 2: admin console

The portal today is a well-built view over the broker's tables. Phase 2 turns it into an
operations console: it shows live state, offers actions that change the real world, and
answers "who did what".

### 2.1 Real host actions and drain

**Status: Planned** · depends on Phase 1 (roles, stop mode, power sync, `CleanupPending`)

**Why.** "Update attributes" (`front_end/web/src/pages/vm/UpdateVmAttributes.tsx`,
`sql_queries/017_create_procedure-UpdateVmAttributes.sql`) edits `PowerState`,
`NetworkStatus` and `VmStatus` directly in SQL. Setting Power to On doesn't start the VM.
Phase 1 makes it an Admin-only repair tool that keeps the lifecycle invariants, and gives
Operators a safe Maintenance toggle for *unassigned* hosts. What's still missing is taking
an *assigned* host out of rotation without stranding its user, plus real power actions.

**Design.**
- API: `POST /api/vms/<vmid>/start`, `/stop` (uses the rule's stop mode, or an explicit
  `{"mode": "Deallocate"}`), `/restart`, `/drain`, `/undrain`, and `POST /api/vms/sync`,
  which runs the Phase 1 Azure power-state sync on demand. Operator role; `stop` on a
  checked-out host needs Admin plus confirmation.
- Drain semantics: add a `DrainRequested` flag rather than a new `VmStatus`, so the
  existing lifecycle states and CHECK constraint stay untouched.
  - `CheckoutVm` skips flagged hosts for new users, but lets the existing user reconnect.
  - When the assignment ends, the Phase 1 cleanup-pending completion moves the host to
    `Maintenance` instead of `Available`.
  - The scaler never powers off a draining host that still has a user.
- The Phase 1 "Update attributes" data-repair tool stays Admin-only and gains an explicit
  warning banner in the portal.
- UI: an action menu on the host list and details page: Start, Stop, Restart, Drain,
  Return to service. Each confirm dialog names the host and its current user.

**Open questions.** Should Restart on a host with a user send a broadcast warning first
(see 2.10)? Should Drain have a deadline after which the user is signed out?

**Done when.** No admin workflow needs "Update attributes". Draining a host never strands
an account or mount. Every action is written to the audit log (2.4).

### 2.2 Host heartbeat and fleet health

**Status: Planned** · no dependencies

**Why.** The only thing a host reports today is the settings version it applied
(`/api/hosts/<hostname>/settings/ack`). Answering "which hosts run the old agent", "is NFS
mounted", "is xrdp up" or "is this host wedged" means SSHing into each one. Host logs are
local files (`/var/log/release-session.log`, `/var/log/createuser.log`,
`/var/log/linuxbroker-host-settings.log`).

**Design.**
- SQL: `dbo.HostHeartbeats` holds one current row per host (Hostname, ReceivedAt,
  AgentVersion, OsId, OsVersion, Desktop, XrdpVersion, XrdpActive, NfsReachable,
  LoadAverage, MemoryAvailableMb, RootDiskFreePct, SessionsJson). A capped history table is
  optional. `RecordHostHeartbeat` upserts it.
- API: `POST /api/hosts/<hostname>/heartbeat` (LinuxHost role plus group, the same
  validation as ack; bounded payload size; unknown keys dropped).
  `GET /api/hosts/health` (Reader).
- Host agent: `release-session.sh` already inventories sessions on every timer run. It
  should also collect the fields above and send one heartbeat per run. That call replaces
  the separate settings ack by carrying `SettingsVersion`, while keeping the ack for older
  API builds. An `AGENT_VERSION` constant goes in every host script, so drift is visible.
- Portal: a **Fleet health** page listing each host's last seen time, agent, OS and xrdp
  versions, NFS status, load and memory, and flags such as "stale > 3 reconcile intervals",
  "xrdp down", "agent outdated" and "settings drift". Dashboard attention counts come from
  the same data.
- The task function can mark a host `Unreachable` when its heartbeat is stale, even if TCP
  22 still answers.

**Open questions.** How long to keep heartbeat history? Should it double as the readiness
signal at boot, replacing the TCP probe?

**Done when.** An operator can find outdated, wedged or NFS-broken hosts without SSH, and
every host reports its agent version.

### 2.3 Sessions and users

**Status: Planned** · depends on 2.2 (heartbeat carries session state) and Phase 1 roles

**Why.** The commonest helpdesk question is "where is this user and why can't they
connect?" Today you search the VM list for a username, and nothing shows connected versus
disconnected state, when the disconnect happened, how much grace is left, or how long the
user has been idle. The host knows all of it (`xrdp-who-xorg.sh`, `disconnected_users.tsv`,
`xprintidle`).

**Design.**
- Data: the heartbeat's `SessionsJson` holds, per user, state
  (active/disconnected/unknown), session start, disconnected-since and idle seconds. SQL
  joins it with `VirtualMachines` (Username, LeaseId, ReleasedDate from Phase 1) and
  `VmUsers`.
- API: `GET /api/sessions` and `GET /api/users/<username>` (Reader). Actions (Operator):
  - `POST /api/sessions/<hostname>/<username>/signout` terminates the logind session.
    The next reconcile releases the host.
  - `POST .../message` shows a notification in the session (reuses `warn_idle_user`).
  - `POST /api/users/<username>/reset-profile` (Admin) renames the NFS home to
    `<name>.reset-<timestamp>` so a fresh profile is created at the next checkout. It's
    only allowed when the user holds no lease.
- Host: a new allowlisted script, `session-control.sh`, with validated `signout`, `message`
  and `reset-profile` verbs. It follows the `manage-lease.sh` pattern, so the API never
  needs broader sudo.
- Portal: a **Sessions** page with a search box ("find user"), state badges, a grace
  countdown, idle time, and actions. The user detail view shows the current host and past
  hosts (from the `VirtualMachinesHistory` temporal table).

**Open questions.** Do we need a "reconnect to a specific host" override for support
cases? Should profile resets be kept, and for how long?

**Done when.** A helpdesk Operator can find a user, see why they're stuck, and fix it
without SSH or the database.

### 2.4 Admin audit log

**Status: Planned** · depends on Phase 1 roles (the actor identity)

**Why.** Nothing records who deleted, released or returned a host, who changed a scaling
rule, or who pushed settings. `LinuxHostSettings` is temporal and has `UpdatedBy`, but the
portal doesn't show that history.

**Design.**
- SQL: `dbo.AuditLog` (AuditId, OccurredAt, ActorOid, ActorName, ActorType
  user/service, Action, TargetType, TargetId, Outcome success/failure/denied, DetailJson,
  CorrelationId) plus a paged reader, following `037`–`039`.
- API: a single `audit(action, target, outcome, detail)` helper called by every mutating
  handler and every authorization denial on a mutating route. The actor comes from the
  validated token (`oid`, `preferred_username` or app ID). A failure to write the audit
  entry never fails the operation, but it is logged.
- Portal: an **Audit** page (Reader) with filters for actor, action, target and date, plus
  CSV export. The host settings page gains **Version history** with a field-by-field diff
  from `LinuxHostSettingsHistory`.

**Open questions.** Retention: forever in SQL, or export to Log Analytics after N days?

**Done when.** Every portal action and every broker-initiated action (scaling, sweep) is
attributable.

### 2.5 Scaling policy and schedules

**Status: Planned** · depends on Phase 1 scaling fixes

**Why.** Phase 1 makes a single rule authoritative. Real pools have daily patterns, and AVD
scaling plans solve that with ramp-up, peak, ramp-down and off-peak phases in a named time
zone.

**Design.**
- SQL: `dbo.ScalingSchedules` (ScheduleId, Name, TimeZone, DaysOfWeek, StartTime, plus
  per-phase MinVMs, MaxVMs, ratios, increments, StopMode, and optional "force sign-out
  idle/disconnected after N minutes" for off-peak). `TriggerScalingLogic` resolves the
  active phase with `AT TIME ZONE`. If no schedule matches, the Phase 1 rule applies.
- API: CRUD (Admin) plus `GET /api/scaling/preview`, which runs the decision logic
  read-only against current counts and returns what the next run would do and why.
- Portal: replace the rule list with a **Scaling policy** page: the current phase, a
  "what happens next" preview, a weekly timeline, and a schedule editor with validation
  (min < max, up > down, increments ≥ 1, contiguous schedules).

**Open questions.** Do we copy AVD's "capacity threshold" semantics exactly, or keep the
up/down ratios?

**Done when.** An admin can express business hours versus nights and weekends, and see the
effect before saving.

### 2.6 Dashboard trends and unmet demand

**Status: Planned** · depends on Phase 1 scaling fixes

**Why.** The dashboard shows point-in-time counts. `VmScalingActivityLog` already has a
row every 5 minutes (running, in use, actions), which is enough for utilization trends.
What's missing is **unmet demand**: users who were told "No Linux host is available"
(checkout 409s) aren't recorded anywhere except the API logs.

**Design.**
- SQL: `dbo.CheckoutEvents` (Timestamp, Username, AvdHost, Outcome
  assigned/reused/none-available/provision-failed, DurationMs, Hostname), written by the
  checkout handler. A `GetUtilizationSeries @From, @To, @Bucket` procedure feeds the charts.
- Portal: 24-hour and 7-day charts of running, in use and max, with markers for denied
  checkouts, checkout latency percentiles, and time from scale-up to ready. They use an
  inline-SVG chart component or a small bundled library (no CDN).
- An **Attention** panel: hosts unreachable for more than N minutes, settings drift,
  outdated agents, zero ready hosts, and denied checkouts in the last hour.
- Align the dashboard's utilization figure with the scaler's definition (Phase 1): in use
  divided by powered-on, non-maintenance hosts.

**Done when.** An admin can answer "were we short on capacity this week, and when?"

### 2.7 Operator-grade host list

**Status: Planned** · depends on 2.1

**Design.**
- Row selection with bulk actions: Drain, Start, Stop, Apply settings, Delete (Admin).
- Status filter chips (Ready, In use, Released, Maintenance, Unreachable, Off), plus
  auto-refresh like the dashboard.
- Optional columns: OS, agent version, settings version, last heartbeat, session state.
- Server-side paging and filtering once pools pass a few hundred hosts. `GetVms` returns
  everything today.
- **Import from Azure** instead of typing IP addresses: list VMs in the host resource
  group tagged `broker-role=linux-host` that aren't registered yet, and register the
  selected ones through `RegisterLinuxHostVm`. "Add VM" becomes the manual fallback.
- Demote **Checkout VM** from the dashboard's primary action to a "Test brokering" tool
  (Admin). It never shows credentials; Phase 1 already strips them.

### 2.8 Navigation and readability

**Status: Planned** · after 2.3, so the new sections exist

- Navigation: **Overview · Hosts · Sessions · Scaling · Settings · Audit**.
- Hostname-first identifiers. VMID becomes a secondary detail.
- Relative times ("5 min ago") with an absolute UTC tooltip. Broker timestamps are
  database-local (UTC on Azure SQL) and currently render without a zone.
- A compact density toggle for large tables. The glass surfaces stay, but row height
  shrinks.
- An inline **lifecycle explainer** (Available → Checked out → Released → Available) on
  host pages. Admins confuse *Release* (the user disconnected, grace running) with
  *Return* (end the assignment now).
- Keyboard shortcuts for search and navigation. Keep the existing accessibility rules
  (contrast, reduced motion and transparency, no color-only status).

### 2.9 Rolling maintenance and patching

**Status: Planned** · depends on 2.1 (drain) and 2.2 (health)

**Why.** Each host is single-user and has a live session. Patching means waiting for users
to leave, which nobody wants to babysit.

**Design.** A maintenance run (Admin) picks hosts by filter or percentage, then:
1. Drains them.
2. Waits until each host has no assignment.
3. Patches: Azure Update Manager assessment or install, or Run Command with
   `dnf -y update` / `apt-get -y upgrade`.
4. Reboots.
5. Waits for a healthy heartbeat.
6. Returns the host to service.

It moves on to the next batch within a concurrency limit, keeping at least `MinVMs` ready.
State lives in `dbo.MaintenanceRuns`. The task function advances the runs.

**Open questions.** Azure Update Manager or Run Command? Update Manager supports RHEL and
Ubuntu, but needs extra permissions and is region-dependent in sovereign clouds.

### 2.10 Broadcast messages

**Status: Planned** · depends on the 2.3 host script

A portal action sends a notification to every active session, or to a filtered set ("host
restarts in 10 minutes"). It reuses the `notify-send`/`xmessage` path in
`release-session.sh` (`warn_idle_user`) through `session-control.sh message`.

---

## Phase 3: operating system and desktop support

### 3.0 Support matrix

| Target | Today | Target state |
| --- | --- | --- |
| RHEL 7 | Offered (`7-LVM`). Maintenance ended June 30, 2024; Extended Life-cycle Support only. | Remove (3.3) |
| RHEL 8 | Works. GNOME on Xorg via xorgxrdp. | Keep |
| RHEL 9 | Works, and it is what production uses. Xorg is deprecated but present. | **Primary target** |
| RHEL 10 | Not offered. **Red Hat removed the Xorg server (Xwayland only), and GNOME is Wayland-only.** | Needs a new remoting backend (3.5) |
| Ubuntu 24.04 | Offered and the **Bicep default**, but it deploys the **server** image and the desktop install is commented out (`Configure-Ubuntu24_desktop-Host.sh`, `DEPLOYMENT.md`). It isn't a usable desktop. | Complete it (3.1) |
| Ubuntu 26.04 | Not offered. GNOME is Wayland-only (Ubuntu 25.10 dropped "Ubuntu on Xorg", and GNOME 49 removed X11). Xorg remains for other desktops. | XFCE/MATE with xrdp (3.2), or the 3.5 backend |
| Rocky / Alma 9 | Not offered | Optional (3.7) |

The current design depends on **Xorg** in three places:
- xrdp's `xorgxrdp` backend.
- Session inspection: `xrdp-who-xorg.sh` uses `ps -C Xorg` and the `xrdp_display` sockets.
- Idle detection: `xprintidle` against the X display.

Every distribution that is going Wayland-only needs either a desktop that still runs on
Xorg, or a different remoting stack.

### 3.1 Ubuntu 24.04 as a real desktop target

**Status: Planned** · no dependencies

**Quick win, do it first:** change the Bicep default `linuxHostOsVersion` from `24_04-lts`
to `9-LVM` until Ubuntu is complete. Today a default `azd up` with Linux hosts produces
hosts with no desktop.

**Design.**
- `Configure-Ubuntu24_desktop-Host.sh` takes `LINUXBROKER_DESKTOP` (`gnome` | `xfce`, 3.2):
  - `gnome`: `ubuntu-desktop-minimal`, with the xrdp session started as "Ubuntu on Xorg"
    (set `GNOME_SHELL_SESSION_MODE=ubuntu`, `XDG_CURRENT_DESKTOP=ubuntu:GNOME`,
    `XDG_SESSION_TYPE=x11` in `startwm.sh` or `/etc/xrdp/startubuntu.sh`).
  - `xfce`: `xfce4 xfce4-goodies` with `xfce4-session` as the xrdp session.
- polkit rules so xrdp sessions don't show admin prompts for colord ("create a color
  managed device") and PackageKit ("refresh system repositories"). These are well-known
  xrdp-on-Ubuntu papercuts.
- Disable the GNOME initial-setup wizard and "What's new" tour for broker-created users.
- Firefox: the Ubuntu archive ships it as a snap. Validate it with the NFS-backed home
  (3.4), and if that's unreliable switch to Mozilla's APT repository.
- Agent parity: merge `linux_host/session_release_buffer/RHEL/release-session.sh` and
  `.../Ubuntu/release-session.sh` into one script with distribution detection. The copies
  differ only in `ensure_jq_installed` and the RHEL-only orphaned-mount cleanup, which
  Ubuntu should have too. Update the CSE and `Migrate-LinuxHostReleaseAgent.ps1`. Delete
  the unused `xrdp-who-xnc.sh`.
- Bicep: map `24_04-lts` to the same server image, since the desktop is installed on top.
  Rename the parameter value or add `24_04-desktop` for clarity. Update `DEPLOYMENT.md` and
  the README's supported-distributions list.

**Done when.** A default Ubuntu deployment yields a working GNOME (and XFCE) desktop through
the AVD RemoteApp, and passes the 3.4 checklist.

### 3.2 Desktop environment choice

**Status: Planned** · after 3.1

**Why.** GNOME Shell under xrdp renders in software (llvmpipe) and costs a lot of CPU per
session. XFCE and MATE are native X11 desktops: much lighter, and not affected by GNOME's
move away from X11. That matters even more with multi-session hosts (4.3).

**Design.**
- Bicep parameter `linuxHostDesktop` (`gnome` default, `xfce`, `mate`) passed to every CSE.
  On RHEL, XFCE and MATE come from EPEL.
- Host settings: the screen-lock policy is dconf/GNOME-only (`apply-host-settings.sh`).
  Add an XFCE branch (`xfconf` system defaults plus kiosk locks for
  `xfce4-screensaver` / `light-locker`), selected by detecting the installed desktop. The
  portal should show a note when a setting doesn't apply to the fleet's desktop.
- The heartbeat (2.2) reports the desktop, so mixed fleets are visible.

### 3.3 Retire RHEL 7

**Status: Planned** · no dependencies

Remove `7-LVM` from `deploy/bicep/main.bicep`, `main.resources.bicep`, `modules/Linux/main.bicep`
and the regenerated `main.json`. Delete `custom_script_extensions/Configure-RHEL7-Host.sh`
and remove RHEL 7 from the README and `DEPLOYMENT.md`. Existing RHEL 7 hosts keep working,
but new deployments can't choose it.

### 3.4 GNOME validation and the login keyring

**Status: Planned** · run it on the RHEL 9 fleet now, and on Ubuntu after 3.1

**Why.** Every checkout sets a **new random password** (`generate_secure_password()` then
`chpasswd` in `api/app.py`), and the home directory roams on NFS. GNOME Keyring encrypts the
login keyring with the password the user had when it was created, so from the second
session on, automatic unlock at login is expected to fail. Browsers, VS Code and other
libsecret apps would then prompt for a password the user never knew. This needs
confirming on a real host.

**Test checklist** (per distribution and desktop):
- [ ] With **Keep sessions alive during the grace period** on (Phase 1, off by default):
      disconnect and reconnect within grace resumes the same desktop, including from a
      different AVD host. An idle disconnect resumes. At grace expiry the session and Xorg
      are gone and cleanup completes. Memory held by disconnected sessions stays within
      the VM size.
- [ ] First login; second login on a *different* host; keyring unlock prompts.
- [ ] Browser: the Firefox snap (Ubuntu) and Flatpak (RHEL 10+) behave with an NFS home.
      Profile lock after an unclean disconnect.
- [ ] Disconnect, then reconnect inside the grace period and resume the same session.
- [ ] Reconnect after the grace period expires: a fresh session with the profile intact.
- [ ] The idle warning appears, and the idle disconnect preserves the session.
- [ ] Clipboard in both directions, audio, resolution change, multi-monitor, full screen.
- [ ] Screen lock posture matches the Host Settings profile, and lock after reconnect.
- [ ] GNOME Tracker/LocalSearch and other indexers aren't crawling the NFS home.
- [ ] `~/.cache` size and I/O on NFS during normal use (feeds 4.6).
- [ ] Log off cleans up: the account is removed, the home is unmounted, and the profile on
      the share is intact.

**Keyring fix options** (decide after testing):
1. A stable per-user secret instead of a password rotated at every checkout. Store it in
   Key Vault keyed by `VmUsers.uid`, and rotate it only on profile reset. This is the
   simplest, but it changes the credential model.
2. Configure `pam_gnome_keyring` so the login keyring uses an empty password, created at
   first login. Secrets are then protected only by file permissions on the NFS home.
3. Disable the gnome-keyring secrets component and use per-application stores. This breaks
   some applications.

### 3.5 RHEL 10 and Wayland-only desktops

**Status: Planned (spike)** · no dependencies

**Why.** RHEL 10 removed the Xorg server. GNOME on Ubuntu 25.10+ is Wayland-only. The
upstream answer for multi-user remote desktops is **GNOME Remote Desktop** in its headless
"remote login" mode (GNOME 46+), which provides RDP sessions through GDM.

**Spike questions.**
- Can gnome-remote-desktop serve concurrent headless sessions for broker-created users, with
  per-user credentials set at checkout?
- How do we detect session state (connected, disconnected, idle) without Xorg? Candidates:
  `loginctl` session properties, GNOME Remote Desktop D-Bus, and Mutter idle monitor over
  D-Bus.
- Does a reconnect return to the same session? What is the lock-screen behavior?
- Performance and codec support (it uses the RDP graphics pipeline) compared with xrdp.

**Design direction.** Introduce a "remoting backend" abstraction in the host agent:
`session_list`, `session_state`, `idle_seconds`, `disconnect` and `terminate`, with an
`xrdp-xorg` implementation (today's code) and a `gnome-remote-desktop` implementation.
The broker API doesn't change. Checkout still returns a host and credentials, and the AVD
side still launches `mstsc`.

**Done when.** There is a written go/no-go with a prototype on RHEL 10, and the remaining
work is estimated as a follow-up item.

### 3.6 xpra application mode

**Status: Planned (decision)**

`avd_host/broker/Connect-LinuxBroker.ps1` accepts an application name for xpra mode, but
the branch is a stub (`# Add XPRA command`). The host scripts still install xpra from
third-party repositories and open TCP 443, and the README advertises "virtualized
applications". Either:
- **Implement it:** publish individual Linux apps as AVD RemoteApps. Each RemoteApp calls
  the broker with `-Mode <app>`, and the script launches the xpra client (bundled on the AVD
  image) against the checked-out host in seamless mode. Or
- **Remove it:** stop installing xpra, close 443, and correct the README.

### 3.7 Rocky Linux and AlmaLinux 9 (optional)

The RHEL 9 script works with little change: skip `subscription-manager` and use the
distribution's CRB repository name. That's useful where RHEL subscriptions are an obstacle.
Add `rocky-9` and `alma-9` image mappings. `Migrate-LinuxHostReleaseAgent.ps1` already
treats `rocky` and `almalinux` as RHEL-like.

---

## Phase 4: strategic scale

### 4.1 Start a host on demand at checkout

**Status: Planned** · depends on Phase 1 (readiness and scaling fixes)

**Why.** When the pool is exhausted, the user sees "No Linux host is available right now.
Try again in a few minutes." (`Connect-LinuxBroker.ps1`). The script retries three times
immediately, and nothing starts until the next 5-minute scaling run.

**Design.**
- API: when `CheckoutVm` finds nothing, call a new `ReserveVmForStart`. It locks a
  powered-off Available host (respecting `MaxVMs` and a cap on pending starts), marks it
  `On`/`Unreachable`, starts it in Azure, and answers `202 {"status": "Starting",
  "retryAfterSeconds": 60}`.
- AVD script: on 202, show a non-modal "Your Linux desktop is starting…" window and poll
  checkout with back-off (for example 30 s, 30 s, 60 s…, up to a configurable limit).
  Keep the 409 path for "the pool is at maximum".
- Record the event for the unmet-demand metric (2.6).
- Once this exists, relax the Phase 1 `MinVMs ≥ 1` rule, so a pool can scale to zero off
  hours and wake on the first checkout.

### 4.2 Golden image and an elastic pool

**Status: Planned** · no dependencies (pairs well with 3.1 and 3.2)

**Why.** Every host builds itself at provisioning time: `dnf update` plus
`Server with GUI`, repositories, xrdp and agents (`custom_script_extensions/*`). That's slow
and non-deterministic. Hosts drift with the upstream package state, and the pool size is
fixed by `linuxHostCount`. Scaling can only power existing VMs.

**Design.**
- An image pipeline (Azure Image Builder or Packer) builds per distribution and desktop,
  with packages, xrdp config, agents and hardening baked in, and publishes to an **Azure
  Compute Gallery** replicated to the deployment regions (Gallery is available in
  Government).
- Bicep: `linuxHostImageId` (gallery image version). When it's set, the CSE only writes
  configuration (API URL, client ID, settings seed). cloud-init is an alternative.
- Elastic pool: a pool manager (new task-function timer plus API endpoints) creates hosts
  from the image when the pool is at `MaxProvisioned` but needs more, and deletes idle
  surplus hosts. This needs VM Contributor-level rights and network join on the subnet,
  so run it under its own identity rather than widening the API's role.
- Scripts are pinned to the image version, which also fixes supply-chain concerns about
  hosts downloading `main` at boot (see hardening).

### 4.3 Multi-session Linux hosts

**Status: Planned** · depends on 2.2 (session reporting); benefits from 3.2 (a lighter desktop)

**Why.** Every Linux VM serves exactly one user (`CheckoutVm` assigns the whole VM, and
`VirtualMachines.Username` is a single column). This is the biggest cost lever. xrdp
supports many concurrent sessions, and the host agent already works per user (per-user
lease files, releases and grace timers).

**Design.**
- SQL: a new `dbo.VmAssignments` table (AssignmentId, VMID, Username, LeaseId,
  Status CheckedOut/Released, AvdHost, CheckedOutDate, ReleasedDate) and
  `VirtualMachines.MaxSessions` (default 1, which preserves today's behavior).
  `VmStatus` becomes host-level only (Available / Draining / Maintenance). `CheckoutVm`
  picks a host by load-balancing mode: breadth-first (fewest sessions) or depth-first
  (fullest below max, which saves cost).
- A migration moves existing assignments from `VirtualMachines` columns into
  `VmAssignments`. The legacy columns become a computed or compatibility view during the
  rollout.
- API: release, return and sweep work per assignment. `delete_remote_user` is unchanged,
  because it's already per user.
- Scaling: utilization = sessions ÷ (serviceable hosts × MaxSessions).
- Host: per-user resource limits through systemd `user-.slice` drop-ins (CPUQuota,
  MemoryMax), private `/tmp` per user (`pam_namespace`), and per-host session caps.
- Portal: hosts show N/M sessions, and the Sessions page (2.3) becomes the primary view.

**Open questions.** Sizing guidance per desktop. Noisy-neighbor limits. Whether some users
or pools should stay single-session (see 4.4).

### 4.4 Host pools

**Status: Planned** · depends on 2.5 (policy per pool)

**Why.** One undifferentiated pool can't serve users who need GPUs, bigger VMs or a
different image.

**Design.**
- `dbo.HostPools` (PoolId, Name, Image, VmSize, LoadBalancing, MaxSessions) and
  `VirtualMachines.PoolId`. Scaling policy and host settings become per pool
  (`LinuxHostSettings.SettingsScope` gains pool scope).
- Checkout takes a `pool`. Each pool is a separate AVD RemoteApp whose command line passes
  `-Pool <name>` to `Connect-LinuxBroker.ps1`.
- Portal: a pool selector across the hosts, scaling and settings pages.

### 4.5 AVD scaling plan for the pass-through host pool

**Status: Planned** · no dependencies

The Windows AVD hosts only run `mstsc`, but they're deployed without any autoscale
(`deploy/bicep/modules/AVD/main.bicep` has no `scalingPlans` resource). Add a
`Microsoft.DesktopVirtualization/scalingPlans` resource for the pooled host pool, with
ramp-up, peak, ramp-down and off-peak parameters and a time zone. Assign **Desktop
Virtualization Power On Off Contributor** to the Azure Virtual Desktop service principal on
the host resource group; its app ID differs in sovereign clouds, so parameterize it.

### 4.6 NFS home performance

**Status: Planned** · informed by 3.4

**Why.** Every user's home, including caches, is on a Premium Azure Files NFS share that
defaults to 100 GiB (`deploy/bicep/modules/core/nfs-storage.bicep`). Premium performance
scales with provisioned size: 100 GiB gives roughly 3,100 baseline IOPS. Desktop sessions
generate many small I/Os, especially browser and GNOME caches and indexers.

**Design.**
- A sizing guide by concurrent users, and a Bicep default that reflects it.
- Keep caches local: `/etc/profile.d/linuxbroker-cache.sh` sets
  `XDG_CACHE_HOME=/var/tmp/xdg-cache/$USER`, with `systemd-tmpfiles` cleanup. Point
  browser disk caches at it. Disable GNOME Tracker/LocalSearch indexing of NFS homes.
- Mount tuning per Azure Files NFS guidance (`nconnect=4` is already set; consider
  `read_ahead_kb`).
- Alerts on share throttling (`Transactions` with `SuccessWithThrottling`) and
  end-to-end latency, via 4.7.

### 4.7 Host log shipping and observability

**Status: Planned** · pairs with 2.2

- Deploy the Azure Monitor Agent to Linux hosts, plus a Data Collection Rule for
  `/var/log/release-session.log`, `/var/log/release-session-watcher.log`,
  `/var/log/linuxbroker-host-settings.log`, `/var/log/createuser.log`,
  `/var/log/xrdp*.log` and syslog. The logs go to the existing Log Analytics workspace.
- A workbook covering release and return rates, checkout latency (from API traces),
  settings-apply failures, per-host error spikes and NFS mount failures.
- Alerts: no ready hosts, denied checkouts, a host with no heartbeat, API 5xx rate, and
  share throttling. Action groups can notify email or Teams.

### 4.8 Tuning the double RDP hop

**Status: Planned**

The user's session is RDP inside RDP: AVD outer, `mstsc` to xrdp inner.
- xrdp ≥ 0.10.2 supports **H.264** in the graphics pipeline. Check the version on each
  distribution (`xrdp --version`) and enable GFX/H.264 in `xrdp.ini` where available.
- Have `Connect-LinuxBroker.ps1` write an `.rdp` file instead of `mstsc /v:`, to set
  `session bpp`, `networkautodetect`, `bandwidthautodetect`, `connection type`, wallpaper
  and font smoothing, full screen and multi-monitor.
- Measure CPU on both hops with GNOME versus XFCE, which feeds 3.2 and 4.3.

### 4.9 Scaling out the portal and API

**Status: Planned**

- The BFF uses filesystem sessions (`front_end/app.py`), which rely on ARR affinity when
  scaled out. Move to a shared session store, or keep affinity and document it.
- The API opens a new `pymssql` connection per request. Phase 1 caps the concurrency per
  process. Add real pooling, ideally together with the move to Entra (passwordless) SQL
  authentication (hardening).
- Split the task function onto its own plan, or use a Flex Consumption plan, if its timers
  compete with the API.

---

## Security hardening backlog

A separate track, prioritized independently of the phases.

| Item | Why | Direction |
| --- | --- | --- |
| API connects to SQL as the **server admin** | `DB_USERNAME` is the SQL admin login (`deploy/bicep/main.resources.bicep`) | A contained database user with EXECUTE on the broker procedures only, or Entra managed-identity authentication (pyodbc with an access token) |
| `avdadmin` sudo allowlist is root-equivalent | `usermod`, `userdel`, `groupadd` and `chpasswd` with arbitrary arguments (`Configure-*-Host.sh`) | Once every host runs `create-user.sh --password-stdin` (Phase 1), drop `chpasswd`, `groupadd` and `usermod`. Move `userdel` into `manage-lease.sh`. The allowlist then holds only validated scripts. |
| SSH host keys not verified | `StrictHostKeyChecking=no` in `run_remote_command` | Record host keys at provisioning (Key Vault or SQL) and pin them, or use an SSH CA |
| RDP server identity not verified | `AuthenticationLevelOverride=0` in `Connect-LinuxBroker.ps1`; xrdp self-signed certificates | Issue xrdp certificates from Key Vault or enterprise PKI, and restore server authentication |
| Username collisions | `re.sub(r'[^a-zA-Z0-9_]', '', username)` maps `john.smith` and `johnsmith` to the same Linux account and NFS home | Derive usernames from a stable identifier (UPN plus collision check, or object ID) and keep the mapping in `VmUsers` |
| Shared SSH private key for the whole fleet | One Key Vault secret (`KEY_NAME`) | Per-host keys or short-lived SSH certificates |
| NFS `AUTH_SYS` trust | `sec=sys`, `NoRootSquash` (`nfs-storage.bicep`, `create-user.sh`); root on any host in the subnet can read every home | Restrict private endpoint access to the Linux host subnet with an NSG. Consider Azure NetApp Files with Kerberos (krb5p) for strong isolation. |
| Hosts download scripts from `main` at provisioning | `scriptSourceRoot` defaults to the `main` branch | Pin to a release tag or commit and verify checksums, or bake scripts into the image (4.2) |
| Checkout abuse | The AvdHost role can check out any username | Rate-limit per AVD host. Optionally verify that the username belongs to the user signed in to that AVD session. |
| Committed test artifacts | `flask_session/` files are tracked, although they're in `.gitignore` | `git rm` them |

---

## Decisions log

| Date | Decision |
| --- | --- |
| 2026-09 | Roles: **Reader** (view), **Operator** (release/return, maintenance, apply settings), and **Admin** (`FullAccess`, everything). They are enforced in the API. The bare `access_as_user` scope no longer grants access. There is a temporary `ALLOW_LEGACY_SCOPE_ACCESS` toggle for upgrades, off by default. |
| 2026-09 | Scale-down **powers off by default**. Admins can switch a scaling rule to **Deallocate** in the portal, after being shown the cost, start-latency and capacity-risk trade-offs. |
| 2026-09 | Only one scaling rule is active (the lowest RuleID) until schedules (2.5) land. Creating a second rule is rejected. |
| 2026-09 | The fix that makes scaling really start and stop VMs goes **active immediately** on upgrade, with no observe-only mode. This is called out in the upgrade notes. |
| 2026-09 | `MinVMs ≥ 1` until start-on-demand (4.1) exists, because a pool at zero can't recover without it. |
| 2026-09 | If the Azure power-state sync fails, scaling proceeds with a logged warning. Azure power operations are idempotent, and this is no worse than before the sync existed. |
| 2026-09 | Session preservation during the grace period is an **opt-in Host Setting**, off by default. It can't be combined with the screen lock, because a resumed session behind a lock screen can't be unlocked with a rotating password. |
| 2026-09 | A returned host isn't offered for checkout until the previous user's cleanup succeeds (`CleanupPending`). |
| 2026-09 | This roadmap lives in `docs/ROADMAP.md` and is updated as items land. |

## Glossary

- **Checkout.** The AVD host asks the broker for a Linux host for a user. The broker
  assigns a host (or reuses the user's existing assignment), creates the Linux account,
  mounts the NFS home, sets a one-time password, and returns the host and credentials.
- **Lease.** A GUID that identifies one assignment (`VirtualMachines.LeaseId`, and on the
  host `/var/lib/linuxbroker-release-session/leases/<user>.lease`). Clean-up only acts
  when the lease matches, so a stale clean-up can't remove a newer user.
- **Release.** The host agent reports that the user disconnected. The host is `Released`,
  and the user can reconnect within the grace period.
- **Grace period.** `GracePeriodSeconds` in Host Settings. The host signs a disconnected
  user off when it expires. With **Keep sessions alive** on, the desktop survives until
  then; otherwise it is closed at disconnect and only the assignment is held. The server's
  sweep returns the host after grace, plus one reconcile interval, plus 60 seconds.
- **Return.** Ends the assignment. The host is marked `CleanupPending` until the Linux
  account is removed and the home unmounted (the profile on the share is kept), and only
  then does it become available for checkout.
- **Reconcile run.** One execution of `release-session.sh`, from the systemd timer or the
  logind watcher.
