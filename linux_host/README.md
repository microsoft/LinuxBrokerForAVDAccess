# Linux broker lease helpers

These helpers preserve the local-account/NFS model while making provisioning, credential rotation, session observation and reclamation generation-fenced. RHEL and Ubuntu use the same lifecycle implementation; their deployed `release-session.sh` names and timer/logind entrypoints remain unchanged.

## Installation contract

Deployment must install these files together, owned by `root:root`, executable with mode `0755`, using LF line endings:

| Repository source | Installed path |
| --- | --- |
| `create-user.sh` | `/usr/local/bin/create-user.sh` |
| `manage-lease.sh` | `/usr/local/bin/manage-lease.sh` |
| **New:** `broker-lease.py` | `/usr/local/bin/broker-lease.py` |
| **New:** `broker-freezer.py` | `/usr/local/bin/broker-freezer.py` |
| **New:** `session_release_buffer/release-session-common.sh` | `/usr/local/bin/release-session-common.sh` |
| `session_release_buffer/RHEL/release-session.sh` or `Ubuntu/release-session.sh` | `/usr/local/bin/release-session.sh` |
| `apply-host-settings.sh` and existing watcher/inspection scripts | Retain their existing installed names |

Fresh bootstrap and migration must additionally provide a validated Python 3.9+ interpreter at **`/usr/local/libexec/linuxbroker/python3`**, using a root-owned symlink in a root-owned `0755` directory. The deployment installer currently uses the SHA256-locked private Python package in `deploy\linux-python.lock.json`, installed by `custom_script_extensions\install-broker-python.py`; an equivalent approved distro-packaged interpreter can also satisfy this core interface. Validate the selected interpreter's version and protected target before publishing the link. Do not change the OS-wide `python3` alternative and do not install an unpinned pip runtime. This runtime link is created by installation, separate from the broker helper files.

Substitute `YOUR_LINUX_BROKER_API_BASE_URL` (HTTPS URL including `/api`) and `YOUR_LINUX_BROKER_API_CLIENT_ID` in the distro wrapper. It exports those settings to the common agent. Do not substitute a Windows launcher client ID; these calls use the Linux host's registered workload identity and API audience.

Requirements: Python 3.9+, Bash, `jq`, `flock`, NFS mount tools, `iproute`/`ss`, `procps`, shadow account tools, and systemd/logind. Optional idle enforcement also uses the existing `xprintidle`/notification tools. Modern hosts use pidfds for idle disconnect; legacy hosts use the verified freezer gate instead.

The wrappers and Python shebang use only `/usr/local/libexec/linuxbroker/python3`, with isolated mode (`-I`) to ignore Python environment/site overrides. There is no `env python3` or stock-interpreter fallback. A missing link or interpreter below 3.9 fails explicitly before helper imports or host actions. Stock Python 3.6 needs the separately selected supported interpreter.

Mount inspection reads **`/proc/self/mountinfo` directly** and does not invoke `findmnt` or require its JSON/`FSROOT` options. This kernel interface has been stable since Linux 2.6.26 and is present on RHEL 7/8/9 and the supported Ubuntu kernels, including hosts with util-linux 2.23. Provisioning needs readable proc mount metadata, not a newer util-linux package for introspection.

Safe cleanup supports two verified gates, selected from actual mounted controllers rather than distribution names:

| Host controller layout | Gate |
| --- | --- |
| RHEL 7/8-style cgroup v1 | Dedicated `freezer` hierarchy plus `name=systemd` hierarchy; both XRDP services must be enrolled through the startup wrapper described below |
| Unified cgroup v2 | Existing systemd freeze/thaw support (systemd 246+) for `xrdp.service` and `xrdp-sesman.service` |

The v1 path does **not** require upgrading the OS, systemd or util-linux, and uses the deployment's private Python runtime. Missing controllers, uncertain enrollment or inconsistent freezer state block availability rather than selecting an unverified signal-based fallback. Do not freeze/thaw live services as part of unapproved validation.

