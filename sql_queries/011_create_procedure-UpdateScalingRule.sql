CREATE PROCEDURE [dbo].[UpdateScalingRule]
    @RuleID INT,
    @MinVMs INT = NULL,
    @MaxVMs INT = NULL,
    @ScaleUpRatio DECIMAL(5,2) = NULL,
    @ScaleUpIncrement INT = NULL,
    @ScaleDownRatio DECIMAL(5,2) = NULL,
    @ScaleDownIncrement INT = NULL
AS
BEGIN
    UPDATE dbo.VmScalingRules
    SET MinVMs = COALESCE(@MinVMs, MinVMs),
        MaxVMs = COALESCE(@MaxVMs, MaxVMs),
        ScaleUpRatio = COALESCE(@ScaleUpRatio, ScaleUpRatio),
        ScaleUpIncrement = COALESCE(@ScaleUpIncrement, ScaleUpIncrement),
        ScaleDownRatio = COALESCE(@ScaleDownRatio, ScaleDownRatio),
        ScaleDownIncrement = COALESCE(@ScaleDownIncrement, ScaleDownIncrement),
        LastChecked = GETDATE()  -- Optionally, update the LastChecked timestamp
    WHERE RuleID = @RuleID;
END
GO
