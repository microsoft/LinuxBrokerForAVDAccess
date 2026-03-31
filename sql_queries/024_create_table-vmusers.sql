USE linuxbroker;

IF OBJECT_ID('dbo.VmUsers', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.VmUsers (
        uid INT PRIMARY KEY,
        username VARCHAR(255) UNIQUE NOT NULL,
        CreateDate DATETIME DEFAULT(GETDATE())
    );
END;
