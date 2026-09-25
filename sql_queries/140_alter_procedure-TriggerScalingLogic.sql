-- Redefines dbo.TriggerScalingLogic for rolling maintenance (2.9). While an active maintenance
-- run is waiting to take a ready host out for want of a spare (dbo.MaintenanceRuns.
-- SurgeRequested), scaling keeps one more host serviceable than the phase's MinVMs, never more
-- than its MaxVMs, so the run can proceed without leaving fewer ready hosts than the minimum.
-- The activity log's MinVMs and notes show the surge, and the dry run returns it as
-- MaintenanceSurge. Everything else is unchanged from 113:
--
-- * The values come from dbo.fnActiveScalingPhase: the enabled schedule window that covers the
--   policy's local time, or else the default rule.
-- * @DryRun = 1 makes the same decision against the current counts without changing anything,
--   and returns one decision row for the portal's preview. @AtUtc resolves the phase at another
--   time and @OverrideJson replaces its values (MinVMs, MaxVMs, ScaleUpRatio, ScaleUpIncrement,
--   ScaleDownRatio, ScaleDownIncrement, StopMode, PhaseName); both apply to a dry run only.
-- * Scaling down to get under MaxVMs never takes serviceable hosts below MinVMs.
-- * A run waits up to five seconds for the scaling lock, which maintenance admission holds
--   briefly, rather than skipping.
-- * Each power-on stamps StartRequestedAt for the start-to-ready measure, a power-off clears it.
--
-- A normal call returns the same columns as before, so the previous API build is unaffected.

