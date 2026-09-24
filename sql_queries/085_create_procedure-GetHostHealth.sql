-- Every registered host with its latest heartbeat, for the portal's Fleet health page and
-- the host agent card on a VM's details. @Hostname narrows it to one host.
--
-- HeartbeatAgeSeconds is computed here, against the database clock that stamped ReceivedAt,
-- so the portal never has to compare timestamps across time zones. The current settings
-- version and reconcile interval come back on every row: the API needs them to flag drift and
-- to decide when a heartbeat is stale.

CREATE PROCEDURE [dbo].[GetHostHealth]
    @Hostname VARCHAR(255) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CurrentSettingsVersion INT;
    DECLARE @ReconcileIntervalSeconds INT;

    SELECT TOP 1
        @CurrentSettingsVersion = SettingsVersion,
        @ReconcileIntervalSeconds = ReconcileIntervalSeconds
    FROM dbo.LinuxHostSettings
    WHERE SettingsScope = 'Global'
    ORDER BY SettingsID;

    SELECT
        vm.VMID,
        vm.Hostname,
        vm.PowerState,
        vm.NetworkStatus,
        vm.VmStatus,
        vm.DrainRequested,
        vm.CleanupPending,
        vm.Username,
        vm.SettingsVersion AS AppliedSettingsVersion,
        @CurrentSettingsVersion AS CurrentSettingsVersion,
        @ReconcileIntervalSeconds AS ReconcileIntervalSeconds,
        CONVERT(VARCHAR(33), hb.ReceivedAt, 126) + 'Z' AS LastHeartbeatUtc,
        -- Never negative, even if the clock that stamped the heartbeat is a moment ahead.
        CASE
            WHEN hb.ReceivedAt IS NULL THEN NULL
            WHEN DATEDIFF(SECOND, hb.ReceivedAt, SYSUTCDATETIME()) < 0 THEN 0
            ELSE DATEDIFF(SECOND, hb.ReceivedAt, SYSUTCDATETIME())
        END AS HeartbeatAgeSeconds,
        hb.AgentVersion,
        hb.ScriptVersionsJson,
        hb.SettingsVersion AS ReportedSettingsVersion,
        hb.OsId,
        hb.OsVersion,
        hb.OsName,
        hb.KernelVersion,
        hb.Desktop,
        hb.XrdpVersion,
        hb.XrdpActive,
        hb.NfsReachable,
        hb.NfsMountCount,
        hb.LoadAverage,
        hb.CpuCount,
        hb.MemoryAvailableMb,
        hb.MemoryTotalMb,
        hb.RootDiskFreePct,
        hb.UptimeSeconds,
        hb.SessionCount,
        hb.SessionsJson
    FROM dbo.VirtualMachines vm
    LEFT JOIN dbo.HostHeartbeats hb ON hb.Hostname = vm.Hostname
    WHERE @Hostname IS NULL OR vm.Hostname = @Hostname
    ORDER BY vm.Hostname;
END
GO
