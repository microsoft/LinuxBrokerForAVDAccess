-- Puts a maintenance host back the way the run found it: back in service, unless it was
-- draining or in maintenance before the run, in which case it is left out of rotation. Used
-- when a host has been patched, and for a host a cancelled run leaves waiting for its user
-- (who keeps the session).
--
-- Result: ReturnedToService, LeftOutOfService, Unchanged (already in service) or NotFound.

CREATE PROCEDURE [dbo].[ReturnMaintenanceHost]
    @RunHostID INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @VMID INT, @WasDrained BIT, @WasMaintenance BIT, @Result VARCHAR(24);

    SELECT @VMID = VMID, @WasDrained = WasDrained, @WasMaintenance = WasMaintenance
    FROM dbo.MaintenanceRunHosts
    WHERE RunHostID = @RunHostID;

    IF @VMID IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.VirtualMachines WHERE VMID = @VMID)
    BEGIN
        SELECT CAST('NotFound' AS VARCHAR(24)) AS Result, @VMID AS VMID, CAST(NULL AS VARCHAR(255)) AS Hostname,
               CAST(NULL AS VARCHAR(16)) AS VmStatus, CAST(NULL AS BIT) AS DrainRequested, CAST(NULL AS VARCHAR(10)) AS PowerState;
        RETURN;
    END

    IF @WasDrained = 1 OR @WasMaintenance = 1
    BEGIN
        SET @Result = 'LeftOutOfService';
    END
    ELSE
    BEGIN
        UPDATE dbo.VirtualMachines
        SET DrainRequested = 0,
            DrainRequestedDate = NULL,
            VmStatus = CASE WHEN VmStatus = 'Maintenance' AND Username IS NULL AND LeaseId IS NULL THEN 'Available' ELSE VmStatus END,
            LastUpdateDate = GETDATE()
        WHERE VMID = @VMID
          AND (DrainRequested = 1 OR VmStatus = 'Maintenance');

        SET @Result = CASE WHEN @@ROWCOUNT = 1 THEN 'ReturnedToService' ELSE 'Unchanged' END;
    END

    SELECT @Result AS Result, VMID, Hostname, VmStatus, DrainRequested, PowerState
    FROM dbo.VirtualMachines
    WHERE VMID = @VMID;
END
GO
