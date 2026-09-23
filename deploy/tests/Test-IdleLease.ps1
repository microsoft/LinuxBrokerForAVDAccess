#requires -Version 7.4
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'Broker.IdleLease.ps1')
$script:checks = 0
function Check {
    param([bool]$Condition, [string]$Message)
    $script:checks++
    if (-not $Condition) { throw "Idle SQL fence check failed: $Message" }
}
function Reject {
    param([scriptblock]$Action)
    $script:checks++
    try { & $Action | Out-Null; throw 'Expected idle fence rejection was not raised.' }
    catch { if ($_.Exception.Message -eq 'Expected idle fence rejection was not raised.') { throw } }
}
$script:rows = @(@{ Username = 'ExistingProfile'; Uid = 10001; HostFence = 12L })
$script:lastCommand = $null
$connection = [pscustomobject]@{}
$connection | Add-Member -MemberType ScriptMethod -Name CreateCommand -Value {
    $parameters = [Data.SqlClient.SqlCommand]::new().Parameters
    $command = [pscustomobject]@{ Parameters = $parameters; CommandText = ''; CommandTimeout = 0 }
    $command | Add-Member -MemberType ScriptMethod -Name ExecuteReader -Value {
        $script:lastCommand = $this
        $table = [Data.DataTable]::new()
        foreach ($name in @('Username', 'Uid', 'HostFence')) { $null = $table.Columns.Add($name, [object]) }
        foreach ($data in $script:rows) {
            $row = $table.NewRow()
            foreach ($name in $data.Keys) { $row[$name] = $data[$name] }
            $table.Rows.Add($row)
        }
        return ,$table.CreateDataReader()
    }
    $command | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
    return $command
}
$observation = @{ kind = 'cleaned'; username = 'ExistingProfile'; uid = 10001; generation = 7L; sha256 = ('a' * 64) }
$evidence = Get-BrokerIdleLeaseEvidence -Connection $connection -Hostname linux-01 -Observation $observation
Check ($evidence.fence -eq 12L -and $evidence.uid -eq 10001 -and $evidence.username -ceq 'ExistingProfile') 'A retained SQL fence greater than the tombstone is valid.'
Check ($evidence.sha256 -ceq $observation.sha256) 'The root marker fingerprint is carried into the locked recheck.'
Check ($script:lastCommand.CommandText.Contains('COALESCE(g.Generation, 0) > v.LeaseGeneration')) 'The maximum VM/retained host-generation fence is read.'
Check ($script:lastCommand.CommandText.Contains('u.username COLLATE Latin1_General_100_BIN2')) 'Retained usernames match case-exactly.'
Check ($script:lastCommand.CommandText.Contains('v.OperationId IS NULL')) 'A newly outstanding SQL operation cannot be skipped.'
Check ($script:lastCommand.CommandText -notmatch '\b(INSERT|UPDATE|DELETE|EXEC|CREATE)\b') 'Tombstone verification never mutates SQL ownership/fences.'
Check ($script:lastCommand.Parameters['@Username'].Value -ceq 'ExistingProfile' -and
    -not $script:lastCommand.CommandText.Contains('ExistingProfile')) 'Marker metadata is parameterized, not injected into SQL.'
foreach ($rows in @(
        @(),
        @(@{ Username = 'different'; Uid = 10001; HostFence = 12L }),
        @(@{ Username = 'ExistingProfile'; Uid = 10002; HostFence = 12L }),
        @(@{ Username = 'ExistingProfile'; Uid = 10001; HostFence = 6L }),
        @(@{ Username = 'ExistingProfile'; Uid = 10001; HostFence = 12L }, @{ Username = 'ExistingProfile'; Uid = 10001; HostFence = 12L })
    )) {
    $script:rows = $rows
    Reject { Get-BrokerIdleLeaseEvidence -Connection $connection -Hostname linux-01 -Observation $observation }
}
Reject { Get-BrokerIdleLeaseEvidence -Connection $connection -Hostname linux-01 -Observation @{ kind = 'ready' } }
$boundary = @{} + $observation
$boundary.generation = 9007199254740991L
$script:rows = @(@{ Username = 'ExistingProfile'; Uid = 10001; HostFence = 9007199254740991L })
$boundaryEvidence = Get-BrokerIdleLeaseEvidence -Connection $connection -Hostname linux-01 -Observation $boundary
$wireRoundTrip = $boundaryEvidence | ConvertTo-Json -Compress | ConvertFrom-Json -AsHashtable
Check ($wireRoundTrip.fence -is [long] -and $wireRoundTrip.fence -eq 9007199254740991L) 'Maximum shared fence survives the deployment JSON round trip exactly.'
foreach ($unsafe in @(9007199254740992L, 9007199254740993L, [long]::MaxValue, 9.007199254740991e15, '9007199254740991')) {
    $boundary.generation = $unsafe
    Reject { Get-BrokerIdleLeaseEvidence -Connection $connection -Hostname linux-01 -Observation $boundary }
}
$script:rows = @(@{ Username = 'ExistingProfile'; Uid = 10001; HostFence = 9007199254740992L })
Reject { Get-BrokerIdleLeaseEvidence -Connection $connection -Hostname linux-01 -Observation $observation }
$absent = Get-BrokerIdleLeaseEvidence -Connection $connection -Hostname linux-01 -Observation @{ kind = 'absent' }
Check ($absent.kind -eq 'absent') 'An inspected absent marker remains a distinct case, not a fabricated tombstone.'
Write-Host "PASS: $script:checks retained idle SQL fence checks with database boundaries mocked."
