# Linux Broker for Azure Virtual Desktop (AVD) Access

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Purpose

The **Linux Broker for AVD Access** is a solution designed to manage and broker user access to Linux hosts via Azure Virtual Desktop (AVD). It provides a scalable and efficient way to connect users to Linux virtual machines (VMs) using either Remote Desktop Protocol (RDP) for full desktop experiences or xpra (X Remote Application) for virtualized applications.

This solution leverages Azure services such as managed identities, security groups, Azure App Service, Azure Functions, and Azure SQL Database to provide secure and efficient brokering, session management, and scaling of Linux hosts.


## Architecture Description

The solution consists of the following components:

- **Azure Virtual Desktop (AVD)**: Provides the interface for users to access Linux hosts. Users can connect via the AVD web client or any supported AVD client.

- **Broker Agent (`Connect-LinuxBroker.ps1`)**: A launcher running in the AVD user's Windows session. Its MSAL.NET helper uses Windows Web Account Manager (WAM) to authenticate that user to the Broker API, checks out that user's Linux workspace, saves the generated Linux credential in the user's Windows Credential Manager, and opens RDP. The shared AVD host managed identity cannot obtain Linux credentials.

- **Linux Hosts Cluster**: A set of Linux VMs that users connect to. Each Linux host has managed identity enabled and runs a Session Release Agent.

- **Session Release Agent**: A host-side reconciliation service that keeps the periodic poll as a safety net, uses XRDP/Xorg session inspection as the source of truth, and can wake early from `systemd-logind` signals to shorten disconnect detection time. It reports lease-scoped session state, preserves the desktop during the configured reconnect window, and also fetches the fleet-wide host settings profile.

- **Broker API**: A RESTful API running on Azure App Service that handles interactions between the Broker Agent, Session Release Agent, and the Broker Database. It uses managed identities and Azure Key Vault for secure access to resources.

- **Broker Database**: An Azure SQL Database that stores information about virtual machines, scaling rules, and scaling activity. It includes the following tables:
  - `virtual_machines`: Stores information about Linux VMs, including hostname, IP address, power state, network status, VM status, connected username, immutable lease ownership, disconnect time, AVD host, and VM ID.
  - `VmUsers`: Maps each verified Entra user identity to a stable Linux username and UID so the same persistent profile is mounted on every assigned host.
  - `vm_scaling_rules`: Stores scaling rules for the Linux host cluster.
  - `vm_scaling_activity`: Logs scaling activities such as VMs being turned on or off.
  - `LinuxHostSettings`: Stores the fleet-wide Linux host settings profile that administrators manage from the portal.

- **Azure Function for Scaling Tasks**: An Azure Function that runs on a schedule to manage scaling of Linux hosts based on the scaling rules. It updates VM network statuses, turns VMs on or off, and performs health checks on the Linux hosts.

- **Service Management Portal**: An administrator-only web application for managing VMs, scaling rules, host settings, and logs. It can release or return assignments but does not issue Linux passwords or connect as another user. It is a React 18 and TypeScript single-page app built with Vite and Tailwind CSS, served by a Flask backend-for-frontend that holds the Entra ID token server-side and calls the Broker API on the administrator's behalf. Both backend services enforce administrator permissions; hiding a UI control is not an authorization boundary.

- **Azure Key Vault**: Stores sensitive information such as SSH keys and database passwords, accessed securely by the Broker API using managed identity.

- **Entra Users and Workload Identities**: Workspace users and portal administrators have separate delegated permissions. Linux hosts and scheduled tasks use application roles on their managed identities. Each Linux host identity is registered against its own host; a caller-supplied hostname is not proof of host identity.

The architecture ensures secure, efficient, and scalable management of Linux host access via AVD.

The two sign-ins are deliberately separate: Entra authenticates the user's request to the broker, while the generated local Linux password authenticates the RDP connection. Linux hosts do not need to be domain joined, and no Entra token is passed to Linux for user login.

## List of Services

