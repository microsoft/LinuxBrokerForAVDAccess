CREATE PROCEDURE [dbo].[ReleaseVm]
    @Hostname VARCHAR(255)
AS
BEGIN
    -- Update the VM's status to Released based on Hostname
    UPDATE dbo.VirtualMachines
    SET VmStatus = 'Released', LastUpdateDate = GETDATE()
    WHERE Hostname = @Hostname;

    -- Return the updated VM details
    SELECT *
    FROM dbo.VirtualMachines
    WHERE Hostname = @Hostname;
END;
