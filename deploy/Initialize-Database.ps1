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

if ($env:SKIP_SQL_BOOTSTRAP -eq 'true') {
    Write-Host 'Skipping SQL bootstrap because SKIP_SQL_BOOTSTRAP=true.'
    exit 0
}

$resolvedScriptsPath = Resolve-Path $ScriptsPath -ErrorAction Stop
$sqlFiles = Get-ChildItem -Path $resolvedScriptsPath -Filter '*.sql' | Sort-Object Name

if (-not $sqlFiles) {
    Write-Host "No SQL files found in $resolvedScriptsPath."
    exit 0
}

$invokeSqlCmd = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue
$sqlcmdExe = Get-Command sqlcmd -ErrorAction SilentlyContinue

if (-not $invokeSqlCmd -and -not $sqlcmdExe) {
    Write-Warning 'Skipping SQL bootstrap because neither Invoke-Sqlcmd nor sqlcmd is available on this machine.'
    exit 0
}

foreach ($sqlFile in $sqlFiles) {
    Write-Host "Applying $($sqlFile.Name)"
    try {
        if ($invokeSqlCmd) {
            Invoke-Sqlcmd -ServerInstance $SqlServerFqdn -Database $DatabaseName -Username $SqlAdminLogin -Password $SqlAdminPassword -InputFile $sqlFile.FullName -Encrypt Mandatory -TrustServerCertificate:$false | Out-Null
        }
        else {
            & $sqlcmdExe.Source -S $SqlServerFqdn -d $DatabaseName -U $SqlAdminLogin -P $SqlAdminPassword -N -i $sqlFile.FullName | Out-Null
        }
    }
    catch {
        Write-Warning "SQL bootstrap stopped on $($sqlFile.Name): $($_.Exception.Message)"
        exit 0
    }
}
