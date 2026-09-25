-- How long each host start took, from the request to the first moment the reachability probe
-- reached it. dbo.SetVmNetworkStatus records one when a host with a StartRequestedAt stamp
-- becomes reachable. Scaling starts, manual starts and restarts stamp it; stops and Azure
-- power-state corrections do not, so they are never measured. Times are UTC. Removed with the
-- checkout events.

IF OBJECT_ID('dbo.HostStartEvents', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.HostStartEvents (
        EventID BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_HostStartEvents PRIMARY KEY,
        VMID INT NULL,
        Hostname VARCHAR(255) NOT NULL,
        RequestedAt DATETIME2(3) NOT NULL,
        ReadyAt DATETIME2(3) NOT NULL,
        Seconds INT NOT NULL,
        CONSTRAINT CK_HostStartEvents_Seconds CHECK (Seconds >= 0)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_HostStartEvents_ReadyAt' AND object_id = OBJECT_ID('dbo.HostStartEvents'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_HostStartEvents_ReadyAt
    ON dbo.HostStartEvents (ReadyAt)
    INCLUDE (Seconds);
END;
GO
