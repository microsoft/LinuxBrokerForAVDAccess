CREATE PROCEDURE [dbo].[CreateScalingRule]
    @MinVMs INT,
    @MaxVMs INT,
    @ScaleUpRatio FLOAT,
    @ScaleUpIncrement INT,
    @ScaleDownRatio FLOAT,
    @ScaleDownIncrement INT,
    @StopMode VARCHAR(16) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @LockResult INT;
    DECLARE @NewRuleID INT = NULL;
    DECLARE @ActiveRuleID INT = NULL;
    DECLARE @Message NVARCHAR(200) = NULL;

    DECLARE @StartedTransaction BIT = 0;

    IF @@TRANCOUNT = 0
    BEGIN
        BEGIN TRANSACTION;
        SET @StartedTransaction = 1;
    END
    ELSE
    BEGIN
        SAVE TRANSACTION ScalingRulesSave;
    END

    EXEC @LockResult = sp_getapplock
        @Resource = 'LinuxBroker.ScalingRules',
        @LockMode = 'Exclusive',
        @LockOwner = 'Transaction',
        @LockTimeout = 10000;

    IF @LockResult < 0
    BEGIN
        SET @Message = N'Scaling rules are busy. Try again.';
        IF @StartedTransaction = 1
        BEGIN
            ROLLBACK TRANSACTION;
        END
        ELSE
        BEGIN
            ROLLBACK TRANSACTION ScalingRulesSave;
        END
        SELECT @NewRuleID AS NewRuleID, @ActiveRuleID AS ActiveRuleID, @Message AS Message;
        RETURN;
    END

    SELECT TOP 1 @ActiveRuleID = RuleID FROM dbo.VmScalingRules ORDER BY RuleID;

    IF @ActiveRuleID IS NOT NULL
    BEGIN
        SET @Message = N'A scaling rule already exists.';
        IF @StartedTransaction = 1 COMMIT TRANSACTION;
        SELECT @NewRuleID AS NewRuleID, @ActiveRuleID AS ActiveRuleID, @Message AS Message;
        RETURN;
    END

    INSERT INTO dbo.VmScalingRules (MinVMs, MaxVMs, ScaleUpRatio, ScaleUpIncrement, ScaleDownRatio, ScaleDownIncrement, StopMode)
    VALUES (@MinVMs, @MaxVMs, @ScaleUpRatio, @ScaleUpIncrement, @ScaleDownRatio, @ScaleDownIncrement, @StopMode);

    SET @NewRuleID = SCOPE_IDENTITY();
    SET @ActiveRuleID = @NewRuleID;

    IF @StartedTransaction = 1 COMMIT TRANSACTION;

    SELECT @NewRuleID AS NewRuleID, @ActiveRuleID AS ActiveRuleID, @Message AS Message;
END
GO
