CREATE OR ALTER PROCEDURE dbo.EnsureBrokerTenant @TenantId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    IF @TenantId IS NULL OR @TenantId = '00000000-0000-0000-0000-000000000000'
        THROW 51000, 'A nonempty tenant is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.BrokerTenant WHERE Id = 1)
        INSERT dbo.BrokerTenant(Id, TenantId) VALUES (1, @TenantId);
    IF NOT EXISTS (SELECT 1 FROM dbo.BrokerTenant WHERE Id = 1 AND TenantId = @TenantId)
        THROW 51000, 'The binding does not match the approved broker tenant.', 1;
END;
GO

CREATE OR ALTER PROCEDURE dbo.BindBrokerUser
    @TenantId UNIQUEIDENTIFIER, @ObjectId UNIQUEIDENTIFIER, @Username VARCHAR(255), @Uid INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    EXEC dbo.LockBrokerState;
    EXEC dbo.EnsureBrokerTenant @TenantId;
    IF @ObjectId IS NULL OR @ObjectId = '00000000-0000-0000-0000-000000000000'
        THROW 51000, 'A nonempty object identity is required.', 1;
    IF @Username IS NULL OR LEN(@Username) NOT BETWEEN 1 AND 32
       OR @Username COLLATE Latin1_General_100_BIN2 LIKE '%[^A-Za-z0-9_-]%'
       OR @Username COLLATE Latin1_General_100_BIN2 NOT LIKE '[A-Za-z_]%'
       OR LOWER(@Username) IN ('root', 'avdadmin', 'nobody', 'daemon', 'bin', 'sys', 'sync', 'games',
                              'man', 'lp', 'mail', 'news', 'uucp', 'proxy', 'www-data', 'backup',
                              'list', 'irc', 'sshd', 'postgres', 'messagebus', 'polkitd')
       OR @Uid IS NULL OR @Uid NOT BETWEEN 2000 AND 2147483646 OR @Uid IN (65534, 65535)
        THROW 51000, 'The approved mapping must use a valid non-reserved Linux username and UID.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.VmUsers WHERE username COLLATE Latin1_General_100_BIN2 = @Username AND uid = @Uid)
        THROW 51000, 'The approved username and UID must already match VmUsers exactly.', 1;
    IF EXISTS (SELECT 1 FROM dbo.VmUsers WHERE
        (username = @Username AND TenantId IS NOT NULL AND (TenantId <> @TenantId OR ObjectId <> @ObjectId))
        OR (TenantId = @TenantId AND ObjectId = @ObjectId AND (username <> @Username OR uid <> @Uid)))
        THROW 51000, 'The approved identity mapping conflicts with an immutable binding.', 1;
    IF (SELECT COUNT(*) FROM dbo.VirtualMachines WHERE Username = @Username) > 1
        THROW 51000, 'The legacy user has conflicting assignments. Resolve them before binding.', 1;
    IF EXISTS (SELECT 1 FROM dbo.VirtualMachines WHERE Username = @Username AND
        (VmStatus NOT IN ('CheckedOut', 'Released') OR OperationId IS NOT NULL
         OR (OwnerTenantId IS NOT NULL AND (OwnerTenantId <> @TenantId OR OwnerObjectId <> @ObjectId))))
        THROW 51000, 'The legacy assignment is inconsistent or has an operation in progress.', 1;

    UPDATE dbo.VmUsers SET TenantId = @TenantId, ObjectId = @ObjectId WHERE uid = @Uid;
    UPDATE dbo.VirtualMachines SET
        OwnerTenantId = @TenantId, OwnerObjectId = @ObjectId,
        LeaseId = COALESCE(LeaseId, NEWID()),
        LeaseGeneration = CASE WHEN LeaseGeneration = 0 THEN 1 ELSE LeaseGeneration END,
        DisconnectedAt = CASE WHEN VmStatus = 'Released' THEN COALESCE(DisconnectedAt, SYSUTCDATETIME()) ELSE DisconnectedAt END
    WHERE Username = @Username;
    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER PROCEDURE dbo.ResolveBrokerUser
    @TenantId UNIQUEIDENTIFIER, @ObjectId UNIQUEIDENTIFIER, @ReturnResult BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    EXEC dbo.LockBrokerState;
    IF NOT EXISTS (SELECT 1 FROM dbo.BrokerTenant WHERE TenantId = @TenantId)
       OR @ObjectId IS NULL OR @ObjectId = '00000000-0000-0000-0000-000000000000'
        THROW 51000, 'An approved tenant and object identity are required.', 1;
    IF EXISTS (SELECT 1 FROM dbo.VmUsers WHERE TenantId = @TenantId AND ObjectId = @ObjectId
               AND (uid NOT BETWEEN 2000 AND 2147483646 OR uid IN (65534, 65535)))
        THROW 51000, 'The established mapping has an unsupported UID; preserve it for operator recovery.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.VmUsers WHERE TenantId = @TenantId AND ObjectId = @ObjectId)
    BEGIN
        DECLARE @Uid BIGINT, @Username VARCHAR(32);
        SELECT @Uid = COALESCE(MAX(CONVERT(BIGINT, uid)), 1999) + 1 FROM dbo.VmUsers WITH (UPDLOCK, HOLDLOCK);
        IF @Uid < 2000 SET @Uid = 2000;
        SET @Username = CONCAT('broker_', @Uid);
        WHILE @Uid IN (65534, 65535) OR EXISTS (SELECT 1 FROM dbo.VmUsers WHERE username = @Username)
        BEGIN
            SET @Uid += 1;
            SET @Username = CONCAT('broker_', @Uid);
        END;
        IF @Uid > 2147483646 THROW 51000, 'The broker UID allocation range is exhausted.', 1;
        INSERT dbo.VmUsers(uid, username, TenantId, ObjectId) VALUES (@Uid, @Username, @TenantId, @ObjectId);
    END;
    IF @ReturnResult = 1
        SELECT username AS Username, uid AS Uid FROM dbo.VmUsers WHERE TenantId = @TenantId AND ObjectId = @ObjectId;
    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER TRIGGER dbo.ProtectBrokerUserMapping ON dbo.VmUsers AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted d LEFT JOIN inserted i ON i.uid = d.uid
        WHERE i.uid IS NULL OR i.username COLLATE Latin1_General_100_BIN2 <> d.username
        OR (d.TenantId IS NOT NULL AND
            (i.TenantId IS NULL OR i.ObjectId IS NULL OR i.TenantId <> d.TenantId OR i.ObjectId <> d.ObjectId)))
        THROW 51000, 'Broker usernames, UIDs and established subjects are immutable and cannot be recycled.', 1;
