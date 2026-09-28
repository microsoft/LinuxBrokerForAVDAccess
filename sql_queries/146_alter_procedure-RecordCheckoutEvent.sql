-- Redefines dbo.RecordCheckoutEvent to accept the Starting outcome and the AVD host script's
-- ClientVersion (145). An outcome it does not know is still stored as Error rather than failing
-- the checkout that reports it.

CREATE PROCEDURE [dbo].[RecordCheckoutEvent]
    @Username VARCHAR(255) = NULL,
    @AvdHost VARCHAR(255) = NULL,
    @Outcome VARCHAR(24),
    @DurationMs INT = NULL,
    @Hostname VARCHAR(255) = NULL,
    @ClientVersion VARCHAR(32) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.CheckoutEvents (Username, AvdHost, Outcome, DurationMs, Hostname, ClientVersion)
    VALUES (
        LEFT(@Username, 255),
        LEFT(@AvdHost, 255),
        CASE WHEN @Outcome IN ('Assigned', 'Reused', 'NoneAvailable', 'ProvisionFailed', 'Error', 'Starting')
             THEN @Outcome ELSE 'Error' END,
        CASE WHEN @DurationMs < 0 THEN 0 ELSE @DurationMs END,
        LEFT(@Hostname, 255),
        NULLIF(LEFT(@ClientVersion, 32), '')
    );

    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS EventID;
END
GO
