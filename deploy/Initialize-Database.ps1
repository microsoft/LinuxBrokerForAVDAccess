[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SqlServerFqdn,

    [Parameter(Mandatory = $true)]
    [string]$DatabaseName,

    [Parameter(Mandatory = $true)]
    [string]$SqlAdminLogin,

    [Parameter(Mandatory = $true)]
    [string]$SqlAdminPassword,

    [Parameter(Mandatory = $true)]
    [string]$ScriptsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Broker.Deployment.Common.ps1"
. "$PSScriptRoot\Broker.HostRegistration.ps1"

function Get-SqlConnection {
    param(
        [Parameter(Mandatory = $true)][string]$Server,
        [Parameter(Mandatory = $true)][string]$Database,
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password
    )

    return New-BrokerSqlConnection -Server $Server -Database $Database -Username $Username -Password $Password
}

function Convert-SqlScriptContent {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    $normalizedContent = $Content -replace "`r`n", "`n"

    if ($FileName -match 'create_procedure|alter_procedure') {
        $normalizedContent = [System.Text.RegularExpressions.Regex]::Replace(
            $normalizedContent,
            '(?im)^\s*(CREATE|ALTER)\s+PROCEDURE\b',
            'CREATE OR ALTER PROCEDURE'
        )
    }

    return $normalizedContent
}

function Split-SqlBatches {
    param([Parameter(Mandatory = $true)][string]$Content)

    return [System.Text.RegularExpressions.Regex]::Split($Content, '(?im)^\s*GO\s*$') |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Invoke-SqlBatch {
    param(
        [Parameter(Mandatory = $true)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory = $true)][string]$Batch,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][int]$BatchNumber
    )

    $command = $Connection.CreateCommand()
    $command.CommandText = $Batch
    $command.CommandTimeout = 120

    try {
        [void]$command.ExecuteNonQuery()
    }
    catch {
        throw "Failed executing batch $BatchNumber from '$FileName': $($_.Exception.Message)"
    }
    finally {
        $command.Dispose()
    }
}

if ($env:SKIP_SQL_BOOTSTRAP -eq 'true') {
    throw 'SKIP_SQL_BOOTSTRAP cannot bypass the authorization/lifecycle schema upgrade. Leave checkout paused and apply the complete ordered schema.'
}

$resolvedScriptsPath = Resolve-Path $ScriptsPath -ErrorAction Stop
$sqlFiles = Get-ChildItem -Path $resolvedScriptsPath -Filter '*.sql' | Sort-Object Name

if (-not $sqlFiles) {
    throw "No SQL files found in $resolvedScriptsPath."
}

$connection = Get-SqlConnection -Server $SqlServerFqdn -Database $DatabaseName -Username $SqlAdminLogin -Password $SqlAdminPassword

# Without this, PRINT output from the scripts is discarded and diagnostics go unnoticed.
$connection.add_InfoMessage({
    param($eventSender, $eventArgs)

    foreach ($sqlMessage in $eventArgs.Errors) {
        Write-Host "  [SQL] $($sqlMessage.Message)"
    }
})

try {
    $connection.Open()

    foreach ($sqlFile in $sqlFiles) {
        Write-Host "Applying $($sqlFile.Name)"

        $scriptContent = Get-Content -Path $sqlFile.FullName -Raw -Encoding UTF8
        $convertedContent = Convert-SqlScriptContent -Content $scriptContent -FileName $sqlFile.Name
        $batches = @(Split-SqlBatches -Content $convertedContent)

        for ($index = 0; $index -lt $batches.Count; $index++) {
            Invoke-SqlBatch -Connection $connection -Batch $batches[$index] -FileName $sqlFile.Name -BatchNumber ($index + 1)
        }
    }
    Assert-BrokerTrustedInventorySchema -Connection $connection
}
finally {
    if ($connection.State -ne [System.Data.ConnectionState]::Closed) {
        $connection.Close()
    }

    $connection.Dispose()
}
