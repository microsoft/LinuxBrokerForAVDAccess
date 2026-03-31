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
        $existingAppName = ''
        if (-not [string]::IsNullOrWhiteSpace($EnvironmentName)) {
            $existingAppName = (azd env get-value appName --environment $EnvironmentName 2>$null | Out-String).Trim()
        }

        if (-not [string]::IsNullOrWhiteSpace($existingAppName)) {
            $existingAppName
        }
        else {
            $defaultAppName = 'linuxbroker'
            $canPromptForAppName = [Environment]::UserInteractive -and
                (-not $env:CI) -and (-not $env:TF_BUILD) -and (-not $env:GITHUB_ACTIONS) -and (-not $env:BUILD_BUILDID)
            try { $canPromptForAppName = $canPromptForAppName -and (-not [Console]::IsInputRedirected) } catch { $canPromptForAppName = $false }
            if ($canPromptForAppName) {
                $inputAppName = Read-Host "Application name for resource naming [$defaultAppName]"
                if ([string]::IsNullOrWhiteSpace($inputAppName)) { $defaultAppName } else { $inputAppName.Trim() }
            }
            else {
                $defaultAppName
            }
        }
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
$defaultAccessAppRoleId = '00000000-0000-0000-0000-000000000000'
$frontendGraphDelegatedPermissions = @(
    @{ name = 'User.Read'; id = 'e1fe6dd8-ba31-4d61-89e7-88639da4683d' }
    @{ name = 'profile'; id = '14dad69e-099b-42c9-810b-d002981feec1' }
    @{ name = 'email'; id = '64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0' }
    @{ name = 'offline_access'; id = '7427e0e9-2fba-42fe-b0c0-848c9e6a8182' }
    @{ name = 'openid'; id = '37f7f235-527c-4136-accd-4a02d197296e' }
)

$apiScopeId = '58db6e6d-38d5-4ce2-bf0a-7fd9cfd5f00a'
$frontendScopeId = '9afc8711-1fe8-4b8d-9178-44235aa93b4a'
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

function Get-AzdEnvFilePath {
    $envDirectory = Join-Path (Join-Path $PSScriptRoot '.azure') $EnvironmentName
    if (-not (Test-Path -Path $envDirectory)) {
        New-Item -ItemType Directory -Path $envDirectory -Force | Out-Null
    }

    return Join-Path $envDirectory '.env'
}

function Set-AzdEnvFileValue {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    $envFilePath = Get-AzdEnvFilePath
    $escapedValue = $Value.Replace('"', '\"')
    $serializedLine = $Key + '="' + $escapedValue + '"'
    $updatedLines = New-Object System.Collections.Generic.List[string]
    $matched = $false

    if (Test-Path -Path $envFilePath) {
        foreach ($line in Get-Content -Path $envFilePath -Encoding utf8) {
            if ($line.StartsWith($Key + '=')) {
                $updatedLines.Add($serializedLine)
                $matched = $true
            }
            else {
                $updatedLines.Add($line)
            }
        }
    }

    if (-not $matched) {
        $updatedLines.Add($serializedLine)
    }

    $updatedContent = ($updatedLines -join "`r`n") + "`r`n"
    Set-Content -Path $envFilePath -Value $updatedContent -Encoding utf8
}

function Set-AzdEnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    if ($Value.StartsWith('-')) {
        Set-AzdEnvFileValue -Key $Key -Value $Value
        return
    }

    azd env set $Key $Value --environment $EnvironmentName 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set azd environment value '$Key'."
    }
}

function New-RandomSecret {
    param([int]$Length = 40)

    # Use only characters that survive azd env round-trips and are accepted
    # by Azure SQL password validation without escaping issues.
    $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789-_.'
    $bytes = New-Object byte[] ($Length)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)

    $builder = New-Object System.Text.StringBuilder
    foreach ($byte in $bytes) {
        [void]$builder.Append($alphabet[$byte % $alphabet.Length])
    }

    return $builder.ToString()
}

function Get-FirstNonEmptyValue {
    param(
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Values = @()
    )

    foreach ($value in $Values) {
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
    }

    return ''
}

function ConvertTo-EscapedMultilineValue {
    param([Parameter(Mandatory = $true)][string]$Value)

    $normalized = $Value.Replace("`r`n", "`n")
    return $normalized.Replace("`n", '\n')
}

