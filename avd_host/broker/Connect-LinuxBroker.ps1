<#
.SYNOPSIS
    Checks out a Linux host from the Linux Broker and opens a Remote Desktop session to it.

.DESCRIPTION
    The Linux Desktop RemoteApp runs this script on the AVD session host, in the user's session.
    The session host's managed identity authenticates it to the broker API.

    When no host is ready, the broker can start one and answer 202. The script then shows a
    window saying the desktop is starting, with Cancel, and asks again when the broker says to,
    until a host is ready, the user cancels, or MaxWaitSeconds pass.

    The desktop opens full screen across every monitor, unless FullScreen or MultiMonitor is
    Off. The script starts mstsc with switches rather than a connection file, because since the
    April 2026 update Remote Desktop Connection asks the user about every unsigned .rdp file and
    turns its redirections off, the clipboard included.

    Configure-AVD-Host.ps1 installs the script at C:\Temp\Connect-LinuxBroker.ps1 when the
    session host is provisioned, and deploy/Update-AvdHostBrokerScript.ps1 replaces it on
    existing session hosts. Both fill in the broker API's URL and client ID.
#>
param (
    [Parameter(Mandatory = $false, HelpMessage = "Only 'desktop' is supported, which opens a Remote Desktop session to a Linux host. Any other value opens the desktop too.")]
    [string]$Mode = "desktop",

    [Parameter(Mandatory = $false, HelpMessage = "How long to wait, in seconds, for a Linux host that the broker starts because none is ready. 0 does not wait.")]
    [ValidateRange(0, 3600)]
    [int]$MaxWaitSeconds = 600,

    [Parameter(Mandatory = $false, HelpMessage = "On opens the Linux desktop full screen. Off opens it in a window on one monitor, whatever MultiMonitor says.")]
    [ValidateSet('On', 'Off')]
    [string]$FullScreen = 'On',

    [Parameter(Mandatory = $false, HelpMessage = "On spreads a full-screen Linux desktop across every monitor. Off keeps it on one monitor.")]
    [ValidateSet('On', 'Off')]
    [string]$MultiMonitor = 'On'
)

# Sent with every checkout, so the scaling policy page can list the session hosts whose script
# cannot wait for a host to start. AVD_HOST_SCRIPT_VERSION in api/config.py must match: bump
# both with any change to this script.
$ScriptVersion = '2.0.0'

$ProgressPreference = 'SilentlyContinue'

# Filled in when the script is installed on the session host.
$apiBaseUrl = "https://your_linuxbroker_api_base_url/api"
$apiAppIdUri = "api://your_linuxbroker_api_client_id"

$sourceName = "LinuxBrokerScript" # The source name for your event log.
$logName = "Application" # The log where your source will write events. Commonly "Application".

# A checkout that provisions the user on the Linux host can take a while.
$RequestTimeoutSeconds = 120
# A request that gets no answer, 408, 429 or a 5xx is tried again, until this many fail in a row.
$MaxTransientFailures = 3
$TransientRetrySeconds = 5
# The broker counts a user as waiting for five minutes after its last 202, so the script always
# asks again well within that.
$MinRetrySeconds = 5
$MaxRetrySeconds = 120
# Used when a 202 does not say how long to wait: 30, 30, then 60 seconds from then on.
$FallbackRetrySeconds = @(30, 30, 60)

$OutcomeMessages = @{
    NoHost      = @{ Text = "No Linux host is available right now. Try again in a few minutes."; Icon = "Warning" }
    Starting    = @{ Text = "A Linux host is starting for you. Try again in a few minutes."; Icon = "Information" }
    TimedOut    = @{ Text = "Your Linux desktop is taking longer than usual to start. Try again in a few minutes."; Icon = "Warning" }
    AuthFailed  = @{ Text = "The Linux Broker could not authenticate this session host. Contact your administrator."; Icon = "Error" }
    Unavailable = @{ Text = "The Linux Broker is not responding. Try again in a few minutes, or contact your administrator."; Icon = "Error" }
    Rejected    = @{ Text = "The Linux Broker could not give you a Linux host. Contact your administrator."; Icon = "Error" }
}

