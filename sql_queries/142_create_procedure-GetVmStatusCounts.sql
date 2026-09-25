-- How many hosts are in each state the host list filters by, for its status chips. @Search
-- narrows them the same way dbo.GetVmsPaged does, so a chip's count is what it would show.

CREATE PROCEDURE [dbo].[GetVmStatusCounts]
    @Search NVARCHAR(128) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Term NVARCHAR(128) = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @Pattern NVARCHAR(400) = CASE WHEN @Term IS NULL THEN NULL
        ELSE N'%' + REPLACE(REPLACE(REPLACE(@Term, N'[', N'[[]'), N'%', N'[%]'), N'_', N'[_]') + N'%' END;

    SELECT
        COUNT(*) AS [All],
        COALESCE(SUM(CASE WHEN vm.VmStatus = 'Available' AND vm.PowerState = 'On' AND vm.NetworkStatus = 'Reachable'
                               AND vm.CleanupPending = 0 AND vm.DrainRequested = 0 AND vm.Username IS NULL AND vm.LeaseId IS NULL
                          THEN 1 ELSE 0 END), 0) AS Ready,
        COALESCE(SUM(CASE WHEN vm.VmStatus = 'CheckedOut' THEN 1 ELSE 0 END), 0) AS InUse,
        COALESCE(SUM(CASE WHEN vm.VmStatus = 'Released' THEN 1 ELSE 0 END), 0) AS Released,
        COALESCE(SUM(CASE WHEN vm.VmStatus = 'Maintenance' THEN 1 ELSE 0 END), 0) AS Maintenance,
        COALESCE(SUM(CASE WHEN vm.DrainRequested = 1 THEN 1 ELSE 0 END), 0) AS Draining,
        COALESCE(SUM(CASE WHEN vm.PowerState = 'On' AND vm.NetworkStatus = 'Unreachable' THEN 1 ELSE 0 END), 0) AS Unreachable,
        COALESCE(SUM(CASE WHEN vm.PowerState = 'Off' THEN 1 ELSE 0 END), 0) AS [Off],
        COALESCE(SUM(CASE WHEN vm.CleanupPending = 1 THEN 1 ELSE 0 END), 0) AS Cleanup
    FROM dbo.VirtualMachines vm
    LEFT JOIN dbo.HostHeartbeats hb ON hb.Hostname = vm.Hostname
    WHERE @Pattern IS NULL
       OR vm.Hostname LIKE @Pattern OR vm.IPAddress LIKE @Pattern OR vm.Username LIKE @Pattern
       OR vm.VmStatus LIKE @Pattern OR hb.OsName LIKE @Pattern;
END
GO
