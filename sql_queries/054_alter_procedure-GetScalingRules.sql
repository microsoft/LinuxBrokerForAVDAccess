CREATE PROCEDURE [dbo].[GetScalingRules]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ActiveRuleID INT;
    SELECT TOP 1 @ActiveRuleID = RuleID FROM dbo.VmScalingRules ORDER BY RuleID;

    SELECT RuleID, MinVMs, MaxVMs, ScaleUpRatio, ScaleUpIncrement,
           ScaleDownRatio, ScaleDownIncrement, LastChecked,
           COALESCE(StopMode, 'PowerOff') AS StopMode,
           CAST(CASE WHEN RuleID = @ActiveRuleID THEN 1 ELSE 0 END AS BIT) AS IsActive
    FROM dbo.VmScalingRules
    ORDER BY RuleID;
END
GO
