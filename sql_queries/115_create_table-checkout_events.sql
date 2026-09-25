-- One row per checkout request from an AVD host, for the dashboard's unmet demand and latency
-- figures. Written by the API after each checkout, whatever its outcome:
--   Assigned         a new assignment
--   Reused           the user already held the host (a reconnect)
--   NoneAvailable    no host could be given: demand the pool did not meet
--   ProvisionFailed  a host was chosen but the user could not be created on it
--   Error            the checkout failed in the broker
-- DurationMs is the whole checkout as the AVD host waited for it. OccurredAt is UTC. Rows are
-- removed after CHECKOUT_EVENT_RETENTION_DAYS by dbo.PurgeCheckoutEvents.

IF OBJECT_ID('dbo.CheckoutEvents', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CheckoutEvents (
        EventID BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_CheckoutEvents PRIMARY KEY,
        OccurredAt DATETIME2(3) NOT NULL CONSTRAINT DF_CheckoutEvents_OccurredAt DEFAULT (SYSUTCDATETIME()),
        Username VARCHAR(255) NULL,
        AvdHost VARCHAR(255) NULL,
        Outcome VARCHAR(24) NOT NULL,
        DurationMs INT NULL,
        Hostname VARCHAR(255) NULL,
        CONSTRAINT CK_CheckoutEvents_Outcome CHECK (Outcome IN ('Assigned', 'Reused', 'NoneAvailable', 'ProvisionFailed', 'Error')),
        CONSTRAINT CK_CheckoutEvents_Duration CHECK (DurationMs IS NULL OR DurationMs >= 0)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_CheckoutEvents_OccurredAt' AND object_id = OBJECT_ID('dbo.CheckoutEvents'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_CheckoutEvents_OccurredAt
    ON dbo.CheckoutEvents (OccurredAt)
    INCLUDE (Outcome, DurationMs);
END;
GO
