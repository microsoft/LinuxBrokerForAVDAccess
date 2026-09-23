#requires -Version 7.4
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$deployRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $deployRoot
. "$deployRoot\Broker.Identity.ps1"
. "$deployRoot\Broker.UserMapping.ps1"
. "$deployRoot\Broker.Launcher.ps1"
. "$deployRoot\Broker.LinuxMigration.ps1"
. "$deployRoot\Broker.BuildContext.ps1"
. "$deployRoot\Broker.Rollout.ps1"
. "$deployRoot\Broker.WorkloadReadiness.ps1"

$script:assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:assertions++
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern = '.', [string]$Message = 'Expected rejection')
    $script:assertions++
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    if (-not $caught) { throw "Assertion failed: $Message. No exception was raised." }
    if ($caught.Exception.Message -notmatch $Pattern) {
        throw "Assertion failed: $Message. Actual: $($caught.Exception.Message)"
    }
}
function Copy-TestObject { param($Value) return ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 100 -Compress) -AsHashtable }
function Get-TestArgument {
    param([array]$Arguments, [string]$Name)
    $index = [array]::IndexOf($Arguments, $Name)
    if ($index -lt 0) { return '' }
    return $Arguments[$index + 1]
}
function New-TestId {
    param([int]$Number)
    return 'aaaaaaaa-aaaa-4aaa-8aaa-' + $Number.ToString('000000000000')
}
$tenant = New-TestId 1
$apiId = New-TestId 2
$portalId = New-TestId 3
$launcherId = New-TestId 4
$apiObject = New-TestId 12
$portalObject = New-TestId 13
$launcherObject = New-TestId 14
$workspaceGroup = New-TestId 20
$adminGroup = New-TestId 21
$userId = New-TestId 22
$unselectedUser = New-TestId 23
$miId = New-TestId 24
$machineGroup = New-TestId 25
$graphObject = New-TestId 30
$graphReadRole = New-TestId 31
$unrelatedRole = New-TestId 32
$extraScope = New-TestId 33
$graphId = '00000003-0000-0000-c000-000000000000'
$script:state = @{}

function New-TestRole {
    param([string]$Value, [string]$Id, [array]$Members)
    return @{ id = $Id; value = $Value; displayName = $Value; description = $Value; allowedMemberTypes = $Members; isEnabled = $true; origin = 'Application' }
}
function Reset-TestDirectory {
    $script:state = @{
        Calls = [Collections.Generic.List[object]]::new()
        Apps = @{}; Principals = @{}; Assignments = @{}; GraphGrants = @()
        Users = @{}; Groups = @{}; Members = @{}; FailNextCli = $false
        GuestFailure = $false; GuestScripts = [Collections.Generic.List[string]]::new()
        GuestWorkloadFailure = $false
        GuestAdditionalOutput = ''
        NativeInstallRequests = [Collections.Generic.List[object]]::new()
        PrivateRequestPaths = [Collections.Generic.List[string]]::new()
        GraphMutations = [Collections.Generic.List[object]]::new()
        StorageReaders = @()
        NativeExtensions = [Collections.Generic.List[object]]::new()
        AppImages = @{}
        ApiStopped = $true
        TaskProbeFailure = $false
        TaskProbeCalls = [Collections.Generic.List[object]]::new()
        ApiSettings = @{}
        StoppedApps = [Collections.Generic.List[string]]::new()
        InvalidNextPage = $false
        IdtypReadbackLag = 0
        IdtypReadbacks = 0
        Vms = @{}; SessionHosts = @()
    }
    foreach ($id in @($userId, $unselectedUser)) {
        $script:state.Users[$id] = @{ id = $id; userPrincipalName = 'reviewed.user@example.org'; accountEnabled = $true }
    }
    foreach ($id in @($workspaceGroup, $adminGroup, $machineGroup)) {
        $script:state.Groups[$id] = @{ id = $id; securityEnabled = $true }
        $script:state.Members[$id] = @()
    }
    $script:state.Members[$machineGroup] = @(@{ id = $miId; '@odata.type' = '#microsoft.graph.servicePrincipal' })
    $roles = @(
        (New-TestRole FullAccess $script:BrokerRoleDefaults.FullAccess @('User'))
        (New-TestRole LinuxHost $script:BrokerRoleDefaults.LinuxHost @('Application', 'User'))
        (New-TestRole ScheduledTask $script:BrokerRoleDefaults.ScheduledTask @('Application', 'User'))
        (New-TestRole AvdHost (New-TestId 40) @('Application', 'User'))
        (New-TestRole OtherPermission $unrelatedRole @('Application'))
    )
    $script:state.Apps[$apiObject] = @{
        id = $apiObject; appId = $apiId; displayName = 'test-api-ar'; signInAudience = 'AzureADMyOrg'
        identifierUris = @('api://preserve-this-uri'); appRoles = $roles
        optionalClaims = @{
            accessToken = @(@{ name = 'ipaddr'; source = $null; essential = $true; additionalProperties = @() })
            idToken = @(@{ name = 'auth_time'; source = $null; essential = $true; additionalProperties = @() })
            saml2Token = @(@{ name = 'groups'; source = $null; essential = $false; additionalProperties = @('emit_as_roles') })
        }
        requiredResourceAccess = @(
            @{ resourceAppId = $graphId; resourceAccess = @(@{ id = $graphReadRole; type = 'Role' }, @{ id = $extraScope; type = 'Scope' }) },
            @{ resourceAppId = (New-TestId 99); resourceAccess = @(@{ id = $unrelatedRole; type = 'Role' }) }
        )
        api = @{
            requestedAccessTokenVersion = 1; acceptMappedClaims = $false
            knownClientApplications = @((New-TestId 98))
            preAuthorizedApplications = @(@{ appId = (New-TestId 98); delegatedPermissionIds = @($extraScope) })
            oauth2PermissionScopes = @(
                @{ id = $script:BrokerScopeDefaults.access_as_user; value = 'access_as_user'; isEnabled = $true; type = 'User'; adminConsentDescription = 'legacy'; adminConsentDisplayName = 'legacy' }
                @{ id = $extraScope; value = 'unrelated_scope'; isEnabled = $true; type = 'Admin'; adminConsentDescription = 'preserve'; adminConsentDisplayName = 'preserve' }
            )
        }
    }
    $script:state.Apps[$portalObject] = @{
        id = $portalObject; appId = $portalId; displayName = 'test-frontend-ar'; signInAudience = 'AzureADMyOrg'
        appRoles = @(); requiredResourceAccess = @()
        web = @{ redirectUris = @('https://keep.example/callback'); implicitGrantSettings = @{ enableIdTokenIssuance = $false } }
    }
    $script:state.Apps[$launcherObject] = @{
        id = $launcherObject; appId = $launcherId; displayName = 'test-launcher-ar'; signInAudience = 'AzureADMyOrg'
        appRoles = @(); requiredResourceAccess = @(); passwordCredentials = @(); keyCredentials = @()
        publicClient = @{ redirectUris = @('http://localhost') }
    }
    foreach ($objectId in @($apiObject, $portalObject, $launcherObject)) {
        $app = $script:state.Apps[$objectId]
        $script:state.Principals[$objectId] = @{ id = $objectId; appId = $app.appId; appRoles = (Copy-TestObject $app.appRoles); appRoleAssignmentRequired = $false }
        $script:state.Assignments[$objectId] = @()
    }
    $script:state.Principals[$graphObject] = @{
        id = $graphObject; appId = $graphId; appRoles = @((New-TestRole Directory.Read.All $graphReadRole @('Application')))
    }
    $script:state.Principals[$miId] = @{ id = $miId; appId = (New-TestId 124); appRoles = @(); servicePrincipalType = 'ManagedIdentity'; accountEnabled = $true }
    $script:state.Assignments[$apiObject] = @(
        @{ id = 'legacy-user'; principalId = $userId; principalType = 'User'; appRoleId = $script:BrokerRoleDefaults.LinuxHost; resourceId = $apiObject },
        @{ id = 'legacy-group'; principalId = $machineGroup; principalType = 'Group'; appRoleId = $script:BrokerRoleDefaults.LinuxHost; resourceId = $apiObject },
        @{ id = 'legacy-mi'; principalId = $miId; principalType = 'ServicePrincipal'; appRoleId = (New-TestId 40); resourceId = $apiObject }
    )
    $script:state.Assignments[$portalObject] = @(
        @{ id = 'unselected-portal'; principalId = $unselectedUser; principalType = 'User'; appRoleId = [guid]::Empty.ToString(); resourceId = $portalObject }
    )
    $script:state.GraphGrants = @(
        @{ id = 'retire-read'; resourceId = $graphObject; appRoleId = $graphReadRole },
        @{ id = 'keep-other'; resourceId = (New-TestId 99); appRoleId = $unrelatedRole }
    )
    $global:BrokerDeploymentTestState = $script:state
}

