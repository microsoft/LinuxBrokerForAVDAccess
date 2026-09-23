[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SqlServerFqdn,
    [Parameter(Mandatory)][string]$DatabaseName,
    [Parameter(Mandatory)][string]$SqlAdminLogin,
    [Parameter(Mandatory)][string]$SqlAdminPassword,
    [Parameter(Mandatory)][string]$RuntimeUsername,
    [Parameter(Mandatory)][string]$RuntimePassword
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Broker.DatabaseRuntime.ps1"
if ($DatabaseName -in @('master', 'model', 'msdb', 'tempdb')) { throw 'Runtime users must be provisioned only in the explicitly selected broker database, not a system database.' }
Assert-BrokerRuntimeDatabaseIdentity -Username $RuntimeUsername -Password $RuntimePassword -DeploymentUsername $SqlAdminLogin
if ($RuntimePassword -ceq $SqlAdminPassword) { throw 'The runtime SQL user must not reuse the deployment administrator password.' }
$deployment = New-BrokerSqlConnection -Server $SqlServerFqdn -Database $DatabaseName -Username $SqlAdminLogin -Password $SqlAdminPassword
try {
    $deployment.Open()
    Initialize-BrokerRuntimeUser -Connection $deployment -Username $RuntimeUsername -Password $RuntimePassword -DeploymentUsername $SqlAdminLogin
}
finally { $deployment.Dispose() }
$runtime = New-BrokerSqlConnection -Server $SqlServerFqdn -Database $DatabaseName -Username $RuntimeUsername -Password $RuntimePassword
try {
    $runtime.Open()
    Test-BrokerRuntimeDatabaseAccess -Connection $runtime -ExpectedUsername $RuntimeUsername
}
finally { $runtime.Dispose() }
Write-Host 'Verified a dedicated contained BrokerApiRuntime SQL user; deployment-only procedures and direct VM writes are denied.'
