-- One maintenance run, or the active one (Active, Paused or Stopping) when @RunID is NULL.
-- Also returns what admission works from right now: the ready hosts and the minimum it keeps
-- (the run's override, or else the scaling phase's MinVMs).

CREATE PROCEDURE [dbo].[GetMaintenanceRun]
    @RunID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Id INT = @RunID;
    IF @Id IS NULL
    BEGIN
        SELECT TOP 1 @Id = RunID FROM dbo.MaintenanceRuns WHERE Status IN ('Active', 'Paused', 'Stopping') ORDER BY RunID DESC;
    END

    DECLARE @PhaseMin INT = (SELECT TOP 1 MinVMs FROM dbo.fnActiveScalingPhase(NULL));
    DECLARE @Ready INT = (
        SELECT COUNT(*) FROM dbo.VirtualMachines
        WHERE VmStatus = 'Available' AND PowerState = 'On' AND NetworkStatus = 'Reachable'
          AND CleanupPending = 0 AND DrainRequested = 0 AND Username IS NULL AND LeaseId IS NULL
    );

    SELECT s.*,
           COALESCE(s.MinReadyOverride, @PhaseMin, 0) AS MinReadyInForce,
           @PhaseMin AS PhaseMinVMs,
           @Ready AS ReadyNow
    FROM dbo.fnMaintenanceRunSummary() s
    WHERE s.RunID = @Id;
END
GO