- **Azure Virtual Desktop (AVD)**: Provides virtual desktop infrastructure.
- **Broker Agent (`Connect-LinuxBroker.ps1`)**: PowerShell entry point and per-user MSAL/WAM Windows helper on AVD hosts.
- **Linux Hosts Cluster**: The set of Linux VMs users connect to.
- **Session Release Agent**: Systemd-timer-based reconciliation service on Linux hosts, optionally accelerated by a `systemd-logind` watcher.
- **Broker API**: RESTful API for brokering connections and managing VMs.
- **Broker Database**: Azure SQL Database for storing VM and scaling data.
- **Azure Function for Scaling Tasks**: Manages scaling of Linux hosts.
- **Service Management Portal**: React and TypeScript front-end application for administrators, served by a Flask backend-for-frontend.
- **Azure Key Vault**: Secure storage for SSH keys and passwords.
- **Managed Identities**: Used for secure authentication between components.
- **Entra App Roles and Assignments**: Separate workspace access, portal administration, and workload permissions.

## User Workflow

1. **User Logs into AVD**: The user accesses the AVD web client or any supported client.
2. **Selects Linux Host Connection**: The user selects a desktop icon for full RDP session or an application for xpra session.
3. **Broker Agent Initiates Connection**:
   - The Broker Agent (`Connect-LinuxBroker.ps1`) authenticates the signed-in user to the Broker API, using silent Windows SSO when available and an interactive sign-in when required.
   - The API resolves the user's Linux username and UID from the verified Entra identity, not a username supplied by the launcher.
   - It reuses that user's existing assignment or checks out an available Linux VM.
   - The user's ID is added to the Linux host with a unique 25-character password.
   - The user is added to appropriate user groups on the Linux host for RDP or xpra access.
4. **User Connects to Linux Host**: The user is connected to the Linux host via RDP or xpra and can work as needed.
5. **Session Management**:
   - If the user disconnects or logs off the Linux RDP session, the Session Release Agent on the Linux host reconciles the XRDP/Xorg session state immediately when possible and otherwise on the next safety-net poll.
   - A reconnect timer is initiated, 20 minutes by default and configurable from the portal.
   - If the user reconnects within that window, they resume their session. Automatic RDP reconnects are reconciled even when the launcher is not run again.
   - If not, the matching session is terminated and the temporary local account is removed after its profile mount is safely detached. Persistent profile files are retained.
   - The VM becomes available to another user only after cleanup succeeds. An unreachable host or failed cleanup remains unavailable for reassignment.

An expired Entra token does not itself terminate an established Linux session. The next request to the broker must authenticate again. Silent SSO depends on the Windows session, consent, and tenant policies; it is not guaranteed to be prompt-free.

The reconnect clock tracks the **Linux XRDP connection**, not just the outer AVD connection. Disconnecting from AVD can leave `mstsc` running and connected inside Windows; that Linux session is still active. Check both connection layers during the deployment pilot rather than assuming an AVD disconnect also disconnects Linux.

The desktop launcher is the supported connection path. The existing non-desktop `Mode` interface does not constitute a completed xpra launcher.

## Admin Workflow

1. **Access Service Management Portal**: Explicitly assigned broker administrators log into the front-end portal. Ordinary AVD users cannot access its management pages or APIs.
2. **Manage VMs**:
   - **Add VMs**: Register new Linux VMs into the system.
   - **Delete VMs**: Remove VMs from the system.
   - **Update VM Attributes**: Modify VM statuses (e.g., set to maintenance), without bypassing active-lease or cleanup safeguards.
   - **Return an Assignment**: Use the current lease guard to request safe cleanup. A stale page cannot silently return a newer user's assignment.
3. **Manage Scaling Rules**:
   - **Create/Update/Delete Scaling Rules**: Adjust scaling rules to control the minimum and maximum number of VMs, scale-up/down ratios, and increments.
