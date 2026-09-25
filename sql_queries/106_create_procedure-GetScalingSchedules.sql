-- Every scaling schedule window, enabled or not, in start order. Times are HH:MM strings in
-- the policy's time zone.

CREATE PROCEDURE [dbo].[GetScalingSchedules]
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        ScheduleID,
        Name,
        Enabled,
        DaysOfWeek,
        CONVERT(VARCHAR(5), StartTime, 108) AS StartTime,
        CONVERT(VARCHAR(5), EndTime, 108) AS EndTime,
        MinVMs,
        MaxVMs,
        ScaleUpRatio,
        ScaleUpIncrement,
        ScaleDownRatio,
        ScaleDownIncrement,
        StopMode,
        UpdatedBy,
        CONVERT(VARCHAR(33), CAST(SysStartTime AS DATETIME2(0)), 126) + 'Z' AS UpdatedAtUtc
    FROM dbo.ScalingSchedules
    ORDER BY StartTime, ScheduleID;
END
GO
