-- Start on demand (4.1). When a checkout finds no ready host, the broker may start a stopped
-- one for the user, whose AVD host waits for it instead of being turned away.
--   StartOnDemandEnabled  On unless an administrator turns it off. While it is off, a checkout
--                         that finds no host is refused as before, and a scaling minimum of 0
--                         is read as 1.
--   MaxPendingStarts      At most this many hosts may be starting for waiting users at once
--                         (1-20). A user who arrives while that many are starting waits for
--                         one of them.

IF COL_LENGTH('dbo.ScalingPolicy', 'StartOnDemandEnabled') IS NULL
BEGIN
    ALTER TABLE dbo.ScalingPolicy
    ADD StartOnDemandEnabled BIT NOT NULL
        CONSTRAINT DF_ScalingPolicy_StartOnDemandEnabled DEFAULT (1);
END;
GO

IF COL_LENGTH('dbo.ScalingPolicy', 'MaxPendingStarts') IS NULL
BEGIN
    ALTER TABLE dbo.ScalingPolicy
    ADD MaxPendingStarts INT NOT NULL
        CONSTRAINT DF_ScalingPolicy_MaxPendingStarts DEFAULT (2);
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.check_constraints
    WHERE name = 'CK_ScalingPolicy_MaxPendingStarts' AND parent_object_id = OBJECT_ID('dbo.ScalingPolicy')
)
BEGIN
    ALTER TABLE dbo.ScalingPolicy WITH CHECK
    ADD CONSTRAINT CK_ScalingPolicy_MaxPendingStarts CHECK (MaxPendingStarts BETWEEN 1 AND 20);
END;
GO
