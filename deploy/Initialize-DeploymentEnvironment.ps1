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
# The Azure Virtual Desktop first-party app, whose service principal starts and stops session
# hosts for the scaling plan and Start VM on Connect.
$avdServicePrincipalAppId = '9cdead84-a844-4324-93f2-b2e6bb768d07'
# Desktop Virtualization Power On Off Contributor, which main.bicep assigns to that service principal.
$avdAutoscaleRoleDefinitionId = '40c5ff49-9181-41f8-ae61-143b0e78555e'
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
    Reader = '73d69433-4ff1-4918-bf30-acfd0b792807'
    Operator = 'd1510542-4e17-41f2-9d21-b975a9ff5553'
    ScheduledTask = 'd11a6ed0-ee5e-4305-a2a2-252a8107d84f'
    AvdHost = '2dd7deea-1e20-4f32-a733-c6f6ec1d2519'
    LinuxHost = '29a8a5a0-2090-4e94-a49d-3386640f0058'
}

$cloudProfiles = @{
    AzurePublic = @{
        GraphUrl = 'https://graph.microsoft.com'
        AppServiceDomain = 'azurewebsites.net'
        StsIssuerHost = 'https://sts.windows.net'
    }
    AzureUSGovernment = @{
        GraphUrl = 'https://graph.microsoft.us'
        AppServiceDomain = 'azurewebsites.us'
        StsIssuerHost = 'https://sts.windows.net'
    }
}

# Maps the cloud name reported by the Azure CLI onto this solution's cloud names.
$azCliCloudNameMap = @{
    AzureCloud = 'AzurePublic'
    AzureUSGovernment = 'AzureUSGovernment'
}

function Get-DefaultCloudName {
    $cloud = az cloud show --output json | ConvertFrom-Json

    if ($azCliCloudNameMap.ContainsKey($cloud.name)) {
        return $azCliCloudNameMap[$cloud.name]
    }

    return 'AzureCustom'
}

function Show-CloudChoicePrompt {
    param([Parameter(Mandatory = $true)][string]$DefaultCloudName)

    $names = @('AzurePublic', 'AzureUSGovernment', 'AzureCustom')
    $choices = [System.Management.Automation.Host.ChoiceDescription[]]@(
        (New-Object System.Management.Automation.Host.ChoiceDescription '&Public', 'Azure commercial cloud.')
        (New-Object System.Management.Automation.Host.ChoiceDescription '&Government', 'Azure US Government cloud.')
        (New-Object System.Management.Automation.Host.ChoiceDescription '&Custom', 'A sovereign or air-gapped cloud whose endpoints you supply explicitly.')
    )

    $defaultIndex = [Math]::Max([Array]::IndexOf($names, $DefaultCloudName), 0)
    $message = "The Azure CLI is currently signed in to a cloud that maps to '$DefaultCloudName'."

    try {
        $selection = $Host.UI.PromptForChoice('Target Azure cloud', $message, $choices, $defaultIndex)
        return $names[$selection]
    }
    catch {
        return $DefaultCloudName
    }
}

function Resolve-AzureCloudName {
    $configured = Get-AzdEnvValue -Key 'azureCloudName'
    if ([string]::IsNullOrWhiteSpace($configured)) {
        $configured = Get-AzdEnvValue -Key 'AZURE_CLOUD_NAME'
    }

    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        if ($configured -notin @('AzurePublic', 'AzureUSGovernment', 'AzureCustom')) {
            throw "AZURE_CLOUD_NAME '$configured' is not supported. Use AzurePublic, AzureUSGovernment, or AzureCustom."
        }

        return $configured
    }

    $defaultCloudName = Get-DefaultCloudName

    if (Test-IsInteractiveLocalRun) {
        return Show-CloudChoicePrompt -DefaultCloudName $defaultCloudName
    }

    return $defaultCloudName
}

