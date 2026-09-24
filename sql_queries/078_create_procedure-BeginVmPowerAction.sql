-- Records a power action an operator requested, before the API asks Azure to carry it out,
-- and returns what the API needs to put the record back if Azure refuses.
--
-- The state recorded matches what scaling records for the same operation, so the scaler, the
-- reachability probe and the Azure power-state sync treat the host consistently:
--   Start    PowerState On and NetworkStatus Unreachable, until the probe reaches it.
--   Stop     PowerState Off and NetworkStatus Unreachable.
--   Restart  NetworkStatus Unreachable, until the probe reaches it again.
-- PowerStateChangedDate is stamped each time, so the power-state sync does not flip the host
-- back while Azure catches up, and the scaler counts a starting host as booting capacity.
--
-- A host with a user assigned is only stopped or restarted when @AllowAssigned = 1, which the
-- API passes only for an administrator who confirmed the hostname; otherwise the result is
-- Assigned and nothing changes. Stopping an assigned host also ends the assignment, exactly as
-- ReturnVm does, so the user is given a working host at their next sign-in instead of this
-- powered-off one. The host stays CleanupPending until the previous user has been removed,
-- which the sweep retries once the host is running again. Restart keeps the assignment: the
-- user can reconnect once the host is back.
--
-- The assignment ends before Azure is asked, so the broker never hands out a host that is
-- stopping. If Azure refuses, dbo.RevertVmPowerAction puts back the power state and the
-- assignment from the Previous* columns returned here.
--
-- StopMode is the active scaling rule's, for a stop that does not name its own.

CREATE PROCEDURE [dbo].[BeginVmPowerAction]
    @VMID INT,
    @Action VARCHAR(16),
    @AllowAssigned BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Hostname VARCHAR(255);
    DECLARE @PowerState VARCHAR(10);
    DECLARE @NetworkStatus VARCHAR(16);
    DECLARE @Status VARCHAR(16);
    DECLARE @Username VARCHAR(255);
    DECLARE @AvdHost VARCHAR(255);
    DECLARE @LeaseId UNIQUEIDENTIFIER;
    DECLARE @ReleasedDate DATETIME;
    DECLARE @Assigned BIT = 0;
    DECLARE @EndedAssignment BIT = 0;
    DECLARE @StopMode VARCHAR(16);
    DECLARE @Result VARCHAR(24) = 'Requested';
    DECLARE @Now DATETIME = GETDATE();
    DECLARE @StartedTransaction BIT = 0;

    IF @@TRANCOUNT = 0
    BEGIN
        BEGIN TRANSACTION;
        SET @StartedTransaction = 1;
    END

    SELECT @Hostname = Hostname,
           @PowerState = PowerState,
           @NetworkStatus = NetworkStatus,
           @Status = VmStatus,
           @Username = Username,
           @AvdHost = AvdHost,
           @LeaseId = LeaseId,
           @ReleasedDate = ReleasedDate
    FROM dbo.VirtualMachines WITH (UPDLOCK, HOLDLOCK, ROWLOCK)
    WHERE VMID = @VMID;

    SELECT TOP 1 @StopMode = COALESCE(StopMode, 'PowerOff')
    FROM dbo.VmScalingRules
    ORDER BY RuleID;

    SET @StopMode = COALESCE(@StopMode, 'PowerOff');
    SET @Assigned = CASE
        WHEN @Username IS NOT NULL OR @LeaseId IS NOT NULL OR @Status IN ('CheckedOut', 'Released') THEN 1
        ELSE 0
    END;

    IF @Hostname IS NULL
    BEGIN
        SET @Result = 'NotFound';
    END
    ELSE IF @Action IS NULL OR @Action NOT IN ('Start', 'Stop', 'Restart')
    BEGIN
        SET @Result = 'InvalidAction';
    END
    ELSE IF @Action IN ('Stop', 'Restart') AND @Assigned = 1 AND COALESCE(@AllowAssigned, 0) = 0
    BEGIN
        SET @Result = 'Assigned';
    END
    ELSE IF @Action = 'Restart' AND @PowerState = 'Off'
    BEGIN
        SET @Result = 'InvalidState';
    END
    ELSE IF @Action = 'Start'
    BEGIN
        -- Azure start is idempotent, so a host already recorded as on is only re-requested.
        UPDATE dbo.VirtualMachines
        SET PowerState = 'On',
            NetworkStatus = 'Unreachable',
            PowerStateChangedDate = @Now,
            LastUpdateDate = @Now
        WHERE VMID = @VMID
          AND PowerState = 'Off';
    END
    ELSE IF @Action = 'Stop'
    BEGIN
        -- Every CASE below reads the row as it was before this UPDATE.
        UPDATE dbo.VirtualMachines
        SET PowerState = 'Off',
            NetworkStatus = 'Unreachable',
            PowerStateChangedDate = @Now,
            LastUpdateDate = @Now,
            VmStatus = CASE WHEN @Assigned = 1 AND VmStatus IN ('CheckedOut', 'Released') THEN 'Available' ELSE VmStatus END,
            Username = CASE WHEN @Assigned = 1 THEN NULL ELSE Username END,
            AvdHost = CASE WHEN @Assigned = 1 THEN NULL ELSE AvdHost END,
            LeaseId = CASE WHEN @Assigned = 1 THEN NULL ELSE LeaseId END,
            ReleasedDate = CASE WHEN @Assigned = 1 THEN NULL ELSE ReleasedDate END,
            CleanupPending = CASE WHEN @Assigned = 1 AND Username IS NOT NULL THEN 1 ELSE CleanupPending END,
            CleanupUsername = CASE WHEN @Assigned = 1 AND Username IS NOT NULL THEN Username ELSE CleanupUsername END,
            CleanupLeaseId = CASE WHEN @Assigned = 1 AND Username IS NOT NULL THEN LeaseId ELSE CleanupLeaseId END,
            CleanupAttemptDate = CASE WHEN @Assigned = 1 AND Username IS NOT NULL THEN NULL ELSE CleanupAttemptDate END
        WHERE VMID = @VMID;

        SET @EndedAssignment = @Assigned;
    END
    ELSE IF @Action = 'Restart'
    BEGIN
        UPDATE dbo.VirtualMachines
        SET NetworkStatus = 'Unreachable',
            PowerStateChangedDate = @Now,
            LastUpdateDate = @Now
        WHERE VMID = @VMID;
    END

    IF @StartedTransaction = 1 COMMIT TRANSACTION;

    SELECT @Result AS Result,
           @VMID AS VMID,
           @Hostname AS Hostname,
           @Action AS Action,
           @PowerState AS PreviousPowerState,
           @NetworkStatus AS PreviousNetworkStatus,
           @Status AS PreviousVmStatus,
           @Username AS Username,
           @AvdHost AS AvdHost,
           @LeaseId AS PreviousLeaseId,
           @ReleasedDate AS PreviousReleasedDate,
           @Assigned AS Assigned,
           @EndedAssignment AS EndedAssignment,
           @StopMode AS StopMode;
END
GO