4. **Manage Linux Host Settings**:
   - **Edit the fleet-wide profile**: Change the reconnect grace period, reconcile interval, watcher timings, idle session timeout, and screen lock policy without editing or redeploying any script.
   - **Apply Now**: Optionally push the profile to hosts immediately instead of waiting for them to pick it up.
   - **Review drift**: See which hosts have applied the current settings version.
5. **Monitor System**:
   - **View VM Details**: Access detailed information about VMs.
   - **View Scaling Activity Logs**: Monitor scaling activities and history.
   - **View VM History**: Track the usage and status changes of VMs.

## RBAC Permissions

The solution separates the authenticated caller's permissions from ownership of the requested resource:

| Caller | Required authority | Access |
| --- | --- | --- |
| AVD workspace user | Delegated `connect_as_user` scope and `WorkspaceUser` role, through the configured launcher client | Only that user's own Linux workspace |
| Portal administrator | Delegated `access_as_user` scope and `FullAccess` role, through the configured portal client | VM, scaling, history, and host-settings management; no credential issuance or impersonation |
| Linux session agent | Application-only `LinuxHost` role and the registered host identity | Settings plus its own host's lease-scoped session operations and settings acknowledgements |
| Scheduled function | Application-only `ScheduledTask` role | Inventory, reachability updates, expired-lease processing, and scaling |
| AVD host managed identity | No credential-issuance permission | Cannot check out a user's workspace, including with a legacy `AvdHost` token |

An Entra account may receive both workspace and administrator permissions, but neither permission implies the other. Configure workspace entitlement for the approved AVD users/groups and portal assignment for the approved administrators. A delegated scope alone, a successful sign-in, or membership in a VM identity group does not grant management authority.

Linux host requests must match the registered host and current lease/generation. Knowing a username, hostname, or lease ID does not grant another user's credential. The API verifies the user principal and resolves the Linux identity before allocating a VM or resetting a password.

Managed identity remains appropriate for backend resource access and workload operations. Its security boundary is the Azure resource, not each Windows user session, so it is not used as proof of an individual AVD user's identity.

## Database Setup

The database component is essential for storing VM information, scaling rules, and activity logs. For detailed instructions on setting up the Azure SQL Database and deploying the stored procedures, please refer to the [Database Setup Documentation](sql_queries/README.md).

## Custom Script Extension

The **Custom Script Extensions** automate the configuration of both the AVD hosts and Linux hosts, ensuring they are prepared to support user access and integration with the Linux Broker for AVD solution.

### **AVD Host Configuration**

The custom script extension for the AVD host:

- **Installs the Linux Broker Agent**: Downloads and sets up the Linux Broker Agent (`Connect-LinuxBroker.ps1`) on the AVD host.
- **Configures User Authentication**: Installs the versioned Windows authentication helper and configures its tenant, cloud authority, launcher client, and Broker API. No application secret is installed on the pooled host.
- **Prepares the Host for User Connection**: Configures the AVD host to support seamless user connections, allowing them to access the Linux desktop via Azure Virtual Desktop.

### **Linux Host Configuration**

The custom script extensions support the following Linux distributions:

- **Red Hat Enterprise Linux (RHEL) 7, 8, and 9**
- **Ubuntu 24 Desktop**

These scripts:

- **Install XRDP and xpra**: Set up XRDP for full desktop access (RDP) and xpra for application virtualization, enabling users to connect via AVD.
- **Configure Authentication**: Sets up authentication mechanisms for secure user access.
- **Deploy the Linux Session Release Agent**: Installs the timer-based reconciliation service plus a `systemd-logind` watcher that can trigger early reconciliations. The timer remains the fallback path so the system still converges even if event delivery is delayed or unavailable.
- **Install the Host Settings Agent**: Installs `apply-host-settings.sh` and seeds the settings profile, so screen lock policy and session timings are applied consistently on every supported distribution rather than only on RHEL 8. `LINUXBROKER_DISABLE_SCREEN_LOCK` still chooses the screen lock posture that is seeded; from then on the values are managed from the portal.

## Additional Details

### Scaling Rules

