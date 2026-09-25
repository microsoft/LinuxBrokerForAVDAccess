-- Creates a schedule window (@ScheduleID NULL) or replaces one. The values are validated as the
-- API validates them, and an enabled window may not overlap another enabled window: the check
-- and the write run under an application lock, so two saves cannot both pass it.
--
-- Result: Created, Updated, NotFound, Overlap (with the window it overlaps), or Invalid (with
-- a Message naming the field).

CREATE PROCEDURE [dbo].[SaveScalingSchedule]
    @ScheduleID INT = NULL,
    @Name NVARCHAR(64),
    @Enabled BIT = 1,
    @DaysOfWeek TINYINT,
    @StartTime TIME(0),
    @EndTime TIME(0),
    @MinVMs INT,
    @MaxVMs INT,
    @ScaleUpRatio DECIMAL(5,2),
    @ScaleUpIncrement INT,
    @ScaleDownRatio DECIMAL(5,2),
    @ScaleDownIncrement INT,
    @StopMode VARCHAR(16) = NULL,
    @UpdatedBy NVARCHAR(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Message NVARCHAR(200) = NULL;
    DECLARE @CleanName NVARCHAR(64) = LTRIM(RTRIM(@Name));
    DECLARE @OverlapID INT;
    DECLARE @OverlapName NVARCHAR(64);
    DECLARE @LockResult INT;
    DECLARE @StartedTransaction BIT = 0;
    DECLARE @SavedID INT = @ScheduleID;

    SET @Message = CASE
        WHEN @CleanName IS NULL OR @CleanName = N'' THEN N'name is required.'
        WHEN @DaysOfWeek IS NULL OR @DaysOfWeek < 1 OR @DaysOfWeek > 127 THEN N'Choose at least one day.'
        WHEN @StartTime IS NULL OR @EndTime IS NULL THEN N'start and end are required.'
        WHEN @StartTime = @EndTime THEN N'start and end must differ.'
        WHEN @MinVMs IS NULL OR @MinVMs < 1 THEN N'minvms must be at least 1.'
        WHEN @MaxVMs IS NULL OR @MaxVMs <= @MinVMs THEN N'maxvms must be greater than minvms.'
        WHEN @ScaleUpRatio IS NULL OR @ScaleUpRatio < 0 OR @ScaleUpRatio > 100 THEN N'scaleupratio must be between 0 and 100.'
        WHEN @ScaleDownRatio IS NULL OR @ScaleDownRatio < 0 OR @ScaleDownRatio > 100 THEN N'scaledownratio must be between 0 and 100.'
        WHEN @ScaleUpRatio <= @ScaleDownRatio THEN N'scaleupratio must be greater than scaledownratio.'
        WHEN @ScaleUpIncrement IS NULL OR @ScaleUpIncrement < 1 THEN N'scaleupincrement must be at least 1.'
        WHEN @ScaleDownIncrement IS NULL OR @ScaleDownIncrement < 1 THEN N'scaledownincrement must be at least 1.'
        WHEN @StopMode IS NOT NULL AND @StopMode NOT IN ('PowerOff', 'Deallocate') THEN N'stopmode must be PowerOff or Deallocate.'
        ELSE NULL
    END;

    IF @Message IS NOT NULL
    BEGIN
        SELECT CAST('Invalid' AS VARCHAR(24)) AS Result, @Message AS Message,
               CAST(NULL AS INT) AS ScheduleID, CAST(NULL AS INT) AS OverlapsScheduleID, CAST(NULL AS NVARCHAR(64)) AS OverlapsName;
        RETURN;
    END

    IF @@TRANCOUNT = 0
    BEGIN
        BEGIN TRANSACTION;
        SET @StartedTransaction = 1;
    END

    EXEC @LockResult = sp_getapplock @Resource = 'LinuxBroker.ScalingSchedules', @LockMode = 'Exclusive',
        @LockOwner = 'Transaction', @LockTimeout = 10000;

    IF @LockResult < 0
    BEGIN
        IF @StartedTransaction = 1 ROLLBACK TRANSACTION;
        SELECT CAST('Busy' AS VARCHAR(24)) AS Result, N'Scaling schedules are busy. Please try again.' AS Message,
               CAST(NULL AS INT) AS ScheduleID, CAST(NULL AS INT) AS OverlapsScheduleID, CAST(NULL AS NVARCHAR(64)) AS OverlapsName;
        RETURN;
    END

    IF @ScheduleID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.ScalingSchedules WHERE ScheduleID = @ScheduleID)
    BEGIN
        IF @StartedTransaction = 1 COMMIT TRANSACTION;
        SELECT CAST('NotFound' AS VARCHAR(24)) AS Result, CAST(NULL AS NVARCHAR(200)) AS Message,
               @ScheduleID AS ScheduleID, CAST(NULL AS INT) AS OverlapsScheduleID, CAST(NULL AS NVARCHAR(64)) AS OverlapsName;
        RETURN;
    END

    IF COALESCE(@Enabled, 1) = 1
    BEGIN
        SELECT TOP 1 @OverlapID = s.ScheduleID, @OverlapName = s.Name
        FROM dbo.ScalingSchedules s
        CROSS APPLY dbo.fnScheduleWeekIntervals(s.DaysOfWeek, s.StartTime, s.EndTime) existing
        CROSS APPLY dbo.fnScheduleWeekIntervals(@DaysOfWeek, @StartTime, @EndTime) proposed
        WHERE s.Enabled = 1
          AND (@ScheduleID IS NULL OR s.ScheduleID <> @ScheduleID)
          AND existing.StartMinute < proposed.EndMinute
          AND proposed.StartMinute < existing.EndMinute
        ORDER BY s.ScheduleID;

        IF @OverlapID IS NOT NULL
        BEGIN
            IF @StartedTransaction = 1 COMMIT TRANSACTION;
            SELECT CAST('Overlap' AS VARCHAR(24)) AS Result, CAST(NULL AS NVARCHAR(200)) AS Message,
                   @ScheduleID AS ScheduleID, @OverlapID AS OverlapsScheduleID, @OverlapName AS OverlapsName;
            RETURN;
        END
    END

    IF @ScheduleID IS NULL
    BEGIN
        INSERT INTO dbo.ScalingSchedules (
            Name, Enabled, DaysOfWeek, StartTime, EndTime, MinVMs, MaxVMs, ScaleUpRatio, ScaleUpIncrement,
            ScaleDownRatio, ScaleDownIncrement, StopMode, UpdatedBy
        )
        VALUES (
            @CleanName, COALESCE(@Enabled, 1), @DaysOfWeek, @StartTime, @EndTime, @MinVMs, @MaxVMs, @ScaleUpRatio,
            @ScaleUpIncrement, @ScaleDownRatio, @ScaleDownIncrement, @StopMode, @UpdatedBy
        );
        SET @SavedID = CAST(SCOPE_IDENTITY() AS INT);
    END
    ELSE
    BEGIN
        UPDATE dbo.ScalingSchedules
        SET Name = @CleanName,
            Enabled = COALESCE(@Enabled, 1),
            DaysOfWeek = @DaysOfWeek,
            StartTime = @StartTime,
            EndTime = @EndTime,
            MinVMs = @MinVMs,
            MaxVMs = @MaxVMs,
            ScaleUpRatio = @ScaleUpRatio,
            ScaleUpIncrement = @ScaleUpIncrement,
            ScaleDownRatio = @ScaleDownRatio,
            ScaleDownIncrement = @ScaleDownIncrement,
            StopMode = @StopMode,
            UpdatedBy = @UpdatedBy
        WHERE ScheduleID = @ScheduleID;
    END

    IF @StartedTransaction = 1 COMMIT TRANSACTION;

    SELECT CAST(CASE WHEN @ScheduleID IS NULL THEN 'Created' ELSE 'Updated' END AS VARCHAR(24)) AS Result,
           CAST(NULL AS NVARCHAR(200)) AS Message,
           @SavedID AS ScheduleID,
           CAST(NULL AS INT) AS OverlapsScheduleID,
           CAST(NULL AS NVARCHAR(64)) AS OverlapsName;
END
GO