function Test-IsInteractiveLocalRun {
    $nonInteractiveSignals = @(
        'CI'
        'TF_BUILD'
        'GITHUB_ACTIONS'
        'BUILD_BUILDID'
    )

    foreach ($signal in $nonInteractiveSignals) {
        if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($signal))) {
            return $false
        }
    }

    if (-not [Environment]::UserInteractive) {
        return $false
    }

    try {
        # Only check stdin redirection. azd hooks redirect stdout/stderr to
        # capture output, but stdin stays connected to the terminal so
        # Read-Host and PromptForChoice still work.
        return -not [Console]::IsInputRedirected
    }
    catch {
        return $false
    }
}

function Show-LinuxHostSshKeyChoicePrompt {
    param([Parameter(Mandatory = $true)][string]$Message)

    $choices = [System.Management.Automation.Host.ChoiceDescription[]]@(
        (New-Object System.Management.Automation.Host.ChoiceDescription '&Generate', 'Generate a new Linux host SSH key pair and store it in the azd environment.')
        (New-Object System.Management.Automation.Host.ChoiceDescription '&UseMine', 'Stop now so you can set your own Linux host SSH public and private keys and rerun azd.')
    )

    $caption = 'Linux host SSH key pair'

    try {
        return $Host.UI.PromptForChoice($caption, $Message, $choices, 0)
    }
    catch {
        return 0
    }
}

function New-LinuxHostSshKeyPair {
    $sshKeyGen = Get-Command ssh-keygen -ErrorAction SilentlyContinue
    if (-not $sshKeyGen) {
        throw 'OpenSSH ssh-keygen was not found. Install OpenSSH Client or set linuxHostSshPublicKey and linuxHostSshPrivateKey manually.'
    }

    $tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("linuxbroker-ssh-" + [guid]::NewGuid().ToString('N'))
    $privateKeyPath = Join-Path $tempDirectory 'id_ed25519'
    $keyComment = "$AppName-$EnvironmentName-linux-host"

    New-Item -ItemType Directory -Path $tempDirectory -Force | Out-Null

    try {
        & $sshKeyGen.Source -q -t ed25519 -N '' -C $keyComment -f $privateKeyPath | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'ssh-keygen failed while creating the Linux host SSH key pair.'
        }

        $privateKey = Get-Content -Path $privateKeyPath -Raw -Encoding utf8
        $publicKey = (Get-Content -Path "$privateKeyPath.pub" -Raw -Encoding utf8).Trim()

        return @{
            PrivateKey = ConvertTo-EscapedMultilineValue -Value $privateKey
            PublicKey = $publicKey
        }
    }
    finally {
        Remove-Item -Path $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-LinuxHostSshKeys {
    $resolvedPublicKey = Get-FirstNonEmptyValue -Values @(
        (Get-AzdEnvValue -Key 'linuxHostSshPublicKey'),
        (Get-AzdEnvValue -Key 'LINUX_HOST_SSH_PUBLIC_KEY')
    )
    $resolvedPrivateKey = Get-FirstNonEmptyValue -Values @(
        (Get-AzdEnvValue -Key 'linuxHostSshPrivateKey'),
        (Get-AzdEnvValue -Key 'LINUX_HOST_SSH_PRIVATE_KEY')
    )

    $hasPublicKey = -not [string]::IsNullOrWhiteSpace($resolvedPublicKey)
    $hasPrivateKey = -not [string]::IsNullOrWhiteSpace($resolvedPrivateKey)

    if ($hasPublicKey -xor $hasPrivateKey) {
        if (Test-IsInteractiveLocalRun) {
            $choice = Show-LinuxHostSshKeyChoicePrompt -Message "A partial Linux host SSH key pair is configured for azd environment '$EnvironmentName'. Generate a fresh complete pair now, or stop and provide your own key pair."
            if ($choice -eq 1) {
                throw 'Set both linuxHostSshPublicKey and linuxHostSshPrivateKey (or LINUX_HOST_SSH_PUBLIC_KEY and LINUX_HOST_SSH_PRIVATE_KEY) and rerun azd.'
            }
        }

        Write-Warning 'Detected a partial Linux host SSH key pair in the azd environment. Generating a fresh complete pair.'
        $resolvedPublicKey = ''
        $resolvedPrivateKey = ''
        $hasPublicKey = $false
        $hasPrivateKey = $false
    }

    if (-not $hasPublicKey -and -not $hasPrivateKey) {
        if (Test-IsInteractiveLocalRun) {
            $choice = Show-LinuxHostSshKeyChoicePrompt -Message "No Linux host SSH key pair is configured for azd environment '$EnvironmentName'."
            if ($choice -eq 1) {
                throw 'Set linuxHostSshPublicKey and linuxHostSshPrivateKey (or LINUX_HOST_SSH_PUBLIC_KEY and LINUX_HOST_SSH_PRIVATE_KEY) and rerun azd.'
            }
        }

        $generatedKeys = New-LinuxHostSshKeyPair
        $resolvedPublicKey = $generatedKeys.PublicKey
        $resolvedPrivateKey = $generatedKeys.PrivateKey
        Write-Host 'Generated a new Linux host SSH key pair for this azd environment.'
    }
    else {
        if ($resolvedPrivateKey.Contains("`n") -or $resolvedPrivateKey.Contains("`r")) {
            $resolvedPrivateKey = ConvertTo-EscapedMultilineValue -Value $resolvedPrivateKey
        }

        Write-Host 'Using the Linux host SSH key pair already configured in the azd environment.'
    }

    Set-AzdEnvValue -Key 'LINUX_HOST_SSH_PUBLIC_KEY' -Value $resolvedPublicKey
    Set-AzdEnvValue -Key 'LINUX_HOST_SSH_PRIVATE_KEY' -Value $resolvedPrivateKey
    Set-AzdEnvValue -Key 'linuxHostSshPublicKey' -Value $resolvedPublicKey
    Set-AzdEnvValue -Key 'linuxHostSshPrivateKey' -Value $resolvedPrivateKey

    return @{
        PublicKey = $resolvedPublicKey
        PrivateKey = $resolvedPrivateKey
    }
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

function Ensure-EnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    $existing = Get-AzdEnvValue -Key $Key
    if ($existing -ne $Value) {
        Set-AzdEnvValue -Key $Key -Value $Value
    }

    return $Value
}

function Get-RequiredAzdEnvValue {
    param([Parameter(Mandatory = $true)][string]$Key)

    $value = Get-AzdEnvValue -Key $Key
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required azd environment value '$Key' is missing."
    }

    return $value
}

