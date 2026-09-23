#requires -Version 7.4
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'Broker.DatabaseRuntime.ps1')
$script:checks = 0
function Check {
    param([bool]$Condition, [string]$Message)
    $script:checks++
    if (-not $Condition) { throw "Runtime SQL check failed: $Message" }
}
function Reject {
    param([scriptblock]$Action)
    $script:checks++
    try { & $Action; throw 'Expected runtime database rejection was not raised.' }
    catch {
        if ($_.Exception.Message -eq 'Expected runtime database rejection was not raised.') { throw }
    }
}

$password = "synthetic-O'Brien-runtime-credential-42!"
$offlineConnection = New-BrokerSqlConnection -Server 'offline-sql.example' -Database 'OfflineBrokerTest' `
    -Username brokerapi -Password ($password + ';quoted=value')
try {
    Check ($offlineConnection.State -eq [Data.ConnectionState]::Closed -and
        $offlineConnection.DataSource -eq 'tcp:offline-sql.example,1433' -and
        $offlineConnection.Database -eq 'OfflineBrokerTest') 'Production SqlClient connection construction works without a network connection.'
    $builder = [Data.SqlClient.SqlConnectionStringBuilder]::new($offlineConnection.ConnectionString)
    Check ($builder['User ID'] -eq 'brokerapi' -and $builder['Password'] -ceq ($password + ';quoted=value')) 'Canonical indexers preserve quoted/semicolon credential data.'
    Check ($builder['Encrypt'] -eq $true -and $builder['TrustServerCertificate'] -eq $false) 'The production connection requires TLS and certificate validation.'
    Check ($builder['Persist Security Info'] -eq $false -and $builder['Connect Timeout'] -eq 30) 'Sensitive connection info is not persisted.'
}
finally { $offlineConnection.Dispose() }
Assert-BrokerRuntimeDatabaseIdentity -Username brokerapi -Password $password -DeploymentUsername brokeradmin
foreach ($name in @('dbo', 'guest', 'BrokerApiRuntime', 'brokeradmin', "user'; DROP TABLE x;--")) {
    Reject { Assert-BrokerRuntimeDatabaseIdentity -Username $name -Password $password -DeploymentUsername brokeradmin }
}
Reject { Assert-BrokerRuntimeDatabaseIdentity -Username brokerapi -Password 'short' -DeploymentUsername brokeradmin }
Reject {
    & (Join-Path (Split-Path -Parent $PSScriptRoot) 'Initialize-BrokerRuntimeDatabaseUser.ps1') `
        -SqlServerFqdn 'not-contacted.example' -DatabaseName fixture -SqlAdminLogin brokeradmin `
        -SqlAdminPassword $password -RuntimeUsername brokerapi -RuntimePassword $password
}

$script:executedCommands = [Collections.Generic.List[object]]::new()
$script:runtimePermissions = @{
    RuntimeUsername = 'brokerapi'; RuntimeRole = 1; CanReadInventory = 1
    DatabaseOwner = 0; CanBindUser = 0; CanRegisterHost = 0; CanRegisterInventory = 0
    CanReadMigration = 0; CanWriteVmTable = 0; CanControlDatabase = 0
    CanWriteTrustedInventory = 0; CanWriteHostBinding = 0
}
function New-FakeCommand {
    $parameters = [Collections.Generic.List[object]]::new()
    $parameterCollection = [pscustomobject]@{ Values = $parameters }
    $parameterCollection | Add-Member -MemberType ScriptMethod -Name Add -Value {
        param($name, $type, $size)
        $parameter = [pscustomobject]@{ ParameterName = $name; SqlDbType = $type; Size = $size; Value = $null }
        $this.Values.Add($parameter)
        return $parameter
    }
    $command = [pscustomobject]@{ CommandText = ''; CommandTimeout = 0; Parameters = $parameterCollection }
    $command | Add-Member -MemberType ScriptMethod -Name ExecuteNonQuery -Value {
        $script:executedCommands.Add($this)
        return 0
    }
    $command | Add-Member -MemberType ScriptMethod -Name ExecuteReader -Value {
        $table = [Data.DataTable]::new()
        foreach ($name in $script:runtimePermissions.Keys) { $null = $table.Columns.Add($name, [object]) }
        $row = $table.NewRow()
        foreach ($name in $script:runtimePermissions.Keys) { $row[$name] = $script:runtimePermissions[$name] }
        $table.Rows.Add($row)
        return ,$table.CreateDataReader()
    }
    $command | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
    return $command
}
$connection = [pscustomobject]@{}
$connection | Add-Member -MemberType ScriptMethod -Name CreateCommand -Value { New-FakeCommand }
Initialize-BrokerRuntimeUser -Connection $connection -Username brokerapi -Password $password -DeploymentUsername brokeradmin
Initialize-BrokerRuntimeUser -Connection $connection -Username brokerapi -Password $password -DeploymentUsername brokeradmin
Check ($script:executedCommands.Count -eq 2) 'The same runtime principal can be provisioned again through the guarded path.'
$command = $script:executedCommands[0]
Check (-not $command.CommandText.Contains($password)) 'Passwords must be SQL parameters, not rendered command text.'
Check ($command.Parameters.Values.Count -eq 2) 'Only runtime username/password parameters are supplied.'
Check (@($command.Parameters.Values | Where-Object { $_.ParameterName -eq '@RuntimePassword' -and $_.Value -ceq $password }).Count -eq 1) 'Password quotes are preserved as parameter data.'
Check ($command.CommandText.Contains('QUOTENAME(@RuntimeName)') -and $command.CommandText.Contains("QUOTENAME(@RuntimePassword, '''')")) 'Dynamic SQL quotes identifiers and password literals on the server.'
Check ($command.CommandText.Contains('IS_ROLEMEMBER(N''BrokerApiRuntime'') = 1')) 'Deployment-role membership is rejected before provisioning.'
Check ($command.CommandText.Contains('member_principal_id = @UserId AND role_principal_id <> @RoleId')) 'Additional existing-user roles cannot be silently retained.'
Check ($command.CommandText.Contains('authentication_type_desc = N''DATABASE''')) 'Only a contained database SQL user can be reused.'
Check ($command.CommandText.Contains('GRANT') -eq $false) 'No broad database/schema/table grant is issued.'
Check ($command.CommandText.Contains('ALTER ROLE BrokerApiRuntime ADD MEMBER')) 'Only the explicit runtime role is assigned.'
Test-BrokerRuntimeDatabaseAccess -Connection $connection -ExpectedUsername brokerapi
foreach ($permission in @('DatabaseOwner', 'CanBindUser', 'CanRegisterHost', 'CanRegisterInventory',
        'CanReadMigration', 'CanWriteVmTable', 'CanWriteTrustedInventory', 'CanWriteHostBinding', 'CanControlDatabase')) {
    $script:runtimePermissions[$permission] = 1
    Reject { Test-BrokerRuntimeDatabaseAccess -Connection $connection -ExpectedUsername brokerapi }
    $script:runtimePermissions[$permission] = 0
}
$script:runtimePermissions.RuntimeUsername = 'dbo'
Reject { Test-BrokerRuntimeDatabaseAccess -Connection $connection -ExpectedUsername brokerapi }
$script:runtimePermissions.RuntimeUsername = 'brokerapi'
$script:runtimePermissions.RuntimeRole = 0
Reject { Test-BrokerRuntimeDatabaseAccess -Connection $connection -ExpectedUsername brokerapi }

$script:secretOperations = [Collections.Generic.List[object]]::new()
$script:privateFiles = [Collections.Generic.List[string]]::new()
function Invoke-BrokerAz {
    param($Arguments, $Operation, [switch]$Raw, [switch]$NoOutput)
    $script:secretOperations.Add($Arguments)
    switch ($Arguments[2]) {
        'set' {
            $file = $Arguments[[array]::IndexOf($Arguments, '--file') + 1]
            $script:privateFiles.Add($file)
            Check ([IO.File]::ReadAllText($file) -ceq $password) 'Key Vault upload file contains the exact runtime credential.'
            Check ($Arguments -contains '--query' -and $Raw) 'Only the new secret ID may be returned, not its value.'
            return 'https://vault.example/secrets/db-password/newversion'
        }
        'list-versions' {
            return @(
                @{ id = 'https://vault.example/secrets/db-password/oldadmin'; attributes = @{ enabled = $true } },
                @{ id = 'https://vault.example/secrets/db-password/newversion'; attributes = @{ enabled = $true } }
            )
        }
        'set-attributes' {
            Check ($Arguments -contains 'https://vault.example/secrets/db-password/oldadmin' -and
                $Arguments -contains 'false' -and $NoOutput) 'Superseded admin-bearing secret version must be disabled.'
        }
        default { throw 'Unexpected live/unsupported Azure boundary.' }
    }
}
Set-BrokerRuntimeDatabaseSecret -KeyVaultName vault -Password $password
Check ($script:secretOperations.Count -eq 3) 'Only the runtime secret and its obsolete versions are touched.'
Check (@($script:privateFiles | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) 'Secret-bearing temporary files are removed.'
Write-Host "PASS: $script:checks dedicated runtime database checks with SQL/Azure boundaries mocked."
