CREATE PROCEDURE [dbo].[ReturnVm]
    @VMID INT
AS
BEGIN
    -- Start a transaction to ensure atomicity
    BEGIN TRANSACTION;

    -- Update the VM status to "Available" and clear the Username and AvdHost fields
    UPDATE dbo.VirtualMachines
    SET VmStatus = 'Available', 
        Username = NULL, 
        AvdHost = NULL,
        LastUpdateDate = GETDATE()
    WHERE VMID = @VMID

    -- Return the updated VM information to confirm the return
    SELECT VMID, Hostname, IPAddress, PowerState, NetworkStatus, VmStatus, LastUpdateDate
    FROM dbo.VirtualMachines
    WHERE VMID = @VMID;

    -- Commit the transaction
    COMMIT TRANSACTION;
END
GO
