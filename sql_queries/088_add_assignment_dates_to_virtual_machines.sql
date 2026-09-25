-- Records when each assignment began and when its user last checked it out. CheckoutVm stamps
-- AssignedDate when it gives a host to a new user and LastCheckoutDate on every checkout,
-- including a reconnect, so the Sessions page can tell a user who never connected from one
-- who is idle. Both are database-local like the table's other dates. Existing assignments
-- keep NULL until their next checkout. ALTER TABLE propagates the columns to the history
-- table automatically.

IF COL_LENGTH('dbo.VirtualMachines', 'AssignedDate') IS NULL
BEGIN
    ALTER TABLE dbo.VirtualMachines
    ADD AssignedDate DATETIME NULL;
END;
GO

IF COL_LENGTH('dbo.VirtualMachines', 'LastCheckoutDate') IS NULL
BEGIN
    ALTER TABLE dbo.VirtualMachines
    ADD LastCheckoutDate DATETIME NULL;
END;
GO
