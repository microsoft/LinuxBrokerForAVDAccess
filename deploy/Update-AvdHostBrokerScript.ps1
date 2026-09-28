<#
.SYNOPSIS
    Replaces Connect-LinuxBroker.ps1 on the existing AVD session hosts with the current one.

.DESCRIPTION
    Configure-AVD-Host.ps1 installs Connect-LinuxBroker.ps1 only when a session host is
    provisioned, so session hosts deployed by an earlier release keep the script they were
    deployed with. A script older than 2.0.0 cannot wait while the broker starts a Linux host for
    its user, and shows an error instead.

    Through Run Command, this script downloads Connect-LinuxBroker.ps1 from ScriptSourceRoot onto
    every running AVD session host in the resource group (VMs tagged broker-role=avd-host), fills
    in the broker API's URL and client ID as Configure-AVD-Host.ps1 does, and replaces
    C:\Temp\Connect-LinuxBroker.ps1 in one step, so a user who connects meanwhile runs either the
    old script or the new one.

    Session hosts that are not running are skipped and named at the end: update each one with
    -AvdHostNames once it is started. Every running session host is attempted, and the ones where
    the update failed are reported together at the end, with a non-zero exit code.

    Values that are not given are read from the azd environment. ScriptSourceRoot and the API URL
    are written into PowerShell code, so both must be https:// URLs made only of ASCII letters,
    digits and the characters . - _ ~ % and /, with an optional port.

.EXAMPLE
    .\Update-AvdHostBrokerScript.ps1 -EnvironmentName <environment-name>

.EXAMPLE
    .\Update-AvdHostBrokerScript.ps1 -EnvironmentName <environment-name> -AvdHostNames <session-host>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$ApiBaseUrl,

    [Parameter(Mandatory = $false)]
    [string]$ApiClientId,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$EnvironmentName,

    [Parameter(Mandatory = $false)]
    [string]$ScriptSourceRoot = 'https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/refs/heads/main',

    [Parameter(Mandatory = $false)]
    [string[]]$AvdHostNames
)

$CompletionMarker = 'Updated Connect-LinuxBroker.ps1 on'

function Get-AzdEnvValue {
    param(
        [AllowEmptyString()]
        [string]$EnvironmentName,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
        return ''
    }

    $value = azd env get-value $Key --environment $EnvironmentName 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ''
    }

    return ($value | Out-String).Trim()
}

# A property's value, or $null when the object or the property is missing, which StrictMode
# would otherwise refuse.
function Get-PropertyValue {
    param(
        $InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-VmTagValue {
    param(
        [Parameter(Mandatory = $true)]
        $Vm,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return [string](Get-PropertyValue -InputObject (Get-PropertyValue -InputObject $Vm -Name 'tags') -Name $Name)
}

function ConvertTo-PowerShellLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    return "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Value) + "'"
}

# Whether a URL can be written into PowerShell code without ending the string it is in. Only plain
# ASCII URL characters pass: PowerShell also ends strings at typographic quotes, and Windows
# PowerShell reads a script without a byte order mark in the ANSI code page, where some accented
# letters turn into quotes. The match is case-sensitive, because matching without regard to case
# lets the Kelvin sign through as a k.
function Test-SafeHttpsUrl {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value -cnotmatch '^https://[A-Za-z0-9._-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~%/-]*)?\z') {
        return $false
    }

    # The pattern lets through a port above 65535, which a URI cannot have.
    $uri = $null
    return [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)
}

# The script Run Command runs on each session host, in Windows PowerShell 5.1 as SYSTEM.
function Get-AvdHostUpdateScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceUrl,

        [Parameter(Mandatory = $true)]
        [string]$ApiBaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$ApiClientId,

        [Parameter(Mandatory = $false)]
        [string]$Destination = 'C:\Temp\Connect-LinuxBroker.ps1'
    )

    $template = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$sourceUrl = __SOURCE_URL__
$apiBaseUrl = __API_BASE_URL__
$apiClientId = __API_CLIENT_ID__
$destination = __DESTINATION__

$baseUrlPlaceholder = 'https://your_linuxbroker_api_base_url/api'
$clientIdPlaceholder = 'your_linuxbroker_api_client_id'

function Get-BrokerScriptVersion {
    param([string]$Text)

    $match = [regex]::Match($Text, '(?m)^\$ScriptVersion = ''([^'']+)''')
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return $null
}

$folder = Split-Path -Parent $destination
if (-not (Test-Path -LiteralPath $folder)) {
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
}

$previous = 'no script'
if (Test-Path -LiteralPath $destination) {
    $previous = Get-BrokerScriptVersion ([System.IO.File]::ReadAllText($destination))
    if (-not $previous) {
        $previous = 'a script without a version'
    }
}

