CREATE PROCEDURE [dbo].[ReturnReleasedVms]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CurrentTime DATETIME = GETDATE();
    DECLARE @Grace INT = 1200;
    DECLARE @Reconcile INT = 60;
    DECLARE @Threshold INT;

    SELECT TOP 1
        @Grace = GracePeriodSeconds,
        @Reconcile = ReconcileIntervalSeconds
    FROM dbo.LinuxHostSettings
    WHERE SettingsScope = 'Global'
    ORDER BY SettingsID;

    SET @Threshold = @Grace + @Reconcile + 60;

    DECLARE @ReturnedVMs TABLE (
        VMID INT,
        Hostname VARCHAR(255),
        IPAddress VARCHAR(50),
        PowerState VARCHAR(10),
        NetworkStatus VARCHAR(16),
        VmStatus VARCHAR(16),
        LastUpdateDate DATETIME,
        ReturnedUsername VARCHAR(255),
        ReturnedAvdHost VARCHAR(255),
        ReturnedLeaseId UNIQUEIDENTIFIER,
        CleanupPending BIT,
        ResultType VARCHAR(16)
    );

    UPDATE dbo.VirtualMachines
    SET VmStatus = 'Available',
        Username = NULL,
        AvdHost = NULL,
        LeaseId = NULL,
        ReleasedDate = NULL,
        CleanupPending = CASE WHEN Username IS NOT NULL THEN 1 ELSE CleanupPending END,
        CleanupUsername = CASE WHEN Username IS NOT NULL THEN Username ELSE CleanupUsername END,
        CleanupLeaseId = CASE WHEN Username IS NOT NULL THEN LeaseId ELSE CleanupLeaseId END,
        CleanupAttemptDate = CASE WHEN Username IS NOT NULL THEN @CurrentTime ELSE CleanupAttemptDate END,
        LastUpdateDate = @CurrentTime
    OUTPUT INSERTED.VMID,
           INSERTED.Hostname,
           INSERTED.IPAddress,
           INSERTED.PowerState,
           INSERTED.NetworkStatus,
           INSERTED.VmStatus,
           INSERTED.LastUpdateDate,
           DELETED.Username,
           DELETED.AvdHost,
           DELETED.LeaseId,
           INSERTED.CleanupPending,
           'Expired'
    INTO @ReturnedVMs (
        VMID, Hostname, IPAddress, PowerState, NetworkStatus, VmStatus, LastUpdateDate,
        ReturnedUsername, ReturnedAvdHost, ReturnedLeaseId, CleanupPending, ResultType
    )
    WHERE VmStatus = 'Released'
      AND DATEADD(SECOND, @Threshold, COALESCE(ReleasedDate, LastUpdateDate)) <= @CurrentTime;

    UPDATE dbo.VirtualMachines
    SET CleanupAttemptDate = @CurrentTime
    OUTPUT INSERTED.VMID,
           INSERTED.Hostname,
           INSERTED.IPAddress,
           INSERTED.PowerState,
           INSERTED.NetworkStatus,
           INSERTED.VmStatus,
           INSERTED.LastUpdateDate,
           INSERTED.CleanupUsername,
           NULL,
           INSERTED.CleanupLeaseId,
           INSERTED.CleanupPending,
           'Retry'
    INTO @ReturnedVMs (
        VMID, Hostname, IPAddress, PowerState, NetworkStatus, VmStatus, LastUpdateDate,
        ReturnedUsername, ReturnedAvdHost, ReturnedLeaseId, CleanupPending, ResultType
    )
    WHERE CleanupPending = 1
      AND PowerState = 'On'
      AND NetworkStatus = 'Reachable'
      AND (CleanupAttemptDate IS NULL OR CleanupAttemptDate <= DATEADD(SECOND, -120, @CurrentTime))
      AND NOT EXISTS (SELECT 1 FROM @ReturnedVMs r WHERE r.VMID = dbo.VirtualMachines.VMID);

    SELECT VMID, Hostname, IPAddress, PowerState, NetworkStatus, VmStatus, LastUpdateDate,
           ReturnedUsername, ReturnedAvdHost, ReturnedLeaseId, CleanupPending, ResultType
    FROM @ReturnedVMs
    ORDER BY VMID, ResultType;
END
GO