function Get-CloudContext {
    $cloudName = Resolve-AzureCloudName

    $graphUrl = Get-AzdEnvValue -Key 'graphEndpoint'
    $appServiceDomain = Get-AzdEnvValue -Key 'appServiceDomain'
    $stsIssuerHost = Get-AzdEnvValue -Key 'stsIssuerHost'
    $authorityHost = Get-AzdEnvValue -Key 'azureAuthorityHost'

    $profile = $cloudProfiles[$cloudName]
    if ($profile) {
        if ([string]::IsNullOrWhiteSpace($graphUrl)) { $graphUrl = $profile.GraphUrl }
        if ([string]::IsNullOrWhiteSpace($appServiceDomain)) { $appServiceDomain = $profile.AppServiceDomain }
        if ([string]::IsNullOrWhiteSpace($stsIssuerHost)) { $stsIssuerHost = $profile.StsIssuerHost }
    }

    # Custom clouds have no built-in profile, so every endpoint has to be supplied.
    $missing = @()
    if ([string]::IsNullOrWhiteSpace($graphUrl)) { $missing += 'graphEndpoint' }
    if ([string]::IsNullOrWhiteSpace($appServiceDomain)) { $missing += 'appServiceDomain' }
    if ([string]::IsNullOrWhiteSpace($stsIssuerHost)) { $missing += 'stsIssuerHost' }

    if ($missing.Count -gt 0) {
        if (-not (Test-IsInteractiveLocalRun)) {
            throw "Cloud '$cloudName' requires these values to be set in the azd environment before deployment: $($missing -join ', ')."
        }

        foreach ($key in $missing) {
            $entered = (Read-Host "Enter $key for cloud '$cloudName'").Trim()
            if ([string]::IsNullOrWhiteSpace($entered)) {
                throw "Cloud '$cloudName' requires a value for $key."
            }

            switch ($key) {
                'graphEndpoint' { $graphUrl = $entered }
                'appServiceDomain' { $appServiceDomain = $entered }
                'stsIssuerHost' { $stsIssuerHost = $entered }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($authorityHost) -and $cloudName -eq 'AzureCustom' -and (Test-IsInteractiveLocalRun)) {
        $authorityHost = (Read-Host "Enter azureAuthorityHost for cloud '$cloudName' (leave blank to use the endpoint the Azure CLI reports)").Trim()
    }

    return @{
        Name = $cloudName
        GraphUrl = $graphUrl.TrimEnd('/')
        AppServiceDomain = $appServiceDomain.TrimStart('.')
        StsIssuerHost = $stsIssuerHost.TrimEnd('/')
        AuthorityHost = $authorityHost.TrimEnd('/')
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

# Linux host images sold through Azure Marketplace with a purchase plan, by linuxHostOsVersion.
# Azure creates a VM from one only after the subscription accepts its terms.
$linuxHostMarketplaceImages = @{
    'rocky-9' = 'resf:rockylinux-x86_64:9-base:latest'
}

function Ensure-LinuxHostImageTerms {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$OsVersion,
        [Parameter(Mandatory = $true)][string]$SubscriptionId
    )

    $urn = $linuxHostMarketplaceImages[$OsVersion]
    if (-not $urn) {
        return
    }

    $terms = az vm image terms show --urn $urn --subscription $SubscriptionId --output json 2>$null | ConvertFrom-Json
    if ($LASTEXITCODE -eq 0 -and $terms.accepted) {
        Write-Host "The Azure Marketplace terms of '$urn' are already accepted in subscription '$SubscriptionId'."
        return
    }

    Write-Host "Accepting the Azure Marketplace terms of '$urn' in subscription '$SubscriptionId', which linuxHostOsVersion '$OsVersion' needs."
    az vm image terms accept --urn $urn --subscription $SubscriptionId --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to accept the Azure Marketplace terms of '$urn' in subscription '$SubscriptionId'. Accept them with 'az vm image terms accept --urn $urn --subscription $SubscriptionId', or set linuxHostOsVersion to alma-9, which has no Marketplace terms."
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

function Ensure-GroupMember {
    param(
        [Parameter(Mandatory = $true)][string]$GroupId,
        [Parameter(Mandatory = $true)][string]$MemberId
    )

    # Newly created groups can take a short time to replicate in Microsoft Entra ID.
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $isMember = az ad group member check --group $GroupId --member-id $MemberId --query value --output tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and "$isMember".Trim() -eq 'true') {
            return $true
        }

        az ad group member add --group $GroupId --member-id $MemberId 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return $true
        }

        Start-Sleep -Seconds (5 * $attempt)
    }

    return $false
}

function Ensure-EntraRdpAuthentication {
    param([Parameter(Mandatory = $true)][hashtable]$CloudContext)

    # The host pool enables Microsoft Entra single sign-on (enablerdsaadauth:i:1),
    # which requires Entra authentication for RDP on the Windows Cloud Login
    # service principal. This is a tenant-wide setting that is only ever enabled here.
    $windowsCloudLoginAppId = '270efc09-cd0d-444b-a71f-39af4910ec45'
    $manualStepsUrl = 'https://learn.microsoft.com/azure/virtual-desktop/configure-single-sign-on#enable-microsoft-entra-authentication-for-rdp'

    try {
        $servicePrincipal = Ensure-ServicePrincipal -AppId $windowsCloudLoginAppId
        if (-not $servicePrincipal -or -not $servicePrincipal.id) {
            throw 'The Windows Cloud Login service principal could not be found or created.'
        }

        $configurationUrl = "$($CloudContext.GraphUrl)/v1.0/servicePrincipals/$($servicePrincipal.id)/remoteDesktopSecurityConfiguration"
        $configuration = az rest --method GET --url $configurationUrl --output json 2>$null | ConvertFrom-Json
        if ($LASTEXITCODE -eq 0 -and $configuration -and $configuration.isRemoteDesktopProtocolEnabled -eq $true) {
            Write-Host 'Microsoft Entra authentication for RDP is already enabled on the Windows Cloud Login service principal.'
            return
        }

        Invoke-GraphRestJson -Method 'PATCH' -Url $configurationUrl -Body @{ isRemoteDesktopProtocolEnabled = $true }
        if ($LASTEXITCODE -ne 0) {
            throw 'Microsoft Graph rejected the remoteDesktopSecurityConfiguration update.'
        }

        Write-Host 'Enabled Microsoft Entra authentication for RDP on the Windows Cloud Login service principal (required for AVD single sign-on).'
    }
    catch {
        Write-Warning "Unable to enable Microsoft Entra authentication for RDP automatically: $($_.Exception.Message) AVD single sign-on connections fail until an administrator enables it. See $manualStepsUrl"
    }
}

# A property's value, or $null when the object or the property is missing. The lookup ignores
# case, as Azure does with tag names.
function Get-PropertyValue {
    param(
        $InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-VmTagValue {
    param(
        [Parameter(Mandatory = $true)]
        $Vm,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return [string](Get-PropertyValue -InputObject (Get-PropertyValue -InputObject $Vm -Name 'tags') -Name $Name)
}

# A time of day for the AVD scaling plan, as HH:mm on a 24-hour clock.
function ConvertTo-TimeOfDayParameterValue {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$DefaultValue
    )

    $value = Get-AzdEnvValue -Key $Key
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = $DefaultValue
    }

    $match = [regex]::Match($value.Trim(), '^([01]?[0-9]|2[0-3]):([0-5][0-9])\z')
    if (-not $match.Success) {
        throw "azd environment value '$Key' must be a time of day as HH:mm on a 24-hour clock, such as 07:00, but was '$value'."
    }

    return ('{0:D2}:{1}' -f [int]$match.Groups[1].Value, $match.Groups[2].Value)
}

function ConvertTo-PercentParameterValue {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][int]$DefaultValue,
        [Parameter(Mandatory = $false)][int]$Minimum = 0
    )

    $value = ConvertTo-IntParameterValue -Key $Key -DefaultValue $DefaultValue
    if ($value -lt $Minimum -or $value -gt 100) {
        throw "azd environment value '$Key' must be a whole number from $Minimum to 100, but was '$value'."
    }

    return $value
}

# The scaling plan's phases start in order within one day: ramp-up, peak, ramp-down, off-peak.
function Assert-AvdScalingPlanTimeOrder {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Times)

    $previousKey = $null
    $previousMinutes = -1
    foreach ($key in @($Times.Keys)) {
        $parts = ([string]$Times[$key]).Split(':')
        $minutes = ([int]$parts[0] * 60) + [int]$parts[1]
        if ($null -ne $previousKey -and $minutes -le $previousMinutes) {
            throw "azd environment value '$key' ($($Times[$key])) must be later than '$previousKey' ($($Times[$previousKey])). The scaling plan's ramp-up, peak, ramp-down and off-peak times must come in that order within one day."
        }

        $previousKey = $key
        $previousMinutes = $minutes
    }
}

