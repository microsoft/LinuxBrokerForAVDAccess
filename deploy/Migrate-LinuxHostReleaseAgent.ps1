[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$TenantId,
    [string]$VmSubscriptionId,
    [ValidateSet('Quiesce', 'Install', 'Activate')][string]$Mode = 'Install',
    [string]$ApiBaseUrl,
    [string]$ApiClientId,
    [string]$SqlServerFqdn,
    [string]$DatabaseName,
    [string]$SqlAdminLogin,
    [string]$SqlAdminPassword,
    [string]$LinuxHostAdminLoginName = 'avdadmin',
    [string]$SourceRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$PythonRuntimeUri,
    [switch]$EnrollDrainedLegacyHosts,
    [ValidateRange(1, 300)][int]$WatcherDebounceSeconds = 10,
    [ValidateRange(0, 60)][int]$WatcherSettleSeconds = 2,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Broker.LinuxMigration.ps1"
Assert-BrokerTenant $TenantId
$hosts = @(Get-BrokerLinuxInventory -ResourceGroupName $ResourceGroupName -TenantId $TenantId -SubscriptionId $VmSubscriptionId)
if ($Mode -ne 'Install') {
    foreach ($hostRecord in $hosts) {
        if ($DryRun) { Write-Host "Would $Mode release agents on '$($hostRecord.Name)' without touching RDP sessions."; continue }
        $script = if ($Mode -eq 'Quiesce') { Get-BrokerAgentQuiesceScript } else { Get-BrokerAgentActivationScript }
        Invoke-BrokerVmScript -ResourceId $hostRecord.ResourceId -CommandId RunShellScript -Script $script -Operation "$Mode Linux agent '$($hostRecord.Name)'"
    }
    return
}
foreach ($value in @($ApiBaseUrl, $ApiClientId, $SqlServerFqdn, $DatabaseName, $SqlAdminLogin, $SqlAdminPassword)) {
    if ([string]::IsNullOrWhiteSpace($value)) { throw 'Agent installation requires API configuration and trusted deployment SQL credentials. It cannot bypass reviewed lease-state validation.' }
}
$connection = New-BrokerSqlConnection -Server $SqlServerFqdn -Database $DatabaseName -Username $SqlAdminLogin -Password $SqlAdminPassword
$plans = @()
try {
    $connection.Open()
    Assert-BrokerMigrationInventory -Hosts $hosts -DatabaseHostnames @(Get-BrokerSqlHostnames -Connection $connection)
    foreach ($hostRecord in $hosts) {
        $rows = @(Invoke-BrokerSqlProcedure -Connection $connection -Name GetBrokerLeaseMigrationState -Parameters @{ Hostname = $hostRecord.Name })
        $lease = Test-BrokerMigrationLease -Rows $rows -Hostname $hostRecord.Name
        $idleEvidence = $null
        if (-not $lease -and -not $DryRun) {
            $observation = Get-BrokerIdleLeaseObservation -HostRecord $hostRecord
            $idleEvidence = Get-BrokerIdleLeaseEvidence -Connection $connection -Hostname $hostRecord.Name -Observation $observation
        }
        $plans += @{ HostRecord = $hostRecord; Lease = $lease; IdleEvidence = $idleEvidence }
    }
}
finally { $connection.Dispose() }
foreach ($plan in $plans) {
    $hostRecord = $plan.HostRecord
    if ($DryRun -and -not $plan.Lease) {
        Write-Host "SQL reports no active lease for '$($hostRecord.Name)'. Root tombstone inspection and retained SQL identity/fence verification are still mandatory during the paused installation."
        continue
    }
    $script = New-BrokerAgentInstallScript -ApiBaseUrl $ApiBaseUrl -ApiClientId $ApiClientId -Hostname $hostRecord.Name `
        -AdminUsername $LinuxHostAdminLoginName -SourceRoot $SourceRoot -Lease $plan.Lease `
        -IdleEvidence $plan.IdleEvidence `
        -EnrollDrainedLegacyHosts:$EnrollDrainedLegacyHosts `
        -PythonRuntimeUri $PythonRuntimeUri `
        -WatcherDebounceSeconds $WatcherDebounceSeconds -WatcherSettleSeconds $WatcherSettleSeconds
    if ($DryRun) {
        Write-Host "Validated SQL lease state and local payload for '$($hostRecord.Name)'. Guest marker/account checks will be mandatory during installation."
        continue
    }
    Invoke-BrokerVmScript -ResourceId $hostRecord.ResourceId -CommandId RunShellScript -Script $script `
        -Operation "Install compatible agent and migrate guarded lease on '$($hostRecord.Name)'"
    Write-Host "Staged compatible agent on '$($hostRecord.Name)'; existing sessions/profiles were not reclaimed."
}
