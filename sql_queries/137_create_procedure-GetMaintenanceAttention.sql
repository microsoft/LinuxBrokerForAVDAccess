-- Hosts a maintenance run could not patch and that are still out of rotation, for the
-- dashboard's Attention panel: from the active run, or a run that ended in the last day.

CREATE PROCEDURE [dbo].[GetMaintenanceAttention]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    SELECT h.RunID, h.RunHostID, h.VMID, h.Hostname, h.Detail,
           DATEDIFF(SECOND, h.CompletedAt, @Now) AS AgeSeconds
    FROM dbo.MaintenanceRunHosts h
    INNER JOIN dbo.MaintenanceRuns r ON r.RunID = h.RunID
    INNER JOIN dbo.VirtualMachines vm ON vm.VMID = h.VMID
    WHERE h.State = 'Failed'
      AND (r.Status IN ('Active', 'Paused', 'Stopping') OR r.EndedAt >= DATEADD(HOUR, -24, @Now))
      AND (vm.VmStatus = 'Maintenance' OR vm.DrainRequested = 1)
    ORDER BY h.CompletedAt DESC, h.Hostname;
END
GO
