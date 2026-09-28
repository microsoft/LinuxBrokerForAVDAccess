-- Redefines dbo.GetScalingPolicy (105) to add start on demand (4.1):
--   StartOnDemandEnabled, MaxPendingStarts  The policy's start on demand settings (144).
--   ZeroMinimumCount  How many scaling rules and enabled schedule windows have a minimum of 0.
--                     While start on demand is off, scaling keeps one host running for them.
--   AvdHostsSeen      The AVD hosts that asked for a checkout in the last seven days.
--   AvdHostsOutdated  Those whose latest checkout reported no ClientVersion: their broker script
--                     predates start on demand and gives up instead of waiting for a host.
--   OutdatedAvdHostsJson   The first 20 of them by name, as [{"AvdHost": ...}].
--   AvdClientVersionsJson  How many of the others report each version, as
--                          [{"ClientVersion": ..., "AvdHosts": n}].

CREATE PROCEDURE [dbo].[GetScalingPolicy]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @NowUtc DATETIME2(0) = CAST(SYSUTCDATETIME() AS DATETIME2(0));
    DECLARE @AvdHosts TABLE (AvdHost VARCHAR(255) NOT NULL PRIMARY KEY, ClientVersion VARCHAR(32) NULL);

    INSERT INTO @AvdHosts (AvdHost, ClientVersion)
    SELECT AvdHost, ClientVersion
    FROM (
        SELECT AvdHost, ClientVersion,
               ROW_NUMBER() OVER (PARTITION BY AvdHost ORDER BY OccurredAt DESC, EventID DESC) AS Position
        FROM dbo.CheckoutEvents
        WHERE OccurredAt >= DATEADD(DAY, -7, @NowUtc) AND AvdHost IS NOT NULL
    ) latest
    WHERE Position = 1;

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
        phase.RuleID AS DefaultRuleID,
        p.StartOnDemandEnabled,
        p.MaxPendingStarts,
        (SELECT COUNT(*) FROM dbo.VmScalingRules WHERE MinVMs = 0)
            + (SELECT COUNT(*) FROM dbo.ScalingSchedules WHERE Enabled = 1 AND MinVMs = 0) AS ZeroMinimumCount,
        (SELECT COUNT(*) FROM @AvdHosts) AS AvdHostsSeen,
        (SELECT COUNT(*) FROM @AvdHosts WHERE ClientVersion IS NULL) AS AvdHostsOutdated,
        (SELECT TOP (20) AvdHost FROM @AvdHosts WHERE ClientVersion IS NULL ORDER BY AvdHost FOR JSON PATH) AS OutdatedAvdHostsJson,
        (SELECT ClientVersion, COUNT(*) AS AvdHosts FROM @AvdHosts WHERE ClientVersion IS NOT NULL
         GROUP BY ClientVersion ORDER BY ClientVersion FOR JSON PATH) AS AvdClientVersionsJson
    FROM dbo.ScalingPolicy p
    OUTER APPLY dbo.fnActiveScalingPhase(@NowUtc) phase
    WHERE p.PolicyID = 1;
END
GO
