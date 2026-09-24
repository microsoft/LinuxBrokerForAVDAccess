-- Redefines dbo.GetVmDetails to also return the drain flag and when it was requested.

CREATE PROCEDURE [dbo].[GetVmDetails]
    @VMID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        VMID, Hostname, IPAddress, PowerState, NetworkStatus, VmStatus,
        Username, AvdHost, LeaseId, CreateDate, LastUpdateDate, Description,
        SettingsVersion, SettingsAppliedDate, ReleasedDate, CleanupPending,
        CleanupUsername, PowerStateChangedDate, DrainRequested, DrainRequestedDate
    FROM dbo.VirtualMachines
    WHERE VMID = @VMID;
END
GO
