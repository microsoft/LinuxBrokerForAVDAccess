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

1. Bootstrap the azd environment, Entra applications, host groups, and SSH key material.
2. Provision Azure infrastructure with Bicep.
3. Build the container images in Azure Container Registry, restart the apps, initialize SQL, assign the function app role, sync VM group membership, and register Linux hosts in SQL.

Two details matter here:

- The supported path is `azd up` from the `deploy/` directory, not a separate manual mix of Bicep plus ad hoc scripts.
- Container images are built remotely with `az acr build`, so local Docker is not required.

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

You also need a tenant admin available to grant admin consent after the app registrations are created.

## What The Deployment Creates

At a high level, the deployment provisions and configures the following:

- Azure Container Registry for the `frontend`, `api`, and `task` images.
- App Service apps for the frontend and API, plus a Function App for scheduled work.
- Azure SQL Database and firewall rules.
- Azure Key Vault.
- App Service plan, storage account, Application Insights, Log Analytics, and networking.
- Optional Linux hosts and optional AVD hosts, depending on azd environment settings.
- Two Entra app registrations: frontend and API.
- Two Entra security groups for VM authorization: AVD hosts and Linux hosts.

The deployment model now follows these runtime rules:

- The function app gets the `ScheduledTask` API app role directly.
- VM managed identities do not get direct API role assignments.
- Instead, VM managed identities are added to Entra security groups, and those groups hold the `AvdHost` and `LinuxHost` API app roles.
- Key Vault stores only two deployment secrets: `db-password` and `linux-host`.
- Frontend and API auth secrets are stored in app settings, not in Key Vault.
- Linux hosts are registered into SQL during `postprovision`. AVD hosts are not.

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
- `linuxHostOsVersion`: Linux image SKU.
- `azureCloudName`: `AzurePublic`, `AzureUSGovernment`, or `AzureCustom`. See [Choosing The Target Azure Cloud](#choosing-the-target-azure-cloud).
- `scriptSourceRoot`: root URL the Linux host bootstrap scripts are downloaded from.
- `domainName`: domain suffix used by the broker when connecting to Linux hosts.
- `nfsShare`: NFS share path if required by your Linux host configuration.
- `vmHostResourceGroup`: override if managed VMs live in a different resource group.

### Values that are usually auto-generated

- `SQL_ADMIN_PASSWORD`
- `HOST_ADMIN_PASSWORD`
- `FLASK_SESSION_SECRET`
- frontend and API client secrets
- frontend and API client IDs if the app registrations do not already exist
- AVD and Linux host group IDs

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

Linux hosts download their agent scripts from `scriptSourceRoot`, which defaults to this repository on GitHub. Government and air-gapped environments usually cannot reach `raw.githubusercontent.com`, so point it at a reachable mirror such as a storage account or internal Git host:

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
- Key Vault stores `db-password` and `linux-host`.
- The API app receives Key Vault Secrets User access so it can read those secrets at runtime.

## What Happens During `postprovision`

[Post-Provision.ps1](Post-Provision.ps1) performs the runtime completion steps after the Azure resources exist.

It currently runs, in order:

1. [Build-ContainerImages.ps1](Build-ContainerImages.ps1)
2. [Initialize-Database.ps1](Initialize-Database.ps1)
3. [Assign-FunctionAppApiRole.ps1](Assign-FunctionAppApiRole.ps1)
4. [Assign-VmApiRoles.ps1](Assign-VmApiRoles.ps1)
5. [Register-LinuxHostSqlRecords.ps1](Register-LinuxHostSqlRecords.ps1)

That means `postprovision` does all of the following:

- Builds `frontend:latest`, `api:latest`, and `task:latest` in ACR.
- Restarts the frontend app, API app, and function app after the new images are pushed.
- Applies all SQL scripts from [../sql_queries](../sql_queries) through ADO.NET.
- Makes the SQL bootstrap rerunnable by handling `GO` batches and converting procedure creation to `CREATE OR ALTER`.
- Assigns the `ScheduledTask` app role to the function app managed identity.
- Adds AVD and Linux VM managed identities to the corresponding Entra groups.
- Registers Linux hosts into `dbo.VirtualMachines` through `dbo.RegisterLinuxHostVm`.

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

The migration also rewrites `/etc/sudoers.d/avdadmin`. Older hosts were provisioned with a broad allowlist that included `cat`, `rm`, `chmod`, `chown`, `cp`, `mount`, and `umount`. The current policy grants only `userdel`, `groupadd`, `usermod`, `chpasswd`, `/usr/local/bin/create-user.sh`, and `/usr/local/bin/manage-lease.sh`; all privileged file work now happens inside those two root-owned scripts. The generated policy is validated with `visudo -c` and moved into place only if it passes.

## Manual Steps After `azd up`

The deployment does not grant tenant-wide admin consent automatically.

After the preprovision hook has created the app registrations, a tenant admin still needs to grant consent for:

- Frontend delegated permissions such as `User.Read`, `profile`, `email`, `offline_access`, `openid`, and the API delegated scope.
- API application permissions to Microsoft Graph used for group and directory reads.

Without admin consent, deployment can still complete, but sign-in and Graph-backed authorization checks will not work correctly.

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
- `dbo.RegisterLinuxHostVm`

For more database detail, see [../sql_queries/README.md](../sql_queries/README.md).

### Entra authorization model

Confirm that:

- the function app managed identity has the `ScheduledTask` API app role
- the AVD host group has the `AvdHost` API app role
- the Linux host group has the `LinuxHost` API app role
- VM managed identities are members of the correct Entra groups

### Application health

Confirm that:

- the frontend and API apps restarted after the ACR builds
- the function app restarted after the image build
- frontend sign-in works after admin consent is granted
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

## Related Files

- [azure.yaml](azure.yaml)
- [Initialize-DeploymentEnvironment.ps1](Initialize-DeploymentEnvironment.ps1)
- [Post-Provision.ps1](Post-Provision.ps1)
- [Build-ContainerImages.ps1](Build-ContainerImages.ps1)
- [Initialize-Database.ps1](Initialize-Database.ps1)
- [Register-LinuxHostSqlRecords.ps1](Register-LinuxHostSqlRecords.ps1)
- [bicep/main.bicep](bicep/main.bicep)
- [../sql_queries/README.md](../sql_queries/README.md)