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
- Create Azure role assignments.
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
- `nfsShareQuotaGiB`: provisioned size of that share in GiB. Premium shares have a 100 GiB minimum, and cost is based on the provisioned size. Defaults to `100`.
- `avdUsersGroupId`: object ID of an existing Entra group whose members can launch **Linux Desktop**. Leave empty to have `preprovision` create `<appName>-<environmentName>-avd-users-sg` and add you to it.
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

Use the migration flow when you already have a deployed customer environment and want to roll forward the current application, SQL, and Linux-host release-agent changes without treating that as part of the normal `azd up` lifecycle.

The migration entrypoint is [Migrate-ExistingEnvironment.ps1](Migrate-ExistingEnvironment.ps1).

That script intentionally stays separate from `azd up`:

- `azd up` continues to express the desired greenfield deployment for new environments.
- [Migrate-ExistingEnvironment.ps1](Migrate-ExistingEnvironment.ps1) is the supported in-place process for existing environments.

By default, the migration script does two things:

1. Runs [Post-Provision.ps1](Post-Provision.ps1) so the existing environment gets the latest container images, SQL scripts, role assignments, VM group sync, and Linux host SQL registration.
2. Runs [Migrate-LinuxHostReleaseAgent.ps1](Migrate-LinuxHostReleaseAgent.ps1) so existing Linux hosts get the current release-agent files, one-minute reconciliation timer, and `systemd-logind` watcher.

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

### Linux Desktop opens but reports that no Linux host is available

`Connect-LinuxBroker.ps1` shows this when checkout does not return a host. Check the **LinuxBrokerScript** source in the session host's Application event log. A `403` from the API means the session host's managed identity is not yet in the AVD host group; rerun `azd hooks run postprovision`. Otherwise, confirm in the portal that at least one Linux host is available.

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

### Home directories are not on the NFS share

Linux hosts mount the share when the broker first creates a user. Confirm that `NFS_SHARE` is set on the API app, that `<account>.file.core.windows.net` resolves to a private IP address from the Linux host, and that the storage account's private endpoint is approved.

If the share is reachable but `df -h ~` inside a session shows the local disk, check `/var/log/release-session.log` for `Attempting to unmount /home/<user>` a few seconds after the checkout. Older release agents unmounted the home whenever the user was not signed in, and the broker's own SSH login at checkout wakes the agent, so the home was usually unmounted before the user arrived. The session then ran on the local disk, and that data was deleted when the broker returned the host. Update the host scripts with [Migrate-LinuxHostReleaseAgent.ps1](Migrate-LinuxHostReleaseAgent.ps1).

Current hosts keep the home mounted while the host holds the user's lease, which lasts from checkout until the broker returns the host. At return, `manage-lease.sh` unmounts the home before the broker runs `userdel -r`, so only the empty local mount point is removed and the profile stays on the share. The API also refuses to run `userdel -r` while the home is still mounted, and logs `home directory is still mounted` instead. If a checkout fails after the host has written the lease, the API runs the same cleanup before it puts the host back in the pool.

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