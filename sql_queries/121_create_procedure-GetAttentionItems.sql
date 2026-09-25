-- What needs an operator now, for the dashboard's Attention panel. One row per item:
--   no-ready-hosts   hosts are registered but none can take a new user and none is starting.
--                    Scaling always keeps at least one (MinVMs is never below one), so the
--                    pool is exhausted or its hosts are failing.
--   denied-checkouts checkouts that found no host in the last @DeniedMinutes (ItemCount).
--   unreachable      powered on, not in maintenance, not just starting, and not reachable for
--                    at least @UnreachableMinutes. The time comes from the temporal history:
--                    the later of the end of the host's last reachable version and its power-on.
--   cleanup-stuck    on and reachable, but the previous user has not been removed for at least
--                    @CleanupMinutes, measured from the end of its last version without a
--                    pending cleanup. Cleanup is retried every two minutes, so this means
--                    several attempts failed.
--   never-connected  checked out at least @NotConnectedMinutes ago, not checked out again
--                    since, and the host's current heartbeat does not report the user.
-- AgeSeconds is how long the condition has lasted. The history is searched for the last seven
-- days only; a condition older than that reports seven days or its power-on time.

CREATE PROCEDURE [dbo].[GetAttentionItems]
    @UnreachableMinutes INT = 10,
    @CleanupMinutes INT = 15,
    @NotConnectedMinutes INT = 30,
    @DeniedMinutes INT = 60
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @NowUtc DATETIME2(0) = CAST(SYSUTCDATETIME() AS DATETIME2(0));
    DECLARE @HistoryFloor DATETIME2(0) = DATEADD(DAY, -7, @NowUtc);
    DECLARE @Now DATETIME = GETDATE();
    DECLARE @OffsetMinutes INT = DATEDIFF(MINUTE, GETDATE(), GETUTCDATE());
    DECLARE @Boot INT = 10;
    DECLARE @ReconcileIntervalSeconds INT, @FreshSeconds INT;
    DECLARE @Items TABLE (
        Kind VARCHAR(32) NOT NULL, VMID INT NULL, Hostname VARCHAR(255) NULL, Username VARCHAR(255) NULL,
        AgeSeconds INT NULL, ItemCount INT NULL
    );

    SELECT TOP 1 @ReconcileIntervalSeconds = ReconcileIntervalSeconds
    FROM dbo.LinuxHostSettings WHERE SettingsScope = 'Global' ORDER BY SettingsID;
    -- The API's heartbeat_stale_after: three reconcile intervals, never under three minutes.
    SET @FreshSeconds = CASE WHEN 3 * COALESCE(@ReconcileIntervalSeconds, 60) > 180 THEN 3 * COALESCE(@ReconcileIntervalSeconds, 60) ELSE 180 END;

    IF EXISTS (SELECT 1 FROM dbo.VirtualMachines)
       AND NOT EXISTS (
           SELECT 1 FROM dbo.VirtualMachines
           WHERE VmStatus = 'Available' AND PowerState = 'On' AND NetworkStatus = 'Reachable'
             AND CleanupPending = 0 AND DrainRequested = 0 AND Username IS NULL AND LeaseId IS NULL
       )
       AND NOT EXISTS (
           SELECT 1 FROM dbo.VirtualMachines
           WHERE PowerState = 'On' AND NetworkStatus = 'Unreachable' AND VmStatus <> 'Maintenance'
             AND DrainRequested = 0 AND PowerStateChangedDate >= DATEADD(MINUTE, -@Boot, @Now)
       )
    BEGIN
        INSERT INTO @Items (Kind) VALUES ('no-ready-hosts');
    END

    INSERT INTO @Items (Kind, ItemCount, AgeSeconds)
    SELECT 'denied-checkouts', COUNT(*), DATEDIFF(SECOND, MAX(OccurredAt), SYSUTCDATETIME())
    FROM dbo.CheckoutEvents
    WHERE Outcome = 'NoneAvailable'
      AND OccurredAt >= DATEADD(MINUTE, -@DeniedMinutes, SYSUTCDATETIME())
    HAVING COUNT(*) > 0;

    INSERT INTO @Items (Kind, VMID, Hostname, AgeSeconds)
    SELECT 'unreachable', vm.VMID, vm.Hostname, DATEDIFF(SECOND, since.SinceUtc, @NowUtc)
    FROM dbo.VirtualMachines vm
    OUTER APPLY (
        SELECT MAX(h.SysEndTime) AS LastReachableEnd
        FROM dbo.VirtualMachinesHistory h
        WHERE h.VMID = vm.VMID AND h.NetworkStatus = 'Reachable' AND h.SysEndTime >= @HistoryFloor
    ) lr
    CROSS APPLY (
        SELECT DATEADD(MINUTE, @OffsetMinutes, CAST(COALESCE(vm.PowerStateChangedDate, vm.CreateDate, @Now) AS DATETIME2(0))) AS PoweredOnUtc
    ) po
    CROSS APPLY (
        SELECT CASE WHEN lr.LastReachableEnd > po.PoweredOnUtc THEN CAST(lr.LastReachableEnd AS DATETIME2(0)) ELSE po.PoweredOnUtc END AS SinceUtc
    ) since
    WHERE vm.PowerState = 'On'
      AND vm.NetworkStatus = 'Unreachable'
      AND vm.VmStatus <> 'Maintenance'
      AND (vm.PowerStateChangedDate IS NULL OR vm.PowerStateChangedDate < DATEADD(MINUTE, -@Boot, @Now))
      AND DATEDIFF(SECOND, since.SinceUtc, @NowUtc) >= @UnreachableMinutes * 60;

    INSERT INTO @Items (Kind, VMID, Hostname, Username, AgeSeconds)
    SELECT 'cleanup-stuck', vm.VMID, vm.Hostname, vm.CleanupUsername,
           DATEDIFF(SECOND, COALESCE(CAST(np.LastNotPendingEnd AS DATETIME2(0)), @HistoryFloor), @NowUtc)
    FROM dbo.VirtualMachines vm
    OUTER APPLY (
        SELECT MAX(h.SysEndTime) AS LastNotPendingEnd
        FROM dbo.VirtualMachinesHistory h
        WHERE h.VMID = vm.VMID AND h.CleanupPending = 0 AND h.SysEndTime >= @HistoryFloor
    ) np
    WHERE vm.CleanupPending = 1
      AND vm.PowerState = 'On'
      AND vm.NetworkStatus = 'Reachable'
      AND DATEDIFF(SECOND, COALESCE(CAST(np.LastNotPendingEnd AS DATETIME2(0)), @HistoryFloor), @NowUtc) >= @CleanupMinutes * 60;

    INSERT INTO @Items (Kind, VMID, Hostname, Username, AgeSeconds)
    SELECT 'never-connected', vm.VMID, vm.Hostname, vm.Username, DATEDIFF(SECOND, vm.AssignedDate, @Now)
    FROM dbo.VirtualMachines vm
    INNER JOIN dbo.HostHeartbeats hb ON hb.Hostname = vm.Hostname
    WHERE vm.VmStatus = 'CheckedOut'
      AND vm.AssignedDate < DATEADD(MINUTE, -@NotConnectedMinutes, @Now)
      AND vm.LastCheckoutDate < DATEADD(MINUTE, -@NotConnectedMinutes, @Now)
      AND hb.ReceivedAt >= DATEADD(SECOND, -@FreshSeconds, SYSUTCDATETIME())
      AND NOT EXISTS (
          SELECT 1 FROM OPENJSON(hb.SessionsJson) WITH (Username VARCHAR(64) '$.username') s
          WHERE s.Username = vm.Username
      );

    SELECT Kind, VMID, Hostname, Username, AgeSeconds, ItemCount
    FROM @Items
    ORDER BY CASE Kind WHEN 'no-ready-hosts' THEN 0 WHEN 'denied-checkouts' THEN 1 WHEN 'unreachable' THEN 2
                       WHEN 'cleanup-stuck' THEN 3 ELSE 4 END,
             AgeSeconds DESC, Hostname;
END
GO