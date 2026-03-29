[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$RegistryName,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$FrontendAppName,

    [Parameter(Mandatory = $false)]
    [string]$ApiAppName,

    [Parameter(Mandatory = $false)]
    [string]$TaskAppName,

    [Parameter(Mandatory = $false)]
    [string]$EnvironmentName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
    $EnvironmentName = if (-not [string]::IsNullOrWhiteSpace($env:AZURE_ENV_NAME)) {
        $env:AZURE_ENV_NAME
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:AZURE_ENVIRONMENT_NAME)) {
        $env:AZURE_ENVIRONMENT_NAME
    }
    else {
        ''
    }
}

function Get-AzdEnvValue {
    param([Parameter(Mandatory = $true)][string]$Key)

    if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
        return ''
    }

    $value = azd env get-value $Key --environment $EnvironmentName 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ''
    }

    return ($value | Out-String).Trim()
}

if ([string]::IsNullOrWhiteSpace($RegistryName)) {
    $RegistryName = Get-AzdEnvValue -Key 'containerRegistryName'
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $ResourceGroupName = Get-AzdEnvValue -Key 'resourceGroupName'
}

if ([string]::IsNullOrWhiteSpace($FrontendAppName)) {
    $FrontendAppName = Get-AzdEnvValue -Key 'frontendAppName'
}

if ([string]::IsNullOrWhiteSpace($ApiAppName)) {
    $ApiAppName = Get-AzdEnvValue -Key 'apiAppName'
}

if ([string]::IsNullOrWhiteSpace($TaskAppName)) {
    $TaskAppName = Get-AzdEnvValue -Key 'taskAppName'
}

if ([string]::IsNullOrWhiteSpace($RegistryName) -or [string]::IsNullOrWhiteSpace($ResourceGroupName) -or [string]::IsNullOrWhiteSpace($FrontendAppName) -or [string]::IsNullOrWhiteSpace($ApiAppName) -or [string]::IsNullOrWhiteSpace($TaskAppName)) {
    throw 'Build inputs could not be fully resolved from parameters or azd environment values.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot

$images = @(
    @{ Name = 'frontend'; Dockerfile = 'front_end/Dockerfile' },
    @{ Name = 'api'; Dockerfile = 'api/Dockerfile' },
    @{ Name = 'task'; Dockerfile = 'task/Dockerfile' }
)

Push-Location $repoRoot
try {
    foreach ($image in $images) {
        Write-Host "Building $($image.Name):latest in ACR '$RegistryName'"
        az acr build --registry $RegistryName --image "$($image.Name):latest" --file $image.Dockerfile --no-logs --output none .
        if ($LASTEXITCODE -ne 0) {
            throw "ACR build failed for $($image.Name)."
        }
    }

    az webapp restart --name $FrontendAppName --resource-group $ResourceGroupName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to restart frontend app '$FrontendAppName'."
    }

    az webapp restart --name $ApiAppName --resource-group $ResourceGroupName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to restart API app '$ApiAppName'."
    }

    az functionapp restart --name $TaskAppName --resource-group $ResourceGroupName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to restart task app '$TaskAppName'."
    }
}
finally {
    Pop-Location
}
