#Requires -Version 7.4
<#
.SYNOPSIS
Runs real broker migrations and concurrent SQL operations in one dedicated LocalDB test database.
.DESCRIPTION
The caller owns and starts the named isolated instance. This harness never creates, starts,
stops or deletes a LocalDB instance and never accepts a server or connection string.
The caller also creates the initially empty test database. Only that database's marked test
schema is reset between cases; no database is created or dropped. No Azure credentials are used.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^LinuxBrokerAuth_[A-Za-z0-9_]+$')]
    [string]$InstanceName,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^LinuxBrokerAuthorizationTests_[A-Za-z0-9_]+$')]
    [string]$DatabaseName,

    [string]$SqlLocalDbExe = 'C:\Program Files\Microsoft SQL Server\150\Tools\Binn\SqlLocalDB.exe',

    [ValidateSet('fresh', 'legacy', 'identity-concurrency', 'reserved-uids', 'checkout-concurrency', 'reconnect',
        'grace', 'return-race', 'cleanup-retry', 'operation-recovery', 'scaling', 'generation', 'generation-bounds', 'host-endpoint-binding', 'host-enrollment-upgrade', 'idle-tombstone-evidence', 'runtime-permissions')]
    [string[]]$Case = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Data

if (-not (Test-Path -LiteralPath $SqlLocalDbExe -PathType Leaf)) {
    throw 'SQL LocalDB tooling is unavailable. Supply the installed SqlLocalDbExe path.'
}
$instanceInfo = & $SqlLocalDbExe info $InstanceName 2>&1
if ($LASTEXITCODE -ne 0 -or ($instanceInfo -join "`n") -notmatch '(?m)^State:\s+Running\s*$') {
    throw "The isolated instance '$InstanceName' must already be running. This harness will not start it."
}
$pipeLine = @($instanceInfo | Where-Object { "$_" -match '^Instance pipe name:\s+' })
if ($pipeLine.Count -ne 1) { throw 'The existing LocalDB instance pipe could not be determined.' }
$script:LocalDbPipe = ([string]$pipeLine[0] -replace '^Instance pipe name:\s+', '').Trim()
if ($script:LocalDbPipe -notmatch '^np:\\\\\.\\pipe\\LOCALDB#[A-Za-z0-9]+\\tsql\\query$') {
    throw 'Refusing an unexpected or non-local SQL pipe.'
}

$script:ScriptsPath = Split-Path -Parent $PSScriptRoot
$script:Tenant = [guid]'11111111-1111-4111-8111-111111111111'
$script:Actor = [guid]'22222222-2222-4222-8222-222222222222'
$script:Database = $DatabaseName
$script:AllowedDatabase = $DatabaseName
$script:OwnershipMarker = "v1:$InstanceName/$DatabaseName"
$script:Passed = 0
$script:RaceCount = 0

function New-TestConnection {
    param([Parameter(Mandatory = $true)][string]$DatabaseName)
    if ($DatabaseName -cne $script:AllowedDatabase) {
        throw 'Refusing a connection outside the explicitly supplied test database.'
    }
    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    # Pin the already-running instance's pipe; unlike the friendly (localdb) alias,
    # this cannot implicitly restart an instance that stops between checks.
    $builder['Data Source'] = $script:LocalDbPipe
    $builder['Initial Catalog'] = $DatabaseName
    $builder['Integrated Security'] = $true
    $builder['TrustServerCertificate'] = $true
    $builder['Pooling'] = $false
    $builder['Connect Timeout'] = 15
    $builder['Application Name'] = 'LinuxBroker.IsolatedAuthorizationTests'
    $connection = [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
    try {
        $connection.Open()
        return $connection
    }
    catch {
        $connection.Dispose()
        throw
    }
}

function New-TestCommand {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [string]$Sql,
        [System.Collections.IDictionary]$Parameters = @{},
        [switch]$Procedure
    )
    $command = $Connection.CreateCommand()
    $command.CommandText = $Sql
    $command.CommandTimeout = 45
    if ($Procedure) {
        $command.CommandType = [System.Data.CommandType]::StoredProcedure
    }
    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        if ($null -eq $value) { $value = [DBNull]::Value }
        [void]$command.Parameters.AddWithValue("@$key", $value)
    }
    return $command
}

function Read-TestRows {
    param([System.Data.SqlClient.SqlDataReader]$Reader)
    do {
        while ($Reader.Read()) {
            $row = [ordered]@{}
            for ($index = 0; $index -lt $Reader.FieldCount; $index++) {
                $value = $Reader.GetValue($index)
                if ($value -is [DBNull]) { $value = $null }
                $row[$Reader.GetName($index)] = $value
            }
            [pscustomobject]$row
        }
    } while ($Reader.NextResult())
}

function Invoke-TestSql {
    param(
        [Parameter(Mandatory = $true)][string]$Sql,
        [System.Collections.IDictionary]$Parameters = @{},
        [switch]$Procedure
    )
    $connection = New-TestConnection $script:Database
    $command = $null
    $reader = $null
    try {
        $command = New-TestCommand -Connection $connection -Sql $Sql -Parameters $Parameters -Procedure:$Procedure
        $reader = $command.ExecuteReader()
        Read-TestRows $reader
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $command) { $command.Dispose() }
        $connection.Dispose()
    }
}

