#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LinuxBrokerApiBaseUrl,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$AuthorityHost,
    [Parameter(Mandatory)][string]$LauncherClientId,
    [Parameter(Mandatory)][string]$ApiClientId,
    [Parameter(Mandatory, ParameterSetName = 'Download')][string]$PackageUri,
    [Parameter(Mandatory, ParameterSetName = 'Local')][string]$PackagePath,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$PackageSha256,
    [Parameter(Mandatory)][ValidatePattern('^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})$')][string]$PackageVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-LauncherGuid {
    param([string]$Value)
    $id = [guid]::Empty
    if ($Value -notmatch '^[0-9a-fA-F-]{36}$' -or -not [guid]::TryParseExact($Value, 'D', [ref]$id) -or $id -eq [guid]::Empty) {
        throw 'Launcher configuration requires canonical, nonzero tenant and application GUIDs.'
    }
    return $id.ToString()
}

function Assert-LauncherUrl {
    param([string]$Value, [switch]$Api, [switch]$Authority, [switch]$AllowQuery)
    $uri = $null
    if (-not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Fragment -or
        (-not $AllowQuery -and $uri.Query) -or ($Authority -and $uri.AbsolutePath -ne '/') -or
        ($Api -and $uri.AbsolutePath.TrimEnd('/') -notmatch '/api$')) {
        throw 'Invalid launcher HTTPS URL. API URL must include /api; authority must be an origin.'
    }
    return $Value.TrimEnd('/')
}

function Assert-LauncherNoReparsePoint {
    param([Parameter(Mandatory)][string]$Path)
    $candidate = [IO.Path]::GetFullPath($Path)
    while ($candidate) {
        if (Test-Path -LiteralPath $candidate) {
            if ((Get-Item -LiteralPath $candidate -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Launcher installation refuses symbolic links and directory junctions.'
            }
        }
        $candidate = [IO.Path]::GetDirectoryName($candidate)
    }
}

function Set-LauncherAcl {
    param([Parameter(Mandatory)][string]$Path)
    Assert-LauncherNoReparsePoint $Path
    $isDirectory = (Get-Item -LiteralPath $Path -Force).PSIsContainer
    $acl = if ($isDirectory) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
    $acl.SetAccessRuleProtection($true, $false)
    $admins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $acl.SetOwner($admins)
    foreach ($entry in @(
            @{ Sid = 'S-1-5-18'; Rights = 'FullControl' },
            @{ Sid = 'S-1-5-32-544'; Rights = 'FullControl' },
            @{ Sid = 'S-1-5-32-545'; Rights = 'ReadAndExecute' })) {
        $sid = New-Object Security.Principal.SecurityIdentifier $entry.Sid
        $inherit = if ($isDirectory) { 'ContainerInherit,ObjectInherit' } else { 'None' }
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, $entry.Rights, $inherit, 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Test-LauncherArchive {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Sha256)
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $Sha256) {
        throw 'Launcher SHA256 mismatch. Nothing was installed.'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $names = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        [long]$expandedBytes = 0
        if ($archive.Entries.Count -gt 10000) { throw 'Launcher archive contains too many entries.' }
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            $segments = $name.TrimEnd('/').Split('/')
            $unixType = ($entry.ExternalAttributes -shr 16) -band 0xf000
            if (-not $name -or $name.StartsWith('/') -or $name -match '[\x00-\x1f:]' -or
                $name.Length -gt 200 -or $unixType -eq 0xa000 -or
                ($entry.ExternalAttributes -band [int][IO.FileAttributes]::ReparsePoint)) {
                throw 'Unsafe path or symbolic link in launcher archive.'
            }
            foreach ($segment in $segments) {
                if (-not $segment -or $segment -in @('.', '..') -or $segment -match '[. ]$' -or
                    $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
                    throw 'Unsafe Windows filename in launcher archive.'
                }
            }
            if (-not $names.Add($name.TrimEnd('/'))) { throw 'Duplicate path in launcher archive.' }
            $expandedBytes += $entry.Length
            if ($expandedBytes -gt 1073741824) { throw 'Launcher archive exceeds the expanded-size limit.' }
        }
        foreach ($required in @(
                'Connect-LinuxBroker.ps1', 'LinuxBroker.Launcher.exe', 'LinuxBroker.Launcher.dll',
                'LinuxBroker.Launcher.deps.json', 'LinuxBroker.Launcher.runtimeconfig.json',
                'Microsoft.Identity.Client.dll', 'Microsoft.Identity.Client.Broker.dll',
                'Microsoft.Identity.Client.NativeInterop.dll', 'coreclr.dll', 'System.Windows.Forms.dll')) {
            if (-not $names.Contains($required) -or $null -eq $archive.GetEntry($required) -or
                $archive.GetEntry($required).Length -eq 0) {
                throw "Launcher package is missing root-level '$required'. Publish the complete self-contained bundle."
            }
        }
        if ($names.Contains('launcher.json')) { throw 'A preconfigured launcher.json must not be shipped inside the bundle.' }
        if (-not @($names | Where-Object { $_ -ieq 'msalruntime.dll' -or $_ -imatch '^runtimes/win-x64/native/msalruntime\.dll$' }).Count) {
            throw 'Launcher package is missing its Windows x64 WAM runtime.'
        }
        $reader = New-Object IO.StreamReader($archive.GetEntry('LinuxBroker.Launcher.runtimeconfig.json').Open())
        try { $runtime = $reader.ReadToEnd() | ConvertFrom-Json }
        finally { $reader.Dispose() }
        if ($null -eq $runtime.runtimeOptions.PSObject.Properties['includedFrameworks'] -or
            $null -ne $runtime.runtimeOptions.PSObject.Properties['framework'] -or
            $null -ne $runtime.runtimeOptions.PSObject.Properties['frameworks']) {
            throw 'Launcher package must be self-contained; a shared .NET installation must not be required.'
        }
    }
    finally { $archive.Dispose() }
}

