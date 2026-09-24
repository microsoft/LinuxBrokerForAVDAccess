-- Adds release and cleanup lifecycle tracking to the temporal VM table.
-- ALTER TABLE propagates these columns to the history table automatically.

IF COL_LENGTH('dbo.VirtualMachines', 'ReleasedDate') IS NULL
BEGIN
    ALTER TABLE dbo.VirtualMachines
    ADD ReleasedDate DATETIME NULL;
END;
GO

IF COL_LENGTH('dbo.VirtualMachines', 'CleanupPending') IS NULL
BEGIN
    ALTER TABLE dbo.VirtualMachines
    ADD CleanupPending BIT NOT NULL CONSTRAINT DF_VirtualMachines_CleanupPending DEFAULT (0);
END;
GO

IF COL_LENGTH('dbo.VirtualMachines', 'CleanupUsername') IS NULL
BEGIN
    ALTER TABLE dbo.VirtualMachines
    ADD CleanupUsername VARCHAR(255) NULL;
END;
GO

IF COL_LENGTH('dbo.VirtualMachines', 'CleanupLeaseId') IS NULL
BEGIN
    ALTER TABLE dbo.VirtualMachines
    ADD CleanupLeaseId UNIQUEIDENTIFIER NULL;
END;
GO

IF COL_LENGTH('dbo.VirtualMachines', 'CleanupAttemptDate') IS NULL
BEGIN
    ALTER TABLE dbo.VirtualMachines
    ADD CleanupAttemptDate DATETIME NULL;
END;
GO

IF COL_LENGTH('dbo.VirtualMachines', 'PowerStateChangedDate') IS NULL
BEGIN
    ALTER TABLE dbo.VirtualMachines
    ADD PowerStateChangedDate DATETIME NULL;
END;
GO

UPDATE dbo.VirtualMachines
SET ReleasedDate = LastUpdateDate
WHERE VmStatus = 'Released'
  AND ReleasedDate IS NULL;
GO

-- Checkout and scaling only use Available hosts with no Username or LeaseId. Two sources left
-- rows that break that: the portal's Add VM stored blank strings, and the previous
-- UpdateVmAttributes kept the assignment when an administrator set a stuck host to Available
-- or Maintenance. Blank values become NULL, and a real leftover assignment is cleared with its
-- cleanup claimed, so the broker removes that user from the host before reusing it.
UPDATE dbo.VirtualMachines
SET CleanupPending = CASE WHEN NULLIF(LTRIM(RTRIM(Username)), '') IS NOT NULL THEN 1 ELSE CleanupPending END,
    CleanupUsername = CASE WHEN NULLIF(LTRIM(RTRIM(Username)), '') IS NOT NULL THEN Username ELSE CleanupUsername END,
    CleanupLeaseId = CASE WHEN NULLIF(LTRIM(RTRIM(Username)), '') IS NOT NULL THEN LeaseId ELSE CleanupLeaseId END,
    CleanupAttemptDate = CASE WHEN NULLIF(LTRIM(RTRIM(Username)), '') IS NOT NULL THEN NULL ELSE CleanupAttemptDate END,
    Username = NULL,
    AvdHost = NULL,
    LeaseId = NULL
WHERE VmStatus IN ('Available', 'Maintenance')
  AND (Username IS NOT NULL OR AvdHost IS NOT NULL OR LeaseId IS NOT NULL);
GO
