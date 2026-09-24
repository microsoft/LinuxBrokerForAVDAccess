-- Returns the Linux uid for a broker user, allocating one from dbo.VmUserUidSequence the
-- first time the user checks out.
--
-- The legacy allocator in the API used MAX(uid) + 1, which two concurrent first logins
-- could compute identically. Values the legacy allocator already used are skipped, and a
-- duplicate-key collision with a concurrent insert is retried.
--
-- pymssql runs every statement inside its own transaction, so when this is called inside
-- one it rolls back to a savepoint instead of unwinding the caller's transaction, which
-- would make SQL Server raise error 266 when the procedure returns.

CREATE PROCEDURE [dbo].[GetOrCreateVmUserUid]
    @Username VARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @uid INT;
    DECLARE @Attempts INT = 0;
    DECLARE @StartedTransaction BIT;

    SELECT @uid = uid
    FROM dbo.VmUsers
    WHERE username = @Username;

    IF @uid IS NOT NULL
    BEGIN
        SELECT @uid AS uid;
        RETURN;
    END

    WHILE @Attempts < 20
    BEGIN
        SET @Attempts += 1;
        SET @StartedTransaction = 0;

        BEGIN TRY
            IF @@TRANCOUNT = 0
            BEGIN
                BEGIN TRANSACTION;
                SET @StartedTransaction = 1;
            END
            ELSE
            BEGIN
                SAVE TRANSACTION UidAllocation;
            END

            -- Re-checked under a lock so two concurrent first logins for the same user agree.
            SET @uid = NULL;
            SELECT @uid = uid
            FROM dbo.VmUsers WITH (UPDLOCK, HOLDLOCK)
            WHERE username = @Username;

            IF @uid IS NULL
            BEGIN
                SET @uid = NEXT VALUE FOR dbo.VmUserUidSequence;

                WHILE EXISTS (SELECT 1 FROM dbo.VmUsers WITH (UPDLOCK, HOLDLOCK) WHERE uid = @uid)
                BEGIN
                    SET @uid = NEXT VALUE FOR dbo.VmUserUidSequence;
                END

                INSERT INTO dbo.VmUsers (uid, username)
                VALUES (@uid, @Username);
            END

            IF @StartedTransaction = 1
            BEGIN
                COMMIT TRANSACTION;
            END

            SELECT @uid AS uid;
            RETURN;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() = -1
            BEGIN
                -- The transaction is doomed and cannot be retried from here.
                IF @StartedTransaction = 1
                BEGIN
                    ROLLBACK TRANSACTION;
                END
                ;THROW;
            END

            IF @StartedTransaction = 1 AND @@TRANCOUNT > 0
            BEGIN
                ROLLBACK TRANSACTION;
            END
            ELSE IF XACT_STATE() = 1
            BEGIN
                ROLLBACK TRANSACTION UidAllocation;
            END

            -- 2601 / 2627: a concurrent insert took the value or the username. Try again.
            IF ERROR_NUMBER() NOT IN (2601, 2627)
            BEGIN
                ;THROW;
            END
        END CATCH
    END

    ;THROW 51000, 'Could not allocate a VM user uid.', 1;
END
GO
