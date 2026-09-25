-- Redefines dbo.GetVmSummary to also count, as the scaler does, the hosts that can take a user
-- (Serviceable) and those in use (InUse), so the dashboard's utilization matches the figure
-- scaling acts on. The other columns are unchanged from 082.

CREATE PROCEDURE [dbo].[GetVmSummary]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now DATETIME = GETDATE();

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
                           AND Username IS NULL AND LeaseId IS NULL THEN 1 ELSE 0 END), 0) AS Ready,
        -- The scaler's definitions (dbo.TriggerScalingLogic).
        COALESCE(SUM(CASE WHEN PowerState = 'On' AND VmStatus <> 'Maintenance' AND DrainRequested = 0
                           AND (NetworkStatus = 'Reachable' OR PowerStateChangedDate >= DATEADD(MINUTE, -10, @Now))
                           AND NOT (VmStatus = 'Available' AND (Username IS NOT NULL OR LeaseId IS NOT NULL))
                      THEN 1 ELSE 0 END), 0) AS Serviceable,
        COALESCE(SUM(CASE WHEN PowerState = 'On' AND DrainRequested = 0
                           AND (VmStatus IN ('CheckedOut', 'Released') OR CleanupPending = 1)
                      THEN 1 ELSE 0 END), 0) AS InUse
    FROM dbo.VirtualMachines;
END
GO
