CREATE PROCEDURE [dbo].[GetScalingActivityLog]
    @StartDate DATETIME = NULL,  -- Optional filter by start date
    @EndDate DATETIME = NULL,    -- Optional filter by end date
    @Limit INT = NULL            -- Optional limit on the number of records to retrieve
AS
BEGIN
    SELECT TOP (ISNULL(@Limit, 1000)) -- Default to 1000 records if no limit is provided
        ActivityID, CheckTimestamp, CurrentRunningVMs, CurrentInUseVMs, 
        ActionTaken, VMsPoweredOn, VMsPoweredOff, NewTotalVMs, Outcome, Notes
    FROM dbo.VmScalingActivityLog
    WHERE (@StartDate IS NULL OR CheckTimestamp >= @StartDate)
      AND (@EndDate IS NULL OR CheckTimestamp <= @EndDate)
    ORDER BY CheckTimestamp DESC; -- Most recent first
END
GO
