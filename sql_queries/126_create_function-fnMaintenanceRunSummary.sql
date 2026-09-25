-- Every maintenance run with how many of its hosts are at each stage, for the run list, the
-- run details and the scheduled advance. Times are ISO-8601 UTC. InProgress counts the hosts
-- out of rotation for the run right now (Draining through Verifying).

CREATE OR ALTER FUNCTION dbo.fnMaintenanceRunSummary ()
RETURNS TABLE
AS
RETURN
    SELECT
        r.RunID, r.Name, r.Status, r.EndStatus, r.PatchMode, r.BatchSize, r.MinReadyOverride,
        r.SignOutDeadlineMinutes, r.WarningMinutes, r.WarningMessage, r.IncludePoweredOff, r.MaxFailures,
        r.CanaryCount, r.CanaryReached, r.SurgeRequested, r.WaitReason, r.StatusReason, r.CreatedBy, r.UpdatedBy,
        CONVERT(VARCHAR(33), r.CreatedAt, 126) + 'Z' AS CreatedAtUtc,
        CONVERT(VARCHAR(33), r.UpdatedAt, 126) + 'Z' AS UpdatedAtUtc,
        CONVERT(VARCHAR(33), r.EndedAt, 126) + 'Z' AS EndedAtUtc,
        CONVERT(VARCHAR(33), r.LastTickAt, 126) + 'Z' AS LastTickAtUtc,
        DATEDIFF(SECOND, r.LastTickAt, SYSUTCDATETIME()) AS LastTickAgeSeconds,
        COALESCE(c.Total, 0) AS Total,
        COALESCE(c.Pending, 0) AS Pending,
        COALESCE(c.InProgress, 0) AS InProgress,
        COALESCE(c.Succeeded, 0) AS Succeeded,
        COALESCE(c.Failed, 0) AS Failed,
        COALESCE(c.Skipped, 0) AS Skipped,
        COALESCE(c.Cancelled, 0) AS Cancelled,
        COALESCE(c.Admitted, 0) AS Admitted
    FROM dbo.MaintenanceRuns r
    OUTER APPLY (
        SELECT
            COUNT(*) AS Total,
            SUM(CASE WHEN h.State = 'Pending' THEN 1 ELSE 0 END) AS Pending,
            SUM(CASE WHEN h.State IN ('Draining', 'Starting', 'Patching', 'Restarting', 'Verifying') THEN 1 ELSE 0 END) AS InProgress,
            SUM(CASE WHEN h.State = 'Succeeded' THEN 1 ELSE 0 END) AS Succeeded,
            SUM(CASE WHEN h.State = 'Failed' THEN 1 ELSE 0 END) AS Failed,
            SUM(CASE WHEN h.State = 'Skipped' THEN 1 ELSE 0 END) AS Skipped,
            SUM(CASE WHEN h.State = 'Cancelled' THEN 1 ELSE 0 END) AS Cancelled,
            SUM(CASE WHEN h.AdmittedAt IS NOT NULL THEN 1 ELSE 0 END) AS Admitted
        FROM dbo.MaintenanceRunHosts h
        WHERE h.RunID = r.RunID
    ) c;
GO
