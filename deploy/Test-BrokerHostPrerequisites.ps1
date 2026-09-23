[CmdletBinding()]
param([Parameter(Mandatory)][string]$EnvironmentName, [switch]$AllowDrainedLegacyEnrollment, [switch]$RequireReady)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Broker.LinuxMigration.ps1"
$values = Get-BrokerEnvironment $EnvironmentName
$tenantId = Assert-BrokerGuid $values['tenantId'] 'Tenant ID'
Assert-BrokerTenant $tenantId
$group = if ($values['vmHostResourceGroup']) { $values['vmHostResourceGroup'] } else { $values['resourceGroupName'] }
$hosts = @(Get-BrokerLinuxInventory -ResourceGroupName $group -TenantId $tenantId -SubscriptionId $values['vmSubscriptionId'])
Test-BrokerHostPrerequisites -Hosts $hosts -AllowDrainedLegacyEnrollment:$AllowDrainedLegacyEnrollment -RequireReady:$RequireReady
Write-Host "Read-only guest prerequisite checks passed on $($hosts.Count) registered ARM hosts. No XRDP service was frozen, thawed, started, or stopped."
if ($AllowDrainedLegacyEnrollment) {
    Write-Host 'Legacy controller availability is not enrolled-gate readiness. The explicit drained enrollment and core gate-status verification are still required before activation.'
}
