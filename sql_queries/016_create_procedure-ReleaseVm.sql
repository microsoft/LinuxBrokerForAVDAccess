CREATE PROCEDURE [dbo].[ReleaseVm]
    @Hostname VARCHAR(255),
    @LeaseId UNIQUEIDENTIFIER = NULL,
    @Username NVARCHAR(255) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRANSACTION;

    BEGIN TRY
        DECLARE @VMID INT;
        DECLARE @ActiveVMID INT;
        DECLARE @HostExists BIT = 0;
        DECLARE @ReleaseStatus VARCHAR(24);

        IF EXISTS (SELECT 1 FROM dbo.VirtualMachines WHERE Hostname = @Hostname)
        BEGIN
            SET @HostExists = 1;
        END

        SELECT TOP 1 @VMID = VMID
        FROM dbo.VirtualMachines WITH (UPDLOCK, HOLDLOCK, ROWLOCK)
        WHERE Hostname = @Hostname
          AND VmStatus IN ('CheckedOut', 'Released')
          AND (@Username IS NULL OR Username = @Username)
          AND (@LeaseId IS NULL OR LeaseId = @LeaseId)
        ORDER BY CASE WHEN VmStatus = 'CheckedOut' THEN 0 ELSE 1 END,
                 LastUpdateDate DESC,
                 VMID DESC;

        IF @VMID IS NOT NULL
        BEGIN
            UPDATE dbo.VirtualMachines
            SET VmStatus = CASE WHEN VmStatus = 'CheckedOut' THEN 'Released' ELSE VmStatus END,
                LastUpdateDate = CASE WHEN VmStatus = 'CheckedOut' THEN GETDATE() ELSE LastUpdateDate END
            WHERE VMID = @VMID;

            SELECT 'Released' AS ReleaseStatus, *
            FROM dbo.VirtualMachines
            WHERE VMID = @VMID;

            COMMIT TRANSACTION;
            RETURN;
        END

        IF @HostExists = 0
        BEGIN
            COMMIT TRANSACTION;

            SELECT 'NotFound' AS ReleaseStatus, @Hostname AS Hostname;
            RETURN;
        END

        -- The host is known, so separate "nothing left to release" from "another lease holds it".
        SELECT TOP 1 @ActiveVMID = VMID
        FROM dbo.VirtualMachines
        WHERE Hostname = @Hostname
          AND VmStatus IN ('CheckedOut', 'Released')
        ORDER BY CASE WHEN VmStatus = 'CheckedOut' THEN 0 ELSE 1 END,
                 LastUpdateDate DESC,
                 VMID DESC;

        SET @ReleaseStatus = CASE WHEN @ActiveVMID IS NULL THEN 'NoActiveAssignment' ELSE 'LeaseMismatch' END;

        IF @ActiveVMID IS NULL
        BEGIN
            SELECT TOP 1 @ActiveVMID = VMID
            FROM dbo.VirtualMachines
            WHERE Hostname = @Hostname
            ORDER BY VMID;
        END

        SELECT @ReleaseStatus AS ReleaseStatus, *
        FROM dbo.VirtualMachines
        WHERE VMID = @ActiveVMID;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
        BEGIN
            ROLLBACK TRANSACTION;
        END

        SELECT ERROR_MESSAGE() AS Message, ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS Severity, ERROR_STATE() AS State;
    END CATCH
END;
