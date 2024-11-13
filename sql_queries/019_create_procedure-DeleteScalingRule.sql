CREATE PROCEDURE DeleteScalingRule
    @RuleID INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Check if the rule exists
    IF EXISTS (SELECT 1 FROM VmScalingRules WHERE RuleID = @RuleID)
    BEGIN
        -- Delete the scaling rule
        DELETE FROM VmScalingRules WHERE RuleID = @RuleID;

        -- Return a success message
        SELECT 'Scaling rule deleted successfully.' AS Message;
    END
    ELSE
    BEGIN
        -- If the rule doesn't exist, return an error message
        SELECT 'Scaling rule not found.' AS Message;
    END
END;