The existing constrained sudo entries for `create-user.sh` and `manage-lease.sh` are sufficient for broker lease operations. Their sibling Python helper and containing directory must not be writable by the SSH account or workspace users. No direct blanket `chpasswd`, `userdel`, `mount`, `cat`, or `rm` sudo grant is needed. The timer/watcher runs as root.

`/var/lib/linuxbroker-release-session` must be root-owned and not group/world-writable. The helper uses a protected `lease.lock` and atomically replaces root-only `lease.json` (mode `0600`, file/directory fsync). Do not edit or delete these files to bypass a failed operation.

## Interfaces

```text
create-user.sh <nfs-export> <uid> <username> <lease-id> <generation> <operation-id>
manage-lease.sh migrate <username> <uid> <lease-id> <generation>
manage-lease.sh cleanup <username> <uid> <lease-id> <generation> <operation-id> <admin|expired|logged_off>
manage-lease.sh observe
manage-lease.sh disconnect-idle <username> <uid> <lease-id> <generation> <xorg-pid>
manage-lease.sh gate-status
manage-lease.sh run-xrdp <xrdp.service|xrdp-sesman.service> <absolute-daemon-path> [original arguments...]
```

Every command requires root. Provisioning reads the random password from **stdin only** and holds the same lock through account/profile verification, group setup, password rotation and marker completion. Passwords are never included in arguments, logs or marker files. The helpers emit only a fixed non-secret JSON acknowledgement or error.

`run-xrdp` is an additional **systemd/deployment-root-only** startup entrypoint, not an API sudo grant. `gate-status` is a read-only preflight; it never freezes/thaws, restarts a service or creates a controller. API sudo remains limited to provisioning, `manage-lease.sh cleanup ...`, and settings apply.

Usernames/UIDs come from the verified SQL identity mapping. New accounts use the assigned UID; an existing local account with a different UID/home is rejected. An unmarked existing account cannot be claimed. Existing profiles must have the mapped owner; they are never recursively reowned to make a mismatch disappear.

The permitted UID range is `2000..2147483646`, excluding reserved `65534` and `65535`, consistently with SQL allocation and deployment validation. An incompatible legacy UID is a migration blocker; it is never rewritten on the account or NFS profile.

The shared SQL/API/host username grammar is `[A-Za-z_][A-Za-z0-9_-]{0,31}` with additional reserved-name checks. Case is preserved. A dotted or otherwise incompatible legacy name is an explicit migration blocker, never sanitized into another name or used to rename a persistent profile; a client's broader accepted grammar does not change this server policy.

The marker/observation generation must be an integer in `1..9007199254740991`, matching the shared JSON-safe contract. Larger Int64 values are refused, not rounded by jq, narrowed to Int32 or reset. Unsafe markers block operations until authoritative recovery.

New skeletons are prepared in a private staging directory before publication. An interrupted copy cannot publish a half-owned profile. Existing profile contents remain untouched during reconnect. The verified NFS export stays mounted at `/awipsprofiles`; each user receives its local bind view under `/home/<username>`.

### Mount-state verification

The mountinfo parser separates fixed fields from optional propagation fields at the kernel's ` - ` separator. It decodes only the kernel escapes for space, tab, newline and backslash, once, and preserves non-UTF-8 filesystem bytes. It uses the actual filesystem root field for bind-home validation, not a basename guessed from a utility's display output.

Each lookup reads fresh kernel metadata and matches an exact mountpoint. It verifies the record's device against the visible path, refuses stacked target/ancestor mounts and refuses nested mounts beneath a home before cleanup. An unreadable, malformed, incomplete or ambiguous mount table is an explicit failure, never interpreted as an unmounted home. After ordinary non-lazy unmount, a fresh check must confirm the mount is gone before account removal.

The existing `LeaseManager.mount_info(Path)` interface returns exactly `target`, `source`, `fstype`, and `fsroot`, or `None` only for a verified absent mount. Its production source is fixed to `/proc/self/mountinfo`; tests can supply `Paths(mountinfo=<temporary fixture path>)` without a CLI/environment override. `parse_mountinfo(bytes)` provides a pure-parser seam for compatibility fixtures, while mount lookup also verifies the visible path's device.

