CREATE PROCEDURE [dbo].[SetVmNetworkStatus]
    @VMID INT,
    @NetworkStatus VARCHAR(16)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Changed TABLE (
        VMID INT,
        Hostname VARCHAR(255),
        PowerState VARCHAR(10),
        NetworkStatus VARCHAR(16),
        Changed BIT
    );

    UPDATE dbo.VirtualMachines
    SET NetworkStatus = @NetworkStatus,
        LastUpdateDate = GETDATE()
    OUTPUT INSERTED.VMID, INSERTED.Hostname, INSERTED.PowerState, INSERTED.NetworkStatus, CAST(1 AS BIT)
    INTO @Changed
    WHERE VMID = @VMID
      AND NetworkStatus <> @NetworkStatus;

    IF NOT EXISTS (SELECT 1 FROM @Changed)
    BEGIN
        INSERT INTO @Changed (VMID, Hostname, PowerState, NetworkStatus, Changed)
        SELECT VMID, Hostname, PowerState, NetworkStatus, CAST(0 AS BIT)
        FROM dbo.VirtualMachines
        WHERE VMID = @VMID;
    END

    SELECT VMID, Hostname, PowerState, NetworkStatus, Changed
    FROM @Changed;
END
GO
