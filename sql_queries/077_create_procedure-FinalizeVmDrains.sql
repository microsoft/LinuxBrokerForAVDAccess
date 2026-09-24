-- Completes every drain whose host has become unassigned and clean, by whatever path got it
-- there: a return, an expired release, a completed cleanup, or an administrator's repair. The
-- API's scheduled sweep runs this, and the rows it returns are written to the audit log.
-- CompleteVmCleanup already completes the common case immediately; this is the catch-all.

CREATE PROCEDURE [dbo].[FinalizeVmDrains]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Finalized TABLE (
        VMID INT,
        Hostname VARCHAR(255),
        VmStatus VARCHAR(16)
    );

    UPDATE dbo.VirtualMachines
    SET VmStatus = 'Maintenance',
        DrainRequested = 0,
        DrainRequestedDate = NULL,
        LastUpdateDate = GETDATE()
    OUTPUT INSERTED.VMID, INSERTED.Hostname, INSERTED.VmStatus
    INTO @Finalized
    WHERE DrainRequested = 1
      AND VmStatus IN ('Available', 'Maintenance')
      AND Username IS NULL
      AND LeaseId IS NULL
      AND CleanupPending = 0;

    SELECT VMID, Hostname, VmStatus
    FROM @Finalized
    ORDER BY Hostname;
END
GO
