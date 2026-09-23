. "$PSScriptRoot\Broker.Deployment.Common.ps1"

function Get-BrokerIdleLeaseScript {
    param([hashtable]$Evidence)
    $source = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Test-BrokerIdleLease.py') -Raw).Replace("`r`n", "`n")
    $encodedSource = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($source))
    $arguments = if ($null -eq $Evidence) { @('broker-idle-lease', '--inspect') }
        else {
            @('broker-idle-lease', '--verify-base64',
                [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Evidence | ConvertTo-Json -Compress))))
        }
    $encodedArguments = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $arguments -Compress)))
    $interpreter = if ($null -eq $Evidence) { 'python3' } else { '/usr/local/libexec/linuxbroker/python3' }
    return @"
$interpreter -I - <<'BROKER_IDLE_PROBE'
import base64, json, sys
sys.dont_write_bytecode = True
sys.argv = json.loads(base64.b64decode('$encodedArguments').decode('utf-8'))
exec(compile(base64.b64decode('$encodedSource').decode('utf-8'), '<broker-idle-lease>', 'exec'))
BROKER_IDLE_PROBE
"@
}

function Get-BrokerIdleLeaseObservation {
    param([Parameter(Mandatory)]$HostRecord)
    $output = Invoke-BrokerVmScript -ResourceId $HostRecord.ResourceId -CommandId RunShellScript `
        -Script (Get-BrokerIdleLeaseScript) -Operation "Inspect protected idle marker on '$($HostRecord.Name)'" -ReturnOutput
    $lines = @($output -split "`r?`n" | Where-Object { $_.StartsWith('BROKER_IDLE_METADATA=') })
    if ($lines.Count -ne 1 -or $lines[0].Length -gt 4096) { throw 'The idle host did not return bounded verified marker metadata.' }
    return ConvertFrom-Json -InputObject $lines[0].Substring('BROKER_IDLE_METADATA='.Length) -AsHashtable
}

function Get-BrokerIdleLeaseEvidence {
    param([Parameter(Mandatory)]$Connection, [Parameter(Mandatory)][string]$Hostname, [Parameter(Mandatory)][hashtable]$Observation)
    if ($Observation.kind -eq 'absent') { return @{ kind = 'absent' } }
    if ($Observation.kind -ne 'cleaned' -or $Observation.sha256 -notmatch '^[a-f0-9]{64}$' -or
        ($Observation.generation -isnot [int] -and $Observation.generation -isnot [long]) -or
        $Observation.generation -lt 1 -or $Observation.generation -gt 9007199254740991L) {
        throw 'The idle host returned invalid tombstone metadata.'
    }
    Assert-BrokerLinuxIdentity -Username $Observation.username -Uid $Observation.uid
    $command = $Connection.CreateCommand()
    $command.CommandTimeout = 60
    $command.CommandText = @'
SELECT u.username AS Username, u.uid AS Uid,
       CASE WHEN COALESCE(g.Generation, 0) > v.LeaseGeneration THEN g.Generation ELSE v.LeaseGeneration END AS HostFence
FROM dbo.VirtualMachines v
LEFT JOIN dbo.BrokerHostGenerations g ON g.Hostname = v.Hostname
JOIN dbo.VmUsers u ON u.username COLLATE Latin1_General_100_BIN2 = @Username COLLATE Latin1_General_100_BIN2 AND u.uid = @Uid
WHERE v.Hostname = @Hostname AND v.Username IS NULL AND v.LeaseId IS NULL
  AND v.OwnerObjectId IS NULL AND v.OwnerTenantId IS NULL AND v.OperationId IS NULL;
'@
    $null = $command.Parameters.Add('@Hostname', [Data.SqlDbType]::NVarChar, 255)
    $null = $command.Parameters.Add('@Username', [Data.SqlDbType]::NVarChar, 255)
    $null = $command.Parameters.Add('@Uid', [Data.SqlDbType]::Int)
    $command.Parameters['@Hostname'].Value = $Hostname
    $command.Parameters['@Username'].Value = $Observation.username
    $command.Parameters['@Uid'].Value = $Observation.uid
    try {
        $reader = $command.ExecuteReader()
        try {
            if (-not $reader.Read() -or $reader['Username'] -cne $Observation.username -or
                $reader['Uid'] -ne $Observation.uid -or $reader['HostFence'] -lt $Observation.generation) {
                throw "Idle host '$Hostname' does not match retained VmUsers identity and the persisted SQL fence."
            }
            $evidence = @{
                kind = 'cleaned'; username = [string]$reader['Username']; uid = [int]$reader['Uid']
                fence = [long]$reader['HostFence']; sha256 = $Observation.sha256
            }
            if ($evidence.fence -lt 0 -or $evidence.fence -gt 9007199254740991L) {
                throw 'The persisted SQL host fence is outside the supported exact-integer range.'
            }
            if ($reader.Read()) { throw 'The retained idle-host identity mapping is ambiguous.' }
            return $evidence
        }
        finally { $reader.Dispose() }
    }
    finally { $command.Dispose() }
}
