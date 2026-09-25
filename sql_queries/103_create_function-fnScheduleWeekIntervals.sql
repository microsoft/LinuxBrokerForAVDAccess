-- The minutes of the week a schedule covers, Monday 00:00 being minute 0 and the week 10080
-- minutes long, as [StartMinute, EndMinute) intervals. A window that runs past midnight ends
-- on the next day, and one that runs past Sunday midnight wraps to the start of the week.
-- Used to find the active window and to reject overlapping windows.

CREATE OR ALTER FUNCTION dbo.fnScheduleWeekIntervals (
    @DaysOfWeek TINYINT,
    @StartTime TIME(0),
    @EndTime TIME(0)
)
RETURNS TABLE
AS
RETURN
    WITH Days AS (
        SELECT DayIndex
        FROM (VALUES (0), (1), (2), (3), (4), (5), (6)) AS days(DayIndex)
        WHERE (@DaysOfWeek & POWER(2, DayIndex)) <> 0
    ),
    Windows AS (
        SELECT
            DayIndex * 1440 + DATEPART(HOUR, @StartTime) * 60 + DATEPART(MINUTE, @StartTime) AS StartMinute,
            DayIndex * 1440 + DATEPART(HOUR, @EndTime) * 60 + DATEPART(MINUTE, @EndTime)
                + CASE WHEN @EndTime <= @StartTime THEN 1440 ELSE 0 END AS EndMinute
        FROM Days
    )
    SELECT StartMinute, CASE WHEN EndMinute > 10080 THEN 10080 ELSE EndMinute END AS EndMinute
    FROM Windows
    UNION ALL
    SELECT 0, EndMinute - 10080
    FROM Windows
    WHERE EndMinute > 10080;
GO