function Write-Log {
    param (
        [string]$Message,
        [ValidateSet("INFO", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )

    # Write-EventLog only accepts EventLogEntryType names, so map the short level names onto them.
    $entryType = switch ($Level) {
        "WARNING" { "Warning" }
        "ERROR" { "Error" }
        default { "Information" }
    }

    try {
        Write-EventLog -LogName $logName -Source $sourceName -EntryType $entryType -EventId 1 -Message $Message -ErrorAction Stop
    }
    catch {
        # Logging must never stop the connection attempt.
        $null = $_
    }
}

# The RemoteApp runs without a visible console, so problems the user can act on are shown in a dialog.
function Show-UserMessage {
    param (
        [string]$Message,
        [ValidateSet("Information", "Warning", "Error")]
        [string]$Icon = "Information"
    )

    $iconFlag = switch ($Icon) {
        "Warning" { 48 }
        "Error" { 16 }
        default { 64 }
    }

    try {
        (New-Object -ComObject WScript.Shell).Popup($Message, 0, "Linux Desktop", $iconFlag) | Out-Null
    }
    catch {
        Write-Log "Failed to show message to the user: $_" "WARNING"
    }
}

# Function to obtain access token using Managed Identity via IMDS
function Get-AccessToken {
    param (
        [string]$Resource
    )

    $imdsEndpoint = "http://169.254.169.254/metadata/identity/oauth2/token"
    $apiVersion = "2018-02-01"
    $uri = $imdsEndpoint + "?api-version=$apiVersion&resource=$Resource"

    $headers = @{
        "Metadata" = "true"
    }

    try {
        Write-Log "Requesting access token for resource: $Resource" "INFO"
        $response = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers
        Write-Log "Access token obtained successfully." "INFO"
        return $response.access_token
    }
    catch {
        Write-Log "Failed to obtain access token: $_" "ERROR"
        return $null
    }
}

# Seconds on a clock that is not moved by changes to the system time.
function Get-MonotonicTime {
    return [System.Diagnostics.Stopwatch]::GetTimestamp() / [double][System.Diagnostics.Stopwatch]::Frequency
}

# The whole number of seconds in a Retry-After value, or $null when it holds none.
function ConvertTo-RetryAfter {
    param (
        $Value
    )

    if ($Value -is [array]) {
        $Value = $Value | Select-Object -First 1
    }
    if ($null -eq $Value) {
        return $null
    }

    $seconds = 0
    if ([int]::TryParse(([string]$Value).Trim(), [ref]$seconds)) {
        return $seconds
    }
    return $null
}

# How long to wait before asking again: what the broker asked for, within limits, or the
# fallback schedule when it asked for nothing.
function Get-RetryDelay {
    param (
        $RetryAfter,
        [int]$WaitCount = 0
    )

    if ($null -ne $RetryAfter) {
        return [int][Math]::Min($MaxRetrySeconds, [Math]::Max($MinRetrySeconds, [int]$RetryAfter))
    }

    $index = [Math]::Min([Math]::Max($WaitCount, 0), $FallbackRetrySeconds.Count - 1)
    return [int]$FallbackRetrySeconds[$index]
}

function Test-TransientFailure {
    param (
        [int]$StatusCode
    )

    return ($StatusCode -eq 0 -or $StatusCode -eq 408 -or $StatusCode -eq 429 -or ($StatusCode -ge 500 -and $StatusCode -le 599))
}

function New-BrokerHttpClient {
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds($RequestTimeoutSeconds)
    $client.DefaultRequestHeaders.ExpectContinue = $false
    return $client
}

# A small window that tells the user their desktop is starting, with Cancel. It is modeless:
# the script keeps working and pumps its messages. Returns $null when it cannot be shown, and
# the wait goes on without it.
function Open-WaitWindow {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        [System.Windows.Forms.Application]::EnableVisualStyles()

        $state = [pscustomobject]@{
            Form      = $null
            Cancelled = $false
            Closing   = $false
        }

        $form = New-Object System.Windows.Forms.Form
        $form.Text = "Linux Desktop"
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.MaximizeBox = $false
        $form.ShowInTaskbar = $true
        $form.AutoSize = $true
        $form.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
        $form.Font = [System.Drawing.SystemFonts]::MessageBoxFont

        $panel = New-Object System.Windows.Forms.FlowLayoutPanel
        $panel.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
        $panel.WrapContents = $false
        $panel.AutoSize = $true
        $panel.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
        $panel.Padding = New-Object System.Windows.Forms.Padding -ArgumentList 16

        $heading = New-Object System.Windows.Forms.Label
        $heading.AutoSize = $true
        $heading.MaximumSize = New-Object System.Drawing.Size -ArgumentList 360, 0
        $heading.Font = New-Object System.Drawing.Font -ArgumentList $form.Font, ([System.Drawing.FontStyle]::Bold)
        $heading.Text = "Your Linux desktop is starting" + [char]0x2026

        $detail = New-Object System.Windows.Forms.Label
        $detail.AutoSize = $true
        $detail.MaximumSize = New-Object System.Drawing.Size -ArgumentList 360, 0
        $detail.Margin = New-Object System.Windows.Forms.Padding -ArgumentList 3, 8, 3, 12
        $detail.Text = "This can take a few minutes. It opens by itself when it is ready."

        $progress = New-Object System.Windows.Forms.ProgressBar
        $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        $progress.MarqueeAnimationSpeed = 30
        $progress.Width = 360
        $progress.AccessibleName = "Waiting for your Linux desktop"

        $cancel = New-Object System.Windows.Forms.Button
        $cancel.Text = "Cancel"
        $cancel.AutoSize = $true
        $cancel.Anchor = [System.Windows.Forms.AnchorStyles]::Right
        $cancel.Margin = New-Object System.Windows.Forms.Padding -ArgumentList 3, 12, 3, 3
        $cancel.Add_Click({ $state.Cancelled = $true; $state.Form.Close() }.GetNewClosure())

        $panel.Controls.AddRange(@($heading, $detail, $progress, $cancel))
        $form.Controls.Add($panel)
        $form.CancelButton = $cancel
        # Closing the window any way but from the script cancels the wait too.
        $form.Add_FormClosing({ if (-not $state.Closing) { $state.Cancelled = $true } }.GetNewClosure())

        $state.Form = $form
        $form.Show()
        $form.Activate()
        [System.Windows.Forms.Application]::DoEvents()
        return $state
    }
    catch {
        Write-Log "The wait window could not be shown: $_" "WARNING"
        return $null
    }
}

function Close-WaitWindow {
    param (
        $WaitWindow
    )

    if ($null -eq $WaitWindow -or $null -eq $WaitWindow.Form) {
        return
    }

    try {
        $WaitWindow.Closing = $true
        if (-not $WaitWindow.Form.IsDisposed) {
            $WaitWindow.Form.Close()
            $WaitWindow.Form.Dispose()
        }
    }
    catch {
        Write-Log "The wait window could not be closed: $_" "WARNING"
    }
}

# Handles the wait window's pending messages, so it repaints and Cancel works.
function Invoke-WindowMessagePump {
    param (
        $WaitWindow
    )

    if ($null -eq $WaitWindow) {
        return
    }

    try {
        [System.Windows.Forms.Application]::DoEvents()
    }
    catch {
        Write-Log "The wait window stopped responding: $_" "WARNING"
    }
}

# Waits the given number of seconds, keeping the wait window responsive. Returns $false as soon
# as the user cancels.
function Wait-CheckoutInterval {
    param (
        [double]$Seconds,
        $WaitWindow
    )

    $until = (Get-MonotonicTime) + $Seconds
    while ((Get-MonotonicTime) -lt $until) {
        if ($null -ne $WaitWindow -and $WaitWindow.Cancelled) {
            return $false
        }
        Invoke-WindowMessagePump -WaitWindow $WaitWindow
        Start-Sleep -Milliseconds 100
    }

    return -not ($null -ne $WaitWindow -and $WaitWindow.Cancelled)
}

# Posts one checkout request. Returns its status code (0 when no answer came), the parsed body,
# the wait a Retry-After asks for, and the error. While the wait window is open it stays
# responsive, and Cancel abandons the request.
function Invoke-BrokerCheckout {
    param (
        [Parameter(Mandatory = $true)]
        $Client,

        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$AccessToken,

        [Parameter(Mandatory = $true)]
        [hashtable]$Body,

        $WaitWindow
    )

    $result = [pscustomobject]@{
        StatusCode = 0
        Body       = $null
        RetryAfter = $null
        Error      = $null
        Cancelled  = $false
    }

    $request = $null
    $response = $null
    $cancellation = New-Object System.Threading.CancellationTokenSource
    try {
        $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList ([System.Net.Http.HttpMethod]::Post), $Url
        $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue -ArgumentList "Bearer", $AccessToken
        $request.Content = New-Object System.Net.Http.StringContent -ArgumentList ($Body | ConvertTo-Json -Compress), ([System.Text.Encoding]::UTF8), "application/json"

        $task = $Client.SendAsync($request, $cancellation.Token)
        while (-not $task.IsCompleted) {
            if ($null -ne $WaitWindow -and $WaitWindow.Cancelled) {
                $cancellation.Cancel()
                $result.Cancelled = $true
                return $result
            }
            Invoke-WindowMessagePump -WaitWindow $WaitWindow
            try {
                [void]$task.Wait(100)
            }
            catch {
                # A failed request is reported from the task below.
                $null = $_
            }
        }

        if ($task.IsCanceled) {
            $result.Error = "The broker did not answer within $RequestTimeoutSeconds seconds."
            return $result
        }
        if ($task.IsFaulted) {
            $result.Error = $task.Exception.GetBaseException().Message
            return $result
        }

        $response = $task.Result
        $result.StatusCode = [int]$response.StatusCode
        $retryHeader = $response.Headers.RetryAfter
        if ($null -ne $retryHeader -and $null -ne $retryHeader.Delta) {
            $result.RetryAfter = [int][Math]::Ceiling($retryHeader.Delta.TotalSeconds)
        }

        $text = $response.Content.ReadAsStringAsync().Result
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            try {
                $result.Body = $text | ConvertFrom-Json
            }
            catch {
                $result.Error = "The broker's answer was not JSON."
            }
        }

        if ($null -ne $result.Body) {
            $bodyRetryAfter = ConvertTo-RetryAfter $result.Body.retryAfterSeconds
            if ($null -ne $bodyRetryAfter) {
                $result.RetryAfter = $bodyRetryAfter
            }
            if ($result.Body.error) {
                $result.Error = [string]$result.Body.error
            }
        }

        return $result
    }
    catch {
        $result.Error = $_.Exception.Message
        return $result
    }
    finally {
        if ($null -ne $response) {
            $response.Dispose()
        }
        if ($null -ne $request) {
            $request.Dispose()
        }
        $cancellation.Dispose()
    }
}

