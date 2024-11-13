# Replace with the Object ID of your Function App's Managed Identity
$functionAppSpId = "YOUR_FUNCTION_APP_MANAGED_IDENTITY_OBJECT_ID"
# Replace with the Application (client) ID of your API
$apiAppId = "YOUR_API_APP_ID"

Install-Module Microsoft.Graph -Force
Import-Module Microsoft.Graph -Force
Connect-MgGraph -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All"

$functionAppSp = Get-MgServicePrincipal -Filter "Id eq '$functionAppSpId'"
$apiSp = Get-MgServicePrincipal -Filter "AppId eq '$apiAppId'"

$appRoleValue = "ScheduledTask"
$appRole = $apiSp.AppRoles | Where-Object { $_.Value -eq $appRoleValue -and $_.AllowedMemberTypes -contains "Application" }

if ($null -eq $appRole) {
    Write-Error "App role '$appRoleValue' not found in API application."
    return
}

New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $functionAppSp.Id -PrincipalId $functionAppSp.Id -ResourceId $apiSp.Id -AppRoleId $appRole.Id

Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $functionAppSp.Id | ForEach-Object {
    $appRoleAssignment = $_
    $resourceSp = Get-MgServicePrincipal -ServicePrincipalId $appRoleAssignment.ResourceId
    $appRole = $resourceSp.AppRoles | Where-Object { $_.Id -eq $appRoleAssignment.AppRoleId }
    [PSCustomObject]@{
        PrincipalDisplayName = $appRoleAssignment.PrincipalDisplayName
        AppRoleAssigned = $appRole.DisplayName
        ResourceDisplayName = $appRoleAssignment.ResourceDisplayName
    }
}
