CREATE PROCEDURE [dbo].[CheckoutVm]
    @Username NVARCHAR(255),
    @AvdHost NVARCHAR(255)
AS
BEGIN
    -- Start a transaction to ensure atomicity
    BEGIN TRANSACTION;

    DECLARE @VMID INT;

    BEGIN TRY
        -- Check if the user already has a VM checked out or a 'Released' VM
        SELECT @VMID = VMID
        FROM dbo.VirtualMachines
        WHERE Username = @Username
          AND AvdHost = @AvdHost
          AND VmStatus IN ('CheckedOut', 'Released');

        -- If the user already has a VM checked out or a 'Released' VM, return that VM
        IF @VMID IS NOT NULL
        BEGIN
            -- Update the VMStatus to 'CheckedOut' if it was 'Released'
            UPDATE dbo.VirtualMachines
            SET VmStatus = 'CheckedOut',
                LastUpdateDate = GETDATE()
            WHERE VMID = @VMID
              AND VmStatus = 'Released';

            -- Return the VM information
            SELECT VMID, Hostname, IPAddress, Username, AvdHost, VmStatus, LastUpdateDate
            FROM dbo.VirtualMachines
            WHERE VMID = @VMID;

            -- Commit the transaction
            COMMIT TRANSACTION;
        END
        ELSE
        BEGIN
            -- Retrieve the first available VM
            SELECT TOP 1 @VMID = VMID
            FROM dbo.VirtualMachines
            WHERE PowerState = 'On' 
              AND NetworkStatus = 'Reachable' 
              AND VmStatus = 'Available'
            ORDER BY VMID;

            -- If an available VM was found, update it
            IF @VMID IS NOT NULL
            BEGIN
                UPDATE dbo.VirtualMachines
                SET Username = @Username, 
                    AvdHost = @AvdHost, 
                    VmStatus = 'CheckedOut', 
                    LastUpdateDate = GETDATE()
                WHERE VMID = @VMID;

                -- Return the updated VM information
                SELECT VMID, Hostname, IPAddress, Username, AvdHost, VmStatus, LastUpdateDate
                FROM dbo.VirtualMachines
                WHERE VMID = @VMID;

                -- Commit the transaction
                COMMIT TRANSACTION;
            END
            ELSE
            BEGIN
                -- Rollback the transaction if no VM was available
                ROLLBACK TRANSACTION;
                
                -- Return an error message
                SELECT 'No available VM found' AS Message;
            END
        END
    END TRY
    BEGIN CATCH
        -- Rollback the transaction if an error occurs
        IF @@TRANCOUNT > 0
        BEGIN
            ROLLBACK TRANSACTION;
        END

        -- Return the error message
        SELECT ERROR_MESSAGE() AS Message, ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS Severity, ERROR_STATE() AS State;
    END CATCH
END
GO