## Legacy cgroup-v1 enrollment and recovery

Install `broker-freezer.py` alongside the lease helper. The host must already mount a dedicated writable `freezer` hierarchy and its `name=systemd` hierarchy, normally `/sys/fs/cgroup/freezer` and `/sys/fs/cgroup/systemd` on RHEL 7/8. Deployment may configure an absent controller explicitly, but the runtime helper never mounts it or moves unrelated processes. Combined resource-controller hierarchies, duplicate/partial mounts, symlinks and writable non-root paths are refused.

For each legacy XRDP unit, preserve its packaged `Type`, `PIDFile`, environment files, arguments, dependencies and stop behavior, but wrap its actual `ExecStart`:

```ini
[Service]
ExecStart=
ExecStart=/usr/local/bin/manage-lease.sh run-xrdp xrdp.service /usr/sbin/xrdp $XRDP_OPTIONS
```

The corresponding sesman entry uses `xrdp-sesman.service`, `/usr/sbin/xrdp-sesman` and its original `$SESMAN_OPTIONS`. `/usr/local/sbin` daemon installations are also accepted. Do not guess options or rewrite an unrecognized customized service. These stock services start privileged; the wrapper verifies that it is in the named systemd unit before executing the protected daemon.

Before `exec`, the wrapper writes **its own process** (`0`) to `cgroup.procs` under:

```text
<freezer mount>/linuxbroker-xrdp/services/xrdp.service
<freezer mount>/linuxbroker-xrdp/services/xrdp-sesman.service
```

The kernel moves the entire thread group and every future child inherits the freezer membership. Enrollment does not scan/move a running PID tree. This matters because scanning while services fork cannot establish a complete reconnect fence. The common `services` parent provides hierarchical freezing even when logind moves sessions in the separate systemd hierarchy. Cleanup itself must remain outside that subtree.

**Existing unenrolled services require a controlled enrollment restart after the host has drained.** Merely installing a drop-in and reloading systemd does not enroll current daemons or existing children. Do not forcibly log off preserved desktops or declare them migrated: leave those hosts owned/unavailable with checkout paused until an approved drain/restart, then require `manage-lease.sh gate-status` to succeed. Fresh hosts can enroll before accepting any sessions. This is a one-time service enrollment requirement, not an OS upgrade or permanent removal of RHEL 7/8 support.

The legacy backend verifies both service wrappers, live main-PID membership and all service descendants, writes `FROZEN` once at the common parent, and waits at most 20 seconds for the parent and bounded descendant set to report `FROZEN`. `FREEZING` is not success. Limits are 256 cgroups and 4096 processes/threads per inspected group; uncertainty remains retryable and unavailable.

After starting services, use `LegacyFreezer.wait_ready()` rather than assuming `systemctl start` means enrollment is complete: `Type=simple`/`exec` can report success before the wrapper joins its cgroup. The bounded startup wait still requires verified wrappers, main-PID membership, descendants and thawed state; failed/malformed service configuration is not treated as a transient success. Existing controller/directory/control-file ownership is checked before polling, so permission or permanent ownership failures are not disguised as slow startup. An exited/un-enrolled process cannot pass readiness, and a startup timeout retains the durable restart-required marker for a later guarded retry. The core restart path uses this same method.

Every active main PID must retain the expected root UID and exact systemd-unit membership, even after freezer enrollment. Before enrollment, only that root-owned in-unit process in the initial freezer root is eligible for startup waiting. Its command must match the exact shell/Python wrapper invocation, or it must be PID 1's identifiable not-yet-execed systemd child. An already executed unenrolled daemon, wrong UID/systemd membership, or unexpected freezer group is an immediate failure before sleeping, not a transient retry. An escaped descendant of an enrolled service also fails immediately even if the other service is still starting.

Membership is re-read when the wrapper can have enrolled and executed the daemon between observations. The full strict gate check still runs before readiness. A missing per-process file is retried only when that exact startup PID has disappeared while proc metadata remains available; missing files for a still-existing process and permission errors remain explicit failures.

