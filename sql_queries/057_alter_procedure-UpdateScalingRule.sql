CREATE PROCEDURE [dbo].[UpdateScalingRule]
    @RuleID INT,
    @MinVMs INT = NULL,
    @MaxVMs INT = NULL,
    @ScaleUpRatio DECIMAL(5,2) = NULL,
    @ScaleUpIncrement INT = NULL,
    @ScaleDownRatio DECIMAL(5,2) = NULL,
    @ScaleDownIncrement INT = NULL,
    @StopMode VARCHAR(16) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.VmScalingRules
    SET MinVMs = COALESCE(@MinVMs, MinVMs),
        MaxVMs = COALESCE(@MaxVMs, MaxVMs),
        ScaleUpRatio = COALESCE(@ScaleUpRatio, ScaleUpRatio),
        ScaleUpIncrement = COALESCE(@ScaleUpIncrement, ScaleUpIncrement),
        ScaleDownRatio = COALESCE(@ScaleDownRatio, ScaleDownRatio),
        ScaleDownIncrement = COALESCE(@ScaleDownIncrement, ScaleDownIncrement),
        StopMode = COALESCE(@StopMode, StopMode),
        LastChecked = GETDATE()
    WHERE RuleID = @RuleID;
END
GO
