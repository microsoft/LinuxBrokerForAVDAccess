-- Starts a stopped host for a user whose checkout found no host ready (4.1, start on demand).
-- The API calls it after dbo.CheckoutVm returns no host, and acts on Result:
--   Disabled         Start on demand is off. The checkout is refused as before.
--   Busy             The scaling lock was not free within five seconds. Ask again shortly.
--   ReadyNow         A host became ready since that checkout. Check out again.
--   Started          A stopped host was started for the user (VMID, VMName, ActivityID). The
--                    API asks Azure to start it, and records it as off again if Azure refuses.
--   AlreadyStarting  Enough hosts are starting for the users waiting, MaxPendingStarts are
--                    starting, or no other host can start while some still are. The user waits
--                    for one of them.
--   AtMaximum        No host is starting and the phase's MaxVMs hosts are all powered on.
--   NoCandidate      No host is starting and none is stopped and free to start.
--
-- A host counts as starting from its power-on until the reachability probe reaches it, for up
-- to ten minutes, as in scaling. The users waiting are dbo.fnWaitingCheckoutUsers and this
-- user. RetryAfterSeconds is when the AVD host should ask again: the median start time over the
-- last week (60 seconds without history), less how long the oldest host has been starting when
-- the user waits for one, kept between 30 and 120 seconds. BootingHostsJson lists the starting
-- hosts a checkout could take once they answer, oldest first, at most MaxPendingStarts, so the
-- API can probe them.
--
-- The decision and the start run under the scaling lock, so start on demand and scaling never
-- pick the same host or together pass MaxVMs. A start is recorded exactly as a scaling start
-- is, with a 'Start On Demand' row in dbo.VmScalingActivityLog.

