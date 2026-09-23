[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MappingPath,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$SqlServerFqdn,
    [Parameter(Mandatory)][string]$DatabaseName,
    [Parameter(Mandatory)][string]$SqlAdminLogin,
    [Parameter(Mandatory)][string]$SqlAdminPassword,
    [string]$GraphEndpoint,
    [string]$LinuxHostAdminLoginName = 'avdadmin',
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Broker.UserMapping.ps1"
$TenantId = Assert-BrokerGuid $TenantId 'TenantId'
$mapping = Read-BrokerUserMapping -Path $MappingPath -TenantId $TenantId -ReservedUsernames @($LinuxHostAdminLoginName)
Test-BrokerUserMapping -Mapping $mapping -GraphEndpoint (Get-BrokerGraphEndpoint $GraphEndpoint)
$connection = New-BrokerSqlConnection -Server $SqlServerFqdn -Database $DatabaseName -Username $SqlAdminLogin -Password $SqlAdminPassword
try {
    $connection.Open()
    Invoke-BrokerUserMapping -Connection $connection -Mapping $mapping -DryRun:$DryRun
}
finally { $connection.Dispose() }
if ($DryRun) { Write-Host 'Reviewed mapping dry run succeeded; SQL changes were rolled back.' }
else { Write-Host 'Reviewed identity bindings committed without changing Linux names, UIDs, or profiles.' }
