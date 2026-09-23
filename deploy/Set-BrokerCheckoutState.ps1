[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentName,
    [Parameter(Mandatory)][ValidateSet('Paused', 'Enabled')][string]$State,
    [switch]$SecuredRolloutValidated
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Broker.Rollout.ps1"
. "$PSScriptRoot\Broker.Launcher.ps1"
. "$PSScriptRoot\Broker.LinuxMigration.ps1"
. "$PSScriptRoot\Broker.WorkloadReadiness.ps1"
$values = Get-BrokerEnvironment $EnvironmentName
$requiredKeys = @('resourceGroupName', 'apiAppName', 'taskAppName', 'tenantId')
if ($State -eq 'Enabled') {
    $requiredKeys += @('frontendAppName', 'apiClientId', 'frontendClientId', 'brokerLauncherClientId', 'azureAuthorityHost', 'sqlRuntimeLogin', 'apiUrl')
}
foreach ($key in $requiredKeys) {
    if (-not $values[$key]) { throw "Missing required deployment value '$key'." }
}
Assert-BrokerTenant $values['tenantId']
$receiptPath = Get-BrokerRolloutReceiptPath $EnvironmentName
$receipt = if (Test-Path -LiteralPath $receiptPath) { Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable } else { $null }
$apiConfiguration = Invoke-BrokerAz -Arguments @('webapp', 'config', 'show', '--resource-group',
    $values['resourceGroupName'], '--name', $values['apiAppName']) -Operation 'Verify secured API image'
$verifiedApiImage = $receipt -and $receipt.contractVersion -eq 1 -and
    $apiConfiguration.linuxFxVersion -match ("/api:" + [regex]::Escape($receipt.imageTag) + '$')
if ($State -eq 'Paused' -and -not $verifiedApiImage) {
    Invoke-BrokerAz -Arguments @('webapp', 'stop', '--resource-group', $values['resourceGroupName'],
        '--name', $values['apiAppName']) -Operation 'Stop unverified/legacy API that may ignore checkout pause' -NoOutput
    Invoke-BrokerAz -Arguments @('functionapp', 'stop', '--resource-group', $values['resourceGroupName'],
        '--name', $values['taskAppName']) -Operation 'Stop unverified maintenance worker' -NoOutput
}
if ($State -eq 'Enabled') {
    if (-not $SecuredRolloutValidated) { throw 'Explicit -SecuredRolloutValidated is required after the controlled authorization/SSO/RDP/NFS pilot.' }
    if (-not $verifiedApiImage) { throw 'No completed secured rollout matches the configured API image. Run the full migration; never enable a legacy API.' }
    if ($receipt['workloadsReady'] -ne $true) { throw 'The rollout has no successful actual-workload authorization probes. Keep checkout paused and complete workload activation.' }
    if ($receipt['runtimeDatabaseVerified'] -ne $true -or $receipt['sqlRuntimeLogin'] -ne $values['sqlRuntimeLogin']) {
        throw 'The rollout does not verify a distinct BrokerApiRuntime database user. Keep checkout paused.'
    }
    if ($receipt['trustedInventoryBindingVersion'] -ne 46) {
        throw 'The rollout predates verified endpoint enrollment. Apply through 046 and reimport/re-enroll every intended ARM host before resuming checkout.'
    }
    $taskIdentity = Invoke-BrokerAz -Arguments @('functionapp', 'identity', 'show', '--resource-group',
        $values['resourceGroupName'], '--name', $values['taskAppName']) -Operation 'Verify the probed scheduled workload identity'
    if ($taskIdentity.principalId -ne $receipt['taskPrincipalId'] -or $taskIdentity.tenantId -ne $values['tenantId']) {
        throw 'The scheduled workload identity changed after its successful authorization probe.'
    }
    foreach ($key in @('resourceGroupName', 'tenantId', 'apiClientId', 'frontendClientId', 'brokerLauncherClientId')) {
        if ($receipt[$key] -ne $values[$key]) { throw "Rollout receipt does not match current '$key'." }
    }
    $vmGroup = if ($values['vmHostResourceGroup']) { $values['vmHostResourceGroup'] } else { $values['resourceGroupName'] }
    $linuxHosts = @(Get-BrokerLinuxInventory -ResourceGroupName $vmGroup -TenantId $values['tenantId'] -SubscriptionId $values['vmSubscriptionId'])
    $linuxIds = @($linuxHosts | ForEach-Object { $_.ResourceId } | Sort-Object)
    $linuxBindings = @($linuxHosts | ForEach-Object { "$($_.ResourceId)|$($_.ObjectId)" } | Sort-Object)
    $avdIds = @(Get-BrokerAvdInventory -ResourceGroupName $values['resourceGroupName'] -HostPoolName $values['avdHostPoolName'] | ForEach-Object { $_.ResourceId } | Sort-Object)
    if (($linuxIds -join '|') -ne (@($receipt.linuxHostIds | Sort-Object) -join '|') -or
        ($linuxBindings -join '|') -ne (@($receipt.linuxHostBindings | Sort-Object) -join '|') -or
        ($avdIds -join '|') -ne (@($receipt.avdHostIds | Sort-Object) -join '|')) {
        throw 'The host inventory changed after the secured rollout. Enroll and upgrade the new/replaced hosts before enabling checkout.'
    }
    foreach ($app in @(
            @{ Type = 'webapp'; Name = $values['frontendAppName']; Image = 'frontend' },
            @{ Type = 'functionapp'; Name = $values['taskAppName']; Image = 'task' })) {
        $configuration = Invoke-BrokerAz -Arguments @($app.Type, 'config', 'show', '--resource-group',
            $values['resourceGroupName'], '--name', $app.Name) -Operation "Verify secured $($app.Image) image"
        if ($configuration.linuxFxVersion -notmatch ("/$($app.Image):" + [regex]::Escape($receipt.imageTag) + '$')) {
            throw "The $($app.Image) image does not match the completed secured rollout."
        }
    }
    $settings = @(Invoke-BrokerAz -Arguments @('webapp', 'config', 'appsettings', 'list', '--resource-group',
        $values['resourceGroupName'], '--name', $values['apiAppName']) -Operation 'Verify authoritative API settings')
    $actual = @{}
    foreach ($setting in $settings) { $actual[$setting.name] = $setting.value }
    foreach ($entry in @{
            CLIENT_ID = $values['apiClientId']; PORTAL_CLIENT_ID = $values['frontendClientId']
            BROKER_LAUNCHER_CLIENT_ID = $values['brokerLauncherClientId']; TENANT_ID = $values['tenantId']
            AZURE_AUTHORITY_HOST = $values['azureAuthorityHost']
            DB_USERNAME = $values['sqlRuntimeLogin']; DB_PASSWORD_NAME = 'db-password'
        }.GetEnumerator()) {
        if ($actual[$entry.Key] -ne $entry.Value) { throw "API setting '$($entry.Key)' does not match the secured rollout." }
    }
    Test-BrokerHostPrerequisites -Hosts $linuxHosts -RequireReady
    Test-BrokerLinuxWorkloadAccess -Hosts $linuxHosts -ApiBaseUrl $values['apiUrl'] -ApiClientId $values['apiClientId']
    Test-BrokerTaskWorkloadAccess -ResourceGroupName $values['resourceGroupName'] -TaskAppName $values['taskAppName'] `
        -ApiBaseUrl $values['apiUrl'] -ApiClientId $values['apiClientId']
}
$enabled = if ($State -eq 'Enabled') { 'true' } else { 'false' }
Set-BrokerAppSettings -Type webapp -ResourceGroupName $values['resourceGroupName'] -Name $values['apiAppName'] -Settings @{ BROKER_CHECKOUT_ENABLED = $enabled }
Set-BrokerEnvironmentValue -EnvironmentName $EnvironmentName -Key brokerCheckoutEnabled -Value $enabled
Set-BrokerEnvironmentValue -EnvironmentName $EnvironmentName -Key BROKER_CHECKOUT_ENABLED -Value $enabled
Write-Host "Checkout state: $State. User, workload, host-binding, and lease authorization remain mandatory."