function New-CheckoutResult {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet("Assigned", "NoHost", "Starting", "TimedOut", "Cancelled", "AuthFailed", "Unavailable", "Rejected")]
        [string]$Outcome,

        $Checkout = $null
    )

    return [pscustomobject]@{
        Outcome  = $Outcome
        Checkout = $Checkout
    }
}

# Checks out a Linux host for the user. While the broker answers 202 because a host is starting,
# shows the wait window and asks again when the broker says to, until a host is ready, the user
# cancels, or MaxWaitSeconds pass. Returns the outcome, with the checkout when a host was assigned.
function Request-LinuxHost {
    param (
        [Parameter(Mandatory = $true)]
        [string]$CheckoutUrl,

        [Parameter(Mandatory = $true)]
        [string]$Resource,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Username,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$AvdHost,

        [int]$MaxWaitSeconds = 600
    )

    $accessToken = Get-AccessToken -Resource $Resource
    if (-not $accessToken) {
        Write-Log "Unable to obtain access token. Exiting script." "ERROR"
        return New-CheckoutResult -Outcome AuthFailed
    }

    $body = @{
        username      = $Username
        avdhost       = $AvdHost
        clientVersion = $ScriptVersion
    }

    $client = New-BrokerHttpClient
    $waitWindow = $null
    $deadline = $null
    $waits = 0
    $failures = 0
    $tokenRenewed = $false
    $attempt = 0

    try {
        while ($true) {
            $attempt++
            Write-Log "Checkout attempt $attempt for $Username from $AvdHost." "INFO"
            $response = Invoke-BrokerCheckout -Client $client -Url $CheckoutUrl -AccessToken $accessToken -Body $body -WaitWindow $waitWindow

            if ($response.Cancelled) {
                Write-Log "$Username cancelled the wait for a Linux host." "INFO"
                return New-CheckoutResult -Outcome Cancelled
            }

            $status = $response.StatusCode
            $checkout = $response.Body

            if ($status -eq 200) {
                if ($null -ne $checkout -and $checkout.VMID -and $checkout.IPAddress) {
                    Write-Log "Successfully checked out or retrieved an existing VM (VMID: $($checkout.VMID), Hostname: $($checkout.Hostname))." "INFO"
                    return New-CheckoutResult -Outcome Assigned -Checkout $checkout
                }
                Write-Log "The checkout answered without a VMID or IP address." "ERROR"
                return New-CheckoutResult -Outcome Rejected
            }

            if ($status -eq 202) {
                $failures = 0
                Write-Log "No Linux host is ready yet ($($checkout.reason)): $($checkout.message)" "INFO"
                if ($MaxWaitSeconds -le 0) {
                    return New-CheckoutResult -Outcome Starting
                }

                $now = Get-MonotonicTime
                if ($null -eq $deadline) {
                    $deadline = $now + $MaxWaitSeconds
                }
                $remaining = $deadline - $now
                if ($remaining -le 0) {
                    Write-Log "No Linux host was ready within $MaxWaitSeconds seconds." "WARNING"
                    return New-CheckoutResult -Outcome TimedOut
                }

                $delay = [Math]::Min((Get-RetryDelay -RetryAfter $response.RetryAfter -WaitCount $waits), [Math]::Ceiling($remaining))
                $waits++
                if ($null -eq $waitWindow) {
                    $waitWindow = Open-WaitWindow
                }
                Write-Log "Asking again in $delay seconds." "INFO"
                if (-not (Wait-CheckoutInterval -Seconds $delay -WaitWindow $waitWindow)) {
                    Write-Log "$Username cancelled the wait for a Linux host." "INFO"
                    return New-CheckoutResult -Outcome Cancelled
                }
                continue
            }

            if ($status -eq 409) {
                Write-Log "No available or checked-out VM found: $($response.Error)" "WARNING"
                return New-CheckoutResult -Outcome NoHost
            }

            # A token can expire while the user waits, so a refused one is renewed once.
            if ($status -eq 401 -and -not $tokenRenewed) {
                $tokenRenewed = $true
                Write-Log "The broker did not accept the access token, so a new one is requested." "WARNING"
                $accessToken = Get-AccessToken -Resource $Resource
                if ($accessToken) {
                    continue
                }
                return New-CheckoutResult -Outcome AuthFailed
            }

            if ($status -eq 401 -or $status -eq 403) {
                Write-Log "The broker refused this session host ($status): $($response.Error)" "ERROR"
                return New-CheckoutResult -Outcome AuthFailed
            }

            if (Test-TransientFailure -StatusCode $status) {
                $failures++
                Write-Log "API request failed ($status): $($response.Error)" "ERROR"
                if ($failures -ge $MaxTransientFailures) {
                    return New-CheckoutResult -Outcome Unavailable
                }

                $delay = $TransientRetrySeconds * $failures
                if ($null -ne $response.RetryAfter) {
                    $delay = Get-RetryDelay -RetryAfter $response.RetryAfter
                }
                if ($null -ne $deadline) {
                    $remaining = $deadline - (Get-MonotonicTime)
                    if ($remaining -le 0) {
                        Write-Log "No Linux host was ready within $MaxWaitSeconds seconds." "WARNING"
                        return New-CheckoutResult -Outcome TimedOut
                    }
                    $delay = [Math]::Min($delay, [Math]::Ceiling($remaining))
                }
                if (-not (Wait-CheckoutInterval -Seconds $delay -WaitWindow $waitWindow)) {
                    Write-Log "$Username cancelled the wait for a Linux host." "INFO"
                    return New-CheckoutResult -Outcome Cancelled
                }
                continue
            }

            Write-Log "The broker refused the checkout ($status): $($response.Error)" "ERROR"
            return New-CheckoutResult -Outcome Rejected
        }
    }
    finally {
        Close-WaitWindow -WaitWindow $waitWindow
        if ($client -is [System.IDisposable]) {
            $client.Dispose()
        }
    }
}

