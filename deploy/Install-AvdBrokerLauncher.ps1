[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [string]$HostPoolName,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$AuthorityHost,
    [Parameter(Mandatory)][string]$LauncherClientId,
    [Parameter(Mandatory)][string]$ApiClientId,
    [Parameter(Mandatory)][string]$ApiBaseUrl,
    [Parameter(Mandatory)][string]$LauncherVersion,
    [string]$PackageUri,
    [string]$PackageSha256,
    [string]$PackagePath,
    [string]$StorageAccountName,
    [hashtable]$Artifact,
    [string]$ContainerName = 'broker-artifacts',
    [ValidateRange(0, 10000)][int]$MinimumHostCount = 0,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Broker.Launcher.ps1"
$config = @{
    tenantId = Assert-BrokerGuid $TenantId 'TenantId'
    authorityHost = Assert-BrokerHttpsUrl $AuthorityHost -Authority
    clientId = Assert-BrokerGuid $LauncherClientId 'Native launcher client ID'
    apiClientId = Assert-BrokerGuid $ApiClientId 'API client ID'
    apiBaseUrl = Assert-BrokerHttpsUrl $ApiBaseUrl -Api
}
Assert-BrokerTenant $config.tenantId
if ($config.clientId -eq $config.apiClientId) { throw 'Native launcher and API client IDs must differ.' }
$hosts = @(Get-BrokerAvdInventory -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName)
if ($hosts.Count -lt $MinimumHostCount) {
    throw "Expected at least $MinimumHostCount AVD hosts but found $($hosts.Count). Check tags and the configured host pool; no host is silently skipped."
}
if ($DryRun) {
    foreach ($hostRecord in $hosts) { Write-Host "Would install launcher $LauncherVersion on '$($hostRecord.Name)' ($($hostRecord.ResourceId))." }
    return
}
if (-not $hosts.Count) {
    Write-Host 'ARM inventory contains no AVD hosts; no launcher installation was requested.'
    return @{ Version = $LauncherVersion; Sha256 = ''; HostCount = 0 }
}
if (-not $Artifact) {
    $Artifact = Publish-BrokerLauncherArtifact -Version $LauncherVersion -PackageUri $PackageUri -PackageSha256 $PackageSha256 `
        -PackagePath $PackagePath -StorageAccountName $StorageAccountName -ContainerName $ContainerName
}
if ($Artifact.Version -ne $LauncherVersion -or $Artifact.Sha256 -notmatch '^[a-fA-F0-9]{64}$') {
    throw 'The staged artifact does not match the requested version and SHA256 contract.'
}
foreach ($hostRecord in $hosts) {
    Install-BrokerLauncherOnHost -HostRecord $hostRecord -Artifact $Artifact -Configuration $config
    Write-Host "Verified launcher installation on '$($hostRecord.Name)'."
}
return @{ Version = $Artifact.Version; Sha256 = $Artifact.Sha256; HostCount = $hosts.Count }
