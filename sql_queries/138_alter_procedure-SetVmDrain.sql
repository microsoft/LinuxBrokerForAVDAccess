-- Redefines dbo.SetVmDrain so a maintenance run keeps the hosts it is working on.
--
-- Returning a host to service (@Enabled = 0) while an active maintenance run is starting,
-- patching, restarting or verifying it is refused: Result InvalidState with Reason
-- InMaintenanceRun and the run's ID, which the previous API also answers with a 409. A host the
-- run has only taken out of rotation, still waiting for its user, is returned and the run
-- skips it. Everything else is unchanged from 076, with Reason and MaintenanceRunID added to
-- the result.

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
    DECLARE @Reason VARCHAR(32) = NULL;
    DECLARE @RunHostID INT, @RunHostState VARCHAR(16), @RunID INT;
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
               CAST(NULL AS BIT) AS CleanupPending,
               CAST(NULL AS VARCHAR(32)) AS Reason,
               CAST(NULL AS INT) AS MaintenanceRunID;
        RETURN;
    END

    IF @Enabled = 0
    BEGIN
        SELECT TOP 1 @RunHostID = h.RunHostID, @RunHostState = h.State, @RunID = h.RunID
        FROM dbo.MaintenanceRunHosts h WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN dbo.MaintenanceRuns r ON r.RunID = h.RunID
        WHERE h.VMID = @VMID
          AND r.Status IN ('Active', 'Paused', 'Stopping')
          AND h.State IN ('Draining', 'Starting', 'Patching', 'Restarting', 'Verifying')
        ORDER BY h.RunID DESC;
    END

    IF @RunHostState IN ('Starting', 'Patching', 'Restarting', 'Verifying')
    BEGIN
        SET @Result = 'InvalidState';
        SET @Reason = 'InMaintenanceRun';
    END
    ELSE IF @Enabled = 1
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

        -- The run had only taken the host out of rotation, so it simply goes without it.
        IF @RunHostState = 'Draining'
        BEGIN
            UPDATE dbo.MaintenanceRunHosts
            SET State = 'Skipped',
                Detail = N'Returned to service by an operator before patching started.',
                CompletedAt = SYSUTCDATETIME(), Version = Version + 1, UpdatedAt = SYSUTCDATETIME()
            WHERE RunHostID = @RunHostID AND State = 'Draining';
        END
    END

    IF @StartedTransaction = 1 COMMIT TRANSACTION;

    SELECT @Result AS Result, VMID, Hostname, VmStatus, DrainRequested, Username, CleanupPending,
           @Reason AS Reason, CASE WHEN @Reason IS NULL THEN NULL ELSE @RunID END AS MaintenanceRunID
    FROM dbo.VirtualMachines
    WHERE VMID = @VMID;
END
GO
