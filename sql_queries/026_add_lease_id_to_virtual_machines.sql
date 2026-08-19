IF COL_LENGTH('dbo.VirtualMachines', 'LeaseId') IS NULL
BEGIN
    ALTER TABLE dbo.VirtualMachines
    ADD LeaseId UNIQUEIDENTIFIER NULL;
END;
GO