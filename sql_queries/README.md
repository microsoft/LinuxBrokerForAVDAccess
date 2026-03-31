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

The table scripts above are written to be rerunnable.

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

## Current Runtime Expectations

The current code and deployment flow depend on the following SQL objects being present:

- `dbo.VmScalingRules`
- `dbo.VmScalingActivityLog`
- `dbo.VirtualMachines`
- `dbo.VmUsers`
- all of the stored procedures above
- especially `dbo.CheckoutVm`, `dbo.ReleaseVm`, `dbo.UpdateVmAttributes`, and `dbo.RegisterLinuxHostVm`

Two current behaviors are worth calling out:

- `dbo.VmUsers` is required by the API path that creates and tracks Linux-side user IDs.
- `dbo.RegisterLinuxHostVm` is the procedure used by post-provision automation to register Linux hosts automatically.

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

## Verification

After bootstrap, verify both tables and procedures.

### Check tables

```sql
SELECT name
FROM sys.tables
WHERE name IN ('VmScalingRules', 'VmScalingActivityLog', 'VirtualMachines', 'VmUsers')
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
    'RegisterLinuxHostVm'
)
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