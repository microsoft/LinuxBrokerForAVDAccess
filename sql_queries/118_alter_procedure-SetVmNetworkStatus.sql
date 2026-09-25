-- Redefines dbo.SetVmNetworkStatus to measure host starts. When a host with a
-- StartRequestedAt stamp becomes reachable, the time since the request is recorded in
-- dbo.HostStartEvents and the stamp is cleared.
-- * A host reported reachable within @MinimumStartSeconds of a restart request had not gone
--   down yet, so the stamp is kept for the moment it comes back.
-- * A stamp older than two hours no longer measures a start (the host was stopped, or started
--   outside the broker), so it is cleared without recording anything.
-- The result columns are unchanged from 048.

CREATE PROCEDURE [dbo].[SetVmNetworkStatus]
    @VMID INT,
    @NetworkStatus VARCHAR(16)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @NowUtc DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @MinimumStartSeconds INT = 20;
    DECLARE @Changed TABLE (
        VMID INT,
        Hostname VARCHAR(255),
        PowerState VARCHAR(10),
        NetworkStatus VARCHAR(16),
        Changed BIT,
        StartRequestedAt DATETIME2(3)
    );

    UPDATE dbo.VirtualMachines
    SET NetworkStatus = @NetworkStatus,
        StartRequestedAt = CASE
            WHEN @NetworkStatus = 'Reachable' AND StartRequestedAt <= DATEADD(SECOND, -@MinimumStartSeconds, @NowUtc) THEN NULL
            ELSE StartRequestedAt
        END,
        LastUpdateDate = GETDATE()
    OUTPUT INSERTED.VMID, INSERTED.Hostname, INSERTED.PowerState, INSERTED.NetworkStatus, CAST(1 AS BIT), DELETED.StartRequestedAt
    INTO @Changed
    WHERE VMID = @VMID
      AND NetworkStatus <> @NetworkStatus;

    INSERT INTO dbo.HostStartEvents (VMID, Hostname, RequestedAt, ReadyAt, Seconds)
    SELECT VMID, Hostname, StartRequestedAt, @NowUtc, DATEDIFF(SECOND, StartRequestedAt, @NowUtc)
    FROM @Changed
    WHERE NetworkStatus = 'Reachable'
      AND PowerState = 'On'
      AND StartRequestedAt <= DATEADD(SECOND, -@MinimumStartSeconds, @NowUtc)
      AND StartRequestedAt >= DATEADD(HOUR, -2, @NowUtc);

    IF NOT EXISTS (SELECT 1 FROM @Changed)
    BEGIN
        INSERT INTO @Changed (VMID, Hostname, PowerState, NetworkStatus, Changed, StartRequestedAt)
        SELECT VMID, Hostname, PowerState, NetworkStatus, CAST(0 AS BIT), NULL
        FROM dbo.VirtualMachines
        WHERE VMID = @VMID;
    END

    SELECT VMID, Hostname, PowerState, NetworkStatus, Changed
    FROM @Changed;
END
GO