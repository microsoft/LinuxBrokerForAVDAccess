-- PreserveSessionsOnDisconnect keeps disconnected sessions alive during the grace period.

IF COL_LENGTH('dbo.LinuxHostSettings', 'PreserveSessionsOnDisconnect') IS NULL
BEGIN
    ALTER TABLE dbo.LinuxHostSettings
    ADD PreserveSessionsOnDisconnect BIT NOT NULL CONSTRAINT DF_LinuxHostSettings_PreserveSessions DEFAULT (0);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_LinuxHostSettings_PreserveSessionsLock' AND parent_object_id = OBJECT_ID('dbo.LinuxHostSettings'))
BEGIN
    ALTER TABLE dbo.LinuxHostSettings WITH CHECK
    ADD CONSTRAINT CK_LinuxHostSettings_PreserveSessionsLock CHECK (NOT (PreserveSessionsOnDisconnect = 1 AND ScreenLockEnabled = 1));
END;
GO
