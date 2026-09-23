. "$PSScriptRoot\Broker.Deployment.Common.ps1"

function Assert-BrokerRuntimeDatabaseIdentity {
    param([string]$Username, [string]$Password, [string]$DeploymentUsername)
    if ($Username -cnotmatch '^[A-Za-z_][A-Za-z0-9_]{2,63}$' -or
        $Username -in @('dbo', 'guest', 'sys', 'INFORMATION_SCHEMA', 'public', 'BrokerApiRuntime') -or
        $Username -ieq $DeploymentUsername) {
        throw 'Use a distinct, non-reserved contained SQL user for the broker API, never the deployment administrator.'
    }
    if ([string]::IsNullOrWhiteSpace($Password) -or $Password.Length -lt 16 -or $Password.Length -gt 128 -or
        $Password -match '[\x00\r\n]') {
        throw 'The separate runtime SQL password must contain 16..128 characters without NUL or line breaks.'
    }
}

function Get-BrokerRuntimeUserSql {
    return @'
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRANSACTION;
DECLARE @RoleId INT = DATABASE_PRINCIPAL_ID(N'BrokerApiRuntime');
IF @RoleId IS NULL OR NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE principal_id = @RoleId AND type = 'R')
    THROW 51000, 'Apply the complete schema including the BrokerApiRuntime role before provisioning runtime credentials.', 1;
IF USER_NAME() = @RuntimeName OR IS_ROLEMEMBER(N'BrokerApiRuntime') = 1
    THROW 51000, 'Deployment and runtime database identities must be separate.', 1;
IF EXISTS (SELECT 1 FROM sys.database_role_members WHERE member_principal_id = @RoleId)
   OR EXISTS (SELECT 1 FROM sys.schemas WHERE principal_id = @RoleId)
   OR EXISTS (SELECT 1 FROM sys.objects WHERE principal_id = @RoleId)
    THROW 51000, 'BrokerApiRuntime must not inherit another role or own a schema/object.', 1;
DECLARE @UserId INT = DATABASE_PRINCIPAL_ID(@RuntimeName);
DECLARE @Statement NVARCHAR(MAX);
IF @UserId IS NULL
BEGIN
    SET @Statement = N'CREATE USER ' + QUOTENAME(@RuntimeName) + N' WITH PASSWORD = '
        + QUOTENAME(@RuntimePassword, '''') + N', DEFAULT_SCHEMA = dbo;';
    EXEC sys.sp_executesql @Statement;
    SET @Statement = N'ALTER ROLE BrokerApiRuntime ADD MEMBER ' + QUOTENAME(@RuntimeName) + N';';
    EXEC sys.sp_executesql @Statement;
END
ELSE
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.database_principals
                   WHERE principal_id = @UserId AND type = 'S' AND authentication_type_desc = N'DATABASE')
       OR NOT EXISTS (SELECT 1 FROM sys.database_role_members WHERE role_principal_id = @RoleId AND member_principal_id = @UserId)
       OR EXISTS (SELECT 1 FROM sys.database_role_members WHERE member_principal_id = @UserId AND role_principal_id <> @RoleId)
       OR EXISTS (SELECT 1 FROM sys.schemas WHERE principal_id = @UserId)
       OR EXISTS (SELECT 1 FROM sys.objects WHERE principal_id = @UserId)
       OR EXISTS (SELECT 1 FROM sys.database_principals WHERE owning_principal_id = @UserId)
       OR EXISTS (SELECT 1 FROM sys.database_permissions WHERE grantee_principal_id = @UserId
                  AND NOT (class = 0 AND permission_name = N'CONNECT' AND state = 'G'))
        THROW 51000, 'Existing runtime name has conflicting ownership, authentication, roles, or direct grants; choose/review a dedicated user.', 1;
    SET @Statement = N'ALTER USER ' + QUOTENAME(@RuntimeName) + N' WITH PASSWORD = '
        + QUOTENAME(@RuntimePassword, '''') + N';';
    EXEC sys.sp_executesql @Statement;
END;
COMMIT TRANSACTION;
'@
}

function Initialize-BrokerRuntimeUser {
    param([Parameter(Mandatory)]$Connection, [string]$Username, [string]$Password, [string]$DeploymentUsername)
    Assert-BrokerRuntimeDatabaseIdentity -Username $Username -Password $Password -DeploymentUsername $DeploymentUsername
    $command = $Connection.CreateCommand()
    $command.CommandText = Get-BrokerRuntimeUserSql
    $command.CommandTimeout = 120
    $nameParameter = $command.Parameters.Add('@RuntimeName', [Data.SqlDbType]::NVarChar, 128)
    $nameParameter.Value = $Username
    $passwordParameter = $command.Parameters.Add('@RuntimePassword', [Data.SqlDbType]::NVarChar, 128)
    $passwordParameter.Value = $Password
    try { $null = $command.ExecuteNonQuery() }
    catch [Data.SqlClient.SqlException] {
        throw "Contained runtime user provisioning failed (SQL error $($_.Exception.Number)). Check role/ownership conflicts using the deployment connection; no credential-bearing SQL or error body was logged."
    }
    finally { $command.Dispose() }
}