CREATE PROCEDURE [dbo].[TriggerScalingLogic]
    @DryRun BIT = 0,
    @AtUtc DATETIME2(0) = NULL,
    @OverrideJson NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Actions TABLE (
        ActionType VARCHAR(16), VMName VARCHAR(255), VMID INT,
        StopMode VARCHAR(16), PreviousNetworkStatus VARCHAR(16), ActivityID INT NULL
    );
    DECLARE @Candidates TABLE (VMID INT, Hostname VARCHAR(255));
    DECLARE @Now DATETIME = GETDATE(), @NowUtc DATETIME2(3) = SYSUTCDATETIME(), @Boot INT = 10, @LockResult INT;
    DECLARE @StartedTransaction BIT = 0;
    DECLARE @IsDryRun BIT = COALESCE(@DryRun, 0);
    DECLARE @PhaseAtUtc DATETIME2(0) = CASE
        WHEN COALESCE(@DryRun, 0) = 1 AND @AtUtc IS NOT NULL THEN @AtUtc
        ELSE CAST(SYSUTCDATETIME() AS DATETIME2(0))
    END;

    IF @IsDryRun = 0
    BEGIN
        IF @@TRANCOUNT = 0
        BEGIN
            BEGIN TRANSACTION;
            SET @StartedTransaction = 1;
        END
        ELSE
        BEGIN
            SAVE TRANSACTION ScalingLogicSave;
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
                ROLLBACK TRANSACTION ScalingLogicSave;
            END
            SELECT ActionType, VMName, VMID, StopMode, PreviousNetworkStatus, ActivityID FROM @Actions;
            RETURN;
        END
    END

    DECLARE @PhaseSource VARCHAR(16), @ScheduleID INT, @PhaseName NVARCHAR(64), @RuleID INT,
            @MinVMs INT, @MaxVMs INT, @ScaleUpRatio DECIMAL(5,2), @ScaleUpIncrement INT,
            @ScaleDownRatio DECIMAL(5,2), @ScaleDownIncrement INT, @StopMode VARCHAR(16),
            @TimeZone NVARCHAR(64), @LocalTime DATETIME2(0);
    DECLARE @OriginalMin INT, @OriginalMax INT, @OriginalUpInc INT, @OriginalDownInc INT;
    DECLARE @Surge BIT = 0;

    SELECT @PhaseSource = Source, @ScheduleID = ScheduleID, @PhaseName = PhaseName, @RuleID = RuleID,
           @MinVMs = MinVMs, @MaxVMs = MaxVMs, @ScaleUpRatio = ScaleUpRatio, @ScaleUpIncrement = ScaleUpIncrement,
           @ScaleDownRatio = ScaleDownRatio, @ScaleDownIncrement = ScaleDownIncrement,
           @StopMode = COALESCE(StopMode, 'PowerOff'), @TimeZone = TimeZone, @LocalTime = LocalTime
    FROM dbo.fnActiveScalingPhase(@PhaseAtUtc);

    IF @IsDryRun = 1 AND @OverrideJson IS NOT NULL AND ISJSON(@OverrideJson) = 1
    BEGIN
        SET @MinVMs = COALESCE(TRY_CAST(JSON_VALUE(@OverrideJson, '$.MinVMs') AS INT), @MinVMs);
        SET @MaxVMs = COALESCE(TRY_CAST(JSON_VALUE(@OverrideJson, '$.MaxVMs') AS INT), @MaxVMs);
        SET @ScaleUpRatio = COALESCE(TRY_CAST(JSON_VALUE(@OverrideJson, '$.ScaleUpRatio') AS DECIMAL(5,2)), @ScaleUpRatio);
        SET @ScaleUpIncrement = COALESCE(TRY_CAST(JSON_VALUE(@OverrideJson, '$.ScaleUpIncrement') AS INT), @ScaleUpIncrement);
        SET @ScaleDownRatio = COALESCE(TRY_CAST(JSON_VALUE(@OverrideJson, '$.ScaleDownRatio') AS DECIMAL(5,2)), @ScaleDownRatio);
        SET @ScaleDownIncrement = COALESCE(TRY_CAST(JSON_VALUE(@OverrideJson, '$.ScaleDownIncrement') AS INT), @ScaleDownIncrement);
        SET @StopMode = CASE WHEN JSON_VALUE(@OverrideJson, '$.StopMode') IN ('PowerOff', 'Deallocate')
                             THEN JSON_VALUE(@OverrideJson, '$.StopMode') ELSE COALESCE(@StopMode, 'PowerOff') END;
        SET @PhaseName = COALESCE(CAST(JSON_VALUE(@OverrideJson, '$.PhaseName') AS NVARCHAR(64)), @PhaseName, N'Proposed values');
        SET @PhaseSource = 'Proposed';
    END

    DECLARE @PoweredOn INT = 0, @Serviceable INT = 0, @InUse INT = 0, @Draining INT = 0, @Utilization DECIMAL(7,2) = 0,
            @Headroom INT = 0, @RequestCount INT = 0, @ActualOn INT = 0, @ActualOff INT = 0,
            @ActionTaken NVARCHAR(50) = N'No Action', @Outcome NVARCHAR(255), @Notes NVARCHAR(MAX),
            @Reason NVARCHAR(400), @Corrections NVARCHAR(600) = N'', @ActivityID INT, @Mode VARCHAR(8) = NULL;

    SELECT @PoweredOn = SUM(CASE WHEN PowerState = 'On' THEN 1 ELSE 0 END),
           -- Capacity a user can be given: an Available host must also pass CheckoutVm's test.
           @Serviceable = SUM(CASE WHEN PowerState = 'On' AND VmStatus <> 'Maintenance' AND DrainRequested = 0
                                    AND (NetworkStatus = 'Reachable' OR PowerStateChangedDate >= DATEADD(MINUTE, -@Boot, @Now))
                                    AND NOT (VmStatus = 'Available' AND (Username IS NOT NULL OR LeaseId IS NOT NULL))
                               THEN 1 ELSE 0 END),
           @InUse = SUM(CASE WHEN PowerState = 'On' AND DrainRequested = 0 AND (VmStatus IN ('CheckedOut', 'Released') OR CleanupPending = 1) THEN 1 ELSE 0 END),
           @Draining = SUM(CASE WHEN DrainRequested = 1 THEN 1 ELSE 0 END)
    FROM dbo.VirtualMachines;

    SET @PoweredOn = COALESCE(@PoweredOn, 0);
    SET @Serviceable = COALESCE(@Serviceable, 0);
    SET @InUse = COALESCE(@InUse, 0);
    SET @Draining = COALESCE(@Draining, 0);
    SET @Utilization = CASE WHEN @Serviceable = 0 THEN CASE WHEN @InUse > 0 THEN 100 ELSE 0 END ELSE CAST(@InUse * 100.0 / @Serviceable AS DECIMAL(7,2)) END;

    IF @MinVMs IS NULL OR @MaxVMs IS NULL
    BEGIN
        IF @IsDryRun = 1
        BEGIN
            SELECT CAST('None' AS VARCHAR(16)) AS Action, 0 AS RequestCount, 0 AS CandidateCount,
                   CAST(N'[]' AS NVARCHAR(MAX)) AS CandidatesJson, CAST(N'No scaling rule is configured.' AS NVARCHAR(400)) AS Reason,
                   CAST(NULL AS VARCHAR(16)) AS PhaseSource, CAST(NULL AS INT) AS ScheduleID, CAST(NULL AS NVARCHAR(64)) AS PhaseName,
                   CAST(NULL AS INT) AS MinVMs, CAST(NULL AS INT) AS MaxVMs, CAST(NULL AS DECIMAL(5,2)) AS ScaleUpRatio,
                   CAST(NULL AS INT) AS ScaleUpIncrement, CAST(NULL AS DECIMAL(5,2)) AS ScaleDownRatio, CAST(NULL AS INT) AS ScaleDownIncrement,
                   CAST(NULL AS VARCHAR(16)) AS StopMode, @PoweredOn AS PoweredOn, @Serviceable AS Serviceable, @InUse AS InUse,
                   @Draining AS Draining, @Utilization AS Utilization, @TimeZone AS TimeZone,
                   CONVERT(VARCHAR(19), @LocalTime, 126) AS LocalTime, CONVERT(VARCHAR(33), @PhaseAtUtc, 126) + 'Z' AS AtUtc,
                   CAST(0 AS BIT) AS MaintenanceSurge;
            RETURN;
        END

        INSERT INTO dbo.VmScalingActivityLog (CheckTimestamp, CurrentRunningVMs, CurrentInUseVMs, ActionTaken, VMsPoweredOn, VMsPoweredOff, NewTotalVMs, Outcome, Notes, ServiceableVMs, DrainingVMs)
        VALUES (@Now, @PoweredOn, @InUse, N'No Action', 0, 0, @PoweredOn, N'No scaling action was necessary', N'No scaling rule is configured.', @Serviceable, @Draining);
        IF @StartedTransaction = 1 COMMIT TRANSACTION;
        SELECT ActionType, VMName, VMID, StopMode, PreviousNetworkStatus, ActivityID FROM @Actions;
        RETURN;
    END

    SET @OriginalMin = @MinVMs; SET @OriginalMax = @MaxVMs; SET @OriginalUpInc = @ScaleUpIncrement; SET @OriginalDownInc = @ScaleDownIncrement;
    SET @MinVMs = CASE WHEN @MinVMs < 1 THEN 1 ELSE @MinVMs END;
    SET @MaxVMs = CASE WHEN @MaxVMs < @MinVMs THEN @MinVMs ELSE @MaxVMs END;
    SET @ScaleUpIncrement = CASE WHEN COALESCE(@ScaleUpIncrement, 0) < 1 THEN 1 ELSE @ScaleUpIncrement END;
    SET @ScaleDownIncrement = CASE WHEN COALESCE(@ScaleDownIncrement, 0) < 1 THEN 1 ELSE @ScaleDownIncrement END;

    IF @OriginalMin <> @MinVMs SET @Corrections = CONCAT(@Corrections, N' Corrected MinVMs from ', @OriginalMin, N' to ', @MinVMs, N'.');
    IF @OriginalMax <> @MaxVMs SET @Corrections = CONCAT(@Corrections, N' Corrected MaxVMs from ', @OriginalMax, N' to ', @MaxVMs, N'.');
    IF COALESCE(@OriginalUpInc, 0) <> @ScaleUpIncrement SET @Corrections = CONCAT(@Corrections, N' Corrected ScaleUpIncrement from ', @OriginalUpInc, N' to ', @ScaleUpIncrement, N'.');
    IF COALESCE(@OriginalDownInc, 0) <> @ScaleDownIncrement SET @Corrections = CONCAT(@Corrections, N' Corrected ScaleDownIncrement from ', @OriginalDownInc, N' to ', @ScaleDownIncrement, N'.');

    IF @MinVMs < @MaxVMs AND EXISTS (SELECT 1 FROM dbo.MaintenanceRuns WHERE Status = 'Active' AND SurgeRequested = 1)
    BEGIN
        SET @MinVMs = @MinVMs + 1;
        SET @Surge = 1;
    END

    SET @Headroom = @MaxVMs - @PoweredOn;

    IF @Serviceable < @MinVMs AND @Headroom > 0
    BEGIN
        SET @Mode = 'Up';
        SET @RequestCount = CASE WHEN @MinVMs - @Serviceable < @Headroom THEN @MinVMs - @Serviceable ELSE @Headroom END;
        SET @Reason = N'Serviceable hosts are below the minimum.';
    END
    ELSE IF @PoweredOn > @MaxVMs
    BEGIN
        -- The minimum wins: never stop so many that fewer than MinVMs hosts can take a user.
        SET @RequestCount = @PoweredOn - @MaxVMs;
        IF @RequestCount > @Serviceable - @MinVMs SET @RequestCount = @Serviceable - @MinVMs;

        IF @RequestCount > 0
        BEGIN
            SET @Mode = 'Down';
            SET @Reason = N'Powered-on hosts exceed the maximum.';
        END
        ELSE
        BEGIN
            SET @RequestCount = 0;
            SET @Reason = N'Powered-on hosts exceed the maximum, but stopping any would leave fewer serviceable hosts than the minimum.';
        END
    END
    ELSE IF @Utilization >= @ScaleUpRatio AND @Headroom > 0
    BEGIN
        SET @Mode = 'Up';
        SET @RequestCount = CASE WHEN @ScaleUpIncrement < @Headroom THEN @ScaleUpIncrement ELSE @Headroom END;
        SET @Reason = N'Utilization is at or above the scale-up ratio.';
    END
    ELSE IF @Utilization <= @ScaleDownRatio AND @Serviceable > @MinVMs
    BEGIN
        SET @Mode = 'Down';
        SET @RequestCount = CASE WHEN @ScaleDownIncrement < @Serviceable - @MinVMs THEN @ScaleDownIncrement ELSE @Serviceable - @MinVMs END;
        SET @Reason = N'Utilization is at or below the scale-down ratio.';
    END
    ELSE
    BEGIN
        SET @Reason = N'No scaling threshold was crossed.';
    END

    IF @Mode = 'Up' AND @RequestCount > 0
    BEGIN
        INSERT INTO @Candidates (VMID, Hostname)
        SELECT TOP (@RequestCount) VMID, Hostname
        FROM dbo.VirtualMachines WITH (UPDLOCK, ROWLOCK)
        WHERE PowerState = 'Off' AND VmStatus = 'Available' AND Username IS NULL AND LeaseId IS NULL AND DrainRequested = 0
        ORDER BY CleanupPending, VMID;
    END
    ELSE IF @Mode = 'Down' AND @RequestCount > 0
    BEGIN
        INSERT INTO @Candidates (VMID, Hostname)
        SELECT TOP (@RequestCount) VMID, Hostname
        FROM dbo.VirtualMachines WITH (UPDLOCK, ROWLOCK)
        WHERE PowerState = 'On' AND NetworkStatus = 'Reachable' AND VmStatus = 'Available'
          AND Username IS NULL AND LeaseId IS NULL AND CleanupPending = 0 AND DrainRequested = 0
          AND (PowerStateChangedDate IS NULL OR PowerStateChangedDate < DATEADD(MINUTE, -@Boot, @Now))
        ORDER BY VMID DESC;
    END

    IF @IsDryRun = 1
    BEGIN
        DECLARE @CandidateCount INT = (SELECT COUNT(*) FROM @Candidates);
        IF @RequestCount > 0 AND @CandidateCount < @RequestCount
        BEGIN
            SET @Reason = CONCAT(@Reason, N' Only ', @CandidateCount, N' of ', @RequestCount, N' requested hosts are available to ',
                                 CASE WHEN @Mode = 'Up' THEN N'start.' ELSE N'stop.' END);
        END

        SELECT CAST(CASE WHEN @Mode = 'Up' AND @CandidateCount > 0 THEN 'PowerOn'
                         WHEN @Mode = 'Down' AND @CandidateCount > 0 THEN 'PowerOff'
                         ELSE 'None' END AS VARCHAR(16)) AS Action,
               @RequestCount AS RequestCount,
               @CandidateCount AS CandidateCount,
               COALESCE((SELECT Hostname FROM @Candidates ORDER BY Hostname FOR JSON PATH), N'[]') AS CandidatesJson,
               @Reason AS Reason,
               @PhaseSource AS PhaseSource, @ScheduleID AS ScheduleID, @PhaseName AS PhaseName,
               @MinVMs AS MinVMs, @MaxVMs AS MaxVMs, @ScaleUpRatio AS ScaleUpRatio, @ScaleUpIncrement AS ScaleUpIncrement,
               @ScaleDownRatio AS ScaleDownRatio, @ScaleDownIncrement AS ScaleDownIncrement, @StopMode AS StopMode,
               @PoweredOn AS PoweredOn, @Serviceable AS Serviceable, @InUse AS InUse, @Draining AS Draining,
               @Utilization AS Utilization, @TimeZone AS TimeZone,
               CONVERT(VARCHAR(19), @LocalTime, 126) AS LocalTime, CONVERT(VARCHAR(33), @PhaseAtUtc, 126) + 'Z' AS AtUtc,
               @Surge AS MaintenanceSurge;
        RETURN;
    END

    IF @Mode = 'Up' AND @RequestCount > 0
    BEGIN
        UPDATE vm
        SET PowerState = 'On', NetworkStatus = 'Unreachable', PowerStateChangedDate = @Now, StartRequestedAt = @NowUtc, LastUpdateDate = @Now
        OUTPUT 'PowerOn', INSERTED.Hostname, INSERTED.VMID, NULL, DELETED.NetworkStatus, NULL
        INTO @Actions (ActionType, VMName, VMID, StopMode, PreviousNetworkStatus, ActivityID)
        FROM dbo.VirtualMachines vm INNER JOIN @Candidates c ON c.VMID = vm.VMID;

        SET @ActualOn = @@ROWCOUNT;
        SET @ActionTaken = CASE WHEN @ActualOn > 0 THEN N'Scale Up' ELSE N'No Action' END;
        SET @Outcome = CASE WHEN @ActualOn > 0 THEN CONCAT(N'Requested power-on of ', @ActualOn, N' VM(s)') ELSE N'No scaling action was necessary' END;
        IF @ActualOn < @RequestCount SET @Reason = CONCAT(@Reason, N' Only ', @ActualOn, N' of ', @RequestCount, N' requested hosts were available to start.');
    END
    ELSE IF @Mode = 'Down' AND @RequestCount > 0
    BEGIN
        UPDATE vm
        SET PowerState = 'Off', NetworkStatus = 'Unreachable', PowerStateChangedDate = @Now, StartRequestedAt = NULL, LastUpdateDate = @Now
        OUTPUT 'PowerOff', INSERTED.Hostname, INSERTED.VMID, @StopMode, DELETED.NetworkStatus, NULL
        INTO @Actions (ActionType, VMName, VMID, StopMode, PreviousNetworkStatus, ActivityID)
        FROM dbo.VirtualMachines vm INNER JOIN @Candidates c ON c.VMID = vm.VMID;

        SET @ActualOff = @@ROWCOUNT;
        SET @ActionTaken = CASE WHEN @ActualOff > 0 THEN N'Scale Down' ELSE N'No Action' END;
        SET @Outcome = CASE WHEN @ActualOff > 0 AND @StopMode = 'Deallocate' THEN CONCAT(N'Requested deallocation of ', @ActualOff, N' VM(s)') WHEN @ActualOff > 0 THEN CONCAT(N'Requested power-off of ', @ActualOff, N' VM(s)') ELSE N'No scaling action was necessary' END;
        IF @ActualOff < @RequestCount SET @Reason = CONCAT(@Reason, N' Only ', @ActualOff, N' of ', @RequestCount, N' requested hosts were available to stop.');
    END
    ELSE
    BEGIN
        SET @Outcome = N'No scaling action was necessary';
    END

    SET @Notes = CONCAT(N'Rule Min=', @MinVMs, N', Max=', @MaxVMs, N', UpRatio=', @ScaleUpRatio, N', DownRatio=', @ScaleDownRatio,
        N', UpIncrement=', @ScaleUpIncrement, N', DownIncrement=', @ScaleDownIncrement, N'. Counts poweredOn=', @PoweredOn,
        N', serviceable=', @Serviceable, N', inUse=', @InUse, N', draining=', @Draining, N', utilization=', @Utilization, N'%. ', @Reason, @Corrections,
        N' Phase=', COALESCE(@PhaseName, N'Default rule'), N'.',
        CASE WHEN @Surge = 1 THEN N' A maintenance run asked for one more ready host.' ELSE N'' END);

    INSERT INTO dbo.VmScalingActivityLog (CheckTimestamp, CurrentRunningVMs, CurrentInUseVMs, ActionTaken, VMsPoweredOn, VMsPoweredOff, NewTotalVMs, Outcome, Notes,
                                          PhaseName, ScheduleID, MinVMs, MaxVMs, ServiceableVMs, DrainingVMs)
    VALUES (@Now, @PoweredOn, @InUse, @ActionTaken, @ActualOn, @ActualOff, @PoweredOn + @ActualOn - @ActualOff, @Outcome, @Notes,
            @PhaseName, @ScheduleID, @MinVMs, @MaxVMs, @Serviceable, @Draining);

    SET @ActivityID = SCOPE_IDENTITY();
    UPDATE @Actions SET ActivityID = @ActivityID;
    -- VmScalingRules.LastChecked is deliberately not updated: the table is system-versioned,
    -- so a write on every run would add a history row every few minutes and bury real rule
    -- edits. VmScalingActivityLog.CheckTimestamp already records each run.
    IF @StartedTransaction = 1 COMMIT TRANSACTION;

    SELECT ActionType, VMName, VMID, StopMode, PreviousNetworkStatus, ActivityID
    FROM @Actions
    ORDER BY CASE WHEN ActionType = 'PowerOn' THEN 0 ELSE 1 END, VMID;
END
GO
