. "$PSScriptRoot\Broker.Deployment.Common.ps1"

function Assert-BrokerTrustedInventorySchema {
    param([Parameter(Mandatory)]$Connection)
    $command = $Connection.CreateCommand()
    $command.CommandText = @'
SELECT CASE WHEN OBJECT_ID(N'dbo.BrokerHostInventory', N'U') IS NOT NULL
                  AND OBJECT_ID(N'dbo.InvalidateBrokerHostInventory', N'TR') IS NOT NULL
                  AND COL_LENGTH(N'dbo.BrokerHosts', N'Retired') IS NOT NULL
            THEN 1 ELSE 0 END;
'@
    $command.CommandTimeout = 60
    try {
        if ($command.ExecuteScalar() -ne 1) {
            throw 'Apply the complete schema through 046 before trusted host enrollment. A hostname-only legacy binding is not sufficient.'
        }
    }
    finally { $command.Dispose() }
}

function Register-BrokerInventoryHosts {
    param([Parameter(Mandatory)]$Connection, [Parameter(Mandatory)]$Transaction, [AllowEmptyCollection()][array]$Hosts)
    foreach ($hostRecord in $Hosts) {
        # Every run imports the verified endpoint first, even if the row/address already exists.
        $null = Invoke-BrokerSqlProcedure -Connection $Connection -Transaction $Transaction -Name RegisterLinuxHostVm -Parameters @{
            Hostname = $hostRecord.Name; IPAddress = $hostRecord.IPAddress; Description = 'Registered from trusted ARM deployment inventory'
        }
        $null = Invoke-BrokerSqlProcedure -Connection $Connection -Transaction $Transaction -Name RegisterBrokerHost -Parameters @{
            TenantId = $hostRecord.TenantId; ObjectId = $hostRecord.ObjectId
            Hostname = $hostRecord.Name; ResourceId = $hostRecord.ResourceId
        }
        Write-Host "Imported verified ARM endpoint and enrolled host '$($hostRecord.Name)' -> identity '$($hostRecord.ObjectId)'."
    }
}
