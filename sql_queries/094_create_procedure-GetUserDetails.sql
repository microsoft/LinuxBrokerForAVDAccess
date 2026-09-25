-- One broker user for the portal's user page: their uid, any requested profile reset, and
-- every host they hold or that is still waiting to clean them up, as JSON. Returns no row for
-- a name the broker has never provisioned or assigned.

CREATE PROCEDURE [dbo].[GetUserDetails]
    @Username VARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.VmUsers WHERE username = @Username)
       AND NOT EXISTS (
            SELECT 1 FROM dbo.VirtualMachines
            WHERE Username = @Username OR (CleanupPending = 1 AND CleanupUsername = @Username)
       )
    BEGIN
        RETURN;
    END

    SELECT
        COALESCE(u.username, @Username) AS Username,
        u.uid AS Uid,
        u.CreateDate AS FirstProvisionedDate,
        CASE WHEN u.ProfileResetRequestedAt IS NULL THEN NULL
             ELSE CONVERT(VARCHAR(33), u.ProfileResetRequestedAt, 126) + 'Z' END AS ProfileResetRequestedAtUtc,
        u.ProfileResetRequestedBy,
        (
            SELECT
                vm.VMID,
                vm.Hostname,
                vm.VmStatus,
                vm.PowerState,
                vm.NetworkStatus,
                vm.AvdHost,
                vm.DrainRequested,
                CAST(CASE WHEN vm.Username = @Username THEN 0 ELSE 1 END AS BIT) AS CleanupPending,
                CASE WHEN vm.Username = @Username AND vm.AssignedDate IS NOT NULL
                     THEN DATEDIFF(SECOND, vm.AssignedDate, GETDATE()) END AS AssignedForSeconds,
                CASE WHEN vm.Username = @Username AND vm.LastCheckoutDate IS NOT NULL
                     THEN DATEDIFF(SECOND, vm.LastCheckoutDate, GETDATE()) END AS LastCheckoutAgeSeconds,
                CASE WHEN vm.Username = @Username AND vm.VmStatus = 'Released' AND vm.ReleasedDate IS NOT NULL
                     THEN DATEDIFF(SECOND, vm.ReleasedDate, GETDATE()) END AS ReleasedForSeconds
            FROM dbo.VirtualMachines vm
            WHERE (vm.Username = @Username AND vm.VmStatus IN ('CheckedOut', 'Released'))
               OR (vm.CleanupPending = 1 AND vm.CleanupUsername = @Username
                   AND (vm.Username IS NULL OR vm.Username <> @Username))
            ORDER BY vm.Hostname
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS AssignmentsJson
    FROM (SELECT 1 AS Anchor) anchor
    LEFT JOIN dbo.VmUsers u ON u.username = @Username;
END
GO
