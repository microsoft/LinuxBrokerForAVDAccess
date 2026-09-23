[CmdletBinding()]
param(
    [string]$EnvironmentName,
    [string]$ResourceGroupName,
    [string]$TaskAppName,
    [string]$ApiClientId,
    [string]$ApiBaseUrl,
    [string]$SqlServerFqdn,
    [string]$DatabaseName,
    [string]$SqlAdminLogin,
    [string]$SqlAdminPassword,
    [string]$ScriptsPath,
    [string]$SubscriptionId,
    [string]$AccessConfigPath,
    [string]$UserMappingPath,
    [string]$LauncherPackageUri,
    [string]$LauncherPackageSha256,
    [string]$LauncherPackagePath,
    [string]$LauncherVersion,
    [switch]$ExistingEnvironment,
    [switch]$EnrollDrainedLegacyHosts,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Broker.Rollout.ps1"
. "$PSScriptRoot\Broker.Identity.ps1"
. "$PSScriptRoot\Broker.UserMapping.ps1"
. "$PSScriptRoot\Broker.Launcher.ps1"
. "$PSScriptRoot\Broker.WorkloadReadiness.ps1"
. "$PSScriptRoot\Broker.DatabaseRuntime.ps1"

if (-not $EnvironmentName) { $EnvironmentName = $env:AZURE_ENV_NAME }
if (-not $EnvironmentName) { $EnvironmentName = $env:AZURE_ENVIRONMENT_NAME }
if (-not $EnvironmentName) { throw 'EnvironmentName is required.' }
$values = Get-BrokerEnvironment $EnvironmentName
function Resolve-DeploymentValue {
    param([string]$Value, [string]$Key, [string]$Alias)
    if ($Value) { return $Value }
    if ($values[$Key]) { return [string]$values[$Key] }
    if ($Alias -and $values[$Alias]) { return [string]$values[$Alias] }
    return ''
}
$ResourceGroupName = Resolve-DeploymentValue $ResourceGroupName 'resourceGroupName'
$TaskAppName = Resolve-DeploymentValue $TaskAppName 'taskAppName'
$ApiClientId = Resolve-DeploymentValue $ApiClientId 'apiClientId' 'API_CLIENT_ID'
$ApiBaseUrl = Resolve-DeploymentValue $ApiBaseUrl 'apiUrl'
$SubscriptionId = Resolve-DeploymentValue $SubscriptionId 'AZURE_SUBSCRIPTION_ID'
$DatabaseName = Resolve-DeploymentValue $DatabaseName 'sqlDatabaseName' 'SQL_DATABASE_NAME'
$SqlAdminLogin = Resolve-DeploymentValue $SqlAdminLogin 'sqlAdminLogin' 'SQL_ADMIN_LOGIN'
$SqlAdminPassword = Resolve-DeploymentValue $SqlAdminPassword 'sqlAdminPassword' 'SQL_ADMIN_PASSWORD'
$AccessConfigPath = Resolve-DeploymentValue $AccessConfigPath 'brokerAccessConfigPath'
$UserMappingPath = Resolve-DeploymentValue $UserMappingPath 'brokerUserMappingPath'
$LauncherVersion = Resolve-DeploymentValue $LauncherVersion 'launcherVersion'
if (-not $LauncherVersion) { $LauncherVersion = '1.0.0' }
if ($LauncherVersion -notmatch '^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})$') {
    throw 'launcherVersion must match the native publisher: numeric major.minor.patch, each part at most four digits.'
}
$LauncherPackageUri = Resolve-DeploymentValue $LauncherPackageUri 'launcherPackageUri'
$LauncherPackageSha256 = Resolve-DeploymentValue $LauncherPackageSha256 'launcherPackageSha256'
$LauncherPackagePath = Resolve-DeploymentValue $LauncherPackagePath 'launcherPackagePath'
$apiName = [string]$values['apiAppName']
$frontendName = [string]$values['frontendAppName']
$tenantId = Assert-BrokerGuid $values['tenantId'] 'tenantId'
if (-not $ScriptsPath) { $ScriptsPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'sql_queries' }
foreach ($value in @($ResourceGroupName, $TaskAppName, $apiName, $frontendName, $ApiClientId, $ApiBaseUrl,
        $DatabaseName, $SqlAdminLogin, $SqlAdminPassword, $AccessConfigPath)) {
    if (-not $value) { throw 'Post-provision inputs are incomplete. Required app, API, SQL, and reviewed access configuration must be resolved before migration.' }
}
if ($ExistingEnvironment -and -not $UserMappingPath) {
    throw 'Existing deployments require an explicitly reviewed brokerUserMappingPath, even if its users array is empty. Profiles are never claimed by a supplied name.'
}
if ($SubscriptionId) {
    $current = Invoke-BrokerAz -Arguments @('account', 'show') -Operation 'Check deployment subscription'
    if ($current.id -ne $SubscriptionId) { throw 'Select the configured Azure subscription before running this script.' }
}
Assert-BrokerTenant $tenantId
$graph = Get-BrokerGraphEndpoint $values['graphEndpoint']
$legacyGroups = @($values['avdHostGroupId'], $values['linuxHostGroupId'], $values['AVD_HOST_GROUP_ID'], $values['LINUX_HOST_GROUP_ID'] | Where-Object { $_ })
$access = Read-BrokerAccessConfiguration -Path $AccessConfigPath -TenantId $tenantId -LegacyMachineGroupIds $legacyGroups
Test-BrokerAccessPrincipals -Configuration $access -GraphEndpoint $graph
$mapping = $null
if ($UserMappingPath) {
    $UserMappingPath = (Resolve-Path -LiteralPath $UserMappingPath).Path
    $mapping = Read-BrokerUserMapping -Path $UserMappingPath -TenantId $tenantId -ReservedUsernames @([string]$values['linuxHostAdminLoginName'])
    Test-BrokerUserMapping -Mapping $mapping -GraphEndpoint $graph
}
$vmGroup = if ($values['vmHostResourceGroup']) { [string]$values['vmHostResourceGroup'] } else { $ResourceGroupName }
$vmSubscription = [string]$values['vmSubscriptionId']
$linuxHosts = @(Get-BrokerLinuxInventory -ResourceGroupName $vmGroup -TenantId $tenantId -SubscriptionId $vmSubscription)
if ($values['deployLinuxHosts'] -eq 'true' -and $linuxHosts.Count -lt [int]$values['linuxHostCount']) {
    throw 'Linux ARM inventory is incomplete. Verify the broker-role tags and configured subscription/resource group.'
}
$avdHosts = @(Get-BrokerAvdInventory -ResourceGroupName $ResourceGroupName -HostPoolName $values['avdHostPoolName'])
$minimumAvdHosts = if ($values['deployAvdHosts'] -eq 'true') { [int]$values['avdSessionHostCount'] } else { 0 }
if ($avdHosts.Count -lt $minimumAvdHosts) { throw 'AVD inventory is incomplete; untagged existing hosts must be resolved through their configured host pool.' }
$storageAccountName = [string]$values['storageAccountName']
if ($avdHosts.Count) {
    if ($LauncherPackageUri) {
        $null = Assert-BrokerHttpsUrl $LauncherPackageUri
        if ($LauncherPackagePath -or $LauncherPackageSha256 -notmatch '^[a-fA-F0-9]{64}$') {
            throw 'Prebuilt package URI requires SHA256 and cannot be combined with a local package path.'
        }
    }
    else {
        if ($LauncherPackagePath) { $null = Get-Item -LiteralPath $LauncherPackagePath -ErrorAction Stop }
        else {
            $dotnet = Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue
            if (-not $dotnet) { throw 'Install the pinned native .NET SDK or supply a reviewed prebuilt launcher package before pausing the environment.' }
            $sdkFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'avd_host\broker\global.json'
            $requiredSdk = (Get-Content -LiteralPath $sdkFile -Raw | ConvertFrom-Json).sdk.version
            $installedSdks = & $dotnet.Source --list-sdks 2>$null
            if ($LASTEXITCODE -ne 0 -or -not @($installedSdks | Where-Object { $_ -match ('^' + [regex]::Escape($requiredSdk) + '\s+\[') }).Count) {
                throw "Install pinned .NET SDK $requiredSdk or supply a reviewed prebuilt launcher package before pausing the environment."
            }
        }
        if (-not $storageAccountName) {
            $taskSettings = @(Invoke-BrokerAz -Arguments @('functionapp', 'config', 'appsettings', 'list',
                '--resource-group', $ResourceGroupName, '--name', $TaskAppName) -Operation 'Resolve existing provisioned artifact storage')
            $connectionSetting = @($taskSettings | Where-Object { $_.name -eq 'AzureWebJobsStorage' })
            if ($connectionSetting.Count -eq 1 -and $connectionSetting[0].value -match '(?:^|;)AccountName=([a-z0-9]{3,24})(?:;|$)') {
                $storageAccountName = $Matches[1]
            }
            if (-not $storageAccountName) { throw 'Cannot identify the provisioned private storage account. Set storageAccountName explicitly.' }
            $taskSettings = $null
            $connectionSetting = $null
        }
    }
}
if (-not $SqlServerFqdn) {
    $sqlServer = Invoke-BrokerAz -Arguments @('sql', 'server', 'show', '--name', $values['sqlServerName'],
        '--resource-group', $ResourceGroupName) -Operation 'Resolve SQL server endpoint'
    $SqlServerFqdn = $sqlServer.fullyQualifiedDomainName
}
$sql = @{ SqlServerFqdn = $SqlServerFqdn; DatabaseName = $DatabaseName; SqlAdminLogin = $SqlAdminLogin; SqlAdminPassword = $SqlAdminPassword }
$agent = @{
    ResourceGroupName = $vmGroup; TenantId = $tenantId; ApiBaseUrl = $ApiBaseUrl; ApiClientId = $ApiClientId
    VmSubscriptionId = $vmSubscription
    PythonRuntimeUri = [string]$values['linuxPythonRuntimeUri']
    EnrollDrainedLegacyHosts = [bool]$EnrollDrainedLegacyHosts
    LinuxHostAdminLoginName = if ($values['linuxHostAdminLoginName']) { $values['linuxHostAdminLoginName'] } else { 'avdadmin' }
}
$inventoryConnection = New-BrokerSqlConnection -Server $SqlServerFqdn -Database $DatabaseName -Username $SqlAdminLogin -Password $SqlAdminPassword
try {
    $inventoryConnection.Open()
    $databaseHosts = @(Get-BrokerSqlHostnames -Connection $inventoryConnection -AllowMissingTable)
    Assert-BrokerMigrationInventory -Hosts $linuxHosts -DatabaseHostnames $databaseHosts
}
finally { $inventoryConnection.Dispose() }
if ($DryRun) {
    Write-Host "Read-only preflight: $($linuxHosts.Count) Linux hosts and $($avdHosts.Count) AVD hosts; selected users/groups were verified in Graph."
    $connection = New-BrokerSqlConnection -Server $SqlServerFqdn -Database $DatabaseName -Username $SqlAdminLogin -Password $SqlAdminPassword
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        try {
            $command.CommandText = "SELECT OBJECT_ID(N'dbo.BindBrokerUser', N'P');"
            $schemaReady = $command.ExecuteScalar() -is [int]
        }
        finally { $command.Dispose() }
        if ($schemaReady -and $mapping) {
            Invoke-BrokerUserMapping -Connection $connection -Mapping $mapping -DryRun
            Write-Host 'Binding procedures accepted the reviewed mapping inside a rolled-back transaction.'
        }
        elseif (-not $schemaReady) {
            Write-Host 'SQL binding procedures are not installed yet. Full SQL conflict and guest marker/account checks remain mandatory during the paused migration.'
        }
    }
    finally { $connection.Dispose() }
    Write-Host 'Dry run made no Azure or persistent SQL changes. No host installation or checkout activation was attempted.'
    return
}

