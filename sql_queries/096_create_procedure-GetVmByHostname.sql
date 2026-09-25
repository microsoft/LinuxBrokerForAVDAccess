-- The registered host an action names. Session actions look a host up here first, so the API
-- never connects to a hostname the broker does not manage.

CREATE PROCEDURE [dbo].[GetVmByHostname]
    @Hostname VARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1
        VMID, Hostname, IPAddress, PowerState, NetworkStatus, VmStatus,
        Username, AvdHost, LeaseId, ReleasedDate, CleanupPending, CleanupUsername,
        CleanupLeaseId, DrainRequested, AssignedDate, LastCheckoutDate
    FROM dbo.VirtualMachines
    WHERE Hostname = @Hostname
    ORDER BY VMID;
END
GO
