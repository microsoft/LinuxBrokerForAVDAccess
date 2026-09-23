#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$brokerDirectory = Split-Path -Parent $PSScriptRoot
$scripts = @(
    (Join-Path $brokerDirectory 'Connect-LinuxBroker.ps1'),
    (Join-Path $brokerDirectory 'Publish-Launcher.ps1'),
    $PSCommandPath
)

foreach ($script in $scripts) {
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -ne 0) {
        throw "PowerShell parser errors in ${script}: $($parseErrors.Message -join '; ')"
    }
}

function Test-WrapperFailure {
    param([string]$Mode, [int]$ExpectedExit, [string]$ExpectedText)

    $wrapper = Join-Path $brokerDirectory 'Connect-LinuxBroker.ps1'
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Arguments = '-NoLogo -NoProfile -NonInteractive -File "{0}" -Mode "{1}" -LauncherPath "C:\missing-launcher-test\LinuxBroker.Launcher.exe" -ConfigPath "C:\missing-launcher-test\launcher.json"' -f $wrapper, $Mode
    $process = [System.Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill()
            throw 'The wrapper failure test did not terminate.'
        }
        $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        $normalizedOutput = [regex]::Replace($output, '\s+', ' ')
        if ($process.ExitCode -ne $ExpectedExit -or $normalizedOutput -notmatch [regex]::Escape($ExpectedText)) {
            throw "Wrapper test failed: expected exit $ExpectedExit and '$ExpectedText'; got $($process.ExitCode). $output"
        }
    }
    finally {
        $process.Dispose()
    }
}

Test-WrapperFailure -Mode 'xpra' -ExpectedExit 13 -ExpectedText 'Only desktop mode is supported'
Test-WrapperFailure -Mode 'xterm' -ExpectedExit 13 -ExpectedText 'Only desktop mode is supported'
Test-WrapperFailure -Mode 'desktop' -ExpectedExit 2 -ExpectedText 'must exist at absolute local Windows paths'
Write-Host 'PowerShell validation passed: 3 scripts parsed; unsupported modes and missing installation fail before authentication.'