$staged = '{0}.{1}.download' -f $destination, [guid]::NewGuid().ToString('N')
try {
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            Invoke-WebRequest -Uri $sourceUrl -OutFile $staged -UseBasicParsing
            break
        }
        catch {
            if ($attempt -ge 3) {
                throw "Could not download $sourceUrl after $attempt attempts: $($_.Exception.Message)"
            }
            Start-Sleep -Seconds (2 * $attempt)
        }
    }

    $text = [System.IO.File]::ReadAllText($staged)
    $version = Get-BrokerScriptVersion $text
    if (-not $version -or -not $text.Contains($baseUrlPlaceholder) -or -not $text.Contains($clientIdPlaceholder)) {
        throw "$sourceUrl is not a Connect-LinuxBroker.ps1 that this update can install."
    }

    $text = $text.Replace($baseUrlPlaceholder, $apiBaseUrl).Replace($clientIdPlaceholder, $apiClientId)

    # The script is written without a byte order mark, which Windows PowerShell reads in the ANSI
    # code page, so any character outside ASCII could read differently, even as a quote.
    if ($text -cmatch '[^\x00-\x7F]') {
        throw "Connect-LinuxBroker.ps1 $version holds characters outside ASCII, which Windows PowerShell could misread."
    }

    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) {
        throw "Connect-LinuxBroker.ps1 $version does not parse once the API URL and client ID are filled in: $($parseErrors[0].Message)"
    }

    # Without a byte order mark, as Configure-AVD-Host.ps1 writes it.
    [System.IO.File]::WriteAllText($staged, $text, (New-Object System.Text.UTF8Encoding -ArgumentList $false))

    # In one step, so a user who connects meanwhile runs either the old script or the new one.
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            if (Test-Path -LiteralPath $destination) {
                [System.IO.File]::Replace($staged, $destination, [NullString]::Value)
            }
            else {
                [System.IO.File]::Move($staged, $destination)
            }
            break
        }
        catch {
            if ($attempt -ge 5) {
                throw "Could not replace ${destination}: $($_.Exception.Message)"
            }
            Start-Sleep -Seconds 1
        }
    }
}
finally {
    Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
}

Unblock-File -LiteralPath $destination
if ((Get-BrokerScriptVersion ([System.IO.File]::ReadAllText($destination))) -ne $version) {
    throw "$destination does not hold Connect-LinuxBroker.ps1 $version after the update."
}

# Configure-AVD-Host.ps1 creates the event source the script logs to, and installs the module it
# saves the Linux host's credentials with.
try {
    if (-not [System.Diagnostics.EventLog]::SourceExists('LinuxBrokerScript')) {
        New-EventLog -LogName Application -Source 'LinuxBrokerScript'
    }
}
catch {
    Write-Output "WARNING: The LinuxBrokerScript event source could not be created, so Connect-LinuxBroker.ps1 cannot log: $($_.Exception.Message)"
}

if (-not (Get-Module -ListAvailable -Name CredentialManager)) {
    Write-Output 'WARNING: The CredentialManager module is not installed, so Connect-LinuxBroker.ps1 cannot save the Linux host credentials. Install it with Install-Module CredentialManager -Scope AllUsers.'
}

Write-Output ('Updated Connect-LinuxBroker.ps1 on {0} from {1} to {2}.' -f $env:COMPUTERNAME, $previous, $version)
'@

    $values = @{
        SOURCE_URL    = ConvertTo-PowerShellLiteral -Value $SourceUrl
        API_BASE_URL  = ConvertTo-PowerShellLiteral -Value $ApiBaseUrl
        API_CLIENT_ID = ConvertTo-PowerShellLiteral -Value $ApiClientId
        DESTINATION   = ConvertTo-PowerShellLiteral -Value $Destination
    }

    # In one pass, so a value that happens to contain a token is not replaced again.
    return [regex]::Replace($template, '__(SOURCE_URL|API_BASE_URL|API_CLIENT_ID|DESTINATION)__', {
            param($match)
            $values[$match.Groups[1].Value]
        })
}

