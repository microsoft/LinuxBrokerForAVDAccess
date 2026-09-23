[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$TaskAppName,
    [Parameter(Mandatory)][string]$ApiClientId,
    [Parameter(Mandatory)][string]$TenantId,
    [string]$GraphEndpoint
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Broker.Deployment.Common.ps1"
Assert-BrokerTenant $TenantId
$identity = Invoke-BrokerAz -Arguments @('functionapp', 'identity', 'show', '--name', $TaskAppName,
    '--resource-group', $ResourceGroupName) -Operation 'Read scheduled-task managed identity'
if ($identity.tenantId -ne $TenantId) { throw 'Scheduled-task managed identity belongs to an unexpected tenant.' }
$principalId = Assert-BrokerGuid $identity.principalId 'Scheduled-task principal ID'
& "$PSScriptRoot\Assign-ServicePrincipalApiRole.ps1" -PrincipalId $principalId `
    -ApiClientId $ApiClientId -RoleValue ScheduledTask -GraphEndpoint $GraphEndpoint
