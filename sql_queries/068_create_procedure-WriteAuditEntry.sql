-- Appends one audit entry and returns its id.
--
-- The API calls this on its own connection after the audited operation has finished, and a
-- failure here never fails that operation. Over-long values are truncated rather than
-- rejected, and detail that is not valid JSON is dropped, so an entry is never lost to a
-- formatting problem.

CREATE PROCEDURE [dbo].[WriteAuditEntry]
    @ActorOid VARCHAR(64) = NULL,
    @ActorName NVARCHAR(256) = NULL,
    @ActorType VARCHAR(16),
    @Action VARCHAR(64),
    @TargetType VARCHAR(32) = NULL,
    @TargetId NVARCHAR(256) = NULL,
    @Outcome VARCHAR(16),
    @DetailJson NVARCHAR(MAX) = NULL,
    @CorrelationId VARCHAR(64) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.AuditLog (
        ActorOid, ActorName, ActorType, Action, TargetType, TargetId, Outcome, DetailJson, CorrelationId
    )
    OUTPUT INSERTED.AuditId
    VALUES (
        LEFT(@ActorOid, 64),
        LEFT(@ActorName, 256),
        @ActorType,
        LEFT(@Action, 64),
        LEFT(@TargetType, 32),
        LEFT(@TargetId, 256),
        @Outcome,
        CASE WHEN @DetailJson IS NOT NULL AND ISJSON(@DetailJson) = 1 THEN @DetailJson ELSE NULL END,
        LEFT(@CorrelationId, 64)
    );
END
GO
