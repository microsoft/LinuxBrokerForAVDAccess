-- Removes checkout and host-start events older than @RetentionDays (clamped to 7-3650), one
-- batch of each per call so audit and checkout writes never wait long. MoreRemaining tells the
-- caller to call again.

CREATE PROCEDURE [dbo].[PurgeCheckoutEvents]
    @RetentionDays INT = 90,
    @BatchSize INT = 2000
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Days INT = CASE WHEN @RetentionDays IS NULL OR @RetentionDays < 7 THEN 7
                             WHEN @RetentionDays > 3650 THEN 3650 ELSE @RetentionDays END;
    DECLARE @Batch INT = CASE WHEN @BatchSize IS NULL OR @BatchSize < 1 THEN 2000
                              WHEN @BatchSize > 4000 THEN 4000 ELSE @BatchSize END;
    DECLARE @Cutoff DATETIME2(3) = DATEADD(DAY, -@Days, SYSUTCDATETIME());
    DECLARE @CheckoutsDeleted INT, @StartsDeleted INT;

    DELETE TOP (@Batch) FROM dbo.CheckoutEvents WHERE OccurredAt < @Cutoff;
    SET @CheckoutsDeleted = @@ROWCOUNT;

    DELETE TOP (@Batch) FROM dbo.HostStartEvents WHERE ReadyAt < @Cutoff;
    SET @StartsDeleted = @@ROWCOUNT;

    SELECT @Days AS RetentionDays,
           @CheckoutsDeleted AS CheckoutEventsDeleted,
           @StartsDeleted AS HostStartEventsDeleted,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.CheckoutEvents WHERE OccurredAt < @Cutoff)
                       OR EXISTS (SELECT 1 FROM dbo.HostStartEvents WHERE ReadyAt < @Cutoff)
                     THEN 1 ELSE 0 END AS BIT) AS MoreRemaining;
END
GO
