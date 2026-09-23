[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$TaskAppName,
    [Parameter(Mandatory)][string]$ApiClientId,
    [Parameter(Mandatory)][string]$TenantId,
    [string]$GraphEndpoint
)
$ErrorActionPreference = 'Stop'
& (Join-Path (Split-Path -Parent $PSScriptRoot) 'Assign-FunctionAppApiRole.ps1') @PSBoundParameters
