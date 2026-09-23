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
    [string]$EnvironmentName,

    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$')]
    [string]$ImageTag = 'latest',

    [switch]$SkipRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Broker.Deployment.Common.ps1"
. "$PSScriptRoot\Broker.BuildContext.ps1"

function Invoke-AzCommandWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Command,

        [Parameter(Mandatory = $true)]
        [string]$Description,

        [Parameter(Mandatory = $false)]
        [int]$MaxAttempts = 4,

        [Parameter(Mandatory = $false)]
        [int]$InitialDelaySeconds = 5
    )

    $lastError = ''

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $commandOutput = & $Command 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            return
        }

        $lastError = $commandOutput.Trim()
        if ($attempt -ge $MaxAttempts) {
            break
        }

        $delaySeconds = [Math]::Min($InitialDelaySeconds * [Math]::Pow(2, $attempt - 1), 30)
        Write-Warning "$Description failed on attempt $attempt of $MaxAttempts. Retrying in $([int]$delaySeconds) seconds."
        Start-Sleep -Seconds ([int]$delaySeconds)
    }

    if ([string]::IsNullOrWhiteSpace($lastError)) {
        throw "Failed to $Description after $MaxAttempts attempts."
    }

    throw "Failed to $Description after $MaxAttempts attempts. Response details were suppressed."
}

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

    return [string](Get-BrokerEnvironment $EnvironmentName)[$Key]
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

$contextPath = Join-Path $PSScriptRoot ('.artifacts\container-context-' + [guid]::NewGuid().ToString('N'))
try {
    New-BrokerContainerBuildContext -SourceRoot $repoRoot -Destination $contextPath
    foreach ($image in $images) {
        Write-Host "Building $($image.Name):$ImageTag in ACR '$RegistryName'"
        Invoke-BrokerAz -Arguments @('acr', 'build', '--registry', $RegistryName, '--image', "$($image.Name):$ImageTag",
            '--file', $image.Dockerfile, '--no-logs', $contextPath) -Operation "Build $($image.Name) container" -NoOutput
    }

    $registry = Invoke-BrokerAz -Arguments @('acr', 'show', '--name', $RegistryName) -Operation 'Read registry endpoint'
    foreach ($app in @(
            @{ Type = 'webapp'; Name = $FrontendAppName; Image = 'frontend' },
            @{ Type = 'webapp'; Name = $ApiAppName; Image = 'api' },
            @{ Type = 'functionapp'; Name = $TaskAppName; Image = 'task' })) {
        $imageArgument = if ($app.Type -eq 'webapp') { '--container-image-name' } else { '--image' }
        $registryArgument = if ($app.Type -eq 'webapp') { '--container-registry-url' } else { '--registry-server' }
        Invoke-BrokerAz -Arguments @($app.Type, 'config', 'container', 'set', '--resource-group', $ResourceGroupName,
            '--name', $app.Name, $imageArgument, "$($registry.loginServer)/$($app.Image):$ImageTag",
            $registryArgument, "https://$($registry.loginServer)") -Operation "Pin $($app.Image) container" -NoOutput
    }
    if ($SkipRestart) { return }

    Invoke-AzCommandWithRetry -Description "restart frontend app '$FrontendAppName'" -Command {
        az webapp restart --name $FrontendAppName --resource-group $ResourceGroupName --only-show-errors --output none
    }

    Invoke-AzCommandWithRetry -Description "restart API app '$ApiAppName'" -Command {
        az webapp restart --name $ApiAppName --resource-group $ResourceGroupName --only-show-errors --output none
    }

    Invoke-AzCommandWithRetry -Description "restart task app '$TaskAppName'" -Command {
        az functionapp restart --name $TaskAppName --resource-group $ResourceGroupName --only-show-errors --output none
    }
}
finally {
    if (Test-Path -LiteralPath $contextPath) { Remove-Item -LiteralPath $contextPath -Recurse -Force }
}