function ConvertTo-BoolParameterValue {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $false)][bool]$DefaultValue = $false
    )

    $value = Get-AzdEnvValue -Key $Key
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultValue
    }

    switch ($value.Trim().ToLowerInvariant()) {
        'true' { return $true }
        'false' { return $false }
        default { throw "azd environment value '$Key' must be 'true' or 'false', but was '$value'." }
    }
}

function ConvertTo-IntParameterValue {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $false)][int]$DefaultValue = 0
    )

    $value = Get-AzdEnvValue -Key $Key
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultValue
    }

    $parsedValue = 0
    if (-not [int]::TryParse($value, [ref]$parsedValue)) {
        throw "azd environment value '$Key' must be an integer, but was '$value'."
    }

    return $parsedValue
}

function Add-BicepParameterValue {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$ParameterCollection,
        [Parameter(Mandatory = $true)][string]$ParameterName,
        [Parameter(Mandatory = $true)]$Value
    )

    $ParameterCollection[$ParameterName] = @{ value = $Value }
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

function Invoke-GraphRestJson {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)]$Body
    )

    $bodyFile = Write-JsonFile -InputObject $Body
    try {
        az rest --method $Method --url $Url --headers 'Content-Type=application/json' --body "@$bodyFile" | Out-Null
    }
    finally {
        Remove-Item -Path $bodyFile -ErrorAction SilentlyContinue
    }
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

