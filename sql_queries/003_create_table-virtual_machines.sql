USE linuxbroker;

CREATE TABLE VirtualMachines (
    VMID INT IDENTITY(1,1) PRIMARY KEY,
    Hostname VARCHAR(255) NOT NULL,
    IPAddress VARCHAR(50),
    PowerState VARCHAR(10) CHECK(PowerState IN ('On', 'Off')),
    NetworkStatus VARCHAR(16) CHECK(NetworkStatus IN ('Reachable', 'Unreachable')),
    VmStatus VARCHAR(16) CHECK(VmStatus IN ('Available', 'CheckedOut', 'Maintenance', 'Released')),
    Username VARCHAR(255),
    AvdHost VARCHAR(255),
    CreateDate DATETIME DEFAULT(GETDATE()),
    LastUpdateDate DATETIME DEFAULT(GETDATE()),
    Description NVARCHAR(MAX), -- Changed from TEXT to NVARCHAR(MAX)
    SysStartTime DATETIME2 GENERATED ALWAYS AS ROW START HIDDEN,
    SysEndTime DATETIME2 GENERATED ALWAYS AS ROW END HIDDEN,
    PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.VirtualMachinesHistory));
