-- The hosts of a maintenance run and how far each has got:
--
--   Pending      waiting to be admitted.
--   Draining     admitted: out of rotation, waiting for its user to leave (or be signed out).
--   Starting     powered off before the run, so started for patching.
--   Patching     patch-host.sh is running on it.
--   Restarting   the Azure restart is being requested.
--   Verifying    waiting for it to come back reachable, with a heartbeat from after the
--                restart and xrdp active.
--   Succeeded, Failed, Skipped (not patched: returned to service by an operator, powered off
--   and not included, or no longer registered) and Cancelled are final.
--
-- Every step is recorded when it is requested (ActionRequestedAt, Attempts) and again when its
-- effect is observed (PatchStartedAt, PatchFinishedAt, VerifiedAt), so a scheduled advance that
-- dies part way is picked up by the next one. Version makes each change a compare-and-set.
-- WasDrained, WasMaintenance and WasPoweredOff record the host before the run, so it is left
-- the way it was found. Times are UTC.

IF OBJECT_ID('dbo.MaintenanceRunHosts', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.MaintenanceRunHosts (
        RunHostID INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_MaintenanceRunHosts PRIMARY KEY,
        RunID INT NOT NULL CONSTRAINT FK_MaintenanceRunHosts_Run REFERENCES dbo.MaintenanceRuns (RunID),
        VMID INT NOT NULL,
        Hostname VARCHAR(255) NOT NULL,
        Position INT NOT NULL,
        State VARCHAR(16) NOT NULL CONSTRAINT DF_MaintenanceRunHosts_State DEFAULT ('Pending'),
        Version INT NOT NULL CONSTRAINT DF_MaintenanceRunHosts_Version DEFAULT (0),
        Attempts INT NOT NULL CONSTRAINT DF_MaintenanceRunHosts_Attempts DEFAULT (0),
        StepStartedAt DATETIME2(3) NULL,
        ActionRequestedAt DATETIME2(3) NULL,
        AdmittedAt DATETIME2(3) NULL,
        WarningSentAt DATETIME2(3) NULL,
        SignOutRequestedAt DATETIME2(3) NULL,
        PatchToken VARCHAR(64) NULL,
        PatchStartedAt DATETIME2(3) NULL,
        PatchFinishedAt DATETIME2(3) NULL,
        RestartRequestedAt DATETIME2(3) NULL,
        VerifiedAt DATETIME2(3) NULL,
        CompletedAt DATETIME2(3) NULL,
        WasDrained BIT NOT NULL CONSTRAINT DF_MaintenanceRunHosts_WasDrained DEFAULT (0),
        WasMaintenance BIT NOT NULL CONSTRAINT DF_MaintenanceRunHosts_WasMaintenance DEFAULT (0),
        WasPoweredOff BIT NOT NULL CONSTRAINT DF_MaintenanceRunHosts_WasPoweredOff DEFAULT (0),
        RebootRequired VARCHAR(8) NULL,
        Detail NVARCHAR(400) NULL,
        UpdatedAt DATETIME2(3) NOT NULL CONSTRAINT DF_MaintenanceRunHosts_UpdatedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT UQ_MaintenanceRunHosts_RunVm UNIQUE (RunID, VMID),
        CONSTRAINT CK_MaintenanceRunHosts_State CHECK (State IN ('Pending', 'Draining', 'Starting', 'Patching', 'Restarting',
            'Verifying', 'Succeeded', 'Failed', 'Skipped', 'Cancelled')),
        CONSTRAINT CK_MaintenanceRunHosts_Attempts CHECK (Attempts >= 0),
        CONSTRAINT CK_MaintenanceRunHosts_RebootRequired CHECK (RebootRequired IS NULL OR RebootRequired IN ('yes', 'no', 'unknown'))
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_MaintenanceRunHosts_Vm' AND object_id = OBJECT_ID('dbo.MaintenanceRunHosts'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_MaintenanceRunHosts_Vm
    ON dbo.MaintenanceRunHosts (VMID, State)
    INCLUDE (RunID);
END;
GO
