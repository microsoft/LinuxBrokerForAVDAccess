#Requires -Version 5.1
[CmdletBinding()]
param (
    [Parameter(HelpMessage = 'Only desktop is implemented. Xpra/application modes are not supported.')]
    [string]$Mode = 'desktop',

    [string]$LauncherPath = (Join-Path $PSScriptRoot 'LinuxBroker.Launcher.exe'),

    [string]$ConfigPath = (Join-Path $PSScriptRoot 'launcher.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Mode -ine 'desktop') {
    Write-Error 'Only desktop mode is supported. Xpra/application modes are not implemented; no sign-in or checkout was attempted.' -ErrorAction Continue
    exit 13
}

try {
    foreach ($path in @($LauncherPath, $ConfigPath)) {
        if ($path -notmatch '^[a-zA-Z]:\\' -or $path -match '["\x00-\x1f]' -or
            -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Write-Error 'The installed launcher executable and launcher.json must exist at absolute local Windows paths. Contact your administrator.' -ErrorAction Continue
            exit 2
        }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = [System.IO.Path]::GetFullPath($LauncherPath)
    $startInfo.WorkingDirectory = [System.IO.Path]::GetDirectoryName($startInfo.FileName)
    $startInfo.UseShellExecute = $false
    $startInfo.Arguments = '--config "{0}" --mode desktop' -f [System.IO.Path]::GetFullPath($ConfigPath)
    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        throw [System.InvalidOperationException]::new('The launcher did not start.')
    }
    try {
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }
    if ($exitCode -ne 0) {
        Write-Error "Linux workspace launcher stopped with status $exitCode. See its sign-in/connection window or the installed README for details." -ErrorAction Continue
    }
    exit $exitCode
}
catch {
    Write-Error 'The Linux workspace launcher could not start. Check the installed bundle, configuration, and application-control policy with your administrator.' -ErrorAction Continue
    exit 11
}
