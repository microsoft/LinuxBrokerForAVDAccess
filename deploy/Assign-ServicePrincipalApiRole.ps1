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

function Test-RoleAssigned {
    $existingAssignments = az rest --method GET --url "$graphUrl/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments" --output json 2>$null | ConvertFrom-Json
    $assignment = $existingAssignments.value | Where-Object {
        $_.resourceId -eq $apiServicePrincipal.id -and $_.appRoleId -eq $role.id
    } | Select-Object -First 1
    return [bool]$assignment
}

if (Test-RoleAssigned) {
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

    # A managed identity created moments earlier can take a short while to appear in
    # Microsoft Graph, so retry instead of reporting success after a failed call.
    $maxAttempts = 6
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $output = az rest --method POST --url "$graphUrl/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments" --headers 'Content-Type=application/json' --body "@$bodyFile" 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -or (Test-RoleAssigned)) {
            break
        }

        if ($attempt -eq $maxAttempts) {
            throw "Failed to assign '$RoleValue' to principal '$PrincipalId'. $($output.Trim())"
        }

        Write-Warning "Assigning '$RoleValue' to principal '$PrincipalId' failed on attempt $attempt of $maxAttempts. Retrying in 15 seconds."
        Start-Sleep -Seconds 15
    }
}
finally {
    Remove-Item -Path $bodyFile -ErrorAction SilentlyContinue
}

Write-Host "Assigned '$RoleValue' application permission to principal '$PrincipalId'."
