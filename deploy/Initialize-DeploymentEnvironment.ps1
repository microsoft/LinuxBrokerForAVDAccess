[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateLength(3, 12)]
    [ValidatePattern('^[a-zA-Z0-9]+$')]
    [string]$AppName,

    [Parameter(Mandatory = $false)]
    [ValidateLength(2, 16)]
    [ValidatePattern('^[a-zA-Z0-9-]+$')]
    [string]$EnvironmentName
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($AppName)) {
    $AppName = if (-not [string]::IsNullOrWhiteSpace($env:AZURE_APP_NAME)) {
        $env:AZURE_APP_NAME
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:APP_NAME)) {
        $env:APP_NAME
    }
    else {
        'linuxbroker'
    }
}

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

$graphAppId = '00000003-0000-0000-c000-000000000000'
$frontendGraphDelegatedPermissions = @(
    @{ name = 'User.Read'; id = 'e1fe6dd8-ba31-4d61-89e7-88639da4683d' }
    @{ name = 'profile'; id = '14dad69e-099b-42c9-810b-d002981feec1' }
    @{ name = 'email'; id = '64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0' }
    @{ name = 'Group.Read.All'; id = '5f8c59db-677d-491f-a6b8-5f174b11ec1d' }
    @{ name = 'offline_access'; id = '7427e0e9-2fba-42fe-b0c0-848c9e6a8182' }
    @{ name = 'openid'; id = '37f7f235-527c-4136-accd-4a02d197296e' }
)

$apiScopeId = '58db6e6d-38d5-4ce2-bf0a-7fd9cfd5f00a'
$apiRoleIds = @{
    FullAccess = '4b2d5f7f-7cc1-4303-8d4b-bd7d2cfe2ca6'
    ScheduledTask = 'd11a6ed0-ee5e-4305-a2a2-252a8107d84f'
    AvdHost = '2dd7deea-1e20-4f32-a733-c6f6ec1d2519'
    LinuxHost = '29a8a5a0-2090-4e94-a49d-3386640f0058'
}

function Get-CloudContext {
    $cloud = az cloud show --output json | ConvertFrom-Json

    switch ($cloud.name) {
        'AzureUSGovernment' {
            return @{
                Name = $cloud.name
                GraphUrl = 'https://graph.microsoft.us'
                AppServiceDomain = 'azurewebsites.us'
            }
        }
        default {
            return @{
                Name = $cloud.name
                GraphUrl = 'https://graph.microsoft.com'
                AppServiceDomain = 'azurewebsites.net'
            }
        }
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

function Set-AzdEnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    azd env set $Key $Value --environment $EnvironmentName | Out-Null
}

function New-RandomSecret {
    param([int]$Length = 40)

    $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@$%^*-_=+'
    $bytes = New-Object byte[] ($Length)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)

    $builder = New-Object System.Text.StringBuilder
    foreach ($byte in $bytes) {
        [void]$builder.Append($alphabet[$byte % $alphabet.Length])
    }

    return $builder.ToString()
}

function Ensure-DefaultEnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][scriptblock]$ValueFactory
    )

    $existing = Get-AzdEnvValue -Key $Key
    if ([string]::IsNullOrWhiteSpace($existing)) {
        $value = & $ValueFactory
        Set-AzdEnvValue -Key $Key -Value $value
        return $value
    }

    return $existing
}

function Get-JsonFilePath {
    $path = [System.IO.Path]::GetTempFileName()
    return [System.IO.Path]::ChangeExtension($path, '.json')
}

function Write-JsonFile {
    param([Parameter(Mandatory = $true)]$InputObject)

    $path = Get-JsonFilePath
    $InputObject | ConvertTo-Json -Depth 20 | Set-Content -Path $path -Encoding utf8
    return $path
}

function Get-MatchingApp {
    param([Parameter(Mandatory = $true)][string]$DisplayName)

    $apps = az ad app list --display-name $DisplayName --output json | ConvertFrom-Json
    if ($apps -is [System.Array]) {
        return $apps | Where-Object { $_.displayName -eq $DisplayName } | Select-Object -First 1
    }

    if ($apps -and $apps.displayName -eq $DisplayName) {
        return $apps
    }

    return $null
}

