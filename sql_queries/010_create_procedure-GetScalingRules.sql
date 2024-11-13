CREATE PROCEDURE [dbo].[GetScalingRules]
AS
BEGIN
    SELECT RuleID, MinVMs, MaxVMs, ScaleUpRatio, ScaleUpIncrement, ScaleDownRatio, ScaleDownIncrement, LastChecked
    FROM dbo.VmScalingRules;
END
GO
