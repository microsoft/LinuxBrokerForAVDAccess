CREATE PROCEDURE [dbo].[GetScalingRuleDetails]
    @RuleID INT
AS
BEGIN
    SELECT 
        RuleID,
        MinVMs,
        MaxVMs,
        ScaleUpRatio,
        ScaleUpIncrement,
        ScaleDownRatio,
        ScaleDownIncrement,
        LastChecked
    FROM 
        dbo.VmScalingRules
    WHERE 
        RuleID = @RuleID
END;
GO
