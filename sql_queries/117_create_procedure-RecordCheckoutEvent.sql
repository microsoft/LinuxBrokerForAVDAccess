-- Records the outcome of one checkout request. An unknown outcome is stored as Error rather
-- than failing the checkout that reports it.

CREATE PROCEDURE [dbo].[RecordCheckoutEvent]
    @Username VARCHAR(255) = NULL,
    @AvdHost VARCHAR(255) = NULL,
    @Outcome VARCHAR(24),
    @DurationMs INT = NULL,
    @Hostname VARCHAR(255) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.CheckoutEvents (Username, AvdHost, Outcome, DurationMs, Hostname)
    VALUES (
        LEFT(@Username, 255),
        LEFT(@AvdHost, 255),
        CASE WHEN @Outcome IN ('Assigned', 'Reused', 'NoneAvailable', 'ProvisionFailed', 'Error') THEN @Outcome ELSE 'Error' END,
        CASE WHEN @DurationMs < 0 THEN 0 ELSE @DurationMs END,
        LEFT(@Hostname, 255)
    );

    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS EventID;
END
GO
