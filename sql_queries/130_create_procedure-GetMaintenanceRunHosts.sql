-- The hosts of a maintenance run in order, each with its live broker state and latest
-- heartbeat, for the run details page and the scheduled advance.
--
-- Every age is computed here against the database clock that stamped the times, so the API
-- never compares clocks. HeartbeatAfterRestart and BootedAfterRestart tell whether the host
-- has reported since its restart was requested, and whether the boot that report implies
-- (received time less uptime) came after it: proof the restart really happened.

CREATE PROCEDURE [dbo].[GetMaintenanceRunHosts]
    @RunID INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @ReconcileIntervalSeconds INT;

    SELECT TOP 1 @ReconcileIntervalSeconds = ReconcileIntervalSeconds
    FROM dbo.LinuxHostSettings WHERE SettingsScope = 'Global' ORDER BY SettingsID;

    SELECT
        h.RunHostID, h.RunID, h.VMID, h.Hostname, h.Position, h.State, h.Version, h.Attempts,
        h.PatchToken, h.WasDrained, h.WasMaintenance, h.WasPoweredOff, h.RebootRequired, h.Detail,
        DATEDIFF(SECOND, h.StepStartedAt, @Now) AS StepAgeSeconds,
        DATEDIFF(SECOND, h.ActionRequestedAt, @Now) AS ActionAgeSeconds,
        DATEDIFF(SECOND, h.AdmittedAt, @Now) AS AdmittedAgeSeconds,
        DATEDIFF(SECOND, h.WarningSentAt, @Now) AS WarningAgeSeconds,
        DATEDIFF(SECOND, h.SignOutRequestedAt, @Now) AS SignOutAgeSeconds,
        DATEDIFF(SECOND, h.RestartRequestedAt, @Now) AS RestartAgeSeconds,
        CONVERT(VARCHAR(33), h.AdmittedAt, 126) + 'Z' AS AdmittedAtUtc,
        CONVERT(VARCHAR(33), h.WarningSentAt, 126) + 'Z' AS WarningSentAtUtc,
        CONVERT(VARCHAR(33), h.SignOutRequestedAt, 126) + 'Z' AS SignOutRequestedAtUtc,
        CONVERT(VARCHAR(33), h.PatchStartedAt, 126) + 'Z' AS PatchStartedAtUtc,
        CONVERT(VARCHAR(33), h.PatchFinishedAt, 126) + 'Z' AS PatchFinishedAtUtc,
        CONVERT(VARCHAR(33), h.RestartRequestedAt, 126) + 'Z' AS RestartRequestedAtUtc,
        CONVERT(VARCHAR(33), h.VerifiedAt, 126) + 'Z' AS VerifiedAtUtc,
        CONVERT(VARCHAR(33), h.CompletedAt, 126) + 'Z' AS CompletedAtUtc,
        CAST(CASE WHEN vm.VMID IS NULL THEN 0 ELSE 1 END AS BIT) AS Registered,
        vm.PowerState, vm.NetworkStatus, vm.VmStatus, vm.Username, vm.LeaseId, vm.CleanupPending, vm.CleanupUsername,
        vm.DrainRequested,
        -- Database-local, like the table's other dates: how recently the user checked the host out.
        DATEDIFF(SECOND, vm.LastCheckoutDate, GETDATE()) AS LastCheckoutAgeSeconds,
        hb.AgentVersion, hb.XrdpActive, hb.SessionsJson, hb.SessionCount, hb.UptimeSeconds,
        CASE WHEN hb.ReceivedAt IS NULL THEN NULL
             WHEN DATEDIFF(SECOND, hb.ReceivedAt, @Now) < 0 THEN 0
             ELSE DATEDIFF(SECOND, hb.ReceivedAt, @Now) END AS HeartbeatAgeSeconds,
        @ReconcileIntervalSeconds AS ReconcileIntervalSeconds,
        CAST(CASE WHEN h.RestartRequestedAt IS NOT NULL AND hb.ReceivedAt > h.RestartRequestedAt THEN 1 ELSE 0 END AS BIT) AS HeartbeatAfterRestart,
        CAST(CASE WHEN h.RestartRequestedAt IS NOT NULL AND hb.ReceivedAt > h.RestartRequestedAt
                       AND hb.UptimeSeconds IS NOT NULL AND hb.UptimeSeconds < 2000000000
                       AND DATEADD(SECOND, -CAST(hb.UptimeSeconds AS INT), hb.ReceivedAt) > h.RestartRequestedAt
                  THEN 1 ELSE 0 END AS BIT) AS BootedAfterRestart
    FROM dbo.MaintenanceRunHosts h
    LEFT JOIN dbo.VirtualMachines vm ON vm.VMID = h.VMID
    LEFT JOIN dbo.HostHeartbeats hb ON hb.Hostname = vm.Hostname
    WHERE h.RunID = @RunID
    ORDER BY h.Position;
END
GO
