#Requires -Version 5.1
[CmdletBinding()]
param (
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'artifacts'),

    [ValidatePattern('^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})$')]
    [string]$Version = '1.0.0',

    [string]$DotNetPath = (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'),

    [string]$NuGetConfigPath = (Join-Path $PSScriptRoot 'NuGet.Config')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'

function Invoke-DotNet {
    param([string[]]$Arguments)
    & $DotNetPath @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet $($Arguments[0]) failed with exit code $LASTEXITCODE. No bundle was produced by this invocation."
    }
}

if ($env:OS -ne 'Windows_NT' -or -not (Test-Path -LiteralPath $DotNetPath -PathType Leaf)) {
    throw 'Publishing requires Windows x64 and the .NET SDK specified in avd_host\broker\global.json.'
}
if ($OutputDirectory -notmatch '^[a-zA-Z]:\\' -or $OutputDirectory -match '["\x00-\x1f]') {
    throw 'OutputDirectory must be an absolute local Windows path.'
}
if (-not (Test-Path -LiteralPath $NuGetConfigPath -PathType Leaf)) {
    throw 'NuGetConfigPath must reference an existing package-source configuration.'
}

$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
if ($OutputDirectory.TrimEnd('\') -eq [System.IO.Path]::GetPathRoot($OutputDirectory).TrimEnd('\')) {
    throw 'OutputDirectory must be a build-artifact directory, not a filesystem root.'
}
$NuGetConfigPath = (Resolve-Path -LiteralPath $NuGetConfigPath).ProviderPath
$archiveName = "LinuxBroker.Launcher-$Version-win-x64.zip"
$bundlePath = Join-Path $OutputDirectory $archiveName
$stageName = '.launcher-build-' + [guid]::NewGuid().ToString('N')
$stagingDirectory = Join-Path $OutputDirectory $stageName
$publishDirectory = Join-Path $stagingDirectory 'bundle'
$temporaryArchive = Join-Path $stagingDirectory $archiveName
$launcherProject = Join-Path $PSScriptRoot 'launcher\LinuxBroker.Launcher.csproj'
$testProject = Join-Path $PSScriptRoot 'tests\LinuxBroker.Launcher.Tests.csproj'
$versionArgument = "-p:Version=$Version"
$stageCreated = $false

Push-Location $PSScriptRoot
try {
    $requiredSdk = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'global.json') -Raw | ConvertFrom-Json).sdk.version
    $actualSdk = & $DotNetPath --version
    if ($LASTEXITCODE -ne 0 -or $actualSdk -ne $requiredSdk) {
        throw "Install .NET SDK $requiredSdk to build this version of the launcher."
    }

    & (Join-Path $PSScriptRoot 'tests\Test-PowerShell.ps1')
    Invoke-DotNet -Arguments @('restore', $testProject, '--runtime', 'win-x64', '--locked-mode', '--configfile', $NuGetConfigPath, '--nologo', '--verbosity', 'minimal')
    Invoke-DotNet -Arguments @('build', $testProject, '--configuration', 'Release', '--runtime', 'win-x64', '--no-restore', '--nologo', '--verbosity', 'minimal', $versionArgument)
    Invoke-DotNet -Arguments @('test', $testProject, '--configuration', 'Release', '--runtime', 'win-x64', '--no-build', '--no-restore', '--nologo', '--verbosity', 'minimal', $versionArgument)

    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $null = New-Item -ItemType Directory -Path $stagingDirectory
    $stageCreated = $true
    Invoke-DotNet -Arguments @('restore', $launcherProject, '--runtime', 'win-x64', '-p:SelfContained=true', '--locked-mode', '--configfile', $NuGetConfigPath, '--nologo', '--verbosity', 'minimal')
    Invoke-DotNet -Arguments @('publish', $launcherProject, '--configuration', 'Release', '--runtime', 'win-x64', '--self-contained', 'true', '--no-restore', '--output', $publishDirectory, '--nologo', '--verbosity', 'minimal', $versionArgument, '-p:ContinuousIntegrationBuild=true')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Connect-LinuxBroker.ps1') -Destination $publishDirectory
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Destination $publishDirectory

    foreach ($required in @('LinuxBroker.Launcher.exe', 'LinuxBroker.Launcher.dll', 'LinuxBroker.Launcher.deps.json',
        'LinuxBroker.Launcher.runtimeconfig.json', 'Microsoft.Identity.Client.dll', 'Microsoft.Identity.Client.Broker.dll', 'Microsoft.Identity.Client.NativeInterop.dll',
        'coreclr.dll', 'System.Windows.Forms.dll', 'Connect-LinuxBroker.ps1', 'README.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $publishDirectory $required) -PathType Leaf)) {
            throw "Self-contained publish is incomplete: missing $required."
        }
    }
    if (Test-Path -LiteralPath (Join-Path $publishDirectory 'launcher.json')) {
        throw 'A populated launcher.json must never be shipped in the bundle.'
    }
    $wamNative = @(Get-ChildItem -LiteralPath $publishDirectory -Recurse -File -Filter 'msalruntime.dll')
    if ($wamNative.Count -eq 0) {
        throw 'The WAM native runtime dependency is missing from publish output.'
    }
    $runtimeConfig = Get-Content -LiteralPath (Join-Path $publishDirectory 'LinuxBroker.Launcher.runtimeconfig.json') -Raw | ConvertFrom-Json
    if ($null -ne $runtimeConfig.runtimeOptions.PSObject.Properties['framework'] -or
        $null -ne $runtimeConfig.runtimeOptions.PSObject.Properties['frameworks'] -or
        $null -eq $runtimeConfig.runtimeOptions.PSObject.Properties['includedFrameworks']) {
        throw 'The output depends on a shared .NET runtime instead of being self-contained.'
    }

    Add-Type -AssemblyName System.IO.Compression
    $archiveStream = [System.IO.File]::Open($temporaryArchive, [System.IO.FileMode]::CreateNew)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($archiveStream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            $files = [System.IO.Directory]::GetFiles($publishDirectory, '*', [System.IO.SearchOption]::AllDirectories)
            [Array]::Sort($files, [StringComparer]::Ordinal)
            $timestamp = [DateTimeOffset]::Parse('2000-01-01T00:00:00Z', [Globalization.CultureInfo]::InvariantCulture)
            foreach ($file in $files) {
                $entryName = $file.Substring($publishDirectory.Length + 1).Replace('\', '/')
                $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $timestamp
                $entry.ExternalAttributes = 0
                $inputStream = [System.IO.File]::OpenRead($file)
                $entryStream = $entry.Open()
                try {
                    $inputStream.CopyTo($entryStream)
                }
                finally {
                    $entryStream.Dispose()
                    $inputStream.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $archiveStream.Dispose()
    }

    Move-Item -LiteralPath $temporaryArchive -Destination $bundlePath -Force
    $hash = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash
    [PSCustomObject]@{
        BundlePath = $bundlePath
        Sha256 = $hash
        Version = $Version
        Runtime = 'win-x64'
    }
}
finally {
    Pop-Location
    # Only this invocation's newly created, resolved staging child may be removed.
    if ($stageCreated -and
        [System.IO.Path]::GetDirectoryName($stagingDirectory) -eq $OutputDirectory.TrimEnd('\') -and
        [System.IO.Path]::GetFileName($stagingDirectory) -eq $stageName -and
        $stageName -match '^\.launcher-build-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
    }
}
