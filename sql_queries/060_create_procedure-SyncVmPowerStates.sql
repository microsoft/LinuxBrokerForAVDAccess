CREATE PROCEDURE [dbo].[SyncVmPowerStates]
    @PowerStatesJson NVARCHAR(MAX),
    @GraceSeconds INT = 120
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now DATETIME = GETDATE();
    DECLARE @Changed TABLE (VMID INT, Hostname VARCHAR(255), PreviousPowerState VARCHAR(10), PowerState VARCHAR(10));

    ;WITH Incoming AS (
        SELECT LOWER(LTRIM(RTRIM(hostname))) AS HostnameKey, powerState AS PowerState
        FROM OPENJSON(@PowerStatesJson)
        WITH (hostname VARCHAR(255) '$.hostname', powerState VARCHAR(10) '$.powerState')
        WHERE powerState IN ('On', 'Off') AND hostname IS NOT NULL
    ), Deduped AS (
        SELECT HostnameKey, MAX(PowerState) AS PowerState
        FROM Incoming
        GROUP BY HostnameKey
    )
    UPDATE vm
    SET PowerState = d.PowerState,
        NetworkStatus = CASE WHEN d.PowerState = 'Off' THEN 'Unreachable' ELSE NetworkStatus END,
        PowerStateChangedDate = @Now,
        LastUpdateDate = @Now
    OUTPUT INSERTED.VMID, INSERTED.Hostname, DELETED.PowerState, INSERTED.PowerState
    INTO @Changed
    FROM dbo.VirtualMachines vm
    INNER JOIN Deduped d ON LOWER(vm.Hostname) = d.HostnameKey
    WHERE vm.PowerState <> d.PowerState
      AND (vm.PowerStateChangedDate IS NULL OR vm.PowerStateChangedDate <= DATEADD(SECOND, -COALESCE(@GraceSeconds, 120), @Now));

    SELECT VMID, Hostname, PreviousPowerState, PowerState
    FROM @Changed
    ORDER BY Hostname;
END
GO