function Invoke-TestGraph {
    param([string]$Method, [string]$Uri, $Body)
    $parsed = [uri]$Uri
    $path = $parsed.AbsolutePath -replace '^/v1.0', ''
    $filter = [uri]::UnescapeDataString($parsed.Query)
    if ($Method -ne 'GET') { $script:state.GraphMutations.Add(@{ Method = $Method; Path = $path; Body = $Body }) }
    if ($path -eq '/paged') {
        if ($parsed.Query -eq '?page=2') { return @{ value = @(@{ id = 'second' }) } }
        return @{
            value = @(@{ id = 'first' })
            '@odata.nextLink' = if ($script:state.InvalidNextPage) { 'https://untrusted.example/v1.0/paged' } else { 'https://graph.example/v1.0/paged?page=2' }
        }
    }
    if ($path -eq '/applications' -and $Method -eq 'GET') {
        $apps = @($script:state.Apps.Values | Where-Object { $filter.Contains($_.appId) -or $filter.Contains($_.displayName) })
        return @{ value = (Copy-TestObject $apps) }
    }
    if ($path -eq '/servicePrincipals' -and $Method -eq 'GET') {
        return @{ value = @(Copy-TestObject @($script:state.Principals.Values | Where-Object { $filter.Contains($_.appId) })) }
    }
    if ($path -match '^/applications/([^/]+)$' -and $Method -eq 'PATCH') {
        $app = $script:state.Apps[$Matches[1]]
        foreach ($key in $Body.Keys) { $app[$key] = Copy-TestObject $Body[$key] }
        if ($Body.ContainsKey('appRoles')) { $script:state.Principals[$app.id].appRoles = Copy-TestObject $Body.appRoles }
        return $null
    }
    if ($path -match '^/applications/([^/]+)$' -and $Method -eq 'GET') {
        $application = Copy-TestObject $script:state.Apps[$Matches[1]]
        $script:state.IdtypReadbacks++
        if ($script:state.IdtypReadbackLag -gt 0) {
            $script:state.IdtypReadbackLag--
            $application.optionalClaims.accessToken = @($application.optionalClaims.accessToken | Where-Object { $_.name -ne 'idtyp' })
        }
        return $application
    }
    if ($path -match '^/servicePrincipals/([^/]+)$') {
        $sp = $script:state.Principals[$Matches[1]]
        if ($Method -eq 'PATCH') { foreach ($key in $Body.Keys) { $sp[$key] = Copy-TestObject $Body[$key] }; return $null }
        return Copy-TestObject $sp
    }
    if ($path -match '^/servicePrincipals/([^/]+)/appRoleAssignedTo(?:/([^/]+))?$') {
        $resource = $Matches[1]
        if ($Method -eq 'GET') { return @{ value = @(Copy-TestObject $script:state.Assignments[$resource]) } }
        if ($Method -eq 'DELETE') {
            $assignmentId = $Matches[2]
            $script:state.Assignments[$resource] = @($script:state.Assignments[$resource] | Where-Object { $_.id -ne $assignmentId })
            return $null
        }
        $role = @($script:state.Principals[$resource].appRoles | Where-Object { $_.id -eq $Body.appRoleId -and $_.isEnabled })
        if ($role.Count -ne 1) { throw 'Mock Graph rejects missing/disabled role assignment.' }
        if (@($script:state.Assignments[$resource] | Where-Object { $_.principalId -eq $Body.principalId -and $_.appRoleId -eq $Body.appRoleId }).Count) {
            throw 'Duplicate Graph app role assignment.'
        }
        $type = if ($script:state.Users.ContainsKey($Body.principalId)) { 'User' }
            elseif ($script:state.Groups.ContainsKey($Body.principalId)) { 'Group' } else { 'ServicePrincipal' }
        $script:state.Assignments[$resource] += @{
            id = [guid]::NewGuid().ToString(); principalId = $Body.principalId; principalType = $type
            resourceId = $resource; appRoleId = $Body.appRoleId
        }
        return $null
    }
    if ($path -match '^/servicePrincipals/([^/]+)/appRoleAssignments(?:/([^/]+))?$') {
        if ($Method -eq 'GET') { return @{ value = @(Copy-TestObject $script:state.GraphGrants) } }
        $assignmentId = $Matches[2]
        $script:state.GraphGrants = @($script:state.GraphGrants | Where-Object { $_.id -ne $assignmentId })
        return $null
    }
    if ($path -match '^/users/([^/]+)$') { return Copy-TestObject $script:state.Users[$Matches[1]] }
    if ($path -match '^/groups/([^/]+)/transitiveMembers$') { return @{ value = @(Copy-TestObject $script:state.Members[$Matches[1]]) } }
    if ($path -match '^/groups/([^/]+)$') { return Copy-TestObject $script:state.Groups[$Matches[1]] }
    throw "Unexpected mock Graph call: $Method $path"
}

# The scripts use the real checked CLI/Graph wrappers; this boundary prevents every live Azure call.
function az {
    $arguments = @($args)
    $mockState = $global:BrokerDeploymentTestState
    $mockState.Calls.Add($arguments)
    if ($mockState.FailNextCli) {
        $mockState.FailNextCli = $false
        $global:LASTEXITCODE = 17
        return 'SYNTHETIC_SECRET_THAT_MUST_NOT_BE_LOGGED'
    }
    $global:LASTEXITCODE = 0
    $result = $null
    switch ($arguments[0]) {
        'account' { $result = @{ tenantId = $tenant; id = (New-TestId 100); user = @{ type = 'user' } } }
        'cloud' { $result = @{ name = 'AzureCloud'; endpoints = @{
            resourceManager = 'https://management.example'; activeDirectoryResourceId = 'https://management.example'
            activeDirectory = 'https://login.microsoftonline.com'
        } } }
        'rest' {
            $uri = Get-TestArgument $arguments '--url'
            if ($uri -like 'https://task.scm.example/*') {
                $bodyPath = (Get-TestArgument $arguments '--body').Substring(1)
                $mockState.PrivateRequestPaths.Add($bodyPath)
                $mockState.TaskProbeCalls.Add((Get-Content -LiteralPath $bodyPath -Raw | ConvertFrom-Json -AsHashtable))
                $result = @{
                    Output = if ($mockState.TaskProbeFailure) { '' } else { 'BROKER_WORKLOAD_READY' }
                    ExitCode = if ($mockState.TaskProbeFailure) { 1 } else { 0 }
                    Error = if ($mockState.TaskProbeFailure) { 'synthetic-secret-not-for-logs' } else { '' }
                }
            }
            elseif ($uri -like 'https://management.example/*') {
                $result = @{ value = @($mockState.SessionHosts) }
            }
            else {
                $body = $null
                $bodyArgument = Get-TestArgument $arguments '--body'
                if ($bodyArgument) {
                    $mockState.PrivateRequestPaths.Add($bodyArgument.Substring(1))
                    $body = Get-Content -LiteralPath $bodyArgument.Substring(1) -Raw | ConvertFrom-Json -AsHashtable
                }
                $result = Invoke-TestGraph -Method (Get-TestArgument $arguments '--method') -Uri $uri -Body $body
            }
        }
        'storage' {
            switch ("$($arguments[1]) $($arguments[2])") {
                'account show' { $result = @{ id = '/subscriptions/test/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/artifacts'; primaryEndpoints = @{ blob = 'https://artifacts.example/' } } }
                'container create' { $result = @{ created = $false } }
                'blob upload' { $result = @{ etag = 'offline' } }
                default { throw 'Unexpected storage CLI operation in test.' }
            }
        }
        'role' {
            if ($arguments[2] -eq 'list') { $result = @($mockState.StorageReaders) }
            elseif ($arguments[2] -eq 'create') {
                $mockState.StorageReaders += @{
                    principalId = (Get-TestArgument $arguments '--assignee-object-id')
                    roleDefinitionId = '/subscriptions/test/providers/Microsoft.Authorization/roleDefinitions/' + (Get-TestArgument $arguments '--role')
                    scope = (Get-TestArgument $arguments '--scope')
                }
            } else { throw 'Unexpected role operation in test.' }
        }
        { $_ -in @('webapp', 'functionapp') } {
            $appName = Get-TestArgument $arguments '--name'
            if ($arguments[1] -eq 'stop') { $mockState.StoppedApps.Add($appName) }
            elseif ($arguments[1] -eq 'show') {
                $result = @{
                    state = if ($mockState.ApiStopped) { 'Stopped' } else { 'Running' }
                    enabledHostNames = @('task.example', 'task.scm.example')
                }
            }
            elseif ($arguments[1] -eq 'identity') { $result = @{ principalId = $miId; tenantId = $tenant } }
            elseif ($arguments[1] -eq 'config' -and $arguments[2] -eq 'show') {
                $result = @{ linuxFxVersion = $mockState.AppImages[$appName] }
            }
            elseif ($arguments[1] -eq 'config' -and $arguments[2] -eq 'appsettings' -and $arguments[3] -eq 'list') {
                $result = @($mockState.ApiSettings.GetEnumerator() | ForEach-Object { @{ name = $_.Key; value = $_.Value } })
            }
            elseif ($arguments[1] -eq 'config' -and $arguments[2] -eq 'appsettings' -and $arguments[3] -eq 'set') {
                $path = (Get-TestArgument $arguments '--settings').Substring(1)
                $mockState.PrivateRequestPaths.Add($path)
                $settings = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
                foreach ($key in $settings.Keys) { $mockState.ApiSettings[$key] = $settings[$key] }
            }
            else { throw 'Unexpected app operation in offline test.' }
        }
        'resource' { $result = @{ id = '/subscriptions/test/resourceGroups/test/providers/Microsoft.DesktopVirtualization/hostPools/pool' } }
        'vm' {
            if ($arguments[1] -eq 'list') { $result = @($mockState.Vms.Values) }
            elseif ($arguments[1] -eq 'show') { $result = $mockState.Vms[(Get-TestArgument $arguments '--ids')] }
            elseif ($arguments[1] -eq 'extension') {
                $settingsPath = (Get-TestArgument $arguments '--protected-settings').Substring(1)
                $mockState.PrivateRequestPaths.Add($settingsPath)
                $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable
                $mockState.NativeExtensions.Add($settings)
                $encoded = ($settings.commandToExecute -split ' ')[-1]
                $guest = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
                $mockState.GuestScripts.Add($guest)
                $null = $guest -match "FromBase64String\('([^']+)'\)"
                $request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1])) | ConvertFrom-Json -AsHashtable
                $mockState.NativeInstallRequests.Add($request)
                $result = @{ provisioningState = if ($mockState.GuestFailure) { 'Failed' } else { 'Succeeded' } }
            }
            elseif ($arguments[1] -eq 'run-command') {
                $scriptPath = (Get-TestArgument $arguments '--scripts').Substring(1)
                $mockState.PrivateRequestPaths.Add($scriptPath)
                $guest = Get-Content -LiteralPath $scriptPath -Raw
                $mockState.GuestScripts.Add($guest)
                if ($guest -match "FromBase64String\('([^']+)'\)") {
                    $settings = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1])) | ConvertFrom-Json -AsHashtable
                    $mockState.NativeInstallRequests.Add($settings)
                }
                $sentinel = [regex]::Match($guest, 'BROKER_OK_[0-9a-f]{32}').Value
                if ($mockState.GuestFailure -or ($mockState.GuestWorkloadFailure -and $guest.Contains('BROKER_PROBE'))) {
                    $sentinel = 'Script failed despite HTTP 200.'
                }
                $result = @{ value = @(@{ code = 'ComponentStatus/StdOut/succeeded'; message = $mockState.GuestAdditionalOutput + "`n" + $sentinel }) }
            }
            else { throw 'Unexpected VM CLI operation in test.' }
        }
        default { throw "Live/unsupported Azure command blocked: $($arguments[0])" }
    }
    $format = Get-TestArgument $arguments '--output'
    if ($format -eq 'none') { return }
    if ($format -eq 'tsv') { return [string]$result }
    if ($null -ne $result) { return ConvertTo-Json -InputObject $result -Depth 100 -Compress }
}
function azd {
    $arguments = @($args)
    $mockState = $global:BrokerDeploymentTestState
    if (-not $mockState.ContainsKey('EnvironmentValues')) { throw 'Unexpected azd call: no test environment is configured.' }
    $global:LASTEXITCODE = 0
    $index = [array]::IndexOf($arguments, 'env')
    switch ($arguments[$index + 1]) {
        'get-values' { return ConvertTo-Json -InputObject $mockState.EnvironmentValues -Depth 20 -Compress }
        'set' {
            # PowerShell consumes -- when invoking a function mock; native azd receives it.
            $mockState.EnvironmentValues[$arguments[-2]] = $arguments[-1]
        }
        default { throw 'Unexpected azd operation in offline test.' }
    }
}