function Ensure-ServicePrincipal {
    param([Parameter(Mandatory = $true)][string]$AppId)

    $servicePrincipals = az ad sp list --filter "appId eq '$AppId'" --output json | ConvertFrom-Json
    $existing = $servicePrincipals | Select-Object -First 1
    if ($existing) {
        return $existing
    }

    return az ad sp create --id $AppId --output json | ConvertFrom-Json
}

function Ensure-ClientSecret {
    param(
        [Parameter(Mandatory = $true)]$Application,
        [Parameter(Mandatory = $true)][string]$EnvClientIdKey,
        [Parameter(Mandatory = $true)][string]$EnvSecretKey
    )

    $existingClientId = Get-AzdEnvValue -Key $EnvClientIdKey
    $existingSecret = Get-AzdEnvValue -Key $EnvSecretKey

    Set-AzdEnvValue -Key $EnvClientIdKey -Value $Application.appId

    if (-not [string]::IsNullOrWhiteSpace($existingSecret) -and $existingClientId -eq $Application.appId) {
        return $existingSecret
    }

    $secret = az ad app credential reset --id $Application.appId --append --output json | ConvertFrom-Json
    Set-AzdEnvValue -Key $EnvSecretKey -Value $secret.password
    return $secret.password
}

function Ensure-Group {
    param([Parameter(Mandatory = $true)][string]$DisplayName)

    $groups = az ad group list --filter "displayName eq '$DisplayName'" --output json | ConvertFrom-Json
    $existing = $groups | Select-Object -First 1
    if ($existing) {
        return $existing
    }

    return az ad group create --display-name $DisplayName --mail-nickname $DisplayName --output json | ConvertFrom-Json
}

function Ensure-FrontendApplication {
    param(
        [Parameter(Mandatory = $true)][hashtable]$CloudContext,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$AppServiceName,
        [Parameter(Mandatory = $true)][string]$ApiAppId
    )

    $redirectBase = "https://$AppServiceName.$($CloudContext.AppServiceDomain)"
    $redirectUris = @(
        "$redirectBase/.auth/login/aad/callback"
        "$redirectBase/getAToken"
    )

    $app = Get-MatchingApp -DisplayName $DisplayName
    if (-not $app) {
        $app = az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg --web-redirect-uris $redirectUris --output json | ConvertFrom-Json
    }

    az ad app update --id $app.id --web-redirect-uris $redirectUris --web-home-page-url $redirectBase --enable-access-token-issuance true --enable-id-token-issuance true | Out-Null

    $requiredResources = @(
        @{
            resourceAppId = $graphAppId
            resourceAccess = @($frontendGraphDelegatedPermissions | ForEach-Object {
                @{
                    id = $_.id
                    type = 'Scope'
                }
            })
        }
        @{
            resourceAppId = $ApiAppId
            resourceAccess = @(
                @{
                    id = $apiScopeId
                    type = 'Scope'
                }
            )
        }
    )

    $requiredResourcesFile = Write-JsonFile -InputObject $requiredResources
    try {
        az ad app update --id $app.id --required-resource-accesses "@$requiredResourcesFile" | Out-Null
    }
    finally {
        Remove-Item -Path $requiredResourcesFile -ErrorAction SilentlyContinue
    }

    $logoutBody = @{
        web = @{
            logoutUrl = "$redirectBase/logout"
        }
    }

    $logoutPayload = $logoutBody | ConvertTo-Json -Depth 10 -Compress
    az rest --method PATCH --url "$($CloudContext.GraphUrl)/v1.0/applications/$($app.id)" --headers 'Content-Type=application/json' --body $logoutPayload | Out-Null

    return $app
}

