CREATE OR ALTER PROCEDURE dbo.BeginBrokerCheckout
    @TenantId UNIQUEIDENTIFIER, @ObjectId UNIQUEIDENTIFIER, @AvdHost VARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    EXEC dbo.LockBrokerState;
    EXEC dbo.ResolveBrokerUser @TenantId, @ObjectId, @ReturnResult = 0;
    DECLARE @VMID INT, @Username VARCHAR(255), @Uid INT, @OldOperation UNIQUEIDENTIFIER,
        @OperationId UNIQUEIDENTIFIER = NEWID(), @NewAllocation BIT = 0, @Grace INT;
    SELECT @Username = username, @Uid = uid FROM dbo.VmUsers WHERE TenantId = @TenantId AND ObjectId = @ObjectId;
    SELECT @Grace = GracePeriodSeconds FROM dbo.LinuxHostSettings WHERE SettingsScope = 'Global';
    IF @Grace IS NULL THROW 51000, 'The global grace policy is unavailable.', 1;

    SELECT @VMID = VMID, @OldOperation = OperationId FROM dbo.VirtualMachines WITH (UPDLOCK, HOLDLOCK)
    WHERE OwnerTenantId = @TenantId AND OwnerObjectId = @ObjectId;
    IF @VMID IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.VirtualMachines v JOIN dbo.BrokerHosts h ON h.Hostname = v.Hostname AND h.Active = 1
            WHERE v.VMID = @VMID AND v.Username = @Username AND v.LeaseId IS NOT NULL
            AND v.VmStatus IN ('CheckedOut', 'Released') AND v.PowerState = 'On' AND v.NetworkStatus = 'Reachable')
        BEGIN
            COMMIT; SELECT 'Unavailable' AS Outcome; RETURN;
        END;
        IF @OldOperation IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM dbo.BrokerLeaseOperations WHERE OperationId = @OldOperation AND Kind = 'Provision'
            AND (State = 'Failed' OR (State = 'Running' AND StartedAt <= DATEADD(SECOND, -300, SYSUTCDATETIME()))))
        BEGIN
            COMMIT; SELECT 'Conflict' AS Outcome; RETURN;
        END;
        IF @OldOperation IS NULL AND EXISTS (SELECT 1 FROM dbo.VirtualMachines WHERE VMID = @VMID
            AND VmStatus = 'Released' AND DisconnectedAt <= DATEADD(SECOND, -@Grace, SYSUTCDATETIME()))
        BEGIN
            COMMIT; SELECT 'Expired' AS Outcome; RETURN;
        END;
    END
    ELSE
    BEGIN
        SELECT TOP (1) @VMID = v.VMID
        FROM dbo.VirtualMachines v WITH (UPDLOCK, HOLDLOCK)
        JOIN dbo.BrokerHosts h ON h.Hostname = v.Hostname AND h.Active = 1
        LEFT JOIN dbo.BrokerHostGenerations g ON g.Hostname = v.Hostname
        WHERE v.VmStatus = 'Available' AND v.PowerState = 'On' AND v.NetworkStatus = 'Reachable'
          AND v.Username IS NULL AND v.LeaseId IS NULL AND v.OwnerTenantId IS NULL
          AND v.OwnerObjectId IS NULL AND v.OperationId IS NULL
          AND v.LeaseGeneration < 9007199254740991 AND COALESCE(g.Generation, 0) < 9007199254740991
        ORDER BY v.VMID;
        IF @VMID IS NULL
        BEGIN
            COMMIT; SELECT 'Unavailable' AS Outcome; RETURN;
        END;
        SET @NewAllocation = 1;
    END;
    UPDATE dbo.BrokerLeaseOperations SET State = 'Superseded' WHERE OperationId = @OldOperation;
    EXEC dbo.AdvanceBrokerGeneration @VMID;
    UPDATE dbo.VirtualMachines SET
        Username = @Username, OwnerTenantId = @TenantId, OwnerObjectId = @ObjectId, AvdHost = @AvdHost,
        VmStatus = CASE WHEN @NewAllocation = 1 THEN 'CheckedOut' ELSE VmStatus END,
        LeaseId = CASE WHEN @NewAllocation = 1 THEN NEWID() ELSE LeaseId END,
        OperationId = @OperationId, LastUpdateDate = GETDATE()
    WHERE VMID = @VMID;
    INSERT dbo.BrokerLeaseOperations(OperationId, VMID, LeaseId, LeaseGeneration, Kind, State, NewAllocation, ActorTenantId, ActorObjectId)
    SELECT @OperationId, VMID, LeaseId, LeaseGeneration, 'Provision', 'Running', @NewAllocation, @TenantId, @ObjectId
    FROM dbo.VirtualMachines WHERE VMID = @VMID;
    SELECT 'Ok' AS Outcome, VMID, Hostname, IPAddress, Username, @Uid AS Uid, LeaseId, LeaseGeneration,
        OperationId, @NewAllocation AS NewAllocation
    FROM dbo.VirtualMachines WHERE VMID = @VMID;
    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER PROCEDURE dbo.ObserveBrokerSession
    @Hostname VARCHAR(255), @LeaseId UNIQUEIDENTIFIER, @LeaseGeneration BIGINT, @State VARCHAR(16)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @State NOT IN ('active', 'disconnected', 'logged_off') OR @State IS NULL
        THROW 51000, 'Invalid session observation.', 1;
    BEGIN TRANSACTION;
    EXEC dbo.LockBrokerState;
    DECLARE @VMID INT;
    SELECT @VMID = VMID FROM dbo.VirtualMachines WITH (UPDLOCK, HOLDLOCK)
    WHERE Hostname = @Hostname AND LeaseId = @LeaseId AND LeaseGeneration = @LeaseGeneration
        AND OwnerTenantId IS NOT NULL AND OwnerObjectId IS NOT NULL
        AND VmStatus IN ('CheckedOut', 'Released') AND OperationId IS NULL;
    IF @VMID IS NULL
    BEGIN
        COMMIT; SELECT 'Conflict' AS Outcome; RETURN;
    END;
    UPDATE dbo.VirtualMachines SET
        VmStatus = CASE WHEN @State = 'active' THEN 'CheckedOut' ELSE 'Released' END,
        DisconnectedAt = CASE WHEN @State = 'active' THEN NULL ELSE COALESCE(DisconnectedAt, SYSUTCDATETIME()) END,
        SessionState = @State, LastUpdateDate = GETDATE()
    WHERE VMID = @VMID;
    COMMIT;
    SELECT 'Ok' AS Outcome;
