#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^LinuxBrokerAuth_[A-Za-z0-9_]+$')]
    [string]$InstanceName,

    [Parameter(Mandatory)][ValidatePattern('^LinuxBrokerAuthorizationTests_[A-Za-z0-9_]+$')]
    [string]$DatabaseName,

    [Parameter(Mandatory)][string]$SqlLocalDbExe
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'deploy\Broker.DatabaseRuntime.ps1')

$instanceInfo = & $SqlLocalDbExe info $InstanceName 2>&1
if ($LASTEXITCODE -ne 0 -or ($instanceInfo -join "`n") -notmatch '(?m)^State:\s+Running\s*$') {
    throw 'The caller must start the isolated LocalDB instance; this test never starts one.'
}
$pipeLines = @($instanceInfo | Where-Object { "$_" -match '^Instance pipe name:\s+' })
if ($pipeLines.Count -ne 1) { throw 'The isolated LocalDB pipe could not be determined.' }
$pipe = ([string]$pipeLines[0] -replace '^Instance pipe name:\s+', '').Trim()
if ($pipe -notmatch '^np:\\\\\.\\pipe\\LOCALDB#[A-Za-z0-9]+\\tsql\\query$') {
    throw 'Refusing a non-local SQL endpoint.'
}

$builder = [Data.SqlClient.SqlConnectionStringBuilder]::new()
$builder['Data Source'] = $pipe
$builder['Initial Catalog'] = $DatabaseName
$builder['Integrated Security'] = $true
$builder['TrustServerCertificate'] = $true
$builder['Pooling'] = $false
$builder['Connect Timeout'] = 15
$deployment = [Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
$runtimeName = 'brokerapi_test_' + [guid]::NewGuid().ToString('N')
$password = 'Aa1!' + [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
$rotatedPassword = 'Aa1!' + [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
$owned = $false

function Open-RuntimeTestConnection([string]$PasswordValue) {
    $runtimeBuilder = [Data.SqlClient.SqlConnectionStringBuilder]::new($builder.ConnectionString)
    $runtimeBuilder['Integrated Security'] = $false
    $runtimeBuilder['User ID'] = $runtimeName
    $runtimeBuilder['Password'] = $PasswordValue
    $connection = [Data.SqlClient.SqlConnection]::new($runtimeBuilder.ConnectionString)
    try {
        $connection.Open()
        return $connection
    }
    catch [Data.SqlClient.SqlException] {
        $connection.Dispose()
        throw 'The dedicated contained runtime login did not succeed.'
    }
}

try {
    $deployment.Open()
    $command = $deployment.CreateCommand()
    try {
        $command.CommandText = "SELECT CONVERT(nvarchar(4000), value) FROM sys.extended_properties WHERE class=0 AND name=N'LinuxBroker.IntegrationHarness';"
        if ($command.ExecuteScalar() -cne "v1:$InstanceName/$DatabaseName") {
            throw 'Run the SQL integration harness first; its exact instance/database ownership marker is required.'
        }
        $command.CommandText = 'SELECT containment FROM sys.databases WHERE database_id=DB_ID();'
        if ($command.ExecuteScalar() -ne 1) {
            throw 'The caller must enable containment on this dedicated test database.'
        }
    }
    finally { $command.Dispose() }

    Initialize-BrokerRuntimeUser -Connection $deployment -Username $runtimeName -Password $password -DeploymentUsername deployment_test
    $owned = $true
    $runtime = Open-RuntimeTestConnection $password
    try { Test-BrokerRuntimeDatabaseAccess -Connection $runtime -ExpectedUsername $runtimeName }
    finally { $runtime.Dispose() }

    Initialize-BrokerRuntimeUser -Connection $deployment -Username $runtimeName -Password $password -DeploymentUsername deployment_test
    Initialize-BrokerRuntimeUser -Connection $deployment -Username $runtimeName -Password $rotatedPassword -DeploymentUsername deployment_test
    $runtime = Open-RuntimeTestConnection $rotatedPassword
    try {
        Test-BrokerRuntimeDatabaseAccess -Connection $runtime -ExpectedUsername $runtimeName
        $command = $runtime.CreateCommand()
        try {
            $command.CommandText = 'EXEC dbo.GetVms;'
            $reader = $command.ExecuteReader()
            $reader.Dispose()
            foreach ($deniedStatement in @(
                    'UPDATE dbo.VirtualMachines SET Description=Description WHERE 1=0;',
                    'EXEC dbo.BindBrokerUser;',
                    'EXEC dbo.RegisterBrokerHost;')) {
                $command.CommandText = $deniedStatement
                $denied = $false
                try { [void]$command.ExecuteNonQuery() }
                catch [Data.SqlClient.SqlException] { $denied = $_.Exception.Number -eq 229 }
                if (-not $denied) {
                    throw 'A deployment-only operation was not denied to the real runtime login.'
                }
            }
        }
        finally { $command.Dispose() }
    }
    finally { $runtime.Dispose() }

    Write-Output 'PASS: actual contained-user creation, idempotent rerun, rotation, login, inventory access, and deployment/write denials.'
}
finally {
    try {
        if ($owned -and $deployment.State -eq [Data.ConnectionState]::Open) {
            $command = $deployment.CreateCommand()
            try {
                $command.CommandText = "DROP USER [$runtimeName];"
                [void]$command.ExecuteNonQuery()
            }
            finally { $command.Dispose() }
        }
    }
    finally { $deployment.Dispose() }
}