Test-BrokerHostPrerequisites -Hosts $linuxHosts -AllowDrainedLegacyEnrollment:$EnrollDrainedLegacyHosts
$receiptPath = Get-BrokerRolloutReceiptPath $EnvironmentName
if (Test-Path -LiteralPath $receiptPath) { Remove-Item -LiteralPath $receiptPath -Force }
$functionActivation = Get-BrokerFunctionActivationState -EnvironmentName $EnvironmentName -ResourceGroupName $ResourceGroupName `
    -TaskAppName $TaskAppName -ExistingEnvironment:$ExistingEnvironment
Suspend-BrokerApps -ResourceGroupName $ResourceGroupName -ApiAppName $apiName -FrontendAppName $frontendName -TaskAppName $TaskAppName
Set-BrokerAppSettings -Type functionapp -ResourceGroupName $ResourceGroupName -Name $TaskAppName -Settings (Get-BrokerFunctionDisableSettings)
Set-BrokerEnvironmentValue -EnvironmentName $EnvironmentName -Key brokerCheckoutEnabled -Value 'false'
Set-BrokerEnvironmentValue -EnvironmentName $EnvironmentName -Key BROKER_CHECKOUT_ENABLED -Value 'false'
& "$PSScriptRoot\Migrate-LinuxHostReleaseAgent.ps1" @agent -Mode Quiesce

& "$PSScriptRoot\Initialize-DeploymentEnvironment.ps1" -EnvironmentName $EnvironmentName -AccessConfigPath $AccessConfigPath `
    -IdentityOnly -ReuseProvisionedImageTag:(-not $ExistingEnvironment)