# Returns what the script wrote to standard output and standard error on the session host.
function Invoke-RunCommandWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [string]$Script,

        [Parameter(Mandatory = $false)]
        [int]$MaxAttempts = 3,

        [Parameter(Mandatory = $false)]
        [int]$InitialDelaySeconds = 5
    )

    $lastError = ''

    # The script reaches az as @file. Passed inline, on Windows it goes through az.cmd, where
    # cmd.exe ends the command at the first newline, and the session host runs only the first line.
    $scriptFile = Join-Path ([System.IO.Path]::GetTempPath()) ('linuxbroker-avd-update-{0}.ps1' -f [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($scriptFile, $Script, (New-Object System.Text.UTF8Encoding -ArgumentList $false))

    try {
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            $output = @(az vm run-command invoke `
                    --resource-group $ResourceGroupName `
                    --name $VmName `
                    --command-id RunPowerShellScript `
                    --scripts "@$scriptFile" `
                    --output json `
                    --only-show-errors 2>&1)
            $exitCode = $LASTEXITCODE
            $errorText = (@($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
            $json = (@($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }) -join "`n").Trim()

            if ($exitCode -eq 0) {
                try {
                    $result = ConvertFrom-Json -InputObject $json
                }
                catch {
                    throw "Run Command on '$VmName' returned output that is not JSON: $json"
                }

                $standardOutput = New-Object System.Collections.Generic.List[string]
                $standardError = New-Object System.Collections.Generic.List[string]
                foreach ($status in @(Get-PropertyValue -InputObject $result -Name 'value')) {
                    $message = [string](Get-PropertyValue -InputObject $status -Name 'message')
                    if ([string](Get-PropertyValue -InputObject $status -Name 'code') -like '*StdErr*') {
                        $standardError.Add($message)
                    }
                    else {
                        $standardOutput.Add($message)
                    }
                }

                return [pscustomobject]@{
                    StdOut = ($standardOutput -join "`n").Trim()
                    StdErr = ($standardError -join "`n").Trim()
                }
            }

            $lastError = $errorText
            if ($attempt -ge $MaxAttempts) {
                break
            }

            $delaySeconds = [Math]::Min($InitialDelaySeconds * [Math]::Pow(2, $attempt - 1), 30)
            Write-Warning "Run Command failed on '$VmName' attempt $attempt of $MaxAttempts. Retrying in $([int]$delaySeconds) seconds."
            if (-not [string]::IsNullOrWhiteSpace($lastError)) {
                Write-Warning $lastError
            }

            Start-Sleep -Seconds ([int]$delaySeconds)
        }
    }
    finally {
        Remove-Item -LiteralPath $scriptFile -Force -ErrorAction SilentlyContinue
    }

    if ([string]::IsNullOrWhiteSpace($lastError)) {
        throw "Run Command failed on '$VmName'."
    }

    throw "Run Command failed on '$VmName'. Last error: $lastError"
}

function Invoke-AvdHostBrokerScriptUpdate {
    param(
        [string]$ResourceGroupName,
        [string]$ApiBaseUrl,
        [string]$ApiClientId,
        [string]$SubscriptionId,
        [string]$EnvironmentName,
        [string]$ScriptSourceRoot = 'https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/refs/heads/main',
        [string[]]$AvdHostNames
    )

    if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
        $EnvironmentName = if (-not [string]::IsNullOrWhiteSpace($env:AZURE_ENV_NAME)) {
            $env:AZURE_ENV_NAME
        }
        elseif (-not [string]::IsNullOrWhiteSpace($env:AZURE_ENVIRONMENT_NAME)) {
            $env:AZURE_ENVIRONMENT_NAME
        }
        else {
            ''
        }
    }

    if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
        $ResourceGroupName = Get-AzdEnvValue -EnvironmentName $EnvironmentName -Key 'resourceGroupName'
    }

    if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $SubscriptionId = Get-AzdEnvValue -EnvironmentName $EnvironmentName -Key 'AZURE_SUBSCRIPTION_ID'
    }

    if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $SubscriptionId = $env:AZURE_SUBSCRIPTION_ID
    }

    if ([string]::IsNullOrWhiteSpace($ApiBaseUrl)) {
        $ApiBaseUrl = Get-AzdEnvValue -EnvironmentName $EnvironmentName -Key 'apiUrl'
    }

    if ([string]::IsNullOrWhiteSpace($ApiClientId)) {
        $ApiClientId = Get-AzdEnvValue -EnvironmentName $EnvironmentName -Key 'apiClientId'
    }

    if ([string]::IsNullOrWhiteSpace($ResourceGroupName) -or [string]::IsNullOrWhiteSpace($ApiBaseUrl) -or [string]::IsNullOrWhiteSpace($ApiClientId)) {
        throw 'The AVD session host update needs ResourceGroupName, ApiBaseUrl and ApiClientId, as parameters or azd environment values.'
    }

    # The API URL and client ID end up inside double-quoted strings in Connect-LinuxBroker.ps1, and
    # the source URL in the script Run Command runs as SYSTEM.
    $ApiBaseUrl = $ApiBaseUrl.Trim().TrimEnd('/')
    if (-not (Test-SafeHttpsUrl -Value $ApiBaseUrl)) {
        throw "ApiBaseUrl must be the broker API's https:// URL, such as https://<api-host>/api, not '$ApiBaseUrl'."
    }

    $ApiClientId = $ApiClientId.Trim()
    $parsedClientId = [guid]::Empty
    if (-not [guid]::TryParseExact($ApiClientId, 'D', [ref]$parsedClientId)) {
        throw "ApiClientId must be the broker API app registration's client ID, a GUID, not '$ApiClientId'."
    }

    $ScriptSourceRoot = ([string]$ScriptSourceRoot).Trim().TrimEnd('/')
    if (-not (Test-SafeHttpsUrl -Value $ScriptSourceRoot)) {
        throw "ScriptSourceRoot must be the https:// URL of the repository or of a mirror of it, such as https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/refs/heads/main, not '$ScriptSourceRoot'."
    }

    $sourceUrl = "$ScriptSourceRoot/avd_host/broker/Connect-LinuxBroker.ps1"

    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        az account set --subscription $SubscriptionId | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not select subscription '$SubscriptionId'."
        }
    }

    $vmJson = (@(az vm list --resource-group $ResourceGroupName --show-details --output json --only-show-errors) -join "`n")
    if ($LASTEXITCODE -ne 0) {
        throw "Could not list the VMs in resource group '$ResourceGroupName'."
    }

    $avdHosts = @(ConvertFrom-Json -InputObject $vmJson | ForEach-Object { $_ } |
            Where-Object { (Get-VmTagValue -Vm $_ -Name 'broker-role') -eq 'avd-host' })

    if ($avdHosts.Count -eq 0) {
        Write-Host "No AVD session host VMs found in resource group '$ResourceGroupName'."
        return
    }

    if ($AvdHostNames -and $AvdHostNames.Count -gt 0) {
        $requestedNames = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in $AvdHostNames) {
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                [void]$requestedNames.Add($name.Trim())
            }
        }

        $filteredHosts = @($avdHosts | Where-Object { $requestedNames.Contains([string]$_.name) })
        foreach ($name in $requestedNames) {
            if (-not ($filteredHosts | Where-Object { $_.name -eq $name })) {
                Write-Warning "Requested AVD session host '$name' was not found in resource group '$ResourceGroupName'."
            }
        }

        $avdHosts = $filteredHosts
    }

    if ($avdHosts.Count -eq 0) {
        Write-Host 'No AVD session hosts matched the requested update scope.'
        return
    }

    $remoteScript = Get-AvdHostUpdateScript -SourceUrl $sourceUrl -ApiBaseUrl $ApiBaseUrl -ApiClientId $ApiClientId

    # One session host that is off or failing must not leave the rest on the old script, so every
    # one is attempted and the failures are reported together at the end.
    $updated = New-Object System.Collections.Generic.List[string]
    $failures = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]

    foreach ($avdHost in $avdHosts) {
        $name = [string]$avdHost.name
        $powerState = [string](Get-PropertyValue -InputObject $avdHost -Name 'powerState')
        if (-not [string]::IsNullOrWhiteSpace($powerState) -and $powerState -notmatch 'running') {
            Write-Warning "Skipping AVD session host '$name' because it is not running ($powerState). Start it and run this script again with -AvdHostNames $name."
            $skipped.Add($name)
            continue
        }

        Write-Host "Updating Connect-LinuxBroker.ps1 on AVD session host '$name'..."
        try {
            $output = Invoke-RunCommandWithRetry -ResourceGroupName $ResourceGroupName -VmName $name -Script $remoteScript
            if (-not [string]::IsNullOrWhiteSpace($output.StdOut)) {
                Write-Host $output.StdOut
            }
            # Run Command reports success whatever the script did, so the script's own closing
            # line is the only evidence that it ran to the end.
            if ($output.StdOut -notmatch [regex]::Escape($CompletionMarker)) {
                $detail = if ([string]::IsNullOrWhiteSpace($output.StdErr)) { '' } else { " $($output.StdErr)" }
                throw "The update did not run to completion on '$name'.$detail"
            }
            $updated.Add($name)
        }
        catch {
            Write-Warning $_.Exception.Message
            $failures.Add($name)
        }
    }

    if ($skipped.Count -gt 0) {
        Write-Warning "Not updated because they are not running: $($skipped -join ', ')."
    }

    if ($failures.Count -gt 0) {
        throw "The Connect-LinuxBroker.ps1 update failed on: $($failures -join ', '). Rerun with -AvdHostNames to retry them."
    }

    Write-Host "Connect-LinuxBroker.ps1 is up to date on $($updated.Count) AVD session host(s)."
}

# Dot-sourcing the script, as its tests do, defines the functions without running the update.
if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    Invoke-AvdHostBrokerScriptUpdate `
        -ResourceGroupName $ResourceGroupName `
        -ApiBaseUrl $ApiBaseUrl `
        -ApiClientId $ApiClientId `
        -SubscriptionId $SubscriptionId `
        -EnvironmentName $EnvironmentName `
        -ScriptSourceRoot $ScriptSourceRoot `
        -AvdHostNames $AvdHostNames
}
