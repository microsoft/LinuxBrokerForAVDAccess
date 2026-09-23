#requires -Version 7.4
Set-StrictMode -Version Latest

function Invoke-BrokerAz {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Operation,
        [switch]$Raw,
        [switch]$NoOutput
    )

    $PSNativeCommandUseErrorActionPreference = $false
    $format = if ($NoOutput) { 'none' } elseif ($Raw) { 'tsv' } else { 'json' }
    $result = & az @Arguments --only-show-errors --output $format 2>$null
    if ($LASTEXITCODE -ne 0) {
        # CLI errors can include request bodies, SAS URLs, app settings, or credentials.
        throw "$Operation failed (Azure CLI exit $LASTEXITCODE). No response body was logged."
    }
    if ($NoOutput) { return }
    $text = ($result | Out-String).Trim()
    if ($Raw) { return $text }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try { return ConvertFrom-Json -InputObject $text -AsHashtable -Depth 100 }
    catch [ArgumentException] { throw "$Operation returned invalid JSON. No response body was logged." }
}

function Get-BrokerEnvironment {
    param([Parameter(Mandatory)][string]$EnvironmentName)
    $PSNativeCommandUseErrorActionPreference = $false
    $result = & azd --cwd $PSScriptRoot env get-values --environment $EnvironmentName --output json --no-prompt 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot read azd environment '$EnvironmentName' (exit $LASTEXITCODE)."
    }
    try { return ConvertFrom-Json -InputObject ($result | Out-String) -AsHashtable }
    catch [ArgumentException] { throw "The azd environment '$EnvironmentName' is not valid JSON. No values were logged." }
}

function Set-BrokerEnvironmentValue {
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    $PSNativeCommandUseErrorActionPreference = $false
    $PSNativeCommandArgumentPassing = 'Standard'
    $null = & azd --cwd $PSScriptRoot env set --environment $EnvironmentName --no-prompt -- $Key $Value 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Cannot set azd value '$Key' (exit $LASTEXITCODE)." }
}