function Invoke-TestProcedure {
    param([string]$Name, [System.Collections.IDictionary]$Parameters = @{})
    Invoke-TestSql -Sql "dbo.$Name" -Parameters $Parameters -Procedure
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    $different = if ($Actual -is [string] -and $Expected -is [string]) {
        $Actual -cne $Expected
    } else {
        $Actual -ne $Expected
    }
    if ($different) {
        throw "Assertion failed: $Message (expected '$Expected'; actual '$Actual')."
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-SqlError {
    param([scriptblock]$Action, [int]$Number = 51000)
    try {
        & $Action | Out-Null
    }
    catch {
        $failure = $_.Exception.GetBaseException()
        if ($failure -isnot [System.Data.SqlClient.SqlException] -or $failure.Number -ne $Number) {
            throw
        }
        return
    }
    throw "Expected SQL error $Number was not raised."
}

function Apply-TestMigrations {
    param([int]$First = 1, [int]$Last = 999)
    foreach ($file in Get-ChildItem -LiteralPath $script:ScriptsPath -Filter '*.sql' | Sort-Object Name) {
        $number = [int]$file.Name.Split('_')[0]
        if ($number -lt $First -or $number -gt $Last) { continue }
        $content = Get-Content -LiteralPath $file.FullName -Raw
        $content = [regex]::Replace($content, '(?im)^(\s*)(?:CREATE|ALTER)\s+PROCEDURE\b', '$1CREATE OR ALTER PROCEDURE')
        $batchNumber = 0
        foreach ($batch in [regex]::Split($content, '(?im)^\s*GO\s*(?:--[^\n]*)?$')) {
            if ([string]::IsNullOrWhiteSpace($batch)) { continue }
            $batchNumber++
            try {
                Invoke-TestSql -Sql $batch | Out-Null
            }
            catch {
                throw "Migration $($file.Name), batch $batchNumber failed: $($_.Exception.GetBaseException().Message)"
            }
        }
    }
}

function New-ProcedureWork {
    param([string]$Name, [System.Collections.IDictionary]$Parameters)
    [pscustomobject]@{ Name = $Name; Parameters = $Parameters }
}

function Invoke-SqlRace {
    param([Parameter(Mandatory = $true)][object[]]$Work)
    # Every worker has an independent real SQL connection. Hold the application's own
    # transaction lock until DMVs prove all workers are waiting, then release them together.
    $gate = New-TestConnection $script:Database
    $workers = [System.Collections.Generic.List[object]]::new()
    $gateCommand = $null
    try {
        $gateCommand = New-TestCommand $gate 'BEGIN TRANSACTION; EXEC dbo.LockBrokerState;'
        [void]$gateCommand.ExecuteNonQuery()
        foreach ($item in $Work) {
            $connection = New-TestConnection $script:Database
            $spidCommand = New-TestCommand $connection 'SELECT @@SPID'
            try { $spid = [int]$spidCommand.ExecuteScalar() } finally { $spidCommand.Dispose() }
            $command = New-TestCommand -Connection $connection -Sql "dbo.$($item.Name)" -Parameters $item.Parameters -Procedure
            $worker = [pscustomobject]@{ Connection = $connection; Command = $command; Task = $null; Spid = $spid; Reader = $null }
            $workers.Add($worker)
            $worker.Task = $command.ExecuteReaderAsync()
        }
        $spids = ($workers | ForEach-Object { [string]$_.Spid }) -join ','
        $waitingCommand = New-TestCommand $gate @"
SELECT COUNT(DISTINCT request_session_id) FROM sys.dm_tran_locks
WHERE resource_database_id = DB_ID() AND resource_type = 'APPLICATION'
  AND request_status = 'WAIT' AND request_session_id IN ($spids)
"@
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(7)
            do {
                $waiting = [int]$waitingCommand.ExecuteScalar()
                if ($waiting -eq $Work.Count) { break }
                Start-Sleep -Milliseconds 20
            } while ([DateTime]::UtcNow -lt $deadline)
            Assert-Equal $waiting $Work.Count 'All competing SQL sessions must reach the durable lock before release'
        }
        finally { $waitingCommand.Dispose() }
        $gateCommand.CommandText = 'COMMIT TRANSACTION;'
        [void]$gateCommand.ExecuteNonQuery()
        $script:RaceCount++
        foreach ($worker in $workers) {
            $worker.Reader = $worker.Task.GetAwaiter().GetResult()
            $rows = @(Read-TestRows $worker.Reader)
            Assert-Equal $rows.Count 1 'Each raced procedure must produce exactly one result row'
            $rows[0]
        }
    }
    finally {
        # A disconnected gate rolls back its transaction, including on test failures.
        if ($null -ne $gateCommand) { $gateCommand.Dispose() }
        $gate.Dispose()
        foreach ($worker in $workers) {
            if ($null -ne $worker.Reader) { $worker.Reader.Dispose() }
            if ($null -ne $worker.Task -and -not $worker.Task.IsCompleted) { $worker.Command.Cancel() }
            $worker.Command.Dispose()
            $worker.Connection.Dispose()
        }
    }
}

function Register-TestHost {
    param([int]$Number = 1)
    $hostname = 'linux-{0:00}' -f $Number
    $row = Invoke-TestProcedure RegisterLinuxHostVm @{ Hostname = $hostname; IPAddress = "192.0.2.$Number" }
    Invoke-TestProcedure RegisterBrokerHost @{
        TenantId = $script:Tenant; ObjectId = [guid]::NewGuid(); Hostname = $hostname
        ResourceId = "/subscriptions/$script:Tenant/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/$hostname"
    } | Out-Null
    return $row.VMID
}

function Checkout-TestLease {
    param([guid]$Subject = $script:Actor)
    Invoke-TestProcedure BeginBrokerCheckout @{ TenantId = $script:Tenant; ObjectId = $Subject; AvdHost = 'avd-test' }
}

function Complete-TestOperation {
    param($Row, [string]$Outcome = 'ready')
    Invoke-TestProcedure CompleteBrokerOperation @{
        VMID = $Row.VMID; OperationId = $Row.OperationId; LeaseGeneration = $Row.LeaseGeneration; Outcome = $Outcome
    }
}

function Observe-TestLease {
    param($Row, [string]$State)
    Invoke-TestProcedure ObserveBrokerSession @{
        Hostname = $Row.Hostname; LeaseId = $Row.LeaseId; LeaseGeneration = $Row.LeaseGeneration; State = $State
    }
}

function Get-CleanupParameters {
    param($Row, [string]$Reason = 'admin')
    @{
        VMID = $Row.VMID; ExpectedLeaseId = $Row.LeaseId; ExpectedLeaseGeneration = $Row.LeaseGeneration
        Reason = $Reason; ActorTenantId = $script:Tenant; ActorObjectId = $script:Actor
    }
}

function Begin-TestCleanup {
    param($Row, [string]$Reason = 'admin')
    Invoke-TestProcedure BeginBrokerCleanup (Get-CleanupParameters $Row $Reason)
}

function Assert-TestDatabaseOwnership {
    $marker = @(Invoke-TestSql @"
SELECT CONVERT(NVARCHAR(4000), value) AS Marker
FROM sys.extended_properties WHERE class=0 AND name=N'LinuxBroker.IntegrationHarness'
"@)
    if ($marker.Count -eq 0) {
        $objects = Invoke-TestSql 'SELECT COUNT(*) AS ObjectCount FROM sys.objects WHERE is_ms_shipped=0'
        Assert-Equal $objects.ObjectCount 0 'A previously unmarked test database must be empty'
        Invoke-TestSql "EXEC sys.sp_addextendedproperty @name=N'LinuxBroker.IntegrationHarness', @value=@Marker" @{ Marker = $script:OwnershipMarker }
    } else {
        Assert-Equal $marker[0].Marker $script:OwnershipMarker 'Test schema ownership must match this exact instance/database'
    }
}

function Reset-TestSchema {
    Assert-TestDatabaseOwnership
    $objects = @(Invoke-TestSql @"
SELECT QUOTENAME(SCHEMA_NAME(schema_id))+'.'+QUOTENAME(name) AS QualifiedName, type AS ObjectType
FROM sys.objects WHERE is_ms_shipped=0 AND type IN ('P','PC','V','TR','FN','IF','TF')
ORDER BY CASE WHEN type='TR' THEN 0 WHEN type='V' THEN 1 ELSE 2 END, name
"@)
    foreach ($object in $objects) {
        $kind = switch ($object.ObjectType.Trim()) {
            'P' { 'PROCEDURE' }
            'PC' { 'PROCEDURE' }
            'V' { 'VIEW' }
            'TR' { 'TRIGGER' }
            default { 'FUNCTION' }
        }
        Invoke-TestSql "DROP $kind $($object.QualifiedName)" | Out-Null
    }
    $temporal = @(Invoke-TestSql "SELECT QUOTENAME(SCHEMA_NAME(schema_id))+'.'+QUOTENAME(name) AS QualifiedName FROM sys.tables WHERE is_ms_shipped=0 AND temporal_type=2")
    foreach ($table in $temporal) {
        Invoke-TestSql "ALTER TABLE $($table.QualifiedName) SET (SYSTEM_VERSIONING=OFF)" | Out-Null
    }
    $tables = @(Invoke-TestSql "SELECT QUOTENAME(SCHEMA_NAME(schema_id))+'.'+QUOTENAME(name) AS QualifiedName FROM sys.tables WHERE is_ms_shipped=0")
    foreach ($table in $tables) {
        Invoke-TestSql "DROP TABLE $($table.QualifiedName)" | Out-Null
    }
    Invoke-TestSql @"
IF DATABASE_PRINCIPAL_ID('BrokerRuntimeTest') IS NOT NULL DROP USER BrokerRuntimeTest;
IF DATABASE_PRINCIPAL_ID('BrokerManagementTest') IS NOT NULL DROP USER BrokerManagementTest;
IF DATABASE_PRINCIPAL_ID('BrokerApiRuntime') IS NOT NULL DROP ROLE BrokerApiRuntime;
"@ | Out-Null
}

function Invoke-Case {
    param([string]$Name, [scriptblock]$Body, [int]$SchemaThrough = 999)
    if ($Case.Count -gt 0 -and $Case -notcontains $Name) { return }
    Reset-TestSchema
    Apply-TestMigrations -Last $SchemaThrough
    & $Body | Out-Null
    $script:Passed++
    Write-Host "PASS $Name"
}

$server = Invoke-TestSql -Sql "SELECT DB_NAME() AS DatabaseName, CONVERT(INT,SERVERPROPERTY('IsLocalDB')) AS IsLocalDB, CONVERT(VARCHAR(32),SERVERPROPERTY('ProductVersion')) AS Version"
Assert-Equal $server.IsLocalDB 1 'Only the explicitly named LocalDB runtime is permitted'
Assert-Equal $server.DatabaseName $DatabaseName 'The connection must use the explicitly supplied test database'
Assert-TestDatabaseOwnership
Write-Host "Using only '$DatabaseName' on isolated LocalDB '$InstanceName' ($($server.Version))."

Invoke-Case fresh {
    [void](Register-TestHost)
    $lease = Checkout-TestLease
    Assert-Equal $lease.Outcome 'Ok' 'Initial checkout'
    Assert-Equal (Complete-TestOperation $lease).Outcome 'Ok' 'Initial completion'
    Apply-TestMigrations
    $state = Invoke-TestProcedure GetVmDetails @{ VMID = $lease.VMID }
    Assert-Equal $state.LeaseId $lease.LeaseId 'Rerun preserves the active lease'
    Assert-Equal $state.LeaseGeneration $lease.LeaseGeneration 'Rerun preserves the generation'
    Assert-Equal $state.Username $lease.Username 'Rerun preserves the username'
    $table = Invoke-TestSql "SELECT temporal_type FROM sys.tables WHERE name='VirtualMachines'"
    Assert-Equal $table.temporal_type 2 'Temporal versioning remains enabled'
    Assert-SqlError { Invoke-TestProcedure CheckoutVm @{ Username = $lease.Username; AvdHost = 'legacy' } }
    Assert-SqlError { Invoke-TestProcedure ReturnVm @{ VMID = $lease.VMID } }
    Assert-SqlError { Invoke-TestProcedure ReleaseVm @{ Hostname = $lease.Hostname } }
}

Invoke-Case legacy -SchemaThrough 39 -Body {
    $legacyLease = [guid]::NewGuid()
    Invoke-TestSql "INSERT dbo.VmUsers(uid,username) VALUES(2042,'legacy_profile')"
    Invoke-TestSql "INSERT dbo.VirtualMachines(Hostname,PowerState,NetworkStatus,VmStatus,Username,LeaseId) VALUES('linux-01','On','Reachable','CheckedOut','legacy_profile',@Lease)" @{ Lease = $legacyLease }
    Apply-TestMigrations -First 40
    Assert-SqlError { Invoke-TestProcedure GetBrokerLeaseMigrationState @{ Hostname = 'linux-01' } }
    $binding = @{ TenantId = $script:Tenant; ObjectId = $script:Actor; Username = 'legacy_profile'; Uid = 2042 }
    Invoke-TestProcedure BindBrokerUser $binding
    Invoke-TestProcedure BindBrokerUser $binding
    $row = Invoke-TestProcedure GetBrokerLeaseMigrationState @{ Hostname = 'linux-01' }
    Assert-Equal (($row.PSObject.Properties.Name | Sort-Object) -join ',') 'LeaseGeneration,LeaseId,Uid,Username' 'Frozen migration response fields'
    Assert-Equal $row.Username 'legacy_profile' 'Legacy profile name'
    Assert-Equal $row.Uid 2042 'Legacy UID'
    Assert-Equal $row.LeaseId $legacyLease 'Legacy lease ID'
    Assert-Equal $row.LeaseGeneration 1 'Initial migrated generation'
    $conflict = $binding.Clone(); $conflict.ObjectId = [guid]::NewGuid()
    Assert-SqlError { Invoke-TestProcedure BindBrokerUser $conflict }
    $conflict = $binding.Clone(); $conflict.Uid = 2043
    Assert-SqlError { Invoke-TestProcedure BindBrokerUser $conflict }
    $conflict = $binding.Clone(); $conflict.TenantId = [guid]::NewGuid()
    Assert-SqlError { Invoke-TestProcedure BindBrokerUser $conflict }
    Invoke-TestSql "INSERT dbo.VmUsers(uid,username) VALUES(2043,'Legacy_Profile-1'),(2044,'Legacy.Profile')"
    $upperSubject = [guid]::NewGuid()
    Invoke-TestProcedure BindBrokerUser @{ TenantId = $script:Tenant; ObjectId = $upperSubject; Username = 'Legacy_Profile-1'; Uid = 2043 }
    Assert-Equal (Invoke-TestProcedure ResolveBrokerUser @{ TenantId = $script:Tenant; ObjectId = $upperSubject }).Username 'Legacy_Profile-1' 'Approved legacy case is preserved'
    Assert-SqlError {
        Invoke-TestProcedure BindBrokerUser @{ TenantId = $script:Tenant; ObjectId = [guid]::NewGuid(); Username = 'Legacy.Profile'; Uid = 2044 }
    }
    $unbound = Invoke-TestSql 'SELECT username,TenantId,ObjectId FROM dbo.VmUsers WHERE uid=2044'
    Assert-Equal $unbound.username 'Legacy.Profile' 'An incompatible legacy name is never renamed'
    Assert-Equal $unbound.TenantId $null 'An incompatible legacy profile remains unclaimed'
    Assert-SqlError { Invoke-TestSql "UPDATE dbo.VmUsers SET username='renamed' WHERE uid=2042" }
    Assert-SqlError { Invoke-TestSql 'DELETE dbo.VmUsers WHERE uid=2042' }
}

Invoke-Case identity-concurrency {
    [void](Register-TestHost)
    Invoke-TestSql "INSERT dbo.VmUsers(uid,username) VALUES(2099,'broker_2100')"
    $owners = @(1..12 | ForEach-Object { [guid]::NewGuid() })
    $work = @($owners | ForEach-Object { New-ProcedureWork ResolveBrokerUser @{ TenantId = $script:Tenant; ObjectId = $_ } })
    $rows = @(Invoke-SqlRace $work)
    Assert-Equal @($rows.Uid | Select-Object -Unique).Count 12 'Concurrent UID allocation is unique'
    Assert-Equal @($rows.Username | Select-Object -Unique).Count 12 'Concurrent usernames are unique'
    Assert-True ($rows.Username -notcontains 'broker_2100') 'An unbound legacy name is never claimed'
    $work = @(1..8 | ForEach-Object { New-ProcedureWork ResolveBrokerUser @{ TenantId = $script:Tenant; ObjectId = $owners[0] } })
    $same = @(Invoke-SqlRace $work)
    Assert-Equal @($same.Uid | Select-Object -Unique).Count 1 'The same subject always resolves the same UID'
    Assert-Equal @($same.Username | Select-Object -Unique).Count 1 'The same subject always resolves the same name'
}

Invoke-Case reserved-uids {
    [void](Register-TestHost)
    Invoke-TestSql "INSERT dbo.VmUsers(uid,username) VALUES(65532,'broker_65533')"
    $work = @(1..8 | ForEach-Object {
        New-ProcedureWork ResolveBrokerUser @{ TenantId = $script:Tenant; ObjectId = [guid]::NewGuid() }
    })
    $rows = @(Invoke-SqlRace $work)
    Assert-Equal @($rows.Uid | Select-Object -Unique).Count 8 'Reserved-range allocation remains race-safe'
    Assert-Equal ($rows.Uid | Measure-Object -Minimum).Minimum 65536 'A name collision cannot increment into a reserved UID'
    Assert-True ($rows.Uid -notcontains 65534 -and $rows.Uid -notcontains 65535) 'Allocator skips both reserved UIDs'
    Invoke-TestSql "INSERT dbo.VmUsers(uid,username) VALUES(65534,'legacy_reserved_a'),(65535,'legacy_reserved_b')"
    foreach ($reserved in @(@{ Uid = 65534; Username = 'legacy_reserved_a' }, @{ Uid = 65535; Username = 'legacy_reserved_b' })) {
        Assert-SqlError {
            Invoke-TestProcedure BindBrokerUser @{
                TenantId = $script:Tenant; ObjectId = [guid]::NewGuid(); Username = $reserved.Username; Uid = $reserved.Uid
            }
        }
        Assert-SqlError -Number 547 -Action {
            Invoke-TestSql 'UPDATE dbo.VmUsers SET TenantId=@Tenant,ObjectId=@Actor WHERE uid=@Uid' @{
                Tenant = $script:Tenant; Actor = [guid]::NewGuid(); Uid = $reserved.Uid
            }
        }
        $unchanged = Invoke-TestSql 'SELECT username,TenantId FROM dbo.VmUsers WHERE uid=@Uid' @{ Uid = $reserved.Uid }
        Assert-Equal $unchanged.username $reserved.Username 'Reserved legacy records are not renamed or re-UIDed'
        Assert-Equal $unchanged.TenantId $null 'Reserved legacy records cannot be claimed'
    }
    Apply-TestMigrations -First 40 -Last 40
}

Invoke-Case checkout-concurrency {
    [void](Register-TestHost 1); [void](Register-TestHost 2)
    $work = @(1..12 | ForEach-Object { New-ProcedureWork BeginBrokerCheckout @{ TenantId = $script:Tenant; ObjectId = [guid]::NewGuid(); AvdHost = 'avd-test' } })
    $rows = @(Invoke-SqlRace $work)
    $allocated = @($rows | Where-Object Outcome -eq 'Ok')
    Assert-Equal $allocated.Count 2 'At most the available host count is allocated'
    Assert-Equal @($allocated.VMID | Select-Object -Unique).Count 2 'Different subjects cannot share a host'
    Assert-Equal @($allocated.Username | Select-Object -Unique).Count 2 'Different subjects have different profiles'
    Assert-Equal (Invoke-TestProcedure GetVmSummary).Ready 0 'In-progress hosts are not ready'
}

Invoke-Case reconnect {
    [void](Register-TestHost)
    $initial = Checkout-TestLease
    Complete-TestOperation $initial
    Observe-TestLease $initial disconnected
    $work = @(1..10 | ForEach-Object { New-ProcedureWork BeginBrokerCheckout @{ TenantId = $script:Tenant; ObjectId = $script:Actor; AvdHost = 'avd-test' } })
    $rotations = @(Invoke-SqlRace $work | Where-Object Outcome -eq 'Ok')
    Assert-Equal $rotations.Count 1 'Only one credential rotation can be reserved'
    $current = $rotations[0]
    Assert-Equal $current.LeaseId $initial.LeaseId 'Reconnect retains the lease'
    Assert-Equal $current.Username $initial.Username 'Reconnect retains the profile'
    Assert-Equal $current.Uid $initial.Uid 'Reconnect retains the UID'
    Invoke-TestProcedure FailBrokerOperation @{ VMID = $current.VMID; OperationId = $current.OperationId; LeaseGeneration = $current.LeaseGeneration; ErrorCode = 'HostUncertain' }
    $state = Invoke-TestProcedure GetVmDetails @{ VMID = $current.VMID }
    Assert-True ($state.VmStatus -ne 'Available') 'Failed reconnect cannot release the assignment'
    $retry = Checkout-TestLease
    Assert-Equal $retry.Outcome 'Ok' 'Same-subject retry'
    Assert-True ($retry.LeaseGeneration -gt $current.LeaseGeneration) 'Retry advances the fence'
    Assert-Equal (Complete-TestOperation $current).Outcome 'Conflict' 'Stale completion is rejected'
    Assert-Equal (Complete-TestOperation $retry).Outcome 'Ok' 'Current operation can complete'
}

Invoke-Case grace {
    [void](Register-TestHost)
    Invoke-TestProcedure UpdateLinuxHostSettings @{ GracePeriodSeconds = 73 }
    $lease = Checkout-TestLease
    Complete-TestOperation $lease
    Observe-TestLease $lease disconnected
    $before = (Invoke-TestProcedure GetVmDetails @{ VMID = $lease.VMID }).DisconnectedAt
    Observe-TestLease $lease disconnected
    Invoke-TestProcedure UpdateVmAttributes @{ VMID = $lease.VMID; NetworkStatus = 'Reachable' }
    $after = (Invoke-TestProcedure GetVmDetails @{ VMID = $lease.VMID }).DisconnectedAt
    Assert-Equal $after $before 'Repeated disconnect and health update do not move the clock'
    foreach ($boundary in @(@{ Elapsed = 68; Count = 0 }, @{ Elapsed = 73; Count = 1 }, @{ Elapsed = 78; Count = 1 })) {
        Invoke-TestSql 'UPDATE dbo.VirtualMachines SET DisconnectedAt=DATEADD(SECOND,@Elapsed,SYSUTCDATETIME()) WHERE VMID=@VMID' @{ Elapsed = -$boundary.Elapsed; VMID = $lease.VMID }
        Assert-Equal @(Invoke-TestProcedure ReturnReleasedVms).Count $boundary.Count 'Configured grace boundary'
    }
    Assert-Equal (Observe-TestLease $lease active).Outcome 'Ok' 'Automatic reconnect'
    Assert-Equal @(Invoke-TestProcedure ReturnReleasedVms).Count 0 'Active reconnect cancels expiry'
    Assert-Equal (Invoke-TestProcedure GetVmDetails @{ VMID = $lease.VMID }).DisconnectedAt $null 'Active clears disconnect timestamp'
}

Invoke-Case return-race {
    [void](Register-TestHost)
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        $initial = Checkout-TestLease
        Complete-TestOperation $initial
        Observe-TestLease $initial disconnected
        $work = @(
            (New-ProcedureWork BeginBrokerCleanup (Get-CleanupParameters $initial)),
            (New-ProcedureWork BeginBrokerCheckout @{ TenantId = $script:Tenant; ObjectId = $script:Actor; AvdHost = 'avd-test' })
        )
        $rows = @(Invoke-SqlRace $work)
        Assert-Equal @($rows | Where-Object Outcome -eq 'Ok').Count 1 'Cleanup and reconnect cannot both win'
        Assert-True ((Checkout-TestLease ([guid]::NewGuid())).Outcome -ne 'Ok') 'Other owners cannot reuse an unfinished operation'
        Assert-Equal (Observe-TestLease $initial active).Outcome 'Conflict' 'Old observation cannot cancel the current reservation'
        if ($rows[0].Outcome -eq 'Ok') {
            Complete-TestOperation $rows[0] cleaned
        } else {
            Complete-TestOperation $rows[1] ready
        }
    }
}

Invoke-Case cleanup-retry {
    $vmid = Register-TestHost
    $initial = Checkout-TestLease
    Complete-TestOperation $initial
    $reserved = Begin-TestCleanup $initial
    Invoke-TestProcedure FailBrokerOperation @{ VMID = $vmid; OperationId = $reserved.OperationId; LeaseGeneration = $reserved.LeaseGeneration; ErrorCode = 'MountBusy' }
    Assert-Equal (Invoke-TestProcedure UpdateVmAttributes @{ VMID = $vmid; PowerState = 'On'; VmStatus = 'Available' }).Outcome 'Conflict' 'Manual mutation cannot clear an assignment'
    Assert-Equal (Invoke-TestProcedure DeleteVm @{ VMID = $vmid }).Outcome 'Conflict' 'Deletion cannot bypass cleanup'
    Assert-Equal (Checkout-TestLease).Outcome 'Conflict' 'Checkout cannot cross an uncertain cleanup'
    Assert-Equal @(Invoke-TestProcedure ReturnReleasedVms).Count 1 'Failed cleanup is a retry candidate'
    $retried = Begin-TestCleanup $reserved
    Assert-Equal $retried.Outcome 'Ok' 'Cleanup retry can reserve'
    Assert-Equal (Complete-TestOperation $reserved cleaned).Outcome 'Conflict' 'Old cleanup cannot finalize'
    Assert-Equal (Complete-TestOperation $retried cleaned).Outcome 'Ok' 'Verified cleanup completes'
    Assert-Equal (Complete-TestOperation $retried cleaned).Outcome 'Ok' 'Completion retry is idempotent'
    $next = Checkout-TestLease ([guid]::NewGuid())
    Assert-Equal $next.Outcome 'Ok' 'Only completed cleanup permits the next owner'
    Assert-True ($next.LeaseGeneration -gt $retried.LeaseGeneration) 'New owner has a new fence'
    Assert-Equal (Complete-TestOperation $retried cleaned).Outcome 'Conflict' 'Old completion cannot affect a new owner'
}

Invoke-Case operation-recovery {
    [void](Register-TestHost)
    $initial = Checkout-TestLease
    Invoke-TestSql 'UPDATE dbo.BrokerLeaseOperations SET StartedAt=DATEADD(SECOND,-295,SYSUTCDATETIME()) WHERE OperationId=@OperationId' @{ OperationId = $initial.OperationId }
    Assert-Equal (Checkout-TestLease).Outcome 'Conflict' 'A running provisioning guard cannot be stolen before its retry boundary'
    Invoke-TestSql 'UPDATE dbo.BrokerLeaseOperations SET StartedAt=DATEADD(SECOND,-300,SYSUTCDATETIME()) WHERE OperationId=@OperationId' @{ OperationId = $initial.OperationId }
    $retry = Checkout-TestLease
    Assert-Equal $retry.Outcome 'Ok' 'An abandoned provisioning operation can be recovered at the boundary'
    Assert-True ($retry.LeaseGeneration -gt $initial.LeaseGeneration) 'Recovery advances the durable fence'
    Assert-Equal (Complete-TestOperation $initial).Outcome 'Conflict' 'A delayed worker cannot finalize after recovery'
    Complete-TestOperation $retry
    $cleanup = Begin-TestCleanup $retry
    Invoke-TestSql 'UPDATE dbo.BrokerLeaseOperations SET StartedAt=DATEADD(SECOND,-295,SYSUTCDATETIME()) WHERE OperationId=@OperationId' @{ OperationId = $cleanup.OperationId }
    Assert-Equal @(Invoke-TestProcedure ReturnReleasedVms).Count 0 'Running cleanup is not retried early'
    Invoke-TestSql 'UPDATE dbo.BrokerLeaseOperations SET StartedAt=DATEADD(SECOND,-300,SYSUTCDATETIME()) WHERE OperationId=@OperationId' @{ OperationId = $cleanup.OperationId }
    Assert-Equal @(Invoke-TestProcedure ReturnReleasedVms).Count 1 'Abandoned cleanup becomes a retry candidate at the boundary'
    $recovered = Begin-TestCleanup $cleanup
    Assert-Equal (Complete-TestOperation $cleanup cleaned).Outcome 'Conflict' 'Stale cleanup completion remains fenced'
    Assert-Equal (Complete-TestOperation $recovered active).Outcome 'Ok' 'A resumed host cancels cleanup'
    $state = Invoke-TestProcedure GetVmDetails @{ VMID = $initial.VMID }
    Assert-Equal $state.VmStatus 'CheckedOut' 'Active cancellation preserves assignment'
    Assert-Equal $state.LeaseId $initial.LeaseId 'Active cancellation preserves the lease'
    Assert-Equal $state.DisconnectedAt $null 'Active cancellation clears expiry'
    Observe-TestLease $recovered logged_off
    $logoff = Begin-TestCleanup $recovered logged_off
    Assert-Equal (Complete-TestOperation $logoff disconnected).Outcome 'Ok' 'A stale logoff preserves a surviving disconnected desktop'
    $state = Invoke-TestProcedure GetVmDetails @{ VMID = $initial.VMID }
    Assert-Equal $state.VmStatus 'Released' 'Deferred logoff uses the normal released state'
    Assert-Equal $state.SessionState 'disconnected' 'Deferred logoff does not remain an immediate-cleanup candidate'
    Assert-Equal @(Invoke-TestProcedure ReturnReleasedVms).Count 0 'Deferred logoff receives the configured grace window'
}

Invoke-Case scaling {
    $first = Register-TestHost 1
    $second = Register-TestHost 2
    $lease = Checkout-TestLease
    Complete-TestOperation $lease
    Invoke-TestProcedure UpdateScalingRule @{ RuleID = 1; MinVMs = 1; MaxVMs = 4; ScaleUpRatio = 100; ScaleUpIncrement = 1; ScaleDownRatio = 90; ScaleDownIncrement = 1 }
    $actions = @(Invoke-TestProcedure TriggerScalingLogic @{ ActorTenantId = $script:Tenant; ActorObjectId = $script:Actor })
    Assert-Equal $actions.Count 1 'Only one unowned host is reserved for scaling'
    Assert-Equal $actions[0].VMID $second 'Owned host is not powered off'
    Assert-Equal $actions[0].ActionType 'PowerOff' 'Power operation contract'
    Assert-Equal (Invoke-TestProcedure GetVmSummary).Ready 0 'Power operation excludes checkout'
    Complete-TestOperation $actions[0] Off
    $state = Invoke-TestProcedure GetVmDetails @{ VMID = $first }
    Assert-Equal $state.LeaseId $lease.LeaseId 'Scaling preserves ownership'
    Assert-Equal $state.VmStatus 'CheckedOut' 'Scaling preserves assignment status'
    Invoke-TestSql "UPDATE dbo.VirtualMachines SET PowerState='Off' WHERE VMID=@VMID" @{ VMID = $first }
    $starts = @(Invoke-TestProcedure TriggerScalingLogic @{ ActorTenantId = $script:Tenant; ActorObjectId = $script:Actor })
    Assert-Equal $starts.Count 1 'Scale-up reserves an unowned host'
    Assert-Equal $starts[0].VMID $second 'An owned powered-off host is not made available'
    Assert-Equal $starts[0].ActionType 'PowerOn' 'Power-on operation contract'
    Complete-TestOperation $starts[0] On
    $state = Invoke-TestProcedure GetVmDetails @{ VMID = $first }
    Assert-Equal $state.LeaseId $lease.LeaseId 'Scale-up never clears an outstanding lease'
    Assert-Equal $state.VmStatus 'CheckedOut' 'Scale-up never manufactures availability'
    Assert-Equal (Invoke-TestProcedure GetVmDetails @{ VMID = $second }).NetworkStatus 'Unreachable' 'Power-on requires a fresh reachability probe'
}

Invoke-Case generation {
    $vmid = Register-TestHost
    $binding = Invoke-TestSql "SELECT TenantId,ObjectId,Hostname,ResourceId FROM dbo.BrokerHosts WHERE Hostname='linux-01' AND Active=1"
    $lease = Checkout-TestLease
    Complete-TestOperation $lease
    $cleanup = Begin-TestCleanup $lease
    Complete-TestOperation $cleanup cleaned
    Invoke-TestProcedure DeleteVm @{ VMID = $vmid }
    Invoke-TestProcedure RegisterLinuxHostVm @{ Hostname = 'linux-01'; IPAddress = '192.0.2.1' }
    Assert-Equal (Checkout-TestLease).Outcome 'Unavailable' 'Inventory import alone cannot revive enrollment'
    Invoke-TestProcedure RegisterBrokerHost @{
        TenantId = $binding.TenantId; ObjectId = $binding.ObjectId; Hostname = $binding.Hostname; ResourceId = $binding.ResourceId
    }
    $next = Checkout-TestLease
    Assert-Equal $next.Outcome 'Ok' 'Recreated inventory can allocate'
    Assert-True ($next.LeaseGeneration -gt $cleanup.LeaseGeneration) 'Inventory recreation cannot recycle the host fence'
}

Invoke-Case host-endpoint-binding {
    $vmid = Register-TestHost
    $binding = Invoke-TestSql "SELECT TenantId,ObjectId,Hostname,ResourceId FROM dbo.BrokerHosts WHERE Hostname='linux-01' AND Active=1"
    $parameters = @{ TenantId = $binding.TenantId; ObjectId = $binding.ObjectId; Hostname = $binding.Hostname; ResourceId = $binding.ResourceId }
    $lease = Checkout-TestLease
    Complete-TestOperation $lease
    $cleanup = Begin-TestCleanup $lease
    Complete-TestOperation $cleanup cleaned
    Invoke-TestSql 'CREATE USER BrokerManagementTest WITHOUT LOGIN; ALTER ROLE BrokerApiRuntime ADD MEMBER BrokerManagementTest;'
    Invoke-TestSql "EXECUTE AS USER='BrokerManagementTest'; EXEC dbo.DeleteVm @VMID=@VMID; REVERT;" @{ VMID = $vmid }
    $manual = Invoke-TestSql @"
EXECUTE AS USER='BrokerManagementTest';
EXEC dbo.AddVm @Hostname='LiNuX-01', @IPAddress='203.0.113.77',
    @PowerState='On', @NetworkStatus='Reachable', @VmStatus='Available';
REVERT;
"@
    Assert-Equal (Invoke-TestProcedure GetVmSummary).Ready 0 'Manual re-add must not inherit a trusted hostname binding'
    $denied = Checkout-TestLease
    Assert-Equal $denied.Outcome 'Unavailable' 'Manual endpoint redirection cannot issue credentials'
    Assert-Equal (($denied.PSObject.Properties.Name | Sort-Object) -join ',') 'Outcome' 'Denial exposes no endpoint or lease'
    Assert-Equal @(Invoke-TestProcedure GetBrokerHost @{ TenantId = $binding.TenantId; ObjectId = $binding.ObjectId }).Count 0 'Deleted enrollment no longer authorizes the old host'
    Assert-SqlError {
        Invoke-TestProcedure RegisterBrokerHost $parameters
    }
    Assert-SqlError -Number 229 -Action {
        Invoke-TestSql "EXECUTE AS USER='BrokerManagementTest'; EXEC dbo.RegisterLinuxHostVm @Hostname='linux-01',@IPAddress='203.0.113.77'; REVERT;"
    }
    Assert-SqlError -Number 229 -Action {
        Invoke-TestSql "EXECUTE AS USER='BrokerManagementTest'; EXEC dbo.RegisterBrokerHost @TenantId=@Tenant,@ObjectId=@Actor,@Hostname='linux-01',@ResourceId=@Resource; REVERT;" @{
            Tenant = $binding.TenantId; Actor = $binding.ObjectId; Resource = $binding.ResourceId
        }
    }
    Assert-SqlError -Number 229 -Action {
        Invoke-TestSql "EXECUTE AS USER='BrokerManagementTest'; UPDATE dbo.BrokerHosts SET Active=1 WHERE Hostname='linux-01'; REVERT;"
    }
    Assert-SqlError -Number 229 -Action {
        Invoke-TestSql "EXECUTE AS USER='BrokerManagementTest'; INSERT dbo.BrokerHostInventory(Hostname,VMID,IPAddress,ImportedAt) VALUES('linux-01',@VMID,'203.0.113.77',SYSUTCDATETIME()); REVERT;" @{
            VMID = $manual.NewVMID
        }
    }
    Invoke-TestProcedure RegisterLinuxHostVm @{ Hostname = 'linux-01'; IPAddress = '192.0.2.1' }
    Assert-Equal (Checkout-TestLease).Outcome 'Unavailable' 'Trusted inventory still requires explicit identity enrollment'
    Invoke-TestProcedure RegisterBrokerHost $parameters
    Assert-Equal (Invoke-TestProcedure GetVmSummary).Ready 1 'Trusted ARM import plus host enrollment restores readiness'
    $reenrolled = Checkout-TestLease
    Assert-Equal $reenrolled.Outcome 'Ok' 'The legitimate host can be checked out after re-enrollment'
    Assert-Equal $reenrolled.VMID $manual.NewVMID 'Re-enrollment binds the recreated record'
    Assert-Equal $reenrolled.IPAddress '192.0.2.1' 'Only the reverified endpoint reaches checkout'
    Assert-True ($reenrolled.LeaseGeneration -gt $cleanup.LeaseGeneration) 'Host tombstone generation remains monotonic'
    Assert-SqlError { Invoke-TestProcedure RegisterLinuxHostVm @{ Hostname = 'linux-01'; IPAddress = '192.0.2.2' } }
    Assert-Equal @(Invoke-TestProcedure GetBrokerHost @{ TenantId = $binding.TenantId; ObjectId = $binding.ObjectId }).Count 1 'Rejected concurrent endpoint changes preserve current trust'
    Complete-TestOperation $reenrolled
    $returned = Begin-TestCleanup $reenrolled
    Complete-TestOperation $returned cleaned
    Invoke-TestSql "UPDATE dbo.VirtualMachines SET IPAddress='203.0.113.88' WHERE VMID=@VMID" @{ VMID = $reenrolled.VMID }
    Assert-Equal (Invoke-TestProcedure GetVmSummary).Ready 0 'Changing an enrolled endpoint invalidates trust'
    Assert-Equal (Checkout-TestLease).Outcome 'Unavailable' 'Changed endpoints cannot reuse prior trust'
    Invoke-TestSql "UPDATE dbo.VirtualMachines SET IPAddress='192.0.2.1' WHERE VMID=@VMID" @{ VMID = $reenrolled.VMID }
    Assert-SqlError { Invoke-TestProcedure RegisterBrokerHost $parameters }
    Invoke-TestProcedure RegisterLinuxHostVm @{ Hostname = 'linux-01'; IPAddress = '192.0.2.2' }
    Invoke-TestProcedure RegisterBrokerHost $parameters
    $updated = Checkout-TestLease
    Assert-Equal $updated.IPAddress '192.0.2.2' 'A legitimate trusted endpoint change is supported'
    Assert-True ($updated.LeaseGeneration -gt $returned.LeaseGeneration) 'Endpoint re-enrollment does not reset the fence'
    Complete-TestOperation $updated
    $finalCleanup = Begin-TestCleanup $updated
    Complete-TestOperation $finalCleanup cleaned
    $racing = @(Invoke-SqlRace @(
        (New-ProcedureWork DeleteVm @{ VMID = $updated.VMID }),
        (New-ProcedureWork BeginBrokerCheckout @{ TenantId = $script:Tenant; ObjectId = $script:Actor; AvdHost = 'avd-test' })
    ))
    Assert-Equal @($racing | Where-Object Outcome -eq 'Ok').Count 1 'Deletion and checkout cannot both win the reservation'
}

Invoke-Case host-enrollment-upgrade -SchemaThrough 45 -Body {
    [void](Register-TestHost)
    $binding = Invoke-TestSql "SELECT TenantId,ObjectId,Hostname,ResourceId FROM dbo.BrokerHosts WHERE Active=1"
    $parameters = @{ TenantId = $binding.TenantId; ObjectId = $binding.ObjectId; Hostname = $binding.Hostname; ResourceId = $binding.ResourceId }
    $lease = Checkout-TestLease
    Complete-TestOperation $lease
    Apply-TestMigrations -First 46
    Assert-Equal (Checkout-TestLease).Outcome 'Unavailable' 'Existing mutable inventory is not automatically trusted during upgrade'
    $state = Invoke-TestProcedure GetBrokerLeaseMigrationState @{ Hostname = 'linux-01' }
    Assert-Equal $state.LeaseId $lease.LeaseId 'Enrollment upgrade preserves the active lease'
    Assert-Equal $state.LeaseGeneration $lease.LeaseGeneration 'Enrollment upgrade preserves the fence'
    Assert-Equal $state.Username $lease.Username 'Enrollment upgrade preserves the profile'
    Assert-SqlError { Invoke-TestProcedure RegisterBrokerHost $parameters }
    Invoke-TestProcedure RegisterLinuxHostVm @{ Hostname = 'linux-01'; IPAddress = '192.0.2.1' }
    Invoke-TestProcedure RegisterBrokerHost $parameters
    Invoke-TestProcedure RegisterBrokerHost $parameters
    $reconnect = Checkout-TestLease
    Assert-Equal $reconnect.Outcome 'Ok' 'Verified existing enrollment can reconnect'
    Assert-Equal $reconnect.LeaseId $lease.LeaseId 'Trusted re-enrollment reuses the original lease'
    Assert-True ($reconnect.LeaseGeneration -gt $lease.LeaseGeneration) 'Reconnect after enrollment advances, never resets'
}

Invoke-Case generation-bounds {
    $vmid = Register-TestHost
    $maximum = [long]9007199254740991
    foreach ($invalidGeneration in @([long]9007199254740992, [long]::MaxValue)) {
        Assert-SqlError -Number 547 -Action {
            Invoke-TestSql 'UPDATE dbo.VirtualMachines SET LeaseGeneration=@Generation WHERE VMID=@VMID' @{ Generation = $invalidGeneration; VMID = $vmid }
        }
    }
    Invoke-TestSql "INSERT dbo.BrokerHostGenerations(Hostname,Generation) VALUES('linux-01',@Generation)" @{ Generation = $maximum - 1 }
    Assert-Equal (Invoke-TestProcedure GetVmSummary).Ready 1 'The final safe generation remains exact'
    Invoke-TestSql 'SET XACT_ABORT ON; BEGIN TRANSACTION; EXEC dbo.LockBrokerState; EXEC dbo.AdvanceBrokerGeneration @VMID=@VMID; COMMIT;' @{ VMID = $vmid }
    Assert-Equal (Invoke-TestProcedure GetVmDetails @{ VMID = $vmid }).LeaseGeneration $maximum 'Advancement reaches the shared maximum without rounding'
    Assert-Equal (Invoke-TestProcedure GetVmSummary).Ready 0 'An exhausted host is not advertised as ready'
    Assert-Equal (Checkout-TestLease).Outcome 'Unavailable' 'Exhausted host cannot allocate a credential operation'
    Assert-SqlError {
        Invoke-TestSql 'SET XACT_ABORT ON; BEGIN TRANSACTION; EXEC dbo.LockBrokerState; EXEC dbo.AdvanceBrokerGeneration @VMID=@VMID; COMMIT;' @{ VMID = $vmid }
    }
    Assert-Equal (Invoke-TestProcedure GetVmDetails @{ VMID = $vmid }).LeaseGeneration $maximum 'Exhaustion never wraps or resets the fence'
    foreach ($invalidGeneration in @([long]9007199254740992, [long]::MaxValue)) {
        Assert-SqlError -Number 547 -Action {
            Invoke-TestSql "UPDATE dbo.BrokerHostGenerations SET Generation=@Generation WHERE Hostname='linux-01'" @{ Generation = $invalidGeneration }
        }
        Assert-SqlError -Number 547 -Action {
            Invoke-TestSql "INSERT dbo.BrokerLeaseOperations(OperationId,VMID,LeaseGeneration,Kind,State,ActorTenantId,ActorObjectId) VALUES(NEWID(),@VMID,@Generation,'PowerOn','Running',@Tenant,@Actor)" @{
                VMID = $vmid; Generation = $invalidGeneration; Tenant = $script:Tenant; Actor = $script:Actor
            }
        }
    }
    Invoke-TestProcedure UpdateVmAttributes @{ VMID = $vmid; PowerState = 'Off' }
    Assert-Equal @(Invoke-TestProcedure TriggerScalingLogic @{ ActorTenantId = $script:Tenant; ActorObjectId = $script:Actor }).Count 0 'Scaling does not reserve an exhausted host'
}

Invoke-Case idle-tombstone-evidence {
    # Import function definitions only; no Azure/host probe is executed by this case.
    . (Join-Path (Split-Path -Parent $script:ScriptsPath) 'deploy\Broker.IdleLease.ps1')
    $vmid = Register-TestHost
    $binding = Invoke-TestSql "SELECT TenantId,ObjectId,Hostname,ResourceId FROM dbo.BrokerHosts WHERE Hostname='linux-01' AND Active=1"
    Invoke-TestSql "INSERT dbo.VmUsers(uid,username) VALUES(10001,'ExistingProfile')"
    Invoke-TestProcedure BindBrokerUser @{
        TenantId = $script:Tenant; ObjectId = $script:Actor; Username = 'ExistingProfile'; Uid = 10001
    }
    $lease = Checkout-TestLease
    Complete-TestOperation $lease
    $cleanup = Begin-TestCleanup $lease
    Complete-TestOperation $cleanup cleaned
    Assert-Equal @(Invoke-TestProcedure GetBrokerLeaseMigrationState @{ Hostname = 'linux-01' }).Count 0 'The tombstone reader follows the SQL-idle migration check'
    $observation = @{
        kind = 'cleaned'; username = 'ExistingProfile'; uid = 10001
        generation = [long]$cleanup.LeaseGeneration; sha256 = ('a' * 64)
    }
    $connection = New-TestConnection $script:Database
    try {
        $first = Get-BrokerIdleLeaseEvidence -Connection $connection -Hostname linux-01 -Observation $observation
        Assert-Equal (($first.Keys | Sort-Object) -join ',') 'fence,kind,sha256,uid,username' 'Evidence contains no lease/operation ID or marker body'
        Assert-Equal $first.fence $cleanup.LeaseGeneration 'Current SQL fence matches completed cleanup'
        Assert-Equal $first.username 'ExistingProfile' 'Case-exact username survives the actual SQL query'
        Assert-Equal $first.sha256 $observation.sha256 'Only the supplied fingerprint is forwarded'
        Invoke-TestProcedure DeleteVm @{ VMID = $vmid }
        Invoke-TestProcedure RegisterLinuxHostVm @{ Hostname = 'linux-01'; IPAddress = '192.0.2.1' }
        $recreated = Invoke-TestSql "SELECT VMID,LeaseGeneration FROM dbo.VirtualMachines WHERE Hostname='linux-01'"
        Assert-Equal $recreated.LeaseGeneration 0 'Recreated inventory starts independently of the retained counter'
        $retained = Get-BrokerIdleLeaseEvidence -Connection $connection -Hostname linux-01 -Observation $observation
        Assert-Equal $retained.fence $cleanup.LeaseGeneration 'Retained host fence is used when greater than recreated inventory'
        Assert-Equal (Get-BrokerIdleLeaseEvidence -Connection $connection -Hostname linux-01 -Observation $observation).sha256 $first.sha256 'Repeated evidence reads preserve the root fingerprint'
        Invoke-TestSql 'SET XACT_ABORT ON; BEGIN TRANSACTION; EXEC dbo.LockBrokerState; EXEC dbo.AdvanceBrokerGeneration @VMID=@VMID; COMMIT;' @{
            VMID = $recreated.VMID
        }
        $advanced = Get-BrokerIdleLeaseEvidence -Connection $connection -Hostname linux-01 -Observation $observation
        Assert-True ($advanced.fence -gt $observation.generation) 'A SQL fence advanced beyond the retained marker is accepted exactly'
        Assert-Equal $advanced.sha256 $first.sha256 'A greater SQL fence does not rewrite the retained marker fingerprint'

        foreach ($changed in @(
            @{ username = 'existingprofile' },
            @{ uid = 10002 },
            @{ generation = [long]($advanced.fence + 1) }
        )) {
            $invalid = @{} + $observation
            foreach ($key in $changed.Keys) { $invalid[$key] = $changed[$key] }
            $rejected = $false
            try { Get-BrokerIdleLeaseEvidence -Connection $connection -Hostname linux-01 -Observation $invalid | Out-Null }
            catch {
                if ($_.Exception.Message -notlike "Idle host 'linux-01' does not match retained*") { throw }
                $rejected = $true
            }
            Assert-True $rejected 'Actual SQL must reject mismatched identity and future tombstone generations'
        }
        Invoke-TestProcedure RegisterBrokerHost @{
            TenantId = $binding.TenantId; ObjectId = $binding.ObjectId; Hostname = $binding.Hostname; ResourceId = $binding.ResourceId
        }
        $occupied = Checkout-TestLease
        foreach ($operationCompleted in @($false, $true)) {
            if ($operationCompleted) { Complete-TestOperation $occupied }
            $rejected = $false
            try { Get-BrokerIdleLeaseEvidence -Connection $connection -Hostname linux-01 -Observation $observation | Out-Null }
            catch {
                if ($_.Exception.Message -notlike "Idle host 'linux-01' does not match retained*") { throw }
                $rejected = $true
            }
            Assert-True $rejected 'Neither an in-progress operation nor an owned lease can look idle'
        }
    }
    finally { $connection.Dispose() }
}

Invoke-Case runtime-permissions {
    [void](Register-TestHost)
    Invoke-TestSql 'CREATE USER BrokerRuntimeTest WITHOUT LOGIN; ALTER ROLE BrokerApiRuntime ADD MEMBER BrokerRuntimeTest;'
    $rows = @(Invoke-TestSql "EXECUTE AS USER='BrokerRuntimeTest'; EXEC dbo.GetVms; REVERT;")
    Assert-Equal $rows.Count 1 'Runtime role can read inventory through its procedure'
    $checked = Invoke-TestSql "EXECUTE AS USER='BrokerRuntimeTest'; EXEC dbo.BeginBrokerCheckout @TenantId=@Tenant,@ObjectId=@Actor,@AvdHost='avd-test'; REVERT;" @{ Tenant = $script:Tenant; Actor = $script:Actor }
    Assert-Equal $checked.Outcome 'Ok' 'Runtime role can execute nested guarded procedures'
    Complete-TestOperation $checked
    Assert-SqlError -Number 229 -Action { Invoke-TestSql "EXECUTE AS USER='BrokerRuntimeTest'; UPDATE dbo.VirtualMachines SET NetworkStatus='Reachable'; REVERT;" }
    Assert-SqlError -Number 229 -Action { Invoke-TestSql "EXECUTE AS USER='BrokerRuntimeTest'; EXEC dbo.GetBrokerLeaseMigrationState @Hostname='linux-01'; REVERT;" }
    Assert-SqlError -Number 229 -Action {
        Invoke-TestSql "EXECUTE AS USER='BrokerRuntimeTest'; EXEC dbo.BindBrokerUser @TenantId=@Tenant,@ObjectId=@Actor,@Username=@Username,@Uid=@Uid; REVERT;" @{
            Tenant = $script:Tenant; Actor = $script:Actor; Username = $checked.Username; Uid = $checked.Uid
        }
    }
    $binding = Invoke-TestSql 'SELECT TenantId,ObjectId,Hostname,ResourceId FROM dbo.BrokerHosts WHERE Active=1'
    Assert-SqlError -Number 229 -Action {
        Invoke-TestSql "EXECUTE AS USER='BrokerRuntimeTest'; EXEC dbo.RegisterBrokerHost @TenantId=@Tenant,@ObjectId=@Actor,@Hostname=@Hostname,@ResourceId=@Resource; REVERT;" @{
            Tenant = $binding.TenantId; Actor = $binding.ObjectId; Hostname = $binding.Hostname; Resource = $binding.ResourceId
        }
    }
}

Assert-True ($script:Passed -gt 0) 'At least one SQL integration case must execute'
Write-Host "$script:Passed SQL integration cases passed; $script:RaceCount synchronized multi-connection races executed."
Write-Host "Only the supplied test database was used. Database and instance were left for the parent to clean up."
