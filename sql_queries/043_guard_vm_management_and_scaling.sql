CREATE OR ALTER PROCEDURE dbo.AddVm
    @Hostname NVARCHAR(255), @IPAddress NVARCHAR(50), @PowerState VARCHAR(10),
    @NetworkStatus VARCHAR(16), @VmStatus VARCHAR(16), @Username NVARCHAR(255) = NULL,
    @AvdHost NVARCHAR(255) = NULL, @Description NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @Username IS NOT NULL OR @AvdHost IS NOT NULL OR @VmStatus NOT IN ('Available', 'Maintenance') OR @VmStatus IS NULL
        THROW 51000, 'Manual inventory creation cannot manufacture an assignment.', 1;
    IF @Hostname IS NULL OR LEN(@Hostname) NOT BETWEEN 1 AND 63
       OR @Hostname COLLATE Latin1_General_100_BIN2 LIKE '%[^A-Za-z0-9-]%'
       OR @Hostname LIKE '-%' OR @Hostname LIKE '%-'
        THROW 51000, 'Invalid host name.', 1;
    BEGIN TRANSACTION;
    EXEC dbo.LockBrokerState;
    INSERT dbo.VirtualMachines(Hostname, IPAddress, PowerState, NetworkStatus, VmStatus, Description)
    VALUES (@Hostname, @IPAddress, @PowerState, @NetworkStatus, @VmStatus, @Description);
    SELECT CONVERT(INT, SCOPE_IDENTITY()) AS NewVMID;
    COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE dbo.UpdateVmAttributes
    @VMID INT, @PowerState VARCHAR(10) = NULL, @NetworkStatus VARCHAR(16) = NULL, @VmStatus VARCHAR(16) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @VmStatus IS NOT NULL AND @VmStatus NOT IN ('Available', 'Maintenance')
        THROW 51000, 'Assignment status is controlled only by the lease lifecycle.', 1;
    BEGIN TRANSACTION;
    EXEC dbo.LockBrokerState;
    IF EXISTS (SELECT 1 FROM dbo.VirtualMachines WHERE VMID = @VMID
        AND (@PowerState IS NOT NULL OR @VmStatus IS NOT NULL)
        AND (Username IS NOT NULL OR LeaseId IS NOT NULL OR OwnerObjectId IS NOT NULL OR OperationId IS NOT NULL))
    BEGIN
        COMMIT; SELECT 'Conflict' AS Outcome; RETURN;
    END;
    UPDATE dbo.VirtualMachines SET PowerState = COALESCE(@PowerState, PowerState),
        NetworkStatus = COALESCE(@NetworkStatus, NetworkStatus), VmStatus = COALESCE(@VmStatus, VmStatus),
        LastUpdateDate = GETDATE() WHERE VMID = @VMID;
    SELECT 'Ok' AS Outcome, VMID, Hostname, IPAddress, PowerState, NetworkStatus, VmStatus, LastUpdateDate
    FROM dbo.VirtualMachines WHERE VMID = @VMID;
    COMMIT;
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
    SELECT 'Ok' AS Outcome, DeletedVMID FROM @Deleted;
    COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE dbo.TriggerScalingLogic
    @ActorTenantId UNIQUEIDENTIFIER, @ActorObjectId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    EXEC dbo.LockBrokerState;
    DECLARE @Min INT, @Max INT, @Up DECIMAL(5,2), @Down DECIMAL(5,2), @UpBy INT, @DownBy INT,
        @Running INT, @InUse INT, @Projected INT, @Count INT = 0, @Kind VARCHAR(16),
        @Action NVARCHAR(50) = 'No Action', @Ratio DECIMAL(9,2);
    SELECT TOP (1) @Min = MinVMs, @Max = MaxVMs, @Up = ScaleUpRatio, @Down = ScaleDownRatio,
        @UpBy = ScaleUpIncrement, @DownBy = ScaleDownIncrement FROM dbo.VmScalingRules ORDER BY RuleID;
    SELECT @Running = COUNT(*), @InUse = COALESCE(SUM(CASE WHEN Username IS NOT NULL OR LeaseId IS NOT NULL
        OR OwnerObjectId IS NOT NULL THEN 1 ELSE 0 END), 0) FROM dbo.VirtualMachines WHERE PowerState = 'On';
    SELECT @Projected = @Running + COALESCE(SUM(CASE WHEN o.Kind = 'PowerOn' THEN 1 WHEN o.Kind = 'PowerOff' THEN -1 ELSE 0 END), 0)
    FROM dbo.VirtualMachines v JOIN dbo.BrokerLeaseOperations o ON o.OperationId = v.OperationId;
    SET @Ratio = CASE WHEN @Projected <= 0 THEN 0 ELSE 100.0 * @InUse / @Projected END;
    IF @Min IS NOT NULL AND (@Projected < @Min OR (@Ratio >= @Up AND @Projected < @Max))
    BEGIN
        SET @Kind = 'PowerOn';
        SET @Count = CASE WHEN @Projected < @Min THEN @Min - @Projected
                          WHEN @Projected + @UpBy > @Max THEN @Max - @Projected ELSE @UpBy END;
        SET @Action = 'Scale Up';
    END
    ELSE IF @Min IS NOT NULL AND @Ratio <= @Down AND @Projected > @Min
    BEGIN
        SET @Kind = 'PowerOff';
        SET @Count = CASE WHEN @Projected - @DownBy < @Min THEN @Projected - @Min ELSE @DownBy END;
        SET @Action = 'Scale Down';
    END;

    DECLARE @Targets TABLE (VMID INT PRIMARY KEY, Kind VARCHAR(16));
    INSERT @Targets
    SELECT TOP (20) v.VMID, o.Kind FROM dbo.VirtualMachines v JOIN dbo.BrokerLeaseOperations o ON o.OperationId = v.OperationId
    WHERE o.Kind IN ('PowerOn', 'PowerOff') AND v.Username IS NULL AND v.LeaseId IS NULL AND v.OwnerObjectId IS NULL
      AND (o.State = 'Failed' OR (o.State = 'Running' AND o.StartedAt <= DATEADD(SECOND, -300, SYSUTCDATETIME())))
    ORDER BY o.StartedAt;
    IF @Count > 0
        INSERT @Targets
        SELECT TOP (@Count) v.VMID, @Kind FROM dbo.VirtualMachines v
        JOIN dbo.BrokerHosts h ON h.Hostname = v.Hostname AND h.Active = 1
        LEFT JOIN dbo.BrokerHostGenerations g ON g.Hostname = v.Hostname
        WHERE v.Username IS NULL AND v.LeaseId IS NULL AND v.OwnerObjectId IS NULL AND v.OperationId IS NULL
          AND v.VmStatus = 'Available'
          AND v.LeaseGeneration < 9007199254740991 AND COALESCE(g.Generation, 0) < 9007199254740991
          AND v.PowerState = CASE WHEN @Kind = 'PowerOn' THEN 'Off' ELSE 'On' END
        ORDER BY v.VMID;
    DECLARE @VMID INT, @TargetKind VARCHAR(16), @Operation UNIQUEIDENTIFIER;
    DECLARE targets CURSOR LOCAL FAST_FORWARD FOR SELECT VMID, Kind FROM @Targets;
    OPEN targets;
    FETCH NEXT FROM targets INTO @VMID, @TargetKind;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Operation = NEWID();
        UPDATE o SET State = 'Superseded' FROM dbo.BrokerLeaseOperations o
        JOIN dbo.VirtualMachines v ON v.OperationId = o.OperationId WHERE v.VMID = @VMID;
        EXEC dbo.AdvanceBrokerGeneration @VMID;
        UPDATE dbo.VirtualMachines SET OperationId = @Operation,
            LastUpdateDate = GETDATE() WHERE VMID = @VMID;
        INSERT dbo.BrokerLeaseOperations(OperationId, VMID, LeaseGeneration, Kind, State, ActorTenantId, ActorObjectId)
        SELECT @Operation, VMID, LeaseGeneration, @TargetKind, 'Running', @ActorTenantId, @ActorObjectId
        FROM dbo.VirtualMachines WHERE VMID = @VMID;
        FETCH NEXT FROM targets INTO @VMID, @TargetKind;
    END;
    CLOSE targets;
    DEALLOCATE targets;
    DECLARE @On INT = (SELECT COUNT(*) FROM @Targets WHERE Kind = 'PowerOn'),
            @Off INT = (SELECT COUNT(*) FROM @Targets WHERE Kind = 'PowerOff');
    INSERT dbo.VmScalingActivityLog(CheckTimestamp, CurrentRunningVMs, CurrentInUseVMs, ActionTaken,
        VMsPoweredOn, VMsPoweredOff, NewTotalVMs, Outcome)
    VALUES (GETDATE(), @Running, @InUse, @Action, @On, @Off, @Running + @On - @Off,
        'Power operations reserved; availability requires confirmed completion and reachability.');
    SELECT t.Kind AS ActionType, v.Hostname AS VMName, v.VMID, v.OperationId, v.LeaseGeneration
    FROM @Targets t JOIN dbo.VirtualMachines v ON v.VMID = t.VMID;
    COMMIT;
END;
GO
