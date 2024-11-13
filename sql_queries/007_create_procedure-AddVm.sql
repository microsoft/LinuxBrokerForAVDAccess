CREATE PROCEDURE [dbo].[AddVm]
    @Hostname NVARCHAR(255),
    @IPAddress NVARCHAR(50),
    @PowerState VARCHAR(10),
    @NetworkStatus VARCHAR(16),
    @VmStatus VARCHAR(16),
    @Username NVARCHAR(255) = NULL,
    @AvdHost NVARCHAR(255) = NULL,
    @Description TEXT = NULL
AS
BEGIN
    INSERT INTO dbo.VirtualMachines (Hostname, IPAddress, PowerState, NetworkStatus, VmStatus, Username, AvdHost, CreateDate, LastUpdateDate, Description)
    VALUES (@Hostname, @IPAddress, @PowerState, @NetworkStatus, @VmStatus, @Username, @AvdHost, GETDATE(), GETDATE(), @Description);

    -- Return the ID of the newly created VM
    SELECT SCOPE_IDENTITY() AS NewVMID;
END
GO
