-- Checkout events gain the Starting outcome (4.1): no host was ready, so the broker started one
-- for the user, or one was already starting, and told their AVD host to ask again shortly. A
-- user who waits records one Starting event each time their AVD host asks, then Assigned once
-- a host takes them.
--
-- ClientVersion is the version the AVD host's broker script reports with each checkout. A
-- script that reports one waits for a host to start; an older one gives up after three quick
-- attempts, so the scaling policy page lists the AVD hosts still running one.

IF COL_LENGTH('dbo.CheckoutEvents', 'ClientVersion') IS NULL
BEGIN
    ALTER TABLE dbo.CheckoutEvents ADD ClientVersion VARCHAR(32) NULL;
END;
GO

IF EXISTS (
    SELECT 1 FROM sys.check_constraints
    WHERE name = 'CK_CheckoutEvents_Outcome'
      AND parent_object_id = OBJECT_ID('dbo.CheckoutEvents')
      AND definition NOT LIKE N'%''Starting''%'
)
BEGIN
    ALTER TABLE dbo.CheckoutEvents DROP CONSTRAINT CK_CheckoutEvents_Outcome;
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.check_constraints
    WHERE name = 'CK_CheckoutEvents_Outcome' AND parent_object_id = OBJECT_ID('dbo.CheckoutEvents')
)
BEGIN
    ALTER TABLE dbo.CheckoutEvents WITH CHECK
    ADD CONSTRAINT CK_CheckoutEvents_Outcome
        CHECK (Outcome IN ('Assigned', 'Reused', 'NoneAvailable', 'ProvisionFailed', 'Error', 'Starting'));
END;
GO
