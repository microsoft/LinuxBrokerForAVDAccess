-- Stores a Linux host's heartbeat, replacing its previous one.
--
-- The API validates and normalizes the document before calling this. Every value is read here
-- as text and converted with TRY_CONVERT, and anything out of range becomes NULL, so a value
-- that slipped past the API is dropped rather than failing the write. Only hosts registered in
-- dbo.VirtualMachines are stored (Result NotFound otherwise), the same rule as the settings
-- acknowledgement.
--
-- A heartbeat that carries SettingsVersion also records it as applied, so a host whose
-- separate acknowledgement failed is not left showing drift. That write only happens when the
-- version actually changed: VirtualMachines is system-versioned, and writing it on every
-- heartbeat would add a history row per host per minute.

CREATE PROCEDURE [dbo].[RecordHostHeartbeat]
    @Hostname VARCHAR(255),
    @HeartbeatJson NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RegisteredHostname VARCHAR(255);
    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    SELECT TOP 1 @RegisteredHostname = Hostname
    FROM dbo.VirtualMachines
    WHERE Hostname = @Hostname
    ORDER BY VMID;

    IF @RegisteredHostname IS NULL
    BEGIN
        SELECT CAST('NotFound' AS VARCHAR(16)) AS Result, @Hostname AS Hostname, CAST(NULL AS VARCHAR(33)) AS ReceivedAtUtc;
        RETURN;
    END

    IF @HeartbeatJson IS NULL OR ISJSON(@HeartbeatJson) <> 1
    BEGIN
        SELECT CAST('Invalid' AS VARCHAR(16)) AS Result, @RegisteredHostname AS Hostname, CAST(NULL AS VARCHAR(33)) AS ReceivedAtUtc;
        RETURN;
    END

    DECLARE @AgentVersion VARCHAR(32), @ScriptVersionsJson NVARCHAR(MAX), @SettingsVersion INT,
            @OsId VARCHAR(32), @OsVersion VARCHAR(32), @OsName NVARCHAR(128), @KernelVersion VARCHAR(128),
            @Desktop VARCHAR(32), @XrdpVersion VARCHAR(32), @XrdpActive BIT, @NfsReachable BIT, @NfsMountCount INT,
            @LoadAverage DECIMAL(9,2), @CpuCount INT, @MemoryAvailableMb INT, @MemoryTotalMb INT,
            @RootDiskFreePct INT, @UptimeSeconds BIGINT, @SessionsJson NVARCHAR(MAX), @SessionCount INT;

    SELECT
        @AgentVersion = LEFT(agentVersion, 32),
        @ScriptVersionsJson = scriptVersions,
        @SettingsVersion = TRY_CONVERT(INT, settingsVersion),
        @OsId = LEFT(osId, 32),
        @OsVersion = LEFT(osVersion, 32),
        @OsName = LEFT(osName, 128),
        @KernelVersion = LEFT(kernel, 128),
        @Desktop = LEFT(desktop, 32),
        @XrdpVersion = LEFT(xrdpVersion, 32),
        @XrdpActive = TRY_CONVERT(BIT, xrdpActive),
        @NfsReachable = TRY_CONVERT(BIT, nfsReachable),
        @NfsMountCount = TRY_CONVERT(INT, nfsMounts),
        @LoadAverage = TRY_CONVERT(DECIMAL(9,2), loadAverage),
        @CpuCount = TRY_CONVERT(INT, cpuCount),
        @MemoryAvailableMb = TRY_CONVERT(INT, memoryAvailableMb),
        @MemoryTotalMb = TRY_CONVERT(INT, memoryTotalMb),
        @RootDiskFreePct = TRY_CONVERT(INT, rootDiskFreePct),
        @UptimeSeconds = TRY_CONVERT(BIGINT, uptimeSeconds),
        @SessionsJson = sessions
    FROM OPENJSON(@HeartbeatJson)
    WITH (
        agentVersion NVARCHAR(4000) '$.agentVersion',
        scriptVersions NVARCHAR(MAX) '$.scriptVersions' AS JSON,
        settingsVersion NVARCHAR(4000) '$.settingsVersion',
        osId NVARCHAR(4000) '$.os.id',
        osVersion NVARCHAR(4000) '$.os.version',
        osName NVARCHAR(4000) '$.os.name',
        kernel NVARCHAR(4000) '$.kernel',
        desktop NVARCHAR(4000) '$.desktop',
        xrdpVersion NVARCHAR(4000) '$.xrdp.version',
        xrdpActive NVARCHAR(4000) '$.xrdp.active',
        nfsReachable NVARCHAR(4000) '$.nfs.reachable',
        nfsMounts NVARCHAR(4000) '$.nfs.mounts',
        loadAverage NVARCHAR(4000) '$.loadAverage',
        cpuCount NVARCHAR(4000) '$.cpuCount',
        memoryAvailableMb NVARCHAR(4000) '$.memoryAvailableMb',
        memoryTotalMb NVARCHAR(4000) '$.memoryTotalMb',
        rootDiskFreePct NVARCHAR(4000) '$.rootDiskFreePct',
        uptimeSeconds NVARCHAR(4000) '$.uptimeSeconds',
        sessions NVARCHAR(MAX) '$.sessions' AS JSON
    );

    IF @ScriptVersionsJson IS NOT NULL AND (LEN(@ScriptVersionsJson) > 2000 OR ISJSON(@ScriptVersionsJson) <> 1)
        SET @ScriptVersionsJson = NULL;
    IF @SessionsJson IS NOT NULL AND ISJSON(@SessionsJson) <> 1
        SET @SessionsJson = NULL;
    IF @SettingsVersion < 0 SET @SettingsVersion = NULL;
    IF @NfsMountCount < 0 SET @NfsMountCount = NULL;
    IF @LoadAverage < 0 SET @LoadAverage = NULL;
    IF @CpuCount < 0 SET @CpuCount = NULL;
    IF @MemoryAvailableMb < 0 SET @MemoryAvailableMb = NULL;
    IF @MemoryTotalMb < 0 SET @MemoryTotalMb = NULL;
    IF @RootDiskFreePct < 0 OR @RootDiskFreePct > 100 SET @RootDiskFreePct = NULL;
    IF @UptimeSeconds < 0 SET @UptimeSeconds = NULL;

    SET @SessionCount = CASE
        WHEN @SessionsJson IS NULL THEN NULL
        ELSE (SELECT COUNT(*) FROM OPENJSON(@SessionsJson))
    END;

    UPDATE dbo.HostHeartbeats WITH (UPDLOCK, SERIALIZABLE)
    SET ReceivedAt = @Now,
        AgentVersion = @AgentVersion,
        ScriptVersionsJson = @ScriptVersionsJson,
        SettingsVersion = @SettingsVersion,
        OsId = @OsId,
        OsVersion = @OsVersion,
        OsName = @OsName,
        KernelVersion = @KernelVersion,
        Desktop = @Desktop,
        XrdpVersion = @XrdpVersion,
        XrdpActive = @XrdpActive,
        NfsReachable = @NfsReachable,
        NfsMountCount = @NfsMountCount,
        LoadAverage = @LoadAverage,
        CpuCount = @CpuCount,
        MemoryAvailableMb = @MemoryAvailableMb,
        MemoryTotalMb = @MemoryTotalMb,
        RootDiskFreePct = @RootDiskFreePct,
        UptimeSeconds = @UptimeSeconds,
        SessionCount = @SessionCount,
        SessionsJson = @SessionsJson
    WHERE Hostname = @RegisteredHostname;

    IF @@ROWCOUNT = 0
    BEGIN
        INSERT INTO dbo.HostHeartbeats (
            Hostname, ReceivedAt, AgentVersion, ScriptVersionsJson, SettingsVersion, OsId, OsVersion, OsName,
            KernelVersion, Desktop, XrdpVersion, XrdpActive, NfsReachable, NfsMountCount, LoadAverage, CpuCount,
            MemoryAvailableMb, MemoryTotalMb, RootDiskFreePct, UptimeSeconds, SessionCount, SessionsJson
        )
        VALUES (
            @RegisteredHostname, @Now, @AgentVersion, @ScriptVersionsJson, @SettingsVersion, @OsId, @OsVersion, @OsName,
            @KernelVersion, @Desktop, @XrdpVersion, @XrdpActive, @NfsReachable, @NfsMountCount, @LoadAverage, @CpuCount,
            @MemoryAvailableMb, @MemoryTotalMb, @RootDiskFreePct, @UptimeSeconds, @SessionCount, @SessionsJson
        );
    END

    IF @SettingsVersion > 0
    BEGIN
        UPDATE dbo.VirtualMachines
        SET SettingsVersion = @SettingsVersion,
            SettingsAppliedDate = GETDATE()
        WHERE Hostname = @RegisteredHostname
          AND (SettingsVersion IS NULL OR SettingsVersion <> @SettingsVersion);
    END

    SELECT CAST('Recorded' AS VARCHAR(16)) AS Result,
           @RegisteredHostname AS Hostname,
           CONVERT(VARCHAR(33), @Now, 126) + 'Z' AS ReceivedAtUtc;
END
GO