- **Minimum VMs Running**: The minimum number of Linux VMs to keep powered on.
- **Maximum VMs Running**: The maximum number of Linux VMs allowed to be powered on.
- **Scale-Up Ratio**: The ratio of used VMs to total VMs at which the system should scale up (e.g., when 80% of VMs are in use).
- **Scale-Up Increment**: The number of VMs to add when scaling up.
- **Scale-Down Ratio**: The ratio at which to scale down the number of running VMs (e.g., when usage drops below 30%).
- **Scale-Down Increment**: The number of VMs to remove when scaling down.

### Session Release Mechanism

- **Session Monitoring**: The Session Release Agent reconciles XRDP/Xorg session state on a timer (60 seconds by default) and can also wake early from `systemd-logind` session signals.
- **Release State**: When a session is disconnected, the exact assignment enters a 'released' state and the desktop remains alive during the configured grace period (20 minutes by default). Repeated observations and unrelated health updates do not restart that period.
- **Reconnect**: Reconnecting restores the assignment to 'checked out' and cancels its pending expiry. The agent reconciles automatic RDP reconnects as well as new launcher requests.
- **Session Termination**: After expiry, cleanup rechecks the lease and actual session state, safely detaches the local profile mount, and removes the temporary account. The NFS profile is retained. Only confirmed cleanup returns a VM to the available pool; failures are reported and retried without assigning an uncleared host to another user.
- **Idle Sessions**: When an idle timeout is configured, a user who stays connected but inactive is disconnected, which starts the same grace period. They can reconnect and resume; if they do not, the VM is reclaimed. This is disabled by default.

### Linux Host Settings

Administrators manage host behavior from the **Host Settings** page in the Service Management Portal instead of editing scripts. The settings form a single fleet-wide profile stored in `dbo.LinuxHostSettings`.

| Setting | Default | Range | Effect |
| --- | --- | --- | --- |
| Reconnect grace period | 1200 s | 60–86400 | How long a disconnected user can reconnect before the VM is reclaimed |
| Reconcile interval | 60 s | 30–900 | How often each host re-checks session state |
| Watcher debounce | 10 s | 1–300 | Minimum gap between `logind`-triggered reconciliations |
| Watcher settle | 2 s | 0–60 | Pause after a `logind` signal before reconciling |
| Idle timeout | 0 (disabled) | 0, or 300–86400 | Inactivity before a connected user is disconnected |
| Idle warning lead time | 120 s | 0–900 | On-screen warning before the idle timeout, must be less than the timeout |
| Remove the lock screen | true | boolean | Disables the Super+L shortcut and the Lock menu entry |
| Screen lock enabled | false | boolean | Whether the screen locks when the screensaver activates |
| Screen blank delay | 0 (never) | 0–86400 | Inactivity before the screen blanks |
| Screen lock delay | 0 (immediate) | 0–86400 | Delay between blanking and locking |
| Lock screen settings | true | boolean | Applies dconf locks so users cannot override the screen lock values |

The session lifecycle defaults match the values that were previously hardcoded, so adopting this feature changes no behavior until an administrator edits the profile.

The screen lock defaults preserve the posture set by `LINUXBROKER_DISABLE_SCREEN_LOCK`: the lock screen is removed, because a locked GNOME greeter inside an xrdp session frequently cannot be unlocked after a reconnect, which strands the host's lease. That environment variable still chooses the posture seeded at provisioning time; from then on the values are managed from the portal. Set **Screen lock enabled** on and **Remove the lock screen** off to satisfy a STIG or CIS idle-lock control.

#### How settings reach the hosts

Delivery is a hybrid of pull and push, mirroring the timer-plus-watcher design of the release agent itself:

- **Pull (the convergence mechanism)**: each host fetches the profile at the start of every reconcile run using the managed identity it already has, caches it to `/etc/linuxbroker/host-settings.conf`, and reports the version it applied. Hosts that were powered off, unreachable, or created later by scale-up converge on their own with no operator action.
- **Push (for immediacy)**: **Apply Now** in the portal has the Broker API connect to each reachable host over SSH so a change takes effect at once. A host missed by a push is not left stale; it simply picks the change up on its next reconcile run.

