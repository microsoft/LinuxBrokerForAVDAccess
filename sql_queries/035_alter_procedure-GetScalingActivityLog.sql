-- Re-defines scaling activity history date filtering to parse MM/DD/YYYY explicitly.
--
-- This must be separate from 013 because deployments run files in numeric order and reruns
-- are applied as CREATE OR ALTER PROCEDURE by the bootstrap script.

CREATE PROCEDURE [dbo].[GetScalingActivityLog]
    @StartDate NVARCHAR(10) = NULL,
    @EndDate NVARCHAR(10) = NULL,
    @Limit INT = NULL
AS
BEGIN
    DECLARE @ConvertedStartDate DATETIME2 = TRY_CONVERT(DATETIME2, NULLIF(LTRIM(RTRIM(@StartDate)), ''), 101);
    DECLARE @ConvertedEndDate DATETIME2 = TRY_CONVERT(DATETIME2, NULLIF(LTRIM(RTRIM(@EndDate)), ''), 101);
    DECLARE @EffectiveLimit INT = CASE WHEN @Limit IS NULL OR @Limit < 1 THEN 1000 ELSE @Limit END;

    SELECT TOP (@EffectiveLimit)
        ActivityID,
        CheckTimestamp,
        CurrentRunningVMs,
        CurrentInUseVMs,
        ActionTaken,
        VMsPoweredOn,
        VMsPoweredOff,
        NewTotalVMs,
        Outcome,
        Notes
    FROM dbo.VmScalingActivityLog
    WHERE (@ConvertedStartDate IS NULL OR CheckTimestamp >= @ConvertedStartDate)
      AND (@ConvertedEndDate IS NULL OR CheckTimestamp <= @ConvertedEndDate)
    ORDER BY CheckTimestamp DESC, ActivityID DESC;
END
GO
