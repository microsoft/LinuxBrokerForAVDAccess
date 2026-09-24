-- The latest heartbeat from each Linux host agent, one row per host.
--
-- release-session.sh posts a heartbeat at the end of every timer run. It carries what the
-- agent can observe about its host (agent and script versions, OS, desktop, xrdp, NFS, load,
-- memory, disk and sessions), so an operator can find outdated, wedged or NFS-broken hosts
-- without SSH. Only the current row is kept: VirtualMachinesHistory already records the
-- broker's own view of each host over time. ReceivedAt is UTC.

IF OBJECT_ID('dbo.HostHeartbeats', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.HostHeartbeats (
        Hostname VARCHAR(255) NOT NULL CONSTRAINT PK_HostHeartbeats PRIMARY KEY,
        ReceivedAt DATETIME2(3) NOT NULL,
        AgentVersion VARCHAR(32) NULL,
        ScriptVersionsJson NVARCHAR(2000) NULL,
        SettingsVersion INT NULL,
        OsId VARCHAR(32) NULL,
        OsVersion VARCHAR(32) NULL,
        OsName NVARCHAR(128) NULL,
        KernelVersion VARCHAR(128) NULL,
        Desktop VARCHAR(32) NULL,
        XrdpVersion VARCHAR(32) NULL,
        XrdpActive BIT NULL,
        NfsReachable BIT NULL,
        NfsMountCount INT NULL,
        LoadAverage DECIMAL(9,2) NULL,
        CpuCount INT NULL,
        MemoryAvailableMb INT NULL,
        MemoryTotalMb INT NULL,
        RootDiskFreePct TINYINT NULL,
        UptimeSeconds BIGINT NULL,
        SessionCount INT NULL,
        SessionsJson NVARCHAR(MAX) NULL,
        CONSTRAINT CK_HostHeartbeats_ScriptVersionsJson CHECK (ScriptVersionsJson IS NULL OR ISJSON(ScriptVersionsJson) = 1),
        CONSTRAINT CK_HostHeartbeats_SessionsJson CHECK (SessionsJson IS NULL OR ISJSON(SessionsJson) = 1),
        CONSTRAINT CK_HostHeartbeats_RootDiskFreePct CHECK (RootDiskFreePct IS NULL OR RootDiskFreePct BETWEEN 0 AND 100),
        CONSTRAINT CK_HostHeartbeats_NonNegative CHECK (
            (SettingsVersion IS NULL OR SettingsVersion >= 0)
            AND (NfsMountCount IS NULL OR NfsMountCount >= 0)
            AND (LoadAverage IS NULL OR LoadAverage >= 0)
            AND (CpuCount IS NULL OR CpuCount >= 0)
            AND (MemoryAvailableMb IS NULL OR MemoryAvailableMb >= 0)
            AND (MemoryTotalMb IS NULL OR MemoryTotalMb >= 0)
            AND (UptimeSeconds IS NULL OR UptimeSeconds >= 0)
            AND (SessionCount IS NULL OR SessionCount >= 0)
        )
    );
END;
GO
