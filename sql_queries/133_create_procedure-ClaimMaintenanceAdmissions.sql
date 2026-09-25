-- Admits the next hosts of an Active maintenance run, keeping enough hosts ready for users.
--
-- It holds the scaling app lock (waiting up to five seconds), so a scaling run and admission
-- never both take the last spare ready host. In one transaction it:
--   * skips pending hosts that are no longer registered, and powered-off ones when the run
--     does not include them;
--   * pauses the run once its canary hosts have all finished and more are pending;
--   * fills free batch slots from the pending hosts in order. A host that can take a user
--     (Ready, as dbo.CheckoutVm tests it) is only admitted while more hosts than the minimum
--     are ready: the run's MinReadyOverride, or else the scaling phase's MinVMs, resolved now.
--     A host that is in use, powered off or already out of rotation takes no ready capacity;
--   * takes each admitted host out of rotation as dbo.SetVmDrain does: straight to
--     Maintenance when it has no user and nothing to clean up, otherwise draining, so its user
--     keeps the session. How the host was found is recorded so it can be put back that way;
--   * asks scaling for one more ready host (SurgeRequested) while a ready host waits for want
--     of a spare, and records why the run is waiting.
--
-- Returns one row per host admitted or skipped. An empty result means nothing changed,
-- including when the lock was busy; the next advance tries again.

