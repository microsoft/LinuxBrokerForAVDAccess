-- The hosts a user was assigned, from the temporal VM history: per host, when the user was
-- first and last on it and how many assignments (leases) they had there, newest first. Only
-- the last @Days days are read. Period columns are UTC, so the times are ISO-8601 UTC strings.

CREATE PROCEDURE [dbo].[GetUserHostHistory]
    @Username VARCHAR(255),
    @Days INT = 90,
    @Limit INT = 20
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now DATETIME2 = SYSUTCDATETIME();
    DECLARE @Since DATETIME2 = DATEADD(DAY, -CASE WHEN @Days BETWEEN 1 AND 3650 THEN @Days ELSE 90 END, @Now);
    DECLARE @SafeLimit INT = CASE
        WHEN @Limit IS NULL OR @Limit < 1 THEN 20
        WHEN @Limit > 100 THEN 100
        ELSE @Limit
    END;

    SELECT TOP (@SafeLimit)
        h.VMID,
        MAX(h.Hostname) AS Hostname,
        CONVERT(VARCHAR(33), CAST(MIN(h.SysStartTime) AS DATETIME2(0)), 126) + 'Z' AS FirstSeenUtc,
        CONVERT(VARCHAR(33), CAST(MAX(CASE WHEN h.SysEndTime > @Now THEN @Now ELSE h.SysEndTime END) AS DATETIME2(0)), 126) + 'Z' AS LastSeenUtc,
        COUNT(DISTINCT h.LeaseId) AS Assignments,
        CAST(MAX(CASE WHEN h.SysEndTime > @Now THEN 1 ELSE 0 END) AS BIT) AS IsCurrent
    FROM dbo.VirtualMachines FOR SYSTEM_TIME ALL AS h
    WHERE h.Username = @Username
      AND h.SysEndTime > @Since
    GROUP BY h.VMID
    ORDER BY MAX(CASE WHEN h.SysEndTime > @Now THEN @Now ELSE h.SysEndTime END) DESC, h.VMID;
END
GO
