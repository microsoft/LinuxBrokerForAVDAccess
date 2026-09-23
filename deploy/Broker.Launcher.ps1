. "$PSScriptRoot\Broker.Deployment.Common.ps1"

function Get-BrokerAvdInventory {
    param([Parameter(Mandatory)][string]$ResourceGroupName, [string]$HostPoolName)
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $vms = @(Invoke-BrokerAz -Arguments @('vm', 'list', '--resource-group', $ResourceGroupName) -Operation 'Read AVD ARM inventory')
    foreach ($vm in $vms) {
        if ($vm.tags -and $vm.tags['broker-role'] -eq 'avd-host') { $null = $ids.Add($vm.id) }
    }
    if ($HostPoolName) {
        $pool = Invoke-BrokerAz -Arguments @('resource', 'show', '--resource-group', $ResourceGroupName,
            '--resource-type', 'Microsoft.DesktopVirtualization/hostPools', '--name', $HostPoolName,
            '--api-version', '2024-04-03') -Operation 'Read configured AVD host pool'
        $cloud = Invoke-BrokerAz -Arguments @('cloud', 'show') -Operation 'Read ARM cloud endpoint'
        $arm = $cloud.endpoints.resourceManager.TrimEnd('/')
        $uri = "$arm$($pool.id)/sessionHosts?api-version=2024-04-03"
        $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        while ($uri) {
            if (-not $visited.Add($uri) -or -not $uri.StartsWith("$arm/", [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Invalid AVD inventory pagination link.'
            }
            $page = Invoke-BrokerAz -Arguments @('rest', '--method', 'GET', '--url', $uri) -Operation 'Read registered AVD session hosts'
            foreach ($hostRecord in $page.value) {
                $id = $hostRecord.properties.resourceId
                if (-not $id -or $id -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft.Compute/virtualMachines/[^/]+$') {
                    throw 'A registered AVD session host has no trustworthy ARM VM resource ID.'
                }
                $null = $ids.Add($id)
            }
            $uri = $page['nextLink']
        }
    }
    foreach ($id in $ids) {
        $vm = Invoke-BrokerAz -Arguments @('vm', 'show', '--ids', $id) -Operation 'Verify AVD host inventory'
        if ($vm.storageProfile.osDisk.osType -ne 'Windows') { throw "AVD inventory contains a non-Windows VM '$($vm.name)'." }
        [pscustomobject]@{
            Name = $vm.name; ResourceId = $vm.id
            ObjectId = if ($vm['identity']) { $vm.identity['principalId'] } else { $null }
            TenantId = if ($vm['identity']) { $vm.identity['tenantId'] } else { $null }
        }
    }
}

function Publish-BrokerLauncherArtifact {
    param(
        [Parameter(Mandatory)][ValidatePattern('^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})$')][string]$Version,
        [string]$PackageUri,
        [string]$PackageSha256,
        [string]$PackagePath,
        [string]$StorageAccountName,
        [string]$ContainerName = 'broker-artifacts'
    )
    if ($PackageUri) {
        if ($PackagePath -or $PackageSha256 -notmatch '^[a-fA-F0-9]{64}$') {
            throw 'A prebuilt HTTPS package requires its SHA256 and version, and cannot be combined with PackagePath.'
        }
        $null = Assert-BrokerHttpsUrl $PackageUri
        return @{ Uri = $PackageUri; Sha256 = $PackageSha256.ToLowerInvariant(); Version = $Version }
    }
    if (-not $StorageAccountName) { throw 'Provisioned storageAccountName is required to stage the native launcher.' }
    if (-not $PackagePath) {
        $publisher = Join-Path (Split-Path -Parent $PSScriptRoot) 'avd_host\broker\Publish-Launcher.ps1'
        if (-not (Test-Path -LiteralPath $publisher)) { throw 'The version-matched native launcher publisher is missing. Do not deploy an old script or invent a release URL.' }
        $destination = Join-Path $PSScriptRoot ".artifacts\launcher\$Version"
        $dotnet = Get-Command dotnet -CommandType Application -ErrorAction Stop
        $published = & $publisher -Version $Version -OutputDirectory $destination -DotNetPath $dotnet.Source
        $PackagePath = $published.BundlePath
        if ($published.Version -ne $Version -or $published.Runtime -ne 'win-x64' -or
            -not $PackagePath -or -not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
            throw 'The native publisher did not return the requested version and win-x64 BundlePath.'
        }
    }
    $PackagePath = (Resolve-Path -LiteralPath $PackagePath).Path
    $digest = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($PackageSha256 -and $digest -ine $PackageSha256) { throw 'The local launcher package does not match the supplied SHA256.' }
    if ($ContainerName -notmatch '^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])$' -or $ContainerName.Contains('--')) {
        throw 'Invalid private artifact container name.'
    }
    $storage = Invoke-BrokerAz -Arguments @('storage', 'account', 'show', '--name', $StorageAccountName) -Operation 'Read artifact storage endpoint'
    $endpoint = Assert-BrokerHttpsUrl $storage.primaryEndpoints.blob -Authority
    $null = Invoke-BrokerAz -Arguments @('storage', 'container', 'create', '--account-name', $StorageAccountName,
        '--blob-endpoint', $endpoint, '--auth-mode', 'login', '--name', $ContainerName, '--public-access', 'off') -Operation 'Ensure private launcher artifact container'
    $blobName = "launcher/$Version/$digest.zip"
    $null = Invoke-BrokerAz -Arguments @('storage', 'blob', 'upload', '--account-name', $StorageAccountName,
        '--blob-endpoint', $endpoint, '--auth-mode', 'login', '--container-name', $ContainerName,
        '--name', $blobName, '--file', $PackagePath, '--overwrite', 'true') -Operation 'Stage content-addressed launcher package'
    $installerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'custom_script_extensions\Configure-AVD-Host.ps1'
    $installerDigest = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $installerName = "launcher/$Version/installer-$installerDigest.ps1"
    $null = Invoke-BrokerAz -Arguments @('storage', 'blob', 'upload', '--account-name', $StorageAccountName,
        '--blob-endpoint', $endpoint, '--auth-mode', 'login', '--container-name', $ContainerName,
        '--name', $installerName, '--file', $installerPath, '--overwrite', 'true') -Operation 'Stage content-addressed launcher installer'
    Write-Host "Staged launcher $Version with SHA256 $digest in private storage. Downloads use container-scoped VM identity, not SAS or account keys."
    return @{
        Uri = "$endpoint/$ContainerName/$blobName"; Sha256 = $digest; Version = $Version
        InstallerUri = "$endpoint/$ContainerName/$installerName"; InstallerSha256 = $installerDigest
        PackageRelativePath = $blobName.Replace('/', '\'); InstallerRelativePath = $installerName.Replace('/', '\')
        StorageScope = "$($storage.id)/blobServices/default/containers/$ContainerName"
    }
}

function Ensure-BrokerArtifactReader {
    param([Parameter(Mandatory)]$HostRecord, [Parameter(Mandatory)][string]$Scope, [Parameter(Mandatory)][string]$TenantId)
    $principalId = Assert-BrokerGuid ([string]$HostRecord.ObjectId) 'AVD artifact-reader managed identity'
    if ($HostRecord.TenantId -ne $TenantId) { throw 'Private artifact installation requires a system-assigned VM identity in the deployment tenant.' }
    $readerRole = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
    $assignments = @(Invoke-BrokerAz -Arguments @('role', 'assignment', 'list', '--scope', $Scope, '--include-inherited') -Operation 'Inspect private artifact reader assignments')
    if (@($assignments | Where-Object { $_.principalId -eq $principalId -and $_.roleDefinitionId.EndsWith("/$readerRole", [StringComparison]::OrdinalIgnoreCase) }).Count) { return }
    Invoke-BrokerAz -Arguments @('role', 'assignment', 'create', '--assignee-object-id', $principalId,
        '--assignee-principal-type', 'ServicePrincipal', '--role', $readerRole, '--scope', $Scope) `
        -Operation 'Grant container-only artifact reader to AVD managed identity' -NoOutput
}

function Install-BrokerPrivateLauncher {
    param([Parameter(Mandatory)]$HostRecord, [hashtable]$Artifact, [hashtable]$Parameters)
    if ($HostRecord.ResourceId -notmatch '^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft.Compute/virtualMachines/([^/]+)$') {
        throw 'Invalid trusted AVD resource ID.'
    }
    $subscription = $Matches[1]; $group = $Matches[2]; $name = $Matches[3]
    Ensure-BrokerArtifactReader -HostRecord $HostRecord -Scope $Artifact.StorageScope -TenantId $Parameters.TenantId
    $Parameters.PackagePath = $Artifact.PackageRelativePath
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Parameters | ConvertTo-Json -Compress)))
    $command = @'
$ErrorActionPreference = 'Stop'
try {
    if ((Get-FileHash -LiteralPath '__INSTALLER_PATH__' -Algorithm SHA256).Hash -ine '__INSTALLER_SHA__') {
        throw 'The downloaded installer failed integrity verification.'
    }
    $settings = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__SETTINGS__')) | ConvertFrom-Json
    $parameters = @{}
    foreach ($property in $settings.PSObject.Properties) { $parameters[$property.Name] = $property.Value }
    & '.\__INSTALLER_PATH__' @parameters
} catch { Write-Error 'Verified launcher installation failed. Checkout remains paused.'; exit 1 }
'@
    $command = $command.Replace('__INSTALLER_PATH__', $Artifact.InstallerRelativePath).
        Replace('__INSTALLER_SHA__', $Artifact.InstallerSha256).Replace('__SETTINGS__', $encoded)
    $protected = @{
        fileUris = @($Artifact.InstallerUri, $Artifact.Uri)
        managedIdentity = @{}
        commandToExecute = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -EncodedCommand ' +
            [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    }
    $path = Write-BrokerPrivateJson -Value $protected
    try {
        for ($attempt = 0; $attempt -lt 5; $attempt++) {
            try {
                $extension = Invoke-BrokerAz -Arguments @('vm', 'extension', 'set', '--subscription', $subscription,
                    '--resource-group', $group, '--vm-name', $name, '--publisher', 'Microsoft.Compute',
                    '--name', 'CustomScriptExtension', '--version', '1.10', '--force-update',
                    '--protected-settings', "@$path") -Operation "Install private native artifact on '$name'"
                if ($extension.provisioningState -ne 'Succeeded') { throw "Native extension on '$name' did not complete successfully." }
                return
            }
            catch [System.Management.Automation.RuntimeException] {
                if ($attempt -eq 4 -or $_.Exception.Message -notmatch 'Azure CLI exit') { throw }
                # Storage RBAC may not have reached the guest yet; every retry remains SHA256-pinned and idempotent.
                Write-Warning "Native extension on '$name' did not complete. Retrying the verified install while checkout remains paused."
                Start-Sleep -Seconds (15 * [Math]::Pow(2, $attempt))
            }
        }
    }
    finally { Remove-Item -LiteralPath $path -Force }
}

function Install-BrokerLauncherOnHost {
    param(
        [Parameter(Mandatory)]$HostRecord,
        [Parameter(Mandatory)][hashtable]$Artifact,
        [Parameter(Mandatory)][hashtable]$Configuration
    )
    $installerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'custom_script_extensions\Configure-AVD-Host.ps1'
    $installer = Get-Content -LiteralPath $installerPath -Raw
    $parameters = @{
        LinuxBrokerApiBaseUrl = $Configuration.apiBaseUrl
        TenantId = $Configuration.tenantId
        AuthorityHost = $Configuration.authorityHost
        LauncherClientId = $Configuration.clientId
        ApiClientId = $Configuration.apiClientId
        PackageSha256 = $Artifact.Sha256
        PackageVersion = $Artifact.Version
    }
    if ($Artifact['StorageScope']) {
        Install-BrokerPrivateLauncher -HostRecord $HostRecord -Artifact $Artifact -Parameters $parameters
        return
    }
    $parameters.PackageUri = $Artifact.Uri
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($parameters | ConvertTo-Json -Compress)))
    $script = @'
$settings = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__SETTINGS__')) | ConvertFrom-Json
$parameters = @{}
foreach ($property in $settings.PSObject.Properties) { $parameters[$property.Name] = $property.Value }
& {
__INSTALLER__
} @parameters
'@
    $script = $script.Replace('__SETTINGS__', $encoded).Replace('__INSTALLER__', $installer)
    Invoke-BrokerVmScript -ResourceId $HostRecord.ResourceId -CommandId RunPowerShellScript -Script $script `
        -Operation "Install verified native launcher on '$($HostRecord.Name)'"
}
