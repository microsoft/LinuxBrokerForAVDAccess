-- Additive changes preserve temporal history and existing username/UID/profile keys.
SET XACT_ABORT ON;
IF EXISTS (SELECT Hostname FROM dbo.VirtualMachines GROUP BY Hostname HAVING COUNT(*) > 1)
    THROW 51000, 'Resolve duplicate hostnames before the broker identity migration.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.VirtualMachines') AND name = 'UX_Broker_Hostname')
    CREATE UNIQUE INDEX UX_Broker_Hostname ON dbo.VirtualMachines(Hostname);

IF COL_LENGTH('dbo.VmUsers', 'TenantId') IS NULL
    ALTER TABLE dbo.VmUsers ADD TenantId UNIQUEIDENTIFIER NULL;
IF COL_LENGTH('dbo.VmUsers', 'ObjectId') IS NULL
    ALTER TABLE dbo.VmUsers ADD ObjectId UNIQUEIDENTIFIER NULL;
IF COL_LENGTH('dbo.VirtualMachines', 'OwnerTenantId') IS NULL
    ALTER TABLE dbo.VirtualMachines ADD OwnerTenantId UNIQUEIDENTIFIER NULL;
IF COL_LENGTH('dbo.VirtualMachines', 'OwnerObjectId') IS NULL
    ALTER TABLE dbo.VirtualMachines ADD OwnerObjectId UNIQUEIDENTIFIER NULL;
IF COL_LENGTH('dbo.VirtualMachines', 'LeaseGeneration') IS NULL
    ALTER TABLE dbo.VirtualMachines ADD LeaseGeneration BIGINT NOT NULL CONSTRAINT DF_Broker_LeaseGeneration DEFAULT (0);
IF COL_LENGTH('dbo.VirtualMachines', 'DisconnectedAt') IS NULL
    ALTER TABLE dbo.VirtualMachines ADD DisconnectedAt DATETIME2 NULL;
IF COL_LENGTH('dbo.VirtualMachines', 'SessionState') IS NULL
    ALTER TABLE dbo.VirtualMachines ADD SessionState VARCHAR(16) NULL;
IF COL_LENGTH('dbo.VirtualMachines', 'OperationId') IS NULL
    ALTER TABLE dbo.VirtualMachines ADD OperationId UNIQUEIDENTIFIER NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.VmUsers') AND name = 'UX_Broker_UserSubject')
    CREATE UNIQUE INDEX UX_Broker_UserSubject ON dbo.VmUsers(TenantId, ObjectId)
        WHERE TenantId IS NOT NULL AND ObjectId IS NOT NULL;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.VirtualMachines') AND name = 'UX_Broker_LeaseOwner')
    CREATE UNIQUE INDEX UX_Broker_LeaseOwner ON dbo.VirtualMachines(OwnerTenantId, OwnerObjectId)
        WHERE OwnerTenantId IS NOT NULL AND OwnerObjectId IS NOT NULL;
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_Broker_UserSubject')
    ALTER TABLE dbo.VmUsers ADD CONSTRAINT CK_Broker_UserSubject CHECK (
        (TenantId IS NULL AND ObjectId IS NULL) OR (TenantId IS NOT NULL AND ObjectId IS NOT NULL));
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_Broker_BoundUserUid')
    ALTER TABLE dbo.VmUsers WITH CHECK ADD CONSTRAINT CK_Broker_BoundUserUid CHECK (
        TenantId IS NULL OR (uid BETWEEN 2000 AND 2147483646 AND uid NOT IN (65534, 65535)));
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_Broker_LeaseOwner')
    ALTER TABLE dbo.VirtualMachines ADD CONSTRAINT CK_Broker_LeaseOwner CHECK (
        (OwnerTenantId IS NULL AND OwnerObjectId IS NULL) OR
        (OwnerTenantId IS NOT NULL AND OwnerObjectId IS NOT NULL AND Username IS NOT NULL AND LeaseId IS NOT NULL
         AND LeaseGeneration > 0 AND VmStatus IN ('CheckedOut', 'Released')));

IF OBJECT_ID('dbo.BrokerTenant', 'U') IS NULL
    CREATE TABLE dbo.BrokerTenant (
        Id INT NOT NULL PRIMARY KEY CONSTRAINT CK_BrokerTenant_Singleton CHECK (Id = 1),
        TenantId UNIQUEIDENTIFIER NOT NULL
    );

