-- Removes a schedule window. The history table keeps its versions.

CREATE PROCEDURE [dbo].[DeleteScalingSchedule]
    @ScheduleID INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Deleted TABLE (ScheduleID INT, Name NVARCHAR(64));

    DELETE FROM dbo.ScalingSchedules
    OUTPUT DELETED.ScheduleID, DELETED.Name INTO @Deleted
    WHERE ScheduleID = @ScheduleID;

    IF NOT EXISTS (SELECT 1 FROM @Deleted)
    BEGIN
        SELECT CAST('NotFound' AS VARCHAR(24)) AS Result, @ScheduleID AS ScheduleID, CAST(NULL AS NVARCHAR(64)) AS Name;
        RETURN;
    END

    SELECT CAST('Deleted' AS VARCHAR(24)) AS Result, ScheduleID, Name FROM @Deleted;
END
GO
