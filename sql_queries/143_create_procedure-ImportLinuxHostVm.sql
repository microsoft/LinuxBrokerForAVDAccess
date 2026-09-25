-- Registers a Linux host found in Azure. Unlike dbo.RegisterLinuxHostVm, which the deployment
-- uses for hosts it has just built, an imported host starts Unreachable with the power state
-- Azure reported, so no one is given it before the reachability probe confirms the broker
-- can reach it. A host already registered is left alone.
--
-- Result: Imported (with the new VMID) or Exists (with the existing one).

CREATE PROCEDURE [dbo].[ImportLinuxHostVm]
    @Hostname VARCHAR(255),
    @IPAddress VARCHAR(50),
    @PowerState VARCHAR(10) = 'Off',
    @Description NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ExistingVmId INT, @StartedTransaction BIT = 0;

    IF @@TRANCOUNT = 0
    BEGIN
        BEGIN TRANSACTION;
        SET @StartedTransaction = 1;
    END

    SELECT TOP 1 @ExistingVmId = VMID
    FROM dbo.VirtualMachines WITH (UPDLOCK, HOLDLOCK)
    WHERE Hostname = @Hostname
    ORDER BY VMID;

    IF @ExistingVmId IS NOT NULL
    BEGIN
        IF @StartedTransaction = 1 COMMIT TRANSACTION;
        SELECT CAST('Exists' AS VARCHAR(16)) AS Result, @ExistingVmId AS VMID, @Hostname AS Hostname;
        RETURN;
    END

    INSERT INTO dbo.VirtualMachines (Hostname, IPAddress, PowerState, NetworkStatus, VmStatus, CreateDate, LastUpdateDate, Description)
    VALUES (@Hostname, @IPAddress, CASE WHEN @PowerState = 'On' THEN 'On' ELSE 'Off' END, 'Unreachable', 'Available',
            GETDATE(), GETDATE(), COALESCE(@Description, N'Imported from Azure.'));

    DECLARE @VMID INT = CAST(SCOPE_IDENTITY() AS INT);
    IF @StartedTransaction = 1 COMMIT TRANSACTION;

    SELECT CAST('Imported' AS VARCHAR(16)) AS Result, @VMID AS VMID, @Hostname AS Hostname;
END
GO
