-- Redefines dbo.DeleteVm to return a row only when a VM was actually deleted.
--
-- The original returned the requested VMID whether or not such a VM existed, so the API
-- reported success, and would audit it, for a delete that did nothing. The returned hostname,
-- status and user let the audit entry say what was removed. The host's heartbeat row goes
-- with it.

CREATE PROCEDURE [dbo].[DeleteVm]
    @VMID INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Deleted TABLE (
        VMID INT,
        Hostname VARCHAR(255),
        VmStatus VARCHAR(16),
        Username VARCHAR(255)
    );

    DELETE FROM dbo.VirtualMachines
    OUTPUT DELETED.VMID, DELETED.Hostname, DELETED.VmStatus, DELETED.Username
    INTO @Deleted
    WHERE VMID = @VMID;

    DELETE hb
    FROM dbo.HostHeartbeats hb
    WHERE hb.Hostname IN (SELECT Hostname FROM @Deleted)
      AND NOT EXISTS (SELECT 1 FROM dbo.VirtualMachines vm WHERE vm.Hostname = hb.Hostname);

    SELECT VMID AS DeletedVMID, Hostname, VmStatus, Username
    FROM @Deleted;
END
GO
