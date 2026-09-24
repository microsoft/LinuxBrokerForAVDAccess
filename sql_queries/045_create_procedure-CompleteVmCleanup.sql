CREATE PROCEDURE [dbo].[CompleteVmCleanup]
    @VMID INT,
    @LeaseId UNIQUEIDENTIFIER = NULL,
    @Username VARCHAR(255) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Updated TABLE (
        VMID INT,
        Hostname VARCHAR(255),
        VmStatus VARCHAR(16),
        CleanupPending BIT
    );

    UPDATE dbo.VirtualMachines
    SET CleanupPending = 0,
        CleanupUsername = NULL,
        CleanupLeaseId = NULL,
        CleanupAttemptDate = NULL
    OUTPUT INSERTED.VMID, INSERTED.Hostname, INSERTED.VmStatus, INSERTED.CleanupPending
    INTO @Updated
    WHERE VMID = @VMID
      AND CleanupPending = 1
      AND (CleanupLeaseId = @LeaseId OR (CleanupLeaseId IS NULL AND @LeaseId IS NULL))
      AND (@Username IS NULL OR CleanupUsername = @Username);

    SELECT VMID, Hostname, VmStatus, CleanupPending
    FROM @Updated;
END
GO
