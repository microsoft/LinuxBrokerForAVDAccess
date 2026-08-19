-- Fleet-wide Linux host settings profile.
--
-- This is a singleton: SettingsScope is constrained to 'Global' and made unique, so the
-- table can only ever hold one active profile. The CHECK constraints below are the last
-- line of defence for values that reach the Linux hosts. The API and apply-host-settings.sh
-- validate the same bounds, but a value that slipped past both must still never be able to
-- strand the fleet (for example a zero grace period that logs every user off instantly, or a
-- reconcile interval low enough to hammer the broker API).

IF OBJECT_ID('dbo.LinuxHostSettings', 'U') IS NULL
BEGIN
    CREATE TABLE LinuxHostSettings (
        SettingsID INT IDENTITY(1,1) PRIMARY KEY,
        SettingsScope VARCHAR(16) NOT NULL CONSTRAINT DF_LinuxHostSettings_Scope DEFAULT ('Global'),

        -- Session lifecycle
        GracePeriodSeconds INT NOT NULL CONSTRAINT DF_LinuxHostSettings_GracePeriod DEFAULT (1200),
        ReconcileIntervalSeconds INT NOT NULL CONSTRAINT DF_LinuxHostSettings_ReconcileInterval DEFAULT (60),
        WatcherDebounceSeconds INT NOT NULL CONSTRAINT DF_LinuxHostSettings_WatcherDebounce DEFAULT (10),
        WatcherSettleSeconds INT NOT NULL CONSTRAINT DF_LinuxHostSettings_WatcherSettle DEFAULT (2),

        -- Idle session enforcement. IdleTimeoutSeconds = 0 disables it entirely, which is the
        -- shipped default so existing deployments keep their current behavior until an admin
        -- opts in.
        IdleTimeoutSeconds INT NOT NULL CONSTRAINT DF_LinuxHostSettings_IdleTimeout DEFAULT (0),
        IdleWarningSeconds INT NOT NULL CONSTRAINT DF_LinuxHostSettings_IdleWarning DEFAULT (120),

        -- Screen lock / screensaver policy pushed to dconf
        ScreenLockEnabled BIT NOT NULL CONSTRAINT DF_LinuxHostSettings_ScreenLockEnabled DEFAULT (1),
        ScreenIdleDelaySeconds INT NOT NULL CONSTRAINT DF_LinuxHostSettings_ScreenIdleDelay DEFAULT (0),
        ScreenLockDelaySeconds INT NOT NULL CONSTRAINT DF_LinuxHostSettings_ScreenLockDelay DEFAULT (0),
        ScreenLockSettingsLocked BIT NOT NULL CONSTRAINT DF_LinuxHostSettings_ScreenLockLocked DEFAULT (1),

        -- Version the hosts acknowledge so the portal can show drift
        SettingsVersion INT NOT NULL CONSTRAINT DF_LinuxHostSettings_Version DEFAULT (1),
        LastUpdateDate DATETIME CONSTRAINT DF_LinuxHostSettings_LastUpdate DEFAULT (GETDATE()),
        UpdatedBy NVARCHAR(255) NULL,

        SysStartTime DATETIME2 GENERATED ALWAYS AS ROW START HIDDEN,
        SysEndTime DATETIME2 GENERATED ALWAYS AS ROW END HIDDEN,
        PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime),

        CONSTRAINT UQ_LinuxHostSettings_Scope UNIQUE (SettingsScope),
        CONSTRAINT CK_LinuxHostSettings_Scope CHECK (SettingsScope = 'Global'),
        CONSTRAINT CK_LinuxHostSettings_GracePeriod CHECK (GracePeriodSeconds BETWEEN 60 AND 86400),
        CONSTRAINT CK_LinuxHostSettings_ReconcileInterval CHECK (ReconcileIntervalSeconds BETWEEN 30 AND 900),
        CONSTRAINT CK_LinuxHostSettings_WatcherDebounce CHECK (WatcherDebounceSeconds BETWEEN 1 AND 300),
        CONSTRAINT CK_LinuxHostSettings_WatcherSettle CHECK (WatcherSettleSeconds BETWEEN 0 AND 60),
        CONSTRAINT CK_LinuxHostSettings_IdleTimeout CHECK (IdleTimeoutSeconds = 0 OR IdleTimeoutSeconds BETWEEN 300 AND 86400),
        CONSTRAINT CK_LinuxHostSettings_IdleWarning CHECK (IdleWarningSeconds BETWEEN 0 AND 900),
        CONSTRAINT CK_LinuxHostSettings_IdleWarningFits CHECK (IdleTimeoutSeconds = 0 OR IdleWarningSeconds < IdleTimeoutSeconds),
        CONSTRAINT CK_LinuxHostSettings_ScreenIdleDelay CHECK (ScreenIdleDelaySeconds BETWEEN 0 AND 86400),
        CONSTRAINT CK_LinuxHostSettings_ScreenLockDelay CHECK (ScreenLockDelaySeconds BETWEEN 0 AND 86400),
        CONSTRAINT CK_LinuxHostSettings_Version CHECK (SettingsVersion > 0)
    )
    WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.LinuxHostSettingsHistory));
END;
GO

-- Seed the single global profile with the values that were previously hardcoded in the
-- release agent, the systemd timer, and the dconf keyfile, so applying this schema is a
-- behavioral no-op.
IF NOT EXISTS (SELECT 1 FROM dbo.LinuxHostSettings)
BEGIN
    INSERT INTO dbo.LinuxHostSettings (
        SettingsScope,
        GracePeriodSeconds,
        ReconcileIntervalSeconds,
        WatcherDebounceSeconds,
        WatcherSettleSeconds,
        IdleTimeoutSeconds,
        IdleWarningSeconds,
        ScreenLockEnabled,
        ScreenIdleDelaySeconds,
        ScreenLockDelaySeconds,
        ScreenLockSettingsLocked,
        SettingsVersion
    )
    VALUES ('Global', 1200, 60, 10, 2, 0, 120, 1, 0, 0, 1, 1);
END;
GO
