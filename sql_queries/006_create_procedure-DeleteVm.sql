CREATE PROCEDURE [dbo].[DeleteVm]
    @VMID INT
AS
BEGIN
    DELETE FROM dbo.VirtualMachines
    WHERE VMID = @VMID;

    -- Optionally return the deleted VMID to confirm deletion
    SELECT @VMID AS DeletedVMID;
END
GO
