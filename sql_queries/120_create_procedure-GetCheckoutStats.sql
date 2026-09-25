-- Checkout health for the dashboard over [@FromUtc, @ToUtc): counts by outcome, the median and
-- 95th percentile time of successful checkouts, denials in the last hour, and the median and
-- 95th percentile host start-to-ready time. One row.

CREATE PROCEDURE [dbo].[GetCheckoutStats]
    @FromUtc DATETIME2(0),
    @ToUtc DATETIME2(0) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Without an end, everything up to now: a second ahead, so nothing just recorded is missed.
    DECLARE @To DATETIME2(0) = COALESCE(@ToUtc, DATEADD(SECOND, 1, SYSUTCDATETIME()));
    DECLARE @From DATETIME2(0) = COALESCE(@FromUtc, DATEADD(HOUR, -24, @To));
    DECLARE @P50Ms INT, @P95Ms INT, @StartP50 INT, @StartP95 INT;

    SELECT TOP 1
        @P50Ms = CAST(ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY DurationMs) OVER (), 0) AS INT),
        @P95Ms = CAST(ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY DurationMs) OVER (), 0) AS INT)
    FROM dbo.CheckoutEvents
    WHERE OccurredAt >= @From AND OccurredAt < @To
      AND Outcome IN ('Assigned', 'Reused')
      AND DurationMs IS NOT NULL;

    SELECT TOP 1
        @StartP50 = CAST(ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY Seconds) OVER (), 0) AS INT),
        @StartP95 = CAST(ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY Seconds) OVER (), 0) AS INT)
    FROM dbo.HostStartEvents
    WHERE ReadyAt >= @From AND ReadyAt < @To;

    SELECT
        COUNT(*) AS Total,
        COALESCE(SUM(CASE WHEN Outcome = 'Assigned' THEN 1 ELSE 0 END), 0) AS Assigned,
        COALESCE(SUM(CASE WHEN Outcome = 'Reused' THEN 1 ELSE 0 END), 0) AS Reused,
        COALESCE(SUM(CASE WHEN Outcome = 'NoneAvailable' THEN 1 ELSE 0 END), 0) AS NoneAvailable,
        COALESCE(SUM(CASE WHEN Outcome = 'ProvisionFailed' THEN 1 ELSE 0 END), 0) AS ProvisionFailed,
        COALESCE(SUM(CASE WHEN Outcome = 'Error' THEN 1 ELSE 0 END), 0) AS Errors,
        @P50Ms AS P50Ms,
        @P95Ms AS P95Ms,
        (SELECT COUNT(*) FROM dbo.CheckoutEvents
         WHERE Outcome = 'NoneAvailable' AND OccurredAt >= DATEADD(HOUR, -1, SYSUTCDATETIME())) AS DeniedLastHour,
        (SELECT CONVERT(VARCHAR(33), MAX(OccurredAt), 126) + 'Z' FROM dbo.CheckoutEvents
         WHERE Outcome = 'NoneAvailable' AND OccurredAt >= @From AND OccurredAt < @To) AS LastDeniedUtc,
        (SELECT COUNT(*) FROM dbo.HostStartEvents WHERE ReadyAt >= @From AND ReadyAt < @To) AS HostStarts,
        @StartP50 AS StartP50Seconds,
        @StartP95 AS StartP95Seconds
    FROM dbo.CheckoutEvents
    WHERE OccurredAt >= @From AND OccurredAt < @To;
END
GO
