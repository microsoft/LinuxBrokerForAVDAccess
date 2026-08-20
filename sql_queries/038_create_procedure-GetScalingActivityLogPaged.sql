-- Adds a paged scaling activity reader with an in-band TotalCount for API pagination.
--
-- This lives after 002 creates dbo.VmScalingActivityLog so fresh deployments validate the
-- referenced columns before the procedure is created.

CREATE PROCEDURE [dbo].[GetScalingActivityLogPaged]
    @StartDate NVARCHAR(10) = NULL,
    @EndDate NVARCHAR(10) = NULL,
    @Offset INT = 0,
    @PageSize INT = 50
AS
BEGIN
    -- Paging determines result size; there is intentionally no @Limit parameter here.
    -- NULL dates, empty strings, or malformed MM/DD/YYYY strings become no filter.
    DECLARE @ConvertedStartDate DATETIME2 = TRY_CONVERT(DATETIME2, NULLIF(LTRIM(RTRIM(@StartDate)), ''), 101);
    DECLARE @ConvertedEndDate DATETIME2 = TRY_CONVERT(DATETIME2, NULLIF(LTRIM(RTRIM(@EndDate)), ''), 101);
    DECLARE @SafeOffset INT = CASE WHEN @Offset IS NULL OR @Offset < 0 THEN 0 ELSE @Offset END;
    DECLARE @SafePageSize INT = CASE WHEN @PageSize IS NULL OR @PageSize < 1 OR @PageSize > 200 THEN 50 ELSE @PageSize END;

    WITH MatchingRows AS (
        SELECT
            ActivityID,
            CheckTimestamp,
            CurrentRunningVMs,
            CurrentInUseVMs,
            ActionTaken,
            VMsPoweredOn,
            VMsPoweredOff,
            NewTotalVMs,
            Outcome,
            Notes,
            COUNT(*) OVER () AS TotalCount
        FROM dbo.VmScalingActivityLog
        WHERE (@ConvertedStartDate IS NULL OR CheckTimestamp >= @ConvertedStartDate)
          AND (@ConvertedEndDate IS NULL OR CheckTimestamp <= @ConvertedEndDate)
    )
    SELECT
        ActivityID,
        CheckTimestamp,
        CurrentRunningVMs,
        CurrentInUseVMs,
        ActionTaken,
        VMsPoweredOn,
        VMsPoweredOff,
        NewTotalVMs,
        Outcome,
        Notes,
        TotalCount
    FROM MatchingRows
    ORDER BY CheckTimestamp DESC, ActivityID DESC
    OFFSET @SafeOffset ROWS
    FETCH NEXT @SafePageSize ROWS ONLY;
END
GO
