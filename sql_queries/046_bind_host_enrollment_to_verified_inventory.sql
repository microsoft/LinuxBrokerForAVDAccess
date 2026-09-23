SET XACT_ABORT ON;
IF COL_LENGTH('dbo.BrokerHosts', 'Retired') IS NULL
    ALTER TABLE dbo.BrokerHosts ADD Retired BIT NOT NULL CONSTRAINT DF_BrokerHosts_Retired DEFAULT (0);
GO

-- No existing mutable inventory row is evidence of a verified ARM endpoint.
-- The first application requires the normal trusted import/enrollment sequence again.
IF OBJECT_ID('dbo.BrokerHostInventory', 'U') IS NULL
BEGIN
    BEGIN TRANSACTION;
    EXEC dbo.LockBrokerState;
    CREATE TABLE dbo.BrokerHostInventory (
        Hostname VARCHAR(255) NOT NULL PRIMARY KEY,
        VMID INT NOT NULL CONSTRAINT UQ_BrokerHostInventory_VMID UNIQUE,
        IPAddress VARCHAR(50) NOT NULL,
        ImportedAt DATETIME2 NOT NULL
    );
    UPDATE dbo.BrokerHosts SET Retired = CASE WHEN Active = 0 THEN 1 ELSE 0 END, Active = 0;
    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER TRIGGER dbo.InvalidateBrokerHostInventory
ON dbo.VirtualMachines AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Changed TABLE (VMID INT PRIMARY KEY, Hostname VARCHAR(255));
    INSERT @Changed(VMID, Hostname)
    SELECT d.VMID, d.Hostname
    FROM deleted d LEFT JOIN inserted i ON i.VMID = d.VMID
    WHERE i.VMID IS NULL
       OR i.Hostname COLLATE Latin1_General_100_BIN2 <> d.Hostname COLLATE Latin1_General_100_BIN2
       OR ISNULL(i.IPAddress, '') COLLATE Latin1_General_100_BIN2 <> ISNULL(d.IPAddress, '') COLLATE Latin1_General_100_BIN2;
    IF NOT EXISTS (SELECT 1 FROM @Changed) RETURN;
    EXEC dbo.LockBrokerState;
    IF EXISTS (SELECT 1 FROM deleted d JOIN @Changed c ON c.VMID = d.VMID WHERE d.OperationId IS NOT NULL)
        THROW 51000, 'An endpoint cannot change while a broker operation is in progress.', 1;
    UPDATE h SET Active = 0
    FROM dbo.BrokerHosts h JOIN @Changed c ON c.Hostname = h.Hostname
    WHERE h.Active = 1;
    DELETE inventory
    FROM dbo.BrokerHostInventory inventory JOIN @Changed c
      ON c.VMID = inventory.VMID OR c.Hostname = inventory.Hostname;
END;
GO