function Save-LinuxHostCredential {
    param (
        [Parameter(Mandatory = $true)]
        $Checkout,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Username
    )

    $hostname = $Checkout.Hostname
    $ipAddress = $Checkout.IPAddress

    # Store or update credentials in Credential Manager
    try {
        Write-Log "Updating Windows Credential Manager with credentials for $hostname..." "INFO"

        # Delete all existing credentials in Credential Manager
        Write-Log "Deleting all existing credentials in Credential Manager..." "INFO"

        cmdkey /list | ForEach-Object {
            if ($_ -match "Target: (.+)") {
                $target = $matches[1]
                cmdkey /delete:$target | Out-Null
                Write-Log "Deleted credential for $target" "INFO"
            }
        }

        New-StoredCredential -Target $hostname -UserName $Username -Password $Checkout.Password -Persist LocalMachine | Out-Null
        New-StoredCredential -Target $ipAddress -UserName $Username -Password $Checkout.Password -Persist LocalMachine | Out-Null

        # mstsc only reuses a saved credential whose target carries the TERMSRV/ prefix.
        New-StoredCredential -Target "TERMSRV/$ipAddress" -UserName $Username -Password $Checkout.Password -Type Generic -Persist LocalMachine | Out-Null
        New-StoredCredential -Target "TERMSRV/$hostname" -UserName $Username -Password $Checkout.Password -Type Generic -Persist LocalMachine | Out-Null

        Write-Log "Credentials for $hostname updated successfully in Credential Manager." "INFO"
    }
    catch {
        Write-Log "Failed to update credentials in Credential Manager: $_" "ERROR"
    }
}

