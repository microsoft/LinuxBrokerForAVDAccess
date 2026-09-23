. "$PSScriptRoot\Broker.Deployment.Common.ps1"

function Set-BrokerAppSettings {
    param([ValidateSet('webapp', 'functionapp')][string]$Type, [string]$ResourceGroupName, [string]$Name, [hashtable]$Settings)
    $path = Write-BrokerPrivateJson -Value $Settings
    try {
        Invoke-BrokerAz -Arguments @($Type, 'config', 'appsettings', 'set', '--resource-group', $ResourceGroupName,
            '--name', $Name, '--settings', "@$path") -Operation "Configure $Type '$Name'" -NoOutput
    }
    finally { Remove-Item -LiteralPath $path -Force }
}

function Suspend-BrokerApps {
    param([string]$ResourceGroupName, [string]$ApiAppName, [string]$FrontendAppName, [string]$TaskAppName)
    # A legacy API ignores the new checkout flag, so stopping it must precede every other migration mutation.
    Invoke-BrokerAz -Arguments @('webapp', 'stop', '--resource-group', $ResourceGroupName, '--name', $ApiAppName) -Operation 'Stop API for coordinated cutover' -NoOutput
    Invoke-BrokerAz -Arguments @('functionapp', 'stop', '--resource-group', $ResourceGroupName, '--name', $TaskAppName) -Operation 'Stop maintenance worker for cutover' -NoOutput
    Invoke-BrokerAz -Arguments @('webapp', 'stop', '--resource-group', $ResourceGroupName, '--name', $FrontendAppName) -Operation 'Stop portal for cutover' -NoOutput
    Set-BrokerAppSettings -Type webapp -ResourceGroupName $ResourceGroupName -Name $ApiAppName -Settings @{ BROKER_CHECKOUT_ENABLED = 'false' }
}

function Get-BrokerRolloutReceiptPath {
    param([string]$EnvironmentName)
    if ($EnvironmentName -notmatch '^[a-zA-Z0-9-]{2,16}$') { throw 'Invalid environment name for rollout receipt.' }
    return Join-Path $PSScriptRoot ".migration\$EnvironmentName.json"
}

function Wait-BrokerHealth {
    param([string]$Uri, [string]$Name)
    $null = Assert-BrokerHttpsUrl $Uri
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $Uri -TimeoutSec 15 -MaximumRedirection 0
            if ($response.StatusCode -eq 200) { return }
        }
        catch [Net.Http.HttpRequestException] {
            if ($attempt -eq 29) { throw "$Name health did not become ready. Checkouts remain paused." }
        }
        catch [Threading.Tasks.TaskCanceledException] {
            if ($attempt -eq 29) { throw "$Name health timed out. Checkouts remain paused." }
        }
        Start-Sleep -Seconds 10
    }
    throw "$Name did not report HTTP 200 health. Checkouts remain paused."
}
