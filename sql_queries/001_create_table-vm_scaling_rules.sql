USE linuxbroker;

CREATE TABLE VmScalingRules (
    RuleID INT IDENTITY(1,1) PRIMARY KEY,
    MinVMs INT NOT NULL,
    MaxVMs INT NOT NULL,
    ScaleUpRatio DECIMAL(5,2) NOT NULL, -- Percentage (e.g., 70.00 for 70%)
    ScaleUpIncrement INT NOT NULL,
    ScaleDownRatio DECIMAL(5,2) NOT NULL, -- Percentage (e.g., 30.00 for 30%)
    ScaleDownIncrement INT NOT NULL,
    LastChecked DATETIME DEFAULT NULL,
    SysStartTime DATETIME2 GENERATED ALWAYS AS ROW START HIDDEN,
    SysEndTime DATETIME2 GENERATED ALWAYS AS ROW END HIDDEN,
    PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime),
    CHECK (MinVMs < MaxVMs),  -- Ensures MinVMs is less than MaxVMs
    CHECK (ScaleUpRatio > ScaleDownRatio)  -- Ensures ScaleUpRatio is greater than ScaleDownRatio
)

WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.VmScalingRulesHistory));


INSERT INTO VMScalingRules (MinVMs, MaxVMs, ScaleUpRatio, ScaleUpIncrement, ScaleDownRatio, ScaleDownIncrement)
VALUES (2, 10, 70.00, 2, 30.00, 1);
