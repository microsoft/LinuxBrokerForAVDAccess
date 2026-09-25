-- Starts a maintenance run over the hosts in @HostsJson, a JSON array of VMIDs in the order
-- they should be patched (a repeated VMID keeps its first place). Only one run can be active,
-- Paused or Stopping at a time; the check and the insert happen under an app lock.
--
-- Result: Created (with RunID), RunActive (with the active RunID), NoHosts, or UnknownHosts
-- (with the VMIDs that are not registered, as JSON). Values out of range fail the table's
-- CHECK constraints; the API validates them first.

CREATE PROCEDURE [dbo].[CreateMaintenanceRun]
    @Name NVARCHAR(100) = NULL,
    @PatchMode VARCHAR(16),
    @BatchSize INT,
    @MinReadyOverride INT = NULL,
    @SignOutDeadlineMinutes INT = NULL,
    @WarningMinutes INT = 15,
    @WarningMessage NVARCHAR(500) = NULL,
    @IncludePoweredOff BIT = 0,
    @MaxFailures INT = 1,
    @CanaryCount INT = 0,
    @HostsJson NVARCHAR(MAX),
    @CreatedBy NVARCHAR(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Hosts TABLE (Position INT NOT NULL, VMID INT NULL, Raw NVARCHAR(4000) NULL);
    DECLARE @RunID INT, @ActiveRunID INT, @LockResult INT, @StartedTransaction BIT = 0;

    IF @HostsJson IS NULL OR ISJSON(@HostsJson) = 0 OR LEFT(LTRIM(@HostsJson), 1) <> '['
    BEGIN
        SELECT CAST('NoHosts' AS VARCHAR(16)) AS Result, CAST(NULL AS INT) AS RunID, 0 AS HostCount, CAST(NULL AS NVARCHAR(MAX)) AS UnknownJson;
        RETURN;
    END

    INSERT INTO @Hosts (Position, VMID, Raw)
    SELECT ROW_NUMBER() OVER (ORDER BY MIN(x.Position)), x.VMID, MIN(x.Raw)
    FROM (
        SELECT CAST(j.[key] AS INT) AS Position, TRY_CAST(j.[value] AS INT) AS VMID, LEFT(j.[value], 100) AS Raw
        FROM OPENJSON(@HostsJson) j
    ) x
    GROUP BY x.VMID, CASE WHEN x.VMID IS NULL THEN x.Raw END;

    IF NOT EXISTS (SELECT 1 FROM @Hosts)
    BEGIN
        SELECT CAST('NoHosts' AS VARCHAR(16)) AS Result, CAST(NULL AS INT) AS RunID, 0 AS HostCount, CAST(NULL AS NVARCHAR(MAX)) AS UnknownJson;
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM @Hosts h WHERE h.VMID IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.VirtualMachines vm WHERE vm.VMID = h.VMID))
    BEGIN
        SELECT CAST('UnknownHosts' AS VARCHAR(16)) AS Result, CAST(NULL AS INT) AS RunID, 0 AS HostCount,
               (SELECT h.Raw AS VMID FROM @Hosts h
                WHERE h.VMID IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.VirtualMachines vm WHERE vm.VMID = h.VMID)
                ORDER BY h.Position FOR JSON PATH) AS UnknownJson;
        RETURN;
    END

    IF @@TRANCOUNT = 0
    BEGIN
        BEGIN TRANSACTION;
        SET @StartedTransaction = 1;
    END

    EXEC @LockResult = sp_getapplock @Resource = 'LinuxBroker.Maintenance', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 5000;
    IF @LockResult < 0
    BEGIN
        IF @StartedTransaction = 1 ROLLBACK TRANSACTION;
        RAISERROR('Another maintenance change is in progress. Try again.', 16, 1);
        RETURN;
    END

    SELECT TOP 1 @ActiveRunID = RunID
    FROM dbo.MaintenanceRuns WITH (UPDLOCK, HOLDLOCK)
    WHERE Status IN ('Active', 'Paused', 'Stopping')
    ORDER BY RunID;

    IF @ActiveRunID IS NOT NULL
    BEGIN
        IF @StartedTransaction = 1 COMMIT TRANSACTION;
        SELECT CAST('RunActive' AS VARCHAR(16)) AS Result, @ActiveRunID AS RunID, 0 AS HostCount, CAST(NULL AS NVARCHAR(MAX)) AS UnknownJson;
        RETURN;
    END

    INSERT INTO dbo.MaintenanceRuns (Name, Status, PatchMode, BatchSize, MinReadyOverride, SignOutDeadlineMinutes, WarningMinutes,
                                     WarningMessage, IncludePoweredOff, MaxFailures, CanaryCount, CreatedBy)
    VALUES (NULLIF(LTRIM(RTRIM(@Name)), N''), 'Active', @PatchMode, @BatchSize, @MinReadyOverride, @SignOutDeadlineMinutes,
            COALESCE(@WarningMinutes, 15), NULLIF(LTRIM(RTRIM(@WarningMessage)), N''), COALESCE(@IncludePoweredOff, 0),
            COALESCE(@MaxFailures, 1), COALESCE(@CanaryCount, 0), @CreatedBy);

    SET @RunID = SCOPE_IDENTITY();

    INSERT INTO dbo.MaintenanceRunHosts (RunID, VMID, Hostname, Position)
    SELECT @RunID, h.VMID, vm.Hostname, h.Position
    FROM @Hosts h
    INNER JOIN dbo.VirtualMachines vm ON vm.VMID = h.VMID;

    IF @StartedTransaction = 1 COMMIT TRANSACTION;

    SELECT CAST('Created' AS VARCHAR(16)) AS Result, @RunID AS RunID,
           (SELECT COUNT(*) FROM dbo.MaintenanceRunHosts WHERE RunID = @RunID) AS HostCount,
           CAST(NULL AS NVARCHAR(MAX)) AS UnknownJson;
END
GO
