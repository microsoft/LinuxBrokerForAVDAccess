-- One page of the host list for the portal, filtered, searched and sorted in SQL so the page
-- stays fast however many hosts are registered.
--
--   @Search      matches hostname, IP address, user, status or OS name (LIKE, wildcards
--                escaped).
--   @Status      all, ready, in-use, released, maintenance, draining, unreachable, off or
--                cleanup; the same tests as dbo.GetVmStatusCounts and dbo.CheckoutVm.
--   @Sort        hostname, status, power, network, user, ip, os, agent, heartbeat,
--                sessions, vmid or updated; anything else sorts by hostname.
--   @Offset, @PageSize  the page; the size is clamped to 1-200.
--
-- Each row carries the host's latest heartbeat (OS, agent, sessions) and the current
-- settings version, and TotalCount, the rows matching before paging.

CREATE PROCEDURE [dbo].[GetVmsPaged]
    @Search NVARCHAR(128) = NULL,
    @Status VARCHAR(16) = NULL,
    @Sort VARCHAR(16) = 'hostname',
    @Descending BIT = 0,
    @Offset INT = 0,
    @PageSize INT = 50
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Size INT = CASE WHEN @PageSize IS NULL OR @PageSize < 1 THEN 50 WHEN @PageSize > 200 THEN 200 ELSE @PageSize END;
    DECLARE @Skip INT = CASE WHEN @Offset IS NULL OR @Offset < 0 THEN 0 ELSE @Offset END;
    DECLARE @Term NVARCHAR(128) = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @Pattern NVARCHAR(400) = CASE WHEN @Term IS NULL THEN NULL
        ELSE N'%' + REPLACE(REPLACE(REPLACE(@Term, N'[', N'[[]'), N'%', N'[%]'), N'_', N'[_]') + N'%' END;
    DECLARE @Filter VARCHAR(16) = LOWER(COALESCE(NULLIF(LTRIM(RTRIM(@Status)), ''), 'all'));
    DECLARE @Key VARCHAR(16) = LOWER(COALESCE(@Sort, 'hostname'));
    DECLARE @Desc BIT = COALESCE(@Descending, 0);
    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @CurrentSettingsVersion INT, @ReconcileIntervalSeconds INT;

    SELECT TOP 1 @CurrentSettingsVersion = SettingsVersion, @ReconcileIntervalSeconds = ReconcileIntervalSeconds
    FROM dbo.LinuxHostSettings WHERE SettingsScope = 'Global' ORDER BY SettingsID;

    ;WITH Hosts AS (
        SELECT
            vm.VMID, vm.Hostname, vm.IPAddress, vm.PowerState, vm.NetworkStatus, vm.VmStatus, vm.Username, vm.AvdHost,
            vm.CreateDate, vm.LastUpdateDate, vm.Description, vm.SettingsVersion, vm.SettingsAppliedDate, vm.ReleasedDate,
            vm.CleanupPending, vm.CleanupUsername, vm.PowerStateChangedDate, vm.DrainRequested, vm.DrainRequestedDate,
            hb.OsName, hb.OsVersion, hb.AgentVersion, hb.XrdpActive, hb.SessionCount, hb.SessionsJson,
            CONVERT(VARCHAR(33), hb.ReceivedAt, 126) + 'Z' AS LastHeartbeatUtc,
            CASE WHEN hb.ReceivedAt IS NULL THEN NULL
                 WHEN DATEDIFF(SECOND, hb.ReceivedAt, @Now) < 0 THEN 0
                 ELSE DATEDIFF(SECOND, hb.ReceivedAt, @Now) END AS HeartbeatAgeSeconds,
            CAST(CASE WHEN vm.VmStatus = 'Available' AND vm.PowerState = 'On' AND vm.NetworkStatus = 'Reachable'
                           AND vm.CleanupPending = 0 AND vm.DrainRequested = 0 AND vm.Username IS NULL AND vm.LeaseId IS NULL
                      THEN 1 ELSE 0 END AS BIT) AS Ready
        FROM dbo.VirtualMachines vm
        LEFT JOIN dbo.HostHeartbeats hb ON hb.Hostname = vm.Hostname
        WHERE (@Pattern IS NULL
               OR vm.Hostname LIKE @Pattern OR vm.IPAddress LIKE @Pattern OR vm.Username LIKE @Pattern
               OR vm.VmStatus LIKE @Pattern OR hb.OsName LIKE @Pattern)
    ),
    Matching AS (
        SELECT * FROM Hosts
        WHERE @Filter = 'all'
           OR (@Filter = 'ready' AND Ready = 1)
           OR (@Filter = 'in-use' AND VmStatus = 'CheckedOut')
           OR (@Filter = 'released' AND VmStatus = 'Released')
           OR (@Filter = 'maintenance' AND VmStatus = 'Maintenance')
           OR (@Filter = 'draining' AND DrainRequested = 1)
           OR (@Filter = 'unreachable' AND PowerState = 'On' AND NetworkStatus = 'Unreachable')
           OR (@Filter = 'off' AND PowerState = 'Off')
           OR (@Filter = 'cleanup' AND CleanupPending = 1)
    )
    SELECT
        VMID, Hostname, IPAddress, PowerState, NetworkStatus, VmStatus, Username, AvdHost, CreateDate, LastUpdateDate,
        Description, SettingsVersion, SettingsAppliedDate, ReleasedDate, CleanupPending, CleanupUsername,
        PowerStateChangedDate, DrainRequested, DrainRequestedDate, Ready, OsName, OsVersion, AgentVersion, XrdpActive,
        SessionCount, SessionsJson, LastHeartbeatUtc, HeartbeatAgeSeconds,
        @CurrentSettingsVersion AS CurrentSettingsVersion, @ReconcileIntervalSeconds AS ReconcileIntervalSeconds,
        COUNT(*) OVER () AS TotalCount
    FROM Matching
    ORDER BY
        CASE WHEN @Key = 'status' AND @Desc = 0 THEN VmStatus END ASC,
        CASE WHEN @Key = 'status' AND @Desc = 1 THEN VmStatus END DESC,
        CASE WHEN @Key = 'power' AND @Desc = 0 THEN PowerState END ASC,
        CASE WHEN @Key = 'power' AND @Desc = 1 THEN PowerState END DESC,
        CASE WHEN @Key = 'network' AND @Desc = 0 THEN NetworkStatus END ASC,
        CASE WHEN @Key = 'network' AND @Desc = 1 THEN NetworkStatus END DESC,
        CASE WHEN @Key = 'user' AND @Desc = 0 THEN Username END ASC,
        CASE WHEN @Key = 'user' AND @Desc = 1 THEN Username END DESC,
        CASE WHEN @Key = 'ip' AND @Desc = 0 THEN IPAddress END ASC,
        CASE WHEN @Key = 'ip' AND @Desc = 1 THEN IPAddress END DESC,
        CASE WHEN @Key = 'os' AND @Desc = 0 THEN OsName END ASC,
        CASE WHEN @Key = 'os' AND @Desc = 1 THEN OsName END DESC,
        CASE WHEN @Key = 'agent' AND @Desc = 0 THEN AgentVersion END ASC,
        CASE WHEN @Key = 'agent' AND @Desc = 1 THEN AgentVersion END DESC,
        CASE WHEN @Key = 'heartbeat' AND @Desc = 0 THEN HeartbeatAgeSeconds END ASC,
        CASE WHEN @Key = 'heartbeat' AND @Desc = 1 THEN HeartbeatAgeSeconds END DESC,
        CASE WHEN @Key = 'sessions' AND @Desc = 0 THEN SessionCount END ASC,
        CASE WHEN @Key = 'sessions' AND @Desc = 1 THEN SessionCount END DESC,
        CASE WHEN @Key = 'vmid' AND @Desc = 0 THEN VMID END ASC,
        CASE WHEN @Key = 'vmid' AND @Desc = 1 THEN VMID END DESC,
        CASE WHEN @Key = 'updated' AND @Desc = 0 THEN LastUpdateDate END ASC,
        CASE WHEN @Key = 'updated' AND @Desc = 1 THEN LastUpdateDate END DESC,
        CASE WHEN @Desc = 1 AND @Key IN ('hostname', '') THEN Hostname END DESC,
        Hostname ASC,
        VMID ASC
    OFFSET @Skip ROWS FETCH NEXT @Size ROWS ONLY;
END
GO