function Expand-LauncherArchive {
    param([string]$Path, [string]$Destination)
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $archive.Entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName.Replace('/', '\')))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Archive path escaped the installation directory.' }
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {
                $null = New-Item -ItemType Directory -Path $target -Force
            }
            else {
                $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
            }
        }
    }
    finally { $archive.Dispose() }
}

function Write-LauncherConfiguration {
    param([string]$Directory, [hashtable]$Configuration)
    $path = Join-Path $Directory 'launcher.json'
    $json = $Configuration | ConvertTo-Json -Compress
    if ((Test-Path -LiteralPath $path) -and [IO.File]::ReadAllText($path) -ceq $json) { return }
    $temporary = Join-Path $Directory ('config-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding $false))
        if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temporary, $path, $null) }
        else { [IO.File]::Move($temporary, $path) }
        Set-LauncherAcl $path
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

$principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or -not [Environment]::Is64BitProcess) {
    throw 'Run the launcher installer as Administrator or SYSTEM in 64-bit PowerShell.'
}
$config = @{
    tenantId = Assert-LauncherGuid $TenantId
    authorityHost = Assert-LauncherUrl $AuthorityHost -Authority
    clientId = Assert-LauncherGuid $LauncherClientId
    apiClientId = Assert-LauncherGuid $ApiClientId
    apiBaseUrl = Assert-LauncherUrl $LinuxBrokerApiBaseUrl -Api
}
if ($config.clientId -eq $config.apiClientId) { throw 'Use a dedicated native application, not the API application as the launcher client.' }
if ($PSCmdlet.ParameterSetName -eq 'Download') { $null = Assert-LauncherUrl $PackageUri }
elseif (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) { throw 'The extension-downloaded package is missing.' }
$root = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'LinuxBroker'
$versions = Join-Path $root 'Launcher'
$versionPath = Join-Path $versions $PackageVersion
$staging = Join-Path $versions ('.staging-' + [guid]::NewGuid().ToString('N'))
$download = Join-Path $versions ('.package-' + [guid]::NewGuid().ToString('N') + '.zip')
Assert-LauncherNoReparsePoint $root
foreach ($directory in @($root, $versions, $staging)) {
    $null = New-Item -ItemType Directory -Path $directory -Force
    Set-LauncherAcl $directory
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ($PSCmdlet.ParameterSetName -eq 'Local') {
        Copy-Item -LiteralPath $PackagePath -Destination $download
    }
    else {
        try { Invoke-WebRequest -Uri $PackageUri -OutFile $download -UseBasicParsing -MaximumRedirection 0 }
        catch { throw 'Launcher package download failed. Check its reachability; the URL was not logged.' }
    }
    Test-LauncherArchive -Path $download -Sha256 $PackageSha256
    Expand-LauncherArchive -Path $download -Destination $staging
    foreach ($item in Get-ChildItem -LiteralPath $staging -Recurse -Force) { Set-LauncherAcl $item.FullName }
    if (Test-Path -LiteralPath $versionPath) {
        Assert-LauncherNoReparsePoint $versionPath
        $digestPath = Join-Path $versionPath 'package.sha256'
        if (-not (Test-Path -LiteralPath $digestPath) -or [IO.File]::ReadAllText($digestPath).Trim() -ine $PackageSha256) {
            throw 'That launcher version already exists with a different or incomplete package. Use a new version or explicitly recover the failed installation.'
        }
        foreach ($item in Get-ChildItem -LiteralPath $versionPath -Recurse -Force) { Set-LauncherAcl $item.FullName }
        foreach ($item in Get-ChildItem -LiteralPath $staging -File -Recurse) {
            $relative = $item.FullName.Substring($staging.Length + 1)
            if ($relative -in @('launcher.json', 'package.sha256')) { continue }
            $installed = Join-Path $versionPath $relative
            if (-not (Test-Path -LiteralPath $installed -PathType Leaf) -or
                (Get-FileHash -LiteralPath $installed).Hash -ne (Get-FileHash -LiteralPath $item.FullName).Hash) {
                throw 'Installed launcher files do not match the verified bundle. Refusing to reuse an altered installation.'
            }
        }
        Set-LauncherAcl $versionPath
    }
    else {
        [IO.File]::WriteAllText((Join-Path $staging 'package.sha256'), $PackageSha256.ToLowerInvariant())
        Move-Item -LiteralPath $staging -Destination $versionPath
    }
    Write-LauncherConfiguration -Directory $versionPath -Configuration $config
    $entrypoint = Join-Path $root 'Connect-LinuxBroker.ps1'
    Assert-LauncherNoReparsePoint $entrypoint
    $shim = @'
[CmdletBinding()]
param([ValidateSet('desktop', 'xpra')][string]$Mode = 'desktop')
$ErrorActionPreference = 'Stop'
& "$PSScriptRoot\Launcher\__VERSION__\Connect-LinuxBroker.ps1" -Mode $Mode
'@
    [IO.File]::WriteAllText($entrypoint, $shim.Replace('__VERSION__', $PackageVersion), (New-Object Text.UTF8Encoding $false))
    Set-LauncherAcl $entrypoint
    $shortcutPath = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Linux Broker.lnk'
    Assert-LauncherNoReparsePoint $shortcutPath
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $shortcut.Arguments = '-NoProfile -File "' + $entrypoint + '" -Mode desktop'
        $shortcut.WorkingDirectory = $root
        $shortcut.Description = 'Connect to your own Linux workspace using your Entra account'
        $shortcut.Save()
        Set-LauncherAcl $shortcutPath
    }
    finally { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
    Write-Host "Installed verified Linux Broker launcher $PackageVersion. Use the Linux Broker desktop shortcut."
}
finally {
    if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download -Force }
    if (Test-Path -LiteralPath $staging) {
        Assert-LauncherNoReparsePoint $staging
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
}
