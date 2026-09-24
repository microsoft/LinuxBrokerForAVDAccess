-- Append-only record of who changed what, read by the portal's Audit page.
--
-- The Broker API writes one row for every call a portal user or an administrator principal
-- makes to a mutating route, for every authorization denial on a mutating route, and for the
-- state changes the broker makes on its own: scaling power actions, power states corrected
-- from Azure, expired releases, and completed cleanups and drains. High-volume agent traffic
-- (AVD checkouts, Linux host releases, settings acknowledgements and heartbeats) is not
-- audited; the VirtualMachinesHistory temporal table already records its effect.
--
-- Rows are never updated, so the table is not system-versioned. dbo.PurgeAuditLog removes
-- entries older than the API's AUDIT_RETENTION_DAYS. OccurredAt is UTC.

IF OBJECT_ID('dbo.AuditLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AuditLog (
        AuditId BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AuditLog PRIMARY KEY,
        OccurredAt DATETIME2(3) NOT NULL CONSTRAINT DF_AuditLog_OccurredAt DEFAULT (SYSUTCDATETIME()),
        ActorOid VARCHAR(64) NULL,
        ActorName NVARCHAR(256) NULL,
        ActorType VARCHAR(16) NOT NULL,
        Action VARCHAR(64) NOT NULL,
        TargetType VARCHAR(32) NULL,
        TargetId NVARCHAR(256) NULL,
        Outcome VARCHAR(16) NOT NULL,
        DetailJson NVARCHAR(MAX) NULL,
        CorrelationId VARCHAR(64) NULL,
        CONSTRAINT CK_AuditLog_ActorType CHECK (ActorType IN ('user', 'service', 'system')),
        CONSTRAINT CK_AuditLog_Outcome CHECK (Outcome IN ('success', 'failure', 'denied')),
        CONSTRAINT CK_AuditLog_DetailJson CHECK (DetailJson IS NULL OR ISJSON(DetailJson) = 1)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_AuditLog_OccurredAt' AND object_id = OBJECT_ID('dbo.AuditLog'))
BEGIN
    CREATE INDEX IX_AuditLog_OccurredAt ON dbo.AuditLog (OccurredAt DESC, AuditId DESC);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_AuditLog_Action' AND object_id = OBJECT_ID('dbo.AuditLog'))
BEGIN
    CREATE INDEX IX_AuditLog_Action ON dbo.AuditLog (Action, OccurredAt DESC);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_AuditLog_Target' AND object_id = OBJECT_ID('dbo.AuditLog'))
BEGIN
    CREATE INDEX IX_AuditLog_Target ON dbo.AuditLog (TargetType, TargetId, OccurredAt DESC);
END;
GO
