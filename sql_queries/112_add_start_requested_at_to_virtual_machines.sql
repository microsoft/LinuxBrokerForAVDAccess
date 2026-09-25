-- When a start or restart of the host was last requested, in UTC. Scaling and the host
-- actions stamp it, and dbo.SetVmNetworkStatus clears it when the host first becomes
-- reachable again, recording how long the start took. Stops and Azure power-state
-- corrections never stamp it, so only real starts are measured. ALTER TABLE propagates the
-- column to the history table.

IF COL_LENGTH('dbo.VirtualMachines', 'StartRequestedAt') IS NULL
BEGIN
    ALTER TABLE dbo.VirtualMachines
    ADD StartRequestedAt DATETIME2(3) NULL;
END;
GO