# Returns the switches for mstsc.exe. mstsc reads anything else on its command line as another
# switch or a connection file, so the address can only be a host name or an IP address, with an
# optional port.
function Get-MstscArgumentList {
    param (
        [Parameter(Mandatory = $true)]
        [string]$IPAddress,

        [ValidateSet('On', 'Off')]
        [string]$FullScreen = 'On',

        [ValidateSet('On', 'Off')]
        [string]$MultiMonitor = 'On'
    )

    if ($IPAddress -cnotmatch '^[A-Za-z0-9][A-Za-z0-9.:-]*\z') {
        throw "The broker gave '$IPAddress' as the Linux host's address, which is not a host name or an IP address."
    }

    $arguments = @("/v:$IPAddress")
    if ($FullScreen -eq 'On') {
        $arguments += '/f'
        # A session that uses every monitor opens full screen even without /f, so a window
        # leaves /multimon out.
        if ($MultiMonitor -eq 'On') {
            $arguments += '/multimon'
        }
    }
    return $arguments
}

function Open-RemoteDesktop {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Hostname,

        [Parameter(Mandatory = $true)]
        [string]$IPAddress,

        [ValidateSet('On', 'Off')]
        [string]$FullScreen = 'On',

        [ValidateSet('On', 'Off')]
        [string]$MultiMonitor = 'On'
    )

    Write-Log "Connecting to $Hostname (IP: $IPAddress) using Remote Desktop Connection..." "INFO"
    try {
        $mstscArguments = @(Get-MstscArgumentList -IPAddress $IPAddress -FullScreen $FullScreen -MultiMonitor $MultiMonitor)

        # xrdp presents a self-signed certificate, so skip the server authentication warning for this user.
        $rdpClientKey = "HKCU:\Software\Microsoft\Terminal Server Client"
        if (-not (Test-Path $rdpClientKey)) {
            New-Item -Path $rdpClientKey -Force | Out-Null
        }
        New-ItemProperty -Path $rdpClientKey -Name "AuthenticationLevelOverride" -PropertyType DWord -Value 0 -Force | Out-Null

        Write-Log "Starting mstsc.exe $($mstscArguments -join ' ')." "INFO"
        Start-Process mstsc.exe -ArgumentList $mstscArguments -ErrorAction Stop

        Write-Log "Successfully connected to $Hostname (IP: $IPAddress) using Remote Desktop Connection." "INFO"
        return $true
    }
    catch {
        Write-Log "Failed to connect to $Hostname (IP: $IPAddress) using Remote Desktop Connection: $_" "ERROR"
        Show-UserMessage "Remote Desktop Connection could not be started for $Hostname. Try again, or contact your administrator." "Error"
        return $false
    }
}