CREATE PROCEDURE [dbo].[ClaimMaintenanceAdmissions]
    @RunID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Changes TABLE (RunHostID INT, VMID INT, Hostname VARCHAR(255), Action VARCHAR(16), Detail NVARCHAR(400));
    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @LockResult INT, @StartedTransaction BIT = 0;
    DECLARE @Status VARCHAR(16), @BatchSize INT, @MinOverride INT, @IncludeOff BIT, @CanaryCount INT, @CanaryReached BIT;
    DECLARE @InFlight INT, @Admitted INT, @Slots INT, @MinReady INT, @Ready INT, @BlockedReady INT = 0, @FirstBlocked VARCHAR(255);
    DECLARE @RunHostID INT, @VMID INT, @Hostname VARCHAR(255), @IsReady BIT;
    DECLARE @VmStatus VARCHAR(16), @PowerState VARCHAR(10), @Draining BIT, @Username VARCHAR(255), @LeaseId UNIQUEIDENTIFIER, @CleanupPending BIT;

    IF @@TRANCOUNT = 0
    BEGIN
        BEGIN TRANSACTION;
        SET @StartedTransaction = 1;
    END

    EXEC @LockResult = sp_getapplock @Resource = 'LinuxBroker.Scaling', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 5000;
    IF @LockResult < 0
    BEGIN
        IF @StartedTransaction = 1 ROLLBACK TRANSACTION;
        SELECT RunHostID, VMID, Hostname, Action, Detail FROM @Changes;
        RETURN;
    END

    SELECT @Status = Status, @BatchSize = BatchSize, @MinOverride = MinReadyOverride, @IncludeOff = IncludePoweredOff,
           @CanaryCount = CanaryCount, @CanaryReached = CanaryReached
    FROM dbo.MaintenanceRuns WITH (UPDLOCK, HOLDLOCK)
    WHERE RunID = @RunID;

    IF @Status IS NULL OR @Status <> 'Active'
    BEGIN
        IF @StartedTransaction = 1 COMMIT TRANSACTION;
        SELECT RunHostID, VMID, Hostname, Action, Detail FROM @Changes;
        RETURN;
    END

    UPDATE h
    SET State = 'Skipped', Detail = N'The host is no longer registered.', CompletedAt = @Now, Version = Version + 1, UpdatedAt = @Now
    OUTPUT INSERTED.RunHostID, INSERTED.VMID, INSERTED.Hostname, 'Skipped', INSERTED.Detail INTO @Changes
    FROM dbo.MaintenanceRunHosts h
    WHERE h.RunID = @RunID AND h.State = 'Pending'
      AND NOT EXISTS (SELECT 1 FROM dbo.VirtualMachines vm WHERE vm.VMID = h.VMID);

    IF @IncludeOff = 0
    BEGIN
        UPDATE h
        SET State = 'Skipped', Detail = N'Powered off, and the run does not include powered-off hosts.',
            CompletedAt = @Now, Version = Version + 1, UpdatedAt = @Now
        OUTPUT INSERTED.RunHostID, INSERTED.VMID, INSERTED.Hostname, 'Skipped', INSERTED.Detail INTO @Changes
        FROM dbo.MaintenanceRunHosts h
        INNER JOIN dbo.VirtualMachines vm ON vm.VMID = h.VMID
        WHERE h.RunID = @RunID AND h.State = 'Pending' AND vm.PowerState = 'Off';
    END

    SELECT @InFlight = COALESCE(SUM(CASE WHEN State IN ('Draining', 'Starting', 'Patching', 'Restarting', 'Verifying') THEN 1 ELSE 0 END), 0),
           @Admitted = COALESCE(SUM(CASE WHEN AdmittedAt IS NOT NULL THEN 1 ELSE 0 END), 0)
    FROM dbo.MaintenanceRunHosts
    WHERE RunID = @RunID;

    -- The canary hosts have all finished: stop for an operator to check them.
    IF @CanaryCount > 0 AND @CanaryReached = 0 AND @Admitted >= @CanaryCount AND @InFlight = 0
       AND EXISTS (SELECT 1 FROM dbo.MaintenanceRunHosts WHERE RunID = @RunID AND State = 'Pending')
    BEGIN
        UPDATE dbo.MaintenanceRuns
        SET Status = 'Paused', CanaryReached = 1, SurgeRequested = 0, WaitReason = NULL,
            StatusReason = CONCAT(N'Paused after the first ', @CanaryCount, N' host', CASE WHEN @CanaryCount = 1 THEN N'' ELSE N's' END,
                                  N'. Check them, then resume the run.'),
            UpdatedAt = @Now
        WHERE RunID = @RunID;

        IF @StartedTransaction = 1 COMMIT TRANSACTION;
        SELECT RunHostID, VMID, Hostname, Action, Detail FROM @Changes;
        RETURN;
    END

    SET @Slots = @BatchSize - @InFlight;
    IF @CanaryCount > 0 AND @CanaryReached = 0 AND @CanaryCount - @Admitted < @Slots
        SET @Slots = @CanaryCount - @Admitted;

    SET @MinReady = COALESCE(@MinOverride, (SELECT TOP 1 MinVMs FROM dbo.fnActiveScalingPhase(NULL)), 0);
    SELECT @Ready = COUNT(*)
    FROM dbo.VirtualMachines
    WHERE VmStatus = 'Available' AND PowerState = 'On' AND NetworkStatus = 'Reachable'
      AND CleanupPending = 0 AND DrainRequested = 0 AND Username IS NULL AND LeaseId IS NULL;

    DECLARE pending CURSOR LOCAL FAST_FORWARD FOR
        SELECT h.RunHostID, h.VMID, vm.Hostname,
               CAST(CASE WHEN vm.VmStatus = 'Available' AND vm.PowerState = 'On' AND vm.NetworkStatus = 'Reachable'
                              AND vm.CleanupPending = 0 AND vm.DrainRequested = 0 AND vm.Username IS NULL AND vm.LeaseId IS NULL
                         THEN 1 ELSE 0 END AS BIT)
        FROM dbo.MaintenanceRunHosts h
        INNER JOIN dbo.VirtualMachines vm ON vm.VMID = h.VMID
        WHERE h.RunID = @RunID AND h.State = 'Pending'
        ORDER BY h.Position;

    OPEN pending;
    FETCH NEXT FROM pending INTO @RunHostID, @VMID, @Hostname, @IsReady;

    WHILE @@FETCH_STATUS = 0 AND @Slots > 0
    BEGIN
        IF @IsReady = 1 AND @Ready - 1 < @MinReady
        BEGIN
            SET @BlockedReady = @BlockedReady + 1;
            IF @FirstBlocked IS NULL SET @FirstBlocked = @Hostname;
        END
        ELSE
        BEGIN
            SELECT @VmStatus = VmStatus, @PowerState = PowerState, @Draining = DrainRequested, @Username = Username,
                   @LeaseId = LeaseId, @CleanupPending = CleanupPending
            FROM dbo.VirtualMachines WITH (UPDLOCK, HOLDLOCK, ROWLOCK)
            WHERE VMID = @VMID;

            IF @Draining = 0 AND @VmStatus <> 'Maintenance'
            BEGIN
                IF @VmStatus = 'Available' AND @Username IS NULL AND @LeaseId IS NULL AND @CleanupPending = 0
                BEGIN
                    UPDATE dbo.VirtualMachines
                    SET VmStatus = 'Maintenance', DrainRequested = 0, DrainRequestedDate = NULL, LastUpdateDate = GETDATE()
                    WHERE VMID = @VMID;
                END
                ELSE
                BEGIN
                    UPDATE dbo.VirtualMachines
                    SET DrainRequested = 1, DrainRequestedDate = GETDATE(), LastUpdateDate = GETDATE()
                    WHERE VMID = @VMID;
                END
            END

            UPDATE dbo.MaintenanceRunHosts
            SET State = 'Draining', AdmittedAt = @Now, StepStartedAt = @Now, ActionRequestedAt = NULL, Attempts = 0,
                WasDrained = @Draining,
                WasMaintenance = CASE WHEN @VmStatus = 'Maintenance' THEN 1 ELSE 0 END,
                WasPoweredOff = CASE WHEN @PowerState = 'Off' THEN 1 ELSE 0 END,
                Detail = NULL, Version = Version + 1, UpdatedAt = @Now
            OUTPUT INSERTED.RunHostID, INSERTED.VMID, INSERTED.Hostname, 'Admitted', NULL INTO @Changes
            WHERE RunHostID = @RunHostID AND State = 'Pending';

            SET @Slots = @Slots - 1;
            IF @IsReady = 1 SET @Ready = @Ready - 1;
        END

        FETCH NEXT FROM pending INTO @RunHostID, @VMID, @Hostname, @IsReady;
    END

    CLOSE pending;
    DEALLOCATE pending;

    UPDATE dbo.MaintenanceRuns
    SET SurgeRequested = CASE WHEN @BlockedReady > 0 THEN 1 ELSE 0 END,
        WaitReason = CASE
            WHEN @BlockedReady > 0 THEN CONCAT(N'Waiting for a spare ready host: taking ', @FirstBlocked, N' now would leave fewer than ',
                                               @MinReady, N' ready. Scaling is keeping one more host on.')
            ELSE NULL
        END
    WHERE RunID = @RunID;

    IF @StartedTransaction = 1 COMMIT TRANSACTION;

    SELECT RunHostID, VMID, Hostname, Action, Detail FROM @Changes;
END
GO
