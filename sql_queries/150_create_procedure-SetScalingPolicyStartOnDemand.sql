-- Turns start on demand on or off and sets how many hosts may start for waiting users at once
-- (4.1). A NULL parameter keeps its current value. Turning start on demand off is allowed while
-- rules or windows have a minimum of 0: scaling then keeps one host running for them, and
-- ZeroMinimumCount lets the caller say so.
--
-- Result: Updated, Unchanged, or Invalid (with a Message naming the field).

CREATE PROCEDURE [dbo].[SetScalingPolicyStartOnDemand]
    @Enabled BIT = NULL,
    @MaxPendingStarts INT = NULL,
    @UpdatedBy NVARCHAR(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PreviousEnabled BIT;
    DECLARE @PreviousMax INT;
    DECLARE @NewEnabled BIT;
    DECLARE @NewMax INT;
    DECLARE @Message NVARCHAR(200) = NULL;
    DECLARE @Result VARCHAR(24);
    DECLARE @ZeroMinimumCount INT =
        (SELECT COUNT(*) FROM dbo.VmScalingRules WHERE MinVMs = 0)
        + (SELECT COUNT(*) FROM dbo.ScalingSchedules WHERE Enabled = 1 AND MinVMs = 0);

    SELECT @PreviousEnabled = StartOnDemandEnabled, @PreviousMax = MaxPendingStarts
    FROM dbo.ScalingPolicy
    WHERE PolicyID = 1;

    SET @NewEnabled = COALESCE(@Enabled, @PreviousEnabled);
    SET @NewMax = COALESCE(@MaxPendingStarts, @PreviousMax);

    SET @Message = CASE
        WHEN @Enabled IS NULL AND @MaxPendingStarts IS NULL THEN N'Provide enabled, maxpendingstarts, or both.'
        WHEN @NewMax < 1 OR @NewMax > 20 THEN N'maxpendingstarts must be between 1 and 20.'
        ELSE NULL
    END;

    IF @Message IS NOT NULL
        SET @Result = 'Invalid';
    ELSE IF @NewEnabled = @PreviousEnabled AND @NewMax = @PreviousMax
        SET @Result = 'Unchanged';
    ELSE
    BEGIN
        UPDATE dbo.ScalingPolicy
        SET StartOnDemandEnabled = @NewEnabled,
            MaxPendingStarts = @NewMax,
            UpdatedBy = @UpdatedBy,
            UpdatedAt = SYSUTCDATETIME()
        WHERE PolicyID = 1;
        SET @Result = 'Updated';
    END

    SELECT
        @Result AS Result,
        @Message AS Message,
        CASE WHEN @Result = 'Updated' THEN @NewEnabled ELSE @PreviousEnabled END AS StartOnDemandEnabled,
        CASE WHEN @Result = 'Updated' THEN @NewMax ELSE @PreviousMax END AS MaxPendingStarts,
        @PreviousEnabled AS PreviousStartOnDemandEnabled,
        @PreviousMax AS PreviousMaxPendingStarts,
        @ZeroMinimumCount AS ZeroMinimumCount;
END
GO
