-- Redefines dbo.CheckoutVm to record when an assignment began and when it was last checked
-- out, and to say which kind of checkout this was:
--   * CheckoutType is Reused when the user already held the host (a reconnect) and Assigned
--     for a new assignment. The API records it with each checkout event.
--   * ProfileResetRequested tells the API an administrator asked for a fresh profile. It is
--     applied on a new assignment only, before create-user.sh mounts the home.
-- Columns are only added to the result, so the previous API build is unaffected. A draining
-- host is still never assigned to a new user, and its current user can still reconnect.

CREATE PROCEDURE [dbo].[CheckoutVm]
    @Username NVARCHAR(255),
    @AvdHost NVARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRANSACTION;

    DECLARE @VMID INT;
    DECLARE @LeaseId UNIQUEIDENTIFIER;
    DECLARE @ResetRequested BIT = CASE WHEN EXISTS (
        SELECT 1 FROM dbo.VmUsers WHERE username = @Username AND ProfileResetRequestedAt IS NOT NULL
    ) THEN 1 ELSE 0 END;

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
                ReleasedDate = NULL,
                LastCheckoutDate = GETDATE(),
                LastUpdateDate = GETDATE()
            WHERE VMID = @VMID;

            SELECT VMID, Hostname, IPAddress, Username, AvdHost, LeaseId, VmStatus, LastUpdateDate,
                   CAST('Reused' AS VARCHAR(16)) AS CheckoutType,
                   @ResetRequested AS ProfileResetRequested
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
          AND Username IS NULL
          AND CleanupPending = 0
          AND DrainRequested = 0
        ORDER BY VMID;

        IF @VMID IS NOT NULL
        BEGIN
            SET @LeaseId = NEWID();

            UPDATE dbo.VirtualMachines
            SET Username = @Username,
                AvdHost = @AvdHost,
                VmStatus = 'CheckedOut',
                LeaseId = @LeaseId,
                ReleasedDate = NULL,
                AssignedDate = GETDATE(),
                LastCheckoutDate = GETDATE(),
                LastUpdateDate = GETDATE()
            WHERE VMID = @VMID;

            SELECT VMID, Hostname, IPAddress, Username, AvdHost, LeaseId, VmStatus, LastUpdateDate,
                   CAST('Assigned' AS VARCHAR(16)) AS CheckoutType,
                   @ResetRequested AS ProfileResetRequested
            FROM dbo.VirtualMachines
            WHERE VMID = @VMID;

            COMMIT TRANSACTION;
            RETURN;
        END

        -- Nothing changed, so commit rather than roll back. pymssql runs every statement
        -- inside its own transaction; a ROLLBACK here unwound that outer transaction too,
        -- SQL Server raised error 266 on return, and the API answered "no VM available"
        -- with a 500 instead of a 409.
        COMMIT TRANSACTION;
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
