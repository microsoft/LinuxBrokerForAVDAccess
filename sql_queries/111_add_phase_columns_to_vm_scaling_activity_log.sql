-- What each scaling run worked from, for the dashboard's capacity trends: the phase that
-- applied (a schedule window or the default rule), its minimum and maximum, and the
-- serviceable and draining counts. Nullable, so runs from before this change read as unknown.

IF COL_LENGTH('dbo.VmScalingActivityLog', 'PhaseName') IS NULL
BEGIN
    ALTER TABLE dbo.VmScalingActivityLog ADD PhaseName NVARCHAR(64) NULL;
END;
GO

IF COL_LENGTH('dbo.VmScalingActivityLog', 'ScheduleID') IS NULL
BEGIN
    ALTER TABLE dbo.VmScalingActivityLog ADD ScheduleID INT NULL;
END;
GO

IF COL_LENGTH('dbo.VmScalingActivityLog', 'MinVMs') IS NULL
BEGIN
    ALTER TABLE dbo.VmScalingActivityLog ADD MinVMs INT NULL;
END;
GO

IF COL_LENGTH('dbo.VmScalingActivityLog', 'MaxVMs') IS NULL
BEGIN
    ALTER TABLE dbo.VmScalingActivityLog ADD MaxVMs INT NULL;
END;
GO

IF COL_LENGTH('dbo.VmScalingActivityLog', 'ServiceableVMs') IS NULL
BEGIN
    ALTER TABLE dbo.VmScalingActivityLog ADD ServiceableVMs INT NULL;
END;
GO

IF COL_LENGTH('dbo.VmScalingActivityLog', 'DrainingVMs') IS NULL
BEGIN
    ALTER TABLE dbo.VmScalingActivityLog ADD DrainingVMs INT NULL;
END;
GO

-- Most readers want the recent runs, by time.
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_VmScalingActivityLog_CheckTimestamp'
      AND object_id = OBJECT_ID('dbo.VmScalingActivityLog')
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_VmScalingActivityLog_CheckTimestamp
    ON dbo.VmScalingActivityLog (CheckTimestamp)
    INCLUDE (CurrentRunningVMs, CurrentInUseVMs, ServiceableVMs, MinVMs, MaxVMs, DrainingVMs);
END;
GO
