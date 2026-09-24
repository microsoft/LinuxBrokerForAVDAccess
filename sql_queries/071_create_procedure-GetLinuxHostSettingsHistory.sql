-- Every version of the fleet-wide host settings profile, newest first, for the portal's
-- version history. The rows come from the temporal history table, whose period columns are
-- UTC; UpdatedBy is the administrator who saved each version.
--
-- This lives after 064 because it reads PreserveSessionsOnDisconnect.

CREATE PROCEDURE [dbo].[GetLinuxHostSettingsHistory]
    @Limit INT = 50
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SafeLimit INT = CASE
        WHEN @Limit IS NULL OR @Limit < 1 THEN 50
        WHEN @Limit > 200 THEN 200
        ELSE @Limit
    END;

    SELECT TOP (@SafeLimit)
        SettingsVersion,
        GracePeriodSeconds,
        ReconcileIntervalSeconds,
        WatcherDebounceSeconds,
        WatcherSettleSeconds,
        IdleTimeoutSeconds,
        IdleWarningSeconds,
        ScreenLockEnabled,
        DisableLockScreen,
        ScreenIdleDelaySeconds,
        ScreenLockDelaySeconds,
        ScreenLockSettingsLocked,
        PreserveSessionsOnDisconnect,
        UpdatedBy,
        CONVERT(VARCHAR(33), SysStartTime, 126) + 'Z' AS ValidFromUtc,
        CASE WHEN SysEndTime >= '9999-12-31' THEN NULL ELSE CONVERT(VARCHAR(33), SysEndTime, 126) + 'Z' END AS ValidToUtc,
        CAST(CASE WHEN SysEndTime >= '9999-12-31' THEN 1 ELSE 0 END AS BIT) AS IsCurrent
    FROM dbo.LinuxHostSettings FOR SYSTEM_TIME ALL
    WHERE SettingsScope = 'Global'
    ORDER BY SysStartTime DESC, SettingsVersion DESC;
END
GO
