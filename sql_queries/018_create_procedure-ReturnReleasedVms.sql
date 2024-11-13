CREATE PROCEDURE [dbo].[ReturnReleasedVms]
AS
BEGIN
    DECLARE @CurrentTime DATETIME = GETDATE();

    -- Temporary table to hold the details of returned VMs
    DECLARE @ReturnedVMs TABLE (
        VMID INT,
        Hostname VARCHAR(255),
        IPAddress VARCHAR(50),
        PowerState VARCHAR(10),
        NetworkStatus VARCHAR(16),
        VmStatus VARCHAR(16),
        LastUpdateDate DATETIME
    );

    -- Find VMs that have been released for more than 30 minutes
    DECLARE @VMID INT;
    DECLARE VM_Cursor CURSOR FOR 
    SELECT VMID 
    FROM dbo.VirtualMachines
    WHERE VmStatus = 'Released'
      AND DATEADD(MINUTE, 30, LastUpdateDate) <= @CurrentTime;

    OPEN VM_Cursor;
    FETCH NEXT FROM VM_Cursor INTO @VMID;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Call the ReturnVM stored procedure for each VMID found
        EXEC dbo.ReturnVM @VMID = @VMID;

        -- Insert the returned VM details into the temporary table
        INSERT INTO @ReturnedVMs (VMID, Hostname, IPAddress, PowerState, NetworkStatus, VmStatus, LastUpdateDate)
        SELECT VMID, Hostname, IPAddress, PowerState, NetworkStatus, VmStatus, LastUpdateDate
        FROM dbo.VirtualMachines
        WHERE VMID = @VMID;

        FETCH NEXT FROM VM_Cursor INTO @VMID;
    END;

    CLOSE VM_Cursor;
    DEALLOCATE VM_Cursor;

    -- Return the details of the VMs that were returned
    SELECT * FROM @ReturnedVMs;
END
GO