function Ensure-ApiApplication {
    param(
        [Parameter(Mandatory = $true)][hashtable]$CloudContext,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    $app = Get-MatchingApp -DisplayName $DisplayName
    if (-not $app) {
        $app = az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg --output json | ConvertFrom-Json
    }

    az ad app update --id $app.id --identifier-uris "api://$($app.appId)" --requested-access-token-version 2 | Out-Null

    $apiManifest = @{
        identifierUris = @("api://$($app.appId)")
        api = @{
            requestedAccessTokenVersion = 2
            oauth2PermissionScopes = @(
                @{
                    adminConsentDescription = 'Allow the front end to access the Linux Broker API on behalf of the signed-in user.'
                    adminConsentDisplayName = 'Access Linux Broker API'
                    id = $apiScopeId
                    isEnabled = $true
                    type = 'User'
                    userConsentDescription = 'Allow the application to access the Linux Broker API on your behalf.'
                    userConsentDisplayName = 'Access Linux Broker API'
                    value = 'access_as_user'
                }
            )
        }
    }

    $manifestPayload = $apiManifest | ConvertTo-Json -Depth 20 -Compress
    az rest --method PATCH --url "$($CloudContext.GraphUrl)/v1.0/applications/$($app.id)" --headers 'Content-Type=application/json' --body $manifestPayload | Out-Null

    $appRoles = @(
        @{
            allowedMemberTypes = @('Application', 'User')
            description = 'Full access to Linux Broker management APIs.'
            displayName = 'Full Access'
            id = $apiRoleIds.FullAccess
            isEnabled = $true
            value = 'FullAccess'
        }
        @{
            allowedMemberTypes = @('Application')
            description = 'Allows the scheduled task function app to call maintenance endpoints.'
            displayName = 'Scheduled Task'
            id = $apiRoleIds.ScheduledTask
            isEnabled = $true
            value = 'ScheduledTask'
        }
        @{
            allowedMemberTypes = @('Application')
            description = 'Allows AVD host automation to call AVD-specific endpoints.'
            displayName = 'AVD Host'
            id = $apiRoleIds.AvdHost
            isEnabled = $true
            value = 'AvdHost'
        }
        @{
            allowedMemberTypes = @('Application')
            description = 'Allows Linux host automation to call Linux host endpoints.'
            displayName = 'Linux Host'
            id = $apiRoleIds.LinuxHost
            isEnabled = $true
            value = 'LinuxHost'
        }
    )

    $appRolesFile = Write-JsonFile -InputObject $appRoles
    try {
        az ad app update --id $app.id --app-roles "@$appRolesFile" | Out-Null
    }
    finally {
        Remove-Item -Path $appRolesFile -ErrorAction SilentlyContinue
    }

    $graphSp = az ad sp show --id $graphAppId --output json | ConvertFrom-Json
    $groupMemberReadAllRoleId = $graphSp.appRoles | Where-Object {
        $_.value -eq 'GroupMember.Read.All' -and $_.allowedMemberTypes -contains 'Application'
    } | Select-Object -ExpandProperty id -First 1

    if ($groupMemberReadAllRoleId) {
        $requiredResources = @(
            @{
                resourceAppId = $graphAppId
                resourceAccess = @(
                    @{
                        id = $groupMemberReadAllRoleId
                        type = 'Role'
                    }
                )
            }
        )

        $requiredResourcesFile = Write-JsonFile -InputObject $requiredResources
        try {
            az ad app update --id $app.id --required-resource-accesses "@$requiredResourcesFile" | Out-Null
        }
        finally {
            Remove-Item -Path $requiredResourcesFile -ErrorAction SilentlyContinue
        }
    }

    return $app
}

$cloudContext = Get-CloudContext

$frontendAppDisplayName = "$AppName-$EnvironmentName-frontend-ar"
$apiAppDisplayName = "$AppName-$EnvironmentName-api-ar"
$frontendAppServiceName = "$AppName-$EnvironmentName-fe"
$avdGroupName = "$AppName-$EnvironmentName-avd-hosts-sg"
$linuxGroupName = "$AppName-$EnvironmentName-linux-hosts-sg"

$subscription = az account show --output json | ConvertFrom-Json
$defaultTenantId = $subscription.tenantId

Ensure-DefaultEnvValue -Key 'appName' -ValueFactory { $AppName } | Out-Null
Ensure-DefaultEnvValue -Key 'environmentName' -ValueFactory { $EnvironmentName } | Out-Null
Ensure-DefaultEnvValue -Key 'AZURE_LOCATION' -ValueFactory {
    if (-not [string]::IsNullOrWhiteSpace($env:AZURE_LOCATION)) {
        $env:AZURE_LOCATION
    }
    else {
        'eastus2'
    }
} | Out-Null
Ensure-DefaultEnvValue -Key 'location' -ValueFactory { Get-AzdEnvValue -Key 'AZURE_LOCATION' } | Out-Null
Ensure-DefaultEnvValue -Key 'tenantId' -ValueFactory { $defaultTenantId } | Out-Null

Ensure-DefaultEnvValue -Key 'SQL_ADMIN_LOGIN' -ValueFactory { 'brokeradmin' } | Out-Null
Ensure-DefaultEnvValue -Key 'SQL_DATABASE_NAME' -ValueFactory { 'LinuxBroker' } | Out-Null
Ensure-DefaultEnvValue -Key 'APP_SERVICE_PLAN_SKU' -ValueFactory { 'P1v3' } | Out-Null
Ensure-DefaultEnvValue -Key 'LINUX_HOST_ADMIN_LOGIN_NAME' -ValueFactory { 'avdadmin' } | Out-Null
Ensure-DefaultEnvValue -Key 'DOMAIN_NAME' -ValueFactory { '' } | Out-Null
Ensure-DefaultEnvValue -Key 'NFS_SHARE' -ValueFactory { '' } | Out-Null
Ensure-DefaultEnvValue -Key 'VM_HOST_RESOURCE_GROUP' -ValueFactory { '' } | Out-Null
Ensure-DefaultEnvValue -Key 'ALLOWED_CLIENT_IP' -ValueFactory { '' } | Out-Null
Ensure-DefaultEnvValue -Key 'FLASK_SESSION_SECRET' -ValueFactory { New-RandomSecret -Length 48 } | Out-Null
Ensure-DefaultEnvValue -Key 'SQL_ADMIN_PASSWORD' -ValueFactory { New-RandomSecret -Length 32 } | Out-Null
Ensure-DefaultEnvValue -Key 'HOST_ADMIN_PASSWORD' -ValueFactory { New-RandomSecret -Length 32 } | Out-Null
Ensure-DefaultEnvValue -Key 'deployLinuxHosts' -ValueFactory { 'true' } | Out-Null
Ensure-DefaultEnvValue -Key 'deployAvdHosts' -ValueFactory { 'true' } | Out-Null
Ensure-DefaultEnvValue -Key 'linuxHostCount' -ValueFactory { '2' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdSessionHostCount' -ValueFactory { '1' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdHostPoolName' -ValueFactory { "$AppName-$EnvironmentName-hp" } | Out-Null
Ensure-DefaultEnvValue -Key 'avdVmNamePrefix' -ValueFactory { 'avdhost' } | Out-Null
Ensure-DefaultEnvValue -Key 'linuxHostVmNamePrefix' -ValueFactory { 'lnxhost' } | Out-Null
Ensure-DefaultEnvValue -Key 'linuxHostAuthType' -ValueFactory { 'Password' } | Out-Null
Ensure-DefaultEnvValue -Key 'linuxHostOsVersion' -ValueFactory { '24_04-lts' } | Out-Null
Ensure-DefaultEnvValue -Key 'linuxHostVmSize' -ValueFactory { 'Standard_D2s_v5' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdVmSize' -ValueFactory { 'Standard_D8s_v5' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdMaxSessionLimit' -ValueFactory { '5' } | Out-Null
Ensure-DefaultEnvValue -Key 'vmSubscriptionId' -ValueFactory { $subscription.id } | Out-Null
Ensure-DefaultEnvValue -Key 'sqlAdminLogin' -ValueFactory { 'brokeradmin' } | Out-Null
Ensure-DefaultEnvValue -Key 'sqlDatabaseName' -ValueFactory { 'LinuxBroker' } | Out-Null
Ensure-DefaultEnvValue -Key 'appServicePlanSku' -ValueFactory { 'P1v3' } | Out-Null
Ensure-DefaultEnvValue -Key 'linuxHostAdminLoginName' -ValueFactory { 'avdadmin' } | Out-Null
Ensure-DefaultEnvValue -Key 'domainName' -ValueFactory { '' } | Out-Null
Ensure-DefaultEnvValue -Key 'nfsShare' -ValueFactory { '' } | Out-Null
Ensure-DefaultEnvValue -Key 'vmHostResourceGroup' -ValueFactory { '' } | Out-Null
Ensure-DefaultEnvValue -Key 'allowedClientIp' -ValueFactory { '' } | Out-Null
Ensure-DefaultEnvValue -Key 'flaskKey' -ValueFactory { Get-AzdEnvValue -Key 'FLASK_SESSION_SECRET' } | Out-Null
Ensure-DefaultEnvValue -Key 'sqlAdminPassword' -ValueFactory { Get-AzdEnvValue -Key 'SQL_ADMIN_PASSWORD' } | Out-Null
Ensure-DefaultEnvValue -Key 'hostAdminPassword' -ValueFactory { Get-AzdEnvValue -Key 'HOST_ADMIN_PASSWORD' } | Out-Null

$apiApp = Ensure-ApiApplication -CloudContext $cloudContext -DisplayName $apiAppDisplayName
Ensure-ServicePrincipal -AppId $apiApp.appId | Out-Null
Ensure-ClientSecret -Application $apiApp -EnvClientIdKey 'API_CLIENT_ID' -EnvSecretKey 'API_CLIENT_SECRET' | Out-Null

$frontendApp = Ensure-FrontendApplication -CloudContext $cloudContext -DisplayName $frontendAppDisplayName -AppServiceName $frontendAppServiceName -ApiAppId $apiApp.appId
Ensure-ServicePrincipal -AppId $frontendApp.appId | Out-Null
Ensure-ClientSecret -Application $frontendApp -EnvClientIdKey 'FRONTEND_CLIENT_ID' -EnvSecretKey 'FRONTEND_CLIENT_SECRET' | Out-Null

$avdGroup = Ensure-Group -DisplayName $avdGroupName
$linuxGroup = Ensure-Group -DisplayName $linuxGroupName

Set-AzdEnvValue -Key 'API_CLIENT_ID' -Value $apiApp.appId
Set-AzdEnvValue -Key 'FRONTEND_CLIENT_ID' -Value $frontendApp.appId
Set-AzdEnvValue -Key 'AVD_HOST_GROUP_ID' -Value $avdGroup.id
Set-AzdEnvValue -Key 'LINUX_HOST_GROUP_ID' -Value $linuxGroup.id
Set-AzdEnvValue -Key 'apiClientId' -Value $apiApp.appId
Set-AzdEnvValue -Key 'frontendClientId' -Value $frontendApp.appId
Set-AzdEnvValue -Key 'avdHostGroupId' -Value $avdGroup.id
Set-AzdEnvValue -Key 'linuxHostGroupId' -Value $linuxGroup.id
Set-AzdEnvValue -Key 'frontendClientSecret' -Value (Get-AzdEnvValue -Key 'FRONTEND_CLIENT_SECRET')
Set-AzdEnvValue -Key 'apiClientSecret' -Value (Get-AzdEnvValue -Key 'API_CLIENT_SECRET')

Write-Host "Configured azd environment '$EnvironmentName' with Entra application and host group values."
Write-Host "API application: $($apiApp.displayName) ($($apiApp.appId))"
Write-Host "Frontend application: $($frontendApp.displayName) ($($frontendApp.appId))"
Write-Host "AVD host group: $($avdGroup.displayName) ($($avdGroup.id))"
Write-Host "Linux host group: $($linuxGroup.displayName) ($($linuxGroup.id))"
Write-Host 'Admin consent is still required for the configured Microsoft Graph and API permissions.'
