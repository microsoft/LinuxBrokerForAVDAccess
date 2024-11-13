CREATE PROCEDURE [dbo].[CreateScalingRule]
    @MinVMs INT,
    @MaxVMs INT,
    @ScaleUpRatio FLOAT,
    @ScaleUpIncrement INT,
    @ScaleDownRatio FLOAT,
    @ScaleDownIncrement INT
AS
BEGIN
    -- Insert the new scaling rule into the VMScalingRules table
    INSERT INTO dbo.VmScalingRules (MinVMs, MaxVMs, ScaleUpRatio, ScaleUpIncrement, ScaleDownRatio, ScaleDownIncrement)
    VALUES (@MinVMs, @MaxVMs, @ScaleUpRatio, @ScaleUpIncrement, @ScaleDownRatio, @ScaleDownIncrement);

    -- Return the ID of the newly created rule
    SELECT SCOPE_IDENTITY() AS NewRuleID;
END
GO
