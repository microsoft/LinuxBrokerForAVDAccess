-- Redefines dbo.GetVmSummary to count draining hosts and to leave them out of Ready, matching
-- CheckoutVm, which no longer assigns them to new users.

CREATE PROCEDURE [dbo].[GetVmSummary]
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        COUNT(*) AS TotalVMs,
        COALESCE(SUM(CASE WHEN VmStatus = 'Available' THEN 1 ELSE 0 END), 0) AS Available,
        COALESCE(SUM(CASE WHEN VmStatus = 'CheckedOut' THEN 1 ELSE 0 END), 0) AS CheckedOut,
        COALESCE(SUM(CASE WHEN VmStatus = 'Maintenance' THEN 1 ELSE 0 END), 0) AS Maintenance,
        COALESCE(SUM(CASE WHEN VmStatus = 'Released' THEN 1 ELSE 0 END), 0) AS Released,
        COALESCE(SUM(CASE WHEN PowerState = 'On' THEN 1 ELSE 0 END), 0) AS PoweredOn,
        COALESCE(SUM(CASE WHEN PowerState = 'Off' THEN 1 ELSE 0 END), 0) AS PoweredOff,
        COALESCE(SUM(CASE WHEN NetworkStatus = 'Unreachable' THEN 1 ELSE 0 END), 0) AS Unreachable,
        COALESCE(SUM(CASE WHEN CleanupPending = 1 THEN 1 ELSE 0 END), 0) AS CleanupPending,
        COALESCE(SUM(CASE WHEN DrainRequested = 1 THEN 1 ELSE 0 END), 0) AS Draining,
        -- The same condition CheckoutVm uses to pick a host.
        COALESCE(SUM(CASE WHEN VmStatus = 'Available' AND PowerState = 'On' AND NetworkStatus = 'Reachable'
                           AND CleanupPending = 0 AND DrainRequested = 0
                           AND Username IS NULL AND LeaseId IS NULL THEN 1 ELSE 0 END), 0) AS Ready
    FROM dbo.VirtualMachines;
END
GO
