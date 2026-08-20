-- Updates the single global settings profile.
--
-- SettingsVersion is only bumped when a value actually changed. Saving the form without
-- edits therefore does not churn the fleet into re-applying identical settings.

CREATE PROCEDURE [dbo].[UpdateLinuxHostSettings]
    @GracePeriodSeconds INT = NULL,
    @ReconcileIntervalSeconds INT = NULL,
    @WatcherDebounceSeconds INT = NULL,
    @WatcherSettleSeconds INT = NULL,
    @IdleTimeoutSeconds INT = NULL,
    @IdleWarningSeconds INT = NULL,
    @ScreenLockEnabled BIT = NULL,
    @DisableLockScreen BIT = NULL,
    @ScreenIdleDelaySeconds INT = NULL,
    @ScreenLockDelaySeconds INT = NULL,
    @ScreenLockSettingsLocked BIT = NULL,
    @UpdatedBy NVARCHAR(255) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.LinuxHostSettings
    SET GracePeriodSeconds = COALESCE(@GracePeriodSeconds, GracePeriodSeconds),
        ReconcileIntervalSeconds = COALESCE(@ReconcileIntervalSeconds, ReconcileIntervalSeconds),
        WatcherDebounceSeconds = COALESCE(@WatcherDebounceSeconds, WatcherDebounceSeconds),
        WatcherSettleSeconds = COALESCE(@WatcherSettleSeconds, WatcherSettleSeconds),
        IdleTimeoutSeconds = COALESCE(@IdleTimeoutSeconds, IdleTimeoutSeconds),
        IdleWarningSeconds = COALESCE(@IdleWarningSeconds, IdleWarningSeconds),
        ScreenLockEnabled = COALESCE(@ScreenLockEnabled, ScreenLockEnabled),
        DisableLockScreen = COALESCE(@DisableLockScreen, DisableLockScreen),
        ScreenIdleDelaySeconds = COALESCE(@ScreenIdleDelaySeconds, ScreenIdleDelaySeconds),
        ScreenLockDelaySeconds = COALESCE(@ScreenLockDelaySeconds, ScreenLockDelaySeconds),
        ScreenLockSettingsLocked = COALESCE(@ScreenLockSettingsLocked, ScreenLockSettingsLocked),
        SettingsVersion = SettingsVersion + 1,
        LastUpdateDate = GETDATE(),
        UpdatedBy = COALESCE(@UpdatedBy, UpdatedBy)
    WHERE SettingsScope = 'Global'
      AND (
            COALESCE(@GracePeriodSeconds, GracePeriodSeconds) <> GracePeriodSeconds
         OR COALESCE(@ReconcileIntervalSeconds, ReconcileIntervalSeconds) <> ReconcileIntervalSeconds
         OR COALESCE(@WatcherDebounceSeconds, WatcherDebounceSeconds) <> WatcherDebounceSeconds
         OR COALESCE(@WatcherSettleSeconds, WatcherSettleSeconds) <> WatcherSettleSeconds
         OR COALESCE(@IdleTimeoutSeconds, IdleTimeoutSeconds) <> IdleTimeoutSeconds
         OR COALESCE(@IdleWarningSeconds, IdleWarningSeconds) <> IdleWarningSeconds
         OR COALESCE(@ScreenLockEnabled, ScreenLockEnabled) <> ScreenLockEnabled
         OR COALESCE(@DisableLockScreen, DisableLockScreen) <> DisableLockScreen
         OR COALESCE(@ScreenIdleDelaySeconds, ScreenIdleDelaySeconds) <> ScreenIdleDelaySeconds
         OR COALESCE(@ScreenLockDelaySeconds, ScreenLockDelaySeconds) <> ScreenLockDelaySeconds
         OR COALESCE(@ScreenLockSettingsLocked, ScreenLockSettingsLocked) <> ScreenLockSettingsLocked
      );

    EXEC dbo.GetLinuxHostSettings;
END
GO