# The canonical form of a Windows time zone ID, or '' when this machine does not know it. It does
# not use FindSystemTimeZoneById, which also accepts IANA names on .NET 6 and later.
function Resolve-WindowsTimeZoneId {
    param([Parameter(Mandatory = $true)][string]$TimeZoneId)

    $id = $TimeZoneId.Trim()
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        foreach ($zone in [System.TimeZoneInfo]::GetSystemTimeZones()) {
            if ([string]::Equals($zone.Id, $id, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $zone.Id
            }
        }

        return ''
    }

    # Elsewhere the system time zones have IANA IDs, so ask ICU whether it knows the Windows ID.
    $ianaId = $null
    if ($null -ne [System.TimeZoneInfo].GetMethod('TryConvertWindowsIdToIanaId', [type[]]@([string], [string].MakeByRefType())) -and
        [System.TimeZoneInfo]::TryConvertWindowsIdToIanaId($id, [ref]$ianaId)) {
        return $id
    }

    return ''
}

# The broker's Linux hosts and AVD session hosts that exist but are not running, and the
# excludeFromScaling tags on the session hosts. Azure refuses to change an extension on a VM that
# is not running, and a deployment replaces the tags of every VM it declares.
function Get-HostPowerStateSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName
    )

    $snapshot = @{
        Listed = $false
        NotRunning = @()
        NotRunningDisplay = @()
        AvdScalingExclusions = [ordered]@{}
    }
    $unlistedWarning = "so this deployment updates the VM extensions of every host. If one is not running, the deployment fails with 'Cannot modify extensions in the VM when the VM is not running'; start that host, or run azd provision again."

    $groupExists = (@(az group exists --name $ResourceGroupName --subscription $SubscriptionId --only-show-errors 2>$null) -join '').Trim()
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not check whether resource group '$ResourceGroupName' exists, $unlistedWarning"
        return $snapshot
    }

    if ($groupExists -ne 'true') {
        $snapshot.Listed = $true
        return $snapshot
    }

    $vmJson = (@(az vm list --resource-group $ResourceGroupName --subscription $SubscriptionId --show-details --output json --only-show-errors 2>$null) -join "`n")
    $vms = $null
    if ($LASTEXITCODE -eq 0) {
        try {
            $vms = @(ConvertFrom-Json -InputObject $vmJson | ForEach-Object { $_ })
        }
        catch {
            $vms = $null
        }
    }

    if ($null -eq $vms) {
        Write-Warning "Could not list the VMs in resource group '$ResourceGroupName', $unlistedWarning"
        return $snapshot
    }

    $notRunning = New-Object System.Collections.Generic.List[string]
    $notRunningDisplay = New-Object System.Collections.Generic.List[string]
    foreach ($vm in $vms) {
        if ($null -eq $vm) {
            continue
        }

        $role = Get-VmTagValue -Vm $vm -Name 'broker-role'
        if ($role -ne 'linux-host' -and $role -ne 'avd-host') {
            continue
        }

        $name = [string](Get-PropertyValue -InputObject $vm -Name 'name')
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        # An empty power state means Azure could not report one, so the host is treated as running.
        $powerState = [string](Get-PropertyValue -InputObject $vm -Name 'powerState')
        if (-not [string]::IsNullOrWhiteSpace($powerState) -and $powerState -notmatch 'running') {
            $notRunning.Add($name.ToLowerInvariant())
            $notRunningDisplay.Add("$name ($powerState)")
        }

        # Autoscale leaves alone a session host that carries the tag, whatever its value.
        if ($role -eq 'avd-host') {
            $exclusion = Get-PropertyValue -InputObject (Get-PropertyValue -InputObject $vm -Name 'tags') -Name 'excludeFromScaling'
            if ($null -ne $exclusion) {
                $snapshot.AvdScalingExclusions[$name.ToLowerInvariant()] = [string]$exclusion
            }
        }
    }

    $snapshot.Listed = $true
    $snapshot.NotRunning = $notRunning.ToArray()
    $snapshot.NotRunningDisplay = $notRunningDisplay.ToArray()
    return $snapshot
}

# The Azure Virtual Desktop service principal's object ID in this tenant, or '' when it cannot be
# found or created. It is looked up by app ID only, never by display name, so that a lookalike app
# registration can never be given a role on the subscription.
function Resolve-AvdServicePrincipalObjectId {
    param(
        [AllowEmptyString()][string]$ConfiguredObjectId = '',
        [Parameter(Mandatory = $true)][string]$AppId,
        [switch]$SkipCreate
    )

    $parsed = [guid]::Empty
    if (-not [string]::IsNullOrWhiteSpace($ConfiguredObjectId)) {
        if (-not [guid]::TryParseExact($ConfiguredObjectId.Trim(), 'D', [ref]$parsed)) {
            throw "azd environment value 'avdServicePrincipalObjectId' must be the object ID of the Azure Virtual Desktop service principal, a GUID, but was '$ConfiguredObjectId'."
        }

        return $parsed.ToString()
    }

    if (-not [guid]::TryParseExact($AppId.Trim(), 'D', [ref]$parsed)) {
        throw "azd environment value 'avdServicePrincipalAppId' must be the app ID of the Azure Virtual Desktop service principal, a GUID, but was '$AppId'."
    }

    $appIdValue = $parsed.ToString()
    $listJson = (@(az ad sp list --filter "appId eq '$appIdValue'" --query '[].id' --output json --only-show-errors 2>$null) -join "`n")
    if ($LASTEXITCODE -eq 0) {
        $ids = @()
        try {
            $ids = @(ConvertFrom-Json -InputObject $listJson | ForEach-Object { [string]$_ })
        }
        catch {
            $ids = @()
        }

        foreach ($id in $ids) {
            if ([guid]::TryParseExact($id, 'D', [ref]$parsed)) {
                return $parsed.ToString()
            }
        }
    }

    if ($SkipCreate) {
        return ''
    }

    $createdId = (@(az ad sp create --id $appIdValue --query id --output tsv --only-show-errors 2>$null) -join '').Trim()
    if ($LASTEXITCODE -eq 0 -and [guid]::TryParseExact($createdId, 'D', [ref]$parsed)) {
        return $parsed.ToString()
    }

    return ''
}

