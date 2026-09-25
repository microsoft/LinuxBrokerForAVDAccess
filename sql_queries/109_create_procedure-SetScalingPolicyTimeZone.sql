-- Sets the time zone every schedule window is read in. Only names SQL Server knows
-- (sys.time_zone_info) are accepted, because AT TIME ZONE fails on any other.
-- Result: Updated, Unchanged or InvalidTimeZone.

CREATE PROCEDURE [dbo].[SetScalingPolicyTimeZone]
    @TimeZone NVARCHAR(64),
    @UpdatedBy NVARCHAR(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Zone NVARCHAR(64);
    DECLARE @Previous NVARCHAR(64);

    SELECT @Zone = name FROM sys.time_zone_info WHERE name = LTRIM(RTRIM(@TimeZone));
    SELECT @Previous = TimeZone FROM dbo.ScalingPolicy WHERE PolicyID = 1;

    IF @Zone IS NULL
    BEGIN
        SELECT CAST('InvalidTimeZone' AS VARCHAR(24)) AS Result, @Previous AS TimeZone, @Previous AS PreviousTimeZone;
        RETURN;
    END

    IF @Previous = @Zone
    BEGIN
        SELECT CAST('Unchanged' AS VARCHAR(24)) AS Result, @Zone AS TimeZone, @Previous AS PreviousTimeZone;
        RETURN;
    END

    UPDATE dbo.ScalingPolicy
    SET TimeZone = @Zone,
        UpdatedBy = @UpdatedBy,
        UpdatedAt = SYSUTCDATETIME()
    WHERE PolicyID = 1;

    SELECT CAST('Updated' AS VARCHAR(24)) AS Result, @Zone AS TimeZone, @Previous AS PreviousTimeZone;
END
GO
