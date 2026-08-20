-- Adds a dashboard summary aggregate for the VM pool.
--
-- This lives after the VM table and later VM column additions so fresh deployments validate
-- every referenced column before the procedure is created.

CREATE PROCEDURE [dbo].[GetVmSummary]
AS
BEGIN
    SELECT
        COUNT(*) AS TotalVMs,
        COALESCE(SUM(CASE WHEN VmStatus = 'Available' THEN 1 ELSE 0 END), 0) AS Available,
        COALESCE(SUM(CASE WHEN VmStatus = 'CheckedOut' THEN 1 ELSE 0 END), 0) AS CheckedOut,
        COALESCE(SUM(CASE WHEN VmStatus = 'Maintenance' THEN 1 ELSE 0 END), 0) AS Maintenance,
        COALESCE(SUM(CASE WHEN VmStatus = 'Released' THEN 1 ELSE 0 END), 0) AS Released,
        COALESCE(SUM(CASE WHEN PowerState = 'On' THEN 1 ELSE 0 END), 0) AS PoweredOn,
        COALESCE(SUM(CASE WHEN PowerState = 'Off' THEN 1 ELSE 0 END), 0) AS PoweredOff,
        COALESCE(SUM(CASE WHEN NetworkStatus = 'Unreachable' THEN 1 ELSE 0 END), 0) AS Unreachable,
        COALESCE(SUM(CASE WHEN VmStatus = 'Available' AND PowerState = 'On' AND NetworkStatus = 'Reachable' THEN 1 ELSE 0 END), 0) AS Ready
    FROM dbo.VirtualMachines;
END
GO