function Ensure-GroupAppRoleAssignment {
    param(
        [Parameter(Mandatory = $true)][hashtable]$CloudContext,
        [Parameter(Mandatory = $true)][string]$GroupId,
        [Parameter(Mandatory = $true)][string]$ResourceServicePrincipalId,
        [Parameter(Mandatory = $true)][string]$AppRoleId
    )

    $assignmentsResponse = az rest --method GET --url "$($CloudContext.GraphUrl)/v1.0/groups/$GroupId/appRoleAssignments" --output json | ConvertFrom-Json
    $existingAssignment = $assignmentsResponse.value | Where-Object {
        $_.resourceId -eq $ResourceServicePrincipalId -and $_.appRoleId -eq $AppRoleId
    } | Select-Object -First 1

    if ($existingAssignment) {
        return
    }

    $payload = @{
        principalId = $GroupId
        resourceId = $ResourceServicePrincipalId
        appRoleId = $AppRoleId
    }

    Invoke-GraphRestJson -Method 'POST' -Url "$($CloudContext.GraphUrl)/v1.0/groups/$GroupId/appRoleAssignments" -Body $payload
}

function Get-SignedInUser {
    try {
        $userType = az account show --query user.type --output tsv 2>$null
        if ($LASTEXITCODE -ne 0 -or $userType -ne 'user') {
            return $null
        }

        return az ad signed-in-user show --output json | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Ensure-UserAppRoleAssignment {
    param(
        [Parameter(Mandatory = $true)][hashtable]$CloudContext,
        [Parameter(Mandatory = $true)][string]$UserId,
        [Parameter(Mandatory = $true)][string]$ResourceServicePrincipalId,
        [Parameter(Mandatory = $true)][string]$AppRoleId
    )

    $assignmentsResponse = az rest --method GET --url "$($CloudContext.GraphUrl)/v1.0/users/$UserId/appRoleAssignments" --output json | ConvertFrom-Json
    $existingAssignment = $assignmentsResponse.value | Where-Object {
        $_.resourceId -eq $ResourceServicePrincipalId -and $_.appRoleId -eq $AppRoleId
    } | Select-Object -First 1

    if ($existingAssignment) {
        return
    }

    $payload = @{
        principalId = $UserId
        resourceId = $ResourceServicePrincipalId
        appRoleId = $AppRoleId
    }

    Invoke-GraphRestJson -Method 'POST' -Url "$($CloudContext.GraphUrl)/v1.0/users/$UserId/appRoleAssignments" -Body $payload
}

function Remove-UserAppRoleAssignment {
    param(
        [Parameter(Mandatory = $true)][hashtable]$CloudContext,
        [Parameter(Mandatory = $true)][string]$UserId,
        [Parameter(Mandatory = $true)][string]$ResourceServicePrincipalId,
        [Parameter(Mandatory = $true)][string]$AppRoleId
    )

    $assignmentsResponse = az rest --method GET --url "$($CloudContext.GraphUrl)/v1.0/users/$UserId/appRoleAssignments" --output json | ConvertFrom-Json
    $existingAssignment = $assignmentsResponse.value | Where-Object {
        $_.resourceId -eq $ResourceServicePrincipalId -and $_.appRoleId -eq $AppRoleId
    } | Select-Object -First 1

    if (-not $existingAssignment) {
        return
    }

    az rest --method DELETE --url "$($CloudContext.GraphUrl)/v1.0/users/$UserId/appRoleAssignments/$($existingAssignment.id)" | Out-Null
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

function Ensure-AppAdminConsent {
    param(
        [Parameter(Mandatory = $true)][string]$AppId,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    az ad app permission admin-consent --id $AppId 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Unable to grant admin consent automatically for application '$DisplayName'. Grant tenant-wide consent manually if required."
    }
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

    $frontendManifest = @{
        identifierUris = @("api://$($app.appId)")
        api = @{
            requestedAccessTokenVersion = 2
            oauth2PermissionScopes = @(
                @{
                    adminConsentDescription = "Allow the application to access $DisplayName on behalf of the signed-in user."
                    adminConsentDisplayName = "Access $DisplayName"
                    id = $frontendScopeId
                    isEnabled = $true
                    type = 'User'
                    userConsentDescription = "Allow the application to access $DisplayName on your behalf."
                    userConsentDisplayName = "Access $DisplayName"
                    value = 'user_impersonation'
                }
            )
        }
    }

    Invoke-GraphRestJson -Method 'PATCH' -Url "$($CloudContext.GraphUrl)/v1.0/applications/$($app.id)" -Body $frontendManifest

    $logoutBody = @{
        web = @{
            logoutUrl = "$redirectBase/logout"
        }
    }

    Invoke-GraphRestJson -Method 'PATCH' -Url "$($CloudContext.GraphUrl)/v1.0/applications/$($app.id)" -Body $logoutBody

    return $app
}

function Ensure-ApiApplication {
    param(
        [Parameter(Mandatory = $true)][hashtable]$CloudContext,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $false)][string]$FrontendAppId = ''
    )

    $app = Get-MatchingApp -DisplayName $DisplayName
    if (-not $app) {
        $app = az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg --output json | ConvertFrom-Json
    }

    az ad app update --id $app.id --identifier-uris "api://$($app.appId)" --requested-access-token-version 2 | Out-Null

    $graphSp = az ad sp show --id $graphAppId --output json | ConvertFrom-Json
    $graphApplicationPermissions = @(
        'Directory.Read.All'
        'Group.Read.All'
        'GroupMember.Read.All'
    )
    $graphResourceAccess = @()

    foreach ($permissionValue in $graphApplicationPermissions) {
        $roleId = $graphSp.appRoles | Where-Object {
            $_.value -eq $permissionValue -and $_.allowedMemberTypes -contains 'Application'
        } | Select-Object -ExpandProperty id -First 1

        if ($roleId) {
            $graphResourceAccess += @{
                id = $roleId
                type = 'Role'
            }
        }
    }

    $requiredResourceAccess = @()
    if ($graphResourceAccess.Count -gt 0) {
        $requiredResourceAccess += @{
            resourceAppId = $graphAppId
            resourceAccess = $graphResourceAccess
        }
    }

    $knownClientApplications = @()
    $preAuthorizedApplications = @()
    if (-not [string]::IsNullOrWhiteSpace($FrontendAppId)) {
        $knownClientApplications = @($FrontendAppId)
        $preAuthorizedApplications = @(
            @{
                appId = $FrontendAppId
                delegatedPermissionIds = @($apiScopeId)
            }
        )
    }

    $apiManifest = @{
        identifierUris = @("api://$($app.appId)")
        requiredResourceAccess = $requiredResourceAccess
        api = @{
            knownClientApplications = $knownClientApplications
            preAuthorizedApplications = $preAuthorizedApplications
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

    Invoke-GraphRestJson -Method 'PATCH' -Url "$($CloudContext.GraphUrl)/v1.0/applications/$($app.id)" -Body $apiManifest

    $appRoles = @(
        @{
            allowedMemberTypes = @('User')
            description = 'Full access to Linux Broker management APIs.'
            displayName = 'FullAccess'
            id = $apiRoleIds.FullAccess
            isEnabled = $true
            value = 'FullAccess'
        }
        @{
            allowedMemberTypes = @('Application')
            description = 'Allows the scheduled task function app to call maintenance endpoints.'
            displayName = 'ScheduledTask'
            id = $apiRoleIds.ScheduledTask
            isEnabled = $true
            value = 'ScheduledTask'
        }
        @{
            allowedMemberTypes = @('Application', 'User')
            description = 'Allows AVD host automation to call AVD-specific endpoints.'
            displayName = 'AvdHost'
            id = $apiRoleIds.AvdHost
            isEnabled = $true
            value = 'AvdHost'
        }
        @{
            allowedMemberTypes = @('Application', 'User')
            description = 'Allows Linux host automation to call Linux host endpoints.'
            displayName = 'LinuxHost'
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

    return $app
}

$cloudContext = Get-CloudContext

$frontendAppDisplayName = "$AppName-$EnvironmentName-frontend-ar"
$apiAppDisplayName = "$AppName-$EnvironmentName-api-ar"
$frontendAppServiceName = "fe-$AppName-$EnvironmentName"
$avdGroupName = "$AppName-$EnvironmentName-avd-hosts-sg"
$linuxGroupName = "$AppName-$EnvironmentName-linux-hosts-sg"

$subscription = az account show --output json | ConvertFrom-Json
$defaultTenantId = $subscription.tenantId

Ensure-DefaultEnvValue -Key 'appName' -ValueFactory { $AppName } | Out-Null
Ensure-DefaultEnvValue -Key 'environmentName' -ValueFactory { $EnvironmentName } | Out-Null
Ensure-DefaultEnvValue -Key 'tenantId' -ValueFactory { $defaultTenantId } | Out-Null

Ensure-DefaultEnvValue -Key 'SQL_ADMIN_LOGIN' -ValueFactory { 'brokeradmin' } | Out-Null
Ensure-DefaultEnvValue -Key 'SQL_DATABASE_NAME' -ValueFactory { 'LinuxBroker' } | Out-Null
Ensure-DefaultEnvValue -Key 'APP_SERVICE_PLAN_SKU' -ValueFactory { 'P2mv3' } | Out-Null
Ensure-DefaultEnvValue -Key 'LINUX_HOST_ADMIN_LOGIN_NAME' -ValueFactory { 'avdadmin' } | Out-Null
Ensure-DefaultEnvValue -Key 'DOMAIN_NAME' -ValueFactory { '' } | Out-Null
Ensure-DefaultEnvValue -Key 'NFS_SHARE' -ValueFactory { '' } | Out-Null
Ensure-DefaultEnvValue -Key 'VM_HOST_RESOURCE_GROUP' -ValueFactory { '' } | Out-Null
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
Ensure-DefaultEnvValue -Key 'linuxHostAuthType' -ValueFactory { 'SSH' } | Out-Null
Ensure-DefaultEnvValue -Key 'LINUX_HOST_SSH_PUBLIC_KEY' -ValueFactory { '' } | Out-Null
Ensure-DefaultEnvValue -Key 'LINUX_HOST_SSH_PRIVATE_KEY' -ValueFactory { '' } | Out-Null
Ensure-DefaultEnvValue -Key 'linuxHostSshPublicKey' -ValueFactory { Get-AzdEnvValue -Key 'LINUX_HOST_SSH_PUBLIC_KEY' } | Out-Null
Ensure-DefaultEnvValue -Key 'linuxHostSshPrivateKey' -ValueFactory { Get-AzdEnvValue -Key 'LINUX_HOST_SSH_PRIVATE_KEY' } | Out-Null
Ensure-DefaultEnvValue -Key 'linuxHostOsVersion' -ValueFactory { '24_04-lts' } | Out-Null
Ensure-DefaultEnvValue -Key 'linuxHostVmSize' -ValueFactory { 'Standard_D2s_v5' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdVmSize' -ValueFactory { 'Standard_D8s_v5' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdMaxSessionLimit' -ValueFactory { '5' } | Out-Null
Ensure-DefaultEnvValue -Key 'vmSubscriptionId' -ValueFactory { $subscription.id } | Out-Null
Ensure-DefaultEnvValue -Key 'sqlAdminLogin' -ValueFactory { 'brokeradmin' } | Out-Null
Ensure-DefaultEnvValue -Key 'sqlDatabaseName' -ValueFactory { 'LinuxBroker' } | Out-Null
Ensure-DefaultEnvValue -Key 'appServicePlanSku' -ValueFactory { 'P2mv3' } | Out-Null
Ensure-DefaultEnvValue -Key 'linuxHostAdminLoginName' -ValueFactory { 'avdadmin' } | Out-Null
Ensure-DefaultEnvValue -Key 'domainName' -ValueFactory { '' } | Out-Null
Ensure-DefaultEnvValue -Key 'nfsShare' -ValueFactory { '' } | Out-Null
Ensure-DefaultEnvValue -Key 'vmHostResourceGroup' -ValueFactory { '' } | Out-Null
# Always refresh the client IP since it can change between runs
$detectedIp = try { (Invoke-RestMethod -Uri 'https://ifconfig.me/ip' -TimeoutSec 10).Trim() } catch { '' }
Set-AzdEnvValue -Key 'allowedClientIp' -Value $detectedIp
if ($detectedIp) { Write-Host "Detected client IP for SQL firewall: $detectedIp" }
Ensure-DefaultEnvValue -Key 'flaskKey' -ValueFactory { Get-AzdEnvValue -Key 'FLASK_SESSION_SECRET' } | Out-Null
Ensure-DefaultEnvValue -Key 'sqlAdminPassword' -ValueFactory { Get-AzdEnvValue -Key 'SQL_ADMIN_PASSWORD' } | Out-Null
Ensure-DefaultEnvValue -Key 'hostAdminPassword' -ValueFactory { Get-AzdEnvValue -Key 'HOST_ADMIN_PASSWORD' } | Out-Null

if ((Get-AzdEnvValue -Key 'APP_SERVICE_PLAN_SKU') -eq 'P1v3') {
    Ensure-EnvValue -Key 'APP_SERVICE_PLAN_SKU' -Value 'P2mv3' | Out-Null
}

if ((Get-AzdEnvValue -Key 'appServicePlanSku') -eq 'P1v3') {
    Ensure-EnvValue -Key 'appServicePlanSku' -Value 'P2mv3' | Out-Null
}

$deployLinuxHostsValue = Get-AzdEnvValue -Key 'deployLinuxHosts'
$linuxHostAuthTypeValue = Get-AzdEnvValue -Key 'linuxHostAuthType'

if ($deployLinuxHostsValue -eq 'true' -and $linuxHostAuthTypeValue -ne 'SSH') {
    throw 'linuxHostAuthType must be SSH for broker-managed Linux hosts because the broker connects to them with an SSH key.'
}

if ($deployLinuxHostsValue -eq 'true') {
    [void](Ensure-LinuxHostSshKeys)
}

$apiApp = Ensure-ApiApplication -CloudContext $cloudContext -DisplayName $apiAppDisplayName
$apiServicePrincipal = Ensure-ServicePrincipal -AppId $apiApp.appId
Ensure-ClientSecret -Application $apiApp -EnvClientIdKey 'API_CLIENT_ID' -EnvSecretKey 'API_CLIENT_SECRET' | Out-Null
Ensure-AppAdminConsent -AppId $apiApp.appId -DisplayName $apiApp.displayName

$frontendApp = Ensure-FrontendApplication -CloudContext $cloudContext -DisplayName $frontendAppDisplayName -AppServiceName $frontendAppServiceName -ApiAppId $apiApp.appId
$frontendServicePrincipal = Ensure-ServicePrincipal -AppId $frontendApp.appId
Ensure-ClientSecret -Application $frontendApp -EnvClientIdKey 'FRONTEND_CLIENT_ID' -EnvSecretKey 'FRONTEND_CLIENT_SECRET' | Out-Null
$apiApp = Ensure-ApiApplication -CloudContext $cloudContext -DisplayName $apiAppDisplayName -FrontendAppId $frontendApp.appId
Ensure-AppAdminConsent -AppId $apiApp.appId -DisplayName $apiApp.displayName

$avdGroup = Ensure-Group -DisplayName $avdGroupName
$linuxGroup = Ensure-Group -DisplayName $linuxGroupName

$deploymentUser = Get-SignedInUser
if ($deploymentUser) {
    Ensure-UserAppRoleAssignment -CloudContext $cloudContext -UserId $deploymentUser.id -ResourceServicePrincipalId $frontendServicePrincipal.id -AppRoleId $defaultAccessAppRoleId
    Remove-UserAppRoleAssignment -CloudContext $cloudContext -UserId $deploymentUser.id -ResourceServicePrincipalId $apiServicePrincipal.id -AppRoleId $defaultAccessAppRoleId
    Ensure-UserAppRoleAssignment -CloudContext $cloudContext -UserId $deploymentUser.id -ResourceServicePrincipalId $apiServicePrincipal.id -AppRoleId $apiRoleIds.FullAccess
}

Ensure-GroupAppRoleAssignment -CloudContext $cloudContext -GroupId $avdGroup.id -ResourceServicePrincipalId $apiServicePrincipal.id -AppRoleId $apiRoleIds.AvdHost
Ensure-GroupAppRoleAssignment -CloudContext $cloudContext -GroupId $linuxGroup.id -ResourceServicePrincipalId $apiServicePrincipal.id -AppRoleId $apiRoleIds.LinuxHost

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
Write-Host 'Automatic admin consent was attempted for the configured application permissions. If consent was not granted, complete it manually in Microsoft Entra ID.'

# Generate the Bicep parameters file with the real values so azd passes them
# to the ARM deployment. azd collects parameters BEFORE running preprovision,
# so env values set above would not be picked up through ${...} references or
# auto-mapping. Writing the file here guarantees the deployment gets real values.
$bicepParametersPath = Join-Path $PSScriptRoot 'bicep' 'main.parameters.json'
$bicepParameterEntries = [ordered]@{}

Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'environmentName' -Value '${AZURE_ENV_NAME}'
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'location' -Value '${AZURE_LOCATION}'
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'appName' -Value (Get-RequiredAzdEnvValue -Key 'appName')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'tenantId' -Value (Get-RequiredAzdEnvValue -Key 'tenantId')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'frontendClientId' -Value (Get-RequiredAzdEnvValue -Key 'frontendClientId')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'frontendClientSecret' -Value (Get-RequiredAzdEnvValue -Key 'frontendClientSecret')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'apiClientId' -Value (Get-RequiredAzdEnvValue -Key 'apiClientId')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'apiClientSecret' -Value (Get-RequiredAzdEnvValue -Key 'apiClientSecret')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'linuxHostSshPrivateKey' -Value (Get-RequiredAzdEnvValue -Key 'linuxHostSshPrivateKey')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'linuxHostSshPublicKey' -Value (Get-RequiredAzdEnvValue -Key 'linuxHostSshPublicKey')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdHostGroupId' -Value (Get-RequiredAzdEnvValue -Key 'avdHostGroupId')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'linuxHostGroupId' -Value (Get-RequiredAzdEnvValue -Key 'linuxHostGroupId')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'sqlAdminLogin' -Value (Get-RequiredAzdEnvValue -Key 'sqlAdminLogin')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'sqlAdminPassword' -Value (Get-RequiredAzdEnvValue -Key 'sqlAdminPassword')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'flaskKey' -Value (Get-RequiredAzdEnvValue -Key 'flaskKey')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'domainName' -Value (Get-AzdEnvValue -Key 'domainName')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'nfsShare' -Value (Get-AzdEnvValue -Key 'nfsShare')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'linuxHostAdminLoginName' -Value (Get-RequiredAzdEnvValue -Key 'linuxHostAdminLoginName')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'hostAdminPassword' -Value (Get-RequiredAzdEnvValue -Key 'hostAdminPassword')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'vmHostResourceGroup' -Value (Get-AzdEnvValue -Key 'vmHostResourceGroup')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'vmSubscriptionId' -Value (Get-RequiredAzdEnvValue -Key 'vmSubscriptionId')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'allowedClientIp' -Value (Get-AzdEnvValue -Key 'allowedClientIp')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'appServicePlanSku' -Value (Get-RequiredAzdEnvValue -Key 'appServicePlanSku')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'deployLinuxHosts' -Value (ConvertTo-BoolParameterValue -Key 'deployLinuxHosts')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'deployAvdHosts' -Value (ConvertTo-BoolParameterValue -Key 'deployAvdHosts')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'linuxHostVmNamePrefix' -Value (Get-RequiredAzdEnvValue -Key 'linuxHostVmNamePrefix')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'linuxHostVmSize' -Value (Get-RequiredAzdEnvValue -Key 'linuxHostVmSize')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'linuxHostCount' -Value (ConvertTo-IntParameterValue -Key 'linuxHostCount')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'linuxHostAuthType' -Value (Get-RequiredAzdEnvValue -Key 'linuxHostAuthType')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'linuxHostOsVersion' -Value (Get-RequiredAzdEnvValue -Key 'linuxHostOsVersion')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdHostPoolName' -Value (Get-RequiredAzdEnvValue -Key 'avdHostPoolName')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdSessionHostCount' -Value (ConvertTo-IntParameterValue -Key 'avdSessionHostCount')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdMaxSessionLimit' -Value (ConvertTo-IntParameterValue -Key 'avdMaxSessionLimit' -DefaultValue 5)
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdVmNamePrefix' -Value (Get-RequiredAzdEnvValue -Key 'avdVmNamePrefix')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdVmSize' -Value (Get-RequiredAzdEnvValue -Key 'avdVmSize')

$bicepParameters = [ordered]@{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters = $bicepParameterEntries
}

$bicepParameters | ConvertTo-Json -Depth 10 | Set-Content -Path $bicepParametersPath -Encoding utf8
Write-Host "Generated Bicep parameters file at '$bicepParametersPath'."
