-- Paged, filtered reader for the portal's Audit page, with an in-band TotalCount like the
-- other paged readers (037-039).
--
-- @From is inclusive and @To exclusive, both UTC. @Actor matches the actor's object id
-- exactly or any part of its name. @Action matches exactly, or as a prefix when it ends in a
-- dot ('vm.' matches every VM action). @TargetId matches any part of the target. CHARINDEX
-- and LEFT are used instead of LIKE so user input needs no wildcard escaping.

CREATE PROCEDURE [dbo].[GetAuditLogPaged]
    @From DATETIME2(3) = NULL,
    @To DATETIME2(3) = NULL,
    @Actor NVARCHAR(256) = NULL,
    @Action VARCHAR(64) = NULL,
    @TargetType VARCHAR(32) = NULL,
    @TargetId NVARCHAR(256) = NULL,
    @Outcome VARCHAR(16) = NULL,
    @Offset INT = 0,
    @PageSize INT = 50
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SafeOffset INT = CASE WHEN @Offset IS NULL OR @Offset < 0 THEN 0 ELSE @Offset END;
    DECLARE @SafePageSize INT = CASE
        WHEN @PageSize IS NULL OR @PageSize < 1 THEN 50
        WHEN @PageSize > 1000 THEN 1000
        ELSE @PageSize
    END;
    DECLARE @ActorFilter NVARCHAR(256) = NULLIF(LTRIM(RTRIM(@Actor)), N'');
    DECLARE @ActionFilter VARCHAR(64) = NULLIF(LTRIM(RTRIM(@Action)), '');
    DECLARE @TargetTypeFilter VARCHAR(32) = NULLIF(LTRIM(RTRIM(@TargetType)), '');
    DECLARE @TargetIdFilter NVARCHAR(256) = NULLIF(LTRIM(RTRIM(@TargetId)), N'');
    DECLARE @OutcomeFilter VARCHAR(16) = NULLIF(LTRIM(RTRIM(@Outcome)), '');

    WITH MatchingRows AS (
        SELECT
            AuditId,
            OccurredAt,
            ActorOid,
            ActorName,
            ActorType,
            Action,
            TargetType,
            TargetId,
            Outcome,
            DetailJson,
            CorrelationId,
            COUNT(*) OVER () AS TotalCount
        FROM dbo.AuditLog
        WHERE (@From IS NULL OR OccurredAt >= @From)
          AND (@To IS NULL OR OccurredAt < @To)
          AND (@ActorFilter IS NULL OR ActorOid = @ActorFilter OR CHARINDEX(@ActorFilter, ActorName) > 0)
          AND (
                @ActionFilter IS NULL
             OR Action = @ActionFilter
             OR (RIGHT(@ActionFilter, 1) = '.' AND LEFT(Action, LEN(@ActionFilter)) = @ActionFilter)
          )
          AND (@TargetTypeFilter IS NULL OR TargetType = @TargetTypeFilter)
          AND (@TargetIdFilter IS NULL OR CHARINDEX(@TargetIdFilter, TargetId) > 0)
          AND (@OutcomeFilter IS NULL OR Outcome = @OutcomeFilter)
    )
    SELECT
        AuditId,
        CONVERT(VARCHAR(33), OccurredAt, 126) + 'Z' AS OccurredAtUtc,
        ActorOid,
        ActorName,
        ActorType,
        Action,
        TargetType,
        TargetId,
        Outcome,
        DetailJson,
        CorrelationId,
        TotalCount
    FROM MatchingRows
    ORDER BY OccurredAt DESC, AuditId DESC
    OFFSET @SafeOffset ROWS
    FETCH NEXT @SafePageSize ROWS ONLY;
END
GO
