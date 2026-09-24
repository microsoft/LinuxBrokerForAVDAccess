-- Puts back what dbo.BeginVmPowerAction recorded when Azure refuses an operator's power
-- action, in one transaction, so nothing sees the host half restored. The caller passes the
-- Previous* columns BeginVmPowerAction returned.
--
-- The power state and network status go back to what they were, as the scaling revert does.
-- A refused stop that ended an assignment also gives the host back to its user, with the
-- lease, AVD host, status and release time it had, and withdraws the cleanup the stop
-- claimed; the user is still signed in, because the host never stopped. That only happens
-- while the host is still exactly as the stop left it and the user has not been given another
-- host in the meantime. Otherwise AssignmentRestored is 0 and the cleanup stays claimed, so
-- the user gets another host when they reconnect and is removed from this one once they sign
-- out, just as after a stop.

CREATE PROCEDURE [dbo].[RevertVmPowerAction]
    @VMID INT,
    @PreviousPowerState VARCHAR(10),
    @PreviousNetworkStatus VARCHAR(16),
    @EndedAssignment BIT = 0,
    @PreviousVmStatus VARCHAR(16) = NULL,
    @Username VARCHAR(255) = NULL,
    @AvdHost VARCHAR(255) = NULL,
    @LeaseId UNIQUEIDENTIFIER = NULL,
    @ReleasedDate DATETIME = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Hostname VARCHAR(255);
    DECLARE @AssignmentRestored BIT = 0;
    DECLARE @Now DATETIME = GETDATE();
    DECLARE @StartedTransaction BIT = 0;

    IF @@TRANCOUNT = 0
    BEGIN
        BEGIN TRANSACTION;
        SET @StartedTransaction = 1;
    END

    SELECT @Hostname = Hostname
    FROM dbo.VirtualMachines WITH (UPDLOCK, HOLDLOCK, ROWLOCK)
    WHERE VMID = @VMID;

    IF @Hostname IS NOT NULL
    BEGIN
        IF COALESCE(@EndedAssignment, 0) = 1
           AND @Username IS NOT NULL
           AND @PreviousVmStatus IN ('CheckedOut', 'Released')
           AND NOT EXISTS (
               SELECT 1
               FROM dbo.VirtualMachines WITH (UPDLOCK, HOLDLOCK)
               WHERE Username = @Username
                 AND VMID <> @VMID
           )
        BEGIN
            UPDATE dbo.VirtualMachines
            SET VmStatus = @PreviousVmStatus,
                Username = @Username,
                AvdHost = @AvdHost,
                LeaseId = @LeaseId,
                ReleasedDate = @ReleasedDate,
                CleanupPending = 0,
                CleanupUsername = NULL,
                CleanupLeaseId = NULL,
                CleanupAttemptDate = NULL
            WHERE VMID = @VMID
              AND VmStatus = 'Available'
              AND Username IS NULL
              AND LeaseId IS NULL
              AND CleanupPending = 1
              AND CleanupUsername = @Username
              AND (CleanupLeaseId = @LeaseId OR (CleanupLeaseId IS NULL AND @LeaseId IS NULL));

            IF @@ROWCOUNT = 1 SET @AssignmentRestored = 1;
        END

        UPDATE dbo.VirtualMachines
        SET PowerState = COALESCE(@PreviousPowerState, PowerState),
            NetworkStatus = COALESCE(@PreviousNetworkStatus, NetworkStatus),
            PowerStateChangedDate = CASE
                WHEN @PreviousPowerState IS NOT NULL AND @PreviousPowerState <> PowerState THEN @Now
                ELSE PowerStateChangedDate
            END,
            LastUpdateDate = @Now
        WHERE VMID = @VMID;
    END

    IF @StartedTransaction = 1 COMMIT TRANSACTION;

    SELECT CASE WHEN @Hostname IS NULL THEN 'NotFound' ELSE 'Reverted' END AS Result,
           @VMID AS VMID,
           @Hostname AS Hostname,
           @AssignmentRestored AS AssignmentRestored;
END
GO
