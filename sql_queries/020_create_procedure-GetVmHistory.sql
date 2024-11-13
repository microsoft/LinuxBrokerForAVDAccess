CREATE PROCEDURE GetVmHistory
    @StartDate NVARCHAR(10) = NULL,  -- Changed to NVARCHAR for date string input
    @EndDate NVARCHAR(10) = NULL,    -- Changed to NVARCHAR for date string input
    @Limit INT = 100
AS
BEGIN
    -- Convert the input strings to DATETIME2, assuming mm/dd/yyyy format
    DECLARE @ConvertedStartDate DATETIME2 = NULL, @ConvertedEndDate DATETIME2 = NULL;
    
    IF @StartDate IS NOT NULL
        SET @ConvertedStartDate = CONVERT(DATETIME2, @StartDate, 101); -- 101 = mm/dd/yyyy
    
    IF @EndDate IS NOT NULL
        SET @ConvertedEndDate = CONVERT(DATETIME2, @EndDate, 101); -- 101 = mm/dd/yyyy
    
    SELECT * 
    FROM dbo.VirtualMachinesHistory 
    WHERE (@ConvertedStartDate IS NULL OR SysStartTime >= @ConvertedStartDate)
      AND (@ConvertedEndDate IS NULL OR SysEndTime <= @ConvertedEndDate)
    ORDER BY SysStartTime DESC 
    OFFSET 0 ROWS 
    FETCH NEXT ISNULL(@Limit, 100) ROWS ONLY;
END;
