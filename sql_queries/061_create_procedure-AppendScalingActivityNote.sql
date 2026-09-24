CREATE PROCEDURE [dbo].[AppendScalingActivityNote]
    @ActivityID INT,
    @Note NVARCHAR(1000)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.VmScalingActivityLog
    SET Notes = CASE
        WHEN Notes IS NULL OR LTRIM(RTRIM(Notes)) = '' THEN @Note
        ELSE CONCAT(Notes, N' ', @Note)
    END
    WHERE ActivityID = @ActivityID;
END
GO
