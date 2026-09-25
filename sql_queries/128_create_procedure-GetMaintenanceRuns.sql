-- The most recent maintenance runs, newest first, with how far each got.

CREATE PROCEDURE [dbo].[GetMaintenanceRuns]
    @Limit INT = 20
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Top INT = CASE WHEN @Limit IS NULL OR @Limit < 1 THEN 20 WHEN @Limit > 200 THEN 200 ELSE @Limit END;

    SELECT TOP (@Top) *
    FROM dbo.fnMaintenanceRunSummary()
    ORDER BY RunID DESC;
END
GO
