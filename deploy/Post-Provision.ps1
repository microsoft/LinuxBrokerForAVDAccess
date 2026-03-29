[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$TaskAppName,

    [Parameter(Mandatory = $false)]
    [string]$ApiClientId,

    [Parameter(Mandatory = $false)]
    [string]$SqlServerFqdn,

    [Parameter(Mandatory = $false)]
    [string]$DatabaseName,

    [Parameter(Mandatory = $false)]
    [string]$SqlAdminLogin,

    [Parameter(Mandatory = $false)]
    [string]$SqlAdminPassword,

    [Parameter(Mandatory = $false)]
    [string]$ScriptsPath,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$EnvironmentName
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
    $EnvironmentName = if (-not [string]::IsNullOrWhiteSpace($env:AZURE_ENV_NAME)) {
        $env:AZURE_ENV_NAME
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:AZURE_ENVIRONMENT_NAME)) {
        $env:AZURE_ENVIRONMENT_NAME
    }
    else {
        throw 'EnvironmentName was not provided and AZURE_ENV_NAME is not set.'
    }
}

function Get-AzdEnvValue {
    param([Parameter(Mandatory = $true)][string]$Key)

    $value = azd env get-value $Key --environment $EnvironmentName 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ''
    }

    return ($value | Out-String).Trim()
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $ResourceGroupName = Get-AzdEnvValue -Key 'resourceGroupName'
}

if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $SubscriptionId = Get-AzdEnvValue -Key 'AZURE_SUBSCRIPTION_ID'
}

if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $SubscriptionId = $env:AZURE_SUBSCRIPTION_ID
}

if ([string]::IsNullOrWhiteSpace($TaskAppName)) {
    $TaskAppName = Get-AzdEnvValue -Key 'taskAppName'
}

if ([string]::IsNullOrWhiteSpace($ApiClientId)) {
    $ApiClientId = Get-AzdEnvValue -Key 'apiClientId'
}

if ([string]::IsNullOrWhiteSpace($DatabaseName)) {
    $DatabaseName = (Get-AzdEnvValue -Key 'sqlDatabaseName')
    if ([string]::IsNullOrWhiteSpace($DatabaseName)) {
        $DatabaseName = Get-AzdEnvValue -Key 'sqlDatabaseName'
    }
}

if ([string]::IsNullOrWhiteSpace($SqlAdminLogin)) {
    $SqlAdminLogin = Get-AzdEnvValue -Key 'sqlAdminLogin'
}

if ([string]::IsNullOrWhiteSpace($SqlAdminPassword)) {
    $SqlAdminPassword = Get-AzdEnvValue -Key 'sqlAdminPassword'
}

if ([string]::IsNullOrWhiteSpace($ScriptsPath)) {
    $ScriptsPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'sql_queries'
}

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    az account set --subscription $SubscriptionId | Out-Null
}

if ([string]::IsNullOrWhiteSpace($SqlServerFqdn)) {
    $sqlServerName = Get-AzdEnvValue -Key 'sqlServerName'
    if (-not [string]::IsNullOrWhiteSpace($sqlServerName) -and -not [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
        $SqlServerFqdn = az sql server show --name $sqlServerName --resource-group $ResourceGroupName --query fullyQualifiedDomainName --output tsv
    }
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName) -or [string]::IsNullOrWhiteSpace($TaskAppName) -or [string]::IsNullOrWhiteSpace($ApiClientId) -or [string]::IsNullOrWhiteSpace($SqlServerFqdn) -or [string]::IsNullOrWhiteSpace($DatabaseName) -or [string]::IsNullOrWhiteSpace($SqlAdminLogin) -or [string]::IsNullOrWhiteSpace($SqlAdminPassword)) {
    throw 'Post-provision inputs could not be fully resolved from parameters or azd environment values.'
}

& "$PSScriptRoot/Build-ContainerImages.ps1"

& "$PSScriptRoot/Initialize-Database.ps1" `
    -SqlServerFqdn $SqlServerFqdn `
    -DatabaseName $DatabaseName `
    -SqlAdminLogin $SqlAdminLogin `
    -SqlAdminPassword $SqlAdminPassword `
    -ScriptsPath $ScriptsPath

& "$PSScriptRoot/Assign-FunctionAppApiRole.ps1" `
    -ResourceGroupName $ResourceGroupName `
    -TaskAppName $TaskAppName `
    -ApiClientId $ApiClientId

& "$PSScriptRoot/Assign-VmApiRoles.ps1" `
    -ResourceGroupName $ResourceGroupName `
    -ApiClientId $ApiClientId
