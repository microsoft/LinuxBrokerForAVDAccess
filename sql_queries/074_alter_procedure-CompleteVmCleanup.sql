-- Redefines dbo.CompleteVmCleanup so a draining host leaves rotation once its previous user
-- is gone: it moves to Maintenance and the drain flag clears. DrainCompleted tells the API to
-- record that in the audit log. A host that is not draining behaves exactly as before.

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
        CleanupPending BIT,
        DrainCompleted BIT
    );

    -- Every CASE below reads the row as it was before this UPDATE.
    UPDATE dbo.VirtualMachines
    SET CleanupPending = 0,
        CleanupUsername = NULL,
        CleanupLeaseId = NULL,
        CleanupAttemptDate = NULL,
        VmStatus = CASE WHEN DrainRequested = 1 AND VmStatus = 'Available' AND Username IS NULL THEN 'Maintenance' ELSE VmStatus END,
        DrainRequested = CASE WHEN DrainRequested = 1 AND VmStatus = 'Available' AND Username IS NULL THEN 0 ELSE DrainRequested END,
        DrainRequestedDate = CASE WHEN DrainRequested = 1 AND VmStatus = 'Available' AND Username IS NULL THEN NULL ELSE DrainRequestedDate END,
        LastUpdateDate = CASE WHEN DrainRequested = 1 AND VmStatus = 'Available' AND Username IS NULL THEN GETDATE() ELSE LastUpdateDate END
    OUTPUT INSERTED.VMID,
           INSERTED.Hostname,
           INSERTED.VmStatus,
           INSERTED.CleanupPending,
           CAST(CASE WHEN DELETED.DrainRequested = 1 AND INSERTED.DrainRequested = 0 THEN 1 ELSE 0 END AS BIT)
    INTO @Updated
    WHERE VMID = @VMID
      AND CleanupPending = 1
      AND (CleanupLeaseId = @LeaseId OR (CleanupLeaseId IS NULL AND @LeaseId IS NULL))
      AND (@Username IS NULL OR CleanupUsername = @Username);

    SELECT VMID, Hostname, VmStatus, CleanupPending, DrainCompleted
    FROM @Updated;
END
GO
