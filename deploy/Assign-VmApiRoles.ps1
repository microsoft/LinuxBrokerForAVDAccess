[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$ApiClientId,
    [Parameter(Mandatory)][string]$TenantId,
    [string]$VmSubscriptionId,
    [string]$GraphEndpoint
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Broker.Deployment.Common.ps1"
Assert-BrokerTenant $TenantId
$hosts = @(Get-BrokerLinuxInventory -ResourceGroupName $ResourceGroupName -TenantId $TenantId -SubscriptionId $VmSubscriptionId)
foreach ($hostRecord in $hosts) {
    & "$PSScriptRoot\Assign-ServicePrincipalApiRole.ps1" -PrincipalId $hostRecord.ObjectId `
        -ApiClientId $ApiClientId -RoleValue LinuxHost -GraphEndpoint $GraphEndpoint
}
Write-Host "Assigned direct roles to $($hosts.Count) Linux identities. AVD managed identities receive no broker role."
