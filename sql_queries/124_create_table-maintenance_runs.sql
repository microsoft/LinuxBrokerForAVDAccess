-- Rolling maintenance runs: patch or restart a set of hosts a batch at a time, keeping enough
-- hosts ready for users throughout. Only one run is active at a time (Active, Paused or
-- Stopping); dbo.CreateMaintenanceRun enforces that under an app lock.
--
--   Status        Active admits and advances hosts. Paused admits none and starts nothing new,
--                 but hosts already being patched or restarted finish. Stopping (a cancel, or
--                 too many failures) returns the hosts still waiting for their users, lets the
--                 rest finish, then becomes EndStatus.
--   PatchMode     Security or All runs linux_host/patch-host.sh; RebootOnly only restarts.
--   MinReadyOverride  The ready hosts to keep; NULL follows the scaling phase's MinVMs.
--   SignOutDeadlineMinutes  With a deadline, a host's user is warned WarningMinutes before it
--                 and then signed out; without one the run waits for them to leave.
--   CanaryCount   Pause once this many hosts have finished, so an operator can check them.
--   SurgeRequested  Set while a ready host waits because taking it would leave fewer ready
--                 hosts than the minimum; scaling then keeps one more host ready.
--   TickToken, TickLeaseUntil  The scheduled advance that owns the run, so two never overlap.
-- Times are UTC.

IF OBJECT_ID('dbo.MaintenanceRuns', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.MaintenanceRuns (
        RunID INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_MaintenanceRuns PRIMARY KEY,
        Name NVARCHAR(100) NULL,
        Status VARCHAR(16) NOT NULL CONSTRAINT DF_MaintenanceRuns_Status DEFAULT ('Active'),
        EndStatus VARCHAR(16) NULL,
        PatchMode VARCHAR(16) NOT NULL,
        BatchSize INT NOT NULL,
        MinReadyOverride INT NULL,
        SignOutDeadlineMinutes INT NULL,
        WarningMinutes INT NOT NULL CONSTRAINT DF_MaintenanceRuns_WarningMinutes DEFAULT (15),
        WarningMessage NVARCHAR(500) NULL,
        IncludePoweredOff BIT NOT NULL CONSTRAINT DF_MaintenanceRuns_IncludePoweredOff DEFAULT (0),
        MaxFailures INT NOT NULL CONSTRAINT DF_MaintenanceRuns_MaxFailures DEFAULT (1),
        CanaryCount INT NOT NULL CONSTRAINT DF_MaintenanceRuns_CanaryCount DEFAULT (0),
        CanaryReached BIT NOT NULL CONSTRAINT DF_MaintenanceRuns_CanaryReached DEFAULT (0),
        SurgeRequested BIT NOT NULL CONSTRAINT DF_MaintenanceRuns_SurgeRequested DEFAULT (0),
        WaitReason NVARCHAR(400) NULL,
        StatusReason NVARCHAR(400) NULL,
        TickToken UNIQUEIDENTIFIER NULL,
        TickLeaseUntil DATETIME2(3) NULL,
        LastTickAt DATETIME2(3) NULL,
        CreatedBy NVARCHAR(256) NULL,
        CreatedAt DATETIME2(3) NOT NULL CONSTRAINT DF_MaintenanceRuns_CreatedAt DEFAULT (SYSUTCDATETIME()),
        UpdatedBy NVARCHAR(256) NULL,
        UpdatedAt DATETIME2(3) NULL,
        EndedAt DATETIME2(3) NULL,
        CONSTRAINT CK_MaintenanceRuns_Status CHECK (Status IN ('Active', 'Paused', 'Stopping', 'Completed', 'Cancelled', 'Failed')),
        CONSTRAINT CK_MaintenanceRuns_EndStatus CHECK (EndStatus IS NULL OR EndStatus IN ('Completed', 'Cancelled', 'Failed')),
        CONSTRAINT CK_MaintenanceRuns_PatchMode CHECK (PatchMode IN ('Security', 'All', 'RebootOnly')),
        CONSTRAINT CK_MaintenanceRuns_BatchSize CHECK (BatchSize BETWEEN 1 AND 50),
        CONSTRAINT CK_MaintenanceRuns_MinReady CHECK (MinReadyOverride IS NULL OR MinReadyOverride BETWEEN 0 AND 1000),
        CONSTRAINT CK_MaintenanceRuns_Deadline CHECK (SignOutDeadlineMinutes IS NULL OR SignOutDeadlineMinutes BETWEEN 5 AND 1440),
        CONSTRAINT CK_MaintenanceRuns_Warning CHECK (WarningMinutes BETWEEN 1 AND 240
            AND (SignOutDeadlineMinutes IS NULL OR WarningMinutes < SignOutDeadlineMinutes)),
        CONSTRAINT CK_MaintenanceRuns_MaxFailures CHECK (MaxFailures BETWEEN 1 AND 1000),
        CONSTRAINT CK_MaintenanceRuns_Canary CHECK (CanaryCount BETWEEN 0 AND 50)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_MaintenanceRuns_Status' AND object_id = OBJECT_ID('dbo.MaintenanceRuns'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_MaintenanceRuns_Status
    ON dbo.MaintenanceRuns (Status)
    INCLUDE (SurgeRequested);
END;
GO
