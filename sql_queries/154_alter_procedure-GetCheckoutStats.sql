-- Redefines dbo.GetCheckoutStats (120) for start on demand (4.1). A user who waits for a host to
-- start records a Starting event each time their AVD host asks, then the outcome that ended
-- the wait, so:
-- * Total and the outcome counts leave Starting events out: they count checkouts that ended,
--   as before, and the API's denied share (NoneAvailable / Total) keeps its meaning.
-- * Starting counts the times an AVD host was told to wait.
-- * A wait runs from a user's first Starting event to the next event of theirs that is not
--   Starting. Waits counts the waits that began in the period, WaitsServed those that ended in
--   a checkout (Assigned or Reused) within 20 minutes, and WaitP50Seconds and WaitP95Seconds
--   how long those took. Events up to 20 minutes either side of the period are read, so a wait
--   that crosses its edges is still measured.
-- * WaitingNow counts the users waiting now (dbo.fnWaitingCheckoutUsers).
-- Everything else is unchanged: the median and 95th percentile time of successful checkouts,
-- denials in the last hour, and the median and 95th percentile host start-to-ready time.

CREATE PROCEDURE [dbo].[GetCheckoutStats]
    @FromUtc DATETIME2(0),
    @ToUtc DATETIME2(0) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Without an end, everything up to now: a second ahead, so nothing just recorded is missed.
    DECLARE @To DATETIME2(0) = COALESCE(@ToUtc, DATEADD(SECOND, 1, SYSUTCDATETIME()));
    DECLARE @From DATETIME2(0) = COALESCE(@FromUtc, DATEADD(HOUR, -24, @To));
    DECLARE @P50Ms INT, @P95Ms INT, @StartP50 INT, @StartP95 INT, @WaitP50 INT, @WaitP95 INT;
    DECLARE @Waits TABLE (FirstStartingAt DATETIME2(3) NOT NULL, EndedAt DATETIME2(3) NULL, EndOutcome VARCHAR(24) NULL);

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

    -- Each of a user's events belongs to the wait that the next event other than Starting ends:
    -- the number of such events before it identifies the wait.
    INSERT INTO @Waits (FirstStartingAt, EndedAt, EndOutcome)
    SELECT MIN(CASE WHEN e.Outcome = 'Starting' THEN e.OccurredAt END),
           MAX(CASE WHEN e.Outcome <> 'Starting' THEN e.OccurredAt END),
           MAX(CASE WHEN e.Outcome <> 'Starting' THEN e.Outcome END)
    FROM (
        SELECT Username, Outcome, OccurredAt,
               COALESCE(SUM(CASE WHEN Outcome = 'Starting' THEN 0 ELSE 1 END)
                   OVER (PARTITION BY Username ORDER BY OccurredAt, EventID ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS WaitNumber
        FROM dbo.CheckoutEvents
        WHERE Username IS NOT NULL
          AND OccurredAt >= DATEADD(MINUTE, -20, @From)
          AND OccurredAt < DATEADD(MINUTE, 20, @To)
    ) e
    GROUP BY e.Username, e.WaitNumber
    HAVING SUM(CASE WHEN e.Outcome = 'Starting' THEN 1 ELSE 0 END) > 0;

    DELETE FROM @Waits WHERE FirstStartingAt < @From OR FirstStartingAt >= @To;

    SELECT TOP 1
        @WaitP50 = CAST(ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY DATEDIFF(SECOND, FirstStartingAt, EndedAt)) OVER (), 0) AS INT),
        @WaitP95 = CAST(ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY DATEDIFF(SECOND, FirstStartingAt, EndedAt)) OVER (), 0) AS INT)
    FROM @Waits
    WHERE EndOutcome IN ('Assigned', 'Reused')
      AND EndedAt <= DATEADD(MINUTE, 20, FirstStartingAt);

    SELECT
        COALESCE(SUM(CASE WHEN Outcome <> 'Starting' THEN 1 ELSE 0 END), 0) AS Total,
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
        @StartP95 AS StartP95Seconds,
        COALESCE(SUM(CASE WHEN Outcome = 'Starting' THEN 1 ELSE 0 END), 0) AS Starting,
        (SELECT COUNT(*) FROM @Waits) AS Waits,
        (SELECT COUNT(*) FROM @Waits
         WHERE EndOutcome IN ('Assigned', 'Reused') AND EndedAt <= DATEADD(MINUTE, 20, FirstStartingAt)) AS WaitsServed,
        @WaitP50 AS WaitP50Seconds,
        @WaitP95 AS WaitP95Seconds,
        (SELECT COUNT(*) FROM dbo.fnWaitingCheckoutUsers()) AS WaitingNow
    FROM dbo.CheckoutEvents
    WHERE OccurredAt >= @From AND OccurredAt < @To;
END
GO
