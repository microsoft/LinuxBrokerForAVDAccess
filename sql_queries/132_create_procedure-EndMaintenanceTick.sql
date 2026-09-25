-- Releases the claim dbo.BeginMaintenanceTick gave an advance, if it still holds it.

CREATE PROCEDURE [dbo].[EndMaintenanceTick]
    @RunID INT,
    @TickToken UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.MaintenanceRuns
    SET TickToken = NULL,
        TickLeaseUntil = NULL
    WHERE RunID = @RunID
      AND TickToken = @TickToken;

    SELECT CAST(CASE WHEN @@ROWCOUNT = 1 THEN 'Released' ELSE 'NotHeld' END AS VARCHAR(16)) AS Result;
END
GO
