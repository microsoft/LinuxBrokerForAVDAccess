-- Records a maintenance host's progress as a compare-and-set: the change only applies while
-- the row still has @ExpectedVersion, so two overlapping advances can never both act on one
-- step. A final state (Succeeded, Failed, Skipped, Cancelled) never changes again.
--
-- A new @State starts a new step (StepStartedAt, and Attempts back to zero). @MarkAction
-- records that the step's action was requested now and counts an attempt; the other @Mark*
-- flags stamp their times from the database clock. @RestartFromAction takes the restart time
-- from the step's own request, for a powered-off host whose start was its restart.
--
-- Result: Updated with the new row, Conflict (the row moved on), Final or NotFound.

CREATE PROCEDURE [dbo].[SetMaintenanceHostState]
    @RunHostID INT,
    @ExpectedVersion INT,
    @State VARCHAR(16) = NULL,
    @Detail NVARCHAR(400) = NULL,
    @SetDetail BIT = 0,
    @MarkAction BIT = 0,
    @MarkWarning BIT = 0,
    @MarkSignOut BIT = 0,
    @PatchToken VARCHAR(64) = NULL,
    @MarkPatchStarted BIT = 0,
    @MarkPatchFinished BIT = 0,
    @MarkRestart BIT = 0,
    @RestartFromAction BIT = 0,
    @MarkVerified BIT = 0,
    @RebootRequired VARCHAR(8) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @Updated TABLE (RunHostID INT);
    DECLARE @CurrentState VARCHAR(16);

    IF @State IS NOT NULL AND @State NOT IN ('Pending', 'Draining', 'Starting', 'Patching', 'Restarting', 'Verifying',
                                             'Succeeded', 'Failed', 'Skipped', 'Cancelled')
    BEGIN
        RAISERROR('Unknown maintenance host state.', 16, 1);
        RETURN;
    END

    UPDATE h
    SET State = COALESCE(@State, h.State),
        StepStartedAt = CASE WHEN @State IS NOT NULL AND @State <> h.State THEN @Now ELSE h.StepStartedAt END,
        Attempts = CASE
            WHEN @State IS NOT NULL AND @State <> h.State THEN CASE WHEN @MarkAction = 1 THEN 1 ELSE 0 END
            WHEN @MarkAction = 1 THEN h.Attempts + 1
            ELSE h.Attempts
        END,
        ActionRequestedAt = CASE
            WHEN @MarkAction = 1 THEN @Now
            WHEN @State IS NOT NULL AND @State <> h.State THEN NULL
            ELSE h.ActionRequestedAt
        END,
        WarningSentAt = CASE WHEN @MarkWarning = 1 THEN @Now ELSE h.WarningSentAt END,
        SignOutRequestedAt = CASE WHEN @MarkSignOut = 1 THEN @Now ELSE h.SignOutRequestedAt END,
        PatchToken = COALESCE(@PatchToken, h.PatchToken),
        PatchStartedAt = CASE WHEN @MarkPatchStarted = 1 THEN COALESCE(h.PatchStartedAt, @Now) ELSE h.PatchStartedAt END,
        PatchFinishedAt = CASE WHEN @MarkPatchFinished = 1 THEN @Now ELSE h.PatchFinishedAt END,
        RestartRequestedAt = CASE
            WHEN @RestartFromAction = 1 THEN COALESCE(h.ActionRequestedAt, @Now)
            WHEN @MarkRestart = 1 THEN @Now
            ELSE h.RestartRequestedAt
        END,
        VerifiedAt = CASE WHEN @MarkVerified = 1 THEN @Now ELSE h.VerifiedAt END,
        CompletedAt = CASE WHEN @State IN ('Succeeded', 'Failed', 'Skipped', 'Cancelled') THEN @Now ELSE h.CompletedAt END,
        RebootRequired = COALESCE(@RebootRequired, h.RebootRequired),
        Detail = CASE WHEN @SetDetail = 1 THEN LEFT(@Detail, 400) ELSE h.Detail END,
        Version = h.Version + 1,
        UpdatedAt = @Now
    OUTPUT INSERTED.RunHostID INTO @Updated
    FROM dbo.MaintenanceRunHosts h
    WHERE h.RunHostID = @RunHostID
      AND h.Version = @ExpectedVersion
      AND h.State NOT IN ('Succeeded', 'Failed', 'Skipped', 'Cancelled');

    IF EXISTS (SELECT 1 FROM @Updated)
    BEGIN
        SELECT CAST('Updated' AS VARCHAR(16)) AS Result, RunHostID, RunID, VMID, Hostname, State, Version, Attempts, Detail
        FROM dbo.MaintenanceRunHosts
        WHERE RunHostID = @RunHostID;
        RETURN;
    END

    SELECT @CurrentState = State FROM dbo.MaintenanceRunHosts WHERE RunHostID = @RunHostID;

    SELECT CAST(CASE
               WHEN @CurrentState IS NULL THEN 'NotFound'
               WHEN @CurrentState IN ('Succeeded', 'Failed', 'Skipped', 'Cancelled') THEN 'Final'
               ELSE 'Conflict'
           END AS VARCHAR(16)) AS Result,
           RunHostID, RunID, VMID, Hostname, State, Version, Attempts, Detail
    FROM (SELECT 1 AS One) one
    LEFT JOIN dbo.MaintenanceRunHosts ON RunHostID = @RunHostID;
END
GO
