CREATE PROCEDURE [dbo].[CheckoutVm]
    @Username NVARCHAR(255),
    @AvdHost NVARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRANSACTION;

    DECLARE @VMID INT;
    DECLARE @LeaseId UNIQUEIDENTIFIER;

    BEGIN TRY
        SELECT TOP 1
            @VMID = VMID,
            @LeaseId = LeaseId
        FROM dbo.VirtualMachines WITH (UPDLOCK, HOLDLOCK, ROWLOCK)
        WHERE Username = @Username
          AND VmStatus IN ('CheckedOut', 'Released')
        ORDER BY CASE WHEN VmStatus = 'CheckedOut' THEN 0 ELSE 1 END,
                 LastUpdateDate DESC,
                 VMID DESC;

        IF @VMID IS NOT NULL
        BEGIN
            IF @LeaseId IS NULL
            BEGIN
                SET @LeaseId = NEWID();
            END

            UPDATE dbo.VirtualMachines
            SET Username = @Username,
                AvdHost = @AvdHost,
                VmStatus = 'CheckedOut',
                LeaseId = @LeaseId,
                LastUpdateDate = GETDATE()
            WHERE VMID = @VMID;

            SELECT VMID, Hostname, IPAddress, Username, AvdHost, LeaseId, VmStatus, LastUpdateDate
            FROM dbo.VirtualMachines
            WHERE VMID = @VMID;

            COMMIT TRANSACTION;
            RETURN;
        END

        SELECT TOP 1 @VMID = VMID
        FROM dbo.VirtualMachines WITH (UPDLOCK, HOLDLOCK, ROWLOCK)
        WHERE PowerState = 'On'
          AND NetworkStatus = 'Reachable'
          AND VmStatus = 'Available'
        ORDER BY VMID;

        IF @VMID IS NOT NULL
        BEGIN
            SET @LeaseId = NEWID();

            UPDATE dbo.VirtualMachines
            SET Username = @Username,
                AvdHost = @AvdHost,
                VmStatus = 'CheckedOut',
                LeaseId = @LeaseId,
                LastUpdateDate = GETDATE()
            WHERE VMID = @VMID;

            SELECT VMID, Hostname, IPAddress, Username, AvdHost, LeaseId, VmStatus, LastUpdateDate
            FROM dbo.VirtualMachines
            WHERE VMID = @VMID;

            COMMIT TRANSACTION;
            RETURN;
        END

        ROLLBACK TRANSACTION;
        SELECT 'No available VM found' AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
        BEGIN
            ROLLBACK TRANSACTION;
        END

        SELECT ERROR_MESSAGE() AS Message, ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS Severity, ERROR_STATE() AS State;
    END CATCH
END
GO
