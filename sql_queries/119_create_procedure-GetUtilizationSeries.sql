-- Capacity over time for the dashboard's charts: one row per bucket of @BucketMinutes from
-- @FromUtc (rounded down to the minute) up to @ToUtc, empty buckets included.
-- * From the scaling runs in each bucket: the average powered-on, in-use and serviceable
--   counts, the peak in use, and the phase's minimum and maximum. The averages keep the lines
--   comparable: in use never averages above serviceable unless it was above it at some point.
-- * From the checkout events: how many checkouts there were, how many found no host and how
--   many failed in the broker.
-- Times are UTC; the activity log's database-local CheckTimestamp is converted with the
-- database's current offset (zero on Azure SQL). At most 2,000 buckets.

CREATE PROCEDURE [dbo].[GetUtilizationSeries]
    @FromUtc DATETIME2(0),
    @ToUtc DATETIME2(0),
    @BucketMinutes INT = 60
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Bucket INT = CASE WHEN @BucketMinutes IS NULL OR @BucketMinutes < 5 THEN 5
                               WHEN @BucketMinutes > 1440 THEN 1440 ELSE @BucketMinutes END;
    DECLARE @BucketSeconds INT = @Bucket * 60;
    -- Without an end, everything up to now: a second ahead, so nothing just recorded is missed.
    DECLARE @To DATETIME2(0) = COALESCE(@ToUtc, DATEADD(SECOND, 1, SYSUTCDATETIME()));
    DECLARE @From DATETIME2(0) = COALESCE(@FromUtc, DATEADD(HOUR, -24, @To));
    SET @From = DATEADD(MINUTE, DATEDIFF(MINUTE, CAST('20000101' AS DATETIME2(0)), @From), CAST('20000101' AS DATETIME2(0)));
    DECLARE @Span INT = DATEDIFF(SECOND, @From, @To);
    DECLARE @Buckets INT = @Span / @BucketSeconds + CASE WHEN @Span % @BucketSeconds = 0 THEN 0 ELSE 1 END;
    DECLARE @OffsetMinutes INT = DATEDIFF(MINUTE, GETDATE(), GETUTCDATE());

    IF @Span <= 0 OR @Buckets > 2000
    BEGIN
        SELECT CAST(NULL AS VARCHAR(33)) AS BucketStartUtc, 0 AS Runs,
               CAST(NULL AS DECIMAL(9,1)) AS PoweredOn, CAST(NULL AS DECIMAL(9,1)) AS InUse,
               CAST(NULL AS DECIMAL(9,1)) AS Serviceable, CAST(NULL AS INT) AS PeakInUse,
               CAST(NULL AS INT) AS MinVMs, CAST(NULL AS INT) AS MaxVMs,
               0 AS Checkouts, 0 AS Denied, 0 AS Failed
        WHERE 1 = 0;
        RETURN;
    END

    ;WITH Tally AS (
        SELECT TOP (@Buckets) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS BucketIndex
        FROM sys.all_columns a CROSS JOIN sys.all_columns b
    ),
    Runs AS (
        SELECT
            DATEDIFF(SECOND, @From, DATEADD(MINUTE, @OffsetMinutes, CAST(CheckTimestamp AS DATETIME2(0)))) / @BucketSeconds AS BucketIndex,
            CurrentRunningVMs, CurrentInUseVMs, ServiceableVMs, MinVMs, MaxVMs
        FROM dbo.VmScalingActivityLog
        WHERE CheckTimestamp >= DATEADD(MINUTE, -@OffsetMinutes, @From)
          AND CheckTimestamp < DATEADD(MINUTE, -@OffsetMinutes, @To)
    ),
    RunBuckets AS (
        SELECT BucketIndex,
               COUNT(*) AS Runs,
               CAST(AVG(CAST(CurrentRunningVMs AS DECIMAL(9,2))) AS DECIMAL(9,1)) AS PoweredOn,
               CAST(AVG(CAST(CurrentInUseVMs AS DECIMAL(9,2))) AS DECIMAL(9,1)) AS InUse,
               CAST(AVG(CAST(ServiceableVMs AS DECIMAL(9,2))) AS DECIMAL(9,1)) AS Serviceable,
               MAX(CurrentInUseVMs) AS PeakInUse,
               MAX(MinVMs) AS MinVMs,
               MAX(MaxVMs) AS MaxVMs
        FROM Runs
        GROUP BY BucketIndex
    ),
    CheckoutBuckets AS (
        SELECT DATEDIFF(SECOND, @From, OccurredAt) / @BucketSeconds AS BucketIndex,
               COUNT(*) AS Checkouts,
               SUM(CASE WHEN Outcome = 'NoneAvailable' THEN 1 ELSE 0 END) AS Denied,
               SUM(CASE WHEN Outcome IN ('ProvisionFailed', 'Error') THEN 1 ELSE 0 END) AS Failed
        FROM dbo.CheckoutEvents
        WHERE OccurredAt >= @From AND OccurredAt < @To
        GROUP BY DATEDIFF(SECOND, @From, OccurredAt) / @BucketSeconds
    )
    SELECT
        CONVERT(VARCHAR(33), DATEADD(MINUTE, t.BucketIndex * @Bucket, @From), 126) + 'Z' AS BucketStartUtc,
        COALESCE(r.Runs, 0) AS Runs,
        r.PoweredOn,
        r.InUse,
        r.Serviceable,
        r.PeakInUse,
        r.MinVMs,
        r.MaxVMs,
        COALESCE(c.Checkouts, 0) AS Checkouts,
        COALESCE(c.Denied, 0) AS Denied,
        COALESCE(c.Failed, 0) AS Failed
    FROM Tally t
    LEFT JOIN RunBuckets r ON r.BucketIndex = t.BucketIndex
    LEFT JOIN CheckoutBuckets c ON c.BucketIndex = t.BucketIndex
    ORDER BY t.BucketIndex;
END
GO