-- Asks for a fresh profile for a broker user at their next new assignment. Asking again only
-- refreshes who asked and when. NotFound means the broker has never provisioned the user.
-- CurrentlyAssigned tells the portal the reset waits until the current assignment ends.

CREATE PROCEDURE [dbo].[RequestProfileReset]
    @Username VARCHAR(255),
    @RequestedBy NVARCHAR(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.VmUsers
    SET ProfileResetRequestedAt = SYSUTCDATETIME(),
        ProfileResetRequestedBy = NULLIF(LTRIM(RTRIM(@RequestedBy)), N'')
    WHERE username = @Username;

    IF @@ROWCOUNT = 0
    BEGIN
        SELECT CAST('NotFound' AS VARCHAR(24)) AS Result,
               CAST(@Username AS VARCHAR(255)) AS Username,
               CAST(NULL AS VARCHAR(33)) AS ProfileResetRequestedAtUtc,
               CAST(NULL AS NVARCHAR(256)) AS ProfileResetRequestedBy,
               CAST(0 AS BIT) AS CurrentlyAssigned;
        RETURN;
    END

    SELECT CAST('Requested' AS VARCHAR(24)) AS Result,
           u.username AS Username,
           CONVERT(VARCHAR(33), u.ProfileResetRequestedAt, 126) + 'Z' AS ProfileResetRequestedAtUtc,
           u.ProfileResetRequestedBy,
           CAST(CASE WHEN EXISTS (
               SELECT 1 FROM dbo.VirtualMachines
               WHERE Username = @Username AND VmStatus IN ('CheckedOut', 'Released')
           ) THEN 1 ELSE 0 END AS BIT) AS CurrentlyAssigned
    FROM dbo.VmUsers u
    WHERE u.username = @Username;
END
GO
