-- Every session the broker knows about, for the portal's Sessions page: each assignment
-- (checked out, released, or waiting for its user to be cleaned up) joined with the sessions
-- the host's heartbeat last reported, by host and user. A session a host reports without an
-- assignment comes back too, with no assignment columns; the API calls it unmanaged.
--
-- Ages are computed against the database clock: the VM dates are database-local, and the
-- heartbeat's epoch times are compared with SYSUTCDATETIME(). The API derives each row's
-- state from these facts.

CREATE PROCEDURE [dbo].[GetSessions]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @GracePeriodSeconds INT;
    DECLARE @ReconcileIntervalSeconds INT;

    SELECT TOP 1
        @GracePeriodSeconds = GracePeriodSeconds,
        @ReconcileIntervalSeconds = ReconcileIntervalSeconds
    FROM dbo.LinuxHostSettings
    WHERE SettingsScope = 'Global'
    ORDER BY SettingsID;

    DECLARE @NowEpoch BIGINT = DATEDIFF_BIG(SECOND, '19700101', SYSUTCDATETIME());

    WITH Assignments AS (
        SELECT vm.VMID, vm.Hostname, vm.Username, vm.AvdHost, vm.VmStatus,
               CAST(0 AS BIT) AS CleanupPending, vm.AssignedDate, vm.LastCheckoutDate, vm.ReleasedDate
        FROM dbo.VirtualMachines vm
        WHERE vm.Username IS NOT NULL
          AND vm.VmStatus IN ('CheckedOut', 'Released')
        UNION ALL
        SELECT vm.VMID, vm.Hostname, vm.CleanupUsername, NULL, vm.VmStatus,
               CAST(1 AS BIT), NULL, NULL, NULL
        FROM dbo.VirtualMachines vm
        WHERE vm.CleanupPending = 1
          AND vm.CleanupUsername IS NOT NULL
          AND (vm.Username IS NULL OR vm.Username <> vm.CleanupUsername)
    ),
    Reported AS (
        SELECT hb.Hostname, s.Username, s.SessionState, s.SessionStart, s.DisconnectedSince, s.IdleSeconds
        FROM dbo.HostHeartbeats hb
        CROSS APPLY OPENJSON(hb.SessionsJson)
        WITH (
            Username VARCHAR(64) '$.username',
            SessionState VARCHAR(16) '$.state',
            SessionStart BIGINT '$.sessionStart',
            DisconnectedSince BIGINT '$.disconnectedSince',
            IdleSeconds BIGINT '$.idleSeconds'
        ) s
        WHERE hb.SessionsJson IS NOT NULL
          AND s.Username IS NOT NULL
    ),
    Combined AS (
        SELECT
            a.VMID AS AssignedVMID,
            COALESCE(a.Hostname, r.Hostname) AS Hostname,
            COALESCE(a.Username, r.Username) AS Username,
            a.AvdHost,
            a.VmStatus AS AssignedVmStatus,
            a.CleanupPending,
            a.AssignedDate,
            a.LastCheckoutDate,
            a.ReleasedDate,
            -- A pending cleanup is tracked by the broker but is no longer an assignment.
            CAST(CASE WHEN a.Username IS NULL OR a.CleanupPending = 1 THEN 0 ELSE 1 END AS BIT) AS HasAssignment,
            CAST(CASE WHEN a.Username IS NULL THEN 0 ELSE 1 END AS BIT) AS BrokerTracked,
            r.SessionState,
            r.SessionStart,
            r.DisconnectedSince,
            r.IdleSeconds
        FROM Assignments a
        FULL OUTER JOIN Reported r
            ON r.Hostname = a.Hostname
           AND r.Username = a.Username
    )
    SELECT
        vm.VMID,
        c.Hostname,
        c.Username,
        c.AvdHost,
        vm.VmStatus,
        vm.PowerState,
        vm.NetworkStatus,
        vm.DrainRequested,
        c.HasAssignment,
        c.BrokerTracked,
        COALESCE(c.CleanupPending, CAST(0 AS BIT)) AS CleanupPending,
        c.SessionState,
        c.SessionStart AS SessionStartEpoch,
        c.DisconnectedSince AS DisconnectedSinceEpoch,
        CASE WHEN c.DisconnectedSince IS NULL THEN NULL
             WHEN @NowEpoch - c.DisconnectedSince < 0 THEN 0
             ELSE @NowEpoch - c.DisconnectedSince END AS DisconnectedForSeconds,
        c.IdleSeconds,
        CASE WHEN c.AssignedDate IS NULL THEN NULL ELSE DATEDIFF(SECOND, c.AssignedDate, GETDATE()) END AS AssignedForSeconds,
        CASE WHEN c.LastCheckoutDate IS NULL THEN NULL ELSE DATEDIFF(SECOND, c.LastCheckoutDate, GETDATE()) END AS LastCheckoutAgeSeconds,
        CASE WHEN c.AssignedVmStatus = 'Released' AND c.ReleasedDate IS NOT NULL
             THEN @GracePeriodSeconds - DATEDIFF(SECOND, c.ReleasedDate, GETDATE()) END AS GraceRemainingSeconds,
        CASE WHEN hb.ReceivedAt IS NULL THEN NULL
             WHEN DATEDIFF(SECOND, hb.ReceivedAt, SYSUTCDATETIME()) < 0 THEN 0
             ELSE DATEDIFF(SECOND, hb.ReceivedAt, SYSUTCDATETIME()) END AS HeartbeatAgeSeconds,
        @GracePeriodSeconds AS GracePeriodSeconds,
        @ReconcileIntervalSeconds AS ReconcileIntervalSeconds
    FROM Combined c
    LEFT JOIN dbo.VirtualMachines vm
        ON vm.VMID = c.AssignedVMID
        OR (c.AssignedVMID IS NULL AND vm.Hostname = c.Hostname)
    LEFT JOIN dbo.HostHeartbeats hb ON hb.Hostname = c.Hostname
    ORDER BY c.Username, c.Hostname;
END
GO
