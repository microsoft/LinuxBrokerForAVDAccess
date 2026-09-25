-- A profile reset an administrator requested for a user. The broker applies it at the user's
-- next new assignment, on the assigned host, before the home is mounted, so the rename can
-- never race a sign-in. Both columns are cleared once it has been applied or cancelled.
-- ProfileResetRequestedAt is UTC.

IF COL_LENGTH('dbo.VmUsers', 'ProfileResetRequestedAt') IS NULL
BEGIN
    ALTER TABLE dbo.VmUsers
    ADD ProfileResetRequestedAt DATETIME2(3) NULL;
END;
GO

IF COL_LENGTH('dbo.VmUsers', 'ProfileResetRequestedBy') IS NULL
BEGIN
    ALTER TABLE dbo.VmUsers
    ADD ProfileResetRequestedBy NVARCHAR(256) NULL;
END;
GO