function Assert-BrokerGuid {
    param([Parameter(Mandatory)][string]$Value, [string]$Name = 'ID')
    $parsed = [guid]::Empty
    if ($Value -cnotmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -or
        -not [guid]::TryParse($Value, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
        throw "$Name must be a nonzero, canonical GUID."
    }
    return $parsed.ToString()
}

function Assert-BrokerHttpsUrl {
    param([Parameter(Mandatory)][string]$Value, [switch]$Api, [switch]$Authority, [switch]$AllowQuery)
    $uri = $null
    if (-not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Fragment -or
        (-not $AllowQuery -and $uri.Query) -or
        ($Api -and $uri.AbsolutePath.TrimEnd('/') -notmatch '/api$') -or
        ($Authority -and $uri.AbsolutePath -ne '/')) {
        throw 'Expected an HTTPS URL without user information or a fragment; API URLs must end in /api.'
    }
    return $Value.TrimEnd('/')
}

function Assert-BrokerLinuxIdentity {
    param([Parameter(Mandatory)][string]$Username, [Parameter(Mandatory)]$Uid)
    $reserved = @(
        'root', 'daemon', 'bin', 'sys', 'sync', 'games', 'man', 'lp', 'mail', 'news', 'uucp',
        'proxy', 'www-data', 'backup', 'list', 'irc', 'nobody', 'sshd', 'dbus', 'polkitd',
        'chrony', 'chronyd', 'waagent', 'avdadmin', 'azureuser', 'ubuntu', 'postgres', 'messagebus', 'systemd-network',
        'systemd-resolve', 'systemd-timesync'
    )
    if ($Username -cnotmatch '^[A-Za-z_][A-Za-z0-9_-]{0,31}$' -or $Username.ToLowerInvariant() -in $reserved -or
        $Username.ToLowerInvariant().StartsWith('systemd-')) {
        throw "Invalid or reserved Linux username '$Username'."
    }
    if (($Uid -isnot [int] -and $Uid -isnot [long]) -or $Uid -lt 2000 -or
        $Uid -gt 2147483646 -or $Uid -in @(65534, 65535)) {
        throw "UID for '$Username' must be an integer in 2000..2147483646, excluding 65534 and 65535."
    }
}

function New-BrokerTemporaryFile {
    param([string]$Extension = '.json')
    return Join-Path ([IO.Path]::GetTempPath()) ('linuxbroker-' + [guid]::NewGuid().ToString('N') + $Extension)
}

function Write-BrokerPrivateJson {
    param([Parameter(Mandatory)]$Value)
    return Write-BrokerPrivateText -Content ($Value | ConvertTo-Json -Depth 100 -Compress)
}

function Write-BrokerPrivateText {
    param([Parameter(Mandatory)][string]$Content)
    $path = New-BrokerTemporaryFile
    # The creator's temp directory is private. Explicitly remove inherited access on Windows.
    $complete = $false
    try {
        [IO.File]::WriteAllText($path, '', [Text.UTF8Encoding]::new($false))
        if ($IsWindows) {
            $acl = [Security.AccessControl.FileSecurity]::new()
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,
                    [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
                    [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
                $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow'))
            }
            Set-Acl -LiteralPath $path -AclObject $acl
        }
        [IO.File]::WriteAllText($path, $Content, [Text.UTF8Encoding]::new($false))
        $complete = $true
        return $path
    }
    finally {
        if (-not $complete -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force }
    }
}

function Invoke-BrokerGraph {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        $Body
    )
    $null = Assert-BrokerHttpsUrl -Value $Uri -AllowQuery
    $arguments = @('rest', '--method', $Method, '--url', $Uri)
    $bodyPath = $null
    try {
        if ($null -ne $Body) {
            $bodyPath = Write-BrokerPrivateJson -Value $Body
            $arguments += @('--headers', 'Content-Type=application/json', '--body', "@$bodyPath")
        }
        return Invoke-BrokerAz -Arguments $arguments -Operation "Graph $Method $(([uri]$Uri).AbsolutePath)"
    }
    finally {
        if ($bodyPath -and (Test-Path -LiteralPath $bodyPath)) { Remove-Item -LiteralPath $bodyPath -Force }
    }
}

function Get-BrokerGraphCollection {
    param([Parameter(Mandatory)][string]$Uri)
    $authority = ([uri]$Uri).GetLeftPart([UriPartial]::Authority)
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while ($Uri) {
        if (-not $visited.Add($Uri) -or ([uri]$Uri).GetLeftPart([UriPartial]::Authority) -cne $authority) {
            throw 'Graph returned an invalid pagination link.'
        }
        $page = Invoke-BrokerGraph -Method GET -Uri $Uri
        if (-not $page.Contains('value')) { throw 'Graph collection response is missing value.' }
        foreach ($item in $page.value) { Write-Output $item }
        $Uri = $page['@odata.nextLink']
    }
}

function Get-BrokerGraphEndpoint {
    param([string]$GraphEndpoint)
    if (-not $GraphEndpoint) { $GraphEndpoint = $env:GRAPH_ENDPOINT }
    if (-not $GraphEndpoint) {
        $cloud = Invoke-BrokerAz -Arguments @('cloud', 'show') -Operation 'Read Azure cloud'
        $GraphEndpoint = switch ($cloud.name) {
            'AzureCloud' { 'https://graph.microsoft.com' }
            'AzureUSGovernment' { 'https://graph.microsoft.us' }
            default { throw 'This cloud requires an explicit GraphEndpoint.' }
        }
    }
    return Assert-BrokerHttpsUrl -Value $GraphEndpoint -Authority
}

function Assert-BrokerTenant {
    param([Parameter(Mandatory)][string]$TenantId)
    $TenantId = Assert-BrokerGuid $TenantId 'TenantId'
    $account = Invoke-BrokerAz -Arguments @('account', 'show') -Operation 'Read deployment tenant'
    if ($account.tenantId -ne $TenantId) { throw 'The Azure CLI tenant does not match the reviewed deployment tenant.' }
}

function New-BrokerSqlConnection {
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$Password
    )
    $builder = [Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder['Data Source'] = "tcp:$Server,1433"
    $builder['Initial Catalog'] = $Database
    $builder['User ID'] = $Username
    $builder['Password'] = $Password
    $builder['Encrypt'] = $true
    $builder['TrustServerCertificate'] = $false
    $builder['Persist Security Info'] = $false
    $builder['Connect Timeout'] = 30
    return [Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
}

function Invoke-BrokerSqlProcedure {
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][ValidateSet('BindBrokerUser', 'RegisterBrokerHost', 'RegisterLinuxHostVm',
            'GetBrokerLeaseMigrationState')][string]$Name,
        [Parameter(Mandatory)][hashtable]$Parameters,
        $Transaction
    )
    $command = $Connection.CreateCommand()
    $command.CommandType = [Data.CommandType]::StoredProcedure
    $command.CommandText = "dbo.$Name"
    $command.CommandTimeout = 120
    if ($Transaction) { $command.Transaction = $Transaction }
    try {
        foreach ($key in $Parameters.Keys) {
            $type = switch ($key) {
                { $_ -in @('TenantId', 'ObjectId', 'LeaseId') } { [Data.SqlDbType]::UniqueIdentifier }
                'Uid' { [Data.SqlDbType]::Int }
                default { [Data.SqlDbType]::NVarChar }
            }
            $parameter = $command.Parameters.Add("@$key", $type)
            $parameter.Value = $Parameters[$key]
            if ($type -eq [Data.SqlDbType]::NVarChar) { $parameter.Size = -1 }
        }
        $reader = $command.ExecuteReader()
        try {
            do {
                while ($reader.Read()) {
                    $row = @{}
                    for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                        $row[$reader.GetName($i)] = if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) }
                    }
                    Write-Output $row
                }
            } while ($reader.NextResult())
        }
        finally { $reader.Dispose() }
    }
    finally { $command.Dispose() }
}