Values are validated at every layer: SQL `CHECK` constraints, API request validation, and a clamp inside the host-side apply script. A settings fetch failure never blocks reconciliation, and idle enforcement is skipped rather than guessed if idle time cannot be read.

Because the profile is versioned, the portal shows which hosts have applied the current version and which are still pending.

### Security and Authentication

- **User Authentication**: The launcher proves the individual user's Entra identity to the broker. Linux continues to use the generated local password; it does not require Entra SSO or domain membership.
- **Stable Profile Ownership**: The verified tenant/object ID maps to a stable Linux username and UID. Existing profiles require a reviewed migration mapping; the first person to request a matching name cannot claim them.
- **Managed Identities**: Used for backend resource access and explicitly scoped workload operations, not user credential issuance.
- **Azure Key Vault**: Stores SSH keys and database passwords securely, accessed via managed identities.
- **API Permissions**: Delegated scopes, user roles, workload roles, and resource ownership are enforced separately in the broker. The portal additionally requires server-side administrator authorization.
- **Logging and Monitoring**: Authorization and lifecycle outcomes are audited without logging bearer tokens or generated passwords.

### AVD Host Sizing Recommendations

- [Session host virtual machine sizing guidelines for Azure Virtual Desktop and Remote Desktop Services | Microsoft Learn](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/virtual-machine-recs#multi-session-recommendations)

Given that AVD acts as a pass-through in this solution, starting with **light to medium workload sizing** is recommended. This provides a good balance of performance and efficiency without overprovisioning resources. The following table outlines the suggested configurations:

| Workload Type | Maximum Users per vCPU | Minimum Configuration             | Example Azure Instances                                      | Minimum Profile Storage |
| ------------- | ---------------------- | --------------------------------- | ------------------------------------------------------------ | ----------------------- |
| Light         | 6 users per vCPU       | 8 vCPUs, 16 GB RAM, 32 GB storage | D8s_v5, D8s_v4, F8s_v2, D8as_v4, D16s_v5, D16s_v4, F16s_v2, D16as_v4 | 30 GB                   |
| Medium        | 4 users per vCPU       | 8 vCPUs, 16 GB RAM, 32 GB storage | D8s_v5, D8s_v4, F8s_v2, D8as_v4, D16s_v5, D16s_v4, F16s_v2, D16as_v4 | 30 GB                   |

#### **Key Considerations:**

1. **Start with Light Workloads**:
   - For initial deployments, use light workload sizing (6 users per vCPU). This provides a good balance, allowing up to 48 users on an 8-core VM.
   - This configuration aligns well with the pass-through nature of the solution, minimizing unnecessary overhead.
2. **Adjust for Medium Workloads if Necessary**:
   - If users experience performance degradation, consider switching to a medium workload configuration (4 users per vCPU).
   - This reduces the user density per core and provides more headroom for CPU-intensive operations.
3. **VM Sizing Recommendations**:
   - Use VMs with at least 8 vCPUs and 16 GB of RAM. This configuration avoids stability issues seen with smaller VMs and provides sufficient resources for user sessions.
   - Avoid using VMs with more than 24 vCPUs to prevent diminishing returns due to increased synchronization overhead.
4. **Optimize for Multi-Session Workloads**:
   - Use multiple smaller VMs (e.g., 8-core instances) rather than fewer large VMs. This allows for better load balancing and resource management.
   - Smaller VMs can be shut down when not in use, conserving resources and reducing costs. Use Azure autoscale to manage VM power states based on demand.

## Getting Started

The supported deployment entrypoint for this repository is in `deploy/`.

For the full deployment walkthrough, see [deploy/DEPLOYMENT.md](deploy/DEPLOYMENT.md).

That guide covers:

- prerequisites and required permissions
- azd environment values and defaults
- how `azd up` prompts for subscription and deployment region when not pre-set
- choosing between Azure commercial, Azure US Government, and custom or sovereign clouds
- Entra app and group bootstrap behavior
- SSH key reuse, prompt, and auto-generation behavior
- what `preprovision`, Bicep provisioning, and `postprovision` each do
- the separate migration path for existing deployed environments
- SQL bootstrap, Linux host SQL registration, and validation steps
- troubleshooting and rerun paths

Quick start from the repository root:

```powershell
cd .\deploy
azd env new <environment-name>
azd up
```

For existing environments that need in-place rollout instead of new-environment provisioning, use [deploy/Migrate-ExistingEnvironment.ps1](deploy/Migrate-ExistingEnvironment.ps1) from the `deploy/` directory. `azd up` remains the supported greenfield path.

The authorization update requires a coordinated migration of app assignments, verified user/profile mappings, registered host identities, Windows launchers, and Linux lease agents. Pause new checkouts during activation and follow the deployment guide. Old machine-token launchers and unbound release calls deliberately fail closed; do not restore them as a compatibility workaround. Existing profile directories and UIDs must not be renamed or reassigned to make migration succeed.

The deployment targets Azure commercial by default. Set `azureCloudName` to `AzureUSGovernment` or `AzureCustom` to deploy elsewhere; commercial and Government resolve their endpoints automatically, while custom and sovereign clouds require their own authority, Graph, STS, and App Service FQDNs. Air-gapped environments should also set `scriptSourceRoot` to a reachable mirror of this repository, because the Linux hosts download their agent scripts from it during bootstrap.

The Service Management Portal serves all of its front-end assets from its own container under `front_end/static/dist/`. The bundle is compiled during the container build, uses the system font stack, and draws its icons as inline SVG, so it makes no requests to a public CDN and renders correctly in Government, sovereign and air-gapped environments where outbound internet access is blocked. Note that building the portal image does require access to the npm registry, so a disconnected build host needs an internal npm mirror. See [front_end/README.md](front_end/README.md).

The deployment defaults the App Service plan to Premium v3 `P2mv3`, which provides the minimum supported baseline of 4 vCPUs and 32 GB memory for the frontend, API, and task apps.

Before running `azd up`, review the detailed guide and set any environment-specific values you need, especially networking, host counts, VM sizes, App Service plan sizing, and SQL firewall access. The deployment scripts under `deploy/` now handle the Entra bootstrap, SSH key flow, App Service health checks on `/health`, Application Insights wiring for the frontend and API, post-provision role assignment, container image builds, SQL initialization, and Linux host SQL registration used by this solution.

Both fresh deployment and migration finish with checkout paused. Validate the intended user/admin assignments, effective workload permissions, Windows sign-in, and Linux reconnect/profile behavior before explicitly enabling it. Older RHEL hosts additionally need verified XRDP startup enrollment for the legacy reconnect gate; drain existing unenrolled sessions as documented rather than force-restarting them.

## Development Verification

The [authorization and lifecycle workflow](.github/workflows/broker-authorization-tests.yml) exercises the broker's real JWT validation, the portal/broker HTTP contract, safe Linux lifecycle fixtures, Windows launcher packaging, disposable SQL transactions and runtime-user permissions, and offline deployment checks. It does not deploy infrastructure or exercise real user profiles.

Use the component guides for the API, portal, launcher, Linux, SQL, and deployment test commands. Keep API and portal Python environments separate. The additional `tests\verify_portal_broker_contract.py --portal-python <portal-python-executable>` harness runs the real services against a loopback-only broker with locally signed tokens. `tests\Test-RuntimeDatabaseIntegration.ps1` checks real contained SQL logins in the explicitly named, marked disposable LocalDB database created by the SQL harness; it never accepts an Azure connection.

Automated checks do not establish live WAM SSO, native RHEL kernel/XRDP behavior, or NFS compatibility. The authorized deployment pilot is a required activation step, not an optional substitute for failed tests.

## Contributing

Contributions are welcome! Please read the [CONTRIBUTING](CONTRIBUTING.md) guidelines for more information.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