# A GET on Azure Resource Manager through az rest. The query string goes in --url-parameters,
# because az.cmd would hand an unquoted & in the URL to cmd.exe.
function Invoke-ArmGetRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$QueryParameters
    )

    # Merged stderr lines must not stop the script, whatever the caller's preference.
    $callerErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = az rest --method get --url $Path --url-parameters $QueryParameters --output json --only-show-errors 2>&1
        $succeeded = $LASTEXITCODE -eq 0
    }
    finally {
        $ErrorActionPreference = $callerErrorActionPreference
    }

    $standardOutput = New-Object System.Collections.Generic.List[string]
    $errorOutput = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($output)) {
        if ($line -is [System.Management.Automation.ErrorRecord]) {
            $errorOutput.Add([string]$line)
        }
        elseif ($null -ne $line) {
            $standardOutput.Add([string]$line)
        }
    }

    $response = $null
    if ($succeeded) {
        try {
            $response = ConvertFrom-Json -InputObject ($standardOutput -join "`n")
        }
        catch {
            $response = $null
        }

        if ($null -eq $response) {
            $succeeded = $false
            $errorOutput.Add('The response was not a JSON object.')
        }
    }

    return @{
        Succeeded = $succeeded
        Response = $response
        ErrorText = ($errorOutput -join "`n")
    }
}

# Whether the principal holds the role on the whole subscription, directly or from a management
# group: Assigned, NotAssigned or Unknown. Autoscale is not satisfied by the role on a resource
# group.
function Get-AvdAutoscaleRoleState {
    param(
        [Parameter(Mandatory = $true)][string]$PrincipalObjectId,
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [string]$RoleDefinitionId = '40c5ff49-9181-41f8-ae61-143b0e78555e'
    )

    $subscriptionScope = "/subscriptions/$SubscriptionId"
    # atScope() returns the assignments on the subscription and the scopes above it, and
    # assignedTo() the principal's own and those of the groups it belongs to.
    $request = Invoke-ArmGetRequest -Path "$subscriptionScope/providers/Microsoft.Authorization/roleAssignments" -QueryParameters @(
        'api-version=2022-04-01',
        ('$filter=atScope() and assignedTo(''{0}'')' -f $PrincipalObjectId)
    )
    if (-not $request.Succeeded) {
        return 'Unknown'
    }

    foreach ($assignment in @(Get-PropertyValue -InputObject $request.Response -Name 'value')) {
        $properties = Get-PropertyValue -InputObject $assignment -Name 'properties'
        if ($null -eq $properties) {
            $properties = $assignment
        }

        $principalId = [string](Get-PropertyValue -InputObject $properties -Name 'principalId')
        $principalType = [string](Get-PropertyValue -InputObject $properties -Name 'principalType')
        $roleDefinition = [string](Get-PropertyValue -InputObject $properties -Name 'roleDefinitionId')
        $scope = [string](Get-PropertyValue -InputObject $properties -Name 'scope')
        if (-not [string]::Equals($principalId, $PrincipalObjectId, [System.StringComparison]::OrdinalIgnoreCase) -and $principalType -ne 'Group') {
            continue
        }

        if (-not $roleDefinition.EndsWith("/$RoleDefinitionId", [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        if ($scope -eq '/' -or
            [string]::Equals($scope.TrimEnd('/'), $subscriptionScope, [System.StringComparison]::OrdinalIgnoreCase) -or
            $scope.StartsWith('/providers/Microsoft.Management/managementGroups/', [System.StringComparison]::OrdinalIgnoreCase)) {
            return 'Assigned'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue -InputObject $request.Response -Name 'nextLink'))) {
        return 'Unknown'
    }

    return 'NotAssigned'
}

# Whether an Azure RBAC action matches one of a role's action patterns, in which * is a wildcard.
function Test-ActionPermitted {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [AllowNull()][AllowEmptyCollection()][object[]]$Patterns = @()
    )

    foreach ($pattern in @($Patterns)) {
        $text = [string]$pattern
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $expression = '^' + [regex]::Escape($text.Trim()).Replace('\*', '.*') + '\z'
        if ([regex]::IsMatch($Action, $expression, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            return $true
        }
    }

    return $false
}

# Whether the signed-in account can create role assignments on the whole subscription: Yes, No or
# Unknown. It reads the account's effective permissions there, which do not show deny assignments,
# so the deployment can still be refused.
function Test-CanAssignSubscriptionRole {
    param([Parameter(Mandatory = $true)][string]$SubscriptionId)

    $action = 'Microsoft.Authorization/roleAssignments/write'
    $request = Invoke-ArmGetRequest -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/permissions" -QueryParameters @('api-version=2022-04-01')
    if (-not $request.Succeeded) {
        if ($request.ErrorText -match 'AuthorizationFailed|Forbidden') {
            return 'No'
        }

        return 'Unknown'
    }

    $conditional = $false
    foreach ($permission in @(Get-PropertyValue -InputObject $request.Response -Name 'value')) {
        if ($null -eq $permission) {
            continue
        }

        $actions = @(Get-PropertyValue -InputObject $permission -Name 'actions')
        $notActions = @(Get-PropertyValue -InputObject $permission -Name 'notActions')
        if ((Test-ActionPermitted -Action $action -Patterns $actions) -and -not (Test-ActionPermitted -Action $action -Patterns $notActions)) {
            # A condition, such as one that limits which roles may be assigned, may not allow this one.
            if ([string]::IsNullOrWhiteSpace([string](Get-PropertyValue -InputObject $permission -Name 'condition'))) {
                return 'Yes'
            }

            $conditional = $true
        }
    }

    if ($conditional -or -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue -InputObject $request.Response -Name 'nextLink'))) {
        return 'Unknown'
    }

    return 'No'
}

