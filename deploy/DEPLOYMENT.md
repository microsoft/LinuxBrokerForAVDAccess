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
- Azure Key Vault.
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
- `linuxHostOsVersion`: Linux image SKU. The RHEL options (`7-LVM`, `8-LVM`, `9-LVM`) map to the Generation 2 images that Trusted Launch requires.
- `linuxHostDisableScreenLock`: `true` or `false`. Disables the GNOME screen saver and screen lock on RHEL hosts. Defaults to `true`. See [Linux Host Screen Lock](#linux-host-screen-lock).
- `azureCloudName`: `AzurePublic`, `AzureUSGovernment`, or `AzureCustom`. See [Choosing The Target Azure Cloud](#choosing-the-target-azure-cloud).
- `scriptSourceRoot`: root URL the Linux host and AVD host bootstrap scripts are downloaded from.
- `domainName`: DNS suffix the broker appends to Linux host names when it connects over SSH. Leave empty to use the deployment's private DNS zone, `linuxbroker.internal`. If you set it, you are responsible for DNS records that resolve `<hostname>.<domainName>` from the API's virtual network.
- `nfsShare`: an existing NFS share, in `<server>:/<export>` form, to mount for Linux home directories. Leave empty to have the deployment provision one.
- `deployNfsShare`: `true` or `false`. Provisions a premium Azure Files NFS share when `nfsShare` is empty. Defaults to `true`.
- `nfsShareQuotaGiB`: provisioned size of that share in GiB. Premium shares have a 100 GiB minimum, and cost is based on the provisioned size. Defaults to `100`.
- `avdUsersGroupId`: object ID of an existing Entra group whose members can launch **Linux Desktop**. Leave empty to have `preprovision` create `<appName>-<environmentName>-avd-users-sg` and add you to it.
- `vmHostResourceGroup`: override if managed VMs live in a different resource group.

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

RHEL hosts install the `Server with GUI` group, so they run a GNOME desktop. By default the
bootstrap script disables the GNOME screen saver and screen lock on those hosts.

This is on by default because a locked GNOME greeter inside an xrdp or xpra session frequently
cannot be unlocked after a reconnect. When that happens the user cannot get back into the
desktop, and the host stays leased until the lease is released manually.

The configuration is applied through a dconf system database:

| File on the host | Written by |
| --- | --- |
| `/etc/dconf/db/local.d/00-screensaver` | [linux_host/apply-host-settings.sh](../linux_host/apply-host-settings.sh) |
| `/etc/dconf/db/local.d/locks/screensaver` | [linux_host/apply-host-settings.sh](../linux_host/apply-host-settings.sh) |
| `/etc/dconf/profile/user` | [linux_host/apply-host-settings.sh](../linux_host/apply-host-settings.sh) |

These files were previously static and downloaded during bootstrap. They are now generated from
the fleet-wide host settings profile, which is what makes the values editable in the portal after
deployment. The bootstrap seeds that profile once, and the release agent keeps each host converged
to it from then on. See [Linux Host Settings](../README.md#linux-host-settings).

It sets `idle-delay` to `0` so the session never goes idle, sets `lock-enabled` to `false` so
the screen saver never locks, and sets `disable-lock-screen` to `true` so the lock screen is
removed entirely, including the `Super+L` shortcut and the `Lock` entry in the system menu. The
lock list prevents users from changing any of those keys back.

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
`LINUXBROKER_DISABLE_SCREEN_LOCK=false` in the environment if you run `Configure-RHEL7-Host.sh`,
`Configure-RHEL8-Host.sh`, or `Configure-RHEL9-Host.sh` by hand.

Because the values are part of the host settings profile, this posture can also be changed after
deployment from **Host Settings** in the portal, without redeploying anything.

This setting has no effect on the Ubuntu 24.04 image. That target uses the `server` SKU and does
not install a desktop environment, so there is no GNOME screen lock to disable.

### Verifying on a host

```bash
# The system database was built and is referenced by the profile.
ls -l /etc/dconf/db/local
grep system-db /etc/dconf/profile/user

# The effective values, from inside a desktop session.
gsettings get org.gnome.desktop.session idle-delay
gsettings get org.gnome.desktop.screensaver lock-enabled
gsettings get org.gnome.desktop.lockdown disable-lock-screen
```

Expect `uint32 0`, `false`, and `true`. If `gsettings` still reports the distribution defaults,
check that `/etc/dconf/profile/user` contains `system-db:local` and rerun `sudo dconf update`.

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
- RHEL hosts use Generation 2 images so they can run with Trusted Launch.
- The AVD host pool prefers RemoteApp and sets RDP properties that enable Microsoft Entra single sign-on to the Microsoft Entra joined session hosts.
- RHEL hosts have the GNOME screen saver and screen lock disabled unless `linuxHostDisableScreenLock` is `false`. See [Linux Host Screen Lock](#linux-host-screen-lock).
- Key Vault stores `db-password` and `linux-host`.
- The API app receives Key Vault Secrets User access so it can read those secrets at runtime.

## What Happens During `postprovision`

[Post-Provision.ps1](Post-Provision.ps1) performs the runtime completion steps after the Azure resources exist.

It currently runs, in order:

1. [Assign-FunctionAppApiRole.ps1](Assign-FunctionAppApiRole.ps1)
2. [Build-ContainerImages.ps1](Build-ContainerImages.ps1)
3. [Initialize-Database.ps1](Initialize-Database.ps1)
4. [Assign-VmApiRoles.ps1](Assign-VmApiRoles.ps1)
5. [Register-LinuxHostSqlRecords.ps1](Register-LinuxHostSqlRecords.ps1)

That means `postprovision` does all of the following:

- Assigns the `ScheduledTask` app role to the function app managed identity. This runs before the images are built because the function app requests an API token as soon as its image starts, and the managed identity service caches that token for up to 24 hours.
- Builds `frontend:latest`, `api:latest`, and `task:latest` in ACR.
- Restarts the frontend app, API app, and function app after the new images are pushed.
- Applies all SQL scripts from [../sql_queries](../sql_queries) through ADO.NET.
- Makes the SQL bootstrap rerunnable by handling `GO` batches and converting procedure creation to `CREATE OR ALTER`.
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

The migration also rewrites `/etc/sudoers.d/avdadmin`. Older hosts were provisioned with a broad allowlist that included `cat`, `rm`, `chmod`, `chown`, `cp`, `mount`, and `umount`. The current policy grants only `userdel`, `groupadd`, `usermod`, `chpasswd`, `/usr/local/bin/create-user.sh`, `/usr/local/bin/manage-lease.sh`, and `/usr/local/bin/apply-host-settings.sh`; all privileged file work now happens inside those root-owned scripts. The generated policy is validated with `visudo -c` and moved into place only if it passes.

`apply-host-settings.sh` is the only way the broker API can change host configuration. It accepts a JSON settings document on stdin and nothing on argv, rejects unknown keys, and clamps every value to a supported range before writing anything, so a bad value cannot strand the fleet.

The migration additionally installs `dconf` and, where available, `xprintidle`. `xprintidle` backs the optional idle session timeout; if it cannot be installed the migration still succeeds and idle enforcement is simply skipped on that host. Existing hosts keep any settings profile they already have, and hosts with no profile are seeded with the shipped defaults, which match the values that were previously hardcoded.

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
- Key Vault
- SQL server and database
- optional Linux and AVD VMs
- the `linuxbroker.internal` private DNS zone with an A record for each Linux host, unless `domainName` was supplied
- the NFS storage account, its `home` share, and its private endpoint, unless `nfsShare` was supplied or `deployNfsShare` is `false`
- for AVD, the host pool, the desktop and RemoteApp application groups, the workspace, and the **Linux Desktop** application

### Key Vault

Confirm the vault contains:

- `db-password`
- `linux-host`

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

### Released Linux hosts never return to Available

The function app returns released hosts to the pool. If hosts stay **Released** and the API log shows `Access denied: insufficient scope or role permissions or group membership.` at the start of every minute, the function app's API token does not carry the `ScheduledTask` role.

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

Trusted Launch requires Generation 2 images. The RHEL options map to Gen2 SKUs; if you customized the image, choose a Gen2 SKU.

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

### `xpra.service` is disabled on a RHEL 9 host

The system proxy service installed by the upstream xpra 6.5 packages exits during startup on RHEL 9. Its unit binds a QUIC socket, and the `aioquic` module it needs is not packaged for RHEL 9. Left enabled, the failed unit would mark the host as degraded, so the bootstrap disables `xpra.socket` and `xpra.service` and logs a warning. xrdp, which the **Linux Desktop** app uses, is not affected.

### A RHEL session is stuck on a lock screen that will not accept the password

The GNOME lock screen inside an xrdp or xpra session often cannot be unlocked after a reconnect. Confirm the screen lock configuration actually applied on the host using the commands in [Linux Host Screen Lock](#linux-host-screen-lock). The most common cause is a missing `system-db:local` line in `/etc/dconf/profile/user`, which makes GNOME ignore the settings even though the files under `/etc/dconf/db/local.d/` are present.

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