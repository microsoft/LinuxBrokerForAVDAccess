## Database Setup and SQL Procedures

The `sql_queries` directory contains all the necessary SQL scripts to set up the Azure SQL Database for the Linux Broker for AVD Access solution. These scripts create the required tables and stored procedures that the Broker API and other components utilize to manage VMs, scaling rules, and activity logs.

### Contents of `sql_queries`

#### Table Creation Scripts

1. **Create Tables**:
   - `001_create_table-vm_scaling_rules.sql`: Creates the `vm_scaling_rules` table to store scaling rules.
   - `002_create_table-vm_scaling_activity_log.sql`: Creates the `vm_scaling_activity_log` table to log scaling activities.
   - `003_create_table-virtual_machines.sql`: Creates the `virtual_machines` table to store information about Linux VMs.

#### Stored Procedure Scripts

2. **Create Stored Procedures**:
   - `005_create_procedure-CheckoutVm.sql`: Checks out a VM for a user.
   - `006_create_procedure-DeleteVm.sql`: Deletes a VM record.
   - `007_create_procedure-AddVm.sql`: Adds a new VM to the system.
   - `008_create_procedure-GetVmDetails.sql`: Retrieves details of a specific VM.
   - `009_create_procedure-ReturnVm.sql`: Returns a VM to the pool.
   - `010_create_procedure-GetScalingRules.sql`: Retrieves current scaling rules.
   - `011_create_procedure-UpdateScalingRule.sql`: Updates a scaling rule.
   - `012_create_procedure-TriggerScalingLogic.sql`: Triggers scaling logic based on current metrics.
   - `013_create_procedure-GetScalingActivityLog.sql`: Retrieves the scaling activity log.
   - `014_create_procedure-GetVms.sql`: Retrieves a list of VMs.
   - `015_create_procedure-CreateScalingRule.sql`: Creates a new scaling rule.
   - `016_create_procedure-ReleaseVm.sql`: Releases a VM from a user.
   - `017_create_procedure-UpdateVmAttributes.sql`: Updates attributes of a VM.
   - `018_create_procedure-ReturnReleasedVms.sql`: Returns VMs that were released.
   - `019_create_procedure-DeleteScalingRule.sql`: Deletes a scaling rule.
   - `020_create_procedure-GetVmHistory.sql`: Retrieves the history of VM status changes.
   - `021_create_procedure-GetVmScalingRulesHistory.sql`: Retrieves the history of scaling rule changes.
   - `022_create_procedure-GetScalingRuleDetails.sql`: Retrieves details of a specific scaling rule.
   - `023_create_procedure-GetDeletedVirtualMachines.sql`: Retrieves records of deleted VMs.

### Prerequisites

- **Azure SQL Database Instance**: Ensure you have an Azure SQL Database instance set up.
- **SQL Client Tool**: Use tools like Azure Data Studio, SQL Server Management Studio (SSMS), or SQLCMD.
- **Permissions**: You need sufficient permissions to create tables, stored procedures, and manage users in the database.

### Deployment Steps

Follow these steps to set up the database:

#### 1. Connect to Azure SQL Database

- Open your SQL client tool.
- Connect to your Azure SQL Database instance using administrator credentials.

#### 2. Create Tables

Run the table creation scripts in the following order:

**a. Create `vm_scaling_rules` Table**

```sql
-- Run 001_create_table-vm_scaling_rules.sql
```

**b. Create `vm_scaling_activity_log` Table**

```sql
-- Run 002_create_table-vm_scaling_activity_log.sql
```

**c. Create `virtual_machines` Table**

```sql
-- Run 003_create_table-virtual_machines.sql
```

#### 3. Deploy Stored Procedures

Run each stored procedure script sequentially:

**a. Checkout VM Procedure**

```sql
-- Run 005_create_procedure-CheckoutVm.sql
```

**b. Delete VM Procedure**

```sql
-- Run 006_create_procedure-DeleteVm.sql
```

**c. Add VM Procedure**

```sql
-- Run 007_create_procedure-AddVm.sql
```

**d. Get VM Details Procedure**

```sql
-- Run 008_create_procedure-GetVmDetails.sql
```

**e. Return VM Procedure**

```sql
-- Run 009_create_procedure-ReturnVm.sql
```

**f. Get Scaling Rules Procedure**

```sql
-- Run 010_create_procedure-GetScalingRules.sql
```

**g. Update Scaling Rule Procedure**

```sql
-- Run 011_create_procedure-UpdateScalingRule.sql
```

**h. Trigger Scaling Logic Procedure**

