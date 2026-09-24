-- Removes audit entries older than the retention window, one batch per DELETE, and reports
-- MoreRemaining so the caller runs it again.
--
-- A batch is at most 2,000 rows. A delete takes a key lock and a page lock for each row, so
-- even rows that fill a page each stay under SQL Server's 5,000-lock escalation threshold: a
-- purge never locks the whole table, and audit writes wait for at most one batch. That only
-- holds while each batch commits on its own: run by hand, in autocommit, each DELETE does.
-- A caller that keeps a transaction open across the call, as pymssql does, should pass
-- @MaxBatches = 1 and commit between calls. The API does.
--
-- The retention is clamped to the same 30-3650 day range the API accepts for
-- AUDIT_RETENTION_DAYS, so a bad value can never empty the table.

CREATE PROCEDURE [dbo].[PurgeAuditLog]
    @RetentionDays INT,
    @BatchSize INT = 2000,
    @MaxBatches INT = 20
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SafeDays INT = CASE
        WHEN @RetentionDays IS NULL OR @RetentionDays < 30 THEN 30
        WHEN @RetentionDays > 3650 THEN 3650
        ELSE @RetentionDays
    END;
    DECLARE @SafeBatchSize INT = CASE
        WHEN @BatchSize IS NULL OR @BatchSize < 1 OR @BatchSize > 2000 THEN 2000
        ELSE @BatchSize
    END;
    DECLARE @SafeMaxBatches INT = CASE
        WHEN @MaxBatches IS NULL OR @MaxBatches < 1 THEN 20
        WHEN @MaxBatches > 200 THEN 200
        ELSE @MaxBatches
    END;
    DECLARE @Cutoff DATETIME2(3) = DATEADD(DAY, -@SafeDays, SYSUTCDATETIME());
    DECLARE @Deleted INT = 0;
    DECLARE @LastBatch INT = 1;
    DECLARE @Batches INT = 0;

    WHILE @LastBatch > 0 AND @Batches < @SafeMaxBatches
    BEGIN
        DELETE TOP (@SafeBatchSize)
        FROM dbo.AuditLog
        WHERE OccurredAt < @Cutoff;

        SET @LastBatch = @@ROWCOUNT;
        SET @Deleted += @LastBatch;
        SET @Batches += 1;
    END

    SELECT
        @Deleted AS Deleted,
        @SafeDays AS RetentionDays,
        CONVERT(VARCHAR(33), @Cutoff, 126) + 'Z' AS CutoffUtc,
        CAST(CASE WHEN @LastBatch > 0 AND EXISTS (SELECT 1 FROM dbo.AuditLog WHERE OccurredAt < @Cutoff) THEN 1 ELSE 0 END AS BIT) AS MoreRemaining;
END
GO