Expiry still rechecks actual XRDP sessions inside that gate. A resumed session cancels cleanup with **no daemon reset or session signal**. When cleanup really proceeds, it verifies that the frozen subtree contains only root service processes and the matching lease UID, then invalidates cached/in-flight authentication workers rather than thawing accepted old logins after account removal. A different user's process blocks reset. Every targeted thread must actually carry the legacy kernel's `PF_FROZEN` flag and uninterruptible frozen state; stopped/vfork/mixed-privilege uncertainty cannot be treated as safe.

An explicit stop suppresses automatic restarts. Verified frozen processes receive pending `SIGKILL` and move to the thawed sibling `linuxbroker-xrdp/cleanup` only so those fatal signals can take effect without resuming cached logins; the listener subtree stays frozen. This is not enrollment of a live process tree and is never used on an unfrozen PID. Quarantine must empty before host cleanup can complete. Matching logind/user processes outside that subtree are also ended using the verified UID; legacy `loginctl` key/value output is used without `--value`.

The durable marker additionally records `gateBackend`, `gateRestartRequired`, `gateTerminated`, and the kernel `gateBootId`. A partial termination remains frozen and is completed by the next generation-guarded retry before thaw. After verified termination, account/home cleanup and controlled service restart must complete before SQL availability can be acknowledged. Interrupted thaw/restart retains recovery state; retries do not clear or guess it. A verified new kernel boot permits a fresh gate/session check, never replay of obsolete PID state. `gate-status`, provisioning and migration refuse unfinished recovery. A failed mount/account cleanup remains a failed lease even if clean daemons have been restored.

The v1 semantics are documented in the Linux kernel's [freezer controller](https://docs.kernel.org/admin-guide/cgroup-v1/freezer-subsystem.html) and [cgroup membership/inheritance](https://docs.kernel.org/admin-guide/cgroup-v1/cgroups.html) documentation. Compatibility fixtures exercise Linux 3.10/4.18-style states; actual service enrollment and XRDP/NFS behavior still require the authorized distro pilot.

## Existing active-lease migration

Pause checkout and apply SQL migrations/approved subject bindings first. Use `GetBrokerLeaseMigrationState(Hostname)` through the trusted deployment connection. For its exact returned username, UID, lease ID and generation, invoke `manage-lease.sh migrate` as root.

Migration requires the existing account's exact UID and verified NFS home. It accepts a matching legacy plain-UUID file at `leases/<username>.lease`, refuses mismatches or another user's marker, atomically writes the new structured marker, then removes the matching legacy marker. Repeating the same migration is safe. It does not create an account, choose an identity, rename a profile, or change its UID/files.

Missing/unresolved SQL ownership or conflicting markers are migration blockers, not a reason to fall back to username or hostname-only release.

## Disconnect, reconnect and expiry

The agent takes a separate reconciliation lock and asks the root helper for a fresh lease/session observation. It reports only `leaseId`, integer `leaseGeneration`, and `state` to:

```text
POST /api/vms/<hostname>/session
```

The API requires app-only `LinuxHost` authority plus the registered `(tid, oid)` binding to that hostname. There is no runtime registration, group shortcut, username fallback or current-lease recovery from an error response.

The API registration must request the `idtyp` optional access-token claim, and a host workload token must carry `idtyp=app`. Stage that registration change before activation and validate a renewed host token against the read-only `/api/hosts/settings` endpoint. IMDS may still return cached pre-change tokens; restarting the agent or making another IMDS request does not guarantee immediate replacement. Missing-claim tokens remain denied, and the agent retries without local reclamation. Keep cutover paused until the intended tokens are accepted rather than enabling a role-only fallback or logging bearer tokens.

The helper distinguishes `active`, `disconnected`, and `logged_off` using verified account ownership, XRDP Xorg processes and connected display sockets. Failure to inspect processes/sockets is uncertainty, not proof of disconnection. A newly provisioned lease with no first session reports disconnected, allowing the configured connection/grace window; logoff requires a previously observed session. The agent reports active on every reconciliation, including automatic mstsc reconnect that did not relaunch the launcher.

