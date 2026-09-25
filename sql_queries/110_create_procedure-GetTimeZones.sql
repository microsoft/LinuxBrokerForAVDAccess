-- The time zones the scaling policy can use, with their current offset from UTC.

CREATE PROCEDURE [dbo].[GetTimeZones]
AS
BEGIN
    SET NOCOUNT ON;

    SELECT name AS Name, current_utc_offset AS CurrentUtcOffset, is_currently_dst AS IsCurrentlyDst
    FROM sys.time_zone_info
    ORDER BY
        CAST(LEFT(current_utc_offset, 1) + '1' AS INT)
            * (CAST(SUBSTRING(current_utc_offset, 2, 2) AS INT) * 60 + CAST(SUBSTRING(current_utc_offset, 5, 2) AS INT)),
        name;
END
GO
