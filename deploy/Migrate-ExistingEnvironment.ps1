[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentName,
    [string]$AccessConfigPath,
    [string]$UserMappingPath,
    [string]$ResourceGroupName,
    [string]$ApiBaseUrl,
    [string]$SqlServerFqdn,
    [string]$DatabaseName,
    [string]$SqlAdminLogin,
    [string]$SqlAdminPassword,
    [string]$LauncherPackageUri,
    [string]$LauncherPackageSha256,
    [string]$LauncherPackagePath,
    [string]$LauncherVersion,
    [switch]$EnrollDrainedLegacyHosts,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
# Both new and existing environments use the same guarded activation sequence.
& "$PSScriptRoot\Post-Provision.ps1" @PSBoundParameters -ExistingEnvironment