IF OBJECT_ID('dbo.BrokerHosts', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.BrokerHosts (
        TenantId UNIQUEIDENTIFIER NOT NULL,
        ObjectId UNIQUEIDENTIFIER NOT NULL,
        Hostname VARCHAR(255) NOT NULL,
        ResourceId NVARCHAR(1024) NOT NULL,
        Active BIT NOT NULL CONSTRAINT DF_BrokerHosts_Active DEFAULT (1),
        RegisteredAt DATETIME2 NOT NULL CONSTRAINT DF_BrokerHosts_Registered DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_BrokerHosts PRIMARY KEY (TenantId, ObjectId)
    );
    CREATE UNIQUE INDEX UX_BrokerHosts_Host ON dbo.BrokerHosts(Hostname) WHERE Active = 1;
END;

IF OBJECT_ID('dbo.BrokerLeaseOperations', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.BrokerLeaseOperations (
        OperationId UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
        VMID INT NOT NULL,
        LeaseId UNIQUEIDENTIFIER NULL,
        LeaseGeneration BIGINT NOT NULL,
        Kind VARCHAR(16) NOT NULL CONSTRAINT CK_BrokerOperation_Kind CHECK (Kind IN ('Provision', 'Cleanup', 'PowerOn', 'PowerOff')),
        State VARCHAR(16) NOT NULL CONSTRAINT CK_BrokerOperation_State CHECK (State IN ('Running', 'Failed', 'Completed', 'Superseded')),
        Reason VARCHAR(16) NULL,
        NewAllocation BIT NOT NULL CONSTRAINT DF_BrokerOperation_New DEFAULT (0),
        ActorTenantId UNIQUEIDENTIFIER NOT NULL,
        ActorObjectId UNIQUEIDENTIFIER NOT NULL,
        StartedAt DATETIME2 NOT NULL CONSTRAINT DF_BrokerOperation_Started DEFAULT (SYSUTCDATETIME()),
        CompletedAt DATETIME2 NULL,
        Outcome VARCHAR(32) NULL,
        ErrorCode VARCHAR(64) NULL,
        CONSTRAINT UQ_BrokerOperation_Generation UNIQUE (VMID, LeaseGeneration)
    );
END;
IF OBJECT_ID('dbo.BrokerHostGenerations', 'U') IS NULL
    CREATE TABLE dbo.BrokerHostGenerations (
        Hostname VARCHAR(255) NOT NULL PRIMARY KEY,
        Generation BIGINT NOT NULL
    );
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_Broker_LeaseGenerationRange')
    ALTER TABLE dbo.VirtualMachines WITH CHECK ADD CONSTRAINT CK_Broker_LeaseGenerationRange
        CHECK (LeaseGeneration BETWEEN 0 AND 9007199254740991);
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_Broker_HostGenerationRange')
    ALTER TABLE dbo.BrokerHostGenerations WITH CHECK ADD CONSTRAINT CK_Broker_HostGenerationRange
        CHECK (Generation BETWEEN 0 AND 9007199254740991);
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_Broker_OperationGenerationRange')
    ALTER TABLE dbo.BrokerLeaseOperations WITH CHECK ADD CONSTRAINT CK_Broker_OperationGenerationRange
        CHECK (LeaseGeneration BETWEEN 1 AND 9007199254740991);
GO

CREATE OR ALTER PROCEDURE dbo.LockBrokerState
AS
BEGIN
    SET NOCOUNT ON;
    IF @@TRANCOUNT = 0 THROW 51000, 'Broker state mutations require a transaction.', 1;
    DECLARE @Result INT;
    EXEC @Result = sys.sp_getapplock @Resource = 'LinuxBroker.State',
        @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 10000;
    IF @Result < 0 THROW 51000, 'Broker state is busy. Retry the operation.', 1;
END;
GO

-- Keep fencing monotonic even if an unassigned inventory row is deleted and later recreated.
CREATE OR ALTER PROCEDURE dbo.AdvanceBrokerGeneration @VMID INT
AS
BEGIN
    SET NOCOUNT ON;
    IF @@TRANCOUNT = 0 THROW 51000, 'Generation advancement requires a transaction.', 1;
    DECLARE @Hostname VARCHAR(255), @Current BIGINT, @Next BIGINT;
    SELECT @Hostname = Hostname, @Current = LeaseGeneration FROM dbo.VirtualMachines WHERE VMID = @VMID;
    IF @Hostname IS NULL THROW 51000, 'Unknown generation target.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.BrokerHostGenerations WHERE Hostname = @Hostname)
        INSERT dbo.BrokerHostGenerations(Hostname, Generation) VALUES (@Hostname, @Current);
    SELECT @Next = CASE WHEN Generation > @Current THEN Generation ELSE @Current END
    FROM dbo.BrokerHostGenerations WHERE Hostname = @Hostname;
    IF @Next >= 9007199254740991
        THROW 51000, 'The host generation range is exhausted; preserve the fence and recover administratively.', 1;
    SET @Next += 1;
    UPDATE dbo.BrokerHostGenerations SET Generation = @Next WHERE Hostname = @Hostname;
    UPDATE dbo.VirtualMachines SET LeaseGeneration = @Next WHERE VMID = @VMID;
END;
GO