END;
GO

CREATE OR ALTER PROCEDURE dbo.BeginBrokerCleanup
    @ExpectedLeaseId UNIQUEIDENTIFIER, @ExpectedLeaseGeneration BIGINT, @Reason VARCHAR(16),
    @ActorTenantId UNIQUEIDENTIFIER, @ActorObjectId UNIQUEIDENTIFIER,
    @VMID INT = NULL, @Hostname VARCHAR(255) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @Reason NOT IN ('admin', 'expired', 'logged_off') OR @Reason IS NULL
        THROW 51000, 'Invalid cleanup reason.', 1;
    BEGIN TRANSACTION;
    EXEC dbo.LockBrokerState;
    DECLARE @Target INT, @OldOperation UNIQUEIDENTIFIER, @OperationId UNIQUEIDENTIFIER = NEWID(), @Grace INT;
    SELECT @Grace = GracePeriodSeconds FROM dbo.LinuxHostSettings WHERE SettingsScope = 'Global';
    IF @Grace IS NULL THROW 51000, 'The global grace policy is unavailable.', 1;
    SELECT @Target = v.VMID, @OldOperation = v.OperationId
    FROM dbo.VirtualMachines v WITH (UPDLOCK, HOLDLOCK)
    JOIN dbo.VmUsers u ON u.TenantId = v.OwnerTenantId AND u.ObjectId = v.OwnerObjectId AND u.username = v.Username
    JOIN dbo.BrokerHosts h ON h.Hostname = v.Hostname AND h.Active = 1
    WHERE ((@VMID IS NOT NULL AND @Hostname IS NULL AND v.VMID = @VMID)
        OR (@VMID IS NULL AND @Hostname IS NOT NULL AND v.Hostname = @Hostname))
      AND v.LeaseId = @ExpectedLeaseId AND v.LeaseGeneration = @ExpectedLeaseGeneration
      AND v.VmStatus IN ('CheckedOut', 'Released');
    IF @Target IS NULL
    BEGIN
        COMMIT; SELECT 'Conflict' AS Outcome; RETURN;
    END;
    IF @OldOperation IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.BrokerLeaseOperations
        WHERE OperationId = @OldOperation AND (Kind = 'Cleanup' OR (@Reason = 'admin' AND Kind = 'Provision'))
        AND (State = 'Failed' OR (State = 'Running' AND StartedAt <= DATEADD(SECOND, -300, SYSUTCDATETIME()))))
    BEGIN
        COMMIT; SELECT 'Conflict' AS Outcome; RETURN;
    END;
    IF @Reason = 'expired' AND NOT EXISTS (SELECT 1 FROM dbo.VirtualMachines WHERE VMID = @Target
        AND VmStatus = 'Released' AND DisconnectedAt <= DATEADD(SECOND, -@Grace, SYSUTCDATETIME()))
    BEGIN
        COMMIT; SELECT 'NotEligible' AS Outcome; RETURN;
    END;
    IF @Reason = 'logged_off' AND NOT EXISTS (SELECT 1 FROM dbo.VirtualMachines WHERE VMID = @Target
        AND VmStatus = 'Released' AND SessionState = 'logged_off')
    BEGIN
        COMMIT; SELECT 'NotEligible' AS Outcome; RETURN;
    END;
    UPDATE dbo.BrokerLeaseOperations SET State = 'Superseded' WHERE OperationId = @OldOperation;
    EXEC dbo.AdvanceBrokerGeneration @Target;
    UPDATE dbo.VirtualMachines SET OperationId = @OperationId,
        LastUpdateDate = GETDATE() WHERE VMID = @Target;
    INSERT dbo.BrokerLeaseOperations(OperationId, VMID, LeaseId, LeaseGeneration, Kind, State, Reason, ActorTenantId, ActorObjectId)
    SELECT @OperationId, VMID, LeaseId, LeaseGeneration, 'Cleanup', 'Running', @Reason, @ActorTenantId, @ActorObjectId
    FROM dbo.VirtualMachines WHERE VMID = @Target;
    SELECT 'Ok' AS Outcome, v.VMID, v.Hostname, v.Username, u.uid AS Uid, v.LeaseId, v.LeaseGeneration,
        v.OperationId, @Reason AS Reason
    FROM dbo.VirtualMachines v JOIN dbo.VmUsers u ON u.TenantId = v.OwnerTenantId AND u.ObjectId = v.OwnerObjectId
    WHERE v.VMID = @Target;
    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER PROCEDURE dbo.CompleteBrokerOperation
    @VMID INT, @OperationId UNIQUEIDENTIFIER, @LeaseGeneration BIGINT, @Outcome VARCHAR(32)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    EXEC dbo.LockBrokerState;
    DECLARE @Kind VARCHAR(16);
    SELECT @Kind = o.Kind FROM dbo.BrokerLeaseOperations o JOIN dbo.VirtualMachines v ON v.OperationId = o.OperationId
    WHERE o.OperationId = @OperationId AND o.VMID = @VMID AND v.VMID = @VMID
      AND o.LeaseGeneration = @LeaseGeneration AND v.LeaseGeneration = @LeaseGeneration AND o.State = 'Running'
      AND (o.LeaseId = v.LeaseId OR (o.LeaseId IS NULL AND v.LeaseId IS NULL));
    IF @Kind IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.BrokerLeaseOperations o JOIN dbo.VirtualMachines v ON v.VMID = o.VMID
            WHERE o.OperationId = @OperationId AND o.VMID = @VMID AND o.State = 'Completed'
              AND o.Outcome = @Outcome AND o.LeaseGeneration = @LeaseGeneration AND v.LeaseGeneration = @LeaseGeneration)
        BEGIN
            COMMIT; SELECT 'Ok' AS Outcome; RETURN;
        END;
        COMMIT; SELECT 'Conflict' AS Outcome; RETURN;
    END;
    IF NOT ((@Kind = 'Provision' AND @Outcome = 'ready')
        OR (@Kind = 'Cleanup' AND @Outcome IN ('cleaned', 'active', 'disconnected'))
        OR (@Kind = 'PowerOn' AND @Outcome = 'On') OR (@Kind = 'PowerOff' AND @Outcome = 'Off'))
        THROW 51000, 'Invalid operation completion.', 1;
    IF @Kind = 'Provision'
        UPDATE dbo.VirtualMachines SET VmStatus = 'CheckedOut', DisconnectedAt = NULL, SessionState = 'pending'
        WHERE VMID = @VMID;
    IF @Kind = 'Cleanup' AND @Outcome = 'cleaned'
        UPDATE dbo.VirtualMachines SET VmStatus = 'Available', Username = NULL, AvdHost = NULL, LeaseId = NULL,
            OwnerTenantId = NULL, OwnerObjectId = NULL, DisconnectedAt = NULL, SessionState = NULL
        WHERE VMID = @VMID;
    IF @Kind = 'Cleanup' AND @Outcome IN ('active', 'disconnected')
        UPDATE dbo.VirtualMachines SET
            VmStatus = CASE WHEN @Outcome = 'active' THEN 'CheckedOut' ELSE 'Released' END,
            DisconnectedAt = CASE WHEN @Outcome = 'active' THEN NULL ELSE COALESCE(DisconnectedAt, SYSUTCDATETIME()) END,
            SessionState = @Outcome
        WHERE VMID = @VMID;
    IF @Kind IN ('PowerOn', 'PowerOff')
        UPDATE dbo.VirtualMachines SET PowerState = @Outcome, NetworkStatus = 'Unreachable' WHERE VMID = @VMID;
    UPDATE dbo.VirtualMachines SET OperationId = NULL, LastUpdateDate = GETDATE() WHERE VMID = @VMID;
    UPDATE dbo.BrokerLeaseOperations SET State = 'Completed', CompletedAt = SYSUTCDATETIME(), Outcome = @Outcome
    WHERE OperationId = @OperationId;
    COMMIT;
    SELECT 'Ok' AS Outcome;
