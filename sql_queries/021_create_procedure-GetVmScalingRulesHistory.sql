CREATE PROCEDURE GetVmScalingRulesHistory
    @StartDate DATETIME2 = NULL,
    @EndDate DATETIME2 = NULL,
    @Limit INT = 100
AS
BEGIN
    SELECT * 
    FROM dbo.VmScalingRulesHistory 
    WHERE (@StartDate IS NULL OR SysStartTime >= @StartDate)
      AND (@EndDate IS NULL OR SysEndTime <= @EndDate)
    ORDER BY SysStartTime DESC 
    OFFSET 0 ROWS 
    FETCH NEXT ISNULL(@Limit, 100) ROWS ONLY;
END;
