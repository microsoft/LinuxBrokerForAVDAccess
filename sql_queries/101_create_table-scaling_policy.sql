-- The scaling policy's settings that apply to every schedule: the time zone the schedules'
-- days and times are read in. One row. A Windows time zone name, as AT TIME ZONE and
-- sys.time_zone_info use; UTC until an administrator chooses one.

IF OBJECT_ID('dbo.ScalingPolicy', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ScalingPolicy (
        PolicyID INT NOT NULL CONSTRAINT PK_ScalingPolicy PRIMARY KEY,
        TimeZone NVARCHAR(64) NOT NULL CONSTRAINT DF_ScalingPolicy_TimeZone DEFAULT (N'UTC'),
        UpdatedBy NVARCHAR(256) NULL,
        UpdatedAt DATETIME2(3) NOT NULL CONSTRAINT DF_ScalingPolicy_UpdatedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT CK_ScalingPolicy_SingleRow CHECK (PolicyID = 1)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.ScalingPolicy)
BEGIN
    INSERT INTO dbo.ScalingPolicy (PolicyID, TimeZone) VALUES (1, N'UTC');
END;
GO
