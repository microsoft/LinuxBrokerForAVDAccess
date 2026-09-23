. "$PSScriptRoot\Broker.Deployment.Common.ps1"

$script:BrokerRoleDefaults = @{
    WorkspaceUser = 'e02173e8-3c03-4b4d-a7bc-0a773c28619f'
    FullAccess = '4b2d5f7f-7cc1-4303-8d4b-bd7d2cfe2ca6'
    LinuxHost = '29a8a5a0-2090-4e94-a49d-3386640f0058'
    ScheduledTask = 'd11a6ed0-ee5e-4305-a2a2-252a8107d84f'
}
$script:BrokerScopeDefaults = @{
    access_as_user = '58db6e6d-38d5-4ce2-bf0a-7fd9cfd5f00a'
    connect_as_user = '8a5bdf27-72dc-4dc4-a663-e15a215bf536'
}
$script:BrokerPortalRoleId = '504a58cb-7b02-45a4-9924-e061706a68d9'

function Read-BrokerAccessConfiguration {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TenantId,
        [string[]]$LegacyMachineGroupIds = @()
    )
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    $fields = @('version', 'tenantId', 'workspaceUserGroupIds', 'workspaceUserIds', 'portalAdminGroupIds', 'portalAdminUserIds')
    foreach ($key in $config.Keys) {
        if ($key -notin $fields) { throw "Unknown access configuration field '$key'." }
    }
    if (($config.version -isnot [int] -and $config.version -isnot [long]) -or
        $config.version -ne 1 -or (Assert-BrokerGuid $config.tenantId 'Access tenantId') -ne $TenantId) {
        throw 'Access configuration version or tenant does not match this deployment.'
    }
    foreach ($key in $fields | Where-Object { $_ -like '*Ids' }) {
        if (-not $config.Contains($key) -or $config[$key] -isnot [array]) {
            throw "Access configuration '$key' must be an explicit array of object IDs."
        }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $config[$key] = @(
            foreach ($id in $config[$key]) {
                $id = Assert-BrokerGuid $id $key
                if (-not $seen.Add($id)) { throw "Duplicate principal in '$key'." }
                if ($id -in $LegacyMachineGroupIds) { throw 'VM managed-identity groups cannot be used as user entitlements.' }
                $id
            }
        )
    }
    $groups = @($config.workspaceUserGroupIds) + @($config.portalAdminGroupIds)
    $users = @($config.workspaceUserIds) + @($config.portalAdminUserIds)
    if (@($groups | Where-Object { $_ -in $users }).Count) { throw 'A principal cannot be both a User and a Group.' }
    if (($config.workspaceUserGroupIds.Count + $config.workspaceUserIds.Count) -eq 0) {
        throw 'Select at least one existing AVD user or user group for workspace access.'
    }
    if (($config.portalAdminGroupIds.Count + $config.portalAdminUserIds.Count) -eq 0) {
        throw 'Select at least one administrator user or group. The deployment operator is not assigned automatically.'
    }
    return $config
}

function Test-BrokerAccessPrincipals {
    param([Parameter(Mandatory)][hashtable]$Configuration, [Parameter(Mandatory)][string]$GraphEndpoint)
    Assert-BrokerTenant $Configuration.tenantId
    $users = @($Configuration.workspaceUserIds) + @($Configuration.portalAdminUserIds)
    foreach ($id in $users | Select-Object -Unique) {
        $user = Invoke-BrokerGraph -Method GET -Uri "$GraphEndpoint/v1.0/users/${id}?`$select=id,accountEnabled"
        if ($user.id -ne $id -or $user.accountEnabled -ne $true) { throw "Selected user '$id' is not an enabled tenant user." }
    }
    $groups = @($Configuration.workspaceUserGroupIds) + @($Configuration.portalAdminGroupIds)
    foreach ($id in $groups | Select-Object -Unique) {
        $group = Invoke-BrokerGraph -Method GET -Uri "$GraphEndpoint/v1.0/groups/${id}?`$select=id,securityEnabled"
        if ($group.id -ne $id -or $group.securityEnabled -ne $true) { throw "Selected group '$id' is not a security group." }
        $members = @(Get-BrokerGraphCollection -Uri "$GraphEndpoint/v1.0/groups/$id/transitiveMembers?`$select=id")
        if (@($members | Where-Object { $_['@odata.type'] -eq '#microsoft.graph.servicePrincipal' }).Count) {
            throw "Selected group '$id' contains workload identities. Select the existing AVD user group, not a VM identity group."
        }
        if (@($members | Where-Object { $_['@odata.type'] -eq '#microsoft.graph.group' }).Count) {
            throw "Selected group '$id' contains nested groups. Entra app roles do not inherit nested membership; explicitly select the existing leaf user groups or direct users."
        }
    }
}

