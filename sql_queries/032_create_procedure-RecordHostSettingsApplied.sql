-- Records the settings version a Linux host has actually applied.
--
-- Called by the host agent after it caches a fetched settings document, and by the API
-- after a successful push. Hostname is the natural key the rest of the broker resolves
-- against, matching ReleaseVm and RegisterLinuxHostVm.

CREATE PROCEDURE [dbo].[RecordHostSettingsApplied]
    @Hostname VARCHAR(255),
    @SettingsVersion INT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.VirtualMachines
    SET SettingsVersion = @SettingsVersion,
        SettingsAppliedDate = GETDATE()
    WHERE Hostname = @Hostname;

    SELECT
        VMID,
        Hostname,
        SettingsVersion,
        SettingsAppliedDate
    FROM dbo.VirtualMachines
    WHERE Hostname = @Hostname;
END
GO
