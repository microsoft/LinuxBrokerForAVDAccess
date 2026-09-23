[CmdletBinding()]
param([Parameter(Mandatory)][string]$EnvironmentName)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Broker.Identity.ps1"
$values = Get-BrokerEnvironment $EnvironmentName
$tenantId = Assert-BrokerGuid $values['tenantId'] 'Tenant ID'
$apiClientId = Assert-BrokerGuid $values['apiClientId'] 'API client ID'
Assert-BrokerTenant $tenantId
$graph = Get-BrokerGraphEndpoint $values['graphEndpoint']
$api = Get-BrokerApplication -GraphEndpoint $graph -DisplayName 'existing-api' -ClientId $apiClientId
$servicePrincipal = Get-BrokerServicePrincipal -GraphEndpoint $graph -ClientId $apiClientId
$roles = @{}
foreach ($name in @('LinuxHost', 'ScheduledTask')) {
    $matches = @($servicePrincipal.appRoles | Where-Object {
        $_.value -eq $name -and $_.isEnabled -and $_.allowedMemberTypes -contains 'Application'
    })
    if ($matches.Count -ne 1) { throw "The existing API must already expose enabled '$name' application permission before it can be staged." }
    $roles[$name] = $matches[0].id
}
$resourceGroup = [string]$values['resourceGroupName']
$vmGroup = if ($values['vmHostResourceGroup']) { $values['vmHostResourceGroup'] } else { $resourceGroup }
$hosts = @(Get-BrokerLinuxInventory -ResourceGroupName $vmGroup -TenantId $tenantId -SubscriptionId $values['vmSubscriptionId'])
$taskIdentity = Invoke-BrokerAz -Arguments @('functionapp', 'identity', 'show', '--resource-group',
    $resourceGroup, '--name', $values['taskAppName']) -Operation 'Read the existing scheduled workload identity'
if ($taskIdentity.tenantId -ne $tenantId) { throw 'The scheduled workload is not in the selected tenant.' }
$taskId = Assert-BrokerGuid $taskIdentity.principalId 'Scheduled workload principal'
$null = Invoke-BrokerGraph -Method PATCH -Uri "$graph/v1.0/applications/$($api.id)" -Body @{
    optionalClaims = Get-BrokerWorkloadOptionalClaims -Application $api
}
Wait-BrokerWorkloadOptionalClaim -GraphEndpoint $graph -ApplicationObjectId $api.id
foreach ($hostRecord in $hosts) {
    Ensure-BrokerAppRoleAssignment -GraphEndpoint $graph -PrincipalId $hostRecord.ObjectId `
        -ResourceId $servicePrincipal.id -RoleId $roles.LinuxHost
}
Ensure-BrokerAppRoleAssignment -GraphEndpoint $graph -PrincipalId $taskId `
    -ResourceId $servicePrincipal.id -RoleId $roles.ScheduledTask
Write-Host 'Direct workload roles and the idtyp claim are staged without minting API tokens, changing user assignments, or activating workloads.'
Write-Host 'This is NOT readiness evidence. Allow managed-identity permission caches to refresh; the coordinated migration must still verify allowed API operations with the actual workload identities.'
