. "$PSScriptRoot\Broker.Deployment.Common.ps1"

function Read-BrokerUserMapping {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$TenantId, [string[]]$ReservedUsernames = @())
    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    foreach ($key in $document.Keys) {
        if ($key -notin @('version', 'tenantId', 'users')) { throw "Unknown mapping field '$key'." }
    }
    if (($document.version -isnot [int] -and $document.version -isnot [long]) -or
        $document.version -ne 1 -or (Assert-BrokerGuid $document.tenantId 'Mapping tenantId') -ne $TenantId -or
        $document.users -isnot [array]) {
        throw 'Mapping must have version 1, the deployment tenant, and an explicit users array.'
    }
    $objects = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $uids = [Collections.Generic.HashSet[int]]::new()
    foreach ($user in $document.users) {
        foreach ($key in $user.Keys) {
            if ($key -notin @('objectId', 'expectedUserPrincipalName', 'username', 'uid')) { throw "Unknown user mapping field '$key'." }
        }
        $user.objectId = Assert-BrokerGuid $user.objectId 'Mapped user objectId'
        Assert-BrokerLinuxIdentity -Username $user.username -Uid $user.uid
        if ($user.username -in $ReservedUsernames) { throw 'The configured broker SSH administrator cannot be mapped to a workspace user.' }
        if ($user.expectedUserPrincipalName -isnot [string] -or
            $user.expectedUserPrincipalName -notmatch '^[^\s@]+@[^\s@]+$' -or $user.expectedUserPrincipalName.Length -gt 320) {
            throw 'Every mapping requires the reviewed expectedUserPrincipalName for Graph verification; it never determines the Linux name.'
        }
        if (-not $objects.Add($user.objectId) -or -not $names.Add($user.username) -or -not $uids.Add($user.uid)) {
            throw 'Duplicate/conflicting object ID, Linux username, or UID in the reviewed mapping.'
        }
    }
    return $document
}

function Test-BrokerUserMapping {
    param([hashtable]$Mapping, [string]$GraphEndpoint)
    Assert-BrokerTenant $Mapping.tenantId
    foreach ($user in $Mapping.users) {
        $actual = Invoke-BrokerGraph -Method GET -Uri "$GraphEndpoint/v1.0/users/$($user.objectId)?`$select=id,userPrincipalName,accountEnabled"
        if ($actual.id -ne $user.objectId -or $actual.accountEnabled -ne $true -or
            $actual.userPrincipalName -ine $user.expectedUserPrincipalName) {
            throw "Graph verification failed for mapped object '$($user.objectId)'. Review the intended owner; never derive a name from the sign-in."
        }
        Write-Host "Verified intended object '$($user.objectId)' for existing Linux '$($user.username)' (UID $($user.uid))."
    }
}

function Invoke-BrokerUserMapping {
    param($Connection, [hashtable]$Mapping, [switch]$DryRun)
    $transaction = $Connection.BeginTransaction()
    try {
        foreach ($user in $Mapping.users) {
            $null = Invoke-BrokerSqlProcedure -Connection $Connection -Transaction $transaction -Name BindBrokerUser -Parameters @{
                TenantId = $Mapping.tenantId; ObjectId = $user.objectId; Username = $user.username; Uid = $user.uid
            }
        }
        if ($DryRun) { $transaction.Rollback() } else { $transaction.Commit() }
    }
    finally {
        if ($transaction.Connection) { $transaction.Rollback() }
        $transaction.Dispose()
    }
}
