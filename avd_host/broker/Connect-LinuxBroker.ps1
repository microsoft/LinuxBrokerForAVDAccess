param (
    [Parameter(Mandatory = $false, HelpMessage = "Specify 'desktop' to use Remote Desktop, or provide the name of the application to run via xrpa.")]
    [string]$Mode = "desktop"
)

$ProgressPreference = 'SilentlyContinue'

# Automatically collect local Windows hostname and username
$localHostname = $env:COMPUTERNAME
$localUsername = $env:USERNAME

# Define the API endpoints
$apiBaseUrl = "https://your_linuxbroker_api_base_url/api"
$checkoutVmUrl = "$apiBaseUrl/vms/checkout"

# Define the maximum number of update attempts
$maxAttempts = 3
$attemptCount = 0
$hasExistingCheckedInVM = $false

$sourceName = "LinuxBrokerScript" # The source name for your event log.
$logName = "Application" # The log where your source will write events. Commonly "Application".

function Write-Log {
    param (
        [string]$Message,
        [ValidateSet("INFO", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )
    
    try {
        #$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        #Write-Host "[$timestamp][$Level] $Message"
        Write-EventLog -LogName $logName -Source $sourceName -EntryType $Level -EventId 1 -Message $Message
    }
    catch {
        #Write-Host "Failed to write to event log: $_"
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

# Define the API's Application ID URI (use the updated valid URL)
$apiAppIdUri = "api://your_linuxbroker_api_client_id"  # Replace with your API's actual Application ID URI

# Obtain the access token using Managed Identity
$accessToken = Get-AccessToken -Resource $apiAppIdUri

if (-not $accessToken) {
    Write-Log "Unable to obtain access token. Exiting script." "ERROR"
    exit 1
}

# Prepare the Authorization header
$authHeader = @{
    "Authorization" = "Bearer $accessToken"
}

# Attempt to get an available VM or a checked-out VM
while ($attemptCount -lt $maxAttempts) {
    $attemptCount++
    Write-Log "Attempt $attemptCount of $maxAttempts Checking for an available or already checked-out VM..." "INFO"

    try {
        # Prepare the payload
        $checkoutPayload = @{
            "username" = $localUsername
            "avdhost"  = $localHostname
        }

        # Invoke the API to checkout a VM with authentication
        Write-Log "Attempting to checkout a VM via API with Managed Identity authentication..." "INFO"
        $checkoutResponse = Invoke-RestMethod -Uri $checkoutVmUrl -Method POST `
            -ContentType "application/json" `
            -Body ($checkoutPayload | ConvertTo-Json) `
            -Headers $authHeader
        
        if ($checkoutResponse.VMID) {
            $hasExistingCheckedInVM = $true
            Write-Log "Successfully checked out or retrieved an existing VM (VMID: $($checkoutResponse.VMID), Hostname: $($checkoutResponse.Hostname))." "INFO"
            break
        }
        else {
            Write-Log "Failed to retrieve VM information from API response." "WARNING"
        }
    }
    catch {
        Write-Log "API request failed: $_" "ERROR"
    }
}

# If a VM was checked out or found, connect to it
if ($hasExistingCheckedInVM -and $checkoutResponse.IPAddress) {
    $hostname = $checkoutResponse.Hostname
    $ipAddress = $checkoutResponse.IPAddress

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

        New-StoredCredential -Target $hostname -UserName $localUsername -Password $checkoutResponse.password -Persist LocalMachine | Out-Null
        New-StoredCredential -Target $ipAddress -UserName $localUsername -Password $checkoutResponse.password -Persist LocalMachine | Out-Null

        Write-Log "Credentials for $hostname updated successfully in Credential Manager." "INFO"
    }
    catch {
        Write-Log "Failed to update credentials in Credential Manager: $_" "ERROR"
    }

    if ($Mode -ieq "desktop") {
        Write-Log "Connecting to $hostname (IP: $ipAddress) using Remote Desktop Connection..." "INFO"
        try {
            # Launch mstsc with the hostname or IP address
            Start-Process mstsc.exe -ArgumentList "/v:$ipAddress"

            Write-Log "Successfully connected to $hostname (IP: $ipAddress) using Remote Desktop Connection." "INFO"
        }
        catch {
            Write-Log "Failed to connect to $hostname (IP: $ipAddress) using Remote Desktop Connection: $_" "ERROR"
        }
    }
    else {
        Write-Log "Running xrpa command to launch application: $Mode" "INFO"
        try {
            # Add XRPA command
        }
        catch {
            Write-Log "Failed to launch application '$Mode' using xrpa: $_" "ERROR"
        }
    }
}
else {
    Write-Log "No available or checked-out VM found. Exiting script." "WARNING"
}
