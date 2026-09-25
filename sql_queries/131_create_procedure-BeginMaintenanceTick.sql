-- Claims the active maintenance run for one scheduled advance, so two never work on it at
-- once. The claim lasts @LeaseSeconds (clamped to 30-600) and is released by
-- dbo.EndMaintenanceTick; an advance that dies simply lets it expire.
--
-- Result: Claimed (with the TickToken to release it), Busy (another advance holds it) or
-- NoRun. The run's summary columns follow, empty for NoRun.

CREATE PROCEDURE [dbo].[BeginMaintenanceTick]
    @LeaseSeconds INT = 90
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Lease INT = CASE WHEN @LeaseSeconds IS NULL OR @LeaseSeconds < 30 THEN 30
                              WHEN @LeaseSeconds > 600 THEN 600 ELSE @LeaseSeconds END;
    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @Token UNIQUEIDENTIFIER = NEWID();
    DECLARE @Claimed TABLE (RunID INT);
    DECLARE @ActiveRunID INT;

    UPDATE TOP (1) dbo.MaintenanceRuns
    SET TickToken = @Token,
        TickLeaseUntil = DATEADD(SECOND, @Lease, @Now),
        LastTickAt = @Now
    OUTPUT INSERTED.RunID INTO @Claimed
    WHERE Status IN ('Active', 'Paused', 'Stopping')
      AND (TickLeaseUntil IS NULL OR TickLeaseUntil < @Now);

    IF EXISTS (SELECT 1 FROM @Claimed)
    BEGIN
        SELECT CAST('Claimed' AS VARCHAR(16)) AS Result, @Token AS TickToken, s.*
        FROM dbo.fnMaintenanceRunSummary() s
        WHERE s.RunID = (SELECT TOP 1 RunID FROM @Claimed);
        RETURN;
    END

    SELECT TOP 1 @ActiveRunID = RunID FROM dbo.MaintenanceRuns WHERE Status IN ('Active', 'Paused', 'Stopping') ORDER BY RunID DESC;

    SELECT CAST(CASE WHEN @ActiveRunID IS NULL THEN 'NoRun' ELSE 'Busy' END AS VARCHAR(16)) AS Result,
           CAST(NULL AS UNIQUEIDENTIFIER) AS TickToken, s.*
    FROM (SELECT 1 AS One) one
    LEFT JOIN dbo.fnMaintenanceRunSummary() s ON s.RunID = @ActiveRunID;
END
GO
