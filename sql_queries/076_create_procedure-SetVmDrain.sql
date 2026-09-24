-- Takes a host out of rotation without stranding its user, or puts it back.
--
-- Enabling drain:
--   * An unassigned host with nothing left to clean up moves straight to Maintenance
--     (Drained).
--   * A host that is assigned (CheckedOut or Released), or is still waiting for its previous
--     user to be removed, keeps running for that user and is flagged (Draining). CheckoutVm
--     stops offering it to anyone new; CompleteVmCleanup, or FinalizeVmDrains for any other
--     path, moves it to Maintenance once the assignment has ended and the host is clean.
--   * A host already draining or in maintenance is Unchanged.
-- Disabling drain ("Return to service") clears the flag, and a Maintenance host with no
-- assignment goes back to Available (ReturnedToService). Anything else is Unchanged.

CREATE PROCEDURE [dbo].[SetVmDrain]
    @VMID INT,
    @Enabled BIT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Hostname VARCHAR(255);
    DECLARE @Status VARCHAR(16);
    DECLARE @Username VARCHAR(255);
    DECLARE @LeaseId UNIQUEIDENTIFIER;
    DECLARE @CleanupPending BIT;
    DECLARE @Draining BIT;
    DECLARE @Result VARCHAR(24);
    DECLARE @StartedTransaction BIT = 0;

    IF @@TRANCOUNT = 0
    BEGIN
        BEGIN TRANSACTION;
        SET @StartedTransaction = 1;
    END

    SELECT @Hostname = Hostname,
           @Status = VmStatus,
           @Username = Username,
           @LeaseId = LeaseId,
           @CleanupPending = CleanupPending,
           @Draining = DrainRequested
    FROM dbo.VirtualMachines WITH (UPDLOCK, HOLDLOCK, ROWLOCK)
    WHERE VMID = @VMID;

    IF @Hostname IS NULL
    BEGIN
        IF @StartedTransaction = 1 COMMIT TRANSACTION;

        SELECT CAST('NotFound' AS VARCHAR(24)) AS Result,
               CAST(NULL AS INT) AS VMID,
               CAST(NULL AS VARCHAR(255)) AS Hostname,
               CAST(NULL AS VARCHAR(16)) AS VmStatus,
               CAST(NULL AS BIT) AS DrainRequested,
               CAST(NULL AS VARCHAR(255)) AS Username,
               CAST(NULL AS BIT) AS CleanupPending;
        RETURN;
    END

    IF @Enabled = 1
    BEGIN
        IF @Draining = 1
           OR (@Status = 'Maintenance' AND @Username IS NULL AND @LeaseId IS NULL)
        BEGIN
            SET @Result = 'Unchanged';
        END
        ELSE IF @Status = 'Available' AND @Username IS NULL AND @LeaseId IS NULL AND @CleanupPending = 0
        BEGIN
            UPDATE dbo.VirtualMachines
            SET VmStatus = 'Maintenance',
                DrainRequested = 0,
                DrainRequestedDate = NULL,
                LastUpdateDate = GETDATE()
            WHERE VMID = @VMID;

            SET @Result = 'Drained';
        END
        ELSE IF @Status IN ('CheckedOut', 'Released') OR @CleanupPending = 1
        BEGIN
            UPDATE dbo.VirtualMachines
            SET DrainRequested = 1,
                DrainRequestedDate = GETDATE(),
                LastUpdateDate = GETDATE()
            WHERE VMID = @VMID;

            SET @Result = 'Draining';
        END
        ELSE
        BEGIN
            SET @Result = 'InvalidState';
        END
    END
    ELSE
    BEGIN
        IF @Draining = 1 OR (@Status = 'Maintenance' AND @Username IS NULL AND @LeaseId IS NULL)
        BEGIN
            UPDATE dbo.VirtualMachines
            SET DrainRequested = 0,
                DrainRequestedDate = NULL,
                VmStatus = CASE WHEN VmStatus = 'Maintenance' AND Username IS NULL AND LeaseId IS NULL THEN 'Available' ELSE VmStatus END,
                LastUpdateDate = GETDATE()
            WHERE VMID = @VMID;

            SET @Result = 'ReturnedToService';
        END
        ELSE
        BEGIN
            SET @Result = 'Unchanged';
        END
    END

    IF @StartedTransaction = 1 COMMIT TRANSACTION;

    SELECT @Result AS Result, VMID, Hostname, VmStatus, DrainRequested, Username, CleanupPending
    FROM dbo.VirtualMachines
    WHERE VMID = @VMID;
END
GO
