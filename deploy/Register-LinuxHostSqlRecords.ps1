[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$TenantId,
    [string]$VmSubscriptionId,
    [Parameter(Mandatory)][string]$SqlServerFqdn,
    [Parameter(Mandatory)][string]$DatabaseName,
    [Parameter(Mandatory)][string]$SqlAdminLogin,
    [Parameter(Mandatory)][string]$SqlAdminPassword,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Broker.HostRegistration.ps1"
Assert-BrokerTenant $TenantId
$hosts = @(Get-BrokerLinuxInventory -ResourceGroupName $ResourceGroupName -TenantId $TenantId -SubscriptionId $VmSubscriptionId)
$connection = New-BrokerSqlConnection -Server $SqlServerFqdn -Database $DatabaseName -Username $SqlAdminLogin -Password $SqlAdminPassword
$transaction = $null
try {
    $connection.Open()
    Assert-BrokerTrustedInventorySchema -Connection $connection
    $transaction = $connection.BeginTransaction()
    Register-BrokerInventoryHosts -Connection $connection -Transaction $transaction -Hosts $hosts
    if ($DryRun) { $transaction.Rollback(); Write-Host 'Host registration dry run rolled back.' }
    else { $transaction.Commit() }
}
finally {
    if ($transaction) {
        if ($transaction.Connection) { $transaction.Rollback() }
        $transaction.Dispose()
    }
    $connection.Dispose()
}
