CREATE PROCEDURE [dbo].[GetLinuxHostSettings]
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1
        SettingsID,
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
        SettingsVersion,
        LastUpdateDate,
        UpdatedBy
    FROM dbo.LinuxHostSettings
    WHERE SettingsScope = 'Global'
    ORDER BY SettingsID;
END
GO
