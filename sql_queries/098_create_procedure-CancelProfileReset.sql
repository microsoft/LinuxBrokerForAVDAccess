-- Withdraws a requested profile reset. NotPending means there was none to withdraw.

CREATE PROCEDURE [dbo].[CancelProfileReset]
    @Username VARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.VmUsers WHERE username = @Username)
    BEGIN
        SELECT CAST('NotFound' AS VARCHAR(24)) AS Result;
        RETURN;
    END

    UPDATE dbo.VmUsers
    SET ProfileResetRequestedAt = NULL,
        ProfileResetRequestedBy = NULL
    WHERE username = @Username
      AND ProfileResetRequestedAt IS NOT NULL;

    SELECT CAST(CASE WHEN @@ROWCOUNT = 0 THEN 'NotPending' ELSE 'Cancelled' END AS VARCHAR(24)) AS Result;
END
GO
