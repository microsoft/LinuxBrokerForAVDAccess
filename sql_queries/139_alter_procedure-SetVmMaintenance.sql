-- Redefines dbo.SetVmMaintenance so a maintenance run keeps the hosts it is working on.
--
-- Turning maintenance off while an active maintenance run is starting, patching, restarting
-- or verifying the host is refused: Result InvalidState with Reason InMaintenanceRun and the
-- run's ID, which the previous API also answers with a 409. A host the run has only taken out
-- of rotation is returned and the run skips it. Everything else is unchanged from 075, with
-- Reason and MaintenanceRunID added to the result.

CREATE PROCEDURE [dbo].[SetVmMaintenance]
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
    DECLARE @Draining BIT;
    DECLARE @RunHostID INT, @RunHostState VARCHAR(16), @RunID INT;
    DECLARE @StartedTransaction BIT = 0;

    IF @@TRANCOUNT = 0
    BEGIN
        BEGIN TRANSACTION;
        SET @StartedTransaction = 1;
    END

    SELECT @Hostname = Hostname, @Status = VmStatus, @Username = Username, @LeaseId = LeaseId, @Draining = DrainRequested
    FROM dbo.VirtualMachines WITH (UPDLOCK, ROWLOCK)
    WHERE VMID = @VMID;

    IF @Hostname IS NULL
    BEGIN
        IF @StartedTransaction = 1 COMMIT TRANSACTION;
        SELECT CAST('NotFound' AS VARCHAR(16)) AS Result,
               CAST(NULL AS INT) AS VMID,
               CAST(NULL AS VARCHAR(255)) AS Hostname,
               CAST(NULL AS VARCHAR(16)) AS VmStatus,
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

        IF @RunHostState IN ('Starting', 'Patching', 'Restarting', 'Verifying')
        BEGIN
            IF @StartedTransaction = 1 COMMIT TRANSACTION;
            SELECT CAST('InvalidState' AS VARCHAR(16)) AS Result, @VMID AS VMID, @Hostname AS Hostname, @Status AS VmStatus,
                   CAST('InMaintenanceRun' AS VARCHAR(32)) AS Reason, @RunID AS MaintenanceRunID;
            RETURN;
        END
    END

    IF @Username IS NOT NULL OR @LeaseId IS NOT NULL
    BEGIN
        IF @StartedTransaction = 1 COMMIT TRANSACTION;
        SELECT CAST('Assigned' AS VARCHAR(16)) AS Result, @VMID AS VMID, @Hostname AS Hostname, @Status AS VmStatus,
               CAST(NULL AS VARCHAR(32)) AS Reason, CAST(NULL AS INT) AS MaintenanceRunID;
        RETURN;
    END

    -- The run had only taken the host out of rotation, so it simply goes without it.
    IF @Enabled = 0 AND @RunHostState = 'Draining'
    BEGIN
        UPDATE dbo.MaintenanceRunHosts
        SET State = 'Skipped',
            Detail = N'Returned to service by an operator before patching started.',
            CompletedAt = SYSUTCDATETIME(), Version = Version + 1, UpdatedAt = SYSUTCDATETIME()
        WHERE RunHostID = @RunHostID AND State = 'Draining';
    END

    IF (@Enabled = 1 AND @Status = 'Maintenance' AND @Draining = 0)
       OR (@Enabled = 0 AND @Status = 'Available' AND @Draining = 0)
    BEGIN
        IF @StartedTransaction = 1 COMMIT TRANSACTION;
        SELECT CAST('Unchanged' AS VARCHAR(16)) AS Result, @VMID AS VMID, @Hostname AS Hostname, @Status AS VmStatus,
               CAST(NULL AS VARCHAR(32)) AS Reason, CAST(NULL AS INT) AS MaintenanceRunID;
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

        IF @StartedTransaction = 1 COMMIT TRANSACTION;
        SELECT CAST('Updated' AS VARCHAR(16)) AS Result, VMID, Hostname, VmStatus,
               CAST(NULL AS VARCHAR(32)) AS Reason, CAST(NULL AS INT) AS MaintenanceRunID
        FROM dbo.VirtualMachines
        WHERE VMID = @VMID;
        RETURN;
    END

    IF @StartedTransaction = 1 COMMIT TRANSACTION;
    SELECT CAST('InvalidState' AS VARCHAR(16)) AS Result, @VMID AS VMID, @Hostname AS Hostname, @Status AS VmStatus,
           CAST(NULL AS VARCHAR(32)) AS Reason, CAST(NULL AS INT) AS MaintenanceRunID;
END
GO
