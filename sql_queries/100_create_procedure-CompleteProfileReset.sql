-- Clears a requested profile reset once the host has renamed the profile, or found none.

CREATE PROCEDURE [dbo].[CompleteProfileReset]
    @Username VARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.VmUsers
    SET ProfileResetRequestedAt = NULL,
        ProfileResetRequestedBy = NULL
    WHERE username = @Username
      AND ProfileResetRequestedAt IS NOT NULL;

    SELECT CAST(CASE WHEN @@ROWCOUNT = 0 THEN 'NotPending' ELSE 'Completed' END AS VARCHAR(24)) AS Result;
END
GO
