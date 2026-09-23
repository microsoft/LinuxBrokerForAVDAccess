CREATE OR ALTER VIEW dbo.BrokerVmInventory
AS
    SELECT v.VMID, v.Hostname, v.IPAddress, v.PowerState, v.NetworkStatus, v.VmStatus,
        v.Username, v.AvdHost, v.LeaseId, v.LeaseGeneration, v.OwnerTenantId, v.OwnerObjectId,
        v.DisconnectedAt, v.SessionState, v.CreateDate, v.LastUpdateDate, v.Description,
        v.SettingsVersion, v.SettingsAppliedDate, v.OperationId, o.Kind AS OperationKind,
        o.State AS OperationState, o.ErrorCode AS OperationError, o.StartedAt AS OperationStartedAt
    FROM dbo.VirtualMachines v LEFT JOIN dbo.BrokerLeaseOperations o ON o.OperationId = v.OperationId;
GO

CREATE OR ALTER PROCEDURE dbo.GetVms
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM dbo.BrokerVmInventory ORDER BY Hostname;
END;
GO

CREATE OR ALTER PROCEDURE dbo.GetVmHistoryPaged
    @StartDate NVARCHAR(10) = NULL, @EndDate NVARCHAR(10) = NULL, @Offset INT = 0, @PageSize INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Start DATETIME2 = TRY_CONVERT(DATETIME2, NULLIF(LTRIM(RTRIM(@StartDate)), ''), 101),
            @End DATETIME2 = TRY_CONVERT(DATETIME2, NULLIF(LTRIM(RTRIM(@EndDate)), ''), 101),
            @SafeOffset INT = CASE WHEN @Offset IS NULL OR @Offset < 0 THEN 0 ELSE @Offset END,
            @SafeSize INT = CASE WHEN @PageSize IS NULL OR @PageSize < 1 OR @PageSize > 200 THEN 50 ELSE @PageSize END;
    SELECT VMID, Hostname, IPAddress, PowerState, NetworkStatus, VmStatus, Username, AvdHost,
        LeaseId, LeaseGeneration, OwnerTenantId, OwnerObjectId, DisconnectedAt, SessionState, OperationId,
        CreateDate, LastUpdateDate, Description, SysStartTime, SysEndTime, SettingsVersion, SettingsAppliedDate,
        COUNT(*) OVER () AS TotalCount
    FROM dbo.VirtualMachinesHistory
    WHERE (@Start IS NULL OR SysStartTime >= @Start) AND (@End IS NULL OR SysEndTime <= @End)
    ORDER BY SysStartTime DESC, SysEndTime DESC, VMID DESC
    OFFSET @SafeOffset ROWS FETCH NEXT @SafeSize ROWS ONLY;
END;
GO
CREATE OR ALTER PROCEDURE dbo.GetVmDetails @VMID INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM dbo.BrokerVmInventory WHERE VMID = @VMID;
END;
GO
CREATE OR ALTER PROCEDURE dbo.GetVmSummary
AS
BEGIN
    SET NOCOUNT ON;
    SELECT COUNT(*) AS TotalVMs,
        COALESCE(SUM(CASE WHEN v.VmStatus = 'Available' THEN 1 ELSE 0 END), 0) AS Available,
        COALESCE(SUM(CASE WHEN v.VmStatus = 'CheckedOut' THEN 1 ELSE 0 END), 0) AS CheckedOut,
        COALESCE(SUM(CASE WHEN v.VmStatus = 'Maintenance' THEN 1 ELSE 0 END), 0) AS Maintenance,
        COALESCE(SUM(CASE WHEN v.VmStatus = 'Released' THEN 1 ELSE 0 END), 0) AS Released,
        COALESCE(SUM(CASE WHEN v.PowerState = 'On' THEN 1 ELSE 0 END), 0) AS PoweredOn,
        COALESCE(SUM(CASE WHEN v.PowerState = 'Off' THEN 1 ELSE 0 END), 0) AS PoweredOff,
        COALESCE(SUM(CASE WHEN v.NetworkStatus = 'Unreachable' THEN 1 ELSE 0 END), 0) AS Unreachable,
        COALESCE(SUM(CASE WHEN v.VmStatus = 'Available' AND v.PowerState = 'On' AND v.NetworkStatus = 'Reachable'
            AND v.Username IS NULL AND v.LeaseId IS NULL AND v.OwnerTenantId IS NULL
            AND v.OwnerObjectId IS NULL AND v.OperationId IS NULL AND h.Hostname IS NOT NULL
            AND v.LeaseGeneration < 9007199254740991 AND COALESCE(g.Generation, 0) < 9007199254740991 THEN 1 ELSE 0 END), 0) AS Ready
    FROM dbo.VirtualMachines v LEFT JOIN dbo.BrokerHosts h ON h.Hostname = v.Hostname AND h.Active = 1
    LEFT JOIN dbo.BrokerHostGenerations g ON g.Hostname = v.Hostname;
END;
GO
