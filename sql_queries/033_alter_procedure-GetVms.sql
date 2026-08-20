-- Adds the settings tracking columns to the VM list.
--
-- This has to live in its own file rather than being folded into
-- 014_create_procedure-GetVms.sql, because that script runs before
-- 029_add_settings_tracking_to_virtual_machines.sql adds the columns. SQL Server validates
-- column references against existing tables at procedure creation time, so editing 014 in
-- place would break a fresh deployment.

CREATE PROCEDURE [dbo].[GetVms]
AS
BEGIN
    SELECT
        VMID,
        Hostname,
        IPAddress,
        PowerState,
        NetworkStatus,
        VmStatus,
        Username,
        AvdHost,
        LeaseId,
        CreateDate,
        LastUpdateDate,
        Description,
        SettingsVersion,
        SettingsAppliedDate
    FROM dbo.VirtualMachines
    ORDER BY Hostname;
END
GO
