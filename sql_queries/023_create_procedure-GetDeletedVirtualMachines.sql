CREATE PROCEDURE GetDeletedVirtualMachines
AS
BEGIN
    -- Common table expression (CTE) to get the most recent entry per VMID
    WITH HistoryLastEntry AS (
        SELECT 
            h.VMID,
            h.Hostname,
            h.IPAddress,
            h.PowerState,
            h.NetworkStatus,
            h.VmStatus,
            h.Username,
            h.AvdHost,
            h.CreateDate,
            h.LastUpdateDate,
            h.Description,
            h.SysStartTime,
            h.SysEndTime,
            ROW_NUMBER() OVER (PARTITION BY h.VMID ORDER BY h.SysEndTime DESC) AS RowNum
        FROM 
            dbo.VirtualMachinesHistory h
        LEFT JOIN 
            dbo.VirtualMachines v
        ON 
            h.VMID = v.VMID
        WHERE 
            v.VMID IS NULL -- Only get records that were deleted
    )
    
    -- Select the most recent deletion entry for each VMID
    SELECT 
        VMID,
        Hostname,
        IPAddress,
        PowerState,
        NetworkStatus,
        VmStatus,
        Username,
        AvdHost,
        CreateDate,
        LastUpdateDate,
        Description,
        SysStartTime,
        SysEndTime AS DeletionTime
    FROM 
        HistoryLastEntry
    WHERE 
        RowNum = 1; -- Only get the most recent entry per VMID
END;
