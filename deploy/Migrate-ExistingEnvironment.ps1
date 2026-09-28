[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$TaskAppName,

    [Parameter(Mandatory = $false)]
    [string]$ApiClientId,

    [Parameter(Mandatory = $false)]
    [string]$ApiBaseUrl,

    [Parameter(Mandatory = $false)]
    [string]$SqlServerFqdn,

    [Parameter(Mandatory = $false)]
    [string]$DatabaseName,

    [Parameter(Mandatory = $false)]
    [string]$SqlAdminLogin,

    [Parameter(Mandatory = $false)]
    [string]$SqlAdminPassword,

    [Parameter(Mandatory = $false)]
    [string]$ScriptsPath,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$EnvironmentName,

    [Parameter(Mandatory = $false)]
    [string]$AvdHostGroupId,

    [Parameter(Mandatory = $false)]
    [string]$LinuxHostGroupId,

    [Parameter(Mandatory = $false)]
    [string]$ScriptSourceRoot = 'https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/refs/heads/main',

    [Parameter(Mandatory = $false)]
    [string[]]$LinuxHostNames,

    [Parameter(Mandatory = $false)]
    [string[]]$AvdHostNames,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 300)]
    [int]$WatcherDebounceSeconds = 10,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 60)]
    [int]$WatcherSettleSeconds = 2,

    [Parameter(Mandatory = $false)]
    [switch]$SkipPostProvision,

    [Parameter(Mandatory = $false)]
    [switch]$SkipLinuxHostReleaseAgentMigration,

    [Parameter(Mandatory = $false)]
    [switch]$SkipAvdHostScriptUpdate
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

if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $ResourceGroupName = Get-AzdEnvValue -Key 'resourceGroupName'
}

if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $SubscriptionId = Get-AzdEnvValue -Key 'AZURE_SUBSCRIPTION_ID'
}

if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $SubscriptionId = $env:AZURE_SUBSCRIPTION_ID
}

if ([string]::IsNullOrWhiteSpace($ApiClientId)) {
    $ApiClientId = Get-AzdEnvValue -Key 'apiClientId'
}

if ([string]::IsNullOrWhiteSpace($ApiBaseUrl)) {
    $ApiBaseUrl = Get-AzdEnvValue -Key 'apiUrl'
}

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    az account set --subscription $SubscriptionId | Out-Null
}

if (-not $SkipPostProvision) {
    Write-Host 'Running post-provision migration steps for the existing environment.'

    & "$PSScriptRoot/Post-Provision.ps1" `
        -ResourceGroupName $ResourceGroupName `
        -TaskAppName $TaskAppName `
        -ApiClientId $ApiClientId `
        -SqlServerFqdn $SqlServerFqdn `
        -DatabaseName $DatabaseName `
        -SqlAdminLogin $SqlAdminLogin `
        -SqlAdminPassword $SqlAdminPassword `
        -ScriptsPath $ScriptsPath `
        -SubscriptionId $SubscriptionId `
        -EnvironmentName $EnvironmentName `
        -AvdHostGroupId $AvdHostGroupId `
        -LinuxHostGroupId $LinuxHostGroupId
}

if ((-not $SkipLinuxHostReleaseAgentMigration -or -not $SkipAvdHostScriptUpdate) -and
    ([string]::IsNullOrWhiteSpace($ResourceGroupName) -or [string]::IsNullOrWhiteSpace($ApiBaseUrl) -or [string]::IsNullOrWhiteSpace($ApiClientId))) {
    throw 'Updating the Linux hosts and the AVD session hosts requires ResourceGroupName, ApiBaseUrl, and ApiClientId.'
}

# Neither host update stops the other, so a Linux host that fails does not leave the AVD session
# hosts on a Connect-LinuxBroker.ps1 that cannot wait for a host to start. Both scripts name the
# hosts to retry, and the failures end the migration together.
$failedSteps = New-Object System.Collections.Generic.List[string]

if (-not $SkipLinuxHostReleaseAgentMigration) {
    Write-Host 'Migrating existing Linux hosts to the current release-agent layout.'

    try {
        & "$PSScriptRoot/Migrate-LinuxHostReleaseAgent.ps1" `
            -ResourceGroupName $ResourceGroupName `
            -ApiBaseUrl $ApiBaseUrl `
            -ApiClientId $ApiClientId `
            -SubscriptionId $SubscriptionId `
            -EnvironmentName $EnvironmentName `
            -ScriptSourceRoot $ScriptSourceRoot `
            -LinuxHostNames $LinuxHostNames `
            -WatcherDebounceSeconds $WatcherDebounceSeconds `
            -WatcherSettleSeconds $WatcherSettleSeconds
    }
    catch {
        Write-Warning $_.Exception.Message
        $failedSteps.Add('the Linux host migration')
    }
}

if (-not $SkipAvdHostScriptUpdate) {
    Write-Host 'Updating Connect-LinuxBroker.ps1 on the existing AVD session hosts.'

    try {
        & "$PSScriptRoot/Update-AvdHostBrokerScript.ps1" `
            -ResourceGroupName $ResourceGroupName `
            -ApiBaseUrl $ApiBaseUrl `
            -ApiClientId $ApiClientId `
            -SubscriptionId $SubscriptionId `
            -EnvironmentName $EnvironmentName `
            -ScriptSourceRoot $ScriptSourceRoot `
            -AvdHostNames $AvdHostNames
    }
    catch {
        Write-Warning $_.Exception.Message
        $failedSteps.Add('the AVD session host update')
    }
}

if ($failedSteps.Count -gt 0) {
    throw "Existing environment migration failed in $($failedSteps -join ' and '). The warnings above name the hosts to retry."
}

Write-Host 'Existing environment migration completed.'