END;
GO

CREATE OR ALTER PROCEDURE dbo.RegisterBrokerHost
    @TenantId UNIQUEIDENTIFIER, @ObjectId UNIQUEIDENTIFIER, @Hostname VARCHAR(255), @ResourceId NVARCHAR(1024)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    EXEC dbo.LockBrokerState;
    EXEC dbo.EnsureBrokerTenant @TenantId;
    IF @ObjectId IS NULL OR @ObjectId = '00000000-0000-0000-0000-000000000000'
       OR @Hostname IS NULL OR LEN(@Hostname) NOT BETWEEN 1 AND 63
       OR @Hostname COLLATE Latin1_General_100_BIN2 LIKE '%[^A-Za-z0-9-]%'
       OR @Hostname LIKE '-%' OR @Hostname LIKE '%-'
       OR @ResourceId IS NULL OR @ResourceId NOT LIKE '/subscriptions/%/resourceGroups/%/providers/Microsoft.Compute/virtualMachines/%'
       OR LOWER(RIGHT(@ResourceId, LEN(@Hostname) + 1)) <> '/' + LOWER(@Hostname)
        THROW 51000, 'A verified host identity and matching ARM resource are required.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.VirtualMachines WHERE Hostname = @Hostname)
        THROW 51000, 'Register the VM inventory record before binding its identity.', 1;
    IF EXISTS (SELECT 1 FROM dbo.BrokerHosts WHERE TenantId = @TenantId AND ObjectId = @ObjectId
               AND (Hostname <> @Hostname OR ResourceId <> @ResourceId OR Active = 0))
       OR EXISTS (SELECT 1 FROM dbo.BrokerHosts WHERE ResourceId = @ResourceId AND Hostname <> @Hostname)
       OR EXISTS (SELECT 1 FROM dbo.BrokerHosts WHERE Hostname = @Hostname AND ResourceId <> @ResourceId)
        THROW 51000, 'The host principal or ARM resource has a conflicting binding.', 1;
    IF EXISTS (SELECT 1 FROM dbo.BrokerHosts WHERE Hostname = @Hostname AND Active = 1
               AND (TenantId <> @TenantId OR ObjectId <> @ObjectId))
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.VirtualMachines WHERE Hostname = @Hostname AND
                   (Username IS NOT NULL OR LeaseId IS NOT NULL OR OwnerObjectId IS NOT NULL OR OperationId IS NOT NULL))
            THROW 51000, 'Resolve the outstanding lease before replacing a host identity.', 1;
        UPDATE dbo.BrokerHosts SET Active = 0 WHERE Hostname = @Hostname AND Active = 1;
    END;
    IF NOT EXISTS (SELECT 1 FROM dbo.BrokerHosts WHERE TenantId = @TenantId AND ObjectId = @ObjectId)
        INSERT dbo.BrokerHosts(TenantId, ObjectId, Hostname, ResourceId) VALUES (@TenantId, @ObjectId, @Hostname, @ResourceId);
    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER PROCEDURE dbo.GetBrokerHost @TenantId UNIQUEIDENTIFIER, @ObjectId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT h.Hostname FROM dbo.BrokerHosts h JOIN dbo.VirtualMachines v ON v.Hostname = h.Hostname
    WHERE h.TenantId = @TenantId AND h.ObjectId = @ObjectId AND h.Active = 1;
