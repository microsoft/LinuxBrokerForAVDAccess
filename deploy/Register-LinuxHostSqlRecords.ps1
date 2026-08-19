[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$SqlServerFqdn,

    [Parameter(Mandatory = $true)]
    [string]$DatabaseName,

    [Parameter(Mandatory = $true)]
    [string]$SqlAdminLogin,

    [Parameter(Mandatory = $true)]
    [string]$SqlAdminPassword
)

$ErrorActionPreference = 'Stop'

function Get-SqlConnection {
    param(
        [Parameter(Mandatory = $true)][string]$Server,
        [Parameter(Mandatory = $true)][string]$Database,
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password
    )

    $connectionString = "Server=tcp:$Server,1433;Initial Catalog=$Database;Persist Security Info=False;User ID=$Username;Password=$Password;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
    return [System.Data.SqlClient.SqlConnection]::new($connectionString)
}

function Invoke-LinuxHostRegistration {
    param(
        [Parameter(Mandatory = $true)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory = $true)]$VirtualMachine
    )

    $privateIpAddress = (($VirtualMachine.privateIps | Out-String).Trim().Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($privateIpAddress)) {
        Write-Warning "Skipping VM '$($VirtualMachine.name)' because no private IP address was resolved."
        return
    }

    $command = $Connection.CreateCommand()
    $command.CommandText = 'EXEC dbo.RegisterLinuxHostVm @Hostname, @IPAddress, @Description;'
    $command.CommandTimeout = 60

    [void]$command.Parameters.Add('@Hostname', [System.Data.SqlDbType]::NVarChar, 255)
    [void]$command.Parameters.Add('@IPAddress', [System.Data.SqlDbType]::NVarChar, 50)
    [void]$command.Parameters.Add('@Description', [System.Data.SqlDbType]::NVarChar, -1)

    $command.Parameters['@Hostname'].Value = $VirtualMachine.name
    $command.Parameters['@IPAddress'].Value = $privateIpAddress
    $command.Parameters['@Description'].Value = 'Registered by azd post-provision'

    try {
        $reader = $command.ExecuteReader()
        try {
            if ($reader.Read()) {
                Write-Host "Registered Linux host '$($VirtualMachine.name)' in SQL using action '$($reader['RegistrationAction'])'."
            }
            else {
                Write-Host "Registered Linux host '$($VirtualMachine.name)' in SQL."
            }
        }
        finally {
            $reader.Close()
        }
    }
    finally {
        $command.Dispose()
    }
}

$linuxHosts = az vm list --resource-group $ResourceGroupName --show-details --output json | ConvertFrom-Json |
    Where-Object { $_.tags.'broker-role' -eq 'linux-host' }

if (-not $linuxHosts) {
    Write-Host "No Linux host VMs found in resource group '$ResourceGroupName'."
    exit 0
}

$connection = Get-SqlConnection -Server $SqlServerFqdn -Database $DatabaseName -Username $SqlAdminLogin -Password $SqlAdminPassword

try {
    $connection.Open()

    foreach ($linuxHost in $linuxHosts) {
        Invoke-LinuxHostRegistration -Connection $connection -VirtualMachine $linuxHost
    }
}
finally {
    if ($connection.State -ne [System.Data.ConnectionState]::Closed) {
        $connection.Close()
    }

    $connection.Dispose()
}