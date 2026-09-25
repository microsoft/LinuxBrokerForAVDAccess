-- Finds broker users for the portal's "find user" search: everyone the broker has provisioned
-- has a VmUsers row. @Query matches any part of the username; exact and prefix matches come
-- first. CHARINDEX is used instead of LIKE so the input needs no wildcard escaping.

CREATE PROCEDURE [dbo].[SearchUsers]
    @Query VARCHAR(64) = NULL,
    @Limit INT = 25
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Filter VARCHAR(64) = NULLIF(LTRIM(RTRIM(@Query)), '');
    DECLARE @SafeLimit INT = CASE
        WHEN @Limit IS NULL OR @Limit < 1 THEN 25
        WHEN @Limit > 200 THEN 200
        ELSE @Limit
    END;

    SELECT TOP (@SafeLimit)
        u.username AS Username,
        u.uid AS Uid,
        CAST(CASE WHEN u.ProfileResetRequestedAt IS NULL THEN 0 ELSE 1 END AS BIT) AS ProfileResetPending,
        cur.VMID AS CurrentVMID,
        cur.Hostname AS CurrentHostname,
        cur.VmStatus AS CurrentVmStatus
    FROM dbo.VmUsers u
    OUTER APPLY (
        SELECT TOP 1 vm.VMID, vm.Hostname, vm.VmStatus
        FROM dbo.VirtualMachines vm
        WHERE vm.Username = u.username
          AND vm.VmStatus IN ('CheckedOut', 'Released')
        ORDER BY CASE WHEN vm.VmStatus = 'CheckedOut' THEN 0 ELSE 1 END, vm.VMID
    ) cur
    WHERE @Filter IS NULL OR CHARINDEX(@Filter, u.username) > 0
    ORDER BY
        CASE
            WHEN @Filter IS NULL THEN 2
            WHEN u.username = @Filter THEN 0
            WHEN LEFT(u.username, LEN(@Filter)) = @Filter THEN 1
            ELSE 2
        END,
        u.username;
END
GO
