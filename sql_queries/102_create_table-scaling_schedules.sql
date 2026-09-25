-- Time windows that override the default scaling rule, such as business hours. Each window has
-- the same values as a rule and applies on its days, from StartTime to EndTime in the policy's
-- time zone (dbo.ScalingPolicy). A window whose EndTime is at or before its StartTime runs past
-- midnight into the next day. Outside every enabled window, the default rule (the lowest
-- RuleID in dbo.VmScalingRules) applies. Enabled windows may not overlap; dbo.SaveScalingSchedule
-- enforces that.
--
-- DaysOfWeek is a bit mask: 1 Monday, 2 Tuesday, 4 Wednesday, 8 Thursday, 16 Friday,
-- 32 Saturday, 64 Sunday. System-versioned, like the rules, so earlier versions are kept.

IF OBJECT_ID('dbo.ScalingSchedules', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ScalingSchedules (
        ScheduleID INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ScalingSchedules PRIMARY KEY,
        Name NVARCHAR(64) NOT NULL,
        Enabled BIT NOT NULL CONSTRAINT DF_ScalingSchedules_Enabled DEFAULT (1),
        DaysOfWeek TINYINT NOT NULL,
        StartTime TIME(0) NOT NULL,
        EndTime TIME(0) NOT NULL,
        MinVMs INT NOT NULL,
        MaxVMs INT NOT NULL,
        ScaleUpRatio DECIMAL(5,2) NOT NULL,
        ScaleUpIncrement INT NOT NULL,
        ScaleDownRatio DECIMAL(5,2) NOT NULL,
        ScaleDownIncrement INT NOT NULL,
        StopMode VARCHAR(16) NULL,
        UpdatedBy NVARCHAR(256) NULL,
        SysStartTime DATETIME2 GENERATED ALWAYS AS ROW START HIDDEN NOT NULL,
        SysEndTime DATETIME2 GENERATED ALWAYS AS ROW END HIDDEN NOT NULL,
        PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime),
        CONSTRAINT CK_ScalingSchedules_Name CHECK (LEN(LTRIM(RTRIM(Name))) > 0),
        CONSTRAINT CK_ScalingSchedules_Days CHECK (DaysOfWeek BETWEEN 1 AND 127),
        CONSTRAINT CK_ScalingSchedules_Times CHECK (StartTime <> EndTime),
        CONSTRAINT CK_ScalingSchedules_MinMax CHECK (MinVMs >= 1 AND MaxVMs > MinVMs),
        CONSTRAINT CK_ScalingSchedules_Ratios CHECK (
            ScaleUpRatio BETWEEN 0 AND 100 AND ScaleDownRatio BETWEEN 0 AND 100 AND ScaleUpRatio > ScaleDownRatio
        ),
        CONSTRAINT CK_ScalingSchedules_Increments CHECK (ScaleUpIncrement >= 1 AND ScaleDownIncrement >= 1),
        CONSTRAINT CK_ScalingSchedules_StopMode CHECK (StopMode IS NULL OR StopMode IN ('PowerOff', 'Deallocate'))
    )
    WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.ScalingSchedulesHistory));
END;
GO
