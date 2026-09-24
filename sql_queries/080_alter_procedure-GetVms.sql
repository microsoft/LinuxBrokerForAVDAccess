-- Redefines dbo.GetVms to also return the drain flag and when it was requested.

CREATE PROCEDURE [dbo].[GetVms]
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        VMID, Hostname, IPAddress, PowerState, NetworkStatus, VmStatus,
        Username, AvdHost, LeaseId, CreateDate, LastUpdateDate, Description,
        SettingsVersion, SettingsAppliedDate, ReleasedDate, CleanupPending,
        CleanupUsername, PowerStateChangedDate, DrainRequested, DrainRequestedDate
    FROM dbo.VirtualMachines
    ORDER BY Hostname;
END
GO
