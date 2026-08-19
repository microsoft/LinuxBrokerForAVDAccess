-- Track which settings version each Linux host has actually applied.
--
-- The host agent acknowledges its applied version on every reconcile run, so the portal can
-- show drift between the desired global profile and what is really running on each host.
-- dbo.VirtualMachines is system-versioned; ALTER TABLE ... ADD propagates to the history
-- table automatically, so no history maintenance is needed here.

IF COL_LENGTH('dbo.VirtualMachines', 'SettingsVersion') IS NULL
BEGIN
    ALTER TABLE dbo.VirtualMachines
    ADD SettingsVersion INT NULL;
END;
GO

IF COL_LENGTH('dbo.VirtualMachines', 'SettingsAppliedDate') IS NULL
BEGIN
    ALTER TABLE dbo.VirtualMachines
    ADD SettingsAppliedDate DATETIME NULL;
END;
GO
