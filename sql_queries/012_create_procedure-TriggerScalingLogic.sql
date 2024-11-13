CREATE PROCEDURE [dbo].[TriggerScalingLogic]
AS
BEGIN
    -- Declare variables to hold the scaling rules
    DECLARE @MinVMs INT, @MaxVMs INT, @ScaleUpRatio DECIMAL(5,2), 
            @ScaleUpIncrement INT, @ScaleDownRatio DECIMAL(5,2), 
            @ScaleDownIncrement INT;

    -- Fetch the scaling rules (assuming there's only one set of rules)
    SELECT TOP 1 
        @MinVMs = MinVMs, 
        @MaxVMs = MaxVMs, 
        @ScaleUpRatio = ScaleUpRatio, 
        @ScaleUpIncrement = ScaleUpIncrement, 
        @ScaleDownRatio = ScaleDownRatio, 
        @ScaleDownIncrement = ScaleDownIncrement
    FROM dbo.VmScalingRules;

    -- Declare variables to hold current VM states
    DECLARE @CurrentRunningVMs INT, @CurrentInUseVMs INT, 
            @ActionTaken NVARCHAR(50), @VMsPoweredOn INT = 0, 
            @VMsPoweredOff INT = 0, @NewTotalVMs INT;

    -- Temporary tables to hold VM names
    DECLARE @PoweredOnVMs TABLE (VMID INT, VMName VARCHAR(255));
    DECLARE @PoweredOffVMs TABLE (VMID INT, VMName VARCHAR(255));

    -- Fetch the current number of running VMs and VMs in use
    SELECT 
        @CurrentRunningVMs = COUNT(*),
        @CurrentInUseVMs = SUM(CASE WHEN VmStatus = 'CheckedOut' THEN 1 ELSE 0 END)
    FROM dbo.VirtualMachines
    WHERE PowerState = 'On';

    -- Calculate the current utilization ratio
    DECLARE @CurrentUtilizationRatio DECIMAL(5,2) = 
        (CAST(@CurrentInUseVMs AS DECIMAL) / CAST(@CurrentRunningVMs AS DECIMAL)) * 100;

    -- Determine the scaling action based on the current utilization ratio
    IF @CurrentUtilizationRatio >= @ScaleUpRatio AND @CurrentRunningVMs < @MaxVMs
    BEGIN
        -- Scale up: Add VMs
        SET @VMsPoweredOn = CASE 
                               WHEN @CurrentRunningVMs + @ScaleUpIncrement > @MaxVMs 
                               THEN @MaxVMs - @CurrentRunningVMs 
                               ELSE @ScaleUpIncrement 
                             END;

        -- Update VM statuses to 'On' for the number of VMs being powered on
        UPDATE TOP (@VMsPoweredOn) dbo.VirtualMachines
        SET PowerState = 'On', VmStatus = 'Available', LastUpdateDate = GETDATE()
        OUTPUT INSERTED.VMID, INSERTED.Hostname INTO @PoweredOnVMs
        WHERE PowerState = 'Off';

        SET @ActionTaken = 'Scale Up';
    END
    ELSE IF @CurrentUtilizationRatio <= @ScaleDownRatio AND @CurrentRunningVMs > @MinVMs
    BEGIN
        -- Scale down: Remove VMs
        SET @VMsPoweredOff = CASE 
                                WHEN @CurrentRunningVMs - @ScaleDownIncrement < @MinVMs 
                                THEN @CurrentRunningVMs - @MinVMs 
                                ELSE @ScaleDownIncrement 
                              END;

        -- Update VM statuses to 'Off' for the number of VMs being powered off
        UPDATE TOP (@VMsPoweredOff) dbo.VirtualMachines
        SET PowerState = 'Off', VmStatus = 'Available', LastUpdateDate = GETDATE()
        OUTPUT INSERTED.VMID, INSERTED.Hostname INTO @PoweredOffVMs
        WHERE PowerState = 'On' AND VmStatus = 'Available';

        SET @ActionTaken = 'Scale Down';
    END
    ELSE
    BEGIN
        -- No scaling action needed
        SET @ActionTaken = 'No Action';
    END

    -- Calculate the new total number of running VMs
    SET @NewTotalVMs = @CurrentRunningVMs + @VMsPoweredOn - @VMsPoweredOff;

    -- Log the scaling activity
    INSERT INTO dbo.VmScalingActivityLog (
        CheckTimestamp, CurrentRunningVMs, CurrentInUseVMs, 
        ActionTaken, VMsPoweredOn, VMsPoweredOff, NewTotalVMs, Outcome
    )
    VALUES (
        GETDATE(), @CurrentRunningVMs, @CurrentInUseVMs, 
        @ActionTaken, @VMsPoweredOn, @VMsPoweredOff, @NewTotalVMs,
        CASE 
            WHEN @ActionTaken = 'Scale Up' THEN CONCAT('Scaled up by ', @VMsPoweredOn, ' VMs')
            WHEN @ActionTaken = 'Scale Down' THEN CONCAT('Scaled down by ', @VMsPoweredOff, ' VMs')
            ELSE 'No scaling action was necessary'
        END
    );

    -- Return the names of the VMs that were powered on or off
    SELECT 'PoweredOn' AS ActionType, VMName FROM @PoweredOnVMs
    UNION ALL
    SELECT 'PoweredOff' AS ActionType, VMName FROM @PoweredOffVMs;
END
GO
