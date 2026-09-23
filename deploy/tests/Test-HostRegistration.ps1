#requires -Version 7.4
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'Broker.HostRegistration.ps1')
$script:checks = 0
function Check {
    param([bool]$Condition, [string]$Message)
    $script:checks++
    if (-not $Condition) { throw "Trusted inventory check failed: $Message" }
}
function Reject {
    param([scriptblock]$Action)
    $script:checks++
    try { & $Action | Out-Null; throw 'Expected trusted inventory rejection was not raised.' }
    catch { if ($_.Exception.Message -eq 'Expected trusted inventory rejection was not raised.') { throw } }
}
$script:schemaReady = 1
$script:schemaQuery = ''
$connection = [pscustomobject]@{}
$connection | Add-Member -MemberType ScriptMethod -Name CreateCommand -Value {
    $command = [pscustomobject]@{ CommandText = ''; CommandTimeout = 0 }
    $command | Add-Member -MemberType ScriptMethod -Name ExecuteScalar -Value {
        $script:schemaQuery = $this.CommandText
        return $script:schemaReady
    }
    $command | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
    return $command
}
Assert-BrokerTrustedInventorySchema -Connection $connection
Check ($script:schemaQuery.Contains('BrokerHostInventory') -and $script:schemaQuery.Contains('InvalidateBrokerHostInventory') -and
    $script:schemaQuery.Contains('Retired')) 'Schema readiness requires the 046 receipt/trigger/retirement structures.'
$script:schemaReady = 0
Reject { Assert-BrokerTrustedInventorySchema -Connection $connection }
$script:schemaReady = 1

$transaction = [pscustomobject]@{ Id = 'same-trusted-transaction' }
$records = @(
    [pscustomobject]@{
        Name = 'linux-01'; IPAddress = '10.0.0.4'; TenantId = 'aaaaaaaa-aaaa-4aaa-8aaa-000000000001'
        ObjectId = 'aaaaaaaa-aaaa-4aaa-8aaa-000000000002'
        ResourceId = '/subscriptions/aaaaaaaa-aaaa-4aaa-8aaa-000000000003/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/linux-01'
    }
    [pscustomobject]@{
        Name = 'linux-02'; IPAddress = '10.0.0.5'; TenantId = 'aaaaaaaa-aaaa-4aaa-8aaa-000000000001'
        ObjectId = 'aaaaaaaa-aaaa-4aaa-8aaa-000000000004'
        ResourceId = '/subscriptions/aaaaaaaa-aaaa-4aaa-8aaa-000000000003/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/linux-02'
    }
)
$script:calls = [Collections.Generic.List[object]]::new()
$script:receipts = @{}
$script:failImport = $false
function Invoke-BrokerSqlProcedure {
    param($Connection, $Transaction, $Name, $Parameters)
    Check ($Transaction.Id -eq 'same-trusted-transaction') 'Import and enrollment share the trusted outer transaction.'
    $script:calls.Add(@{ Name = $Name; Parameters = $Parameters })
    if ($Name -eq 'RegisterLinuxHostVm') {
        if ($script:failImport) { throw 'Synthetic trusted import failure.' }
        $script:receipts[$Parameters.Hostname] = $Parameters.IPAddress
    }
    elseif ($Name -eq 'RegisterBrokerHost') {
        if (-not $script:receipts.ContainsKey($Parameters.Hostname)) { throw 'Enrollment without a trusted endpoint receipt.' }
    }
    else { throw 'Unexpected deployment procedure.' }
}
Register-BrokerInventoryHosts -Connection $connection -Transaction $transaction -Hosts $records
Register-BrokerInventoryHosts -Connection $connection -Transaction $transaction -Hosts $records
Check ($script:calls.Count -eq 8) 'Every intended host is imported and enrolled again on an unchanged rerun.'
for ($index = 0; $index -lt $script:calls.Count; $index += 2) {
    $import = $script:calls[$index]
    $enrollment = $script:calls[$index + 1]
    Check ($import.Name -eq 'RegisterLinuxHostVm' -and $enrollment.Name -eq 'RegisterBrokerHost') 'Trusted import always precedes identity activation.'
    Check ($import.Parameters.Hostname -eq $enrollment.Parameters.Hostname) 'Receipt and identity refer to the same ARM host.'
    Check ($enrollment.Parameters.ResourceId.EndsWith('/' + $import.Parameters.Hostname)) 'Frozen enrollment receives the verified ARM resource ID.'
}
$script:failImport = $true
$priorCalls = $script:calls.Count
Reject { Register-BrokerInventoryHosts -Connection $connection -Transaction $transaction -Hosts @($records[0]) }
Check ($script:calls.Count -eq $priorCalls + 1 -and $script:calls[-1].Name -eq 'RegisterLinuxHostVm') 'A failed receipt import cannot be followed by identity activation.'
Write-Host "PASS: $script:checks trusted inventory enrollment checks with SQL boundaries mocked."
