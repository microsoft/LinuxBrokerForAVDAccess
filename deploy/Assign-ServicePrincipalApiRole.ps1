[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PrincipalId,

    [Parameter(Mandatory = $true)]
    [string]$ApiClientId,

    [Parameter(Mandatory = $true)]
    [string]$RoleValue,

    [Parameter(Mandatory = $false)]
    [string]$GraphEndpoint
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($GraphEndpoint)) {
    $GraphEndpoint = $env:GRAPH_ENDPOINT
}

if ([string]::IsNullOrWhiteSpace($GraphEndpoint)) {
    $cloud = az cloud show --output json | ConvertFrom-Json
    $GraphEndpoint = switch ($cloud.name) {
        'AzureUSGovernment' { 'https://graph.microsoft.us' }
        'AzureCloud' { 'https://graph.microsoft.com' }
        default { throw "Cloud '$($cloud.name)' has no built-in Microsoft Graph endpoint. Pass -GraphEndpoint or set GRAPH_ENDPOINT." }
    }
}

$graphUrl = $GraphEndpoint.TrimEnd('/')

$apiServicePrincipal = az ad sp list --filter "appId eq '$ApiClientId'" --output json | ConvertFrom-Json | Select-Object -First 1
if (-not $apiServicePrincipal) {
    throw "Unable to resolve service principal for API client id '$ApiClientId'."
}

$role = $apiServicePrincipal.appRoles | Where-Object {
    $_.value -eq $RoleValue -and $_.allowedMemberTypes -contains 'Application'
} | Select-Object -First 1

if (-not $role) {
    throw "App role '$RoleValue' was not found on API service principal '$ApiClientId'."
}

$existingAssignments = az rest --method GET --url "$graphUrl/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments" --output json | ConvertFrom-Json
$assignment = $existingAssignments.value | Where-Object {
    $_.resourceId -eq $apiServicePrincipal.id -and $_.appRoleId -eq $role.id
} | Select-Object -First 1

if ($assignment) {
    Write-Host "Principal '$PrincipalId' already has '$RoleValue' app role assignment."
    exit 0
}

$payload = @{
    principalId = $PrincipalId
    resourceId = $apiServicePrincipal.id
    appRoleId = $role.id
}

$bodyFile = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.json')
try {
    $payload | ConvertTo-Json -Compress | Set-Content -Path $bodyFile -Encoding utf8
    az rest --method POST --url "$graphUrl/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments" --headers 'Content-Type=application/json' --body "@$bodyFile" | Out-Null
}
finally {
    Remove-Item -Path $bodyFile -ErrorAction SilentlyContinue
}

Write-Host "Assigned '$RoleValue' application permission to principal '$PrincipalId'."
