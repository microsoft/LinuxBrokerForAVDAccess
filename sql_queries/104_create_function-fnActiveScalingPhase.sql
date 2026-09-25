-- The scaling values in force at @AtUtc (now when NULL): the enabled schedule window that
-- covers the local time in the policy's time zone, or else the default rule (the lowest
-- RuleID). Returns no row when neither exists. The day of the week is computed from a known
-- Monday, so it does not depend on @@DATEFIRST or the session language.
--
-- Source is Schedule or Rule. StopMode falls back from the window to the rule, then to
-- PowerOff. LocalTime is the policy-zone time the window was matched against.

CREATE OR ALTER FUNCTION dbo.fnActiveScalingPhase (@AtUtc DATETIME2(0))
RETURNS TABLE
AS
RETURN
    WITH PolicyZone AS (
        SELECT COALESCE((SELECT TOP 1 TimeZone FROM dbo.ScalingPolicy ORDER BY PolicyID), N'UTC') AS TimeZone
    ),
    LocalClock AS (
        SELECT
            z.TimeZone,
            CAST(TODATETIMEOFFSET(COALESCE(@AtUtc, CAST(SYSUTCDATETIME() AS DATETIME2(0))), 0) AT TIME ZONE z.TimeZone AS DATETIME2(0)) AS LocalTime
        FROM PolicyZone z
    ),
    LocalParts AS (
        SELECT
            TimeZone,
            LocalTime,
            (DATEDIFF(DAY, CAST('19000101' AS DATE), CAST(LocalTime AS DATE)) % 7) * 1440
                + DATEPART(HOUR, LocalTime) * 60 + DATEPART(MINUTE, LocalTime) AS WeekMinute
        FROM LocalClock
    ),
    DefaultRule AS (
        SELECT TOP 1 RuleID, MinVMs, MaxVMs, ScaleUpRatio, ScaleUpIncrement, ScaleDownRatio, ScaleDownIncrement, StopMode
        FROM dbo.VmScalingRules
        ORDER BY RuleID
    ),
    Candidates AS (
        SELECT
            0 AS Priority,
            CAST('Schedule' AS VARCHAR(16)) AS Source,
            s.ScheduleID,
            s.Name AS PhaseName,
            s.MinVMs, s.MaxVMs, s.ScaleUpRatio, s.ScaleUpIncrement, s.ScaleDownRatio, s.ScaleDownIncrement,
            COALESCE(s.StopMode, (SELECT StopMode FROM DefaultRule), 'PowerOff') AS StopMode,
            (SELECT RuleID FROM DefaultRule) AS RuleID,
            lp.TimeZone,
            lp.LocalTime
        FROM dbo.ScalingSchedules s
        CROSS JOIN LocalParts lp
        WHERE s.Enabled = 1
          AND EXISTS (
              SELECT 1
              FROM dbo.fnScheduleWeekIntervals(s.DaysOfWeek, s.StartTime, s.EndTime) w
              WHERE lp.WeekMinute >= w.StartMinute AND lp.WeekMinute < w.EndMinute
          )
        UNION ALL
        SELECT
            1,
            CAST('Rule' AS VARCHAR(16)),
            NULL,
            CAST(N'Default rule' AS NVARCHAR(64)),
            r.MinVMs, r.MaxVMs, r.ScaleUpRatio, r.ScaleUpIncrement, r.ScaleDownRatio, r.ScaleDownIncrement,
            COALESCE(r.StopMode, 'PowerOff'),
            r.RuleID,
            lp.TimeZone,
            lp.LocalTime
        FROM DefaultRule r
        CROSS JOIN LocalParts lp
    )
    SELECT TOP 1
        Source, ScheduleID, PhaseName, MinVMs, MaxVMs, ScaleUpRatio, ScaleUpIncrement,
        ScaleDownRatio, ScaleDownIncrement, StopMode, RuleID, TimeZone, LocalTime
    FROM Candidates
    ORDER BY Priority, ScheduleID;
GO