END;
GO

CREATE OR ALTER PROCEDURE dbo.FailBrokerOperation
    @VMID INT, @OperationId UNIQUEIDENTIFIER, @LeaseGeneration BIGINT, @ErrorCode VARCHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    EXEC dbo.LockBrokerState;
    UPDATE o SET State = 'Failed', ErrorCode = @ErrorCode
    FROM dbo.BrokerLeaseOperations o JOIN dbo.VirtualMachines v ON v.OperationId = o.OperationId
    WHERE v.VMID = @VMID AND o.OperationId = @OperationId AND v.LeaseGeneration = @LeaseGeneration
      AND o.LeaseGeneration = @LeaseGeneration AND o.State = 'Running'
      AND (o.LeaseId = v.LeaseId OR (o.LeaseId IS NULL AND v.LeaseId IS NULL));
    DECLARE @Changed INT = @@ROWCOUNT;
    COMMIT;
    SELECT CASE WHEN @Changed = 1 THEN 'Ok' ELSE 'Conflict' END AS Outcome;
END;
GO

-- This is a candidate query, not a return: cleanup must succeed before completion can clear ownership.
CREATE OR ALTER PROCEDURE dbo.ReturnReleasedVms
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Grace INT;
    SELECT @Grace = GracePeriodSeconds FROM dbo.LinuxHostSettings WHERE SettingsScope = 'Global';
    IF @Grace IS NULL THROW 51000, 'The global grace policy is unavailable.', 1;
    SELECT TOP (20) v.VMID, v.LeaseId, v.LeaseGeneration,
        CASE WHEN o.Kind = 'Cleanup' THEN o.Reason WHEN v.SessionState = 'logged_off' THEN 'logged_off' ELSE 'expired' END AS Reason
    FROM dbo.VirtualMachines v LEFT JOIN dbo.BrokerLeaseOperations o ON o.OperationId = v.OperationId
    WHERE v.OwnerTenantId IS NOT NULL AND v.OwnerObjectId IS NOT NULL AND v.LeaseId IS NOT NULL AND
        ((v.OperationId IS NULL AND v.VmStatus = 'Released' AND
            (v.SessionState = 'logged_off' OR v.DisconnectedAt <= DATEADD(SECOND, -@Grace, SYSUTCDATETIME())))
         OR (o.Kind = 'Cleanup' AND (o.State = 'Failed' OR
             (o.State = 'Running' AND o.StartedAt <= DATEADD(SECOND, -300, SYSUTCDATETIME())))))
    ORDER BY v.DisconnectedAt, v.VMID;
END;
GO

-- Intentionally incompatible with legacy callers; no username/hostname-only mutation remains.
CREATE OR ALTER PROCEDURE dbo.CheckoutVm @Username NVARCHAR(255), @AvdHost NVARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;
    THROW 51000, 'Use subject-bound BeginBrokerCheckout and guarded completion.', 1;
END;
GO
CREATE OR ALTER PROCEDURE dbo.ReturnVm @VMID INT, @ExpectedLeaseId UNIQUEIDENTIFIER = NULL, @RequireReleased BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    THROW 51000, 'Use generation-guarded BeginBrokerCleanup and verified completion.', 1;
END;
GO
CREATE OR ALTER PROCEDURE dbo.ReleaseVm @Hostname VARCHAR(255), @LeaseId UNIQUEIDENTIFIER = NULL, @Username NVARCHAR(255) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    THROW 51000, 'Use lease- and generation-bound ObserveBrokerSession.', 1;
END;
GO