END;
GO

CREATE OR ALTER PROCEDURE dbo.GetBrokerLeaseMigrationState @Hostname VARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    EXEC dbo.LockBrokerState;
    IF NOT EXISTS (SELECT 1 FROM dbo.VirtualMachines WHERE Hostname = @Hostname)
        THROW 51000, 'The migration host is not registered.', 1;
    IF EXISTS (SELECT 1 FROM dbo.VirtualMachines v LEFT JOIN dbo.VmUsers u
        ON u.TenantId = v.OwnerTenantId AND u.ObjectId = v.OwnerObjectId AND u.username = v.Username
        WHERE v.Hostname = @Hostname AND
        (v.OperationId IS NOT NULL OR
         ((v.VmStatus IN ('CheckedOut', 'Released') OR v.Username IS NOT NULL OR v.LeaseId IS NOT NULL
           OR v.OwnerObjectId IS NOT NULL) AND
          (v.VmStatus NOT IN ('CheckedOut', 'Released') OR u.uid IS NULL OR v.LeaseId IS NULL OR v.LeaseGeneration < 1))))
        THROW 51000, 'Active lease ownership is unresolved or conflicting; migration cannot continue.', 1;
    SELECT u.username AS Username, u.uid AS Uid, v.LeaseId, v.LeaseGeneration
    FROM dbo.VirtualMachines v JOIN dbo.VmUsers u ON u.TenantId = v.OwnerTenantId AND u.ObjectId = v.OwnerObjectId
    WHERE v.Hostname = @Hostname AND v.VmStatus IN ('CheckedOut', 'Released');
    COMMIT TRANSACTION;
END;
GO
