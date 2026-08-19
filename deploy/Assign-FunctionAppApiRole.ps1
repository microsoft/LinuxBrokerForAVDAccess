[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$TaskAppName,

    [Parameter(Mandatory = $true)]
    [string]$ApiClientId,

    [string]$RoleValue = 'ScheduledTask',

    [Parameter(Mandatory = $false)]
    [string]$GraphEndpoint
)

$ErrorActionPreference = 'Stop'

$identity = az functionapp identity show --name $TaskAppName --resource-group $ResourceGroupName --output json | ConvertFrom-Json
if (-not $identity.principalId) {
    throw "Unable to resolve managed identity for function app '$TaskAppName'."
}

& "$PSScriptRoot/Assign-ServicePrincipalApiRole.ps1" `
    -PrincipalId $identity.principalId `
    -ApiClientId $ApiClientId `
    -RoleValue $RoleValue `
    -GraphEndpoint $GraphEndpoint

Write-Host "Ensured '$RoleValue' application permission for function app '$TaskAppName'."
