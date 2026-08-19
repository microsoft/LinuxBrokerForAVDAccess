-- Hostname is the natural key the broker resolves against: RegisterLinuxHostVm, ReleaseVm,
-- and the host agents all locate a VM by Hostname alone. Without a uniqueness guarantee those
-- lookups fall back to TOP 1 and can act on the wrong row.
--
-- Existing databases may already contain duplicates, so this script reports them and skips
-- rather than failing the bootstrap. Resolve the duplicates and rerun to gain the constraint.

IF OBJECT_ID('dbo.VirtualMachines', 'U') IS NOT NULL
BEGIN
    IF EXISTS (
        SELECT 1
        FROM dbo.VirtualMachines
        GROUP BY Hostname
        HAVING COUNT(*) > 1
    )
    BEGIN
        DECLARE @DuplicateHostnames NVARCHAR(MAX);

        SELECT @DuplicateHostnames = STRING_AGG(CAST(Hostname AS NVARCHAR(MAX)), ', ')
        FROM (
            SELECT Hostname
            FROM dbo.VirtualMachines
            GROUP BY Hostname
            HAVING COUNT(*) > 1
        ) AS Duplicates;

        PRINT 'WARNING: dbo.VirtualMachines contains duplicate Hostname values, so the unique index was not created.';
        PRINT 'WARNING: Duplicate hostnames: ' + ISNULL(@DuplicateHostnames, '');
        PRINT 'WARNING: Remove the duplicate rows and rerun this script to enforce Hostname uniqueness.';
    END
    ELSE IF NOT EXISTS (
        SELECT 1
        FROM sys.indexes
        WHERE name = 'UQ_VirtualMachines_Hostname'
          AND object_id = OBJECT_ID('dbo.VirtualMachines')
    )
    BEGIN
        CREATE UNIQUE INDEX UQ_VirtualMachines_Hostname
        ON dbo.VirtualMachines (Hostname);

        PRINT 'Created unique index UQ_VirtualMachines_Hostname on dbo.VirtualMachines.';
    END
END;
GO