function Get-BrokerApplication {
    param([Parameter(Mandatory)][string]$GraphEndpoint, [Parameter(Mandatory)][string]$DisplayName, [string]$ClientId)
    $filter = if ($ClientId) { "appId eq '$(Assert-BrokerGuid $ClientId 'Application client ID')'" }
        else { "displayName eq '$($DisplayName.Replace("'", "''"))'" }
    $matches = @(Get-BrokerGraphCollection -Uri "$GraphEndpoint/v1.0/applications?`$filter=$([uri]::EscapeDataString($filter))")
    if ($matches.Count -gt 1) { throw "Application '$DisplayName' is ambiguous. Configure its existing client ID explicitly." }
    if ($matches.Count -eq 1) { return $matches[0] }
    if ($ClientId) { throw "Configured application '$DisplayName' was not found in this tenant." }
    return Invoke-BrokerGraph -Method POST -Uri "$GraphEndpoint/v1.0/applications" -Body @{
        displayName = $DisplayName
        signInAudience = 'AzureADMyOrg'
    }
}

function Get-BrokerServicePrincipal {
    param([Parameter(Mandatory)][string]$GraphEndpoint, [Parameter(Mandatory)][string]$ClientId, [switch]$Create)
    $ClientId = Assert-BrokerGuid $ClientId 'Application client ID'
    $matches = @(Get-BrokerGraphCollection -Uri "$GraphEndpoint/v1.0/servicePrincipals?`$filter=appId%20eq%20'$ClientId'")
    if ($matches.Count -gt 1) { throw 'Multiple service principals were returned for one client ID.' }
    if ($matches.Count -eq 1) { return $matches[0] }
    if (-not $Create) { throw "Service principal for '$ClientId' was not found." }
    return Invoke-BrokerGraph -Method POST -Uri "$GraphEndpoint/v1.0/servicePrincipals" -Body @{ appId = $ClientId }
}

function ConvertTo-BrokerRolePayload {
    param([Parameter(Mandatory)]$Role)
    $result = @{}
    foreach ($key in @('id', 'value', 'displayName', 'description', 'allowedMemberTypes', 'isEnabled')) {
        $result[$key] = $Role[$key]
    }
    return $result
}

function Get-BrokerWorkloadOptionalClaims {
    param([Parameter(Mandatory)][hashtable]$Application)
    $claims = if ($Application['optionalClaims']) { $Application['optionalClaims'] } else { @{} }
    $claims.accessToken = @($claims['accessToken'] | Where-Object { $_ -and $_.name -ne 'idtyp' }) + @(@{
        name = 'idtyp'; source = $null; essential = $false; additionalProperties = @()
    })
    return $claims
}

function Wait-BrokerWorkloadOptionalClaim {
    param(
        [Parameter(Mandatory)][string]$GraphEndpoint,
        [Parameter(Mandatory)][string]$ApplicationObjectId,
        [ValidateRange(1, 24)][int]$MaxAttempts = 12,
        [ValidateRange(0, 60)][int]$RetrySeconds = 5
    )
    $ApplicationObjectId = Assert-BrokerGuid $ApplicationObjectId 'API application object ID'
    for ($attempt = 0; $attempt -lt $MaxAttempts; $attempt++) {
        $application = Invoke-BrokerGraph -Method GET -Uri "$GraphEndpoint/v1.0/applications/${ApplicationObjectId}?`$select=id,optionalClaims"
        $claims = @()
        if ($application['optionalClaims']) {
            $claims = @($application.optionalClaims['accessToken'] | Where-Object { $_ -and $_.name -eq 'idtyp' })
        }
        if ($application.id -eq $ApplicationObjectId -and $claims.Count -eq 1 -and
            $null -eq $claims[0]['source'] -and $claims[0]['essential'] -eq $false -and
            @($claims[0]['additionalProperties'] | Where-Object { $null -ne $_ }).Count -eq 0) {
            return
        }
        if ($attempt + 1 -lt $MaxAttempts -and $RetrySeconds) { Start-Sleep -Seconds $RetrySeconds }
    }
    throw 'The API idtyp access-token optional claim was not confirmed by Graph readback. Keep workloads disabled and retry after manifest propagation; this readback never substitutes for actual workload API authorization.'
}

function Merge-BrokerRequiredScope {
    param([AllowEmptyCollection()][array]$Resources, [string]$ApiClientId, [string]$ScopeId, [string[]]$RemoveScopeIds = @())
    $found = $false
    @(
        foreach ($resource in $Resources) {
            if ($resource.resourceAppId -ne $ApiClientId) { $resource; continue }
            $found = $true
            $access = @($resource.resourceAccess | Where-Object { $_.id -notin $RemoveScopeIds -and $_.id -ne $ScopeId })
            @{ resourceAppId = $ApiClientId; resourceAccess = @($access) + @(@{ id = $ScopeId; type = 'Scope' }) }
        }
        if (-not $found) {
            @{ resourceAppId = $ApiClientId; resourceAccess = @(@{ id = $ScopeId; type = 'Scope' }) }
        }
    )
}

function Ensure-BrokerAppRoleAssignment {
    param(
        [Parameter(Mandatory)][string]$GraphEndpoint,
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$RoleId
    )
    $assignments = @(Get-BrokerGraphCollection -Uri "$GraphEndpoint/v1.0/servicePrincipals/$ResourceId/appRoleAssignedTo")
    if (@($assignments | Where-Object { $_.principalId -eq $PrincipalId -and $_.appRoleId -eq $RoleId }).Count) { return }
    $null = Invoke-BrokerGraph -Method POST -Uri "$GraphEndpoint/v1.0/servicePrincipals/$ResourceId/appRoleAssignedTo" -Body @{
        principalId = $PrincipalId; resourceId = $ResourceId; appRoleId = $RoleId
    }
}

function Wait-BrokerApplicationRoles {
    param([string]$GraphEndpoint, [string]$ClientId, [string[]]$RoleIds, [hashtable]$ExpectedMemberTypes = @{})
    for ($attempt = 0; $attempt -lt 12; $attempt++) {
        $sp = Get-BrokerServicePrincipal -GraphEndpoint $GraphEndpoint -ClientId $ClientId
        $available = @($sp.appRoles | Where-Object { $_.isEnabled } | ForEach-Object { $_.id })
        $typesMatch = $true
        foreach ($entry in $ExpectedMemberTypes.GetEnumerator()) {
            $role = @($sp.appRoles | Where-Object { $_.id -eq $entry.Key })
            if ($role.Count -ne 1 -or ($role[0].allowedMemberTypes -join ',') -ne $entry.Value) { $typesMatch = $false }
        }
        if (@($RoleIds | Where-Object { $_ -notin $available }).Count -eq 0 -and $typesMatch) { return $sp }
        if ($attempt -lt 11) { Start-Sleep -Seconds 5 }
    }
    throw 'Updated application roles have not propagated to the service principal. Leave checkouts paused and rerun.'
}

function Sync-BrokerUserAssignments {
    param(
        [hashtable]$Configuration, [string]$GraphEndpoint, [hashtable]$ApiServicePrincipal,
        [hashtable]$PortalServicePrincipal, [hashtable]$RoleIds, [string]$PortalRoleId,
        [string[]]$LegacyMachineGroupIds = @()
    )
    $workspace = @($Configuration.workspaceUserIds) + @($Configuration.workspaceUserGroupIds)
    $admins = @($Configuration.portalAdminUserIds) + @($Configuration.portalAdminGroupIds)
    $approved = $workspace + $admins
    $rolesById = @{}
    foreach ($role in $ApiServicePrincipal.appRoles) { $rolesById[$role.id] = $role.value }
    $existing = @(Get-BrokerGraphCollection -Uri "$GraphEndpoint/v1.0/servicePrincipals/$($ApiServicePrincipal.id)/appRoleAssignedTo")

    # Validate the entire legacy transition before removing any entitlement.
    foreach ($assignment in $existing) {
        $roleName = $rolesById[$assignment.appRoleId]
        if ($roleName -in @('WorkspaceUser', 'FullAccess') -and $assignment.principalType -eq 'ServicePrincipal') {
            throw "Workload '$($assignment.principalId)' has a user role. Remove that invalid assignment explicitly before migration."
        }
        if ($roleName -notin @('AvdHost', 'LinuxHost', 'ScheduledTask') -or $assignment.principalType -eq 'ServicePrincipal') { continue }
        if ($assignment.principalId -in $LegacyMachineGroupIds -and $assignment.principalType -eq 'Group') {
            $members = @(Get-BrokerGraphCollection -Uri "$GraphEndpoint/v1.0/groups/$($assignment.principalId)/transitiveMembers?`$select=id")
            if (@($members | Where-Object { $_['@odata.type'] -notin @('#microsoft.graph.servicePrincipal', '#microsoft.graph.group') }).Count) {
                throw "Legacy VM group '$($assignment.principalId)' contains people. Move them to reviewed user entitlements before retiring its role."
            }
        }
        elseif ($assignment.principalId -notin $approved -or $assignment.principalType -notin @('User', 'Group')) {
            throw "Legacy '$roleName' assignment for '$($assignment.principalId)' needs an explicit reviewed workspace/admin selection. No assignment was removed."
        }
    }

    foreach ($id in $workspace) {
        Ensure-BrokerAppRoleAssignment -GraphEndpoint $GraphEndpoint -PrincipalId $id -ResourceId $ApiServicePrincipal.id -RoleId $RoleIds.WorkspaceUser
    }
    foreach ($id in $admins) {
        Ensure-BrokerAppRoleAssignment -GraphEndpoint $GraphEndpoint -PrincipalId $id -ResourceId $ApiServicePrincipal.id -RoleId $RoleIds.FullAccess
        Ensure-BrokerAppRoleAssignment -GraphEndpoint $GraphEndpoint -PrincipalId $id -ResourceId $PortalServicePrincipal.id -RoleId $PortalRoleId
    }
    foreach ($assignment in $existing) {
        $roleName = $rolesById[$assignment.appRoleId]
        $remove = ($roleName -eq 'WorkspaceUser' -and $assignment.principalId -notin $workspace) -or
            ($roleName -eq 'FullAccess' -and $assignment.principalId -notin $admins) -or
            ($roleName -eq 'AvdHost') -or
            ($roleName -in @('LinuxHost', 'ScheduledTask') -and $assignment.principalType -ne 'ServicePrincipal')
        if ($remove) {
            Write-Host "Retiring API '$roleName' assignment for principal '$($assignment.principalId)'."
            $null = Invoke-BrokerGraph -Method DELETE -Uri "$GraphEndpoint/v1.0/servicePrincipals/$($ApiServicePrincipal.id)/appRoleAssignedTo/$($assignment.id)"
        }
    }
    $portalAssignments = @(Get-BrokerGraphCollection -Uri "$GraphEndpoint/v1.0/servicePrincipals/$($PortalServicePrincipal.id)/appRoleAssignedTo")
    foreach ($assignment in $portalAssignments) {
        if ($assignment.principalId -notin $admins -or $assignment.principalType -notin @('User', 'Group')) {
            Write-Host "Retiring unselected portal assignment for principal '$($assignment.principalId)'."
            $null = Invoke-BrokerGraph -Method DELETE -Uri "$GraphEndpoint/v1.0/servicePrincipals/$($PortalServicePrincipal.id)/appRoleAssignedTo/$($assignment.id)"
        }
    }
}

function Remove-BrokerRuntimeDirectoryPermissions {
    param([string]$GraphEndpoint, [hashtable]$Application, [hashtable]$ServicePrincipal)
    $graphId = '00000003-0000-0000-c000-000000000000'
    $graph = Get-BrokerServicePrincipal -GraphEndpoint $GraphEndpoint -ClientId $graphId
    $retired = @($graph.appRoles | Where-Object {
        $_.value -in @('Directory.Read.All', 'Group.Read.All', 'GroupMember.Read.All') -and
        $_.allowedMemberTypes -contains 'Application'
    } | ForEach-Object { $_.id })
    $assignments = @(Get-BrokerGraphCollection -Uri "$GraphEndpoint/v1.0/servicePrincipals/$($ServicePrincipal.id)/appRoleAssignments")
    foreach ($assignment in $assignments) {
        if ($assignment.resourceId -eq $graph.id -and $assignment.appRoleId -in $retired) {
            $null = Invoke-BrokerGraph -Method DELETE -Uri "$GraphEndpoint/v1.0/servicePrincipals/$($ServicePrincipal.id)/appRoleAssignments/$($assignment.id)"
        }
    }
    $resources = @(
        foreach ($resource in $Application.requiredResourceAccess) {
            if ($resource.resourceAppId -ne $graphId) { $resource; continue }
            $access = @($resource.resourceAccess | Where-Object { $_.id -notin $retired -or $_.type -ne 'Role' })
            if ($access.Count) { @{ resourceAppId = $graphId; resourceAccess = $access } }
        }
    )
    $null = Invoke-BrokerGraph -Method PATCH -Uri "$GraphEndpoint/v1.0/applications/$($Application.id)" -Body @{ requiredResourceAccess = $resources }
}

function Initialize-BrokerApplications {
    param(
        [Parameter(Mandatory)][hashtable]$Configuration,
        [Parameter(Mandatory)][string]$GraphEndpoint,
        [Parameter(Mandatory)][string]$NamePrefix,
        [Parameter(Mandatory)][string]$PortalUrl,
        [string]$ApiClientId, [string]$PortalClientId, [string]$LauncherClientId,
        [string[]]$LegacyMachineGroupIds = @()
    )
    Test-BrokerAccessPrincipals -Configuration $Configuration -GraphEndpoint $GraphEndpoint
    $PortalUrl = Assert-BrokerHttpsUrl $PortalUrl
    $api = Get-BrokerApplication -GraphEndpoint $GraphEndpoint -DisplayName "$NamePrefix-api-ar" -ClientId $ApiClientId
    $portal = Get-BrokerApplication -GraphEndpoint $GraphEndpoint -DisplayName "$NamePrefix-frontend-ar" -ClientId $PortalClientId
    $launcher = Get-BrokerApplication -GraphEndpoint $GraphEndpoint -DisplayName "$NamePrefix-launcher-ar" -ClientId $LauncherClientId
    if (@($api.appId, $portal.appId, $launcher.appId | Select-Object -Unique).Count -ne 3) {
        throw 'The API, portal, and public launcher must be three distinct applications.'
    }
    if (@($launcher.passwordCredentials).Count -or @($launcher.keyCredentials).Count) {
        throw 'The dedicated launcher application must not have client secrets or certificate credentials. Review and remove them explicitly.'
    }
    $apiSp = Get-BrokerServicePrincipal -GraphEndpoint $GraphEndpoint -ClientId $api.appId -Create
    $portalSp = Get-BrokerServicePrincipal -GraphEndpoint $GraphEndpoint -ClientId $portal.appId -Create
    $launcherSp = Get-BrokerServicePrincipal -GraphEndpoint $GraphEndpoint -ClientId $launcher.appId -Create
    if ($launcherSp.appRoleAssignmentRequired -and @($launcher.appRoles).Count) {
        throw 'An assignment-required launcher with existing custom app roles needs an explicit operator review. Use the dedicated public-client registration; unrelated native roles will not be overwritten.'
    }

    $roleIds = @{}
    $roles = @($api.appRoles | ForEach-Object { ConvertTo-BrokerRolePayload $_ })
    foreach ($name in $script:BrokerRoleDefaults.Keys) {
        $match = @($roles | Where-Object { $_.value -eq $name })
        if ($match.Count -gt 1) { throw "API role '$name' is ambiguous." }
        $roleIds[$name] = if ($match.Count) { $match[0].id } else { $script:BrokerRoleDefaults[$name] }
        if (-not $match.Count) {
            $roles += @{
                id = $roleIds[$name]; value = $name; displayName = $name
                description = "Linux Broker $name permission."
                allowedMemberTypes = @(if ($name -in @('WorkspaceUser', 'FullAccess')) { 'User' } else { 'Application' })
                isEnabled = $true
            }
        }
        else {
            # Recover safely after an interrupted disable/change/enable transition.
            $match[0].isEnabled = $true
        }
    }
    $apiSettings = if ($api.api) { $api.api } else { @{} }
    $scopes = @($apiSettings.oauth2PermissionScopes)
    $scopeIds = @{}
    foreach ($name in $script:BrokerScopeDefaults.Keys) {
        $match = @($scopes | Where-Object { $_.value -eq $name })
        if ($match.Count -gt 1) { throw "API scope '$name' is ambiguous." }
        $scopeIds[$name] = if ($match.Count) { $match[0].id } else { $script:BrokerScopeDefaults[$name] }
        $scopes = @($scopes | Where-Object { $_.value -ne $name }) + @(@{
            id = $scopeIds[$name]; value = $name; isEnabled = $true; type = 'Admin'
            adminConsentDescription = if ($name -eq 'connect_as_user') { 'Connect only to the signed-in user''s Linux workspace.' } else { 'Manage the broker as an assigned administrator; cannot issue Linux credentials.' }
            adminConsentDisplayName = if ($name -eq 'connect_as_user') { 'Connect to own workspace' } else { 'Manage Linux Broker' }
        })
    }
    $apiSettings.oauth2PermissionScopes = $scopes
    $apiSettings.requestedAccessTokenVersion = 2
    $apiSettings.knownClientApplications = @(@($apiSettings.knownClientApplications) + @($portal.appId, $launcher.appId) | Select-Object -Unique)
    $apiSettings.preAuthorizedApplications = @($apiSettings.preAuthorizedApplications | Where-Object { $_.appId -notin @($portal.appId, $launcher.appId) }) + @(
        @{ appId = $portal.appId; delegatedPermissionIds = @($scopeIds.access_as_user) }
        @{ appId = $launcher.appId; delegatedPermissionIds = @($scopeIds.connect_as_user) }
    )
    $null = Invoke-BrokerGraph -Method PATCH -Uri "$GraphEndpoint/v1.0/applications/$($api.id)" -Body @{
        identifierUris = @(@($api.identifierUris) + @("api://$($api.appId)") | Select-Object -Unique)
        api = $apiSettings; appRoles = $roles; signInAudience = 'AzureADMyOrg'
        optionalClaims = Get-BrokerWorkloadOptionalClaims -Application $api
    }
    Wait-BrokerWorkloadOptionalClaim -GraphEndpoint $GraphEndpoint -ApplicationObjectId $api.id

    $web = if ($portal.web) { $portal.web } else { @{} }
    $web.redirectUris = @(@($web.redirectUris) + @("$PortalUrl/.auth/login/aad/callback", "$PortalUrl/getAToken") | Select-Object -Unique)
    if (-not $web['homePageUrl']) { $web.homePageUrl = $PortalUrl }
    if (-not $web['logoutUrl']) { $web.logoutUrl = "$PortalUrl/logout" }
    $portalRoles = @($portal.appRoles | ForEach-Object { ConvertTo-BrokerRolePayload $_ })
    $portalRole = @($portalRoles | Where-Object { $_.value -eq 'BrokerPortalAdministrator' })
    if ($portalRole.Count -gt 1) { throw 'Portal administrator role is ambiguous.' }
    $portalRoleId = if ($portalRole.Count) { $portalRole[0].id } else { $script:BrokerPortalRoleId }
    if (-not $portalRole.Count) {
        $portalRoles += @{
            id = $portalRoleId; value = 'BrokerPortalAdministrator'; displayName = 'Broker portal administrator'
            description = 'Sign in to the administrator portal. API FullAccess is independently required.'
            allowedMemberTypes = @('User'); isEnabled = $true
        }
    }
    $null = Invoke-BrokerGraph -Method PATCH -Uri "$GraphEndpoint/v1.0/applications/$($portal.id)" -Body @{
        web = $web; appRoles = $portalRoles; signInAudience = 'AzureADMyOrg'
        requiredResourceAccess = @(Merge-BrokerRequiredScope -Resources @($portal.requiredResourceAccess) -ApiClientId $api.appId -ScopeId $scopeIds.access_as_user -RemoveScopeIds @($scopeIds.connect_as_user))
    }
    $publicClient = if ($launcher.publicClient) { $launcher.publicClient } else { @{} }
    $publicClient.redirectUris = @(@($publicClient.redirectUris) + @("ms-appx-web://microsoft.aad.brokerplugin/$($launcher.appId)") | Select-Object -Unique)
    $null = Invoke-BrokerGraph -Method PATCH -Uri "$GraphEndpoint/v1.0/applications/$($launcher.id)" -Body @{
        signInAudience = 'AzureADMyOrg'; isFallbackPublicClient = $true; publicClient = $publicClient
        requiredResourceAccess = @(Merge-BrokerRequiredScope -Resources @($launcher.requiredResourceAccess) -ApiClientId $api.appId -ScopeId $scopeIds.connect_as_user -RemoveScopeIds @($scopeIds.access_as_user))
    }
    $null = Invoke-BrokerGraph -Method PATCH -Uri "$GraphEndpoint/v1.0/servicePrincipals/$($portalSp.id)" -Body @{ appRoleAssignmentRequired = $true }
    $apiSp = Wait-BrokerApplicationRoles -GraphEndpoint $GraphEndpoint -ClientId $api.appId -RoleIds @($roleIds.Values)
    $portalSp = Wait-BrokerApplicationRoles -GraphEndpoint $GraphEndpoint -ClientId $portal.appId -RoleIds @($portalRoleId)
    Sync-BrokerUserAssignments -Configuration $Configuration -GraphEndpoint $GraphEndpoint -ApiServicePrincipal $apiSp `
        -PortalServicePrincipal $portalSp -RoleIds $roleIds -PortalRoleId $portalRoleId -LegacyMachineGroupIds $LegacyMachineGroupIds
    if ($launcherSp.appRoleAssignmentRequired) {
        foreach ($id in (@($Configuration.workspaceUserIds) + @($Configuration.workspaceUserGroupIds))) {
            Ensure-BrokerAppRoleAssignment -GraphEndpoint $GraphEndpoint -PrincipalId $id -ResourceId $launcherSp.id -RoleId '00000000-0000-0000-0000-000000000000'
        }
    }

    $changed = @()
    foreach ($role in $roles) {
        if ($role.value -notin @('WorkspaceUser', 'FullAccess', 'LinuxHost', 'ScheduledTask', 'AvdHost')) { continue }
        $members = if ($role.value -in @('WorkspaceUser', 'FullAccess')) { @('User') } else { @('Application') }
        if (($role.allowedMemberTypes -join ',') -ne ($members -join ',') -or $role.value -eq 'AvdHost') {
            $changed += $role.id
            $role.isEnabled = $false
        }
    }
    if ($changed.Count) {
        $null = Invoke-BrokerGraph -Method PATCH -Uri "$GraphEndpoint/v1.0/applications/$($api.id)" -Body @{ appRoles = $roles }
    }
    foreach ($role in $roles) {
        if ($role.value -in @('WorkspaceUser', 'FullAccess', 'LinuxHost', 'ScheduledTask')) {
            $role.allowedMemberTypes = @(if ($role.value -in @('WorkspaceUser', 'FullAccess')) { 'User' } else { 'Application' })
            $role.isEnabled = $true
        }
    }
    $null = Invoke-BrokerGraph -Method PATCH -Uri "$GraphEndpoint/v1.0/applications/$($api.id)" -Body @{ appRoles = $roles }
    $memberTypes = @{}
    foreach ($name in $roleIds.Keys) { $memberTypes[$roleIds[$name]] = if ($name -in @('WorkspaceUser', 'FullAccess')) { 'User' } else { 'Application' } }
    $apiSp = Wait-BrokerApplicationRoles -GraphEndpoint $GraphEndpoint -ClientId $api.appId -RoleIds @($roleIds.Values) -ExpectedMemberTypes $memberTypes
    Remove-BrokerRuntimeDirectoryPermissions -GraphEndpoint $GraphEndpoint -Application $api -ServicePrincipal $apiSp
    return @{ Api = $api; Portal = $portal; Launcher = $launcher; RoleIds = $roleIds; ScopeIds = $scopeIds }
}