function Get-BrokerLinuxInventory {
    param([Parameter(Mandatory)][string]$ResourceGroupName, [Parameter(Mandatory)][string]$TenantId, [string]$SubscriptionId)
    $arguments = @('vm', 'list', '--resource-group', $ResourceGroupName, '--show-details')
    if ($SubscriptionId) { $arguments += @('--subscription', (Assert-BrokerGuid $SubscriptionId 'VM subscription ID')) }
    $vms = @(Invoke-BrokerAz -Arguments $arguments -Operation 'Read Linux ARM inventory')
    foreach ($item in $vms) {
        if (-not $item.tags -or $item.tags['broker-role'] -ne 'linux-host') { continue }
        $vm = Invoke-BrokerAz -Arguments @('vm', 'show', '--ids', $item.id) -Operation "Read Linux VM '$($item.name)'"
        if ($vm.storageProfile.osDisk.osType -ne 'Linux' -or
            -not $vm.identity -or $vm.identity.tenantId -ne $TenantId) {
            throw "Linux VM '$($item.name)' has an unexpected OS or managed-identity tenant."
        }
        $principalId = Assert-BrokerGuid $vm.identity.principalId 'Host principal ID'
        $hostname = $vm.osProfile.computerName
        if ($hostname -notmatch '^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$' -or $hostname -ne $vm.name) {
            throw "VM '$($vm.name)' must have a matching, valid ARM computerName before broker enrollment."
        }
        $privateIp = @($item.privateIps -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $address = $null
        if ($privateIp.Count -ne 1 -or -not [Net.IPAddress]::TryParse($privateIp[0], [ref]$address)) {
            throw "Linux VM '$hostname' must have exactly one verified private IP."
        }
        [pscustomobject]@{
            Name = $hostname
            ResourceId = $vm.id
            ObjectId = $principalId
            TenantId = $TenantId
            IPAddress = $privateIp[0]
        }
    }
}

function Get-BrokerSqlHostnames {
    param([Parameter(Mandatory)]$Connection, [switch]$AllowMissingTable)
    $command = $Connection.CreateCommand()
    $command.CommandText = if ($AllowMissingTable) {
        "IF OBJECT_ID(N'dbo.VirtualMachines', N'U') IS NOT NULL SELECT Hostname FROM dbo.VirtualMachines;"
    } else { 'SELECT Hostname FROM dbo.VirtualMachines;' }
    $command.CommandTimeout = 60
    try {
        $reader = $command.ExecuteReader()
        try {
            while ($reader.Read()) {
                if ($reader.IsDBNull(0)) { throw 'A SQL host record has no hostname. Resolve the inventory before migration.' }
                Write-Output $reader.GetString(0)
            }
        }
        finally { $reader.Dispose() }
    }
    finally { $command.Dispose() }
}

function Assert-BrokerMigrationInventory {
    param([AllowEmptyCollection()][array]$Hosts, [AllowEmptyCollection()][string[]]$DatabaseHostnames)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($hostRecord in $Hosts) {
        if (-not $names.Add($hostRecord.Name)) { throw 'ARM inventory has duplicate broker hostnames.' }
    }
    foreach ($name in $DatabaseHostnames) {
        if (-not $names.Contains($name)) {
            throw "SQL host '$name' is absent from the trusted tagged ARM inventory. Resolve its resource/tag/scope or explicitly retire the record; it cannot be silently skipped."
        }
    }
}

function Invoke-BrokerVmScript {
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][ValidateSet('RunShellScript', 'RunPowerShellScript')][string]$CommandId,
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string]$Operation,
        [switch]$ReturnOutput
    )
    $sentinel = 'BROKER_OK_' + [guid]::NewGuid().ToString('N')
    $path = $null
    try {
        if ($CommandId -eq 'RunShellScript') {
            $content = "set -euo pipefail`n" + $Script + "`nprintf '%s\n' '$sentinel'`n"
        }
        else {
            $content = "`$ErrorActionPreference = 'Stop'`ntry {`n" + $Script +
                "`nWrite-Output '$sentinel'`n} catch { Write-Error 'Broker host operation failed. Inspect the host locally; response details were suppressed.'; exit 1 }`n"
        }
        $path = Write-BrokerPrivateText -Content $content.Replace("`r`n", "`n")
        $result = Invoke-BrokerAz -Arguments @('vm', 'run-command', 'invoke', '--ids', $ResourceId,
            '--command-id', $CommandId, '--scripts', "@$path") -Operation $Operation
        # Run Command may return HTTP success even when the guest script exited nonzero.
        $stdout = @($result.value | Where-Object { $_.code -eq 'ComponentStatus/StdOut/succeeded' } |
            ForEach-Object { $_.message }) -join "`n"
        if ($stdout -notmatch "(?m)^$sentinel\s*$") {
            throw "$Operation did not report verified guest completion. The environment remains paused."
        }
        if ($ReturnOutput) { return $stdout }
    }
    finally {
        if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force }
    }
}

function ConvertTo-BrokerBashLiteral {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return "'" + $Value.Replace("'", "'`"'`"'") + "'"
}
