CREATE PROCEDURE [dbo].[GetVms]
AS
BEGIN
    SELECT 
        VMID,
        Hostname,
        IPAddress,
        PowerState,
        NetworkStatus,
        VmStatus,
        Username,
        AvdHost,
        CreateDate,
        LastUpdateDate,
        Description
    FROM dbo.VirtualMachines
    ORDER BY Hostname; -- Optional: Order by Hostname or another field as needed
END
GO
