-- The users waiting for a host to start (4.1): each user whose latest checkout event in the last
-- five minutes is Starting. An AVD host asks again at least every two minutes while its user
-- waits, and a checkout that ends in any other way records that outcome, so a user who gave up
-- stops counting within five minutes. Scaling, start on demand, the dashboard and the fleet
-- snapshot all count waiting users with this.

CREATE OR ALTER FUNCTION dbo.fnWaitingCheckoutUsers ()
RETURNS TABLE
AS
RETURN
    SELECT latest.Username, latest.OccurredAt AS LastAskedAt
    FROM (
        SELECT e.Username, e.Outcome, e.OccurredAt,
               ROW_NUMBER() OVER (PARTITION BY e.Username ORDER BY e.OccurredAt DESC, e.EventID DESC) AS Recency
        FROM dbo.CheckoutEvents e
        WHERE e.Username IS NOT NULL
          AND e.OccurredAt >= DATEADD(MINUTE, -5, SYSUTCDATETIME())
    ) latest
    WHERE latest.Recency = 1
      AND latest.Outcome = 'Starting';
GO
