CREATE PROCEDURE [dbo].[BeginVmCleanupRetry]
    @VMID INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Updated TABLE (
        VMID INT,
        Hostname VARCHAR(255),
        PowerState VARCHAR(10),
        NetworkStatus VARCHAR(16),
        CleanupUsername VARCHAR(255),
        CleanupLeaseId UNIQUEIDENTIFIER
    );

    UPDATE dbo.VirtualMachines
    SET CleanupAttemptDate = GETDATE()
    OUTPUT INSERTED.VMID, INSERTED.Hostname, INSERTED.PowerState, INSERTED.NetworkStatus,
           INSERTED.CleanupUsername, INSERTED.CleanupLeaseId
    INTO @Updated
    WHERE VMID = @VMID
      AND CleanupPending = 1;

    SELECT VMID, Hostname, PowerState, NetworkStatus, CleanupUsername, CleanupLeaseId
    FROM @Updated;
END
GO