$temporary = Join-Path $deployRoot ('.artifacts\tests-' + [guid]::NewGuid().ToString('N'))
$testReceiptPath = $null
$testWorkloadStatePath = $null
$null = New-Item -ItemType Directory -Path $temporary
try {
    foreach ($file in Get-ChildItem -LiteralPath $deployRoot, (Join-Path $repoRoot 'custom_script_extensions') -Filter '*.ps1' -Recurse) {
        $tokens = $null; $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        Assert-True ($parseErrors.Count -eq 0) "PowerShell syntax: $($file.Name)"
    }
    Reset-TestDirectory
    $config = @{
        version = 1; tenantId = $tenant; workspaceUserGroupIds = @($workspaceGroup); workspaceUserIds = @($userId)
        portalAdminGroupIds = @($adminGroup); portalAdminUserIds = @()
    }
    $accessPath = Join-Path $temporary 'access.json'
    $config | ConvertTo-Json | Set-Content -LiteralPath $accessPath
    $config = Read-BrokerAccessConfiguration -Path $accessPath -TenantId $tenant -LegacyMachineGroupIds @($machineGroup)
    $init = @{
        Configuration = $config; GraphEndpoint = 'https://graph.example'; NamePrefix = 'test'
        PortalUrl = 'https://portal.example'; ApiClientId = $apiId; PortalClientId = $portalId
        LauncherClientId = $launcherId; LegacyMachineGroupIds = @($machineGroup)
    }
    $result = Initialize-BrokerApplications @init
    $manifest = $script:state.Apps[$apiObject]
    foreach ($name in @('WorkspaceUser', 'FullAccess', 'LinuxHost', 'ScheduledTask')) {
        $role = @($manifest.appRoles | Where-Object { $_.value -eq $name })[0]
        $expectedType = if ($name -in @('WorkspaceUser', 'FullAccess')) { 'User' } else { 'Application' }
        Assert-True (($role.allowedMemberTypes -join ',') -eq $expectedType -and $role.isEnabled) "$name has one correct member type"
    }
    Assert-True (-not @($manifest.appRoles | Where-Object { $_.value -eq 'AvdHost' })[0].isEnabled) 'Legacy AVD role is disabled'
    Assert-True (@($manifest.appRoles | Where-Object { $_.id -eq $unrelatedRole }).Count -eq 1) 'Unrelated roles preserved'
    Assert-True (@($manifest.api.oauth2PermissionScopes | Where-Object { $_.id -eq $extraScope }).Count -eq 1) 'Unrelated API scope preserved'
    Assert-True (@($manifest.api.preAuthorizedApplications | Where-Object { $_.appId -eq (New-TestId 98) }).Count -eq 1) 'Unrelated preauthorization preserved'
    $idtyp = @($manifest.optionalClaims.accessToken | Where-Object { $_.name -eq 'idtyp' })
    Assert-True ($idtyp.Count -eq 1 -and $null -eq $idtyp[0].source) 'API requests the standard workload idtyp access-token claim'
    Assert-True (@($manifest.optionalClaims.accessToken | Where-Object { $_.name -eq 'ipaddr' -and $_.essential }).Count -eq 1) 'Unrelated access-token optional claims preserved'
    Assert-True ($manifest.optionalClaims.idToken[0].name -eq 'auth_time' -and
        $manifest.optionalClaims.saml2Token[0].additionalProperties[0] -eq 'emit_as_roles') 'ID-token and SAML optional claims preserved'
    $nativeGrant = @($manifest.api.preAuthorizedApplications | Where-Object { $_.appId -eq $launcherId })[0]
    Assert-True (($nativeGrant.delegatedPermissionIds -join ',') -eq $result.ScopeIds.connect_as_user) 'Launcher is preauthorized only for connect scope'
    $portalGrant = @($manifest.api.preAuthorizedApplications | Where-Object { $_.appId -eq $portalId })[0]
    Assert-True (($portalGrant.delegatedPermissionIds -join ',') -eq $result.ScopeIds.access_as_user) 'Portal is preauthorized only for management scope'
    Assert-True $script:state.Principals[$portalObject].appRoleAssignmentRequired 'Portal requires assignment'
    Assert-True (@($script:state.Assignments[$portalObject] | Where-Object { $_.principalId -ne $adminGroup }).Count -eq 0) 'Only configured admins can enter the portal'
    Assert-True (@($script:state.Assignments[$apiObject] | Where-Object { $_.principalId -eq $userId -and $_.appRoleId -eq $result.RoleIds.WorkspaceUser }).Count -eq 1) 'Reviewed direct legacy user migrated before removal'
    $grantIndex = -1; $removeIndex = -1
    for ($i = 0; $i -lt $script:state.GraphMutations.Count; $i++) {
        $mutation = $script:state.GraphMutations[$i]
        if ($mutation.Method -eq 'POST' -and $mutation.Body.principalId -eq $userId -and $mutation.Body.appRoleId -eq $result.RoleIds.WorkspaceUser) { $grantIndex = $i }
        if ($mutation.Method -eq 'DELETE' -and $mutation.Path.EndsWith('/legacy-user')) { $removeIndex = $i }
    }
    Assert-True ($grantIndex -ge 0 -and $removeIndex -gt $grantIndex) 'Replacement entitlement is granted before removing a direct legacy user assignment'
    Assert-True ($script:state.GraphGrants.Count -eq 1 -and $script:state.GraphGrants[0].id -eq 'keep-other') 'Only obsolete runtime directory app grants revoked'
    Assert-True $script:state.Apps[$launcherObject].isFallbackPublicClient 'Launcher is public'
    Assert-True ($script:state.Apps[$launcherObject].publicClient.redirectUris -contains "ms-appx-web://microsoft.aad.brokerplugin/$launcherId") 'Exact WAM redirect configured'
    Assert-True ($script:state.Apps[$portalObject].web.redirectUris -contains 'https://keep.example/callback') 'Existing portal redirects preserved'
    $assignmentCount = $script:state.Assignments[$apiObject].Count
    $null = Initialize-BrokerApplications @init
    Assert-True ($script:state.Assignments[$apiObject].Count -eq $assignmentCount) 'Application/assignment updates rerun without duplicate grants'
    Assert-True (@($script:state.Apps[$apiObject].optionalClaims.accessToken | Where-Object { $_.name -eq 'idtyp' }).Count -eq 1) 'Workload idtyp claim is not duplicated on rerun'
    $priorReadbacks = $script:state.IdtypReadbacks
    $script:state.IdtypReadbackLag = 1
    Wait-BrokerWorkloadOptionalClaim -GraphEndpoint 'https://graph.example' -ApplicationObjectId $apiObject -MaxAttempts 2 -RetrySeconds 0
    Assert-True ($script:state.IdtypReadbacks -eq $priorReadbacks + 2) 'Delayed manifest propagation is read back and confirmed, not assumed from PATCH success'
    $script:state.IdtypReadbackLag = 2
    Assert-Throws {
        Wait-BrokerWorkloadOptionalClaim -GraphEndpoint 'https://graph.example' -ApplicationObjectId $apiObject -MaxAttempts 2 -RetrySeconds 0
    } 'Keep workloads disabled'
    $script:state.IdtypReadbackLag = 0
    foreach ($role in $script:state.Apps[$apiObject].appRoles) {
        if ($role.value -eq 'LinuxHost') { $role.isEnabled = $false }
    }
    $script:state.Principals[$apiObject].appRoles = Copy-TestObject $script:state.Apps[$apiObject].appRoles
    $null = Initialize-BrokerApplications @init
    Assert-True (@($script:state.Apps[$apiObject].appRoles | Where-Object { $_.value -eq 'LinuxHost' })[0].isEnabled) 'Interrupted disabled-role transition recovers on rerun'
    . "$deployRoot\Assign-ServicePrincipalApiRole.ps1" -PrincipalId $miId -ApiClientId $apiId -RoleValue LinuxHost -GraphEndpoint 'https://graph.example'
    . "$deployRoot\Assign-ServicePrincipalApiRole.ps1" -PrincipalId $miId -ApiClientId $apiId -RoleValue LinuxHost -GraphEndpoint 'https://graph.example'
    Assert-True (@($script:state.Assignments[$apiObject] | Where-Object { $_.principalId -eq $miId }).Count -eq 1) 'MI role is direct and rerunnable'
    Reset-TestDirectory
    $script:state.Apps[$apiObject].appRoles = @()
    $script:state.Apps[$apiObject].api.oauth2PermissionScopes = @()
    $script:state.Apps[$apiObject].requiredResourceAccess = @()
    $script:state.Principals[$apiObject].appRoles = @()
    $script:state.Assignments[$apiObject] = @()
    $null = Initialize-BrokerApplications @init
    Assert-True ($script:state.Apps[$apiObject].appRoles.Count -eq 4) 'Fresh API registration gets exactly the four supported roles'
    Reset-TestDirectory
    $script:state.Assignments[$apiObject][0].principalId = $unselectedUser
    Assert-Throws { Initialize-BrokerApplications @init } 'explicit reviewed' 'Unreviewed legacy direct user is not silently dropped'
    Assert-True (@($script:state.Calls | Where-Object { (Get-TestArgument $_ '--method') -eq 'DELETE' }).Count -eq 0) 'Unreviewed legacy migration did not delete grants'
    Reset-TestDirectory
    $script:state.Members[$workspaceGroup] = @(@{ id = $miId; '@odata.type' = '#microsoft.graph.servicePrincipal' })
    Assert-Throws { Test-BrokerAccessPrincipals -Configuration $config -GraphEndpoint 'https://graph.example' } 'workload identities'
    Reset-TestDirectory
    $script:state.Apps[$launcherObject].passwordCredentials = @(@{ keyId = (New-TestId 88) })
    Assert-Throws { Initialize-BrokerApplications @init } 'must not have client secrets'
    Reset-TestDirectory
    $script:state.FailNextCli = $true
    $failure = $null
    try { $null = Invoke-BrokerAz -Arguments @('account', 'show') -Operation 'Offline boundary' } catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'exit 17' -and $failure -notmatch 'SYNTHETIC_SECRET') 'CLI failures stop execution without logging secret-bearing output'
    $pages = @(Get-BrokerGraphCollection -Uri 'https://graph.example/v1.0/paged')
    Assert-True ($pages.Count -eq 2) 'App-role/Graph collection pagination is consumed'
    $script:state.InvalidNextPage = $true
    Assert-Throws { Get-BrokerGraphCollection -Uri 'https://graph.example/v1.0/paged' } 'pagination'
    $script:state.InvalidNextPage = $false
    $script:state.EnvironmentValues = @{
        tenantId = $tenant; APP_NAME = 'testapp'; frontendAppName = 'existing-portal'; resourceGroupName = 'test'; apiAppName = 'api'
        frontendUrl = 'https://keep.example'; API_CLIENT_ID = $apiId; FRONTEND_CLIENT_ID = $portalId
        BROKER_LAUNCHER_CLIENT_ID = $launcherId; FRONTEND_CLIENT_SECRET = '-synthetic-existing-secret'
        brokerAccessConfigPath = $accessPath; linuxHostGroupId = $machineGroup
    }
    . "$deployRoot\Initialize-DeploymentEnvironment.ps1" -EnvironmentName testenv -IdentityOnly
    Assert-True ($script:state.EnvironmentValues['apiClientId'] -eq $apiId -and
        $script:state.EnvironmentValues['brokerLauncherClientId'] -eq $launcherId) 'Identity bootstrap preserves uppercase existing client aliases'
    Assert-True ($script:state.EnvironmentValues['frontendClientSecret'] -eq '-synthetic-existing-secret') 'Existing portal secret, including a leading dash, is reused without logging/resetting it'
    Assert-True ($script:state.EnvironmentValues['BROKER_CHECKOUT_ENABLED'] -eq 'false') 'Identity-only migration cannot accidentally enable checkout'
    Assert-True ($script:state.EnvironmentValues['sqlRuntimeLogin'] -eq 'brokerapi' -and
        $script:state.EnvironmentValues['sqlRuntimePassword'].Length -ge 16) 'Existing migration seeds a separate durable API SQL runtime identity'
    $script:state.ApiStopped = $false
    Assert-Throws { . "$deployRoot\Initialize-DeploymentEnvironment.ps1" -EnvironmentName testenv -IdentityOnly } 'Stop the API'
    $script:state.ApiStopped = $true

    $mappingPath = Join-Path $temporary 'mapping.json'
    $mapping = @{ version = 1; tenantId = $tenant; users = @(@{ objectId = $userId; expectedUserPrincipalName = 'reviewed.user@example.org'; username = 'original_profile'; uid = 10001 }) }
    $mapping | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mappingPath
    $reviewed = Read-BrokerUserMapping -Path $mappingPath -TenantId $tenant
    Test-BrokerUserMapping -Mapping $reviewed -GraphEndpoint 'https://graph.example'
    Assert-True ($reviewed.users[0].username -eq 'original_profile' -and $reviewed.users[0].uid -eq 10001) 'Reviewed profile name and UID preserved'
    Assert-BrokerLinuxIdentity -Username ExistingProfile -Uid 2000
    Assert-Throws { Assert-BrokerLinuxIdentity -Username validname -Uid 1999 } 'UID'
    foreach ($mutation in @(
            { param($m) $m.users += Copy-TestObject $m.users[0] },
            { param($m) $m.users[0].username = 'root' },
            { param($m) $m.users[0].username = 'existing.profile' },
            { param($m) $m.users[0].username = "alice'; touch bad" },
            { param($m) $m.users[0].uid = '10001' },
            { param($m) $m.users[0].objectId = [guid]::Empty.ToString() },
            { param($m) $m.tenantId = New-TestId 55 })) {
        $bad = Copy-TestObject $mapping
        & $mutation $bad
        $bad | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mappingPath
        Assert-Throws { Read-BrokerUserMapping -Path $mappingPath -TenantId $tenant } '.' 'Invalid/duplicate mapping rejected'
    }
    $script:state.Users[$userId].userPrincipalName = 'different.user@example.org'
    Assert-Throws { Test-BrokerUserMapping -Mapping $reviewed -GraphEndpoint 'https://graph.example' } 'Graph verification failed'
    $script:state.Users[$userId].userPrincipalName = 'reviewed.user@example.org'
    $originalSqlProcedure = (Get-Command Invoke-BrokerSqlProcedure).ScriptBlock
    $script:bindingStore = @{}
    $script:bindingCalls = [Collections.Generic.List[object]]::new()
    $script:bindingCommits = 0
    $script:bindingRollbacks = 0
    $fakeConnection = [pscustomobject]@{}
    $fakeConnection | Add-Member -MemberType ScriptMethod -Name BeginTransaction -Value {
        $transaction = [pscustomobject]@{ Connection = $this; Before = (Copy-TestObject $script:bindingStore) }
        $transaction | Add-Member -MemberType ScriptMethod -Name Commit -Value { $script:bindingCommits++; $this.Connection = $null }
        $transaction | Add-Member -MemberType ScriptMethod -Name Rollback -Value {
            $script:bindingRollbacks++
            $script:bindingStore = Copy-TestObject $this.Before
            $this.Connection = $null
        }
        $transaction | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
        return $transaction
    }
    function Invoke-BrokerSqlProcedure {
        param($Connection, $Name, $Parameters, $Transaction)
        if ($Name -ne 'BindBrokerUser' -or $Parameters.Count -ne 4 -or -not $Transaction) { throw 'Invalid SQL binding interface.' }
        $script:bindingCalls.Add((Copy-TestObject $Parameters))
        $key = "$($Parameters.TenantId)|$($Parameters.ObjectId)"
        if ($script:bindingStore.ContainsKey($key)) {
            $prior = $script:bindingStore[$key]
            if ($prior.Username -cne $Parameters.Username -or $prior.Uid -ne $Parameters.Uid) { throw 'Immutable binding conflict.' }
        }
        $script:bindingStore[$key] = Copy-TestObject $Parameters
    }
    try {
        Invoke-BrokerUserMapping -Connection $fakeConnection -Mapping $reviewed
        Invoke-BrokerUserMapping -Connection $fakeConnection -Mapping $reviewed
        Assert-True ($script:bindingCommits -eq 2 -and $script:bindingStore.Count -eq 1) 'Rerun sends the same immutable binding rather than reallocating a profile'
        $dryMapping = Copy-TestObject $reviewed
        $dryMapping.users[0].objectId = $unselectedUser
        $dryMapping.users[0].username = 'second_profile'
        $dryMapping.users[0].uid = 10002
        Invoke-BrokerUserMapping -Connection $fakeConnection -Mapping $dryMapping -DryRun
        Assert-True ($script:bindingStore.Count -eq 1 -and $script:bindingRollbacks -eq 1) 'Mapping dry-run rolls back all writes'
        $conflict = Copy-TestObject $reviewed
        $conflict.users = @($dryMapping.users[0]) + @($conflict.users[0])
        $conflict.users[1].uid = 10003
        Assert-Throws { Invoke-BrokerUserMapping -Connection $fakeConnection -Mapping $conflict } 'Immutable binding conflict'
        Assert-True ($script:bindingStore.Count -eq 1 -and $script:bindingRollbacks -eq 2) 'A later SQL conflict rolls back earlier bindings in the same mapping'
    }
    finally { Set-Item -Path Function:\Invoke-BrokerSqlProcedure -Value $originalSqlProcedure }
    $lease = @{ Username = 'original_profile'; Uid = 10001; LeaseId = New-TestId 60; LeaseGeneration = 2L }
    Assert-BrokerMigrationInventory -Hosts @(@{ Name = 'linux-01' }) -DatabaseHostnames @('linux-01')
    Assert-Throws { Assert-BrokerMigrationInventory -Hosts @() -DatabaseHostnames @('unresolved-active-host') } 'cannot be silently skipped'
    $null = Test-BrokerMigrationLease -Rows @($lease) -Hostname 'linux-01'
    Assert-Throws { Test-BrokerMigrationLease -Rows @($lease, $lease) -Hostname 'linux-01' } 'more than one'
    $badLease = Copy-TestObject $lease; $badLease.LeaseGeneration = 0
    Assert-Throws { Test-BrokerMigrationLease -Rows @($badLease) -Hostname 'linux-01' } 'generation'
    $aboveInt32Lease = Copy-TestObject $lease; $aboveInt32Lease.LeaseGeneration = 2147483648L
    $aboveInt32Result = Test-BrokerMigrationLease -Rows @($aboveInt32Lease) -Hostname 'linux-01'
    Assert-True ($aboveInt32Result.LeaseGeneration -eq 2147483648L) 'The Int64 launcher contract permits an unchanged generation above Int32'
    $maximumLease = Copy-TestObject $lease; $maximumLease.LeaseGeneration = 9007199254740991L
    $maximumResult = Test-BrokerMigrationLease -Rows @($maximumLease) -Hostname 'linux-01'
    Assert-True ($maximumResult.LeaseGeneration -eq 9007199254740991L) 'Shared SQL/JSON maximum generation is preserved exactly in Int64'
    $maximumLease.LeaseGeneration++
    Assert-Throws { Test-BrokerMigrationLease -Rows @($maximumLease) -Hostname 'linux-01' } '1\.\.9007199254740991'
    foreach ($invalidGeneration in @([long]::MaxValue, -1L, '9007199254740991', 1.5, $true)) {
        $invalidLease = Copy-TestObject $lease
        $invalidLease.LeaseGeneration = $invalidGeneration
        Assert-Throws { Test-BrokerMigrationLease -Rows @($invalidLease) -Hostname 'linux-01' } 'shared SQL/JSON range'
    }
    $script = New-BrokerAgentInstallScript -ApiBaseUrl 'https://broker.example/api' -ApiClientId $apiId -Hostname linux-01 -AdminUsername avdadmin -SourceRoot $repoRoot -Lease $lease
    Assert-True ($script.Contains("/usr/local/bin/manage-lease.sh migrate 'original_profile' '10001' '$($lease.LeaseId)' '2'")) 'Exact trusted root-marker migration interface'
    Assert-True ($script.Contains('Unknown, stale, or untrusted lease marker') -and
        -not $script.Contains('The bound active lease is missing its root marker')) 'Conflicting markers fail closed; approved active mappings can migrate an unmarked legacy account through the guarded helper'
    Assert-True ($script.Contains('A live session has no matching reviewed SQL lease') -and $script.Contains('Guest hostname does not match')) 'Unknown live sessions and hostname drift block activation'
    Assert-True ($script -notmatch '(?m)^\s*(?:sudo\s+)?pkill\b|userdel\s+-r\b|terminate_session_processes') 'Deployment never kills desktops or recursively removes profiles'
    Assert-True ($script -notmatch 'NOPASSWD:.*(?:userdel|chpasswd|mount|chmod)') 'Only root-validated helper commands receive sudo permission'
    Assert-True ($script.Contains("install_script 'broker-lease.py'") -and $script.Contains("install_script 'release-session-common.sh'")) 'Migration installs both required shared helper implementations'
    Assert-True ($script.Contains('ensure_command ss "$iproute_package"') -and
        $script.Contains('for binary in ps pgrep pkill') -and
        $script.Contains('for binary in useradd usermod userdel groupadd chpasswd')) 'Existing migration ensures the confirmed process, network, and account tools'
    Assert-True ($script.Contains('ensure_command mount.nfs "$nfs_package"') -and
        $script.Contains('nfs_package=nfs-common') -and $script.Contains('nfs_package=nfs-utils')) 'Existing migrations ensure the distro-specific NFS mount helper'
    Assert-True ($script -match 'manage-lease\.sh cleanup \*' -and $script -notmatch 'NOPASSWD:.*manage-lease\.sh,') 'Deployment-only marker migration is not granted to the runtime SSH account'
    Assert-True ($script.Contains('/usr/local/bin/create-user.sh *') -and
        $script.Contains('/usr/local/bin/apply-host-settings.sh ""')) 'Runtime settings helper is explicitly restricted to no argv in sudoers'
    foreach ($name in @('create-user.sh', 'manage-lease.sh')) {
        $wrapper = Get-Content -LiteralPath (Join-Path $repoRoot "linux_host\$name") -Raw
        Assert-True ($wrapper.Contains('BROKER_PYTHON="/usr/local/libexec/linuxbroker/python3"') -and
            $wrapper.Contains('exec "$BROKER_PYTHON" -I')) "The deployed interpreter must be exactly the one selected by $name"
    }
    Assert-Throws {
        New-BrokerAgentInstallScript -ApiBaseUrl 'https://broker.example/api' -ApiClientId $apiId -Hostname linux-01 `
            -AdminUsername avdadmin -SourceRoot $repoRoot
    } 'trusted SQL identity/fence evidence'
    $idleScript = New-BrokerAgentInstallScript -ApiBaseUrl 'https://broker.example/api' -ApiClientId $apiId -Hostname linux-01 `
        -AdminUsername avdadmin -SourceRoot $repoRoot -IdleEvidence @{ kind = 'absent' }
    Assert-True ($idleScript.Contains('BROKER_IDLE_PROBE') -and -not $idleScript.Contains('manage-lease.sh observe')) 'Idle migration verifies SQL-backed evidence, not the ambiguous observe/no-live-lease result'
    Assert-True ($idleScript.Contains('for marker in "$lease_directory"/*.lease') -and
        -not $idleScript.Contains('for marker in "$state_directory"/*')) 'Locks, settings and warnings are not misclassified as lease markers'
    $shellPath = Join-Path $temporary 'migration.sh'
    [IO.File]::WriteAllText($shellPath, $script.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    & bash -n ($shellPath.Replace('\', '/'))
    Assert-True ($LASTEXITCODE -eq 0) 'Generated Linux migration has valid Bash syntax'

    $tokens = $null; $errors = $null
    $agentAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $deployRoot 'Broker.LinuxMigration.ps1'), [ref]$tokens, [ref]$errors)
    foreach ($definition in $agentAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Convert-AgentContent', 'Get-AgentInstallLine')
    }, $true)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $ApiBaseUrl = 'https://broker.example/api'
    $ApiClientId = $apiId
    $crlfSource = "#!/bin/bash`r`nprintf '%s\n' 'YOUR_LINUX_BROKER_API_BASE_URL' 'YOUR_LINUX_BROKER_API_CLIENT_ID'`r`n"
    $crlfPath = Join-Path $temporary 'crlf-source.sh'
    [IO.File]::WriteAllText($crlfPath, $crlfSource, [Text.UTF8Encoding]::new($false))
    $installLine = Get-AgentInstallLine -Path $crlfPath -Name 'crlf-source.sh'
    $payloadMatch = [regex]::Match($installLine, "^install_script 'crlf-source\.sh' '([a-f0-9]{64})' '([A-Za-z0-9+/=]+)'$")
    Assert-True $payloadMatch.Success 'CRLF source uses the same pinned agent-install interface'
    $payloadBytes = [Convert]::FromBase64String($payloadMatch.Groups[2].Value)
    $payloadText = [Text.Encoding]::UTF8.GetString($payloadBytes)
    $expectedText = $crlfSource.Replace("`r`n", "`n").Replace('YOUR_LINUX_BROKER_API_BASE_URL', $ApiBaseUrl).
        Replace('YOUR_LINUX_BROKER_API_CLIENT_ID', $ApiClientId)
    Assert-True ($payloadText -ceq $expectedText -and -not $payloadText.Contains("`r")) 'The installed payload has LF-only shebang/content even from an existing CRLF checkout'
    $payloadDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($payloadBytes)).ToLowerInvariant()
    Assert-True ($payloadDigest -ceq $payloadMatch.Groups[1].Value) 'Agent SHA256 covers the exact normalized and substituted bytes carried in base64'
    $normalizedPath = Join-Path $temporary 'normalized-source.sh'
    [IO.File]::WriteAllBytes($normalizedPath, $payloadBytes)
    & bash -n ($normalizedPath.Replace('\', '/'))
    Assert-True ($LASTEXITCODE -eq 0) 'Normalized CRLF-checkout payload remains valid executable Bash'

    $installerPath = Join-Path $repoRoot 'custom_script_extensions\Configure-AVD-Host.ps1'
    $tokens = $null; $errors = $null
    $installerAst = [Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$errors)
    foreach ($definition in $installerAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $aclPath = Join-Path $temporary 'acl-check.txt'
    Set-Content -LiteralPath $aclPath -Value 'offline'
    $script:checkedAcl = $null
    function Set-Acl { param($LiteralPath, $AclObject) $script:checkedAcl = $AclObject }
    try {
        Set-LauncherAcl $aclPath
        $rules = @($script:checkedAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        Assert-True ($script:checkedAcl.AreAccessRulesProtected -and $rules.Count -eq 3) 'Installer removes inherited write permissions'
        $usersRule = @($rules | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-32-545' })[0]
        Assert-True (($usersRule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write) -eq 0) 'Ordinary Windows users cannot modify binaries or configuration'
        $configDirectory = Join-Path $temporary 'config'
        $null = New-Item -ItemType Directory -Path $configDirectory
        $nativeConfiguration = @{ tenantId = $tenant; authorityHost = 'https://login.example'; clientId = $launcherId; apiClientId = $apiId; apiBaseUrl = 'https://broker.example/api' }
        Write-LauncherConfiguration -Directory $configDirectory -Configuration $nativeConfiguration
        Write-LauncherConfiguration -Directory $configDirectory -Configuration $nativeConfiguration
        $installedConfiguration = Get-Content -LiteralPath (Join-Path $configDirectory 'launcher.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($installedConfiguration.Count -eq 5 -and $installedConfiguration.clientId -eq $launcherId) 'Idempotent config writer emits the exact five-field frozen contract'
    }
    finally { Remove-Item -Path Function:\Set-Acl }
    Assert-Throws { Assert-LauncherUrl 'http://broker.example/api' -Api } 'Invalid'
    Assert-Throws { Assert-LauncherUrl 'https://broker.example' -Api } 'Invalid'
    Assert-Throws { Assert-LauncherUrl 'https://user:password@broker.example/api' -Api } 'Invalid'
    Assert-Throws { Assert-LauncherUrl 'https://login.example/tenant' -Authority } 'Invalid'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    function New-TestZip {
        param([string]$Path, [string[]]$ExtraEntries = @())
        $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($name in @(
                    'Connect-LinuxBroker.ps1', 'LinuxBroker.Launcher.exe', 'LinuxBroker.Launcher.dll',
                    'LinuxBroker.Launcher.deps.json', 'LinuxBroker.Launcher.runtimeconfig.json',
                    'Microsoft.Identity.Client.dll', 'Microsoft.Identity.Client.Broker.dll',
                    'Microsoft.Identity.Client.NativeInterop.dll', 'coreclr.dll', 'System.Windows.Forms.dll',
                    'runtimes/win-x64/native/msalruntime.dll') + $ExtraEntries) {
                $entry = $archive.CreateEntry($name)
                $writer = [IO.StreamWriter]::new($entry.Open())
                try {
                    $text = if ($name -eq 'LinuxBroker.Launcher.runtimeconfig.json') {
                        '{"runtimeOptions":{"includedFrameworks":[{"name":"Microsoft.WindowsDesktop.App","version":"8.0.0"}]}}'
                    } else { 'offline fixture' }
                    $writer.Write($text)
                } finally { $writer.Dispose() }
            }
        } finally { $archive.Dispose() }
    }
    $zipPath = Join-Path $temporary 'launcher.zip'
    New-TestZip $zipPath
    $digest = (Get-FileHash -LiteralPath $zipPath).Hash
    Test-LauncherArchive -Path $zipPath -Sha256 $digest
    Assert-Throws { Test-LauncherArchive -Path $zipPath -Sha256 ('0' * 64) } 'SHA256 mismatch'
    foreach ($unsafe in @('../escape.ps1', '/rooted.exe', 'C:\absolute.exe', 'dir/../escape.exe', 'NUL.txt', 'file.', 'LinuxBroker.Launcher.EXE')) {
        $badZip = Join-Path $temporary ([guid]::NewGuid().ToString('N') + '.zip')
        New-TestZip -Path $badZip -ExtraEntries @($unsafe)
        Assert-Throws { Test-LauncherArchive -Path $badZip -Sha256 (Get-FileHash -LiteralPath $badZip).Hash } 'Unsafe|Duplicate' 'Zip-slip/Windows alias rejected'
    }
    $artifact = Publish-BrokerLauncherArtifact -Version '1.2.3' -PackagePath $zipPath -StorageAccountName 'offlineartifacts'
    Assert-True ($artifact.Sha256 -ieq $digest) 'Published artifact digest equals actual bytes'
    Assert-True (@($script:state.Calls | Where-Object { $_ -contains 'generate-sas' }).Count -eq 0) 'Private artifacts never require a SAS credential'
    Assert-True (@($script:state.Calls | Where-Object { $_ -contains 'list-keys' -or $_ -contains '--account-key' }).Count -eq 0) 'No storage account key or public artifact access'
    Assert-Throws { Publish-BrokerLauncherArtifact -Version '1.2.3' -PackageUri 'https://packages.example/bundle.zip' } 'requires its SHA256'
    $avdResource = '/subscriptions/aaaaaaaa-aaaa-4aaa-8aaa-000000000100/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/avd-01'
    $script:state.Vms[$avdResource] = @{
        id = $avdResource; name = 'avd-01'; tags = @{}
        identity = @{ principalId = $miId; tenantId = $tenant }
        storageProfile = @{ osDisk = @{ osType = 'Windows' } }
    }
    $script:state.SessionHosts = @(@{ properties = @{ resourceId = $avdResource } })
    $avdInventory = @(Get-BrokerAvdInventory -ResourceGroupName 'test' -HostPoolName 'pool')
    Assert-True ($avdInventory.Count -eq 1) 'Existing untagged AVD host discovered through trusted host-pool inventory'
    Install-BrokerLauncherOnHost -HostRecord $avdInventory[0] -Artifact $artifact -Configuration @{
        tenantId = $tenant; authorityHost = 'https://login.microsoftonline.us'; clientId = $launcherId
        apiClientId = $apiId; apiBaseUrl = 'https://broker.example/api'
    }
    $request = $script:state.NativeInstallRequests[0]
    Assert-True ($request.AuthorityHost -eq 'https://login.microsoftonline.us' -and $request.LauncherClientId -eq $launcherId -and $request.ApiClientId -eq $apiId) 'Native cloud, launcher client, and API audience propagate separately'
    Assert-True ($request.PackageSha256 -ieq $digest) 'Installer receives pinned SHA256'
    Assert-True ($script:state.StorageReaders.Count -eq 1 -and $script:state.StorageReaders[0].scope -like '*/containers/broker-artifacts') 'AVD identity gets only container-scoped artifact RBAC'
    Assert-True ($script:state.NativeExtensions[0].ContainsKey('managedIdentity') -and $request.ContainsKey('PackagePath') -and -not $request.ContainsKey('PackageUri')) 'CSE downloads private blobs with its own identity, not a token-bearing script argument'
    Assert-True ($script:state.GuestScripts[-1].Contains($artifact.InstallerSha256)) 'Downloaded installer itself is SHA256-pinned before execution'
    Install-BrokerLauncherOnHost -HostRecord $avdInventory[0] -Artifact $artifact -Configuration @{
        tenantId = $tenant; authorityHost = 'https://login.microsoftonline.us'; clientId = $launcherId
        apiClientId = $apiId; apiBaseUrl = 'https://broker.example/api'
    }
    Assert-True ($script:state.StorageReaders.Count -eq 1) 'Private artifact reader assignment is rerunnable'
    Assert-Throws { Publish-BrokerLauncherArtifact -Version '1.2.3' -PackageUri 'https://packages.example/bundle.zip?sig=secret' -PackageSha256 $digest } 'Expected an HTTPS URL'
    $script:state.GuestFailure = $true
    Assert-Throws { Invoke-BrokerVmScript -ResourceId $avdResource -CommandId RunPowerShellScript -Script "'noop'" -Operation 'Offline guest failure' } 'verified guest completion'
    Assert-True (@($script:state.PrivateRequestPaths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) 'Private request files are cleaned up'
    $script:state.GuestFailure = $false

    $testEnvironment = 'test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $testReceiptPath = Get-BrokerRolloutReceiptPath $testEnvironment
    $script:state.EnvironmentValues = @{
        resourceGroupName = 'test'; apiAppName = 'api'; frontendAppName = 'portal'; taskAppName = 'task'
        tenantId = $tenant; apiClientId = $apiId; frontendClientId = $portalId; brokerLauncherClientId = $launcherId
        azureAuthorityHost = 'https://login.microsoftonline.com'; avdHostPoolName = 'pool'
        sqlRuntimeLogin = 'brokerapi'
        apiUrl = 'https://broker.example/api'
    }
    $script:state.AppImages = @{ api = 'DOCKER|registry.example/api:legacy'; portal = 'DOCKER|registry.example/frontend:secure'; task = 'DOCKER|registry.example/task:secure' }
    & "$deployRoot\Set-BrokerCheckoutState.ps1" -EnvironmentName $testEnvironment -State Paused
    Assert-True ($script:state.StoppedApps -contains 'api' -and $script:state.StoppedApps -contains 'task') 'Pausing an unverified legacy API stops binaries that ignore the new flag'
    Assert-Throws { & "$deployRoot\Set-BrokerCheckoutState.ps1" -EnvironmentName $testEnvironment -State Enabled -SecuredRolloutValidated } 'never enable a legacy API'
    $script:state.AppImages.api = 'DOCKER|registry.example/api:secure'
    $script:state.ApiSettings = @{
        CLIENT_ID = $apiId; PORTAL_CLIENT_ID = $portalId; BROKER_LAUNCHER_CLIENT_ID = $launcherId
        TENANT_ID = $tenant; AZURE_AUTHORITY_HOST = 'https://login.microsoftonline.com'; BROKER_CHECKOUT_ENABLED = 'false'
        DB_USERNAME = 'brokerapi'; DB_PASSWORD_NAME = 'db-password'
    }
    $linuxResource = $avdResource.Replace('avd-01', 'linux-01')
    $linuxPrincipal = New-TestId 70
    $script:state.Vms[$linuxResource] = @{
        id = $linuxResource; name = 'linux-01'; tags = @{ 'broker-role' = 'linux-host' }; privateIps = '10.0.0.4'
        identity = @{ tenantId = $tenant; principalId = $linuxPrincipal }
        osProfile = @{ computerName = 'linux-01' }; storageProfile = @{ osDisk = @{ osType = 'Linux' } }
    }
    $receipt = @{
        contractVersion = 1; resourceGroupName = 'test'; tenantId = $tenant; apiClientId = $apiId
        frontendClientId = $portalId; brokerLauncherClientId = $launcherId; imageTag = 'secure'
        linuxHostIds = @($linuxResource); linuxHostBindings = @("$linuxResource|$linuxPrincipal"); avdHostIds = @($avdResource)
        workloadsReady = $true; taskPrincipalId = $miId
        runtimeDatabaseVerified = $true; sqlRuntimeLogin = 'brokerapi'
        trustedInventoryBindingVersion = 46
    }
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $testReceiptPath) -Force
    $receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testReceiptPath
    $resumeGuestStart = $script:state.GuestScripts.Count
    & "$deployRoot\Set-BrokerCheckoutState.ps1" -EnvironmentName $testEnvironment -State Enabled -SecuredRolloutValidated
    Assert-True ($script:state.ApiSettings.BROKER_CHECKOUT_ENABLED -eq 'true') 'Only a matching secured rollout enables checkout'
    $resumeScripts = @($script:state.GuestScripts | Select-Object -Skip $resumeGuestStart)
    Assert-True (@($resumeScripts | Where-Object { $_.Contains("set -- 'ready'") -and $_.Contains('gate-status') }).Count -eq 1) 'Resume rechecks the current root gate rather than relying only on an old receipt'
    Assert-True (@($resumeScripts | Where-Object { $_.Contains('BROKER_PROBE') }).Count -eq 1 -and
        $script:state.TaskProbeCalls.Count -eq 1) 'Resume revalidates current Linux registration and scheduled-workload authority through allowed operations'
    $receipt.trustedInventoryBindingVersion = 45
    $receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testReceiptPath
    Assert-Throws { & "$deployRoot\Set-BrokerCheckoutState.ps1" -EnvironmentName $testEnvironment -State Enabled -SecuredRolloutValidated } 'Apply through 046'
    $receipt.trustedInventoryBindingVersion = 46
    $receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testReceiptPath
    $script:state.ApiSettings.BROKER_CHECKOUT_ENABLED = 'false'
    $script:state.GuestFailure = $true
    Assert-Throws { & "$deployRoot\Set-BrokerCheckoutState.ps1" -EnvironmentName $testEnvironment -State Enabled -SecuredRolloutValidated } 'verified guest completion'
    Assert-True ($script:state.ApiSettings.BROKER_CHECKOUT_ENABLED -eq 'false') 'A failed resume-time platform probe leaves checkout paused'
    $script:state.GuestFailure = $false
    $script:state.GuestWorkloadFailure = $true
    Assert-Throws { & "$deployRoot\Set-BrokerCheckoutState.ps1" -EnvironmentName $testEnvironment -State Enabled -SecuredRolloutValidated } 'verified guest completion'
    Assert-True ($script:state.GuestScripts[-1].Contains('BROKER_PROBE') -and
        $script:state.ApiSettings.BROKER_CHECKOUT_ENABLED -eq 'false') 'A revoked SQL host enrollment cannot pass resume merely because its local gate and prior receipt are valid'
    $script:state.GuestWorkloadFailure = $false
    $script:state.Vms[$linuxResource].identity.principalId = New-TestId 71
    Assert-Throws { & "$deployRoot\Set-BrokerCheckoutState.ps1" -EnvironmentName $testEnvironment -State Enabled -SecuredRolloutValidated } 'inventory changed'
    $script:state.Vms[$linuxResource].identity.principalId = $linuxPrincipal
    $script:state.AppImages.portal = 'DOCKER|registry.example/frontend:legacy'
    Assert-Throws { & "$deployRoot\Set-BrokerCheckoutState.ps1" -EnvironmentName $testEnvironment -State Enabled -SecuredRolloutValidated } 'image does not match'

    $disabled = Get-BrokerFunctionDisableSettings
    Assert-True ($disabled.Count -eq 3 -and @($disabled.Values | Where-Object { $_ -ne 'true' }).Count -eq 0) 'All startup timer functions are disabled during staging'
    $taskSource = Get-Content -LiteralPath (Join-Path $repoRoot 'task\function_app.py') -Raw
    $functionNames = @([regex]::Matches($taskSource, '@app\.function_name\(name="([^"]+)"\)') | ForEach-Object { $_.Groups[1].Value })
    foreach ($name in $functionNames) {
        Assert-True ($disabled.ContainsKey("AzureWebJobs.$name.Disabled")) "Every current scheduled function is included in the rollout startup gate: $name"
    }
    $script:state.ApiSettings = @{ 'AzureWebJobs.ScalingVMs.Disabled' = 'true' }
    $activationState = Get-BrokerFunctionActivationState -EnvironmentName $testEnvironment -ResourceGroupName test -TaskAppName task -ExistingEnvironment
    $testWorkloadStatePath = $activationState.Path
    Assert-True ($activationState.Settings['AzureWebJobs.ScalingVMs.Disabled'] -eq 'true' -and
        $activationState.Settings['AzureWebJobs.TestVMConnectivity.Disabled'] -eq 'false') 'An operator-disabled function stays disabled after the staged rollout'
    $script:state.ApiSettings = Get-BrokerFunctionDisableSettings
    $resumedState = Get-BrokerFunctionActivationState -EnvironmentName $testEnvironment -ResourceGroupName test -TaskAppName task -ExistingEnvironment
    Assert-True ($resumedState.Settings['AzureWebJobs.TestVMConnectivity.Disabled'] -eq 'false') 'A failed rollout reuses the original desired state, not its temporary disabled flags'
    $hostProbe = Get-BrokerWorkloadProbeScript -Workload LinuxHost -ApiBaseUrl 'https://broker.example/api' -ApiClientId $apiId
    Assert-True ($hostProbe.StartsWith('/usr/local/libexec/linuxbroker/python3 -I')) 'Host readiness runs in the root-selected broker runtime'
    $taskProbe = Get-BrokerWorkloadProbeScript -Workload ScheduledTask -ApiBaseUrl 'https://broker.example/api' -ApiClientId $apiId
    Assert-True ($taskProbe -notmatch 'az login|az account get-access-token|client_secret') 'Probe does not substitute operator/application-secret authentication'
    $priorTaskProbes = $script:state.TaskProbeCalls.Count
    Test-BrokerTaskWorkloadAccess -ResourceGroupName test -TaskAppName task -ApiBaseUrl 'https://broker.example/api' -ApiClientId $apiId
    Assert-True ($script:state.TaskProbeCalls.Count -eq $priorTaskProbes + 1 -and $script:state.TaskProbeCalls[-1].command.Contains('BROKER_PROBE')) 'Scheduled readiness executes a checked probe in the actual Function App SCM context'
    $script:state.TaskProbeFailure = $true
    Assert-Throws { Test-BrokerTaskWorkloadAccess -ResourceGroupName test -TaskAppName task -ApiBaseUrl 'https://broker.example/api' -ApiClientId $apiId } 'Keep scheduled functions disabled'
    $script:state.TaskProbeFailure = $false
    Test-BrokerLinuxWorkloadAccess -Hosts @(@{ Name = 'linux-01'; ResourceId = $linuxResource }) -ApiBaseUrl 'https://broker.example/api' -ApiClientId $apiId
    Assert-True ($script:state.GuestScripts[-1].Contains('/usr/local/libexec/linuxbroker/python3 -I')) 'Linux readiness executes on the actual registered ARM host'
    $script:state.GuestFailure = $true
    Assert-Throws { Test-BrokerLinuxWorkloadAccess -Hosts @(@{ Name = 'linux-01'; ResourceId = $linuxResource }) -ApiBaseUrl 'https://broker.example/api' -ApiClientId $apiId } 'verified guest completion'
    $script:state.GuestFailure = $false

    $main = Get-Content -LiteralPath (Join-Path $deployRoot 'bicep\main.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    Assert-True ($main.parameters.ContainsKey('brokerLauncherClientId') -and $main.parameters.brokerCheckoutEnabled.defaultValue -eq $false) 'Compiled template carries native client and fail-closed checkout default'
    Assert-True ($main.parameters.ContainsKey('containerImageTag')) 'Fresh provisioning must reference an upcoming secured image tag, never old latest'
    $resourcesModule = @($main.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -eq 'resources' })[0]
    Assert-True ($resourcesModule.properties.parameters.brokerLauncherClientId.value -eq "[parameters('brokerLauncherClientId')]") 'Native client traverses the subscription/resource-group parameter boundary'
    $apiModule = @($resourcesModule.properties.template.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -eq 'apiApp' })[0]
    $apiSettings = $apiModule.properties.parameters.appSettings.value
    $taskModule = @($resourcesModule.properties.template.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -eq 'taskApp' })[0]
    $taskSettings = $taskModule.properties.parameters.appSettings.value
    if ($taskSettings -is [string] -and $taskSettings -match "^\[variables\('([^']+)'\)\]$") {
        $taskSettings = $resourcesModule.properties.template.variables[$Matches[1]]
    }
    foreach ($key in $disabled.Keys) {
        Assert-True ($taskSettings[$key] -eq 'true') "Initial Bicep disables scheduled startup execution: $key"
    }
    foreach ($entry in @{
            CLIENT_ID = "[parameters('apiClientId')]"; PORTAL_CLIENT_ID = "[parameters('frontendClientId')]"
            BROKER_LAUNCHER_CLIENT_ID = "[parameters('brokerLauncherClientId')]"; TENANT_ID = "[parameters('tenantId')]"
            AZURE_AUTHORITY_HOST = "[variables('resolvedAuthorityHost')]"; BROKER_CHECKOUT_ENABLED = "[string(parameters('brokerCheckoutEnabled'))]"
        }.GetEnumerator()) {
        Assert-True ($apiSettings[$entry.Key] -eq $entry.Value) "Compiled API setting propagation: $($entry.Key)"
    }
    Assert-True (-not $apiSettings.ContainsKey('MICROSOFT_PROVIDER_AUTHENTICATION_SECRET') -and -not $apiSettings.ContainsKey('GRAPH_ENDPOINT')) 'API runtime no longer receives directory credentials/settings'
    Assert-True ($apiSettings.DB_USERNAME -eq "[parameters('sqlRuntimeLogin')]") 'API runtime uses its contained SQL user, not sqlAdminLogin'
    Assert-True ($main.parameters.sqlRuntimePassword.type -eq 'securestring') 'Runtime SQL credential is a secure Bicep parameter'
    $vaultModule = @($resourcesModule.properties.template.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -eq 'keyVault' })[0]
    Assert-True ($vaultModule.properties.parameters.sqlRuntimePassword.value -eq "[parameters('sqlRuntimePassword')]" -and
        -not $vaultModule.properties.parameters.ContainsKey('sqlAdminPassword')) 'The API-readable Key Vault receives no deployment-admin SQL password'
    Assert-True ($resourcesModule.properties.parameters.linuxAgentFileHashes.value -eq "[parameters('linuxAgentFileHashes')]") 'Linux artifact hashes cross the subscription/resource-group boundary'
    $linuxModule = @($resourcesModule.properties.template.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -eq 'linuxHosts' })[0]
    Assert-True ($linuxModule.properties.parameters.agentFileHashes.value -eq "[parameters('linuxAgentFileHashes')]") 'All distro deployments receive the approved helper hashes'
    $linuxBicep = Get-Content -LiteralPath (Join-Path $deployRoot 'bicep\modules\Linux\main.bicep') -Raw
    Assert-True ($linuxBicep.Contains('sha256sum --check --status') -and
        $linuxBicep.Contains("'`${verifyCommand} && `${bootstrapEnv} bash")) 'The bootstrap and shared helpers are checksum-verified before any bootstrap code executes'
    $linuxHashes = Get-BrokerLinuxArtifactHashes -SourceRoot $repoRoot
    Assert-True ($linuxHashes.Count -eq 17 -and $linuxHashes.ContainsKey('custom_script_extensions/configure-broker-xrdp-gate.py') -and $linuxHashes.ContainsKey('linux_host/broker-freezer.py') -and $linuxHashes.ContainsKey('custom_script_extensions/check-broker-host-prerequisites.sh') -and $linuxHashes.ContainsKey('custom_script_extensions/install-broker-python.py') -and $linuxHashes.ContainsKey('linux_host/broker-lease.py') -and
        $linuxHashes.ContainsKey('linux_host/session_release_buffer/release-session-common.sh')) 'Approved manifest pins both new helpers and every distro entrypoint'
    $runtimeLock = Get-BrokerPythonRuntimeLock
    $runtimeDefault = $main.parameters.linuxPythonRuntime.defaultValue
    if ($runtimeDefault -is [string] -and $runtimeDefault -match "^\[variables\('([^']+)'\)\]$") { $runtimeDefault = $main.variables[$Matches[1]] }
    Assert-True ($runtimeDefault.sha256 -eq $runtimeLock.sha256) 'Compiled template pins the exact reviewed Linux Python runtime digest'
    Assert-True ($script.Contains('broker_python=/usr/local/libexec/linuxbroker/python3') -and
        $script.Contains('python3 "$runtime_installer" --config-base64') -and
        $script.Contains('sys.version_info >= (3, 6)')) 'Migration bootstraps the selected private modern interpreter with stock Python 3.6'
    $pinnedDirectory = Join-Path $temporary 'pinned-bootstrap'
    $null = New-Item -ItemType Directory -Path $pinnedDirectory
    $checksumLines = @()
    foreach ($relative in @(
            'custom_script_extensions/Configure-RHEL7-Host.sh',
            'custom_script_extensions/install-broker-python.py',
            'custom_script_extensions/check-broker-host-prerequisites.sh',
            'custom_script_extensions/configure-broker-xrdp-gate.py',
            'linux_host/create-user.sh', 'linux_host/manage-lease.sh', 'linux_host/broker-lease.py', 'linux_host/broker-freezer.py',
            'linux_host/apply-host-settings.sh', 'linux_host/session_release_buffer/release-session-common.sh',
            'linux_host/session_release_buffer/RHEL/release-session.sh',
            'linux_host/session_release_buffer/xrdp-who-xorg.sh',
            'linux_host/session_release_buffer/logind-session-watcher.sh')) {
        $name = [IO.Path]::GetFileName($relative.Replace('/', '\'))
        $content = (Get-Content -LiteralPath (Join-Path $repoRoot $relative.Replace('/', '\')) -Raw).Replace("`r`n", "`n")
        [IO.File]::WriteAllText((Join-Path $pinnedDirectory $name), $content, [Text.UTF8Encoding]::new($false))
        $checksumLines += "$($linuxHashes[$relative])  $name"
    }
    [IO.File]::WriteAllText((Join-Path $pinnedDirectory 'SHA256SUMS'), ($checksumLines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    Push-Location $pinnedDirectory
    try {
        & bash -c 'sha256sum --check --status SHA256SUMS'
        Assert-True ($LASTEXITCODE -eq 0) 'Actual staged bootstrap/helper bytes match the generated checksum manifest'
        [IO.File]::AppendAllText((Join-Path $pinnedDirectory 'broker-lease.py'), "`n# modified test fixture`n")
        $gateOutput = & bash -c 'sha256sum --check --status SHA256SUMS && printf BOOTSTRAP_EXECUTED'
        $gateExitCode = $LASTEXITCODE
        Assert-True ($gateExitCode -ne 0 -and ($gateOutput | Out-String) -notmatch 'BOOTSTRAP_EXECUTED') 'An altered shared Python helper blocks bootstrap execution'
    }
    finally { Pop-Location }
    foreach ($private in @('deploy/.azure/prod/.env', 'deploy/broker-user-mapping.json', 'deploy/.artifacts/launcher.zip',
            'deploy/bicep/main.parameters.json', 'api/.env', 'front_end/flask_session/session-id', 'task/local.settings.json')) {
        Assert-True (-not (Test-BrokerContainerSourcePath $private)) "Private/runtime build input excluded: $private"
    }
    $buildContext = Join-Path $temporary 'container-context'
    New-BrokerContainerBuildContext -SourceRoot $repoRoot -Destination $buildContext
    Assert-True ((Test-Path -LiteralPath (Join-Path $buildContext 'api\Dockerfile')) -and
        -not (Test-Path -LiteralPath (Join-Path $buildContext 'deploy'))) 'Real local build snapshot contains application code, not deployment secrets'
    $avdBicep = Get-Content -LiteralPath (Join-Path $deployRoot 'bicep\modules\AVD\main.bicep') -Raw
    Assert-True ($avdBicep -match '(?s)resource vmSessionHost.*?tags: tags') 'AVD VM inventory tags are actually applied'
    Assert-True ($avdBicep -notmatch 'Configure-AVD-Host|CustomScriptExtension') 'Bicep does not install a nonexistent/pre-staging native artifact'
    foreach ($name in @('Configure-RHEL7-Host.sh', 'Configure-RHEL8-Host.sh', 'Configure-RHEL9-Host.sh', 'Configure-Ubuntu24_desktop-Host.sh')) {
        $path = Join-Path $repoRoot "custom_script_extensions\$name"
        $bootstrap = Get-Content -LiteralPath $path -Raw
        Assert-True ($bootstrap.Contains('broker-lease.py') -and $bootstrap.Contains('release-session-common.sh')) "$name installs the Python helper and shared agent"
        Assert-True ($bootstrap.Contains('install -o root -g root -m 0755 "$broker_agent_source/broker-freezer.py"')) "$name includes the new legacy freezer companion in the pinned root-owned install"
        Assert-True ($bootstrap.Contains('LINUXBROKER_LOCAL_AGENT_DIRECTORY:?') -and
            $bootstrap.Contains('install -o root -g root -m 0755 "$broker_agent_source/broker-lease.py"') -and
            $bootstrap.Contains('install -o root -g root -m 0755 "$broker_agent_source/release-session-common.sh"')) "$name requires the verified stage and installs both helpers root-owned"
        Assert-True ($bootstrap.Contains('sudo python3 "$broker_agent_source/install-broker-python.py" --config-base64') -and
            $bootstrap.Contains('LINUXBROKER_PYTHON_RUNTIME_CONFIG:?')) "$name installs the locked private interpreter before any broker helper runs"
        Assert-True ($bootstrap.Contains('check-broker-host-prerequisites.sh" platform') -and
            $bootstrap.Contains('check-broker-host-prerequisites.sh" full')) "$name verifies the freezer platform before installing and XRDP control groups before completing"
        Assert-True ($bootstrap.Contains('configure-broker-xrdp-gate.py" --enroll-drained --admin-username') -and
            $bootstrap.Contains('install -o root -g root -m 0755 "$broker_agent_source/configure-broker-xrdp-gate.py"')) "$name enrolls only verified fresh/drained legacy services through the root startup wrapper"
        Assert-True ($bootstrap -match 'install -y .*python3.*iproute.*procps.*(shadow-utils|passwd)') "$name installs the confirmed helper dependencies"
        Assert-True ($bootstrap -notmatch 'enable --now "\$(SYSTEMD_TIMER_NAME|WATCHER_SERVICE_NAME)"') "$name defers activation until enrollment"
        Assert-True ($bootstrap -notmatch 'cmds=\(userdel|ALL=\(ALL\)|pkill -f') "$name removes legacy broad privilege/process handling"
        Assert-True ($bootstrap.Contains('$create_user_script *, $manage_lease_script cleanup *, $apply_settings_script \"\"')) "$name restricts host settings to stdin-only sudo invocation"
        & bash -n ($path.Replace('\', '/'))
        Assert-True ($LASTEXITCODE -eq 0) "$name Bash syntax"
    }
    $post = Get-Content -LiteralPath (Join-Path $deployRoot 'Post-Provision.ps1') -Raw
    $sequence = @('Test-BrokerHostPrerequisites -', 'Suspend-BrokerApps -', '-Mode Quiesce', 'Initialize-DeploymentEnvironment.ps1"', 'Initialize-Database.ps1"',
        'Initialize-BrokerRuntimeDatabaseUser.ps1"', 'Set-BrokerRuntimeDatabaseSecret -',
        'Bind-BrokerUserMappings.ps1"', 'Register-LinuxHostSqlRecords.ps1"', 'Publish-BrokerLauncherArtifact -', '-Mode Install', 'Install-AvdBrokerLauncher.ps1"', "'Start secured API",
        'Test-BrokerTaskWorkloadAccess -', 'Test-BrokerLinuxWorkloadAccess -', '-Mode Activate')
    $last = -1
    foreach ($step in $sequence) {
        $position = $post.IndexOf($step, [StringComparison]::Ordinal)
        Assert-True ($position -gt $last) "Coordinated cutover ordering: $step"
        $last = $position
    }
    Assert-True ($post -notmatch "BROKER_CHECKOUT_ENABLED\s*=\s*'true'") 'Post-provision never automatically resumes checkouts'
    Assert-True (@($main.parameters.linuxHostOsVersion.allowedValues | Where-Object { $_ -in @('7-LVM', '8-LVM') }).Count -eq 2) 'Original RHEL7/8 targets are retained; no unapproved platform support removal'
    $preflightScript = Get-BrokerHostPrerequisiteScript
    Assert-True ($preflightScript -notmatch '(?m)^\s*(?:sudo\s+)?systemctl\s+(?:freeze|thaw|start|stop|restart|enable|disable)\b') 'Host prerequisite probe has no service-changing command'
    Assert-True ($preflightScript.Contains('cgroup2fs') -and $preflightScript.Contains('FreezerState') -and
        $preflightScript.Contains('cgroup.freeze') -and $preflightScript.Contains('cgroup.events')) 'Preflight verifies actual unified cgroup freezer interfaces and systemd state'
    Assert-True ($preflightScript.Contains('for directory in /usr /usr/local /usr/local/bin') -and
        $preflightScript.Contains('directory_mode & 022')) 'Privileged helper parent directories must be root-controlled without silently changing unrelated permissions'
    Assert-True ($preflightScript.Contains('Legacy v1 freezer platform is available') -and
        $preflightScript.Contains('/usr/local/bin/manage-lease.sh gate-status')) 'Legacy cgroup readiness uses the same core gate, not a weaker systemd-version fallback'
    $activationScript = Get-BrokerAgentActivationScript
    Assert-True ($activationScript.Contains("set -- 'ready'") -and
        $activationScript.IndexOf("set -- 'ready'") -lt $activationScript.IndexOf('systemctl start linuxbroker-release-session.service')) 'Agent activation rechecks the installed core gate before starting any agent service'
    $legacyIdleScript = New-BrokerAgentInstallScript -ApiBaseUrl 'https://broker.example/api' -ApiClientId $apiId -Hostname linux-01 `
        -AdminUsername avdadmin -SourceRoot $repoRoot -IdleEvidence @{ kind = 'absent' } -EnrollDrainedLegacyHosts
    Assert-True ($legacyIdleScript.Contains('configure-broker-xrdp-gate.py --enroll-drained') -and
        $legacyIdleScript.Contains('BROKER_IDLE_PROBE')) 'Explicit legacy enrollment still requires SQL-idle/root-marker verification'
    $legacyActiveScript = New-BrokerAgentInstallScript -ApiBaseUrl 'https://broker.example/api' -ApiClientId $apiId -Hostname linux-01 `
        -AdminUsername avdadmin -SourceRoot $repoRoot -Lease $lease -EnrollDrainedLegacyHosts
    Assert-True (-not $legacyActiveScript.Contains('configure-broker-xrdp-gate.py --enroll-drained')) 'An active mapped lease can never receive permission to restart for first legacy enrollment'
    $migration = Get-Content -LiteralPath (Join-Path $deployRoot 'Migrate-ExistingEnvironment.ps1') -Raw
    Assert-True ($migration.Contains('@PSBoundParameters -ExistingEnvironment') -and $migration.Contains('Post-Provision.ps1')) 'Existing deployments share the fresh guarded pipeline, including AVD installation'
    $stageCallStart = $script:state.Calls.Count
    $assignmentCountBeforeStage = $script:state.Assignments[$apiObject].Count
    . "$deployRoot\Stage-BrokerWorkloadPermissions.ps1" -EnvironmentName $testEnvironment
    $stagedAssignmentCount = $script:state.Assignments[$apiObject].Count
    . "$deployRoot\Stage-BrokerWorkloadPermissions.ps1" -EnvironmentName $testEnvironment
    Assert-True ($stagedAssignmentCount -ge $assignmentCountBeforeStage -and
        $script:state.Assignments[$apiObject].Count -eq $stagedAssignmentCount) 'Early direct workload permission staging is additive and rerunnable'
    $stageCalls = @($script:state.Calls | Select-Object -Skip $stageCallStart)
    Assert-True (@($stageCalls | Where-Object {
        (Get-TestArgument $_ '--method') -eq 'GET' -and (Get-TestArgument $_ '--url') -like '*applications/*optionalClaims*'
    }).Count -eq 2) 'Each early workload staging run reads back the idtyp manifest without minting a token'
    Assert-True (@($stageCalls | Where-Object {
        $_ -contains 'get-access-token' -or $_ -contains 'run-command' -or
        (($_ -contains '--url') -and (Get-TestArgument $_ '--url') -like '*scm*') -or
        (Get-TestArgument $_ '--method') -eq 'DELETE'
    }).Count -eq 0) 'Pre-cutover staging neither mints workload tokens nor executes workloads/removes user assignments'
    $script:state.GuestAdditionalOutput = 'BROKER_IDLE_METADATA={"kind":"cleaned","username":"ExistingProfile","uid":10001,"generation":7,"sha256":"' + ('a' * 64) + '"}'
    $idleObservation = Get-BrokerIdleLeaseObservation -HostRecord @{ Name = 'linux-01'; ResourceId = $linuxResource }
    Assert-True ($idleObservation.kind -eq 'cleaned' -and $idleObservation.generation -eq 7) 'Only bounded protected-marker metadata is collected for trusted SQL verification'
    $script:state.GuestAdditionalOutput = ''
    & (Join-Path $deployRoot 'tests\Test-DatabaseRuntime.ps1')
    & (Join-Path $deployRoot 'tests\Test-IdleLease.ps1')
    & (Join-Path $deployRoot 'tests\Test-HostRegistration.ps1')
    foreach ($testName in @('Test-LegacyGateEnrollment.py', 'Test-HostPrerequisites.py')) {
        & python -B (Join-Path $PSScriptRoot $testName) -q
        if ($LASTEXITCODE -ne 0) { throw "Offline legacy gate coverage failed in '$testName'." }
    }
    Write-Host "PASS: $script:assertions offline deployment assertions. Azure, Graph, and VM boundaries were mocked."
}
finally {
    if ($testReceiptPath -and (Test-Path -LiteralPath $testReceiptPath)) { Remove-Item -LiteralPath $testReceiptPath -Force }
    if ($testWorkloadStatePath -and (Test-Path -LiteralPath $testWorkloadStatePath)) { Remove-Item -LiteralPath $testWorkloadStatePath -Force }
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
