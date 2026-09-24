-- Redefines dbo.SetVmMaintenance so either transition also clears the drain flag.
-- Maintenance is where a drain ends, and turning maintenance off returns the host to service,
-- so a leftover flag would otherwise pull the host straight back out of rotation. Turning
-- maintenance off on an Available host that is still flagged clears the flag.

CREATE PROCEDURE [dbo].[SetVmMaintenance]
    @VMID INT,
    @Enabled BIT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Hostname VARCHAR(255);
    DECLARE @Status VARCHAR(16);
    DECLARE @Username VARCHAR(255);
    DECLARE @LeaseId UNIQUEIDENTIFIER;
    DECLARE @Draining BIT;

    SELECT @Hostname = Hostname, @Status = VmStatus, @Username = Username, @LeaseId = LeaseId, @Draining = DrainRequested
    FROM dbo.VirtualMachines WITH (UPDLOCK, ROWLOCK)
    WHERE VMID = @VMID;

    IF @Hostname IS NULL
    BEGIN
        SELECT CAST('NotFound' AS VARCHAR(16)) AS Result,
               CAST(NULL AS INT) AS VMID,
               CAST(NULL AS VARCHAR(255)) AS Hostname,
               CAST(NULL AS VARCHAR(16)) AS VmStatus;
        RETURN;
    END

    IF @Username IS NOT NULL OR @LeaseId IS NOT NULL
    BEGIN
        SELECT CAST('Assigned' AS VARCHAR(16)) AS Result, @VMID AS VMID, @Hostname AS Hostname, @Status AS VmStatus;
        RETURN;
    END

    IF (@Enabled = 1 AND @Status = 'Maintenance' AND @Draining = 0)
       OR (@Enabled = 0 AND @Status = 'Available' AND @Draining = 0)
    BEGIN
        SELECT CAST('Unchanged' AS VARCHAR(16)) AS Result, @VMID AS VMID, @Hostname AS Hostname, @Status AS VmStatus;
        RETURN;
    END

    IF @Status IN ('Available', 'Maintenance')
    BEGIN
        UPDATE dbo.VirtualMachines
        SET VmStatus = CASE WHEN @Enabled = 1 THEN 'Maintenance' ELSE 'Available' END,
            DrainRequested = 0,
            DrainRequestedDate = NULL,
            LastUpdateDate = GETDATE()
        WHERE VMID = @VMID;

        SELECT CAST('Updated' AS VARCHAR(16)) AS Result, VMID, Hostname, VmStatus
        FROM dbo.VirtualMachines
        WHERE VMID = @VMID;
        RETURN;
    END

    SELECT CAST('InvalidState' AS VARCHAR(16)) AS Result, @VMID AS VMID, @Hostname AS Hostname, @Status AS VmStatus;
END
GO
