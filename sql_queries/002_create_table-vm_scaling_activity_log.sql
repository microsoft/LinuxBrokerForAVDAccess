use linuxbroker;

CREATE TABLE VmScalingActivityLog (
    ActivityID INT IDENTITY(1,1) PRIMARY KEY,
    CheckTimestamp DATETIME NOT NULL DEFAULT(GETDATE()),
    CurrentRunningVMs INT NOT NULL,
    CurrentInUseVMs INT NOT NULL,
    ActionTaken NVARCHAR(50) NOT NULL, -- "Scale Up", "Scale Down", "No Action"
    VMsPoweredOn INT NULL,
    VMsPoweredOff INT NULL,
    NewTotalVMs INT NOT NULL,
    Outcome NVARCHAR(255) NULL,
    Notes TEXT NULL
);
