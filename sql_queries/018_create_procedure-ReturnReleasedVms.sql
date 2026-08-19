CREATE PROCEDURE [dbo].[ReturnReleasedVms]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CurrentTime DATETIME = GETDATE();

    DECLARE @ReturnedVMs TABLE (
        VMID INT,
        Hostname VARCHAR(255),
        IPAddress VARCHAR(50),
        PowerState VARCHAR(10),
        NetworkStatus VARCHAR(16),
        VmStatus VARCHAR(16),
        LastUpdateDate DATETIME,
        ReturnedUsername VARCHAR(255),
        ReturnedAvdHost VARCHAR(255),
        ReturnedLeaseId UNIQUEIDENTIFIER
    );

    -- Set-based so the expiry sweep stays atomic and never depends on INSERT ... EXEC,
    -- which aborts the whole batch if the inner procedure returns an error result set.
    UPDATE dbo.VirtualMachines
    SET VmStatus = 'Available',
        Username = NULL,
        AvdHost = NULL,
        LeaseId = NULL,
        LastUpdateDate = GETDATE()
    OUTPUT INSERTED.VMID,
           INSERTED.Hostname,
           INSERTED.IPAddress,
           INSERTED.PowerState,
           INSERTED.NetworkStatus,
           INSERTED.VmStatus,
           INSERTED.LastUpdateDate,
           DELETED.Username,
           DELETED.AvdHost,
           DELETED.LeaseId
    INTO @ReturnedVMs (
        VMID,
        Hostname,
        IPAddress,
        PowerState,
        NetworkStatus,
        VmStatus,
        LastUpdateDate,
        ReturnedUsername,
        ReturnedAvdHost,
        ReturnedLeaseId
    )
    WHERE VmStatus = 'Released'
      AND DATEADD(MINUTE, 30, LastUpdateDate) <= @CurrentTime;

    SELECT *
    FROM @ReturnedVMs;
END
GO
