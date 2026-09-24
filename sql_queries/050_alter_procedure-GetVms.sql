CREATE PROCEDURE [dbo].[GetVms]
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        VMID, Hostname, IPAddress, PowerState, NetworkStatus, VmStatus,
        Username, AvdHost, LeaseId, CreateDate, LastUpdateDate, Description,
        SettingsVersion, SettingsAppliedDate, ReleasedDate, CleanupPending,
        CleanupUsername, PowerStateChangedDate
    FROM dbo.VirtualMachines
    ORDER BY Hostname;
END
GO