# Whether the deployment gives the Azure Virtual Desktop service principal Desktop Virtualization
# Power On Off Contributor on the subscription, and whether it assigns the scaling plan to the
# host pool, which Azure refuses while the service principal lacks that role. An assignment that
# is certain to be refused is left out with a warning, so that it does not fail the deployment.
function Resolve-AvdAutoscaleRolePlan {
    param(
        [Parameter(Mandatory = $true)][bool]$AvdSessionHostsDeployed,
        [Parameter(Mandatory = $true)][bool]$ScalingPlanRequested,
        [Parameter(Mandatory = $true)][bool]$StartVmOnConnect,
        [Parameter(Mandatory = $true)][bool]$AssignRoleRequested,
        [AllowEmptyString()][string]$ConfiguredObjectId = '',
        [Parameter(Mandatory = $true)][string]$AppId,
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [string]$RoleDefinitionId = '40c5ff49-9181-41f8-ae61-143b0e78555e'
    )

    $plan = @{
        ServicePrincipalObjectId = ''
        AssignRole = $false
        ScalingPlanEnabled = $ScalingPlanRequested
        Summary = ''
    }

    if (-not $AvdSessionHostsDeployed) {
        $plan.Summary = 'no AVD session hosts are deployed.'
        return $plan
    }

    if (-not $ScalingPlanRequested -and -not $StartVmOnConnect) {
        $plan.Summary = 'neither the scaling plan nor Start VM on Connect needs a role.'
        return $plan
    }

    $roleName = 'Desktop Virtualization Power On Off Contributor'
    $startVmImpact = 'Start VM on Connect cannot start session hosts'
    $leftOutImpact = New-Object System.Collections.Generic.List[string]
    $keptImpact = New-Object System.Collections.Generic.List[string]
    if ($ScalingPlanRequested) {
        $leftOutImpact.Add('the scaling plan is deployed but assigned to no host pool, because Azure refuses the assignment without the role')
        $keptImpact.Add('Azure refuses to assign the scaling plan to the host pool, which fails the deployment')
    }
    if ($StartVmOnConnect) {
        $leftOutImpact.Add($startVmImpact)
        $keptImpact.Add($startVmImpact)
    }

    $objectId = Resolve-AvdServicePrincipalObjectId -ConfiguredObjectId $ConfiguredObjectId -AppId $AppId -SkipCreate:(-not $AssignRoleRequested)
    $plan.ServicePrincipalObjectId = $objectId
    $ownerCommand = "az role assignment create --assignee-object-id $objectId --assignee-principal-type ServicePrincipal --role $RoleDefinitionId --scope /subscriptions/$SubscriptionId"

    if (-not $AssignRoleRequested) {
        # The administrator manages the role, possibly through a custom role this check cannot see,
        # so the scaling plan stays as requested.
        if (-not [string]::IsNullOrWhiteSpace($objectId) -and
            (Get-AvdAutoscaleRoleState -PrincipalObjectId $objectId -SubscriptionId $SubscriptionId -RoleDefinitionId $RoleDefinitionId) -eq 'NotAssigned') {
            Write-Warning "assignAvdAutoscaleRole is false, and the Azure Virtual Desktop service principal does not hold $roleName on subscription '$SubscriptionId'. Unless it has the same permissions through another role, $($keptImpact -join ', and '). An Owner or User Access Administrator can assign the role with this command: $ownerCommand"
        }

        $plan.Summary = 'the role is managed outside this deployment (assignAvdAutoscaleRole is false).'
        return $plan
    }

    if ([string]::IsNullOrWhiteSpace($objectId)) {
        $plan.ScalingPlanEnabled = $false
        Write-Warning "Could not find or create the service principal of Azure Virtual Desktop (app ID $AppId) in this tenant, so the deployment cannot give it $roleName on subscription '$SubscriptionId'. Until it holds the role, $($leftOutImpact -join ', and '). Set avdServicePrincipalObjectId to the object ID of the service principal and run azd provision again, or, if it already holds the role, set assignAvdAutoscaleRole to false."
        $plan.Summary = 'the Azure Virtual Desktop service principal was not found, so no role is assigned.'
        return $plan
    }

    $roleState = Get-AvdAutoscaleRoleState -PrincipalObjectId $objectId -SubscriptionId $SubscriptionId -RoleDefinitionId $RoleDefinitionId
    if ($roleState -eq 'Assigned') {
        $plan.Summary = "the Azure Virtual Desktop service principal already holds $roleName on the subscription."
        return $plan
    }

    $canAssign = Test-CanAssignSubscriptionRole -SubscriptionId $SubscriptionId
    if ($canAssign -eq 'No') {
        $plan.ScalingPlanEnabled = $false
        Write-Warning "Your account cannot assign roles on subscription '$SubscriptionId', so the deployment cannot give the Azure Virtual Desktop service principal $roleName there. Until it holds the role, $($leftOutImpact -join ', and '). Have an Owner or User Access Administrator run the command below, then run azd provision again. If the service principal has the same permissions through another role, set assignAvdAutoscaleRole to false instead. Command: $ownerCommand"
        $plan.Summary = 'the role is not assigned, and your account cannot assign it.'
        return $plan
    }

    $plan.AssignRole = $true
    if ($roleState -eq 'Unknown' -or $canAssign -eq 'Unknown') {
        Write-Warning "Could not confirm whether the Azure Virtual Desktop service principal already holds $roleName on subscription '$SubscriptionId', or whether your account can assign it, so the deployment assigns it. If the deployment fails with RoleAssignmentExists, the role is already assigned: set assignAvdAutoscaleRole to false. If it fails with AuthorizationFailed, have an Owner or User Access Administrator run the command below, then set assignAvdAutoscaleRole to false. Command: $ownerCommand"
    }

    $plan.Summary = "the deployment gives the Azure Virtual Desktop service principal $roleName on the subscription."
    return $plan
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
            allowedMemberTypes = @('User')
            description = 'Read-only access to the Linux Broker management portal and APIs.'
            displayName = 'Reader'
            id = $apiRoleIds.Reader
            isEnabled = $true
            value = 'Reader'
        }
        @{
            allowedMemberTypes = @('User')
            description = 'Operate Linux Broker hosts: release, return, retry cleanup, maintenance, and apply host settings.'
            displayName = 'Operator'
            id = $apiRoleIds.Operator
            isEnabled = $true
            value = 'Operator'
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

Set-AzdEnvValue -Key 'AZURE_CLOUD_NAME' -Value $cloudContext.Name
Set-AzdEnvValue -Key 'azureCloudName' -Value $cloudContext.Name
Set-AzdEnvValue -Key 'graphEndpoint' -Value $cloudContext.GraphUrl
Set-AzdEnvValue -Key 'appServiceDomain' -Value $cloudContext.AppServiceDomain
Set-AzdEnvValue -Key 'stsIssuerHost' -Value $cloudContext.StsIssuerHost
Set-AzdEnvValue -Key 'azureAuthorityHost' -Value $cloudContext.AuthorityHost
Write-Host "Targeting Azure cloud '$($cloudContext.Name)' (Graph: $($cloudContext.GraphUrl), App Service domain: $($cloudContext.AppServiceDomain))."

$frontendAppDisplayName = "$AppName-$EnvironmentName-frontend-ar"
$apiAppDisplayName = "$AppName-$EnvironmentName-api-ar"
$frontendAppServiceName = "fe-$AppName-$EnvironmentName"
$avdGroupName = "$AppName-$EnvironmentName-avd-hosts-sg"
$linuxGroupName = "$AppName-$EnvironmentName-linux-hosts-sg"
$avdUsersGroupName = "$AppName-$EnvironmentName-avd-users-sg"

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
Ensure-DefaultEnvValue -Key 'linuxHostOsVersion' -ValueFactory { '9-LVM' } | Out-Null
Ensure-DefaultEnvValue -Key 'linuxHostDisableScreenLock' -ValueFactory { 'true' } | Out-Null
Ensure-DefaultEnvValue -Key 'linuxHostDesktop' -ValueFactory { 'gnome' } | Out-Null
Ensure-DefaultEnvValue -Key 'linuxHostVmSize' -ValueFactory { 'Standard_D2s_v5' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdVmSize' -ValueFactory { 'Standard_D8s_v5' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdMaxSessionLimit' -ValueFactory { '5' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdLinuxDesktopFullScreen' -ValueFactory { 'true' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdLinuxDesktopMultiMonitor' -ValueFactory { 'true' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdScalingPlanEnabled' -ValueFactory { 'true' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdStartVmOnConnect' -ValueFactory { 'true' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdScalingPlanTimeZone' -ValueFactory { 'UTC' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdScalingPlanRampUpStart' -ValueFactory { '07:00' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdScalingPlanPeakStart' -ValueFactory { '09:00' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdScalingPlanRampDownStart' -ValueFactory { '18:00' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdScalingPlanOffPeakStart' -ValueFactory { '20:00' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdScalingPlanRampUpMinimumHostsPct' -ValueFactory { '20' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdScalingPlanRampUpCapacityThresholdPct' -ValueFactory { '60' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdScalingPlanRampDownMinimumHostsPct' -ValueFactory { '10' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdScalingPlanRampDownCapacityThresholdPct' -ValueFactory { '90' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdScalingPlanWeekendMinimumHostsPct' -ValueFactory { '0' } | Out-Null
Ensure-DefaultEnvValue -Key 'assignAvdAutoscaleRole' -ValueFactory { 'true' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdServicePrincipalAppId' -ValueFactory { $avdServicePrincipalAppId } | Out-Null
Ensure-DefaultEnvValue -Key 'vmSubscriptionId' -ValueFactory { $subscription.id } | Out-Null
Ensure-DefaultEnvValue -Key 'sqlAdminLogin' -ValueFactory { 'brokeradmin' } | Out-Null
Ensure-DefaultEnvValue -Key 'sqlDatabaseName' -ValueFactory { 'LinuxBroker' } | Out-Null
Ensure-DefaultEnvValue -Key 'sqlDatabaseSkuName' -ValueFactory { 'Basic' } | Out-Null
Ensure-DefaultEnvValue -Key 'allowLegacyScopeAccess' -ValueFactory { 'false' } | Out-Null
Ensure-DefaultEnvValue -Key 'appServicePlanSku' -ValueFactory { 'P2mv3' } | Out-Null
Ensure-DefaultEnvValue -Key 'linuxHostAdminLoginName' -ValueFactory { 'avdadmin' } | Out-Null
Ensure-DefaultEnvValue -Key 'domainName' -ValueFactory { '' } | Out-Null
Ensure-DefaultEnvValue -Key 'nfsShare' -ValueFactory { '' } | Out-Null
Ensure-DefaultEnvValue -Key 'deployNfsShare' -ValueFactory { 'true' } | Out-Null
Ensure-DefaultEnvValue -Key 'nfsShareQuotaGiB' -ValueFactory { '100' } | Out-Null
Ensure-DefaultEnvValue -Key 'avdUsersGroupId' -ValueFactory { '' } | Out-Null
Ensure-DefaultEnvValue -Key 'vmHostResourceGroup' -ValueFactory { '' } | Out-Null
Ensure-DefaultEnvValue -Key 'scriptSourceRoot' -ValueFactory { 'https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/refs/heads/main' } | Out-Null
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

# The subscription azd provisions, where the hosts and the scaling plan deploy; not vmSubscriptionId.
$deploymentSubscriptionId = Get-FirstNonEmptyValue -Values @(
    (Get-AzdEnvValue -Key 'AZURE_SUBSCRIPTION_ID'),
    $env:AZURE_SUBSCRIPTION_ID,
    $subscription.id
)

if ($deployLinuxHostsValue -eq 'true' -and (ConvertTo-IntParameterValue -Key 'linuxHostCount') -gt 0) {
    Ensure-LinuxHostImageTerms -OsVersion (Get-AzdEnvValue -Key 'linuxHostOsVersion') -SubscriptionId $deploymentSubscriptionId
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
Ensure-AppAdminConsent -AppId $frontendApp.appId -DisplayName $frontendApp.displayName

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

# Optional groups for the portal roles. Assigning an app role to a group needs Microsoft
# Entra ID P1 or P2; without it, assign the roles to users directly.
$portalRoleGroups = [ordered]@{
    brokerReaderGroupId = @{ Role = 'Reader'; Id = $apiRoleIds.Reader }
    brokerOperatorGroupId = @{ Role = 'Operator'; Id = $apiRoleIds.Operator }
    brokerAdminGroupId = @{ Role = 'FullAccess'; Id = $apiRoleIds.FullAccess }
}
$portalRoleSummary = @()
foreach ($entry in $portalRoleGroups.GetEnumerator()) {
    $groupId = Get-AzdEnvValue -Key $entry.Key
    if (-not [string]::IsNullOrWhiteSpace($groupId)) {
        Ensure-GroupAppRoleAssignment -CloudContext $cloudContext -GroupId $groupId.Trim() -ResourceServicePrincipalId $apiServicePrincipal.id -AppRoleId $entry.Value.Id
        $portalRoleSummary += "$($entry.Value.Role) -> $($groupId.Trim())"
    }
}

$avdUsersGroupSummary = 'not configured (AVD hosts are not deployed)'
if ((Get-AzdEnvValue -Key 'deployAvdHosts') -eq 'true') {
    $avdUsersGroupId = Get-AzdEnvValue -Key 'avdUsersGroupId'
    if ([string]::IsNullOrWhiteSpace($avdUsersGroupId)) {
        # No existing group was supplied, so create a managed group and add the
        # deploying user so they can open the Linux Desktop RemoteApp right away.
        $avdUsersGroup = Ensure-Group -DisplayName $avdUsersGroupName
        $avdUsersGroupId = $avdUsersGroup.id
        Set-AzdEnvValue -Key 'avdUsersGroupId' -Value $avdUsersGroupId
        $avdUsersGroupSummary = "$($avdUsersGroup.displayName) ($avdUsersGroupId)"

        if ($deploymentUser) {
            if (Ensure-GroupMember -GroupId $avdUsersGroupId -MemberId $deploymentUser.id) {
                Write-Host "Added $($deploymentUser.userPrincipalName) to AVD users group '$($avdUsersGroup.displayName)'."
            }
            else {
                Write-Warning "Unable to add $($deploymentUser.userPrincipalName) to AVD users group '$($avdUsersGroup.displayName)'. Add users to the group manually."
            }
        }
    }
    else {
        $avdUsersGroupSummary = "$avdUsersGroupId (supplied through azd environment value 'avdUsersGroupId')"
    }

    Ensure-EntraRdpAuthentication -CloudContext $cloudContext
}

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
if ($portalRoleSummary.Count -gt 0) {
    Write-Host "Portal role groups: $($portalRoleSummary -join '; ')"
}
else {
    Write-Host 'Portal role groups: none configured. Assign the Reader, Operator or FullAccess app roles to administrators in Microsoft Entra ID.'
}
Write-Host "AVD users group: $avdUsersGroupSummary"
Write-Host 'Automatic admin consent was attempted for the configured application permissions. If consent was not granted, complete it manually in Microsoft Entra ID.'

# Azure refuses to change an extension on a VM that is not running, and autoscale and the broker's
# own scaling leave hosts deallocated. So the deployment leaves out the extensions of the hosts that
# are not running, and writes back the excludeFromScaling tags it would otherwise remove. This is
# the resource group main.bicep deploys to, since resourceGroupName is not set here.
$deploymentResourceGroupName = "rg-$(Get-RequiredAzdEnvValue -Key 'appName')-$EnvironmentName"
$hostNamesNotRunning = @()
$avdScalingExclusions = [ordered]@{}
if ((ConvertTo-BoolParameterValue -Key 'deployLinuxHosts') -or (ConvertTo-BoolParameterValue -Key 'deployAvdHosts')) {
    $hostSnapshot = Get-HostPowerStateSnapshot -SubscriptionId $deploymentSubscriptionId -ResourceGroupName $deploymentResourceGroupName
    $hostNamesNotRunning = @($hostSnapshot.NotRunning)
    $avdScalingExclusions = $hostSnapshot.AvdScalingExclusions
    if ($hostNamesNotRunning.Count -gt 0) {
        Write-Warning "These hosts are not running, so this deployment leaves their VM extensions as they are: $($hostSnapshot.NotRunningDisplay -join ', '). Changes that the extensions carry, such as the API URL, scriptSourceRoot, linuxHostDesktop and linuxHostDisableScreenLock, reach a host only once it is running and azd provision runs again. If a host stops while this deployment runs, the deployment can still fail; run azd provision again."
    }

    if ($avdScalingExclusions.Count -gt 0) {
        Write-Host "Keeping the excludeFromScaling tag on AVD session hosts: $(@($avdScalingExclusions.Keys) -join ', ')."
    }
}

# The AVD scaling plan and the role that lets Azure Virtual Desktop start and stop session hosts.
$avdScalingPlanTimes = [ordered]@{
    avdScalingPlanRampUpStart = ConvertTo-TimeOfDayParameterValue -Key 'avdScalingPlanRampUpStart' -DefaultValue '07:00'
    avdScalingPlanPeakStart = ConvertTo-TimeOfDayParameterValue -Key 'avdScalingPlanPeakStart' -DefaultValue '09:00'
    avdScalingPlanRampDownStart = ConvertTo-TimeOfDayParameterValue -Key 'avdScalingPlanRampDownStart' -DefaultValue '18:00'
    avdScalingPlanOffPeakStart = ConvertTo-TimeOfDayParameterValue -Key 'avdScalingPlanOffPeakStart' -DefaultValue '20:00'
}
Assert-AvdScalingPlanTimeOrder -Times $avdScalingPlanTimes
$avdScalingPlanRampUpMinimumHostsPct = ConvertTo-PercentParameterValue -Key 'avdScalingPlanRampUpMinimumHostsPct' -DefaultValue 20
$avdScalingPlanRampUpCapacityThresholdPct = ConvertTo-PercentParameterValue -Key 'avdScalingPlanRampUpCapacityThresholdPct' -DefaultValue 60 -Minimum 1
$avdScalingPlanRampDownMinimumHostsPct = ConvertTo-PercentParameterValue -Key 'avdScalingPlanRampDownMinimumHostsPct' -DefaultValue 10
$avdScalingPlanRampDownCapacityThresholdPct = ConvertTo-PercentParameterValue -Key 'avdScalingPlanRampDownCapacityThresholdPct' -DefaultValue 90 -Minimum 1
$avdScalingPlanWeekendMinimumHostsPct = ConvertTo-PercentParameterValue -Key 'avdScalingPlanWeekendMinimumHostsPct' -DefaultValue 0
$avdStartVmOnConnect = ConvertTo-BoolParameterValue -Key 'avdStartVmOnConnect' -DefaultValue $true
$avdSessionHostsDeployed = (ConvertTo-BoolParameterValue -Key 'deployAvdHosts') -and
    ((ConvertTo-IntParameterValue -Key 'avdSessionHostCount') -gt 0) -and
    (-not [string]::IsNullOrWhiteSpace((Get-AzdEnvValue -Key 'avdHostPoolName')))

$avdScalingPlanTimeZone = Get-FirstNonEmptyValue -Values @((Get-AzdEnvValue -Key 'avdScalingPlanTimeZone'), 'UTC')
$knownTimeZoneId = Resolve-WindowsTimeZoneId -TimeZoneId $avdScalingPlanTimeZone
if (-not [string]::IsNullOrWhiteSpace($knownTimeZoneId)) {
    $avdScalingPlanTimeZone = $knownTimeZoneId
}
elseif ($avdSessionHostsDeployed) {
    $timeZoneHint = ''
    if ($avdScalingPlanTimeZone.Contains('/')) {
        $timeZoneHint = ' It looks like an IANA time zone name; use the Windows ID instead, such as Eastern Standard Time for America/New_York.'
    }

    Write-Warning "avdScalingPlanTimeZone '$avdScalingPlanTimeZone' is not a Windows time zone ID this machine knows, so Azure may refuse the scaling plan.$timeZoneHint"
}

$avdAutoscaleArguments = @{
    AvdSessionHostsDeployed = $avdSessionHostsDeployed
    ScalingPlanRequested = (ConvertTo-BoolParameterValue -Key 'avdScalingPlanEnabled' -DefaultValue $true)
    StartVmOnConnect = $avdStartVmOnConnect
    AssignRoleRequested = (ConvertTo-BoolParameterValue -Key 'assignAvdAutoscaleRole' -DefaultValue $true)
    ConfiguredObjectId = (Get-AzdEnvValue -Key 'avdServicePrincipalObjectId')
    AppId = (Get-FirstNonEmptyValue -Values @((Get-AzdEnvValue -Key 'avdServicePrincipalAppId'), $avdServicePrincipalAppId))
    SubscriptionId = $deploymentSubscriptionId
    RoleDefinitionId = $avdAutoscaleRoleDefinitionId
}
$avdAutoscale = Resolve-AvdAutoscaleRolePlan @avdAutoscaleArguments
if ($avdSessionHostsDeployed) {
    $avdScalingPlanState = "assigned to the host pool, in time zone $avdScalingPlanTimeZone"
    if (-not $avdAutoscale.ScalingPlanEnabled) {
        $avdScalingPlanState = 'deployed but assigned to no host pool'
    }

    $avdStartVmOnConnectState = 'off'
    if ($avdStartVmOnConnect) {
        $avdStartVmOnConnectState = 'on'
    }

    Write-Host "AVD autoscale: scaling plan $avdScalingPlanState; Start VM on Connect $avdStartVmOnConnectState; $($avdAutoscale.Summary)"
}

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
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdUsersGroupId' -Value (Get-AzdEnvValue -Key 'avdUsersGroupId')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'sqlAdminLogin' -Value (Get-RequiredAzdEnvValue -Key 'sqlAdminLogin')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'sqlAdminPassword' -Value (Get-RequiredAzdEnvValue -Key 'sqlAdminPassword')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'sqlDatabaseSkuName' -Value (Get-RequiredAzdEnvValue -Key 'sqlDatabaseSkuName')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'allowLegacyScopeAccess' -Value (ConvertTo-BoolParameterValue -Key 'allowLegacyScopeAccess' -DefaultValue $false)
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'flaskKey' -Value (Get-RequiredAzdEnvValue -Key 'flaskKey')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'domainName' -Value (Get-AzdEnvValue -Key 'domainName')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'nfsShare' -Value (Get-AzdEnvValue -Key 'nfsShare')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'deployNfsShare' -Value (ConvertTo-BoolParameterValue -Key 'deployNfsShare' -DefaultValue $true)
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'nfsShareQuotaGiB' -Value (ConvertTo-IntParameterValue -Key 'nfsShareQuotaGiB' -DefaultValue 100)
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
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'linuxHostDisableScreenLock' -Value (ConvertTo-BoolParameterValue -Key 'linuxHostDisableScreenLock' -DefaultValue $true)
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'linuxHostDesktop' -Value (Get-RequiredAzdEnvValue -Key 'linuxHostDesktop').Trim().ToLowerInvariant()
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdHostPoolName' -Value (Get-RequiredAzdEnvValue -Key 'avdHostPoolName')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdSessionHostCount' -Value (ConvertTo-IntParameterValue -Key 'avdSessionHostCount')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdMaxSessionLimit' -Value (ConvertTo-IntParameterValue -Key 'avdMaxSessionLimit' -DefaultValue 5)
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdLinuxDesktopFullScreen' -Value (ConvertTo-BoolParameterValue -Key 'avdLinuxDesktopFullScreen' -DefaultValue $true)
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdLinuxDesktopMultiMonitor' -Value (ConvertTo-BoolParameterValue -Key 'avdLinuxDesktopMultiMonitor' -DefaultValue $true)
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdScalingPlanEnabled' -Value ([bool]$avdAutoscale.ScalingPlanEnabled)
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdStartVmOnConnect' -Value $avdStartVmOnConnect
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdScalingPlanTimeZone' -Value $avdScalingPlanTimeZone
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdScalingPlanRampUpStart' -Value $avdScalingPlanTimes['avdScalingPlanRampUpStart']
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdScalingPlanPeakStart' -Value $avdScalingPlanTimes['avdScalingPlanPeakStart']
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdScalingPlanRampDownStart' -Value $avdScalingPlanTimes['avdScalingPlanRampDownStart']
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdScalingPlanOffPeakStart' -Value $avdScalingPlanTimes['avdScalingPlanOffPeakStart']
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdScalingPlanRampUpMinimumHostsPct' -Value $avdScalingPlanRampUpMinimumHostsPct
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdScalingPlanRampUpCapacityThresholdPct' -Value $avdScalingPlanRampUpCapacityThresholdPct
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdScalingPlanRampDownMinimumHostsPct' -Value $avdScalingPlanRampDownMinimumHostsPct
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdScalingPlanRampDownCapacityThresholdPct' -Value $avdScalingPlanRampDownCapacityThresholdPct
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdScalingPlanWeekendMinimumHostsPct' -Value $avdScalingPlanWeekendMinimumHostsPct
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdScalingExclusions' -Value $avdScalingExclusions
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'hostNamesNotRunning' -Value @($hostNamesNotRunning)
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdServicePrincipalObjectId' -Value $avdAutoscale.ServicePrincipalObjectId
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'assignAvdAutoscaleRole' -Value ([bool]$avdAutoscale.AssignRole)
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdVmNamePrefix' -Value (Get-RequiredAzdEnvValue -Key 'avdVmNamePrefix')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'avdVmSize' -Value (Get-RequiredAzdEnvValue -Key 'avdVmSize')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'azureCloudName' -Value (Get-RequiredAzdEnvValue -Key 'azureCloudName')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'azureAuthorityHost' -Value (Get-AzdEnvValue -Key 'azureAuthorityHost')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'graphEndpoint' -Value (Get-RequiredAzdEnvValue -Key 'graphEndpoint')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'stsIssuerHost' -Value (Get-RequiredAzdEnvValue -Key 'stsIssuerHost')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'appServiceDomain' -Value (Get-RequiredAzdEnvValue -Key 'appServiceDomain')
Add-BicepParameterValue -ParameterCollection $bicepParameterEntries -ParameterName 'scriptSourceRoot' -Value (Get-RequiredAzdEnvValue -Key 'scriptSourceRoot')

$bicepParameters = [ordered]@{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters = $bicepParameterEntries
}

$bicepParameters | ConvertTo-Json -Depth 10 | Set-Content -Path $bicepParametersPath -Encoding utf8
Write-Host "Generated Bicep parameters file at '$bicepParametersPath'."