# Returns the exit code: 0 when the desktop opened or the user cancelled, 1 otherwise.
function Invoke-ConnectLinuxBroker {
    param (
        [string]$Mode = "desktop",

        [int]$MaxWaitSeconds = 600,

        [ValidateSet('On', 'Off')]
        [string]$FullScreen = 'On',

        [ValidateSet('On', 'Off')]
        [string]$MultiMonitor = 'On',

        [Parameter(Mandatory = $true)]
        [string]$ApiBaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$Resource,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Username,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$AvdHost
    )

    # Earlier releases kept every other value for starting a single application through xpra,
    # which was never implemented and has been removed. A RemoteApp that still passes one gets the
    # desktop rather than nothing.
    if ($Mode -ine "desktop") {
        Write-Log "Mode '$Mode' is not supported, so the desktop is opened instead." "WARNING"
    }

    Write-Log "Connect-LinuxBroker.ps1 $ScriptVersion is checking out a Linux host for $Username." "INFO"
    $result = Request-LinuxHost -CheckoutUrl "$ApiBaseUrl/vms/checkout" -Resource $Resource -Username $Username -AvdHost $AvdHost -MaxWaitSeconds $MaxWaitSeconds

    if ($result.Outcome -eq "Assigned") {
        Save-LinuxHostCredential -Checkout $result.Checkout -Username $Username
        if (Open-RemoteDesktop -Hostname $result.Checkout.Hostname -IPAddress $result.Checkout.IPAddress -FullScreen $FullScreen -MultiMonitor $MultiMonitor) {
            return 0
        }
        return 1
    }

    if ($result.Outcome -eq "Cancelled") {
        return 0
    }

    $message = $OutcomeMessages[$result.Outcome]
    Show-UserMessage $message.Text $message.Icon
    return 1
}

# Dot-sourcing the script, as its tests do, defines the functions without connecting.
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = Invoke-ConnectLinuxBroker -Mode $Mode -MaxWaitSeconds $MaxWaitSeconds -FullScreen $FullScreen -MultiMonitor $MultiMonitor `
        -ApiBaseUrl $apiBaseUrl -Resource $apiAppIdUri -Username ($env:USERNAME -replace '[^a-zA-Z0-9_]', '') -AvdHost $env:COMPUTERNAME
    exit ([int]($exitCode | Select-Object -Last 1))
}
