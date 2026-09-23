[CmdletBinding()]
param(
    [ValidateLength(3, 12)][ValidatePattern('^[a-zA-Z0-9]+$')][string]$AppName,
    [ValidateLength(2, 16)][ValidatePattern('^[a-zA-Z0-9-]+$')][string]$EnvironmentName,
    [string]$AccessConfigPath,
    [switch]$IdentityOnly,
    [switch]$ReuseProvisionedImageTag
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Broker.Identity.ps1"
. "$PSScriptRoot\Broker.LinuxMigration.ps1"
. "$PSScriptRoot\Broker.DatabaseRuntime.ps1"

$resolvedEnvironmentName = $EnvironmentName
if (-not $resolvedEnvironmentName) { $resolvedEnvironmentName = $env:AZURE_ENV_NAME }
if (-not $resolvedEnvironmentName) { $resolvedEnvironmentName = $env:AZURE_ENVIRONMENT_NAME }
if (-not $resolvedEnvironmentName) { throw 'EnvironmentName or AZURE_ENV_NAME is required.' }
$EnvironmentName = $resolvedEnvironmentName
$values = Get-BrokerEnvironment $EnvironmentName
foreach ($entry in @{
        apiClientId = 'API_CLIENT_ID'; frontendClientId = 'FRONTEND_CLIENT_ID'
        brokerLauncherClientId = 'BROKER_LAUNCHER_CLIENT_ID'; tenantId = 'TENANT_ID'
    }.GetEnumerator()) {
    if (-not $values[$entry.Key] -and $values[$entry.Value]) { $values[$entry.Key] = $values[$entry.Value] }
}
$resolvedAppName = $AppName
if (-not $resolvedAppName) { $resolvedAppName = $values['appName'] }
if (-not $resolvedAppName) { $resolvedAppName = $values['AZURE_APP_NAME'] }
if (-not $resolvedAppName) { $resolvedAppName = $values['APP_NAME'] }
if (-not $resolvedAppName) { $resolvedAppName = $env:AZURE_APP_NAME }
if (-not $resolvedAppName) { $resolvedAppName = $env:APP_NAME }
if (-not $resolvedAppName) { $resolvedAppName = 'linuxbroker' }
if ($resolvedAppName -notmatch '^[a-zA-Z0-9]{3,12}$') { throw 'appName must contain 3..12 letters or digits.' }
$AppName = $resolvedAppName
if (-not $AccessConfigPath) { $AccessConfigPath = $values['brokerAccessConfigPath'] }
if (-not $AccessConfigPath) { throw 'Set brokerAccessConfigPath to an operator-reviewed access configuration. No tenant-wide or deployer-default grant is made.' }
$AccessConfigPath = (Resolve-Path -LiteralPath $AccessConfigPath).Path

function Set-DeploymentValue {
    param([string]$Key, [AllowEmptyString()][string]$Value)
    Set-BrokerEnvironmentValue -EnvironmentName $EnvironmentName -Key $Key -Value $Value
    $values[$Key] = $Value
}

function New-DeploymentSecret {
    $bytes = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_') + 'aA7!'
}

$cloud = Invoke-BrokerAz -Arguments @('cloud', 'show') -Operation 'Read Azure cloud configuration'
$account = Invoke-BrokerAz -Arguments @('account', 'show') -Operation 'Read deployment account'
$tenantId = if ($values['tenantId']) { $values['tenantId'] } else { $account.tenantId }
$tenantId = Assert-BrokerGuid $tenantId 'tenantId'
Assert-BrokerTenant $tenantId
$cloudName = $values['azureCloudName']
if (-not $cloudName) { $cloudName = $values['AZURE_CLOUD_NAME'] }
if (-not $cloudName) {
    $cloudName = switch ($cloud.name) {
        'AzureCloud' { 'AzurePublic' }
        'AzureUSGovernment' { 'AzureUSGovernment' }
        default { 'AzureCustom' }
    }
}
$profiles = @{
    AzurePublic = @{ cli = 'AzureCloud'; graphEndpoint = 'https://graph.microsoft.com'; appServiceDomain = 'azurewebsites.net'; stsIssuerHost = 'https://sts.windows.net' }
    AzureUSGovernment = @{ cli = 'AzureUSGovernment'; graphEndpoint = 'https://graph.microsoft.us'; appServiceDomain = 'azurewebsites.us'; stsIssuerHost = 'https://sts.windows.net' }
    AzureCustom = @{ cli = $cloud.name; graphEndpoint = ''; appServiceDomain = ''; stsIssuerHost = '' }
}
if (-not $profiles.ContainsKey($cloudName) -or $profiles[$cloudName].cli -ne $cloud.name) {
    throw 'The configured Azure cloud does not match the Azure CLI cloud. Select the intended cloud before deployment.'
}
foreach ($key in @('graphEndpoint', 'appServiceDomain', 'stsIssuerHost')) {
    if (-not $values[$key]) { $values[$key] = $profiles[$cloudName][$key] }
    if (-not $values[$key]) { throw "Cloud '$cloudName' requires '$key'." }
}
if (-not $values['azureAuthorityHost']) { $values['azureAuthorityHost'] = $cloud.endpoints.activeDirectory }
$values['azureAuthorityHost'] = Assert-BrokerHttpsUrl $values['azureAuthorityHost'] -Authority
$values['graphEndpoint'] = Assert-BrokerHttpsUrl $values['graphEndpoint'] -Authority
$values['stsIssuerHost'] = Assert-BrokerHttpsUrl $values['stsIssuerHost'] -Authority
if ($values['appServiceDomain'] -notmatch '^[a-zA-Z0-9.-]+$') { throw 'Invalid appServiceDomain.' }
$legacyGroups = @($values['avdHostGroupId'], $values['AVD_HOST_GROUP_ID'], $values['linuxHostGroupId'], $values['LINUX_HOST_GROUP_ID'] |
    Where-Object { $_ } | Select-Object -Unique)
$access = Read-BrokerAccessConfiguration -Path $AccessConfigPath -TenantId $tenantId -LegacyMachineGroupIds $legacyGroups
if ($IdentityOnly) {
    if (-not $values['resourceGroupName'] -or -not $values['apiAppName']) {
        throw 'Identity-only migration requires the existing resourceGroupName and apiAppName.'
    }
    $existingApi = Invoke-BrokerAz -Arguments @('webapp', 'show', '--resource-group', $values['resourceGroupName'],
        '--name', $values['apiAppName']) -Operation 'Verify API is stopped before identity migration'
    if ($existingApi.state -ne 'Stopped') { throw 'Stop the API through the coordinated migration before changing legacy authorization assignments.' }
}

if (-not $IdentityOnly) {
    if ($values['deployAvdHosts'] -ne 'false' -and -not $values['launcherPackageUri'] -and
        -not $values['launcherPackagePath'] -and -not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw 'The native launcher requires the .NET SDK used by avd_host\broker\Publish-Launcher.ps1. Install it or configure launcherPackageUri, launcherPackageSha256, and launcherVersion.'
    }
    $groupName = if ($values['resourceGroupName']) { $values['resourceGroupName'] } else { "rg-$AppName-$EnvironmentName" }
    $exists = Invoke-BrokerAz -Arguments @('group', 'exists', '--name', $groupName) -Operation 'Check for an existing deployment'
    if ($exists) {
        $apps = @(Invoke-BrokerAz -Arguments @('webapp', 'list', '--resource-group', $groupName) -Operation 'Inspect existing broker apps')
        if (@($apps | Where-Object { $_.name -eq "api-$AppName-$EnvironmentName" }).Count) {
            throw 'An existing broker API was found. Use Migrate-ExistingEnvironment.ps1 for a paused, coordinated upgrade; preprovision must not update a running legacy authorization boundary.'
        }
    }
}

foreach ($entry in @{
        appName = $AppName; environmentName = $EnvironmentName; tenantId = $tenantId; TENANT_ID = $tenantId
        AZURE_CLOUD_NAME = $cloudName; azureCloudName = $cloudName; brokerAccessConfigPath = $AccessConfigPath
        graphEndpoint = $values['graphEndpoint']; appServiceDomain = $values['appServiceDomain']
        stsIssuerHost = $values['stsIssuerHost']; azureAuthorityHost = $values['azureAuthorityHost']
        brokerCheckoutEnabled = 'false'; BROKER_CHECKOUT_ENABLED = 'false'
    }.GetEnumerator()) {
    Set-DeploymentValue $entry.Key $entry.Value
}

$portalUrl = if ($values['frontendUrl']) { $values['frontendUrl'] }
    elseif ($values['frontendAppName']) { "https://$($values['frontendAppName']).$($values['appServiceDomain'])" }
    else { "https://fe-$AppName-$EnvironmentName.$($values['appServiceDomain'])" }
$applications = Initialize-BrokerApplications -Configuration $access -GraphEndpoint $values['graphEndpoint'] `
    -NamePrefix "$AppName-$EnvironmentName" -PortalUrl $portalUrl `
    -ApiClientId $values['apiClientId'] -PortalClientId $values['frontendClientId'] `
    -LauncherClientId $values['brokerLauncherClientId'] -LegacyMachineGroupIds $legacyGroups

$oldPortalId = $values['frontendClientId']
$portalSecret = $values['frontendClientSecret']
if (-not $portalSecret) { $portalSecret = $values['FRONTEND_CLIENT_SECRET'] }
if (-not $portalSecret -or $oldPortalId -ne $applications.Portal.appId) {
    $credential = Invoke-BrokerAz -Arguments @('ad', 'app', 'credential', 'reset', '--id', $applications.Portal.appId, '--append',
        '--display-name', 'LinuxBroker portal deployment') -Operation 'Create portal credential'
    $portalSecret = $credential.password
    if (-not $portalSecret) { throw 'The portal credential was not returned; deployment cannot continue.' }
}
foreach ($entry in @{
        apiClientId = $applications.Api.appId; API_CLIENT_ID = $applications.Api.appId
        frontendClientId = $applications.Portal.appId; FRONTEND_CLIENT_ID = $applications.Portal.appId; PORTAL_CLIENT_ID = $applications.Portal.appId
        brokerLauncherClientId = $applications.Launcher.appId; BROKER_LAUNCHER_CLIENT_ID = $applications.Launcher.appId
        frontendClientSecret = $portalSecret; FRONTEND_CLIENT_SECRET = $portalSecret
    }.GetEnumerator()) {
    Set-DeploymentValue $entry.Key $entry.Value
}
foreach ($key in @('workspaceUserGroupIds', 'workspaceUserIds', 'portalAdminGroupIds', 'portalAdminUserIds')) {
    Set-DeploymentValue $key (ConvertTo-Json -InputObject @($access[$key]) -Compress)
}
if (-not $ReuseProvisionedImageTag -or -not $values['containerImageTag']) {
    Set-DeploymentValue 'containerImageTag' ('broker-auth-v1-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
}
elseif ($values['containerImageTag'] -notmatch '^broker-auth-v1-[0-9]{14}-[0-9a-f]{8}$') {
    throw 'Provisioning did not supply a unique secured image tag.'
}
$runtimeLogin = if ($values['sqlRuntimeLogin']) { $values['sqlRuntimeLogin'] }
    elseif ($values['SQL_RUNTIME_LOGIN']) { $values['SQL_RUNTIME_LOGIN'] } else { 'brokerapi' }
$runtimePassword = if ($values['sqlRuntimePassword']) { $values['sqlRuntimePassword'] }
    elseif ($values['SQL_RUNTIME_PASSWORD']) { $values['SQL_RUNTIME_PASSWORD'] } else { New-DeploymentSecret }
$deploymentLogin = if ($values['sqlAdminLogin']) { $values['sqlAdminLogin'] }
    elseif ($values['SQL_ADMIN_LOGIN']) { $values['SQL_ADMIN_LOGIN'] } else { 'brokeradmin' }
Assert-BrokerRuntimeDatabaseIdentity -Username $runtimeLogin -Password $runtimePassword -DeploymentUsername $deploymentLogin
foreach ($deploymentPassword in @($values['sqlAdminPassword'], $values['SQL_ADMIN_PASSWORD'])) {
    if ($deploymentPassword -and $runtimePassword -ceq $deploymentPassword) {
        throw 'sqlRuntimePassword must not reuse the deployment administrator password.'
    }
}
foreach ($entry in @{
        sqlRuntimeLogin = $runtimeLogin; SQL_RUNTIME_LOGIN = $runtimeLogin
        sqlRuntimePassword = $runtimePassword; SQL_RUNTIME_PASSWORD = $runtimePassword
    }.GetEnumerator()) {
    Set-DeploymentValue $entry.Key $entry.Value
}
Write-Host 'Configured separate workspace, portal administrator, and application-only workload permissions. Checkouts remain disabled.'
if ($IdentityOnly) { return }

$defaults = @{
    sqlAdminLogin = 'brokeradmin'; sqlDatabaseName = 'LinuxBroker'; appServicePlanSku = 'P2mv3'
    linuxHostAdminLoginName = 'avdadmin'; domainName = ''; nfsShare = ''; vmHostResourceGroup = ''
    deployLinuxHosts = 'true'; deployAvdHosts = 'true'; linuxHostCount = '2'; avdSessionHostCount = '1'
    avdHostPoolName = "$AppName-$EnvironmentName-hp"; avdVmNamePrefix = 'avdhost'; linuxHostVmNamePrefix = 'lnxhost'
    linuxHostAuthType = 'SSH'; linuxHostOsVersion = '24_04-lts'; linuxHostDisableScreenLock = 'true'
    linuxHostVmSize = 'Standard_D2s_v5'; avdVmSize = 'Standard_D8s_v5'; avdMaxSessionLimit = '5'
    vmSubscriptionId = $account.id; scriptSourceRoot = 'https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/refs/heads/main'
    launcherVersion = '1.0.0'; launcherPackageUri = ''; launcherPackageSha256 = ''
}
$aliases = @{
    sqlAdminLogin = 'SQL_ADMIN_LOGIN'; sqlDatabaseName = 'SQL_DATABASE_NAME'; appServicePlanSku = 'APP_SERVICE_PLAN_SKU'
    linuxHostAdminLoginName = 'LINUX_HOST_ADMIN_LOGIN_NAME'; domainName = 'DOMAIN_NAME'; nfsShare = 'NFS_SHARE'
    vmHostResourceGroup = 'VM_HOST_RESOURCE_GROUP'; sqlAdminPassword = 'SQL_ADMIN_PASSWORD'
    hostAdminPassword = 'HOST_ADMIN_PASSWORD'; flaskKey = 'FLASK_SESSION_SECRET'
    linuxHostSshPublicKey = 'LINUX_HOST_SSH_PUBLIC_KEY'; linuxHostSshPrivateKey = 'LINUX_HOST_SSH_PRIVATE_KEY'
}
foreach ($entry in $aliases.GetEnumerator()) {
    if (-not $values[$entry.Key] -and $values[$entry.Value]) { $values[$entry.Key] = $values[$entry.Value] }
}
foreach ($entry in $defaults.GetEnumerator()) {
    if (-not $values[$entry.Key]) { $values[$entry.Key] = $entry.Value }
    Set-DeploymentValue $entry.Key $values[$entry.Key]
}
foreach ($key in @('sqlAdminPassword', 'hostAdminPassword', 'flaskKey')) {
    if (-not $values[$key]) { $values[$key] = New-DeploymentSecret }
    Set-DeploymentValue $key $values[$key]
}
if ($values['deployLinuxHosts'] -eq 'true' -and $values['linuxHostAuthType'] -ne 'SSH') {
    throw 'Broker-managed Linux hosts require SSH key authentication.'
}
$hasPublic = -not [string]::IsNullOrWhiteSpace($values['linuxHostSshPublicKey'])
$hasPrivate = -not [string]::IsNullOrWhiteSpace($values['linuxHostSshPrivateKey'])
if ($hasPublic -xor $hasPrivate) { throw 'A partial Linux SSH keypair is configured. Supply both matching keys; deployment never silently replaces an existing key.' }
if (-not $hasPublic -and $values['deployLinuxHosts'] -eq 'true') {
    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) { throw 'Install OpenSSH Client or configure both Linux host SSH keys.' }
    $keyPath = New-BrokerTemporaryFile -Extension '.key'
    try {
        $null = & ssh-keygen -q -t ed25519 -N '' -C "$AppName-$EnvironmentName-linux-host" -f $keyPath 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'Linux host SSH key generation failed.' }
        $values['linuxHostSshPublicKey'] = (Get-Content -LiteralPath "$keyPath.pub" -Raw).Trim()
        $values['linuxHostSshPrivateKey'] = (Get-Content -LiteralPath $keyPath -Raw).Replace("`r`n", "`n").Replace("`n", '\n')
    }
    finally {
        foreach ($file in @($keyPath, "$keyPath.pub")) {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        }
    }
}
foreach ($entry in $aliases.GetEnumerator()) {
    $value = [string]$values[$entry.Key]
    if ($entry.Key -eq 'linuxHostSshPrivateKey') { $value = $value.Replace("`r`n", "`n").Replace("`n", '\n') }
    Set-DeploymentValue $entry.Key $value
    Set-DeploymentValue $entry.Value $value
}
if (-not $values['allowedClientIp']) {
    try { $values['allowedClientIp'] = (Invoke-RestMethod -Uri 'https://ifconfig.me/ip' -TimeoutSec 10).Trim() }
    catch { throw 'Cannot determine the SQL firewall client IP. Set allowedClientIp explicitly and rerun.' }
    Set-DeploymentValue 'allowedClientIp' $values['allowedClientIp']
}

$parameters = [ordered]@{
    environmentName = @{ value = '${AZURE_ENV_NAME}' }
    location = @{ value = '${AZURE_LOCATION}' }
}
$strings = @(
    'appName', 'tenantId', 'frontendClientId', 'frontendClientSecret', 'apiClientId', 'brokerLauncherClientId', 'containerImageTag',
    'linuxHostSshPrivateKey', 'linuxHostSshPublicKey', 'sqlAdminLogin', 'sqlAdminPassword', 'sqlRuntimeLogin', 'sqlRuntimePassword', 'flaskKey',
    'domainName', 'nfsShare', 'linuxHostAdminLoginName', 'hostAdminPassword', 'vmHostResourceGroup',
    'vmSubscriptionId', 'allowedClientIp', 'appServicePlanSku', 'linuxHostVmNamePrefix', 'linuxHostVmSize',
    'linuxHostAuthType', 'linuxHostOsVersion', 'avdHostPoolName', 'avdVmNamePrefix', 'avdVmSize',
    'azureCloudName', 'azureAuthorityHost', 'graphEndpoint', 'stsIssuerHost', 'appServiceDomain', 'scriptSourceRoot'
)
foreach ($key in $strings) { $parameters[$key] = @{ value = [string]$values[$key] } }
foreach ($key in @('deployLinuxHosts', 'deployAvdHosts', 'linuxHostDisableScreenLock', 'brokerCheckoutEnabled')) {
    if ($values[$key] -notin @('true', 'false')) { throw "'$key' must be true or false." }
    $parameters[$key] = @{ value = $values[$key] -eq 'true' }
}
foreach ($key in @('linuxHostCount', 'avdSessionHostCount', 'avdMaxSessionLimit')) {
    $number = 0
    if (-not [int]::TryParse($values[$key], [ref]$number) -or $number -lt 0) { throw "'$key' must be a nonnegative integer." }
    $parameters[$key] = @{ value = $number }
}
foreach ($key in @('workspaceUserGroupIds', 'workspaceUserIds')) { $parameters[$key] = @{ value = @($access[$key]) } }
$parameters['linuxAgentFileHashes'] = @{ value = Get-BrokerLinuxArtifactHashes -SourceRoot (Split-Path -Parent $PSScriptRoot) }
$parameters['linuxPythonRuntime'] = @{ value = Get-BrokerPythonRuntimeLock -MirrorUri $values['linuxPythonRuntimeUri'] }
$parameterFile = Join-Path $PSScriptRoot 'bicep\main.parameters.json'
@{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'; parameters = $parameters
} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $parameterFile -Encoding utf8
Write-Host 'Generated local Bicep parameters. The native package is built/staged and installed only after storage and VMs exist.'
