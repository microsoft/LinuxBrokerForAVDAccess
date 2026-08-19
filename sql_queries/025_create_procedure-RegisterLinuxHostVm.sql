CREATE PROCEDURE [dbo].[RegisterLinuxHostVm]
    @Hostname NVARCHAR(255),
    @IPAddress NVARCHAR(50),
    @Description NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ExistingVmId INT;

    -- Hostname is unique once 027 has applied. TOP 1 keeps this deterministic on older
    -- databases that still carry duplicates, and the UPDATE below refreshes every match
    -- so no duplicate row is left holding a stale address.
    SELECT TOP 1 @ExistingVmId = VMID
    FROM dbo.VirtualMachines
    WHERE Hostname = @Hostname
    ORDER BY VMID;

    IF @ExistingVmId IS NULL
    BEGIN
        INSERT INTO dbo.VirtualMachines (
            Hostname,
            IPAddress,
            PowerState,
            NetworkStatus,
            VmStatus,
            Username,
            AvdHost,
            CreateDate,
            LastUpdateDate,
            Description
        )
        VALUES (
            @Hostname,
            @IPAddress,
            'On',
            'Reachable',
            'Available',
            NULL,
            NULL,
            GETDATE(),
            GETDATE(),
            @Description
        );

        SELECT CAST(SCOPE_IDENTITY() AS INT) AS VMID, 'Inserted' AS RegistrationAction;
        RETURN;
    END;

    UPDATE dbo.VirtualMachines
    SET IPAddress = @IPAddress,
        Description = COALESCE(@Description, Description),
        LastUpdateDate = GETDATE()
    WHERE Hostname = @Hostname;

    SELECT @ExistingVmId AS VMID, 'Updated' AS RegistrationAction;
END
GO
