-- One row describing the fleet now (4.7). The API logs it to Application Insights as
-- "fleet snapshot" at the end of every scaling run, every five minutes, and the monitoring
-- workbook and alerts read it there:
--   ReadyHosts       hosts a new user can be given now: Available, on, reachable, not draining,
--                    and with no user, lease, or pending cleanup (CheckoutVm's test).
--   PoweredOn        hosts recorded as on.
--   Serviceable      hosts that can take a user now or once they finish starting, and InUse,
--                    hosts with a user, a released session, or a pending cleanup, both counted
--                    as TriggerScalingLogic counts them.
--   Waiting          users waiting for a host to start (dbo.fnWaitingCheckoutUsers).
--   Booting          hosts started in the last ten minutes that are not reachable yet.
--   StaleHeartbeats  hosts on and reachable, not in maintenance, and on for longer than
--                    @StaleAfterSeconds, whose agent has not reported within @StaleAfterSeconds.
--   NfsUnreachable   hosts on, not in maintenance, whose fresh heartbeat reports the home directory
--                    share unreachable, and XrdpInactive, those whose fresh heartbeat reports xrdp
--                    not running. A host in maintenance is being worked on, so none of the three
--                    health counts, which the unhealthy hosts alert adds up, includes it.
--   Draining, Maintenance, TotalHosts
--   EffectiveMinVMs  the active phase's MinVMs as scaling reads it: 0 is read as 1 while start on
--                    demand is off. MaxVMs is the phase's maximum, never below that. Both are
--                    NULL when no scaling rule is configured.
--   StartOnDemandEnabled, StaleAfterSeconds
-- @StaleAfterSeconds defaults to the API's heartbeat_stale_after: three reconcile intervals,
-- never under three minutes. The procedure only reads, so it takes no scaling lock.

CREATE PROCEDURE [dbo].[GetFleetSnapshot]
    @StaleAfterSeconds INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now DATETIME = GETDATE(), @NowUtc DATETIME2(3) = SYSUTCDATETIME(), @Boot INT = 10;
    DECLARE @ReconcileIntervalSeconds INT, @StartOnDemand BIT, @MinVMs INT, @MaxVMs INT, @Waiting INT;

    IF @StaleAfterSeconds IS NULL OR @StaleAfterSeconds < 1
    BEGIN
        SELECT TOP 1 @ReconcileIntervalSeconds = ReconcileIntervalSeconds
        FROM dbo.LinuxHostSettings WHERE SettingsScope = 'Global' ORDER BY SettingsID;
        SET @StaleAfterSeconds = CASE WHEN 3 * COALESCE(@ReconcileIntervalSeconds, 60) > 180
                                      THEN 3 * COALESCE(@ReconcileIntervalSeconds, 60) ELSE 180 END;
    END

    SET @StartOnDemand = COALESCE((SELECT StartOnDemandEnabled FROM dbo.ScalingPolicy WHERE PolicyID = 1), 0);
    SELECT @MinVMs = MinVMs, @MaxVMs = MaxVMs FROM dbo.fnActiveScalingPhase(NULL);
    SET @MinVMs = CASE WHEN @MinVMs < 0 THEN 0 WHEN @MinVMs < 1 AND @StartOnDemand = 0 THEN 1 ELSE @MinVMs END;
    SET @MaxVMs = CASE WHEN @MaxVMs < @MinVMs THEN @MinVMs ELSE @MaxVMs END;
    SELECT @Waiting = COUNT(*) FROM dbo.fnWaitingCheckoutUsers();

    SELECT
        COALESCE(SUM(CASE WHEN vm.VmStatus = 'Available' AND vm.PowerState = 'On' AND vm.NetworkStatus = 'Reachable'
                               AND vm.CleanupPending = 0 AND vm.DrainRequested = 0 AND vm.Username IS NULL AND vm.LeaseId IS NULL
                          THEN 1 ELSE 0 END), 0) AS ReadyHosts,
        COALESCE(SUM(CASE WHEN vm.PowerState = 'On' THEN 1 ELSE 0 END), 0) AS PoweredOn,
        COALESCE(SUM(CASE WHEN vm.PowerState = 'On' AND vm.VmStatus <> 'Maintenance' AND vm.DrainRequested = 0
                               AND (vm.NetworkStatus = 'Reachable' OR vm.PowerStateChangedDate >= DATEADD(MINUTE, -@Boot, @Now))
                               AND NOT (vm.VmStatus = 'Available' AND (vm.Username IS NOT NULL OR vm.LeaseId IS NOT NULL))
                          THEN 1 ELSE 0 END), 0) AS Serviceable,
        COALESCE(SUM(CASE WHEN vm.PowerState = 'On' AND vm.DrainRequested = 0
                               AND (vm.VmStatus IN ('CheckedOut', 'Released') OR vm.CleanupPending = 1)
                          THEN 1 ELSE 0 END), 0) AS InUse,
        @Waiting AS Waiting,
        COALESCE(SUM(CASE WHEN vm.PowerState = 'On' AND vm.NetworkStatus = 'Unreachable' AND vm.VmStatus <> 'Maintenance'
                               AND vm.DrainRequested = 0 AND vm.PowerStateChangedDate >= DATEADD(MINUTE, -@Boot, @Now)
                          THEN 1 ELSE 0 END), 0) AS Booting,
        COALESCE(SUM(CASE WHEN vm.PowerState = 'On' AND vm.NetworkStatus = 'Reachable' AND vm.VmStatus <> 'Maintenance'
                               AND (vm.PowerStateChangedDate IS NULL OR vm.PowerStateChangedDate < DATEADD(SECOND, -@StaleAfterSeconds, @Now))
                               AND (hb.ReceivedAt IS NULL OR hb.ReceivedAt < DATEADD(SECOND, -@StaleAfterSeconds, @NowUtc))
                          THEN 1 ELSE 0 END), 0) AS StaleHeartbeats,
        COALESCE(SUM(CASE WHEN vm.PowerState = 'On' AND vm.VmStatus <> 'Maintenance'
                               AND hb.ReceivedAt >= DATEADD(SECOND, -@StaleAfterSeconds, @NowUtc)
                               AND hb.NfsReachable = 0
                          THEN 1 ELSE 0 END), 0) AS NfsUnreachable,
        COALESCE(SUM(CASE WHEN vm.PowerState = 'On' AND vm.VmStatus <> 'Maintenance'
                               AND hb.ReceivedAt >= DATEADD(SECOND, -@StaleAfterSeconds, @NowUtc)
                               AND hb.XrdpActive = 0
                          THEN 1 ELSE 0 END), 0) AS XrdpInactive,
        COALESCE(SUM(CASE WHEN vm.DrainRequested = 1 THEN 1 ELSE 0 END), 0) AS Draining,
        COALESCE(SUM(CASE WHEN vm.VmStatus = 'Maintenance' THEN 1 ELSE 0 END), 0) AS Maintenance,
        COUNT(vm.VMID) AS TotalHosts,
        @MinVMs AS EffectiveMinVMs,
        @MaxVMs AS MaxVMs,
        @StartOnDemand AS StartOnDemandEnabled,
        @StaleAfterSeconds AS StaleAfterSeconds
    FROM dbo.VirtualMachines vm
    LEFT JOIN dbo.HostHeartbeats hb ON hb.Hostname = vm.Hostname;
END
GO
