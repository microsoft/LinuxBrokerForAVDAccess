CREATE PROCEDURE [dbo].[ReturnVm]
    @VMID INT,
    @ExpectedLeaseId UNIQUEIDENTIFIER = NULL,
    @RequireReleased BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRANSACTION;

    BEGIN TRY
        DECLARE @ReturnedVm TABLE (
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
        INTO @ReturnedVm (
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
        WHERE VMID = @VMID
          AND VmStatus IN ('CheckedOut', 'Released')
          AND (@ExpectedLeaseId IS NULL OR LeaseId = @ExpectedLeaseId)
          AND (@RequireReleased = 0 OR VmStatus = 'Released');

        SELECT *
        FROM @ReturnedVm;

        COMMIT TRANSACTION;
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
