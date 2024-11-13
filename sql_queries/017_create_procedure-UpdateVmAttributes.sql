CREATE PROCEDURE [dbo].[UpdateVmAttributes]
    @VMID INT,
    @PowerState VARCHAR(10) = NULL,
    @NetworkStatus VARCHAR(16) = NULL,
    @VmStatus VARCHAR(16) = NULL
AS
BEGIN
    -- Start a transaction to ensure atomicity
    BEGIN TRANSACTION;

    -- Update only the fields that are provided
    UPDATE dbo.VirtualMachines
    SET 
        PowerState = COALESCE(@PowerState, PowerState),
        NetworkStatus = COALESCE(@NetworkStatus, NetworkStatus),
        VmStatus = COALESCE(@VmStatus, VmStatus),
        LastUpdateDate = GETDATE()
    WHERE VMID = @VMID;

    -- Return the updated VM information
    SELECT VMID, Hostname, IPAddress, PowerState, NetworkStatus, VmStatus, LastUpdateDate
    FROM dbo.VirtualMachines
    WHERE VMID = @VMID;

    -- Commit the transaction
    COMMIT TRANSACTION;
END
GO
