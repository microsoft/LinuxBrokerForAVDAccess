-- The scaling policy for the portal: the time zone, the local time there, and the values in
-- force now (dbo.fnActiveScalingPhase). One row; the Active* columns are NULL when there is
-- neither a default rule nor a matching window.

CREATE PROCEDURE [dbo].[GetScalingPolicy]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @NowUtc DATETIME2(0) = CAST(SYSUTCDATETIME() AS DATETIME2(0));

    SELECT
        p.TimeZone,
        p.UpdatedBy,
        CONVERT(VARCHAR(33), p.UpdatedAt, 126) + 'Z' AS UpdatedAtUtc,
        CONVERT(VARCHAR(33), @NowUtc, 126) + 'Z' AS NowUtc,
        CONVERT(VARCHAR(19), CAST(TODATETIMEOFFSET(@NowUtc, 0) AT TIME ZONE p.TimeZone AS DATETIME2(0)), 126) AS LocalTime,
        phase.Source AS ActiveSource,
        phase.ScheduleID AS ActiveScheduleID,
        phase.PhaseName AS ActivePhaseName,
        phase.MinVMs AS ActiveMinVMs,
        phase.MaxVMs AS ActiveMaxVMs,
        phase.ScaleUpRatio AS ActiveScaleUpRatio,
        phase.ScaleUpIncrement AS ActiveScaleUpIncrement,
        phase.ScaleDownRatio AS ActiveScaleDownRatio,
        phase.ScaleDownIncrement AS ActiveScaleDownIncrement,
        phase.StopMode AS ActiveStopMode,
        phase.RuleID AS DefaultRuleID
    FROM dbo.ScalingPolicy p
    OUTER APPLY dbo.fnActiveScalingPhase(@NowUtc) phase
    WHERE p.PolicyID = 1;
END
GO
