[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PrincipalId,
    [Parameter(Mandatory)][string]$ApiClientId,
    [Parameter(Mandatory)][ValidateSet('LinuxHost', 'ScheduledTask')][string]$RoleValue,
    [string]$GraphEndpoint
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Broker.Identity.ps1"
$PrincipalId = Assert-BrokerGuid $PrincipalId 'Workload principal ID'
$GraphEndpoint = Get-BrokerGraphEndpoint $GraphEndpoint
$principal = Invoke-BrokerGraph -Method GET -Uri "$GraphEndpoint/v1.0/servicePrincipals/${PrincipalId}?`$select=id,servicePrincipalType,accountEnabled"
if ($principal.id -ne $PrincipalId -or $principal.servicePrincipalType -ne 'ManagedIdentity' -or $principal.accountEnabled -ne $true) {
    throw 'Broker workload roles require an enabled managed-identity service principal, not a user or a group.'
}
$api = Get-BrokerServicePrincipal -GraphEndpoint $GraphEndpoint -ClientId $ApiClientId
$roles = @($api.appRoles | Where-Object {
    $_.value -eq $RoleValue -and $_.isEnabled -and
    $_.allowedMemberTypes.Count -eq 1 -and $_.allowedMemberTypes[0] -eq 'Application'
})
if ($roles.Count -ne 1) { throw "API role '$RoleValue' must be enabled and application-only. Complete identity migration first." }
Ensure-BrokerAppRoleAssignment -GraphEndpoint $GraphEndpoint -PrincipalId $PrincipalId -ResourceId $api.id -RoleId $roles[0].id
Write-Host "Ensured direct '$RoleValue' role for managed identity '$PrincipalId'."
