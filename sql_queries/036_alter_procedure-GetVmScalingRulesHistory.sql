-- Re-defines scaling rule history date filtering to parse MM/DD/YYYY explicitly.
--
-- This must be separate from 021 because deployments run files in numeric order and reruns
-- are applied as CREATE OR ALTER PROCEDURE by the bootstrap script.

CREATE PROCEDURE [dbo].[GetVmScalingRulesHistory]
    @StartDate NVARCHAR(10) = NULL,
    @EndDate NVARCHAR(10) = NULL,
    @Limit INT = 100
AS
BEGIN
    DECLARE @ConvertedStartDate DATETIME2 = TRY_CONVERT(DATETIME2, NULLIF(LTRIM(RTRIM(@StartDate)), ''), 101);
    DECLARE @ConvertedEndDate DATETIME2 = TRY_CONVERT(DATETIME2, NULLIF(LTRIM(RTRIM(@EndDate)), ''), 101);
    DECLARE @EffectiveLimit INT = CASE WHEN @Limit IS NULL OR @Limit < 1 THEN 100 ELSE @Limit END;

    SELECT
        RuleID,
        MinVMs,
        MaxVMs,
        ScaleUpRatio,
        ScaleUpIncrement,
        ScaleDownRatio,
        ScaleDownIncrement,
        LastChecked,
        SysStartTime,
        SysEndTime
    FROM dbo.VmScalingRulesHistory
    WHERE (@ConvertedStartDate IS NULL OR SysStartTime >= @ConvertedStartDate)
      AND (@ConvertedEndDate IS NULL OR SysEndTime <= @ConvertedEndDate)
    ORDER BY SysStartTime DESC, SysEndTime DESC, RuleID DESC
    OFFSET 0 ROWS
    FETCH NEXT @EffectiveLimit ROWS ONLY;
END
GO