function Test-BrokerRuntimeDatabaseAccess {
    param([Parameter(Mandatory)]$Connection, [string]$ExpectedUsername)
    $command = $Connection.CreateCommand()
    $command.CommandTimeout = 60
    $command.CommandText = @'
SELECT USER_NAME() AS RuntimeUsername,
       IS_ROLEMEMBER(N'BrokerApiRuntime') AS RuntimeRole,
       IS_ROLEMEMBER(N'db_owner') AS DatabaseOwner,
       HAS_PERMS_BY_NAME(N'dbo.GetVms', N'OBJECT', N'EXECUTE') AS CanReadInventory,
       HAS_PERMS_BY_NAME(N'dbo.BindBrokerUser', N'OBJECT', N'EXECUTE') AS CanBindUser,
       HAS_PERMS_BY_NAME(N'dbo.RegisterBrokerHost', N'OBJECT', N'EXECUTE') AS CanRegisterHost,
       HAS_PERMS_BY_NAME(N'dbo.RegisterLinuxHostVm', N'OBJECT', N'EXECUTE') AS CanRegisterInventory,
       HAS_PERMS_BY_NAME(N'dbo.GetBrokerLeaseMigrationState', N'OBJECT', N'EXECUTE') AS CanReadMigration,
       HAS_PERMS_BY_NAME(N'dbo.VirtualMachines', N'OBJECT', N'UPDATE') AS CanWriteVmTable,
       HAS_PERMS_BY_NAME(N'dbo.BrokerHostInventory', N'OBJECT', N'UPDATE') AS CanWriteTrustedInventory,
       HAS_PERMS_BY_NAME(N'dbo.BrokerHosts', N'OBJECT', N'UPDATE') AS CanWriteHostBinding,
       HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'CONTROL') AS CanControlDatabase;
'@
    try {
        $reader = $command.ExecuteReader()
        try {
            if (-not $reader.Read() -or $reader['RuntimeUsername'] -cne $ExpectedUsername -or
                $reader['RuntimeRole'] -ne 1 -or $reader['CanReadInventory'] -ne 1) {
                throw 'The API SQL connection is not the expected dedicated runtime user with its required role.'
            }

            foreach ($column in @('DatabaseOwner', 'CanBindUser', 'CanRegisterHost', 'CanRegisterInventory',
                    'CanReadMigration', 'CanWriteVmTable', 'CanWriteTrustedInventory', 'CanWriteHostBinding', 'CanControlDatabase')) {
                if ($reader[$column] -ne 0) { throw "API SQL permission '$column' must be denied. Runtime database isolation failed." }
            }
        }
        finally { $reader.Dispose() }
    }
    finally { $command.Dispose() }
}

function Set-BrokerRuntimeDatabaseSecret {
    param([Parameter(Mandatory)][string]$KeyVaultName, [Parameter(Mandatory)][string]$Password)
    $path = Write-BrokerPrivateText -Content $Password
    try {
        $currentId = Invoke-BrokerAz -Arguments @('keyvault', 'secret', 'set', '--vault-name', $KeyVaultName,
            '--name', 'db-password', '--file', $path, '--encoding', 'utf-8', '--query', 'id') `
            -Operation 'Store dedicated broker runtime SQL credential' -Raw
        $null = Assert-BrokerHttpsUrl $currentId
        if (([uri]$currentId).AbsolutePath -notmatch '^/secrets/db-password/[a-zA-Z0-9]+$') {
            throw 'Key Vault did not confirm the runtime database credential version.'
        }
        $versions = @(Invoke-BrokerAz -Arguments @('keyvault', 'secret', 'list-versions', '--vault-name', $KeyVaultName,
            '--name', 'db-password') -Operation 'Inspect superseded database credential versions')
        foreach ($version in $versions) {
            if ($version.id -eq $currentId -or $version.attributes.enabled -eq $false) { continue }
            if (([uri]$version.id).Host -ine ([uri]$currentId).Host -or
                ([uri]$version.id).AbsolutePath -notmatch '^/secrets/db-password/[a-zA-Z0-9]+$') {
                throw 'Key Vault returned an unexpected database credential version.'
            }
            # Old versions can contain the former deployment-admin credential; runtime read access must not retain it.
            Invoke-BrokerAz -Arguments @('keyvault', 'secret', 'set-attributes', '--id', $version.id, '--enabled', 'false') `
                -Operation 'Disable a superseded database credential version' -NoOutput
        }
    }
    finally { Remove-Item -LiteralPath $path -Force }
}