CREATE PROCEDURE [dbo].[ReserveVmForStart]
    @Username VARCHAR(255),
    @AvdHost VARCHAR(255) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME = GETDATE(), @NowUtc DATETIME2(3) = SYSUTCDATETIME(), @Boot INT = 10;
    DECLARE @Enabled BIT, @MaxPending INT, @LockResult INT, @StartedTransaction BIT = 0;
    DECLARE @Result VARCHAR(24), @VMID INT, @VMName VARCHAR(255), @PreviousNetworkStatus VARCHAR(16), @ActivityID INT;
    DECLARE @PoweredOn INT = 0, @Serviceable INT = 0, @InUse INT = 0, @Draining INT = 0, @Booting INT = 0, @Waiting INT = 0;
    DECLARE @OldestBoot DATETIME, @MedianSeconds INT, @RetryAfter INT;
    DECLARE @PhaseName NVARCHAR(64), @ScheduleID INT, @MinVMs INT, @MaxVMs INT;
    DECLARE @BootingJson NVARCHAR(MAX);
    DECLARE @Started TABLE (VMID INT, Hostname VARCHAR(255), PreviousNetworkStatus VARCHAR(16));

    SELECT @Enabled = StartOnDemandEnabled, @MaxPending = MaxPendingStarts
    FROM dbo.ScalingPolicy
    WHERE PolicyID = 1;

    IF COALESCE(@Enabled, 0) = 0
    BEGIN
        SELECT CAST('Disabled' AS VARCHAR(24)) AS Result, CAST(NULL AS INT) AS VMID, CAST(NULL AS VARCHAR(255)) AS VMName,
               CAST(NULL AS VARCHAR(16)) AS PreviousNetworkStatus, CAST(NULL AS INT) AS ActivityID,
               CAST(NULL AS INT) AS RetryAfterSeconds, CAST(N'[]' AS NVARCHAR(MAX)) AS BootingHostsJson,
               0 AS Waiting, 0 AS Booting;
        RETURN;
    END

    IF @@TRANCOUNT = 0
    BEGIN
        BEGIN TRANSACTION;
        SET @StartedTransaction = 1;
    END
    ELSE
    BEGIN
        SAVE TRANSACTION ReserveVmForStartSave;
    END

    EXEC @LockResult = sp_getapplock @Resource = 'LinuxBroker.Scaling', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 5000;

    IF @LockResult < 0
    BEGIN
        IF @StartedTransaction = 1
        BEGIN
            ROLLBACK TRANSACTION;
        END
        ELSE
        BEGIN
            ROLLBACK TRANSACTION ReserveVmForStartSave;
        END

        SELECT CAST('Busy' AS VARCHAR(24)) AS Result, CAST(NULL AS INT) AS VMID, CAST(NULL AS VARCHAR(255)) AS VMName,
               CAST(NULL AS VARCHAR(16)) AS PreviousNetworkStatus, CAST(NULL AS INT) AS ActivityID,
               30 AS RetryAfterSeconds, CAST(N'[]' AS NVARCHAR(MAX)) AS BootingHostsJson,
               0 AS Waiting, 0 AS Booting;
        RETURN;
    END

    -- CheckoutVm's test for a host it can give a new user.
    IF EXISTS (
        SELECT 1 FROM dbo.VirtualMachines
        WHERE PowerState = 'On' AND NetworkStatus = 'Reachable' AND VmStatus = 'Available'
          AND Username IS NULL AND CleanupPending = 0 AND DrainRequested = 0
    )
    BEGIN
        IF @StartedTransaction = 1 COMMIT TRANSACTION;

        SELECT CAST('ReadyNow' AS VARCHAR(24)) AS Result, CAST(NULL AS INT) AS VMID, CAST(NULL AS VARCHAR(255)) AS VMName,
               CAST(NULL AS VARCHAR(16)) AS PreviousNetworkStatus, CAST(NULL AS INT) AS ActivityID,
               CAST(NULL AS INT) AS RetryAfterSeconds, CAST(N'[]' AS NVARCHAR(MAX)) AS BootingHostsJson,
               0 AS Waiting, 0 AS Booting;
        RETURN;
    END

    SELECT @PoweredOn = COALESCE(SUM(CASE WHEN PowerState = 'On' THEN 1 ELSE 0 END), 0),
           @Serviceable = COALESCE(SUM(CASE WHEN PowerState = 'On' AND VmStatus <> 'Maintenance' AND DrainRequested = 0
                                                AND (NetworkStatus = 'Reachable' OR PowerStateChangedDate >= DATEADD(MINUTE, -@Boot, @Now))
                                                AND NOT (VmStatus = 'Available' AND (Username IS NOT NULL OR LeaseId IS NOT NULL))
                                           THEN 1 ELSE 0 END), 0),
           @InUse = COALESCE(SUM(CASE WHEN PowerState = 'On' AND DrainRequested = 0
                                          AND (VmStatus IN ('CheckedOut', 'Released') OR CleanupPending = 1)
                                     THEN 1 ELSE 0 END), 0),
           @Draining = COALESCE(SUM(CASE WHEN DrainRequested = 1 THEN 1 ELSE 0 END), 0),
           @Booting = COALESCE(SUM(CASE WHEN PowerState = 'On' AND COALESCE(NetworkStatus, 'Unreachable') <> 'Reachable'
                                            AND VmStatus = 'Available' AND Username IS NULL AND LeaseId IS NULL
                                            AND DrainRequested = 0 AND PowerStateChangedDate >= DATEADD(MINUTE, -@Boot, @Now)
                                       THEN 1 ELSE 0 END), 0),
           @OldestBoot = MIN(CASE WHEN PowerState = 'On' AND COALESCE(NetworkStatus, 'Unreachable') <> 'Reachable'
                                      AND VmStatus = 'Available' AND Username IS NULL AND LeaseId IS NULL
                                      AND DrainRequested = 0 AND PowerStateChangedDate >= DATEADD(MINUTE, -@Boot, @Now)
                                 THEN PowerStateChangedDate END)
    FROM dbo.VirtualMachines;

    SELECT @Waiting = COUNT(*)
    FROM (
        SELECT Username FROM dbo.fnWaitingCheckoutUsers()
        UNION
        SELECT @Username
    ) waiting;

    SELECT TOP 1 @MedianSeconds = CAST(ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY Seconds) OVER (), 0) AS INT)
    FROM dbo.HostStartEvents
    WHERE ReadyAt >= DATEADD(DAY, -7, @NowUtc);
    SET @MedianSeconds = COALESCE(@MedianSeconds, 60);

    IF @Booting >= @MaxPending OR @Booting >= @Waiting
    BEGIN
        SET @Result = 'AlreadyStarting';
    END
    ELSE
    BEGIN
        SELECT @PhaseName = PhaseName, @ScheduleID = ScheduleID, @MinVMs = MinVMs, @MaxVMs = MaxVMs
        FROM dbo.fnActiveScalingPhase(NULL);

        IF @MaxVMs IS NULL OR @PoweredOn < @MaxVMs
        BEGIN
            SELECT TOP 1 @VMID = VMID
            FROM dbo.VirtualMachines WITH (UPDLOCK, ROWLOCK)
            WHERE PowerState = 'Off' AND VmStatus = 'Available' AND Username IS NULL AND LeaseId IS NULL
              AND DrainRequested = 0 AND CleanupPending = 0
            ORDER BY VMID;
        END

        IF @VMID IS NOT NULL
        BEGIN
            UPDATE vm
            SET PowerState = 'On', NetworkStatus = 'Unreachable', PowerStateChangedDate = @Now,
                StartRequestedAt = @NowUtc, LastUpdateDate = @Now
            OUTPUT INSERTED.VMID, INSERTED.Hostname, DELETED.NetworkStatus INTO @Started (VMID, Hostname, PreviousNetworkStatus)
            FROM dbo.VirtualMachines vm
            WHERE vm.VMID = @VMID;

            SELECT @VMName = Hostname, @PreviousNetworkStatus = PreviousNetworkStatus FROM @Started;

            INSERT INTO dbo.VmScalingActivityLog (CheckTimestamp, CurrentRunningVMs, CurrentInUseVMs, ActionTaken, VMsPoweredOn, VMsPoweredOff,
                                                  NewTotalVMs, Outcome, Notes, PhaseName, ScheduleID, MinVMs, MaxVMs, ServiceableVMs, DrainingVMs)
            VALUES (@Now, @PoweredOn, @InUse, N'Start On Demand', 1, 0, @PoweredOn + 1,
                    CONCAT(N'Requested power-on of ', @VMName, N' for a waiting user'),
                    CONCAT(N'No host was ready for ', @Username,
                           CASE WHEN @AvdHost IS NOT NULL THEN CONCAT(N' (AVD host ', @AvdHost, N')') ELSE N'' END,
                           N', so ', @VMName, N' was started. Counts poweredOn=', @PoweredOn, N', serviceable=', @Serviceable,
                           N', inUse=', @InUse, N', starting=', @Booting, N', waiting=', @Waiting,
                           N'. Phase=', COALESCE(@PhaseName, N'Default rule'), N'.'),
                    @PhaseName, @ScheduleID, @MinVMs, @MaxVMs, @Serviceable, @Draining);
            SET @ActivityID = SCOPE_IDENTITY();

            SET @Result = 'Started';
        END
        ELSE IF @Booting > 0
            SET @Result = 'AlreadyStarting';
        ELSE IF @MaxVMs IS NOT NULL AND @PoweredOn >= @MaxVMs
            SET @Result = 'AtMaximum';
        ELSE
            SET @Result = 'NoCandidate';
    END

    SET @RetryAfter = CASE
        WHEN @Result = 'Started' THEN @MedianSeconds
        WHEN @Result = 'AlreadyStarting' THEN @MedianSeconds - COALESCE(DATEDIFF(SECOND, @OldestBoot, @Now), 0)
        ELSE NULL
    END;
    SET @RetryAfter = CASE WHEN @RetryAfter IS NULL THEN NULL WHEN @RetryAfter < 30 THEN 30 WHEN @RetryAfter > 120 THEN 120 ELSE @RetryAfter END;

    IF @Result = 'AlreadyStarting'
    BEGIN
        SET @BootingJson = (
            SELECT TOP (@MaxPending) VMID, Hostname, IPAddress
            FROM dbo.VirtualMachines
            WHERE PowerState = 'On' AND COALESCE(NetworkStatus, 'Unreachable') <> 'Reachable'
              AND VmStatus = 'Available' AND Username IS NULL AND LeaseId IS NULL
              AND DrainRequested = 0 AND CleanupPending = 0
              AND PowerStateChangedDate >= DATEADD(MINUTE, -@Boot, @Now)
            ORDER BY PowerStateChangedDate, VMID
            FOR JSON PATH
        );
    END

    IF @StartedTransaction = 1 COMMIT TRANSACTION;

    SELECT @Result AS Result,
           @VMID AS VMID,
           @VMName AS VMName,
           @PreviousNetworkStatus AS PreviousNetworkStatus,
           @ActivityID AS ActivityID,
           @RetryAfter AS RetryAfterSeconds,
           COALESCE(@BootingJson, N'[]') AS BootingHostsJson,
           @Waiting AS Waiting,
           CASE WHEN @Result = 'Started' THEN @Booting + 1 ELSE @Booting END AS Booting;
END
GO
