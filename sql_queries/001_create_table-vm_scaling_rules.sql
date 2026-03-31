USE linuxbroker;

IF OBJECT_ID('dbo.VmScalingRules', 'U') IS NULL
BEGIN
    CREATE TABLE VmScalingRules (
        RuleID INT IDENTITY(1,1) PRIMARY KEY,
        MinVMs INT NOT NULL,
        MaxVMs INT NOT NULL,
        ScaleUpRatio DECIMAL(5,2) NOT NULL,
        ScaleUpIncrement INT NOT NULL,
        ScaleDownRatio DECIMAL(5,2) NOT NULL,
        ScaleDownIncrement INT NOT NULL,
        LastChecked DATETIME DEFAULT NULL,
        SysStartTime DATETIME2 GENERATED ALWAYS AS ROW START HIDDEN,
        SysEndTime DATETIME2 GENERATED ALWAYS AS ROW END HIDDEN,
        PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime),
        CHECK (MinVMs < MaxVMs),
        CHECK (ScaleUpRatio > ScaleDownRatio)
    )
    WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.VmScalingRulesHistory));
END;

IF NOT EXISTS (SELECT 1 FROM dbo.VmScalingRules)
BEGIN
    INSERT INTO dbo.VmScalingRules (MinVMs, MaxVMs, ScaleUpRatio, ScaleUpIncrement, ScaleDownRatio, ScaleDownIncrement)
    VALUES (2, 10, 70.00, 2, 30.00, 1);
END;
