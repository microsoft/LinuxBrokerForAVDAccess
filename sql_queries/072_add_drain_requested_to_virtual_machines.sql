-- Adds the drain flag to the temporal VM table. ALTER TABLE propagates both columns to
-- dbo.VirtualMachinesHistory automatically.
--
-- A draining host keeps its current user, who can still reconnect, but is not offered to
-- anyone new. Once the assignment has ended and the previous user has been cleaned off the
-- host, it moves to Maintenance and the flag clears. A flag rather than a new VmStatus keeps
-- the existing lifecycle states and their CHECK constraint untouched.

IF COL_LENGTH('dbo.VirtualMachines', 'DrainRequested') IS NULL
BEGIN
    ALTER TABLE dbo.VirtualMachines
    ADD DrainRequested BIT NOT NULL CONSTRAINT DF_VirtualMachines_DrainRequested DEFAULT (0);
END;
GO

IF COL_LENGTH('dbo.VirtualMachines', 'DrainRequestedDate') IS NULL
BEGIN
    ALTER TABLE dbo.VirtualMachines
    ADD DrainRequestedDate DATETIME NULL;
END;
GO
