-- Adds stop-mode metadata and write-time validation for scaling rules.

IF COL_LENGTH('dbo.VmScalingRules', 'StopMode') IS NULL
BEGIN
    ALTER TABLE dbo.VmScalingRules
    ADD StopMode VARCHAR(16) NULL;
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_VmScalingRules_StopMode' AND parent_object_id = OBJECT_ID('dbo.VmScalingRules'))
BEGIN
    ALTER TABLE dbo.VmScalingRules WITH CHECK
    ADD CONSTRAINT CK_VmScalingRules_StopMode CHECK (StopMode IS NULL OR StopMode IN ('PowerOff','Deallocate'));
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_VmScalingRules_MinVMs' AND parent_object_id = OBJECT_ID('dbo.VmScalingRules'))
BEGIN
    ALTER TABLE dbo.VmScalingRules WITH NOCHECK
    ADD CONSTRAINT CK_VmScalingRules_MinVMs CHECK (MinVMs >= 1);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_VmScalingRules_Increments' AND parent_object_id = OBJECT_ID('dbo.VmScalingRules'))
BEGIN
    ALTER TABLE dbo.VmScalingRules WITH NOCHECK
    ADD CONSTRAINT CK_VmScalingRules_Increments CHECK (ScaleUpIncrement >= 1 AND ScaleDownIncrement >= 1);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_VmScalingRules_Ratios' AND parent_object_id = OBJECT_ID('dbo.VmScalingRules'))
BEGIN
    ALTER TABLE dbo.VmScalingRules WITH NOCHECK
    ADD CONSTRAINT CK_VmScalingRules_Ratios CHECK (ScaleUpRatio BETWEEN 0 AND 100 AND ScaleDownRatio BETWEEN 0 AND 100);
END;
GO