Initial disconnect never kills Xorg. SQL records the first disconnect time once and applies the global `GracePeriodSeconds` (default 1200). The local agent does not reclaim using an independent clock, and repeated reports/health updates cannot extend SQL's disconnect timestamp. Expiry timing includes polling latency; it is not instantaneous at the boundary.

Cleanup is a broker-reserved SQL operation, not an agent-local action. Under the host lock, the helper verifies the current lease/generation, freezes both XRDP control groups to exclude in-flight reconnects, locks new password logins and checks actual sessions again. Active expiry/logoff races are cancelled and thawed without terminating the desktop. An explicit administrative return may end the matching lease's sessions.

After ending only the mapped UID's sessions/processes, cleanup uses a verified non-lazy `umount`, removes the ephemeral account with `userdel -- <username>` (**never `userdel -r`**), and removes only an empty local mountpoint with `rmdir`. Persistent NFS files and UID are retained. A cleaned marker remains as a fencing tombstone so stale commands cannot revive or destroy a newer assignment.

Successful acknowledgement requires the selected XRDP gate to be thawed and verified ready, including controlled daemon restart when legacy reclamation discarded accepted login state. Recovery markers are durable: interruption remains unavailable and the next guarded cleanup retry recovers it. A busy mount, UID mismatch, unknown XRDP state, failed account removal or uncertain SSH result is a failure, not completed cleanup.

## Recovery

Do not reset SQL state to `Available` or clear a root marker after a timeout. The API retains the lease and operation. Owner checkout retries failed provisioning using a new generation without evicting the desktop; maintenance retries failed reclamation. Administrators refresh inventory for the latest lease/generation before a guarded return. Abandoned running reservations become retryable after the broker's 300-second operation interval.

Higher generations fence delayed workers. A password rotation cannot be repeated under an already completed generation. Cleanup is idempotent across lost acknowledgements and checks account/mount absence before acknowledging a cleaned tombstone. An older generation or another lease cannot touch the host.

Optional idle enforcement still disconnects the XRDP connection, not Xorg. It goes through the lease lock and generation check and signals only verified connection processes using pidfds on modern kernels, or the enrolled legacy freezer on older kernels. The legacy path refuses to signal the listener main PID. It does not require pidfd syscalls on RHEL 7/8.

## Safe local tests

On Linux, from the repository root:

```sh
python3 -m unittest discover -s linux_host/tests -v
```

On Windows, use an existing Linux/WSL runtime with its working directory set to this worktree. Tests use standard-library stubs for **every** account, mount, logind/systemd and process operation, temporary profiles/markers, and fake HTTP/IMDS boundaries. They execute the helper control flow, actual file locks, shell agent functions and both distro wrapper interfaces. They never execute account deletion, mounts, service freezes or signals against the test host.

These tests cover generation/UID mismatches, migration, disconnect/reconnect/logoff, interrupted provisioning, busy unmount, account-deletion failure, stale operations, profile sentinel retention, lock serialization, reconnect gating and interrupted-thaw recovery. `test_mountinfo.py` adds synthetic RHEL 7/8/9 and Ubuntu kernel-record variants, path escapes/non-UTF-8 bytes, NFS bind roots/IPv6 sources, unknown optional fields, stacked/nested mounts, device mismatch and unavailable/truncated records. It also reads the local kernel's real `/proc/self/mountinfo` without running commands or changing mount state. Lifecycle stubs now emit kernel-format mount tables rather than mocked `findmnt` JSON.

`test_legacy_freezer.py` uses temporary controller/proc trees and a fail-closed command/signal model to cover fork/descendant containment, startup self-enrollment, frozen-vs-freezing bounds, other-user exclusion, root authentication invalidation, active reconnect cancellation, account/unmount failure, exact daemon arguments, and interrupted termination/restart recovery. It never signals a live process or writes a real freezer control file.

These compatibility fixtures are not live runs on every distribution and do not replace an authorized pilot with real XRDP, NFS and Entra workload tokens. The available local WSL runtime is unified cgroup v2, so native cgroup-v1 freezer execution is not claimed by the fixture results.
