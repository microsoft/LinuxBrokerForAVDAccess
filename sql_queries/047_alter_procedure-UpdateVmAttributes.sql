CREATE PROCEDURE [dbo].[UpdateVmAttributes]
    @VMID INT,
    @PowerState VARCHAR(10) = NULL,
    @NetworkStatus VARCHAR(16) = NULL,
    @VmStatus VARCHAR(16) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;

    DECLARE @OldPowerState VARCHAR(10);
    DECLARE @OldNetworkStatus VARCHAR(16);
    DECLARE @OldVmStatus VARCHAR(16);
    DECLARE @OldUsername VARCHAR(255);
    DECLARE @OldLeaseId UNIQUEIDENTIFIER;

    SELECT @OldPowerState = PowerState,
           @OldNetworkStatus = NetworkStatus,
           @OldVmStatus = VmStatus,
           @OldUsername = Username,
           @OldLeaseId = LeaseId
    FROM dbo.VirtualMachines WITH (UPDLOCK, HOLDLOCK, ROWLOCK)
    WHERE VMID = @VMID;

    IF @OldPowerState IS NOT NULL
       AND (
              (@PowerState IS NOT NULL AND @PowerState <> @OldPowerState)
           OR (@NetworkStatus IS NOT NULL AND @NetworkStatus <> @OldNetworkStatus)
           OR (@VmStatus IS NOT NULL AND @VmStatus <> @OldVmStatus)
       )
    BEGIN
        UPDATE dbo.VirtualMachines
        SET PowerState = COALESCE(@PowerState, PowerState),
            NetworkStatus = COALESCE(@NetworkStatus, NetworkStatus),
            VmStatus = COALESCE(@VmStatus, VmStatus),
            Username = CASE WHEN @VmStatus IN ('Available', 'Maintenance') AND @OldVmStatus IN ('CheckedOut', 'Released') THEN NULL ELSE Username END,
            AvdHost = CASE WHEN @VmStatus IN ('Available', 'Maintenance') AND @OldVmStatus IN ('CheckedOut', 'Released') THEN NULL ELSE AvdHost END,
            LeaseId = CASE WHEN @VmStatus IN ('Available', 'Maintenance') AND @OldVmStatus IN ('CheckedOut', 'Released') THEN NULL ELSE LeaseId END,
            ReleasedDate = CASE
                WHEN @VmStatus = 'Released' AND @OldVmStatus <> 'Released' THEN GETDATE()
                WHEN @VmStatus IS NOT NULL AND @VmStatus <> 'Released' THEN NULL
                ELSE ReleasedDate
            END,
            CleanupPending = CASE WHEN @VmStatus IN ('Available', 'Maintenance') AND @OldVmStatus IN ('CheckedOut', 'Released') AND @OldUsername IS NOT NULL THEN 1 ELSE CleanupPending END,
            CleanupUsername = CASE WHEN @VmStatus IN ('Available', 'Maintenance') AND @OldVmStatus IN ('CheckedOut', 'Released') AND @OldUsername IS NOT NULL THEN @OldUsername ELSE CleanupUsername END,
            CleanupLeaseId = CASE WHEN @VmStatus IN ('Available', 'Maintenance') AND @OldVmStatus IN ('CheckedOut', 'Released') AND @OldUsername IS NOT NULL THEN @OldLeaseId ELSE CleanupLeaseId END,
            CleanupAttemptDate = CASE WHEN @VmStatus IN ('Available', 'Maintenance') AND @OldVmStatus IN ('CheckedOut', 'Released') AND @OldUsername IS NOT NULL THEN NULL ELSE CleanupAttemptDate END,
            PowerStateChangedDate = CASE WHEN @PowerState IS NOT NULL AND @PowerState <> @OldPowerState THEN GETDATE() ELSE PowerStateChangedDate END,
            LastUpdateDate = GETDATE()
        WHERE VMID = @VMID;
    END

    SELECT VMID, Hostname, IPAddress, PowerState, NetworkStatus, VmStatus, LastUpdateDate
    FROM dbo.VirtualMachines
    WHERE VMID = @VMID;

    COMMIT TRANSACTION;
END
GO
