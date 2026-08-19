CREATE PROCEDURE [dbo].[GetVmDetails]
    @VMID INT
AS
BEGIN
    SELECT VMID, Hostname, IPAddress, PowerState, NetworkStatus, VmStatus, Username, AvdHost, LeaseId, CreateDate, LastUpdateDate, Description
    FROM dbo.VirtualMachines
    WHERE VMID = @VMID;
END
GO
