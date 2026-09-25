-- Whether a requested profile reset can be applied on this checkout. The API calls it after
-- CheckoutVm gave @VMID to @Username as a new assignment, and before create-user.sh mounts the
-- home. The reset is applied only when nothing else can be using the profile:
--   * this is the user's only assignment,
--   * no other host is waiting to remove the user (a cleanup the user may still be signed
--     in for), and
--   * no heartbeat from the last @FreshSeconds reports the user on another host.
-- Otherwise it is left pending for a later checkout. Results: Ready, NotPending, NotAssigned,
-- InUseElsewhere.

CREATE PROCEDURE [dbo].[BeginProfileReset]
    @Username VARCHAR(255),
    @VMID INT,
    @FreshSeconds INT = 600
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Hostname VARCHAR(255);
    DECLARE @SafeFreshSeconds INT = CASE WHEN @FreshSeconds IS NULL OR @FreshSeconds < 60 THEN 600 ELSE @FreshSeconds END;

    IF NOT EXISTS (SELECT 1 FROM dbo.VmUsers WHERE username = @Username AND ProfileResetRequestedAt IS NOT NULL)
    BEGIN
        SELECT CAST('NotPending' AS VARCHAR(24)) AS Result;
        RETURN;
    END

    SELECT @Hostname = Hostname
    FROM dbo.VirtualMachines
    WHERE VMID = @VMID
      AND Username = @Username
      AND VmStatus = 'CheckedOut';

    IF @Hostname IS NULL
    BEGIN
        SELECT CAST('NotAssigned' AS VARCHAR(24)) AS Result;
        RETURN;
    END

    IF EXISTS (
        SELECT 1 FROM dbo.VirtualMachines
        WHERE VMID <> @VMID
          AND (Username = @Username OR (CleanupPending = 1 AND CleanupUsername = @Username))
    )
    OR EXISTS (
        SELECT 1
        FROM dbo.HostHeartbeats hb
        CROSS APPLY OPENJSON(hb.SessionsJson) WITH (Username VARCHAR(64) '$.username') s
        WHERE hb.SessionsJson IS NOT NULL
          AND hb.Hostname <> @Hostname
          AND hb.ReceivedAt >= DATEADD(SECOND, -@SafeFreshSeconds, SYSUTCDATETIME())
          AND s.Username = @Username
    )
    BEGIN
        SELECT CAST('InUseElsewhere' AS VARCHAR(24)) AS Result;
        RETURN;
    END

    SELECT CAST('Ready' AS VARCHAR(24)) AS Result;
END
GO
