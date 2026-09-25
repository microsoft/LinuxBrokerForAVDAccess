-- Changes a maintenance run's status:
--   pause     Active -> Paused. No host is admitted or started on a new step; hosts already
--             being patched or restarted finish.
--   resume    Paused -> Active.
--   cancel    Active or Paused -> Stopping, ending Cancelled.
--   fail      Active or Paused -> Stopping, ending Failed (too many hosts failed).
--   complete  Active -> Completed, once no host is pending or in progress.
--   finish    Stopping -> its end status, once no host is in progress.
-- Stopping cancels the hosts still pending at once; the scheduled advance returns the hosts
-- waiting for their users and lets the rest finish. Every change clears the scaling surge.
--
-- Result: Updated, Unchanged, InvalidState or NotFound, with the run's summary.

CREATE PROCEDURE [dbo].[SetMaintenanceRunStatus]
    @RunID INT,
    @Action VARCHAR(16),
    @Reason NVARCHAR(400) = NULL,
    @UpdatedBy NVARCHAR(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @Status VARCHAR(16), @EndStatus VARCHAR(16), @Result VARCHAR(16) = 'InvalidState';
    DECLARE @StartedTransaction BIT = 0;
    DECLARE @Busy BIT;

    IF @@TRANCOUNT = 0
    BEGIN
        BEGIN TRANSACTION;
        SET @StartedTransaction = 1;
    END

    SELECT @Status = Status, @EndStatus = EndStatus
    FROM dbo.MaintenanceRuns WITH (UPDLOCK, HOLDLOCK)
    WHERE RunID = @RunID;

    IF @Status IS NULL
    BEGIN
        SET @Result = 'NotFound';
    END
    ELSE IF @Action = 'pause'
    BEGIN
        IF @Status = 'Paused' SET @Result = 'Unchanged';
        ELSE IF @Status = 'Active'
        BEGIN
            UPDATE dbo.MaintenanceRuns
            SET Status = 'Paused', SurgeRequested = 0, WaitReason = NULL, StatusReason = LEFT(@Reason, 400),
                UpdatedBy = @UpdatedBy, UpdatedAt = @Now
            WHERE RunID = @RunID;
            SET @Result = 'Updated';
        END
    END
    ELSE IF @Action = 'resume'
    BEGIN
        IF @Status = 'Active' SET @Result = 'Unchanged';
        ELSE IF @Status = 'Paused'
        BEGIN
            UPDATE dbo.MaintenanceRuns
            SET Status = 'Active', StatusReason = NULL, UpdatedBy = @UpdatedBy, UpdatedAt = @Now
            WHERE RunID = @RunID;
            SET @Result = 'Updated';
        END
    END
    ELSE IF @Action IN ('cancel', 'fail')
    BEGIN
        IF @Status = 'Stopping' SET @Result = 'Unchanged';
        ELSE IF @Status IN ('Active', 'Paused')
        BEGIN
            UPDATE dbo.MaintenanceRuns
            SET Status = 'Stopping',
                EndStatus = CASE WHEN @Action = 'cancel' THEN 'Cancelled' ELSE 'Failed' END,
                SurgeRequested = 0, WaitReason = NULL, StatusReason = LEFT(@Reason, 400),
                UpdatedBy = @UpdatedBy, UpdatedAt = @Now
            WHERE RunID = @RunID;

            UPDATE dbo.MaintenanceRunHosts
            SET State = 'Cancelled',
                Detail = CASE WHEN @Action = 'cancel' THEN N'The run was cancelled before this host was started.'
                              ELSE N'The run stopped after too many hosts failed.' END,
                CompletedAt = @Now, Version = Version + 1, UpdatedAt = @Now
            WHERE RunID = @RunID AND State = 'Pending';
            SET @Result = 'Updated';
        END
    END
    ELSE IF @Action IN ('complete', 'finish')
    BEGIN
        SELECT @Busy = CASE WHEN EXISTS (
            SELECT 1 FROM dbo.MaintenanceRunHosts
            WHERE RunID = @RunID
              AND (State IN ('Draining', 'Starting', 'Patching', 'Restarting', 'Verifying')
                   OR (@Action = 'complete' AND State = 'Pending'))
        ) THEN 1 ELSE 0 END;

        IF @Busy = 0 AND ((@Action = 'complete' AND @Status = 'Active') OR (@Action = 'finish' AND @Status = 'Stopping'))
        BEGIN
            UPDATE dbo.MaintenanceRuns
            SET Status = CASE WHEN @Action = 'complete' THEN 'Completed' ELSE COALESCE(EndStatus, 'Cancelled') END,
                EndStatus = CASE WHEN @Action = 'complete' THEN 'Completed' ELSE COALESCE(EndStatus, 'Cancelled') END,
                SurgeRequested = 0, WaitReason = NULL,
                StatusReason = COALESCE(LEFT(@Reason, 400), StatusReason),
                TickToken = NULL, TickLeaseUntil = NULL, EndedAt = @Now, UpdatedAt = @Now
            WHERE RunID = @RunID;
            SET @Result = 'Updated';
        END
    END

    IF @StartedTransaction = 1 COMMIT TRANSACTION;

    SELECT @Result AS Result, s.*
    FROM (SELECT 1 AS One) one
    LEFT JOIN dbo.fnMaintenanceRunSummary() s ON s.RunID = @RunID;
END
GO
