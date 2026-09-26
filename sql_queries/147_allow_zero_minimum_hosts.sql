-- A pool may scale to zero while start on demand is on (4.1): the first user to arrive waits
-- for a host to start instead of being refused. The scaling rule and schedule windows accept a
-- minimum of 0; the API and dbo.SaveScalingSchedule allow it only while start on demand is on,
-- and scaling reads 0 as 1 whenever start on demand is off. A window's maximum must still be
-- above its minimum, so it is at least 1; the API checks the same for the rule.

IF EXISTS (
    SELECT 1 FROM sys.check_constraints
    WHERE name = 'CK_VmScalingRules_MinVMs'
      AND parent_object_id = OBJECT_ID('dbo.VmScalingRules')
      AND definition LIKE N'%>=(1)%'
)
BEGIN
    ALTER TABLE dbo.VmScalingRules DROP CONSTRAINT CK_VmScalingRules_MinVMs;
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.check_constraints
    WHERE name = 'CK_VmScalingRules_MinVMs' AND parent_object_id = OBJECT_ID('dbo.VmScalingRules')
)
BEGIN
    ALTER TABLE dbo.VmScalingRules WITH NOCHECK
    ADD CONSTRAINT CK_VmScalingRules_MinVMs CHECK (MinVMs >= 0);
END;
GO

IF EXISTS (
    SELECT 1 FROM sys.check_constraints
    WHERE name = 'CK_ScalingSchedules_MinMax'
      AND parent_object_id = OBJECT_ID('dbo.ScalingSchedules')
      AND definition LIKE N'%>=(1)%'
)
BEGIN
    ALTER TABLE dbo.ScalingSchedules DROP CONSTRAINT CK_ScalingSchedules_MinMax;
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.check_constraints
    WHERE name = 'CK_ScalingSchedules_MinMax' AND parent_object_id = OBJECT_ID('dbo.ScalingSchedules')
)
BEGIN
    ALTER TABLE dbo.ScalingSchedules WITH CHECK
    ADD CONSTRAINT CK_ScalingSchedules_MinMax CHECK (MinVMs >= 0 AND MaxVMs > MinVMs);
END;
GO
