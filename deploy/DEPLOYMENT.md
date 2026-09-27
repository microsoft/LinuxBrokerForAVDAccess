# Detailed Deployment Guide

This guide documents the supported deployment path for this repository.

The short version stays in [../README.md](../README.md). Use this guide when you need the full `azd` workflow, required permissions, key environment values, SSH key behavior, validation steps, or troubleshooting guidance.

## Deployment Model

The supported deployment entrypoint is [azure.yaml](azure.yaml) in the `deploy/` folder.

- `azd up` is wired to run `provision` and the deployment hooks from [azure.yaml](azure.yaml).
- The `preprovision` hook runs [Initialize-DeploymentEnvironment.ps1](Initialize-DeploymentEnvironment.ps1).
- Infrastructure is provisioned from [bicep/main.bicep](bicep/main.bicep).
- The `postprovision` hook runs [Post-Provision.ps1](Post-Provision.ps1).

That means the actual deployment flow is:

1. Bootstrap the azd environment, Entra applications, host groups, the AVD users group, and SSH key material.
2. Provision Azure infrastructure with Bicep.
3. Build the container images in Azure Container Registry, restart the apps, initialize SQL, assign the function app role, sync VM group membership, and register Linux hosts in SQL.

Two details matter here:

- The supported path is `azd up` from the `deploy/` directory, not a separate manual mix of Bicep plus ad hoc scripts.
- Container images are built remotely with `az acr build`, so local Docker is not required.
- The `frontend` image is multi-stage and compiles the React portal in a Node stage, so the build host needs to reach the npm registry. See [Front end build requirements](#front-end-build-requirements).

For upgrade scenarios, keep one more distinction clear:

- `azd up` remains the greenfield path that deploys the current ideal version for new environments.
- Existing customer environments should use a separate migration process instead of pushing upgrade logic into `azd up`.

## Prerequisites

### Local tooling

- Windows with PowerShell 7 available as `pwsh`. The hooks in [azure.yaml](azure.yaml) are currently configured only under `windows`.
- Azure CLI logged into the target tenant and subscription.
- Azure Developer CLI (`azd`) logged in.
- OpenSSH Client if you want the hook to generate SSH keys automatically or from the local prompt path.

### Azure and Entra permissions

You need enough access to do all of the following:

- Create resource groups and deploy Azure resources.
- Create Azure role assignments. When AVD session hosts are deployed, one of them is on the subscription, which needs **Owner** or **User Access Administrator** on the subscription. Without that, the deployment still succeeds, but the AVD scaling plan is left unassigned until an administrator assigns the role; see [AVD Autoscale](#avd-autoscale).
- Create or update Microsoft Entra app registrations.
- Create or update service principals.
- Create or update Entra security groups.
- Create Entra app-role assignments from groups to the API service principal.
- Add members to Entra security groups.

You also need a tenant admin available to grant admin consent after the app registrations are created. `preprovision` attempts admin consent for both applications and, when AVD hosts are deployed, enables Microsoft Entra authentication for RDP on the tenant's Windows Cloud Login service principal. Both succeed automatically when the operator is a Global Administrator, Privileged Role Administrator, or Cloud Application Administrator; otherwise `preprovision` prints a warning and a tenant admin completes them afterward. See [Manual Steps After azd up](#manual-steps-after-azd-up).

## What The Deployment Creates

At a high level, the deployment provisions and configures the following:

- Azure Container Registry for the `frontend`, `api`, and `task` images.
- App Service apps for the frontend and API, plus a Function App for scheduled work.
- Azure SQL Database and firewall rules.
- Two Azure Key Vaults: one for the deployment's secrets, and one for the keys that unlock each user's login keyring.
- App Service plan, storage account, Application Insights, Log Analytics, and networking.
- A private DNS zone, `linuxbroker.internal`, linked to the virtual network with auto-registration, so the broker reaches each Linux host as `<hostname>.linuxbroker.internal`. It is skipped when you supply `domainName`.
- A premium Azure Files NFS share for Linux home directories, reachable only through a private endpoint. It is skipped when you supply `nfsShare`, set `deployNfsShare` to `false`, or deploy no Linux hosts.
- Optional Linux hosts and optional AVD hosts, depending on azd environment settings.
- When AVD hosts are deployed, a RemoteApp application group that publishes **Linux Desktop**, which runs `Connect-LinuxBroker.ps1` on the session host to check out a Linux host and open an RDP session to it.
- When AVD hosts are deployed, an Azure Virtual Desktop scaling plan that starts and stops the session hosts on a schedule, and Start VM on Connect on the host pool. See [AVD Autoscale](#avd-autoscale).
- Two Entra app registrations: frontend and API.
- Two Entra security groups for VM authorization: AVD hosts and Linux hosts.
- When AVD hosts are deployed and `avdUsersGroupId` is not set, a third Entra security group for AVD users, with the deploying user added as a member.

The deployment model now follows these runtime rules:

- The function app gets the `ScheduledTask` API app role directly.
- VM managed identities do not get direct API role assignments.
- Instead, VM managed identities are added to Entra security groups, and those groups hold the `AvdHost` and `LinuxHost` API app roles.
- Key Vault stores only two deployment secrets: `db-password` and `linux-host`.
- The keyring vault holds one secret per user, `keyring-<uid>`, which the API creates at the user's first checkout. The template adds none.
- Frontend and API auth secrets are stored in app settings, not in Key Vault.
- Linux hosts are registered into SQL during `postprovision`. AVD hosts are not.
- The API and function apps are integrated with the virtual network's app subnet, so the API reaches Linux hosts on their private IP addresses for SSH and the portal's connectivity test.
- The API managed identity holds **Desktop Virtualization Power On Off Contributor** on the VM resource group, which lets it start and stop hosts for the portal and scaling rules without broader write access. Stopping a host powers it off without deallocating it, so a stopped host still accrues compute charges.
- Members of the AVD users group hold **Desktop Virtualization User** on the RemoteApp application group and **Virtual Machine User Login** on each session host. Both are required: the first publishes **Linux Desktop** to the user, and the second lets the user sign in to the Microsoft Entra joined session host.
- The Azure Virtual Desktop service principal holds **Desktop Virtualization Power On Off Contributor** on the subscription, which autoscale and Start VM on Connect need. Autoscale does not work with the role on a resource group, and the role lets Azure Virtual Desktop start and stop any session host in the subscription, not only this deployment's.

## Required And Common azd Environment Values

The preprovision hook seeds many defaults automatically, but you should still treat the following values as the main inputs you may want to review or override.

The checked-in [bicep/main.parameters.example.json](bicep/main.parameters.example.json) file is a safe template and reference. If you need a manual parameters file, copy it locally to `bicep/main.parameters.json` and fill in the values. The real [bicep/main.parameters.json](bicep/main.parameters.json) file is also generated locally by preprovision, contains secrets, and is gitignored. Prefer the azd environment for operational values.

### Common values to set explicitly

- `appName`: base name for generated resources.
- `AZURE_LOCATION`: deployment region.
- `appServicePlanSku`: App Service plan SKU. The deployment baseline defaults to Premium v3 `P2mv3` for 4 vCPUs and 32 GB memory.
- `allowedClientIp`: your public client IP for SQL bootstrap from the local machine.
- `deployLinuxHosts`: `true` or `false`.
- `deployAvdHosts`: `true` or `false`.
- `linuxHostCount`: number of Linux hosts to provision.
- `avdSessionHostCount`: number of AVD hosts to provision.
- `linuxHostVmSize`: Linux host VM size.
- `avdVmSize`: AVD host VM size.
- `linuxHostOsVersion`: Linux image SKU. Defaults to `9-LVM` (RHEL 9). The RHEL options (`8-LVM`, `9-LVM`) map to the Generation 2 images that Trusted Launch requires. `rocky-9` and `alma-9` deploy Rocky Linux 9 and AlmaLinux 9, rebuilds of RHEL 9 that need no Red Hat subscription, and run the RHEL 9 bootstrap, with CRB and EPEL from the distribution's own repositories; their hosts get the 64 GB OS disk that RHEL hosts have. Rocky Linux 9 is a free Azure Marketplace image with a purchase plan: `preprovision` accepts its terms in the deployment subscription, and the subscription must be allowed to buy Marketplace images. Where it is not, use `alma-9`, whose image has no plan; see [A Rocky Linux host deployment failed with `MarketplacePurchaseEligibilityFailed`](#a-rocky-linux-host-deployment-failed-with-marketplacepurchaseeligibilityfailed). `24_04-lts` deploys Canonical's Ubuntu 24.04 server image and adds the Ubuntu desktop, which xrdp sessions run as Ubuntu on Xorg.
- `linuxHostDesktop`: `gnome`, `xfce` or `mate`. The desktop the Linux hosts run in xrdp sessions. Defaults to `gnome`, which is the `Server with GUI` group on RHEL, Rocky Linux and AlmaLinux, and the Ubuntu desktop on Ubuntu. Xfce and MATE come from EPEL on RHEL, Rocky Linux and AlmaLinux, and from Ubuntu's own packages on Ubuntu. Changing it on existing hosts runs their bootstrap again at the next `azd provision`, so drain them first. See [Upgrading To Distribution And Desktop Support](#upgrading-to-distribution-and-desktop-support).
- `linuxHostDisableScreenLock`: `true` or `false`. Disables the screen saver and screen lock on the Linux hosts, whichever desktop they run. Defaults to `true`. See [Linux Host Screen Lock](#linux-host-screen-lock).
- `azureCloudName`: `AzurePublic`, `AzureUSGovernment`, or `AzureCustom`. See [Choosing The Target Azure Cloud](#choosing-the-target-azure-cloud).
- `scriptSourceRoot`: root URL the Linux host and AVD host bootstrap scripts are downloaded from.
- `domainName`: DNS suffix the broker appends to Linux host names when it connects over SSH. Leave empty to use the deployment's private DNS zone, `linuxbroker.internal`. If you set it, you are responsible for DNS records that resolve `<hostname>.<domainName>` from the API's virtual network.
- `nfsShare`: an existing NFS share, in `<server>:/<export>` form, to mount for Linux home directories. Leave empty to have the deployment provision one.
- `deployNfsShare`: `true` or `false`. Provisions a premium Azure Files NFS share when `nfsShare` is empty. Defaults to `true`.
- `nfsShareQuotaGiB`: provisioned size of that share in GiB. Premium shares have a 100 GiB minimum, and the size sets the share's IOPS, throughput and cost as well as its capacity. Defaults to `100`. See [Sizing the share](#sizing-the-share).
- `avdUsersGroupId`: object ID of an existing Entra group whose members can launch **Linux Desktop**. Leave empty to have `preprovision` create `<appName>-<environmentName>-avd-users-sg` and add you to it.
- `avdLinuxDesktopFullScreen`: `true` or `false`. Defaults to `true`, which opens the Linux desktop full screen. `false` opens it in a window on one monitor. See [Linux Desktop Display](#linux-desktop-display).
- `avdLinuxDesktopMultiMonitor`: `true` or `false`. Defaults to `true`, which spreads a full-screen Linux desktop across every monitor of the user's AVD session. `false` keeps it on one monitor. See [Linux Desktop Display](#linux-desktop-display).
- `avdScalingPlanEnabled`: `true` or `false`. Defaults to `true`, which assigns the deployment's scaling plan to the AVD host pool, so autoscale starts and stops the session hosts. `false` deploys the plan assigned to no host pool and leaves the session hosts as they are. See [AVD Autoscale](#avd-autoscale).
- `avdStartVmOnConnect`: `true` or `false`. Defaults to `true`, which starts a stopped AVD session host for a user who opens **Linux Desktop** when no running session host can take the session.
- `avdScalingPlanTimeZone`: Windows time zone ID the scaling plan's times are in, such as `Eastern Standard Time`. Defaults to `UTC`. The schedule itself comes from `avdScalingPlanRampUpStart`, `avdScalingPlanPeakStart`, `avdScalingPlanRampDownStart`, `avdScalingPlanOffPeakStart` and the five `avdScalingPlan...Pct` values; see [AVD Autoscale](#avd-autoscale).
- `assignAvdAutoscaleRole`: `true` or `false`. Defaults to `true`, which lets the deployment give the Azure Virtual Desktop service principal **Desktop Virtualization Power On Off Contributor** on the subscription when it does not hold it. Set it to `false` when an administrator manages that role.
- `avdServicePrincipalObjectId`: object ID of the Azure Virtual Desktop service principal in your tenant. Leave empty to have `preprovision` find it by its app ID, `avdServicePrincipalAppId`, which defaults to `9cdead84-a844-4324-93f2-b2e6bb768d07`.
- `vmHostResourceGroup`: override if managed VMs live in a different resource group.
- `brokerReaderGroupId`, `brokerOperatorGroupId`, `brokerAdminGroupId`: optional object IDs of Entra groups to assign the Broker API's `Reader`, `Operator` and `FullAccess` app roles to. Assigning an app role to a group needs Microsoft Entra ID P1 or P2; without it, assign the roles to users in **Enterprise applications**. See [Portal roles](#portal-roles).
- `sqlDatabaseSkuName`: Azure SQL Database SKU, for example `Basic`, `S1` or `GP_S_Gen5_1`. Defaults to `Basic`, which suits small pools. Use `S1` or higher when many hosts and portal users call the broker at once; each API worker process opens at most `DB_MAX_CONCURRENCY` connections (6 by default).
- `allowLegacyScopeAccess`: `true` or `false`. Defaults to `false`. When `true`, any portal user holding the `access_as_user` scope is treated as `FullAccess`, as in releases before role enforcement. Use it only while you assign roles during an upgrade.

### Values that are usually auto-generated

- `SQL_ADMIN_PASSWORD`
- `HOST_ADMIN_PASSWORD`
- `FLASK_SESSION_SECRET`
- frontend and API client secrets
- frontend and API client IDs if the app registrations do not already exist
- AVD and Linux host group IDs
- the AVD users group ID, when `avdUsersGroupId` is not supplied

When `AZURE_LOCATION` is not already set, `azd up` will prompt you to select an Azure region before provisioning starts. The selected value is saved into the azd environment automatically. You can also pre-set it with `azd env set AZURE_LOCATION <region>` to skip the prompt.

## Choosing The Target Azure Cloud

The deployment supports Azure commercial, Azure US Government, and custom or sovereign clouds. The selection is stored in the azd environment as `azureCloudName` (also mirrored to `AZURE_CLOUD_NAME`) and accepts:

- `AzurePublic`
- `AzureUSGovernment`
- `AzureCustom`

If the value is not already set, `preprovision` infers a default from whichever cloud the Azure CLI is signed in to and, on a local interactive run, prompts you to confirm or change it. Non-interactive runs use the inferred value without prompting. Set it ahead of time to skip the prompt entirely:

```powershell
azd env set azureCloudName AzureUSGovernment
```

Sign the Azure CLI in to the matching cloud before deploying, because the deployment reads the subscription, creates the Entra app registrations, and builds container images there:

```powershell
az cloud set --name AzureUSGovernment
az login
```

### Endpoints resolved per cloud

`AzurePublic` and `AzureUSGovernment` have built-in endpoints, so nothing else is required:

| Value | AzurePublic | AzureUSGovernment |
| --- | --- | --- |
| `graphEndpoint` | `https://graph.microsoft.com` | `https://graph.microsoft.us` |
| `appServiceDomain` | `azurewebsites.net` | `azurewebsites.us` |
| `stsIssuerHost` | `https://sts.windows.net` | `https://sts.windows.net` |

The Entra authority host is not in that table because ARM already reports it for the cloud being deployed into, so Bicep resolves it with `environment().authentication.loginEndpoint`. SQL, Key Vault, storage, and container registry endpoints are likewise taken from resource properties rather than hardcoded suffixes.

### Custom and sovereign clouds

`AzureCustom` has no built-in profile, so every endpoint must be supplied. A local interactive run prompts for the missing values; a non-interactive run fails with the list of values it needs. Set them explicitly to keep the run deterministic:

```powershell
azd env set azureCloudName AzureCustom
azd env set azureAuthorityHost https://login.<your-cloud>
azd env set graphEndpoint https://graph.<your-cloud>
azd env set stsIssuerHost https://sts.<your-cloud>
azd env set appServiceDomain azurewebsites.<your-cloud>
```

Register the cloud with the Azure CLI first so `az` can reach its ARM endpoint:

```powershell
az cloud register --name MyCloud --endpoint-resource-manager https://management.<your-cloud> --endpoint-active-directory https://login.<your-cloud> --endpoint-active-directory-graph-resource-id https://graph.<your-cloud>/ --suffix-storage-endpoint <your-cloud> --suffix-keyvault-dns .vault.<your-cloud>
az cloud set --name MyCloud
az login
```

The resolved values flow into the frontend, API, and task app settings as `AZURE_CLOUD_NAME`, `AZURE_AUTHORITY_HOST`, `GRAPH_ENDPOINT`, and `STS_ISSUER_HOST`. The applications read those settings instead of assuming commercial-cloud endpoints, and `AZURE_AUTHORITY_HOST` is the standard variable the Azure SDK credentials already honor.

### Linux host bootstrap source

Linux hosts download their agent scripts from `scriptSourceRoot`, which defaults to the `main` branch of this repository on GitHub. The AVD session host extension downloads `Configure-AVD-Host.ps1` and `Connect-LinuxBroker.ps1` from the same root.

When you deploy from a branch or fork that changes those scripts, push it first and point `scriptSourceRoot` at the published commit. Otherwise the hosts run the scripts from `main`, which may not accept the parameters the templates pass. A commit SHA is more reliable than a branch name, because `raw.githubusercontent.com` caches branch content for a few minutes:

```powershell
azd env set scriptSourceRoot https://raw.githubusercontent.com/<owner>/LinuxBrokerForAVDAccess/<commit-sha>
```

Government and air-gapped environments usually cannot reach `raw.githubusercontent.com`, so point it at a reachable mirror such as a storage account or internal Git host:

```powershell
azd env set scriptSourceRoot https://<your-mirror>/LinuxBrokerForAVDAccess/main
```

The mirror must preserve the repository layout, because the bootstrap scripts append paths such as `/linux_host/create-user.sh` and `/custom_script_extensions/Configure-RHEL9-Host.sh`. The same value is available as `-ScriptSourceRoot` on [Migrate-LinuxHostReleaseAgent.ps1](Migrate-LinuxHostReleaseAgent.ps1) for existing hosts.

### Cloud availability caveats

Confirm before deploying to a non-commercial cloud that the region offers Azure Virtual Desktop, the App Service Premium v3 `P2mv3` SKU, and the Linux and Windows VM images referenced by the deployment. Availability differs between clouds, and a missing SKU or image surfaces as a provisioning failure rather than a validation error.

### SSH key values for Linux hosts

The broker requires SSH key-based access to Linux hosts. The relevant azd environment values are:

- `linuxHostSshPublicKey`
- `linuxHostSshPrivateKey`

Behavior is now:

- If both values are already set, the deployment reuses them.
- If neither value is set and the run is local and interactive, the hook prompts you to either generate a new keypair or stop and provide your own.
- If neither value is set and the run is non-interactive, the hook generates a new ed25519 keypair automatically.
- If only one of the two values is set, the hook treats that as a partial keypair state. Local interactive runs prompt you to generate a fresh pair or stop and provide your own. Non-interactive runs automatically regenerate a fresh complete pair.

The private key is normalized into escaped newline form before it is written back into the azd environment and then stored in Key Vault.

## Supplying Your Own SSH Keys

If you want to use an existing SSH keypair instead of the generated one, set both values before running `azd up`.

PowerShell example:

```powershell
$publicKey = (Get-Content "$HOME/.ssh/id_ed25519.pub" -Raw).Trim()
$privateKey = (Get-Content "$HOME/.ssh/id_ed25519" -Raw) -replace "`r?`n", '\n'

azd env set linuxHostSshPublicKey $publicKey
azd env set linuxHostSshPrivateKey $privateKey
```

If you prefer to be prompted locally, leave both values unset and run `azd up` from an interactive terminal.

## Linux Host Screen Lock

Linux hosts run GNOME unless `linuxHostDesktop` chooses Xfce or MATE. By default the bootstrap
script disables the screen saver and screen lock on those hosts, whichever desktop they run.

This is on by default because a locked GNOME greeter inside an xrdp session frequently
cannot be unlocked after a reconnect. When that happens the user cannot get back into the
desktop, and the host stays leased until the lease is released manually. Xfce and MATE hosts get
the same default, so the posture does not depend on the desktop a deployment chose.

The configuration is applied through a dconf system database, which GNOME and MATE read, and on
Xfce hosts through a system xfconf file:

| File on the host | Written by |
| --- | --- |
| `/etc/dconf/db/local.d/00-screensaver` | [linux_host/apply-host-settings.sh](../linux_host/apply-host-settings.sh) |
| `/etc/dconf/db/local.d/locks/screensaver` | [linux_host/apply-host-settings.sh](../linux_host/apply-host-settings.sh) |
| `/etc/dconf/profile/user` | [linux_host/apply-host-settings.sh](../linux_host/apply-host-settings.sh) |
| `/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-screensaver.xml`, on Xfce hosts | [linux_host/apply-host-settings.sh](../linux_host/apply-host-settings.sh) |

These files were previously static and downloaded during bootstrap. They are now generated from
the fleet-wide host settings profile, which is what makes the values editable in the portal after
deployment. The bootstrap seeds that profile once, and the release agent keeps each host converged
to it from then on. See [Linux Host Settings](../README.md#linux-host-settings).

On GNOME it sets `idle-delay` to `0` so the session never goes idle, sets `lock-enabled` to
`false` so the screen saver never locks, and sets `disable-lock-screen` to `true` so the lock
screen is removed entirely, including the `Super+L` shortcut and the `Lock` entry in the system
menu. The same database sets the matching MATE keys under `org/mate`, where
`disable-lock-screen` in `org/mate/desktop/lockdown` stops MATE from locking the screen. On Xfce
the xfconf file turns off xfce4-screensaver's blanking and locking; Xfce keeps its `Lock Screen`
entry, which does nothing while locking is disabled. While **Prevent users from changing these
screen lock settings** is on in **Host Settings**, as it is by default, the lock list stops users
from changing any of the GNOME and MATE keys back, and each property in the xfconf file is marked
`unlocked="root"`, so Xfce ignores the values users set for themselves.

GNOME counts the blank and lock delays in seconds, as the portal does. MATE and Xfce count them
in whole minutes, up to 8 hours, so the delays are converted for them: the blank delay rounds up,
so a delay of a few seconds does not turn blanking off, and the lock delay rounds to the nearest
minute. Xfce reads the file when a session starts, so a change reaches the Xfce sessions that
start after it.

RHEL does not ship `/etc/dconf/profile/user`, and a system dconf database is only read when a
profile references it, so the bootstrap creates that file with `system-db:local`. An existing
profile is preserved and only appended to.

### Keeping the lock screen

Set the parameter to `false` if you need to satisfy an idle screen lock control such as a DISA
STIG or CIS benchmark:

```powershell
azd env set linuxHostDisableScreenLock false
```

The bootstrap then seeds the profile with the lock screen left enabled. You can also set
`LINUXBROKER_DISABLE_SCREEN_LOCK=false` in the environment if you run `Configure-RHEL8-Host.sh`,
`Configure-RHEL9-Host.sh` or `Configure-Ubuntu24_desktop-Host.sh` by hand.

Because the values are part of the host settings profile, this posture can also be changed after
deployment from **Host Settings** in the portal, without redeploying anything.

### Verifying on a host

```bash
# The system database was built and is referenced by the profile.
ls -l /etc/dconf/db/local
grep system-db /etc/dconf/profile/user

# The effective values, from inside a GNOME session.
gsettings get org.gnome.desktop.session idle-delay
gsettings get org.gnome.desktop.screensaver lock-enabled
gsettings get org.gnome.desktop.lockdown disable-lock-screen

# From inside a MATE session.
gsettings get org.mate.session idle-delay
gsettings get org.mate.screensaver lock-enabled
gsettings get org.mate.lockdown disable-lock-screen

# From inside an Xfce session.
xfconf-query -c xfce4-screensaver -p /saver/enabled
xfconf-query -c xfce4-screensaver -p /lock/enabled
```

Expect `uint32 0`, `false`, and `true` on GNOME, `0`, `false`, and `true` on MATE, and `false`
twice on Xfce. If `gsettings` still reports the distribution defaults, check that
`/etc/dconf/profile/user` contains `system-db:local` and rerun `sudo dconf update`.

## Linux Desktop Display

**Linux Desktop** runs [Connect-LinuxBroker.ps1](../avd_host/broker/Connect-LinuxBroker.ps1) on the
AVD session host, and the script starts Remote Desktop Connection (`mstsc.exe`) to the user's Linux
host. From version 2.0.0 of the script, the Linux desktop opens full screen across every monitor,
with `mstsc /v:<address> /f /multimon`. Earlier scripts ran `mstsc /v:<address>`, which left full
screen and monitors to the user's own Remote Desktop Connection settings.

Two azd environment values change this for every user:

| Value | Set to `false`, it |
| --- | --- |
| `avdLinuxDesktopFullScreen` | opens the desktop in a window on one monitor, whatever `avdLinuxDesktopMultiMonitor` says |
| `avdLinuxDesktopMultiMonitor` | keeps a full-screen desktop on one monitor |

```powershell
azd env set avdLinuxDesktopMultiMonitor false
azd provision
```

Provisioning passes a `false` value to the script as `-FullScreen Off` or `-MultiMonitor Off` on the
RemoteApp's command line. The RemoteApp requires that command line, and every `azd provision` sets
it again, so change these values rather than the command line in the Azure portal.

Before you set either value to `false`, update every session host to script 2.0.0 or later,
including the stopped ones, which [Update-AvdHostBrokerScript.ps1](Update-AvdHostBrokerScript.ps1)
skips. An older script refuses the argument, and **Linux Desktop** then closes on that session host
without connecting. While both values are `true`, the command line is the one earlier releases
used, which every script accepts.

The Linux desktop can use only the monitors that the user's AVD session has. An AVD session uses
every monitor of the user's device, if the user's client supports several, unless the host pool's
RDP properties set `use multimon:i:0`, which this deployment does not.

### Why the script writes no connection file

Since the April 2026 Windows security update, Remote Desktop Connection warns about every `.rdp` file
that no trusted publisher signed, and turns off every redirection the file asks for, the clipboard
included, until the user turns each one back on. The warning applies only to connections started
from a file, so the script passes switches to `mstsc.exe` instead of writing one. See
[Understanding security warnings when opening Remote Desktop (RDP) files](https://learn.microsoft.com/windows-server/remote/remote-desktop-services/remotepc/understanding-security-warnings).

Do not apply Microsoft's
[high-security configuration](https://learn.microsoft.com/windows-server/remote/remote-desktop-services/remotepc/manage-rdp-file-security-settings-with-group-policy#high-security-environments)
for RDP files to the session hosts. With **Allow .rdp files from valid publishers and user's
default .rdp settings** disabled, Remote Desktop Connection opens only files signed by a trusted
publisher, and refuses the connection the script starts as well. Disabling **Allow .rdp files from unknown
publishers** on its own does no harm. Connection files signed by a publisher the session hosts
trust, which would allow the high-security configuration, are in the
[security hardening backlog](../docs/ROADMAP.md#security-hardening-backlog).

## AVD Autoscale

The AVD session hosts only run Remote Desktop Connection to the Linux hosts, so they need to run
only while users need them. With the session hosts, the deployment creates an Azure Virtual Desktop
[scaling plan](https://learn.microsoft.com/azure/virtual-desktop/autoscale-scenarios),
`<host-pool>-scaling-plan`, that starts and stops them on a schedule, and turns on
[Start VM on Connect](https://learn.microsoft.com/azure/virtual-desktop/start-virtual-machine-connect)
for the host pool.

The plan has one schedule for Monday to Friday and one for Saturday and Sunday, with the same times,
in `avdScalingPlanTimeZone`:

| Phase | Starts at | Session hosts kept on | Starts another session host above | New sessions go to |
| --- | --- | --- | --- | --- |
| Ramp-up | `avdScalingPlanRampUpStart`, 07:00 | `avdScalingPlanRampUpMinimumHostsPct`, 20% | `avdScalingPlanRampUpCapacityThresholdPct`, 60% | the session host with the fewest sessions |
| Peak | `avdScalingPlanPeakStart`, 09:00 | as ramp-up | as ramp-up | the session host with the fewest sessions |
| Ramp-down | `avdScalingPlanRampDownStart`, 18:00 | `avdScalingPlanRampDownMinimumHostsPct`, 10% | `avdScalingPlanRampDownCapacityThresholdPct`, 90% | the busiest session host with room |
| Off-peak | `avdScalingPlanOffPeakStart`, 20:00 | as ramp-down | as ramp-down | the busiest session host with room |

- **Session hosts kept on** is a share of all the session hosts, rounded up, so with up to five
  session hosts, 20% and 10% both keep one on. On Saturday and Sunday,
  `avdScalingPlanWeekendMinimumHostsPct`, 0% by default, takes the place of both.
- Autoscale starts another session host when the sessions fill more than the threshold's share of
  what the running session hosts can hold, `avdMaxSessionLimit` each. During peak, ramp-down and
  off-peak, it also stops session hosts that have no sessions, as long as the others stay under the
  threshold. It stops none during ramp-up. Its load balancing replaces the host pool's own.
- Users are never signed out. A session host stops only once it has no sessions, disconnected ones
  included, so a user who closes their Remote Desktop client without signing out keeps their session
  host, and their Linux session, running.
- The times are `HH:mm` on a 24-hour clock and must come in the order of the table within one day.
  Each share is a whole number from 0 to 100, and each threshold from 1 to 100. `preprovision`
  refuses other values.

`avdScalingPlanTimeZone` is a Windows time zone ID, such as `Eastern Standard Time`, not an IANA
name such as `America/New_York`, and `preprovision` warns when it does not know the value. It is
separate from the time zone of the broker's own scaling schedule for the Linux hosts, which an
administrator sets on the portal's **Scaling** page, so change them together.

With the weekend share at 0%, every session host can stop. The first user to open **Linux Desktop**
then waits while Start VM on Connect starts a session host, which their Remote Desktop client
reports, and if no Linux host is ready either, waits again inside the session host while the broker
starts one. So the first user can wait through two starts, of several minutes in all. Keep a
weekend share above 0% if that is too long. For a pooled host pool, Start VM on Connect starts a
session host only when none is running, and another only when the running ones reach their session
limit; autoscale starts the rest.

To keep autoscale away from a session host, for example while you maintain it, tag it
`excludeFromScaling`, with any value. Autoscale then never starts or stops it, and leaves its drain
mode alone, which it otherwise overrides in a pooled host pool. A deployment replaces a VM's tags,
so `preprovision` records the tag and `azd provision` writes it back.

```powershell
az vm update -g <resource-group> -n <session-host> --set tags.excludeFromScaling=maintenance
az vm update -g <resource-group> -n <session-host> --remove tags.excludeFromScaling
```

The plan uses power-management autoscale, which starts and stops existing session hosts and works in
Azure Government. Dynamic autoscale, which also creates and deletes session hosts, is not available
there, and the deployment does not use it.

### The autoscale role

Autoscale and Start VM on Connect start and stop the session hosts as the Azure Virtual Desktop
service principal, which must hold **Desktop Virtualization Power On Off Contributor** on the
subscription: autoscale does not work with the role on a resource group or a VM. The role lets
Azure Virtual Desktop start and stop any session host in the subscription, and assigning it needs
**Owner** or **User Access Administrator** on the subscription.

`preprovision` finds the service principal by its app ID, `avdServicePrincipalAppId`, never by its
name, and, unless `assignAvdAutoscaleRole` is `false`, creates it in the tenant if it is missing. It
then checks whether the service principal holds the role on the subscription already, directly,
through a group or from a management group, and whether your account can assign roles there:

| `preprovision` finds that | The deployment |
| --- | --- |
| The role is assigned | assigns nothing |
| The role is not assigned, and you can assign it | assigns it |
| The role is not assigned, and you cannot assign it | deploys the scaling plan assigned to no host pool, and `preprovision` prints the command for an Owner or User Access Administrator to run. Start VM on Connect stays on, but starts nothing until the role is assigned. |
| The service principal cannot be found or created | does the same, and `preprovision` asks you to set `avdServicePrincipalObjectId` |
| It cannot tell | assigns the role, and `preprovision` warns what a failure would mean |

Once an administrator has assigned the role, run `azd provision` again, and it assigns the plan to
the host pool.

- `assignAvdAutoscaleRole=false` stops the deployment from assigning the role, for when an
  administrator manages it, for example through a custom role, which the check does not recognize.
  The plan is then assigned as `avdScalingPlanEnabled` says, and `preprovision` only warns when the
  service principal holds no **Desktop Virtualization Power On Off Contributor** assignment on the
  subscription.
- `avdScalingPlanEnabled=false` keeps the plan but assigns it to no host pool, so autoscale leaves
  the session hosts alone. Set it when the host pool already has a scaling plan, because a host pool
  can have only one and the deployment would fail, or when something else scales the session hosts,
  because autoscale must not be combined with another scaling tool.
- `avdStartVmOnConnect=false` turns off Start VM on Connect. With the plan off too, the deployment
  assigns no role. Start VM on Connect on its own needs only **Desktop Virtualization Power On
  Contributor**, on any scope that contains the session hosts: to use it on the resource group
  instead of the subscription role, assign it to the service principal yourself and set
  `assignAvdAutoscaleRole` to `false`.
- `avdServicePrincipalObjectId` skips the lookup. `avdServicePrincipalAppId` defaults to
  `9cdead84-a844-4324-93f2-b2e6bb768d07`, the app ID Microsoft documents for Azure Virtual Desktop;
  set it only for a cloud where the service principal has another.

## Home Directory Share

Linux hosts keep each broker user's home directory on an NFS share, so a user's files follow them
from host to host. At checkout, `create-user.sh` mounts the user's directory on the share over
`/home/<user>`, and the host keeps it mounted until the broker returns the host. Unless `nfsShare`
names a share of your own, the deployment creates a premium Azure Files NFS share of
`nfsShareQuotaGiB` GiB, 100 by default.

### Sizing the share

The share uses the provisioned v1 model, where the size you provision sets how fast the share is
as well as how much it holds:

| Provisioned size (GiB) | Baseline IOPS | Burst IOPS | Throughput (MiB/s) |
| ---: | ---: | ---: | ---: |
| 100 | 3,100 | 10,000 | 110 |
| 256 | 3,256 | 10,000 | 127 |
| 512 | 3,512 | 10,000 | 152 |
| 1,024 | 4,024 | 10,000 | 203 |
| 2,048 | 5,048 | 10,000 | 305 |
| 5,120 | 8,120 | 15,360 | 613 |
| 10,240 | 13,240 | 30,720 | 1,125 |

Baseline IOPS are 3,000 plus one for each GiB, burst IOPS are three for each GiB but at least
10,000, and throughput is 100 MiB/s plus about 0.1 MiB/s for each GiB, as
[Microsoft documents](https://learn.microsoft.com/azure/storage/files/understanding-billing#provisioned-v1-model).
A share gathers credits while it runs below its baseline, and with a full set it can run at its
burst IOPS for an hour.

- **Size for capacity first.** The share keeps the profile of every user who has ever signed in,
  not only of those signed in now, so it needs room for all of them: the number of users times a
  typical profile, and room to grow. `df -h ~` in a session shows how full the share is.
- **IOPS follow how many users are signed in at once,** and what they run. With caches on the
  local disk, as described below, a session's traffic to the share is mostly the files its user
  opens and saves, and an idle session moves at most a few hundred bytes a minute. Signing in and
  starting applications cost the most, so many users who sign in together, such as at the start
  of a shift, make the peak. Burst credits are there for peaks like that.
- **Start at 100 GiB and watch the share.** In the storage account's **Metrics**, choose the
  **File** metric namespace and **Transactions**, and split it by **Response type**.
  `SuccessWithThrottling`, the `SuccessWithShare...Throttling` types and the
  `ClientShare...ThrottlingError` types mean the share held requests back because they went over
  its IOPS or throughput. **Success E2E Latency** shows how long requests took, and **Success
  Server Latency** how much of that the share itself took. If the share throttles, make it larger.
- **Change the size with azd:** `azd env set nfsShareQuotaGiB <GiB>`, then `azd provision`. A
  larger size takes effect within minutes, and the hosts don't need to mount the share again. A
  share can be made smaller only 24 hours after it was last made larger. A size changed anywhere
  else, such as in the Azure portal, lasts only until the next `azd provision` sets it back.

Microsoft now recommends the provisioned v2 model for new shares. It provisions IOPS and throughput
separately from capacity, so a share that holds little but serves many users at once costs less.
The deployment still creates a provisioned v1 share, and a storage account can't move from one
model to the other, so moving an environment to provisioned v2 takes a new share and a copy of the
profiles.

### How hosts use the share

Every Linux host runs `install-host-config.sh` from its bootstrap, and again whenever
[Migrate-LinuxHostReleaseAgent.ps1](Migrate-LinuxHostReleaseAgent.ps1) runs. It writes only files
of its own, and only when they differ. A host works without them, so when the script fails the
bootstrap reports it and goes on.

- **Read-ahead.** On an NFS mount, Linux reads ahead 128 KiB at a time. Microsoft
  [recommends 15 MiB](https://learn.microsoft.com/azure/storage/files/nfs-performance) for Azure
  Files NFS shares, which the script sets on NFS mounts that already exist and, for later ones,
  with the udev rule Microsoft publishes, in `/etc/udev/rules.d/99-nfs.rules`. The rule applies to
  every NFS mount on the host, not only to the home directory share. It takes the place of a rule
  of the same name in `/usr/lib/udev/rules.d`, which some distributions install with their NFS
  packages. A rule an administrator wrote at that path is left alone, as long as it doesn't carry
  the script's marker line. The rule differs from Microsoft's in one character, `$$4` where
  Microsoft writes `$4`: udev reads `$$` as a literal `$`, so awk still gets `$4`, and systemd 255
  and later no longer report the rule as invalid each time udev loads its rules.
- **Caches on the local disk.** At checkout, `create-user.sh` creates
  `/var/cache/linuxbroker/users/<user>`, which only the user can read, and the session launcher
  points `XDG_CACHE_HOME` at it, as `/etc/profile.d/linuxbroker-cache.sh` does in login shells.
  Applications that follow the XDG base directory specification, such as the desktops' own
  components and most browsers, then keep their caches there instead of in `~/.cache` on the
  share. Returning the host deletes the cache, and a restart empties the directory. Only root can
  create entries in `/var/cache/linuxbroker/users`, so no user can create another user's cache
  ahead of them, as they could in a directory every user can write to, such as `/var/tmp`.
- **Log rotation.** `/etc/logrotate.d/linuxbroker` rotates the broker's logs in `/var/log` every
  week, or sooner once one passes 50 MB, and keeps four, compressed. `linuxbroker-patch.log` is
  left out, because `patch-host.sh` trims it itself.
- **The old mount point.** `create-user.sh` mounts the share on `/nfs_profiles` while it creates a
  home directory. The script removes the previous mount point, `/awipsprofiles`, when it is empty
  and nothing is mounted on it.

Some caches still go to the share:

- The Firefox snap on Ubuntu keeps its cache in `~/snap/firefox/common/.cache`, because a snap
  sets its own `XDG_CACHE_HOME`.
- Services that the user's systemd instance starts before the desktop hands it its environment
  use `~/.cache`.
- Applications that keep caches in their own directories, such as Visual Studio Code under
  `~/.config/Code`, ignore `XDG_CACHE_HOME`.

Caches that sessions left in `~/.cache` before the host was updated stay on the share and can be
deleted; an application rebuilds a cache it needs.

## Quick Start

From the repository root:

```powershell
Set-Location .\deploy
azd auth login
az login
azd env new <environment-name>
```

If `AZURE_LOCATION` is not already set, `azd up` will prompt you to select an Azure region before provisioning starts.

Set the environment values you care about before the first run. Example:

```powershell
azd env set appName linuxbroker
azd env set allowedClientIp <your-public-ip>
azd env set deployLinuxHosts true
azd env set deployAvdHosts true
azd env set linuxHostCount 2
azd env set avdSessionHostCount 1
```

Then run:

```powershell
azd up
```

## What Happens During `preprovision`

[Initialize-DeploymentEnvironment.ps1](Initialize-DeploymentEnvironment.ps1) performs the environment bootstrap before any Azure resources are provisioned.

It currently does all of the following:

- Seeds default azd environment values for common parameters.
- Creates or reuses the frontend Entra app registration.
- Creates or reuses the API Entra app registration.
- Creates service principals for those applications if needed.
- Creates or reuses the AVD host and Linux host Entra security groups.
- Assigns the `AvdHost` and `LinuxHost` app roles from the API application to those groups.
- When AVD hosts are deployed and `avdUsersGroupId` is empty, creates or reuses the AVD users group and adds the signed-in user to it.
- Attempts tenant-wide admin consent for the API and frontend applications.
- When AVD hosts are deployed, enables Microsoft Entra authentication for RDP on the Windows Cloud Login service principal if it is not already enabled. The host pool turns on Entra single sign-on, which depends on this tenant-wide setting. `preprovision` never disables it.
- Creates or reuses frontend and API client secrets.
- Generates or reuses Linux host SSH keys.
- When Linux hosts are deployed with `linuxHostOsVersion=rocky-9`, accepts the Azure Marketplace terms of the Rocky Linux 9 image in the deployment subscription unless they are accepted already.
- Lists the Linux hosts and AVD session hosts already in the resource group that are not running, so the deployment leaves out their VM extensions, which Azure refuses to change on a VM that is not running, and records the `excludeFromScaling` tag of each AVD session host, which the deployment writes back. See [A deployment failed with `Cannot modify extensions in the VM when the VM is not running`](#a-deployment-failed-with-cannot-modify-extensions-in-the-vm-when-the-vm-is-not-running).
- Checks the AVD scaling plan's times and shares, and, when AVD session hosts are deployed, finds the Azure Virtual Desktop service principal and decides whether the deployment gives it **Desktop Virtualization Power On Off Contributor** on the subscription. See [The autoscale role](#the-autoscale-role).
- Writes resolved values back into the azd environment in both uppercase and camelCase forms expected by the deployment.

The API app registration is also configured with the Graph application permissions the API uses to validate host and group membership.

## What Happens During Provisioning

[bicep/main.bicep](bicep/main.bicep) and the modules under `bicep/modules/` provision the infrastructure.

Important deployment characteristics:

- SQL public network access is enabled.
- Azure services are allowed through the SQL firewall.
- A client-IP firewall rule is added only if `allowedClientIp` is set.
- The frontend and API App Services enable App Service health checks on `/health`.
- The frontend and API apps are instrumented with Azure Monitor OpenTelemetry and receive `APPLICATIONINSIGHTS_CONNECTION_STRING` and `OTEL_SERVICE_NAME` through app settings.
- Linux host auth defaults to `SSH`.
- Linux hosts register their names in the `linuxbroker.internal` private DNS zone unless `domainName` is set, and the API's `DOMAIN_NAME` setting points at whichever suffix is in effect.
- The API's `NFS_SHARE` setting points at the provisioned Azure Files share unless `nfsShare` is set. The storage account disables public network access and shared key access, and it allows non-HTTPS traffic because NFS does not use HTTPS; the private endpoint is the only path to it.
- RHEL, Rocky Linux and AlmaLinux hosts use Generation 2 images so they can run with Trusted Launch.
- The AVD host pool prefers RemoteApp and sets RDP properties that enable Microsoft Entra single sign-on to the Microsoft Entra joined session hosts.
- The AVD host pool has Start VM on Connect on, and a scaling plan starts and stops its session hosts on a schedule. See [AVD Autoscale](#avd-autoscale).
- Hosts that were not running when `preprovision` listed them keep their VM extensions as they were. Changes that the extensions carry, such as the API URL, `scriptSourceRoot`, `linuxHostDesktop` and `linuxHostDisableScreenLock`, reach such a host the next time `azd provision` runs while it is running.
- Linux hosts run the desktop that `linuxHostDesktop` names, GNOME by default, with the screen saver and screen lock disabled unless `linuxHostDisableScreenLock` is `false`. See [Linux Host Screen Lock](#linux-host-screen-lock).
- Key Vault stores `db-password` and `linux-host`.
- The API app receives Key Vault Secrets User access so it can read those secrets at runtime.
- A second vault, `kr<app><env><suffix>`, holds the key that unlocks each user's login keyring. The API holds Key Vault Secrets Officer on that vault only, so it can create and rotate the keys without being able to change the deployment's secrets, and finds it through the `KEYRING_VAULT_URL` app setting. Like the main vault, it uses Azure RBAC, allows public network access, and keeps deleted secrets for 90 days.

## What Happens During `postprovision`

[Post-Provision.ps1](Post-Provision.ps1) performs the runtime completion steps after the Azure resources exist.

It currently runs, in order:

1. [Assign-FunctionAppApiRole.ps1](Assign-FunctionAppApiRole.ps1)
2. [Initialize-Database.ps1](Initialize-Database.ps1)
3. [Build-ContainerImages.ps1](Build-ContainerImages.ps1)
4. [Assign-VmApiRoles.ps1](Assign-VmApiRoles.ps1)
5. [Register-LinuxHostSqlRecords.ps1](Register-LinuxHostSqlRecords.ps1)

That means `postprovision` does all of the following:

- Assigns the `ScheduledTask` app role to the function app managed identity. This runs before the images are built because the function app requests an API token as soon as its image starts, and the managed identity service caches that token for up to 24 hours.
- Applies all SQL scripts from [../sql_queries](../sql_queries) through ADO.NET, before any new image starts, so new code never runs against procedures it cannot call. The scripts only add columns, parameters and result columns, so the images still running meanwhile keep working.
- Makes the SQL bootstrap rerunnable by handling `GO` batches and converting procedure creation to `CREATE OR ALTER`.
- Builds `frontend:latest`, `api:latest`, and `task:latest` in ACR.
- Restarts the API app, then the function app, then the frontend app, so nothing starts ahead of the API endpoints it calls.
- Adds AVD and Linux VM managed identities to the corresponding Entra groups, retrying while new identities replicate, and fails the hook if a membership still cannot be confirmed.
- Registers Linux hosts into `dbo.VirtualMachines` through `dbo.RegisterLinuxHostVm`.

### Front End Build Requirements

The Service Management Portal is a React and TypeScript single-page app. [front_end/Dockerfile](../front_end/Dockerfile) is multi-stage: a `node:22-alpine` stage runs `npm ci` and `npm run build`, and only the compiled bundle is copied into the Python runtime image.

That means the machine performing the build, which is the ACR build agent when using `az acr build`, needs to pull the `node:22-alpine` base image and resolve packages from the npm registry. Nothing is fetched at runtime: the compiled bundle, the fonts, and the icons all ship inside the image, so the portal still renders in Government, sovereign and air-gapped environments.

If the build environment cannot reach `registry.npmjs.org`, point npm at an internal mirror before building, for example by adding an `.npmrc` with a `registry=` entry alongside [front_end/web/package.json](../front_end/web/package.json). `package-lock.json` is committed, so `npm ci` installs an exact, reviewable dependency set.

## Migration For Existing Deployments

Use the migration flow when you already have a deployed customer environment and want to roll forward the current application, SQL, Linux host release-agent and AVD session host script changes without treating that as part of the normal `azd up` lifecycle.

The migration entrypoint is [Migrate-ExistingEnvironment.ps1](Migrate-ExistingEnvironment.ps1).

That script intentionally stays separate from `azd up`:

- `azd up` continues to express the desired greenfield deployment for new environments.
- [Migrate-ExistingEnvironment.ps1](Migrate-ExistingEnvironment.ps1) is the supported in-place process for existing environments.

By default, the migration script does three things:

1. Runs [Post-Provision.ps1](Post-Provision.ps1) so the existing environment gets the latest container images, SQL scripts, role assignments, VM group sync, and Linux host SQL registration.
2. Runs [Migrate-LinuxHostReleaseAgent.ps1](Migrate-LinuxHostReleaseAgent.ps1) so existing Linux hosts get the current release-agent files, one-minute reconciliation timer, and `systemd-logind` watcher.
3. Runs [Update-AvdHostBrokerScript.ps1](Update-AvdHostBrokerScript.ps1) so existing AVD session hosts get the current `Connect-LinuxBroker.ps1`, the script the **Linux Desktop** RemoteApp runs.

A failed post-provision step stops the migration. The two host steps run even when the other fails, and the migration then fails, naming the steps that did; the warnings before it name the hosts to retry.

Example full migration:

```powershell
Set-Location .\deploy
.\Migrate-ExistingEnvironment.ps1 -EnvironmentName <environment-name>
```

Example canary rollout to only selected Linux hosts:

```powershell
Set-Location .\deploy
.\Migrate-ExistingEnvironment.ps1 `
	-EnvironmentName <environment-name> `
	-LinuxHostNames lnxhost-01,lnxhost-02
```

`-LinuxHostNames` limits only the Linux host step. `-AvdHostNames` limits the AVD session host step in the same way, and `-SkipLinuxHostReleaseAgentMigration` and `-SkipAvdHostScriptUpdate` leave out a step. Example update of only selected AVD session hosts:

```powershell
Set-Location .\deploy
.\Migrate-ExistingEnvironment.ps1 `
	-EnvironmentName <environment-name> `
	-SkipPostProvision `
	-SkipLinuxHostReleaseAgentMigration `
	-AvdHostNames <session-host-1>,<session-host-2>
```

Example host-only migration when you do not want to rerun the post-provision steps:

```powershell
Set-Location .\deploy
.\Migrate-ExistingEnvironment.ps1 `
	-EnvironmentName <environment-name> `
	-SkipPostProvision
```

Example migration against a release tag source instead of `main`:

```powershell
Set-Location .\deploy
.\Migrate-ExistingEnvironment.ps1 `
	-EnvironmentName <environment-name> `
	-ScriptSourceRoot https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/refs/tags/<tag>
```

The host migration step updates only the release-agent-related files and services on existing Linux VMs. It does not reprovision infrastructure, replace the VM image, rerun the full Linux custom script extension, or attempt to reconcile every manual drift in an older environment.

The AVD session host step changes only `C:\Temp\Connect-LinuxBroker.ps1`, through Run Command, on the VMs in the resource group tagged `broker-role=avd-host`. On each running session host it downloads the script from `ScriptSourceRoot`, fills in the API URL and client ID as `Configure-AVD-Host.ps1` does, checks that the result is a broker script in plain ASCII that parses, and replaces the installed script in one step. Because the API URL and `ScriptSourceRoot` are written into PowerShell code on the session host, the update refuses either one unless it is an `https://` URL made only of ASCII letters, digits and the characters `.`, `-`, `_`, `~`, `%` and `/`, with an optional port. A download or check that fails leaves the installed script as it was, and sessions already open keep the script they started with. Session hosts that are not running are skipped and named at the end; update each one with `-AvdHostNames` once it is started. While the scaling plan is assigned, autoscale can stop a session host you started before the update reaches it, so tag the session host `excludeFromScaling` before you start it and remove the tag once it is updated; see [AVD Autoscale](#avd-autoscale). To update only the session hosts, you can also run [Update-AvdHostBrokerScript.ps1](Update-AvdHostBrokerScript.ps1) on its own, with the same `-EnvironmentName`, `-ScriptSourceRoot` and `-AvdHostNames` parameters.

The migration also rewrites `/etc/sudoers.d/avdadmin`. Older hosts were provisioned with a broad allowlist that included `cat`, `rm`, `chmod`, `chown`, `cp`, `mount`, and `umount`. The current policy grants only `userdel`, `groupadd`, `usermod`, `chpasswd`, `/usr/local/bin/create-user.sh`, `/usr/local/bin/manage-lease.sh`, `/usr/local/bin/apply-host-settings.sh`, `/usr/local/bin/session-control.sh`, and `/usr/local/bin/patch-host.sh`; all privileged file work now happens inside those root-owned scripts. The generated policy is validated with `visudo -c` and moved into place only if it passes.

`apply-host-settings.sh` is the only way the broker API can change host configuration. It accepts a JSON settings document on stdin and nothing on argv, rejects unknown keys, and clamps every value to a supported range before writing anything, so a bad value cannot strand the fleet.

The migration additionally installs `dconf` and, where available, `xprintidle`. `xprintidle` backs the optional idle session timeout; if it cannot be installed the migration still succeeds and idle enforcement is simply skipped on that host. RHEL, Rocky Linux and AlmaLinux do not package it, not even in EPEL, so only Ubuntu hosts enforce the idle timeout. Existing hosts keep any settings profile they already have, and hosts with no profile are seeded with the shipped defaults, which match the values that were previously hardcoded.

The current host scripts also bring:

- **Single-call provisioning.** `create-user.sh --password-stdin` creates the account, mounts the home, adds the remote access groups and sets the password in one SSH session, instead of six to eight. The API falls back to the old sequence for a host whose script predates it, and logs a reminder to migrate that host.
- **Lease handling for signed-in users.** `manage-lease.sh` keeps the lease while the user is still signed in, so the broker keeps the host **Cleanup pending** and retries, instead of treating it as clean.
- **Keeping sessions alive.** The release agent and `apply-host-settings.sh` understand the **Keep sessions alive during the grace period** setting. Hosts that are not migrated reject the setting once it is turned on, keep their current behavior, and show as pending in the drift table.
- **Heartbeats.** The release agent reports its version, each installed script's version, OS, desktop, xrdp, NFS, load, memory, disk and sessions to the broker at the end of every timer run. Watcher-triggered runs do not report, and a broker without heartbeats is asked again only every 15 minutes.
- **Session control and patching.** `session-control.sh` signs users out, shows messages and resets profiles for the broker, and `patch-host.sh` runs the package upgrade for a rolling maintenance run. Both refuse anything but validated input, and `session-control.sh` only acts on accounts the broker created.

## Upgrading To Role-Based Access And Working Scaling

This release changes three behaviors that need planning before you upgrade an existing environment.

### Portal roles

Every Broker API endpoint now checks the caller's app roles. The delegated `access_as_user` scope that the portal requests no longer grants anything by itself.

| Role | Allows |
| --- | --- |
| `Reader` | Viewing everything in the portal, including fleet health and the audit log |
| `Operator` | Reader, plus releasing and returning hosts, retrying cleanup, draining and returning hosts to service, starting hosts, stopping and restarting hosts no one is using, syncing power states, and **Apply Now** |
| `FullAccess` | Operator, plus stopping and restarting hosts in use, adding, deleting and repairing VMs, test checkouts, and editing the scaling rule and host settings |

`preprovision` creates the `Reader` and `Operator` roles on the API app registration (`FullAccess` already exists) and assigns `FullAccess` to the user running the deployment. Assign roles to other administrators under **Microsoft Entra ID > Enterprise applications > *API app* > Users and groups**, or set `brokerReaderGroupId`, `brokerOperatorGroupId` and `brokerAdminGroupId` so `preprovision` assigns them to groups (group assignment needs Entra ID P1 or P2). Users pick up a new role the next time they sign in to the portal.

If you cannot assign roles before the upgrade, deploy once with the legacy toggle and turn it off afterwards:

```powershell
azd env set allowLegacyScopeAccess true
azd provision
# ...assign the roles...
azd env set allowLegacyScopeAccess false
azd provision
```

While the toggle is on, the API logs a warning whenever it grants access through the scope, and the portal shows a banner.

### Scaling now starts and stops VMs

Earlier releases recorded scaling decisions in the database but never sent them to Azure, because the procedure and the API disagreed on the action names. After this upgrade the scaling task starts and stops VMs for real, every five minutes.

- Review the scaling rule first. `MinVMs` must now be at least 1, only one rule applies, and idle hosts above the minimum are powered off when utilization is at or below the scale-down ratio.
- Choose the stop mode per rule in the portal. **Power off** (the default) keeps compute allocated and billed but starts quickly; **Deallocate** stops compute billing but starts more slowly and can fail with `AllocationFailed` in a capacity-constrained region.
- The API's managed identity already holds **Desktop Virtualization Power On Off Contributor** on the VM resource group, which includes start, power off and deallocate.

### Returned hosts are cleaned before reuse

A returned host is now held **Cleanup pending** until the previous user's account has been removed and their home unmounted, and the released-VM sweep follows the configured grace period instead of a fixed 30 minutes. Hosts released by the previous API build during the rollout are claimed by the new sweep and cleaned automatically.

### Recommended order

1. Assign the portal roles, or set `allowLegacyScopeAccess`.
2. Review the scaling rule and, for larger pools, set `sqlDatabaseSkuName`.
3. Run [Migrate-ExistingEnvironment.ps1](Migrate-ExistingEnvironment.ps1), which applies the SQL scripts first, then rebuilds and restarts the apps, then migrates the Linux hosts.
4. Confirm that a checkout, a disconnect and a return work end to end, and that returned hosts leave **Cleanup pending** within a few minutes.

## Upgrading To The Admin Console Foundations

This release adds the audit log, real host actions and drain, and host heartbeats with a fleet health page (items 2.1, 2.2 and 2.4 of the [roadmap](../docs/ROADMAP.md)). It needs no new Azure resources, role assignments or deployment parameters.

- **Audit log.** Every portal action, every denied attempt on a mutating API route, and the changes the broker makes on its own are recorded in `dbo.AuditLog` and on the portal's **Audit** page, with CSV export. Each entry also goes to Application Insights as a log record from the `linuxbroker.api.audit` logger. The scheduled task purges SQL entries older than `AUDIT_RETENTION_DAYS` (default 365) every day at 03:17 UTC; set that app setting on the API to keep more or fewer. Entries written before this release do not exist: the log starts at the upgrade.
- **Host actions.** Operators can start, stop, restart and drain hosts from the portal instead of editing records with **Update attributes**. The API's existing **Desktop Virtualization Power On Off Contributor** role already covers restart. Stopping or restarting a host that a user is signed in to needs `FullAccess` and the hostname typed to confirm; stopping it ends the user's assignment, so they get a different host when they reconnect.
- **Drain** replaces the maintenance toggle in the portal. A draining host keeps its current user, takes no new ones, and moves to maintenance when the assignment ends. Scaling no longer counts draining hosts as capacity, so draining several busy hosts can start replacements, up to the rule's `MaxVMs`.
- **Heartbeats.** Migrated Linux hosts post a heartbeat at the end of every reconcile run, which the **Fleet health** page and each host's **Host agent** card show. It reports only: checkout readiness still comes from the reachability probe. Each heartbeat is one small SQL write per host per reconcile interval (60 seconds by default), about 1.7 writes a second for 100 hosts, which the Basic SQL tier handles; size up with `sqlDatabaseSkuName` for pools of several hundred hosts or a shorter interval.
- **Host agent version.** Every script in `linux_host/` now declares `LINUXBROKER_AGENT_VERSION` (1.0.0). Hosts that are not migrated keep working, show **No heartbeat** in fleet health, and are counted there as needing attention.

### Recommended order

1. Run [Migrate-ExistingEnvironment.ps1](Migrate-ExistingEnvironment.ps1). It applies SQL scripts `067`–`087` before the new images start, restarts the apps in the order API, task, front end, and then migrates the Linux hosts so they start sending heartbeats.
2. Open **Fleet health** and confirm every powered-on host reports within a few minutes. A host that stays on **No heartbeat** was not migrated; rerun the migration for it with `-LinuxHostNames`.
3. Drain one idle host and return it to service, and confirm both appear on the **Audit** page.

Every layer tolerates the others being one release behind during the rollout. A host agent that meets an older API backs off its heartbeat for 15 minutes on each `404`. A portal that meets an older API shows the new pages' errors and hides the dashboard's fleet health strip. The previous API build keeps working against the new database, apart from `DeleteVm`, which now answers `404` for a VM that does not exist instead of reporting success.

## Upgrading To The Complete Admin Console

This release completes the admin console: sessions and users, broadcast messages, scaling schedules, dashboard trends, rolling maintenance and patching, the new navigation, and the operator-grade host list (items 2.3 and 2.5–2.10 of the [roadmap](../docs/ROADMAP.md)). It needs no new Azure resources, role assignments or deployment parameters, and no Bicep change.

- **Host agent 1.1.0.** Two new allowlisted scripts: `session-control.sh` signs users out, shows messages and resets profiles, and only acts on accounts the broker created; `patch-host.sh` runs the package upgrade for a maintenance run. [Migrate-LinuxHostReleaseAgent.ps1](Migrate-LinuxHostReleaseAgent.ps1) installs both and adds them to the `avdadmin` sudoers allowlist, validated with `visudo -c` as before. The migration now carries on past a host that fails or is powered off and reports every failure at the end with a non-zero exit code, so rerun it with `-LinuxHostNames` for the hosts it names. Hosts that are not migrated keep working: sign-out, messages and patching answer that the agent is older than 1.1.0 and must be migrated, a requested profile reset waits, fleet health flags the agent as outdated, and restart-only maintenance runs still work.
- **Sessions and users.** The **Sessions** page shows who is on which host and why someone cannot connect, and "Find a user" searches everyone the broker has provisioned. Operators can sign a user out, optionally returning the host, and message their session or every session. Sign-out releases the host through the broker, so the grace period no longer depends on the host agent's own release.
- **Profile resets.** An administrator can ask for a fresh profile; it is applied at the user's next new assignment, before the home is mounted. The old profile is renamed on the NFS share, at its root next to the live profiles, as `<user>.reset-<YYYYMMDDTHHMMSSZ>`, and the broker never deletes it. Remove those folders by hand once they are no longer needed, from any machine that mounts the share as root.
- **Scaling schedules.** The **Scaling** page shows the policy in force and what the next run would do, and schedule windows override the default rule on chosen days and times in one policy time zone (`UTC` until you choose one). Existing deployments keep scaling exactly as before until a window is added. From this release the minimum wins over the maximum: a scale-down never leaves fewer serviceable hosts than `MinVMs`, even when draining or maintenance hosts push the pool over `MaxVMs`.
- **Trends and unmet demand.** Every checkout records its outcome and duration, and every start its time to reachable, for the dashboard's capacity and checkout charts and its **Attention** panel. The events are purged with the audit log after `CHECKOUT_EVENT_RETENTION_DAYS` (default 90). The charts fill in from the upgrade on; the capacity series also reads the scaling activity log, which already has history.
- **Rolling maintenance.** A new `AdvanceMaintenance` timer (every minute, at 30 seconds past) advances the active run through `POST /api/maintenance/advance` with the task's existing `ScheduledTask` role. Patching runs over SSH with the broker's existing key; the reboot uses the Azure restart the API already has, so no new permission is needed and it works in sovereign and air-gapped clouds. The hosts need their package repositories: a RHEL subscription (RHUI on pay-as-you-go images, or Satellite or a mirror) or an Ubuntu archive or mirror. **Security updates** on Ubuntu run `unattended-upgrade`, so the `unattended-upgrades` package must be installed; without it choose **All updates**. Each host's patch output is in `/var/log/linuxbroker-patch.log`. A patch only counts as done when the kernel the host boots next has its initramfs: rpm does not fail an update whose initramfs could not be written, and a restart would then stop in GRUB. Azure's RHEL 9 images have a 960 MB `/boot` that holds two kernels while dnf keeps three, so when `/boot` cannot hold another kernel a run keeps two (the running one and the newest). If the initramfs still cannot be built, the running kernel stays the default and the patch fails with the free space in `/boot`. The first kernel update also makes dracut write a rescue image as large as a kernel's (about 270 MB); on a host that is still short of room, remove it or an old kernel before patching again. A host whose patch fails stays drained for inspection. The optional settings are `MAINTENANCE_ADVANCE_DEADLINE_SECONDS` (default 45) and `MAINTENANCE_PATCH_TIMEOUT_MINUTES` (default 90) on the API.
- **Host list and import.** The host list pages on the server, and **Import from Azure** registers tagged `broker-role=linux-host` VMs that are not registered yet. Import needs each name to resolve as `<hostname>.<DOMAIN_NAME>`. The deployment's private DNS zone registers every VM in its virtual network automatically; with a custom `domainName`, your DNS must. A host that does not resolve is listed but cannot be imported, and imported hosts start unreachable until the probe reaches them. The dashboard's **Checkout VM** button is now **Test brokering** in the host list's **Tools** menu.
- **Broadcast settings.** `BROADCAST_CONCURRENCY`, `BROADCAST_HOST_TIMEOUT_SECONDS` and `BROADCAST_DEADLINE_SECONDS` tune how many hosts a message reaches at once; the defaults suit pools of a few hundred hosts.

### Recommended order

1. Run [Migrate-ExistingEnvironment.ps1](Migrate-ExistingEnvironment.ps1). It applies SQL scripts `088`–`143` before the new images start, restarts the apps in the order API, task, front end, and then migrates the Linux hosts to agent 1.1.0.
2. Open **Fleet health** and confirm no powered-on host is flagged **Agent outdated**; rerun the migration with `-LinuxHostNames` for any that are.
3. On **Sessions**, send a message to one test session, then run a restart-only maintenance run over one idle host and confirm it comes back in service. Try **Security updates** on a single host before a larger run.

Every layer tolerates the others being one release behind during the rollout. The previous API build keeps working against the new database: the changed procedures only add result columns, and scaling's normal call is unchanged. A portal that meets an older API hides the dashboard's trends and Attention panel, pages the host list itself, points the Scaling section at the scaling rules, and shows the new pages' errors. A task that meets an older API logs a `404` from the maintenance timer and carries on.

## Upgrading To Distribution And Desktop Support

This release changes which Linux distributions and desktops the deployment offers, and unlocks each user's login keyring (items 3.1–3.4, 3.6 and 3.7 of the [roadmap](../docs/ROADMAP.md)). Unlike the admin console releases, it adds an Azure resource and a role assignment, so it needs `azd provision`, and the Linux hosts need agent 1.2.0.

- **RHEL 9 is the default Linux host.** New azd environments, and templates deployed without a value, now use `linuxHostOsVersion=9-LVM` instead of `24_04-lts`, which deployed an Ubuntu server with no desktop. An existing environment keeps the value it stored; check it with `azd env get-value linuxHostOsVersion`.
- **RHEL 7 is no longer offered.** `7-LVM` is removed from `linuxHostOsVersion`, along with `Configure-RHEL7-Host.sh`; RHEL 7 left maintenance on June 30, 2024. An azd environment that still stores `linuxHostOsVersion=7-LVM` fails template validation at the next `azd provision`, even with `deployLinuxHosts=false`, so set it to a supported value first. A VM's image cannot be changed in place, so for existing RHEL 7 hosts either also set `deployLinuxHosts=false`, which leaves them as they are, or replace them: drain them, delete the VMs in Azure and their records in the portal, and run `azd provision`. Existing RHEL 7 hosts keep working with the broker, and `patch-host.sh` and the host migration still support them.
- **One release agent for every distribution.** The separate RHEL and Ubuntu copies of `release-session.sh` are merged into `linux_host/session_release_buffer/release-session.sh`, and the unused `xrdp-who-xnc.sh` is deleted. Ubuntu hosts now also unmount orphaned NFS homes, as RHEL hosts did. Run [Migrate-LinuxHostReleaseAgent.ps1](Migrate-LinuxHostReleaseAgent.ps1) from this release: a copy from an earlier release downloads the old paths, which no longer exist, and stops before it changes anything.
- **xrdp starts sessions through `xrdp-startwm.sh`.** The bootstrap and the host migration install `/usr/local/bin/xrdp-startwm.sh` and make it the `DefaultWindowManager` in `/etc/xrdp/sesman.ini`. The first change keeps the original file as `sesman.ini.linuxbroker-orig`, the previous value is recorded in `/etc/linuxbroker/xrdp-startwm.conf`, and xrdp-sesman reloads its configuration without ending any session. The launcher starts the desktop named in `/etc/linuxbroker/desktop.conf`, which the bootstrap writes; without that file, as on a migrated host, it runs the distribution's own session script as before. It also adds `/etc/polkit-1/rules.d/45-linuxbroker-xrdp.rules`, so members of `tsusers` are not asked for an administrator's password when their session creates a color profile or refreshes the package lists. Every maintenance patch run installs it again in case an update replaced `sesman.ini`, and security updates on Ubuntu now keep configuration files that were changed locally, as all updates already did.
- **File indexing is off in broker sessions.** Tracker, GNOME's file indexer, keeps its index in each home directory, so on broker hosts it crawled the NFS share. Homes also move between hosts, and an index that one distribution's Tracker wrote does not open in another's: RHEL 9 then restarted its indexer every few seconds, reading the share each time. `xrdp-startwm.sh --install`, which the bootstrap, the host migration and every maintenance patch run call, now masks Tracker's user services with links to `/dev/null` in `/etc/systemd/user`. It also hides Tracker's autostart entries, which Xfce, and GNOME on RHEL 8, start directly: copies marked `Hidden=true` go in `/etc/linuxbroker/xdg/autostart`, which the launcher puts ahead of `/etc/xdg` for every session. The distribution's own files are not changed. Search in the Files app still works, without the index; the Xfce and MATE file managers never used it. Sessions already running on a migrated host keep any indexer they started. Existing indexes stay in each profile, in `~/.cache/tracker3` or, from RHEL 8, `~/.cache/tracker` and `~/.local/share/tracker`, and can be deleted.
- **Ubuntu hosts run the Ubuntu desktop.** `24_04-lts` still deploys Canonical's Ubuntu 24.04 server image, and the bootstrap now adds `ubuntu-desktop-minimal`, which xrdp sessions run as Ubuntu on Xorg, so the screen lock and host settings apply to Ubuntu hosts too. The first-login wizard, crash reporting and update notifications are left out, because broker users cannot act on them. Firefox, a snap on Ubuntu, is installed on its own, and a host that cannot reach the Snap Store finishes without it. The bootstrap no longer adds Microsoft's package repository or installs the Azure CLI, and broker users get `/bin/bash` rather than Ubuntu's default `/bin/sh`; existing users are switched at their next sign-in. The previous bootstrap's package install failed on Ubuntu 24.04, because Microsoft's repository has no `azure-cli` package for it, so existing Ubuntu hosts lack `nfs-common`, `jq` and `dconf-cli` and cannot mount NFS homes. Replace them as described for RHEL 7 above, or drain each one and run the new bootstrap on it. Restarting xrdp ends the connections to the host, so it must be drained:

  ```powershell
  $root = 'https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/refs/heads/main'
  $api = azd env get-value apiUrl
  $clientId = azd env get-value apiClientId
  az vm run-command invoke -g <resource-group> -n <vm-name> --command-id RunShellScript --scripts "curl -fsSL -o /tmp/linuxbroker-bootstrap.sh $root/custom_script_extensions/Configure-Ubuntu24_desktop-Host.sh && LINUXBROKER_SCRIPT_SOURCE_ROOT=$root bash /tmp/linuxbroker-bootstrap.sh $api $clientId"
  ```

- **Hosts can run Xfce or MATE.** The new `linuxHostDesktop` parameter chooses the desktop: `gnome`, the default and the only desktop until now, `xfce` or `mate`. The bootstrap installs it, from EPEL on RHEL and from Ubuntu's own packages on Ubuntu, and records it in `/etc/linuxbroker/desktop.conf`. `xrdp-startwm.sh` starts the desktop named there, and the heartbeat reports it in **Fleet health**. The host settings apply to all three desktops; see [Linux Host Screen Lock](#linux-host-screen-lock) for how MATE and Xfce count the screen delays in minutes and when Xfce sessions pick up a change. With `gnome` the extension command is unchanged, so an environment that keeps the default sees no change to its hosts. Changing the value changes the extension command, so the next `azd provision` runs the bootstrap again on existing hosts. It adds the new desktop next to the old one, and the sessions that start afterwards use the new desktop. Drain the hosts first, because the bootstrap also updates every package and reinstalls the release agent, and on Ubuntu it restarts xrdp. To choose Xfce or MATE when you run a bootstrap script by hand, set `LINUXBROKER_DESKTOP=xfce` or `LINUXBROKER_DESKTOP=mate` in its environment.
- **xpra is removed.** The broker only ever connected through xrdp, and `Connect-LinuxBroker.ps1` never started an xpra application, so the bootstrap no longer adds the xpra repository, installs xpra or opens TCP 443; the host firewall allows only SSH and RDP. The RHEL 8 bootstrap is now built from the RHEL 9 one, so it also stops at the first step that fails, as the RHEL 9 bootstrap does. The extension command is unchanged, so `azd provision` does not run the bootstrap again on existing hosts. Instead, [Migrate-LinuxHostReleaseAgent.ps1](Migrate-LinuxHostReleaseAgent.ps1) from this release removes xpra from them: it stops and disables the xpra services and sockets, deletes `/etc/yum.repos.d/xpra.repo` and the xpra.org signing key, removes xpra's own packages but not the libraries they brought in, and closes TCP 443 in firewalld or ufw. Each step is best effort and reported in the migration output, and a host where one fails is still migrated. If a host serves something else on TCP 443, open it again after the migration. `Connect-LinuxBroker.ps1` now opens the desktop whatever `-Mode` it is given, and logs a warning for any value other than `desktop`.
- **Rocky Linux 9 and AlmaLinux 9 hosts.** `linuxHostOsVersion` accepts `rocky-9` and `alma-9`. Both run the RHEL 9 bootstrap, which skips the subscription registration on them, enables their CRB repository, installs EPEL from their own `epel-release` package and adds firewalld, which their Azure images leave out. The existing values set no purchase plan or disk size, so the template leaves existing hosts as they are. A VM's image cannot be changed in place, so to move an environment to one of them, replace its hosts as described for RHEL 7 above. Rocky Linux 9 is an Azure Marketplace image with a purchase plan, so the subscription must be allowed to buy Marketplace images; see [A Rocky Linux host deployment failed with `MarketplacePurchaseEligibilityFailed`](#a-rocky-linux-host-deployment-failed-with-marketplacepurchaseeligibilityfailed).
- **The login keyring unlocks.** Every checkout sets a new random password, which cannot protect a GNOME login keyring, and xrdp-sesman has no keyring PAM module, so until now applications that save passwords, such as browsers and Visual Studio Code, asked users for a keyring password at every sign-in. The broker now keeps a random key for each user, separate from the password, as the secret `keyring-<uid>` in a new Key Vault, `kr<app><env><suffix>`. A checkout reads the key, or creates it the first time, and hands it to the host, where `xrdp-startwm.sh` unlocks the login keyring with it before the desktop starts, or creates the keyring at the first sign-in. This works on every desktop the deployment offers. `azd provision` creates the vault, gives the API **Key Vault Secrets Officer** on that vault only, and sets `KEYRING_VAULT_URL` on the API. [Migrate-ExistingEnvironment.ps1](Migrate-ExistingEnvironment.ps1) provisions no infrastructure, so run `azd provision` first. Until then, and on hosts older than agent 1.2.0, no key is used and keyrings behave as before. A Key Vault error never fails a checkout: the API logs a warning, and that worker sends no key for the next five minutes.

  The first time a key meets a login keyring that something else protects, such as a password the user chose when an application first asked, the launcher moves that keyring to `~/.local/share/linuxbroker/keyring-backup/` and creates a new one. Passwords and tokens saved before the upgrade then have to be entered again. A profile reset writes a new version of the user's secret and keeps the old ones, which open the keyring kept with the old profile. Do not delete keyring secrets to reset a keyring: the vault keeps a deleted secret for 90 days, and until it is recovered or purged the API cannot create that user's key again, so their keyring stays locked.
- **Host agent 1.2.0.** Every script in `linux_host/` declares 1.2.0 and the API expects it, so **Fleet health** flags every host as **Agent outdated** until [Migrate-LinuxHostReleaseAgent.ps1](Migrate-LinuxHostReleaseAgent.ps1) from this release has updated it. 1.2.0 carries the merged release agent, the session launcher and its keyring unlock, the keyring key in `create-user.sh` and `manage-lease.sh`, the xpra cleanup and the idle timeout fixes below, and its heartbeat also reports the launcher's version. The migration restarts only the release agent's own units and reloads xrdp-sesman's configuration, so sessions in progress keep running, and each session uses the launcher from the next time it starts. It now runs as a bash script. Run Command starts a script with no `#!` line with `/bin/sh`, which on Ubuntu is dash, so earlier migrations failed on every Ubuntu host and left it on its old agent. Hosts that are not running are skipped and named at the end; migrate each one with `-LinuxHostNames` once it is started, because until then it keeps its old agent.
- **The idle timeout disconnects.** Before this release the idle timeout never disconnected anyone, on any distribution: the agent showed the warning, then logged `No xrdp connection process was found` every minute and left the session connected. Agent 1.2.0 finds the xrdp connection from the display socket's peer and ends it, which starts the grace period, and it never signals the xrdp daemon, which carries every connection on the host. It also counts idle time from the current connection at most. X keeps counting while a session is disconnected, and a reconnect sends it no input, so otherwise a user who reconnected after an idle disconnect would be disconnected again within a minute. An environment that already set an idle timeout starts enforcing it on each Ubuntu host as the host is migrated, so review **Idle timeout** in Host Settings first. RHEL, Rocky Linux and AlmaLinux do not package `xprintidle`, so their hosts still skip the timeout and log `Could not read idle time` instead. When a grace period ends with **Keep sessions alive** on, the agent also waits up to five seconds for the Xorg it ended to exit, instead of logging `ERROR: Xorg processes remain` for an Xorg that was still exiting.

### Recommended order

1. Run `azd env get-value linuxHostOsVersion`. If it returns `7-LVM`, set a supported value, as described above, before anything else.
2. Run `azd provision`. It creates the keyring vault, its role assignment and `KEYRING_VAULT_URL`, and its `postprovision` step rebuilds the images and restarts the apps. With `linuxHostDesktop` left at `gnome`, the Linux hosts' images and extensions do not change, so no bootstrap runs again.
3. Migrate one idle host with `.\Migrate-ExistingEnvironment.ps1 -EnvironmentName <environment-name> -SkipPostProvision -LinuxHostNames <host>`. Confirm that **Fleet health** shows it on 1.2.0, then sign in to it through AVD, open an application that saves a password, and check `sudo journalctl -t linuxbroker-startwm` on the host for `Unlocked the login keyring`.
4. Migrate the remaining hosts with `-SkipPostProvision` and no `-LinuxHostNames`, then confirm no powered-on host is flagged **Agent outdated**.
5. Replace, or bootstrap again, any Ubuntu hosts from earlier releases and any RHEL 7 hosts you are retiring.

Every layer tolerates the others being one release behind during the rollout, and the database does not change. Hosts on agent 1.1.0 ignore the key the new API sends and keep working, flagged **Agent outdated**. A 1.2.0 host that meets the previous API, or an API without `KEYRING_VAULT_URL`, gets no key and starts the desktop as before. The previous API drops the launcher's version from the heartbeat.

## Upgrading To Start On Demand

This release lets a checkout that finds no ready host start one, so a pool can scale to zero when nobody needs it (item 4.1 of the [roadmap](../docs/ROADMAP.md)), opens the Linux desktop full screen across every monitor (item 4.8), starts and stops the AVD session hosts on a schedule (item 4.5), and moves users' caches off the home directory share (item 4.6). The schedule adds a scaling plan and a role assignment on the subscription, so the release needs `azd provision`, the AVD session hosts need the new `Connect-LinuxBroker.ps1`, and the Linux hosts need the host migration.

- **Start on demand.** When a checkout finds no ready host, the API starts a stopped one for the user and answers `202` with how long to wait, instead of refusing. On the AVD session host, **Linux Desktop** shows *Your Linux desktop is starting…* with **Cancel**, asks again when the broker says to, and opens the desktop as soon as the host is reachable, for up to 10 minutes. The start is recorded as a scaling start is, in the scaling activity log as `Start On Demand` and in the audit log as `vm.start_on_demand`, and uses the API's existing **Desktop Virtualization Power On Off Contributor** role. It never takes the pool past the active rule's or window's `MaxVMs`, so a user who arrives when that many hosts are on and none is free is refused as before. Start on demand is on after the upgrade; an administrator can turn it off, and set how many hosts may start at once for waiting users (2 by default, up to 20), in the **Start on demand** card on the **Scaling** page.
- **Scale to zero.** While start on demand is on, the default rule and schedule windows may keep a minimum of 0 hosts, so idle hosts stop, for example overnight, and the first user to arrive waits a minute or two for one to start. Scaling counts waiting users as demand, and a scale-down keeps a host for each of them. A minimum of 0 cannot be saved while start on demand is off. If it is turned off afterwards, scaling keeps one host on for those rules and windows, and the card says so.
- **Connect-LinuxBroker.ps1 2.0.0.** Besides waiting for a host to start, the script tries a request again after no answer, a `408`, a `429` or a `5xx`, until three fail in a row, where the previous script tried three times at once. It requests a new token once when the broker refuses one, and tells the user in plain words what went wrong. Each attempt is logged under the **LinuxBrokerScript** source in the session host's Application event log. Session hosts keep the script they were deployed with, so the migration's new third step, [Update-AvdHostBrokerScript.ps1](Update-AvdHostBrokerScript.ps1), replaces it on every running session host. An older script treats `202` as a failure: its user is told that no Linux host is available while a host starts for them, and gets that host at their next try once it is up. The script now reports its version with each checkout, and the **Start on demand** card shows, for the session hosts that asked for a host in the last seven days, how many run each version, and names those whose script cannot wait.
- **Waits on the dashboard.** Every time a user is told to wait, the checkout records a `Starting` event. The dashboard's checkout card adds how many users waited, how many of them got a host, the median and 95th percentile wait, and how many are waiting now, and the capacity chart shows the users who waited. **Attention** no longer reports that no host is ready for a pool scaled to zero that nobody is waiting on.
- **Full screen across every monitor.** The new script opens the Linux desktop full screen across every monitor of the user's AVD session, where the previous one left that to the user's own Remote Desktop Connection settings, so users with more than one monitor see the desktop on all of them. The new `avdLinuxDesktopFullScreen` and `avdLinuxDesktopMultiMonitor` values open it in a window or on one monitor instead; set them only after every session host runs the new script. See [Linux Desktop Display](#linux-desktop-display).
- **The AVD session hosts start and stop on a schedule.** `azd provision` creates a scaling plan, assigns it to the host pool, turns on Start VM on Connect and gives the Azure Virtual Desktop service principal **Desktop Virtualization Power On Off Contributor** on the subscription, which needs Owner or User Access Administrator there. The plan takes effect at once. In UTC, unless you set `avdScalingPlanTimeZone`, it keeps at least 20% of the session hosts on from 07:00 on weekdays, 10% from 18:00 and none on Saturday and Sunday, rounded up, and it stops a session host only once the session host has no sessions. Review the schedule before you provision, and set `avdScalingPlanEnabled` to `false` if the host pool already has a scaling plan or the session hosts should stay as they are. See [AVD Autoscale](#avd-autoscale).
- **`azd provision` leaves stopped hosts' extensions alone.** Azure refuses to change a VM extension on a VM that is not running, and scaling, start on demand and autoscale all stop hosts, so `preprovision` lists the hosts that are not running and the deployment leaves out their extensions. It also keeps any `excludeFromScaling` tag on the session hosts, which a deployment would otherwise remove.
- **Caches stay on the local disk.** Each broker user's cache moves from `~/.cache`, in the home directory on the NFS share, to `/var/cache/linuxbroker/users/<user>` on the host's own disk. `create-user.sh` creates it at checkout, `manage-lease.sh` deletes it when the broker returns the host, and the session launcher points `XDG_CACHE_HOME` at it, as the new `/etc/profile.d/linuxbroker-cache.sh` does in login shells. A cache no longer follows its user to the next host, so applications rebuild their caches the first time they start on each host. Caches that sessions left in `~/.cache` stay on the share and can be deleted. See [How hosts use the share](#how-hosts-use-the-share).
- **NFS read-ahead of 15 MiB.** Linux hosts now read ahead 15 MiB at a time on NFS mounts, instead of 128 KiB, as Microsoft recommends for Azure Files NFS shares. This applies to every NFS mount on a host, not only to the home directory share.
- **The broker's logs rotate.** The logs of the release agent, its watcher, `create-user.sh`, the host settings and `session-control.sh` in `/var/log` grew without limit until now. They now rotate every week, or sooner once one passes 50 MB, and each keeps four compressed copies.
- **`install-host-config.sh`.** The three bootstraps and the host migration install `/usr/local/bin/install-host-config.sh` and run it as root. It writes the read-ahead rule, the log rotation, the cache directory with the file that empties it at every restart, and the profile script, and it removes the unused `/awipsprofiles`, because `create-user.sh` now mounts the share on `/nfs_profiles` while it creates a home directory. `azd provision` doesn't run the bootstrap again on existing hosts, so they get the script from the migration; a host the migration skips because it is stopped keeps its caches in the home directory until it is migrated. The script can be run again at any time. See [Sizing the share](#sizing-the-share) for how the share's size sets its IOPS.

### Recommended order

1. Run [Migrate-ExistingEnvironment.ps1](Migrate-ExistingEnvironment.ps1). It applies SQL scripts `144`–`156` before the new images start, restarts the apps in the order API, task, front end, migrates the Linux hosts, and then updates `Connect-LinuxBroker.ps1` on the running AVD session hosts. Running it before `azd provision` updates the session hosts before autoscale starts stopping them.
2. Start any AVD session host the migration skipped because it was not running, and update it with `-SkipPostProvision -SkipLinuxHostReleaseAgentMigration -AvdHostNames <session-host>`.
3. Review the [AVD autoscale](#avd-autoscale) values, then run `azd provision`. It creates the scaling plan and the role assignment and turns on Start VM on Connect, and its `postprovision` step builds the images and restarts the apps again. If `preprovision` warns that it cannot assign the role, have an Owner or User Access Administrator run the command it prints, then run `azd provision` again.
4. With a test user, open **Linux Desktop** while no host is free, for example with every idle host stopped, and confirm that the wait window appears and the desktop opens once the host is up. In a terminal in that session, `echo $XDG_CACHE_HOME` should print `/var/cache/linuxbroker/users/<user>`.
5. Before you set any minimum to 0, confirm that the **Start on demand** card names no session host whose script cannot wait. The card goes by each session host's latest checkout in the last seven days, so a session host updated since then is listed until its next checkout.

Every layer tolerates the others being one release behind during the rollout. Against a database without the new procedures, the new API refuses a checkout that finds no host with `409`, as before, and logs it once, and the portal says that the broker does not support start on demand yet. The previous API build keeps working against the new database: it never answers `202`, so nobody waits, and it refuses a minimum of 0 as before. Session hosts that still run an older script behave as described above. The Linux host changes don't depend on the API: a migrated host keeps caches on its own disk with either API, and a host that is not migrated yet keeps them in the home directory.

## Manual Steps After `azd up`

### Admin consent

`preprovision` attempts tenant-wide admin consent for both app registrations. It succeeds when the operator can grant consent, and prints a warning otherwise. If you saw that warning, have a tenant admin grant consent for:

- Frontend delegated permissions such as `User.Read`, `profile`, `email`, `offline_access`, `openid`, and the API delegated scope.
- API application permissions to Microsoft Graph used for group and directory reads.

Without admin consent, deployment can still complete, but sign-in and Graph-backed authorization checks will not work correctly.

### Microsoft Entra authentication for RDP

If `preprovision` warned that it could not enable Microsoft Entra authentication for RDP, have a tenant admin turn it on for the **Windows Cloud Login** service principal (`270efc09-cd0d-444b-a71f-39af4910ec45`) under **Microsoft Entra ID** > **Devices** > **Remote connection configuration**, as described in [Configure single sign-on for Azure Virtual Desktop](https://learn.microsoft.com/azure/virtual-desktop/configure-single-sign-on#enable-microsoft-entra-authentication-for-rdp). Until it is enabled, connections to the session hosts fail.

The first time a user connects to a session host, Windows asks them to allow the remote desktop connection. To hide that prompt, add the session hosts to a device group listed under the service principal's target device groups.

### AVD user access

Add the users who should reach Linux hosts to the AVD users group, `<appName>-<environmentName>-avd-users-sg` or the group you supplied in `avdUsersGroupId`. They then see **Linux Desktop** in Windows App or the AVD web client. The deploying user is added automatically when `preprovision` creates the group.

## Validation Checklist

After a successful deployment, verify these items:

### azd environment values

```powershell
azd env get-values
```

Confirm that values such as the following are present:

- `frontendClientId`
- `apiClientId`
- `avdHostGroupId`
- `linuxHostGroupId`
- `linuxHostSshPublicKey`
- `linuxHostSshPrivateKey`

### Azure resources

Verify that the expected resources exist in the target resource group:

- frontend web app
- API web app
- task function app
- ACR
- Key Vault, and the keyring vault
- SQL server and database
- optional Linux and AVD VMs
- the `linuxbroker.internal` private DNS zone with an A record for each Linux host, unless `domainName` was supplied
- the NFS storage account, its `home` share, and its private endpoint, unless `nfsShare` was supplied or `deployNfsShare` is `false`
- for AVD, the host pool, the desktop and RemoteApp application groups, the workspace, and the **Linux Desktop** application

### Key Vault

Confirm the vault contains:

- `db-password`
- `linux-host`

The keyring vault, `kr<app><env><suffix>`, starts empty and gains a `keyring-<uid>` secret at each user's first checkout. The API app has **Key Vault Secrets Officer** on it and a `KEYRING_VAULT_URL` app setting that points at it.

### SQL

Confirm the database contains the expected tables and procedures.

This includes the newer objects used by the current deployment flow:

- `dbo.VmUsers`
- `dbo.VirtualMachines`
- `dbo.VmScalingRules`
- `dbo.VmScalingActivityLog`
- `dbo.LinuxHostSettings`
- `dbo.RegisterLinuxHostVm`
- `dbo.GetLinuxHostSettings`
- `dbo.UpdateLinuxHostSettings`
- `dbo.RecordHostSettingsApplied`

`dbo.LinuxHostSettings` holds a single fleet-wide profile and is seeded automatically with the values that were previously hardcoded in the release agent, so applying it changes no behavior. `dbo.VirtualMachines` also gains `SettingsVersion` and `SettingsAppliedDate`, which the portal uses to show which hosts have applied the current profile.

For more database detail, see [../sql_queries/README.md](../sql_queries/README.md).

### Entra authorization model

Confirm that:

- the function app managed identity has the `ScheduledTask` API app role
- the AVD host group has the `AvdHost` API app role
- the Linux host group has the `LinuxHost` API app role
- every portal administrator holds `Reader`, `Operator` or `FullAccess` on the API app, and `allowLegacyScopeAccess` is `false`
- VM managed identities are members of the correct Entra groups
- the AVD users group holds **Desktop Virtualization User** on the RemoteApp application group and **Virtual Machine User Login** on each session host
- the API app's managed identity holds **Desktop Virtualization Power On Off Contributor** on the VM resource group

### Application health

Confirm that:

- the frontend and API apps restarted after the ACR builds
- the function app restarted after the image build
- frontend sign-in works after admin consent is granted
- the portal's connectivity test succeeds for each Linux host, which confirms DNS resolution and SSH from the API
- a user in the AVD users group can open **Linux Desktop** and land on a Linux desktop, and their home directory is on the NFS share (`df -h ~` on the Linux host)
- AVD checkout and Linux host release operations work end to end

## Rerunning Parts Of The Deployment

You do not always need to reprovision the whole environment.

### Rebuild container images and restart apps

```powershell
Set-Location .\deploy
.\Build-ContainerImages.ps1 -EnvironmentName <environment-name>
```

### Rerun post-provision tasks

```powershell
Set-Location .\deploy
.\Post-Provision.ps1 -EnvironmentName <environment-name>
```

That reruns the image build, SQL bootstrap, function-role assignment, VM group sync, and Linux host SQL registration.

## Troubleshooting

### The SSH key prompt did not appear

The prompt only appears for local interactive runs. If the console is redirected or the run is happening in CI, the hook will use the non-interactive path and auto-generate keys instead.

### `ssh-keygen` was not found

Install the OpenSSH Client on the local machine, or prepopulate both `linuxHostSshPublicKey` and `linuxHostSshPrivateKey` in the azd environment.

### SQL bootstrap failed with a connectivity or firewall error

`postprovision` connects to SQL from the machine running `azd up`, not from inside Azure. Set `allowedClientIp` before provisioning so the Bicep deployment adds the client-IP firewall rule.

### App registration or group operations failed during `preprovision`

The signed-in operator likely lacks enough Microsoft Entra permissions to create applications, groups, service principals, or app-role assignments.

### Sign-in or Graph-backed authorization fails after deployment

Admin consent was likely not granted yet for the frontend delegated permissions or the API Graph application permissions.

### Linux hosts were provisioned but do not appear in SQL

Rerun [Post-Provision.ps1](Post-Provision.ps1) after confirming SQL connectivity. Linux host SQL registration is intentionally limited to Linux hosts only.

### The portal's connectivity test or a checkout fails to reach a Linux host

The API connects to `<LINUX_HOST_ADMIN_LOGIN_NAME>@<hostname>.<DOMAIN_NAME>` over SSH from inside the virtual network. With the default configuration, confirm that the host has an A record in the `linuxbroker.internal` private DNS zone and that the zone is linked to the virtual network. If you supplied `domainName`, confirm that `<hostname>.<domainName>` resolves from the API's virtual network. Also confirm that the API app shows virtual network integration with the `snet-appsvc` subnet.

If the API log shows `Load key "/tmp/private_key.pem": error in libcrypto` followed by `Permission denied (publickey)`, the API image is older than version 0.160. The private key loses its trailing newline on the way into Key Vault, and OpenSSH will not load a key without one; 0.160 restores it. Rebuild the images as described in [Rebuild container images and restart apps](#rebuild-container-images-and-restart-apps).

### Linux Desktop does not appear for a user

Confirm that the user is a member of the AVD users group. The group must hold **Desktop Virtualization User** on the RemoteApp application group; that assignment is created only when `avdUsersGroupId` has a value during provisioning, so rerun `azd provision` after setting it.

### Linux Desktop opens but sign-in to the session host fails

Confirm that Microsoft Entra authentication for RDP is enabled on the Windows Cloud Login service principal (see [Microsoft Entra authentication for RDP](#microsoft-entra-authentication-for-rdp)) and that the user holds **Virtual Machine User Login** on the session host through the AVD users group.

### The AVD session host is not joined to Microsoft Entra ID

Users cannot sign in to a session host that is not joined, even though the `AADLoginForWindows` extension reports success. On the host, `dsregcmd /status` shows `AzureAdJoined : NO`, and the **Microsoft-Windows-User Device Registration/Admin** event log shows `error_hostname_duplicate` ("Another object with the same value for property hostnames already exists").

A device object left over from an earlier deployment that used the same VM name blocks the join. In Microsoft Entra ID, find the devices with the session host's name, confirm from the Azure resource ID on the device that its VM no longer exists, and delete that device. The host retries the join on its own, typically within 15 minutes.

### Linux Desktop closes without connecting after the display values changed

A session host whose `Connect-LinuxBroker.ps1` is older than 2.0.0 refuses the `-FullScreen` and `-MultiMonitor` arguments that `azd provision` adds to the RemoteApp's command line when `avdLinuxDesktopFullScreen` or `avdLinuxDesktopMultiMonitor` is `false`. PowerShell stops before the script runs, so **Linux Desktop** closes at once and nothing is logged under the **LinuxBrokerScript** source. Update the script on that session host with [Update-AvdHostBrokerScript.ps1](Update-AvdHostBrokerScript.ps1) and `-AvdHostNames <session-host>`, or set both values back to `true` and run `azd provision` again. See [Linux Desktop Display](#linux-desktop-display).

### Linux Desktop opens but reports that no Linux host is available

`Connect-LinuxBroker.ps1` shows this when the broker answers `409`: no host is ready and the broker cannot start one, because start on demand is off, the active rule or window already has `MaxVMs` hosts on, or no stopped host is free to start. Hosts in maintenance, draining or waiting for cleanup are never started. The session host's Application event log has the broker's answer to each attempt under the **LinuxBrokerScript** source, and the portal's scaling activity log shows each start on demand. Otherwise, confirm in the portal that at least one Linux host is available.

A session host whose script is older than 2.0.0 shows the same message while a host starts for its user, after logging `Failed to retrieve VM information from API response.` three times. The **Start on demand** card on the **Scaling** page names such session hosts; update them as described in [Migration For Existing Deployments](#migration-for-existing-deployments).

### Linux Desktop says the Linux desktop is taking longer than usual to start

The user waited `MaxWaitSeconds` (10 minutes by default) and no host became ready for them. Usually the host the broker started did not become reachable on SSH: find it in the portal's scaling activity log under the `Start On Demand` action, then check its power state and reachability. The broker stops counting a host as starting 10 minutes after it started, so the next request can start another, if a stopped host is free and `MaxVMs` allows. A start that Azure refuses is logged by the API, and the user is then refused with `409` instead of waiting.

### Linux Desktop reports that the Linux Broker could not authenticate this session host

`Connect-LinuxBroker.ps1` shows this when the session host cannot get a token from its managed identity (`Failed to obtain access token` in the **LinuxBrokerScript** event log) or the broker refuses it (`The broker refused this session host (403)`). A `403` means the session host's managed identity is not yet in the AVD host group; rerun `azd hooks run postprovision`. The script renews a token the broker refuses with `401` once before it gives up.

### Start VM on Connect does not start a session host

Start VM on Connect needs the Azure Virtual Desktop service principal to hold **Desktop Virtualization Power On Off Contributor** or **Desktop Virtualization Power On Contributor** on a scope that contains the session hosts. `preprovision` warns when the deployment cannot assign it, and a new assignment can take a few minutes to take effect. Also confirm that `avdStartVmOnConnect` is `true` and that the host pool's **Properties** in the Azure portal show **Start VM on Connect** turned on. In a pooled host pool, Start VM on Connect starts a session host only when none is running, and another only when the running ones reach their session limit.

### The portal shows "No access" after signing in

The signed-in account holds none of the Broker API's `Reader`, `Operator` or `FullAccess` app roles. Assign one (see [Portal roles](#portal-roles)) and sign in again. If the portal instead reports that it could not verify your roles, the portal could not reach the API's `/api/me` endpoint; check the API app's health.

### A host stays Cleanup pending

The broker keeps a returned host out of the pool until the previous user's account has been removed. The API log names the reason on each retry: the user is still signed in (the host agent signs them off when the grace period expires), the host is powered off or unreachable (retries resume when it is back), or the home directory is still mounted on a host that has not been migrated. Use **Retry cleanup** in the portal after fixing the cause.

### Released Linux hosts never return to Available

The function app returns released hosts to the pool. If hosts stay **Released** and the API log shows `Access denied: insufficient role permissions or group membership.` at the start of every minute, the function app's API token does not carry the `ScheduledTask` role.

This happens when the function app requested a token before the role was assigned, which earlier versions of [Post-Provision.ps1](Post-Provision.ps1) allowed on a new deployment. The managed identity service caches the token for up to 24 hours, so restarting the function app does not help. Either wait for the token to expire, or give the function app a new identity. Stop the app first, so it cannot request a token before the role is in place:

```powershell
az functionapp stop --name <task-app> --resource-group <resource-group>
$old = az functionapp identity show --name <task-app> --resource-group <resource-group> --query principalId --output tsv
az functionapp identity remove --name <task-app> --resource-group <resource-group>
$new = az functionapp identity assign --name <task-app> --resource-group <resource-group> --query principalId --output tsv

# Move the registry pull assignment to the new identity under the same name, so the
# next azd provision updates it instead of failing.
$acrId = az acr show --name <registry> --query id --output tsv
$name = az role assignment list --scope $acrId --role AcrPull --query "[?principalId=='$old'].name" --output tsv
az role assignment delete --ids "$acrId/providers/Microsoft.Authorization/roleAssignments/$name"
az role assignment create --name $name --assignee-object-id $new --assignee-principal-type ServicePrincipal --role AcrPull --scope $acrId

.\Assign-FunctionAppApiRole.ps1 -ResourceGroupName <resource-group> -TaskAppName <task-app> -ApiClientId <api-client-id>
Start-Sleep -Seconds 120
az functionapp start --name <task-app> --resource-group <resource-group>
```

### The Linux host deployment failed with a Trusted Launch error

Trusted Launch requires Generation 2 images. The RHEL, Rocky Linux and AlmaLinux options map to Gen2 images; if you customized the image, choose a Gen2 SKU.

### A Rocky Linux host deployment failed with `MarketplacePurchaseEligibilityFailed`

The Rocky Linux 9 image is a free Azure Marketplace offer from the Rocky Enterprise Software Foundation, and Azure checks that the subscription may buy it before it creates the VM. `preprovision` accepts the image's terms, so when the check still fails, the subscription cannot buy Marketplace offers at all: its billing account turns off Azure Marketplace purchases, its offer type does not allow them, or a private Azure Marketplace does not list the offer. Confirm the terms with `az vm image terms show --urn resf:rockylinux-x86_64:9-base:latest --query accepted`, then either have the billing account's administrator allow the purchase, or switch to AlmaLinux 9, whose image has no purchase plan:

```powershell
azd env set linuxHostOsVersion alma-9
azd provision
```

If the failed deployment left a Linux host VM behind, delete it before you run `azd provision` again, because Azure cannot change the image of an existing VM.

### A VM deployment failed with `SkuNotAvailable`

The requested size is restricted for your subscription in that region, which is common for popular sizes. List the sizes your subscription can use with `az vm list-skus --location <region> --resource-type virtualMachines --output table` (sizes with `NotAvailableForSubscription` are blocked), then choose another size and rerun `azd provision`:

```powershell
azd env set linuxHostVmSize Standard_D2as_v5
azd env set avdVmSize Standard_D8as_v4
```

`avdVmSize` accepts only the sizes listed in `main.bicep`, and both host types use Trusted Launch, so pick a Gen2-capable size.

### A deployment failed with `Cannot modify extensions in the VM when the VM is not running`

A host was stopped or deallocated when the deployment tried to update its VM extensions. `preprovision` lists the hosts that are not running so that the deployment leaves out their extensions, so either the host stopped after `preprovision` listed it, which the broker's scaling, start on demand and autoscale can all do at any time, or `preprovision` could not list the VMs and warned that the deployment would update the extensions of every host. Run `azd provision` again, which lists the hosts again.

### A deployment failed with `AuthorizationFailed` on a role assignment on the subscription

The deployment tried to give the Azure Virtual Desktop service principal **Desktop Virtualization Power On Off Contributor** on the subscription, and your account cannot assign roles there. `preprovision` could not check this beforehand and warned about it. Have an Owner or User Access Administrator run the command from that warning, which looks like this:

```powershell
az role assignment create --assignee-object-id <object-id> --assignee-principal-type ServicePrincipal --role 40c5ff49-9181-41f8-ae61-143b0e78555e --scope /subscriptions/<subscription-id>
```

`40c5ff49-9181-41f8-ae61-143b0e78555e` is **Desktop Virtualization Power On Off Contributor**, and `az ad sp list --filter "appId eq '9cdead84-a844-4324-93f2-b2e6bb768d07'" --query "[0].id" --output tsv` prints the object ID of the service principal. Then set `assignAvdAutoscaleRole` to `false`, because the check that could not tell may not tell next time either, and run `azd provision` again. To do without autoscale instead, set `avdScalingPlanEnabled` and `avdStartVmOnConnect` to `false`. See [The autoscale role](#the-autoscale-role).

### A deployment failed with `RoleAssignmentExists`

The Azure Virtual Desktop service principal already holds **Desktop Virtualization Power On Off Contributor** on the subscription through an assignment that `preprovision` could not see, so the deployment tried to assign it again. Set `assignAvdAutoscaleRole` to `false` and run `azd provision` again.

### The AVD scaling plan is not assigned to the host pool

The deployment leaves the plan assigned to no host pool when `avdScalingPlanEnabled` is `false`, and when `preprovision` finds that the Azure Virtual Desktop service principal cannot get its role, because the service principal cannot be found or created, or because it does not hold the role and your account cannot assign it. `preprovision` says which in a warning. Once the role is assigned, run `azd provision` again. See [The autoscale role](#the-autoscale-role).

If the `avdScalingPlan` deployment fails with `BadRequest` and `unable to access host pool`, Azure Virtual Desktop could not use its role on the host pool. The deployment assigns the plan last, but a role assigned in the same deployment can still take a few more minutes to take effect, so wait and run `azd provision` again. With `assignAvdAutoscaleRole` set to `false`, also confirm that the service principal holds the role on the subscription.

A host pool can have only one scaling plan. If the host pool is assigned to another plan, remove it from that plan in the Azure portal, or set `avdScalingPlanEnabled` to `false` to keep the other plan.

### `preprovision` warns that `avdScalingPlanTimeZone` is not a Windows time zone ID

`preprovision` looks the value up among the Windows time zone IDs that the machine it runs on knows. Use the Windows ID, such as `Eastern Standard Time` for `America/New_York`. On Windows, `Get-TimeZone -ListAvailable` lists the IDs in its `Id` column, and in PowerShell 7 on any platform the first line below converts an IANA name:

```powershell
$id = $null; [System.TimeZoneInfo]::TryConvertIanaIdToWindowsId('America/New_York', [ref]$id) | Out-Null; $id
azd env set avdScalingPlanTimeZone "Eastern Standard Time"
```

`preprovision` passes a value it does not know to the deployment unchanged, and Azure refuses the scaling plan if Azure does not know it either.

### Home directories are not on the NFS share

Linux hosts mount the share when the broker first creates a user. Confirm that `NFS_SHARE` is set on the API app, that `<account>.file.core.windows.net` resolves to a private IP address from the Linux host, and that the storage account's private endpoint is approved.

If the share is reachable but `df -h ~` inside a session shows the local disk, check `/var/log/release-session.log` for `Attempting to unmount /home/<user>` a few seconds after the checkout. Older release agents unmounted the home whenever the user was not signed in, and the broker's own SSH login at checkout wakes the agent, so the home was usually unmounted before the user arrived. The session then ran on the local disk, and that data was deleted when the broker returned the host. Update the host scripts with [Migrate-LinuxHostReleaseAgent.ps1](Migrate-LinuxHostReleaseAgent.ps1).

Current hosts keep the home mounted while the host holds the user's lease, which lasts from checkout until the broker returns the host. At return, `manage-lease.sh` unmounts the home before the broker runs `userdel -r`, so only the empty local mount point is removed and the profile stays on the share. The API also refuses to run `userdel -r` while the home is still mounted, and logs `home directory is still mounted` instead. If a checkout fails after the host has written the lease, the API runs the same cleanup before it puts the host back in the pool.

### Sessions are slow on the home directory share

First check whether the share holds requests back, as described in [Sizing the share](#sizing-the-share), and make it larger if it does. Then check the host, and a session on it:

```bash
# The read-ahead of each NFS mount on the host, in KiB. It should be 15360.
awk 'NR > 1 { print $4 }' /proc/fs/nfsfs/volumes | while read -r device; do
    echo "$device $(cat "/sys/class/bdi/$device/read_ahead_kb")"
done
# In a terminal in the session. It should print /var/cache/linuxbroker/users/<user>.
echo "$XDG_CACHE_HOME"
```

- A read-ahead of 128 means the host has not run `install-host-config.sh`, or `/etc/udev/rules.d/99-nfs.rules` is a rule of your own, which the script leaves alone. Run `sudo /usr/local/bin/install-host-config.sh`, which reports each step, or migrate the host with [Migrate-LinuxHostReleaseAgent.ps1](Migrate-LinuxHostReleaseAgent.ps1).
- An empty `XDG_CACHE_HOME` means the session keeps its caches in `~/.cache` on the share. Either the host was migrated after the session started, or `create-user.sh` could not create the cache and said why in `/var/log/createuser.log`, in a line that ends `so the cache of <user> stays in the home directory.`

### A RHEL session is stuck on a lock screen that will not accept the password

The GNOME lock screen inside an xrdp session often cannot be unlocked after a reconnect. Confirm the screen lock configuration actually applied on the host using the commands in [Linux Host Screen Lock](#linux-host-screen-lock). The most common cause is a missing `system-db:local` line in `/etc/dconf/profile/user`, which makes GNOME ignore the settings even though the files under `/etc/dconf/db/local.d/` are present.

### A session starts a different desktop than `linuxHostDesktop` names

`xrdp-startwm.sh` starts the desktop named in `/etc/linuxbroker/desktop.conf` and logs each start under the `linuxbroker-startwm` tag. When that desktop is not installed, it runs the distribution's own session script instead and logs that too. A host that was migrated rather than bootstrapped has no `desktop.conf`, so it always runs the distribution's session script. Drain such a host and run its bootstrap again, which installs the desktop and writes the file:

```bash
cat /etc/linuxbroker/desktop.conf
sudo journalctl -t linuxbroker-startwm -n 20
```

### Applications ask for a password to unlock the login keyring

The session launcher logs what it did with the user's keyring under the `linuxbroker-startwm` tag, and the key the broker sent, if any, is in `/run/linuxbroker-keyring/<user>`:

```bash
sudo journalctl -t linuxbroker-startwm -n 20
sudo ls -l /run/linuxbroker-keyring/
```

- No key file means the host received no key. Check that the API app has the `KEYRING_VAULT_URL` setting, which `azd provision` adds, and that **Fleet health** shows the host on agent 1.2.0. The API logs `Could not use the keyring key` when Key Vault refused a request, for example while a new role assignment is still propagating, and then sends no key from that worker for five minutes. It logs `a deleted secret with that name must be recovered or purged first` when that user's secret was deleted; recover it, or purge it to give the user a new key.
- `The login keyring of <user> stays locked: the key does not open it.` means another password protects the keyring, and the launcher left it alone because it did not start the keyring daemon itself, typically because one from an earlier session of the user was still running. The next session that starts without one moves the old keyring aside and creates a new one.
- No `linuxbroker-startwm` entries for the session mean it did not start through the launcher; see the previous entry.

### The idle timeout does not disconnect anyone

Check `/var/log/release-session.log` on the host once the session has been idle for longer than the timeout:

- `Could not read idle time for user <user>. Skipping idle enforcement.` means `xprintidle` is missing. RHEL, Rocky Linux and AlmaLinux do not package it, so only Ubuntu hosts enforce the timeout.
- `No xrdp connection process was found for user <user> on display <display>` every minute means the host runs an agent older than 1.2.0, which never found the connection; migrate it. On agent 1.2.0 it means xrdp runs with `fork=false` in `/etc/xrdp/xrdp.ini`, so one xrdp process carries every connection on the host, and the agent does not end it.

### The Custom Script Extension failed on the screen lock step

The bootstrap fails deliberately if the host settings cannot be applied, so the problem is visible instead of silently leaving the lock screen enabled. Check that `scriptSourceRoot` is reachable from the host so `apply-host-settings.sh` can be downloaded, or set `linuxHostDisableScreenLock` to `false` to seed the profile with the lock screen left enabled.

## Related Files

- [azure.yaml](azure.yaml)
- [Initialize-DeploymentEnvironment.ps1](Initialize-DeploymentEnvironment.ps1)
- [Post-Provision.ps1](Post-Provision.ps1)
- [Build-ContainerImages.ps1](Build-ContainerImages.ps1)
- [Initialize-Database.ps1](Initialize-Database.ps1)
- [Register-LinuxHostSqlRecords.ps1](Register-LinuxHostSqlRecords.ps1)
- [bicep/main.bicep](bicep/main.bicep)
- [../sql_queries/README.md](../sql_queries/README.md)