CREATE OR ALTER PROCEDURE dbo.RegisterLinuxHostVm
    @Hostname NVARCHAR(255), @IPAddress NVARCHAR(50), @Description NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @Hostname IS NULL OR LEN(@Hostname) NOT BETWEEN 1 AND 63
       OR @Hostname COLLATE Latin1_General_100_BIN2 LIKE '%[^A-Za-z0-9-]%'
       OR @Hostname LIKE '-%' OR @Hostname LIKE '%-'
       OR @IPAddress IS NULL OR LEN(LTRIM(RTRIM(@IPAddress))) = 0
        THROW 51000, 'Trusted inventory requires a hostname and verified ARM address.', 1;
    BEGIN TRANSACTION;
    EXEC dbo.LockBrokerState;
    DECLARE @VMID INT, @StoredHostname VARCHAR(255), @Action VARCHAR(16) = 'Updated';
    SELECT @VMID = VMID, @StoredHostname = Hostname
    FROM dbo.VirtualMachines WITH (UPDLOCK, HOLDLOCK) WHERE Hostname = @Hostname;
    IF @VMID IS NULL
    BEGIN
        INSERT dbo.VirtualMachines(Hostname, IPAddress, PowerState, NetworkStatus, VmStatus, Description)
        VALUES (@Hostname, @IPAddress, 'On', 'Reachable', 'Available', @Description);
        SET @VMID = CONVERT(INT, SCOPE_IDENTITY());
        SET @StoredHostname = @Hostname;
        SET @Action = 'Inserted';
    END
    ELSE
        UPDATE dbo.VirtualMachines SET IPAddress = @IPAddress,
            Description = COALESCE(@Description, Description), LastUpdateDate = GETDATE()
        WHERE VMID = @VMID;

    -- The endpoint-change trigger revokes the old receipt and identity activation.
    -- Only this deployment-only import can issue a replacement receipt.
    UPDATE dbo.BrokerHostInventory SET VMID = @VMID, IPAddress = @IPAddress, ImportedAt = SYSUTCDATETIME()
    WHERE Hostname = @StoredHostname;
    IF @@ROWCOUNT = 0
        INSERT dbo.BrokerHostInventory(Hostname, VMID, IPAddress, ImportedAt)
        VALUES (@StoredHostname, @VMID, @IPAddress, SYSUTCDATETIME());
    SELECT @VMID AS VMID, @Action AS RegistrationAction;
    COMMIT TRANSACTION;
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
    IF NOT EXISTS (
        SELECT 1 FROM dbo.VirtualMachines v JOIN dbo.BrokerHostInventory inventory
          ON inventory.VMID = v.VMID
         AND inventory.Hostname COLLATE Latin1_General_100_BIN2 = v.Hostname COLLATE Latin1_General_100_BIN2
         AND inventory.IPAddress COLLATE Latin1_General_100_BIN2 = v.IPAddress COLLATE Latin1_General_100_BIN2
        WHERE v.Hostname = @Hostname
    )
        THROW 51000, 'Import the exact current VM record and ARM endpoint before enrolling its identity.', 1;
    IF EXISTS (SELECT 1 FROM dbo.BrokerHosts WHERE TenantId = @TenantId AND ObjectId = @ObjectId
               AND (Hostname <> @Hostname OR ResourceId <> @ResourceId OR Retired = 1))
       OR EXISTS (SELECT 1 FROM dbo.BrokerHosts WHERE ResourceId = @ResourceId AND Hostname <> @Hostname)
       OR EXISTS (SELECT 1 FROM dbo.BrokerHosts WHERE Hostname = @Hostname AND ResourceId <> @ResourceId)
        THROW 51000, 'The host principal or ARM resource has a conflicting or retired binding.', 1;
    IF EXISTS (SELECT 1 FROM dbo.BrokerHosts WHERE Hostname = @Hostname AND Retired = 0
               AND (TenantId <> @TenantId OR ObjectId <> @ObjectId))
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.VirtualMachines WHERE Hostname = @Hostname AND
                   (Username IS NOT NULL OR LeaseId IS NOT NULL OR OwnerObjectId IS NOT NULL OR OperationId IS NOT NULL))
            THROW 51000, 'Resolve the outstanding lease before replacing a host identity.', 1;
        UPDATE dbo.BrokerHosts SET Active = 0, Retired = 1 WHERE Hostname = @Hostname AND Retired = 0;
    END;
    IF NOT EXISTS (SELECT 1 FROM dbo.BrokerHosts WHERE TenantId = @TenantId AND ObjectId = @ObjectId)
        INSERT dbo.BrokerHosts(TenantId, ObjectId, Hostname, ResourceId)
        VALUES (@TenantId, @ObjectId, @Hostname, @ResourceId);
    ELSE
        UPDATE dbo.BrokerHosts SET Active = 1, RegisteredAt = SYSUTCDATETIME()
        WHERE TenantId = @TenantId AND ObjectId = @ObjectId AND Retired = 0;
    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER PROCEDURE dbo.DeleteVm @VMID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    EXEC dbo.LockBrokerState;
    IF EXISTS (SELECT 1 FROM dbo.VirtualMachines WHERE VMID = @VMID
        AND (Username IS NOT NULL OR LeaseId IS NOT NULL OR OwnerObjectId IS NOT NULL OR OperationId IS NOT NULL
             OR VmStatus NOT IN ('Available', 'Maintenance')))
    BEGIN
        COMMIT; SELECT 'Conflict' AS Outcome; RETURN;
    END;
    DECLARE @Deleted TABLE (DeletedVMID INT);
    DELETE dbo.VirtualMachines OUTPUT DELETED.VMID INTO @Deleted WHERE VMID = @VMID;
    -- The trigger invalidates enrollment in the same transaction. Generation
    -- tombstones and immutable user/profile mappings are deliberately untouched.
    SELECT 'Ok' AS Outcome, DeletedVMID FROM @Deleted;
    COMMIT TRANSACTION;
END;
GO