$values = Get-BrokerEnvironment $EnvironmentName
if ($ApiClientId -ne $values['apiClientId']) { throw 'The migration API audience differs from the authoritative application configuration.' }
$authority = Assert-BrokerHttpsUrl $values['azureAuthorityHost'] -Authority
$launcherId = Assert-BrokerGuid $values['brokerLauncherClientId'] 'Native client ID'
$portalId = Assert-BrokerGuid $values['frontendClientId'] 'Portal client ID'
& "$PSScriptRoot\Initialize-Database.ps1" @sql -ScriptsPath $ScriptsPath
& "$PSScriptRoot\Initialize-BrokerRuntimeDatabaseUser.ps1" @sql -RuntimeUsername $values['sqlRuntimeLogin'] `
    -RuntimePassword $values['sqlRuntimePassword']
Set-BrokerRuntimeDatabaseSecret -KeyVaultName $values['keyVaultName'] -Password $values['sqlRuntimePassword']
if ($mapping) {
    & "$PSScriptRoot\Bind-BrokerUserMappings.ps1" @sql -MappingPath $UserMappingPath -TenantId $tenantId -GraphEndpoint $graph `
        -LinuxHostAdminLoginName $agent.LinuxHostAdminLoginName
}
& "$PSScriptRoot\Register-LinuxHostSqlRecords.ps1" @sql -ResourceGroupName $vmGroup -TenantId $tenantId -VmSubscriptionId $vmSubscription
& "$PSScriptRoot\Assign-FunctionAppApiRole.ps1" -ResourceGroupName $ResourceGroupName -TaskAppName $TaskAppName -ApiClientId $ApiClientId -TenantId $tenantId -GraphEndpoint $graph
& "$PSScriptRoot\Assign-VmApiRoles.ps1" -ResourceGroupName $vmGroup -ApiClientId $ApiClientId -TenantId $tenantId -VmSubscriptionId $vmSubscription -GraphEndpoint $graph
$nativeArtifact = $null
if ($avdHosts.Count) {
    $nativeArtifact = Publish-BrokerLauncherArtifact -Version $LauncherVersion -PackageUri $LauncherPackageUri `
        -PackageSha256 $LauncherPackageSha256 -PackagePath $LauncherPackagePath -StorageAccountName $storageAccountName
}
& "$PSScriptRoot\Migrate-LinuxHostReleaseAgent.ps1" @sql @agent -Mode Install

$imageTag = $values['containerImageTag']
if ($imageTag -notmatch '^broker-auth-v1-[0-9]{14}-[0-9a-f]{8}$') { throw 'The secured rollout image tag is missing or invalid.' }
& "$PSScriptRoot\Build-ContainerImages.ps1" -EnvironmentName $EnvironmentName -ResourceGroupName $ResourceGroupName `
    -FrontendAppName $frontendName -ApiAppName $apiName -TaskAppName $TaskAppName -ImageTag $imageTag -SkipRestart
Set-BrokerAppSettings -Type webapp -ResourceGroupName $ResourceGroupName -Name $apiName -Settings @{
    CLIENT_ID = $ApiClientId; PORTAL_CLIENT_ID = $portalId; BROKER_LAUNCHER_CLIENT_ID = $launcherId
    TENANT_ID = $tenantId; AZURE_AUTHORITY_HOST = $authority; BROKER_CHECKOUT_ENABLED = 'false'
    AZURE_CLOUD_NAME = $values['azureCloudName']; STS_ISSUER_HOST = $values['stsIssuerHost']
    DB_USERNAME = $values['sqlRuntimeLogin']; DB_PASSWORD_NAME = 'db-password'
}
Invoke-BrokerAz -Arguments @('webapp', 'config', 'appsettings', 'delete', '--resource-group', $ResourceGroupName, '--name', $apiName,
    '--setting-names', 'AVD_HOST_GROUP_ID', 'LINUX_HOST_GROUP_ID', 'GRAPH_ENDPOINT', 'GRAPH_API_ENDPOINT',
    'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET') -Operation 'Remove unused API directory-authentication settings' -NoOutput
$apiResource = Invoke-BrokerAz -Arguments @('webapp', 'show', '--resource-group', $ResourceGroupName, '--name', $apiName) -Operation 'Resolve API auth-settings resource'
Invoke-BrokerAz -Arguments @('resource', 'update', '--ids', "$($apiResource.id)/config/authsettingsV2", '--api-version', '2023-12-01',
    '--set', 'properties.platform.enabled=false') -Operation 'Keep broker JWT policy authoritative without legacy Easy Auth secret dependencies' -NoOutput
Set-BrokerAppSettings -Type webapp -ResourceGroupName $ResourceGroupName -Name $frontendName -Settings @{
    CLIENT_ID = $portalId; API_CLIENT_ID = $ApiClientId; API_URL = $ApiBaseUrl
    TENANT_ID = $tenantId; AZURE_AUTHORITY_HOST = $authority
    AZURE_CLOUD_NAME = $values['azureCloudName']
    MICROSOFT_PROVIDER_AUTHENTICATION_SECRET = $values['frontendClientSecret']
}
Set-BrokerAppSettings -Type functionapp -ResourceGroupName $ResourceGroupName -Name $TaskAppName -Settings @{
    API_CLIENT_ID = $ApiClientId; API_URL = $ApiBaseUrl; AZURE_AUTHORITY_HOST = $authority; AZURE_CLOUD_NAME = $values['azureCloudName']
}
$launcher = & "$PSScriptRoot\Install-AvdBrokerLauncher.ps1" -ResourceGroupName $ResourceGroupName -HostPoolName $values['avdHostPoolName'] `
    -TenantId $tenantId -AuthorityHost $authority -LauncherClientId $launcherId -ApiClientId $ApiClientId -ApiBaseUrl $ApiBaseUrl `
    -LauncherVersion $LauncherVersion -Artifact $nativeArtifact -MinimumHostCount $minimumAvdHosts

Invoke-BrokerAz -Arguments @('webapp', 'start', '--resource-group', $ResourceGroupName, '--name', $apiName) -Operation 'Start secured API with checkout paused' -NoOutput
Invoke-BrokerAz -Arguments @('webapp', 'start', '--resource-group', $ResourceGroupName, '--name', $frontendName) -Operation 'Start administrator-only portal' -NoOutput
Wait-BrokerHealth -Uri ($ApiBaseUrl.TrimEnd('/') -replace '/api$', '/health') -Name 'Secured API'
$portalUrl = if ($values['frontendUrl']) { $values['frontendUrl'] } else { "https://$frontendName.$($values['appServiceDomain'])" }
Wait-BrokerHealth -Uri "$($portalUrl.TrimEnd('/'))/health" -Name 'Administrator portal'
Invoke-BrokerAz -Arguments @('functionapp', 'start', '--resource-group', $ResourceGroupName, '--name', $TaskAppName) -Operation 'Start function platform with scheduled triggers disabled' -NoOutput
try {
    Test-BrokerTaskWorkloadAccess -ResourceGroupName $ResourceGroupName -TaskAppName $TaskAppName -ApiBaseUrl $ApiBaseUrl -ApiClientId $ApiClientId
    Test-BrokerLinuxWorkloadAccess -Hosts $linuxHosts -ApiBaseUrl $ApiBaseUrl -ApiClientId $ApiClientId
    & "$PSScriptRoot\Migrate-LinuxHostReleaseAgent.ps1" @agent -Mode Activate
    Set-BrokerAppSettings -Type functionapp -ResourceGroupName $ResourceGroupName -Name $TaskAppName -Settings $functionActivation.Settings
}
catch {
    $activationFailure = $_
    $pauseFailures = [Collections.Generic.List[string]]::new()
    try { Set-BrokerAppSettings -Type functionapp -ResourceGroupName $ResourceGroupName -Name $TaskAppName -Settings (Get-BrokerFunctionDisableSettings) }
    catch { $pauseFailures.Add('disable scheduled callbacks') }
    try {
        Invoke-BrokerAz -Arguments @('functionapp', 'stop', '--resource-group', $ResourceGroupName, '--name', $TaskAppName) -Operation 'Keep unready scheduled workload stopped' -NoOutput
    }
    catch { $pauseFailures.Add('stop Function App') }
    try { & "$PSScriptRoot\Migrate-LinuxHostReleaseAgent.ps1" @agent -Mode Quiesce }
    catch { $pauseFailures.Add('quiesce Linux agents') }
    if ($pauseFailures.Count) {
        throw "Workload authorization/activation failed and automatic pausing was incomplete: $($pauseFailures -join ', '). Checkout remains disabled; reconcile these workloads before retrying."
    }
    throw $activationFailure
}
$taskIdentity = Invoke-BrokerAz -Arguments @('functionapp', 'identity', 'show', '--resource-group', $ResourceGroupName,
    '--name', $TaskAppName) -Operation 'Record verified scheduled workload identity'
$taskPrincipalId = Assert-BrokerGuid $taskIdentity.principalId 'Verified scheduled workload identity'
if ($taskIdentity.tenantId -ne $tenantId) { throw 'The verified scheduled workload tenant changed before rollout completion.' }

$receipt = @{
    contractVersion = 1; completedAt = [DateTime]::UtcNow.ToString('o'); imageTag = $imageTag
    resourceGroupName = $ResourceGroupName; tenantId = $tenantId; apiClientId = $ApiClientId
    frontendClientId = $portalId; brokerLauncherClientId = $launcherId; launcher = $launcher
    workloadsReady = $true; workloadsVerifiedAt = [DateTime]::UtcNow.ToString('o')
    taskPrincipalId = $taskPrincipalId
    runtimeDatabaseVerified = $true; sqlRuntimeLogin = $values['sqlRuntimeLogin']
    trustedInventoryBindingVersion = 46
    linuxHostIds = @($linuxHosts | ForEach-Object { $_.ResourceId })
    linuxHostBindings = @($linuxHosts | ForEach-Object { "$($_.ResourceId)|$($_.ObjectId)" })
    avdHostIds = @($avdHosts | ForEach-Object { $_.ResourceId })
    reviewedMappingSha256 = if ($UserMappingPath) { (Get-FileHash -LiteralPath $UserMappingPath).Hash } else { $null }
}
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $receiptPath) -Force
$receipt | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $receiptPath -Encoding utf8
Remove-Item -LiteralPath $functionActivation.Path -Force
Write-Host "Secured stack, reviewed bindings, host agents, and native launchers are installed. Checkout is still PAUSED. Validate the controlled pilot, then use Set-BrokerCheckoutState.ps1 -EnvironmentName $EnvironmentName -State Enabled -SecuredRolloutValidated."
