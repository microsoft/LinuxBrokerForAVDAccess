. "$PSScriptRoot\Broker.Rollout.ps1"

function Get-BrokerFunctionDisableSettings {
    param([bool]$Disabled = $true)
    $value = if ($Disabled) { 'true' } else { 'false' }
    return @{
        'AzureWebJobs.ReturnReleasedVMs.Disabled' = $value
        'AzureWebJobs.TestVMConnectivity.Disabled' = $value
        'AzureWebJobs.ScalingVMs.Disabled' = $value
    }
}

function Get-BrokerWorkloadProbeScript {
    param(
        [Parameter(Mandatory)][ValidateSet('LinuxHost', 'ScheduledTask')][string]$Workload,
        [Parameter(Mandatory)][string]$ApiBaseUrl,
        [Parameter(Mandatory)][string]$ApiClientId
    )
    $null = Assert-BrokerHttpsUrl $ApiBaseUrl -Api
    $null = Assert-BrokerGuid $ApiClientId 'API client ID'
    $source = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Test-BrokerWorkloadAccess.py') -Raw).Replace("`r`n", "`n")
    $encodedSource = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($source))
    $arguments = @('broker-workload-probe', '--workload', $Workload, '--api-base-url', $ApiBaseUrl, '--api-client-id', $ApiClientId)
    $encodedArguments = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $arguments -Compress)))
    $python = if ($Workload -eq 'LinuxHost') { '/usr/local/libexec/linuxbroker/python3' } else { 'python3' }
    return @"
$python -I - <<'BROKER_PROBE'
import base64, json, sys
sys.argv = json.loads(base64.b64decode('$encodedArguments').decode('utf-8'))
exec(compile(base64.b64decode('$encodedSource').decode('utf-8'), '<broker-workload-probe>', 'exec'))
BROKER_PROBE
"@
}

function Get-BrokerFunctionActivationState {
    param([string]$EnvironmentName, [string]$ResourceGroupName, [string]$TaskAppName, [switch]$ExistingEnvironment)
    $statePath = (Get-BrokerRolloutReceiptPath $EnvironmentName) -replace '\.json$', '.workloads.json'
    $defaults = Get-BrokerFunctionDisableSettings -Disabled $false
    if (Test-Path -LiteralPath $statePath) {
        $pending = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        if ($pending.resourceGroupName -ne $ResourceGroupName -or $pending.taskAppName -ne $TaskAppName -or
            $pending.settings.Count -ne $defaults.Count) { throw 'The pending workload activation state does not match this deployment.' }
        foreach ($key in $defaults.Keys) {
            if ($pending.settings[$key] -notin @('true', 'false', '1', '0')) { throw 'The pending workload activation state contains an invalid function setting.' }
        }
        return @{ Path = $statePath; Settings = $pending.settings }
    }
    if ($ExistingEnvironment) {
        $settings = @(Invoke-BrokerAz -Arguments @('functionapp', 'config', 'appsettings', 'list',
            '--resource-group', $ResourceGroupName, '--name', $TaskAppName) -Operation 'Preserve intentional scheduled-function disable settings')
        foreach ($setting in $settings) {
            if (-not $defaults.ContainsKey($setting.name)) { continue }
            if ($setting.value -notin @('true', 'false', '1', '0')) { throw "Existing function setting '$($setting.name)' is invalid." }
            $defaults[$setting.name] = $setting.value
        }
    }
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force
    @{
        resourceGroupName = $ResourceGroupName; taskAppName = $TaskAppName; settings = $defaults
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statePath -Encoding utf8
    return @{ Path = $statePath; Settings = $defaults }
}

function Test-BrokerLinuxWorkloadAccess {
    param([array]$Hosts, [string]$ApiBaseUrl, [string]$ApiClientId)
    $script = Get-BrokerWorkloadProbeScript -Workload LinuxHost -ApiBaseUrl $ApiBaseUrl -ApiClientId $ApiClientId
    foreach ($hostRecord in $Hosts) {
        Invoke-BrokerVmScript -ResourceId $hostRecord.ResourceId -CommandId RunShellScript -Script $script `
            -Operation "Verify effective LinuxHost authorization for '$($hostRecord.Name)'"
    }
}

function Test-BrokerTaskWorkloadAccess {
    param([string]$ResourceGroupName, [string]$TaskAppName, [string]$ApiBaseUrl, [string]$ApiClientId)
    $app = Invoke-BrokerAz -Arguments @('functionapp', 'show', '--resource-group', $ResourceGroupName,
        '--name', $TaskAppName) -Operation 'Resolve Function App SCM endpoint for workload readiness'
    $scmHosts = @($app.enabledHostNames | Where-Object { $_ -match '^[a-zA-Z0-9-]+\.scm\.[a-zA-Z0-9.-]+$' })
    if ($scmHosts.Count -ne 1) { throw 'The Function App must expose one trusted SCM endpoint for its managed-identity probe. Scheduled functions remain disabled.' }
    $cloud = Invoke-BrokerAz -Arguments @('cloud', 'show') -Operation 'Resolve ARM audience for SCM authorization'
    $armAudience = $cloud.endpoints.activeDirectoryResourceId
    if (-not $armAudience) { throw 'This cloud did not supply the ARM audience for Entra-authenticated SCM access.' }
    $script = Get-BrokerWorkloadProbeScript -Workload ScheduledTask -ApiBaseUrl $ApiBaseUrl -ApiClientId $ApiClientId
    $body = Write-BrokerPrivateJson -Value @{ command = $script; dir = '/home' }
    try {
        $result = Invoke-BrokerAz -Arguments @('rest', '--method', 'POST', '--url', "https://$($scmHosts[0])/api/command",
            '--resource', $armAudience, '--headers', 'Content-Type=application/json', '--body', "@$body") `
            -Operation 'Verify ScheduledTask access using the Function App platform managed identity'
        if ($result.ExitCode -ne 0 -or $result.Output -notmatch '(?m)^BROKER_WORKLOAD_READY\s*$') {
            throw 'The ScheduledTask allowed-operation probe did not succeed. Keep scheduled functions disabled. Check direct roles, idtyp propagation, managed-identity caches, and SCM access to the app identity endpoint; no response body or credential was logged.'
        }
    }
    finally { Remove-Item -LiteralPath $body -Force }
}