```sql
-- Run 012_create_procedure-TriggerScalingLogic.sql
```

**i. Get Scaling Activity Log Procedure**

```sql
-- Run 013_create_procedure-GetScalingActivityLog.sql
```

**j. Get VMs Procedure**

```sql
-- Run 014_create_procedure-GetVms.sql
```

**k. Create Scaling Rule Procedure**

```sql
-- Run 015_create_procedure-CreateScalingRule.sql
```

**l. Release VM Procedure**

```sql
-- Run 016_create_procedure-ReleaseVm.sql
```

**m. Update VM Attributes Procedure**

```sql
-- Run 017_create_procedure-UpdateVmAttributes.sql
```

**n. Return Released VMs Procedure**

```sql
-- Run 018_create_procedure-ReturnReleasedVms.sql
```

**o. Delete Scaling Rule Procedure**

```sql
-- Run 019_create_procedure-DeleteScalingRule.sql
```

**p. Get VM History Procedure**

```sql
-- Run 020_create_procedure-GetVmHistory.sql
```

**q. Get VM Scaling Rules History Procedure**

```sql
-- Run 021_create_procedure-GetVmScalingRulesHistory.sql
```

**r. Get Scaling Rule Details Procedure**

```sql
-- Run 022_create_procedure-GetScalingRuleDetails.sql
```

**s. Get Deleted Virtual Machines Procedure**

```sql
-- Run 023_create_procedure-GetDeletedVirtualMachines.sql
```

#### 4. Verify Deployment

After running all scripts:

- **Check Tables**:

  ```sql
  SELECT name FROM sys.tables;
  ```

  Ensure `vm_scaling_rules`, `vm_scaling_activity_log`, and `virtual_machines` tables are listed.

- **Check Stored Procedures**:

  ```sql
  SELECT name FROM sys.procedures;
  ```

  Verify that all stored procedures are present.

#### 5. Grant Permissions (If Necessary)

Ensure that the managed identities and users have the appropriate permissions to execute the stored procedures:

- **Grant Execute Permission**:

  ```sql
  GRANT EXECUTE ON [schema].[procedure_name] TO [user_or_role];
  ```

### Notes and Best Practices

- **Run Scripts Sequentially**: The order of execution is crucial due to dependencies between tables and stored procedures.
- **Backup Database**: If you're deploying to an existing database, consider taking a backup before making changes.
- **Use Transaction Blocks**: For critical deployments, wrap your scripts in transactions to ensure atomicity.
- **Error Handling**: Check for errors after running each script and resolve any issues before proceeding.
- **Security**: Ensure that connection strings and credentials are secured. Use Azure Key Vault where applicable.

### Example Deployment Using SQLCMD

If you prefer to run scripts from the command line using `sqlcmd`, here's how you can do it:

```bash
sqlcmd -S your_server.database.windows.net -U your_username -P your_password -d your_database -i "sql_queries/001_create_table-vm_scaling_rules.sql"

sqlcmd -S your_server.database.windows.net -U your_username -P your_password -d your_database -i "sql_queries/002_create_table-vm_scaling_activity_log.sql"

-- Continue running all scripts in order
```

Replace `your_server`, `your_username`, `your_password`, and `your_database` with your actual database connection details.

### Automating Deployment with a Script

You can create a deployment script to automate running all SQL files in the correct order. Here's an example using a PowerShell script:

```powershell
$server = "your_server.database.windows.net"
$username = "your_username"
$password = "your_password"
$database = "your_database"
$sqlFiles = Get-ChildItem -Path "sql_queries" -Filter "*.sql" | Sort-Object Name

foreach ($file in $sqlFiles) {
    Write-Host "Executing $($file.Name)..."
    sqlcmd -S $server -U $username -P $password -d $database -i $file.FullName
}
```

### Troubleshooting

- **Common Errors**:

  - *Permission Denied*: Ensure your user has the necessary permissions.
  - *Syntax Errors*: Check the SQL script for typos or syntax issues.
  - *Missing Objects*: Verify that dependent tables or procedures exist before running a script.

- **Logging**:

  - Enable logging in your SQL client to capture detailed error messages.
  - Review Azure SQL Database logs for any server-side issues.

### Updating the Database

If you need to update existing stored procedures or tables:

- **Modify the Script**: Update the SQL script with the necessary changes.
- **Run ALTER Commands**: Use `ALTER PROCEDURE` or `ALTER TABLE` instead of `CREATE`.
- **Version Control**: Keep your SQL scripts under version control to track changes.