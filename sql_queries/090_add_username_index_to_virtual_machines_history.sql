-- The user page lists the hosts a user had from the temporal history, which is otherwise
-- scanned in full for every lookup.

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_VirtualMachinesHistory_Username'
      AND object_id = OBJECT_ID('dbo.VirtualMachinesHistory')
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_VirtualMachinesHistory_Username
    ON dbo.VirtualMachinesHistory (Username, SysEndTime)
    INCLUDE (VMID, Hostname, LeaseId, SysStartTime);
END;
GO
