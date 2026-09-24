-- Redefines dbo.TriggerScalingLogic to respect drain.
--
-- A draining host is leaving the pool: it is not counted as serviceable or in use, and is
-- never selected to start or stop. Counting it would let a drained pool look healthy while no
-- host can accept a new user; leaving it out makes the scaler bring up replacement capacity,
-- within MaxVMs. Powered-on draining hosts still count toward MaxVMs, which caps cost. The
-- result columns are unchanged.

CREATE PROCEDURE [dbo].[TriggerScalingLogic]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Actions TABLE (
        ActionType VARCHAR(16), VMName VARCHAR(255), VMID INT,
        StopMode VARCHAR(16), PreviousNetworkStatus VARCHAR(16), ActivityID INT NULL
    );
    DECLARE @Now DATETIME = GETDATE(), @Boot INT = 10, @LockResult INT;
    DECLARE @StartedTransaction BIT = 0;

    IF @@TRANCOUNT = 0
    BEGIN
        BEGIN TRANSACTION;
        SET @StartedTransaction = 1;
    END
    ELSE
    BEGIN
        SAVE TRANSACTION ScalingLogicSave;
    END
    EXEC @LockResult = sp_getapplock @Resource = 'LinuxBroker.Scaling', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 0;

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

    DECLARE @RuleID INT, @MinVMs INT, @MaxVMs INT, @ScaleUpRatio DECIMAL(5,2), @ScaleUpIncrement INT,
            @ScaleDownRatio DECIMAL(5,2), @ScaleDownIncrement INT, @StopMode VARCHAR(16);
    DECLARE @OriginalMin INT, @OriginalMax INT, @OriginalUpInc INT, @OriginalDownInc INT;

    SELECT TOP 1 @RuleID = RuleID, @MinVMs = MinVMs, @MaxVMs = MaxVMs,
           @ScaleUpRatio = ScaleUpRatio, @ScaleUpIncrement = ScaleUpIncrement,
           @ScaleDownRatio = ScaleDownRatio, @ScaleDownIncrement = ScaleDownIncrement,
           @StopMode = COALESCE(StopMode, 'PowerOff')
    FROM dbo.VmScalingRules WITH (UPDLOCK, HOLDLOCK)
    ORDER BY RuleID;

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

    IF @RuleID IS NULL
    BEGIN
        INSERT INTO dbo.VmScalingActivityLog (CheckTimestamp, CurrentRunningVMs, CurrentInUseVMs, ActionTaken, VMsPoweredOn, VMsPoweredOff, NewTotalVMs, Outcome, Notes)
        VALUES (@Now, @PoweredOn, @InUse, N'No Action', 0, 0, @PoweredOn, N'No scaling action was necessary', N'No scaling rule is configured.');
        IF @StartedTransaction = 1 COMMIT TRANSACTION;
        SELECT ActionType, VMName, VMID, StopMode, PreviousNetworkStatus, ActivityID FROM @Actions;
        RETURN;
    END

    SET @OriginalMin = @MinVMs; SET @OriginalMax = @MaxVMs; SET @OriginalUpInc = @ScaleUpIncrement; SET @OriginalDownInc = @ScaleDownIncrement;
    SET @MinVMs = CASE WHEN @MinVMs < 1 THEN 1 ELSE @MinVMs END;
    SET @MaxVMs = CASE WHEN @MaxVMs < @MinVMs THEN @MinVMs ELSE @MaxVMs END;
    SET @ScaleUpIncrement = CASE WHEN @ScaleUpIncrement < 1 THEN 1 ELSE @ScaleUpIncrement END;
    SET @ScaleDownIncrement = CASE WHEN @ScaleDownIncrement < 1 THEN 1 ELSE @ScaleDownIncrement END;

    IF @OriginalMin <> @MinVMs SET @Corrections = CONCAT(@Corrections, N' Corrected MinVMs from ', @OriginalMin, N' to ', @MinVMs, N'.');
    IF @OriginalMax <> @MaxVMs SET @Corrections = CONCAT(@Corrections, N' Corrected MaxVMs from ', @OriginalMax, N' to ', @MaxVMs, N'.');
    IF @OriginalUpInc <> @ScaleUpIncrement SET @Corrections = CONCAT(@Corrections, N' Corrected ScaleUpIncrement from ', @OriginalUpInc, N' to ', @ScaleUpIncrement, N'.');
    IF @OriginalDownInc <> @ScaleDownIncrement SET @Corrections = CONCAT(@Corrections, N' Corrected ScaleDownIncrement from ', @OriginalDownInc, N' to ', @ScaleDownIncrement, N'.');

    SET @Headroom = @MaxVMs - @PoweredOn;

    IF @Serviceable < @MinVMs AND @Headroom > 0
    BEGIN
        SET @Mode = 'Up';
        SET @RequestCount = CASE WHEN @MinVMs - @Serviceable < @Headroom THEN @MinVMs - @Serviceable ELSE @Headroom END;
        SET @Reason = N'Serviceable hosts are below the minimum.';
    END
    ELSE IF @PoweredOn > @MaxVMs
    BEGIN
        SET @Mode = 'Down';
        SET @RequestCount = @PoweredOn - @MaxVMs;
        SET @Reason = N'Powered-on hosts exceed the maximum.';
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
        ;WITH Candidates AS (
            SELECT TOP (@RequestCount) VMID
            FROM dbo.VirtualMachines WITH (UPDLOCK, ROWLOCK)
            WHERE PowerState = 'Off' AND VmStatus = 'Available' AND Username IS NULL AND LeaseId IS NULL AND DrainRequested = 0
            ORDER BY CleanupPending, VMID
        )
        UPDATE vm
        SET PowerState = 'On', NetworkStatus = 'Unreachable', PowerStateChangedDate = @Now, LastUpdateDate = @Now
        OUTPUT 'PowerOn', INSERTED.Hostname, INSERTED.VMID, NULL, DELETED.NetworkStatus, NULL
        INTO @Actions (ActionType, VMName, VMID, StopMode, PreviousNetworkStatus, ActivityID)
        FROM dbo.VirtualMachines vm INNER JOIN Candidates c ON c.VMID = vm.VMID;

        SET @ActualOn = @@ROWCOUNT;
        SET @ActionTaken = CASE WHEN @ActualOn > 0 THEN N'Scale Up' ELSE N'No Action' END;
        SET @Outcome = CASE WHEN @ActualOn > 0 THEN CONCAT(N'Requested power-on of ', @ActualOn, N' VM(s)') ELSE N'No scaling action was necessary' END;
        IF @ActualOn < @RequestCount SET @Reason = CONCAT(@Reason, N' Only ', @ActualOn, N' of ', @RequestCount, N' requested hosts were available to start.');
    END
    ELSE IF @Mode = 'Down' AND @RequestCount > 0
    BEGIN
        ;WITH Candidates AS (
            SELECT TOP (@RequestCount) VMID
            FROM dbo.VirtualMachines WITH (UPDLOCK, ROWLOCK)
            WHERE PowerState = 'On' AND NetworkStatus = 'Reachable' AND VmStatus = 'Available'
              AND Username IS NULL AND LeaseId IS NULL AND CleanupPending = 0 AND DrainRequested = 0
              AND (PowerStateChangedDate IS NULL OR PowerStateChangedDate < DATEADD(MINUTE, -@Boot, @Now))
            ORDER BY VMID DESC
        )
        UPDATE vm
        SET PowerState = 'Off', NetworkStatus = 'Unreachable', PowerStateChangedDate = @Now, LastUpdateDate = @Now
        OUTPUT 'PowerOff', INSERTED.Hostname, INSERTED.VMID, @StopMode, DELETED.NetworkStatus, NULL
        INTO @Actions (ActionType, VMName, VMID, StopMode, PreviousNetworkStatus, ActivityID)
        FROM dbo.VirtualMachines vm INNER JOIN Candidates c ON c.VMID = vm.VMID;

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
        N', serviceable=', @Serviceable, N', inUse=', @InUse, N', draining=', @Draining, N', utilization=', @Utilization, N'%. ', @Reason, @Corrections);

    INSERT INTO dbo.VmScalingActivityLog (CheckTimestamp, CurrentRunningVMs, CurrentInUseVMs, ActionTaken, VMsPoweredOn, VMsPoweredOff, NewTotalVMs, Outcome, Notes)
    VALUES (@Now, @PoweredOn, @InUse, @ActionTaken, @ActualOn, @ActualOff, @PoweredOn + @ActualOn - @ActualOff, @Outcome, @Notes);

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
