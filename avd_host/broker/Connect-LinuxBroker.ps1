$ProgressPreference = 'SilentlyContinue'

$localHostname = $env:COMPUTERNAME
$localUsername = $env:USERNAME

$apiBaseUrl = "https://linuxbroker-api2.azurewebsites.net/api"
$checkoutVmUrl = "$apiBaseUrl/vms/checkout"

$maxAttempts = 3
$attemptCount = 0
$hasExistingCheckedInVM = $false

$sourceName = "LinuxBrokerScript"
$logName = "Application"

function Write-Log {
    param (
        [string]$Message,
        [ValidateSet("INFO", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    try {
        Write-Host "[$timestamp][$Level] $Message"
        Write-EventLog -LogName $logName -Source $sourceName -EntryType $Level -EventId 1 -Message $Message
    }
    catch {
        Write-Host "Failed to write to event log: $_"
    }
}

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

function Set-StoredCredential {
    param (
        [string]$Target,
        [string]$Username,
        [SecureString]$SecurePassword
    )

    try {
        $password = [Runtime.InteropServices.Marshal]::PtrToStringUni(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
        )
        Write-Log "Updating Windows Credential Manager with credentials for $Target..." "INFO"
        start-sleep -s 5
        New-StoredCredential -Target $Target -UserName $Username -Password $password | Out-Null
        Write-Host "Trying cmdkey"
        cmdkey /generic:$Target /user:$Username /pass:$password

        Write-Log "Credentials for $Target updated successfully in Credential Manager." "INFO"
    }
    catch {
        Write-Log "Failed to update credentials in Credential Manager: $_" "ERROR"
    }
}

function Remove-AllCredentials {
    cmdkey /list | ForEach-Object {
        if($_ -match "Target: (.*)"){
            cmdkey /delete $matches[1]
        }
    }
}

$apiAppIdUri = "api://4c1b2eb9-92bd-49c4-bee2-c007f1908d96"

$accessToken = Get-AccessToken -Resource $apiAppIdUri

if (-not $accessToken) {
    Write-Log "Unable to obtain access token. Exiting script." "ERROR"
    exit 1
}

$authHeader = @{
    "Authorization" = "Bearer $accessToken"
}

while ($attemptCount -lt $maxAttempts) {
    $attemptCount++
    Write-Log "Attempt $attemptCount of $maxAttempts Checking for an available or already checked-out VM..." "INFO"

    try {
        $checkoutPayload = @{
            "username" = $localUsername
            "avdhost"  = $localHostname
        }

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

if ($hasExistingCheckedInVM -and $checkoutResponse.IPAddress) {
    $hostname = $checkoutResponse.Hostname
    $ipAddress = $checkoutResponse.IPAddress
    $securePassword = ConvertTo-SecureString $checkoutResponse.password -AsPlainText -Force

    try {
        Write-Log "Updating Windows Credential Manager with credentials for $hostname..." "INFO"
        Remove-AllCredentials
        Set-StoredCredential -Target $hostname -Username $localUsername -SecurePassword $securePassword
        Set-StoredCredential -Target $ipAddress -Username $localUsername -SecurePassword $securePassword

        Write-Log "Credentials for $hostname updated successfully in Credential Manager." "INFO"
    }
    catch {
        Write-Log "Failed to update credentials in Credential Manager: $_" "ERROR"
    }

    Write-Log "Connecting to $hostname (IP: $ipAddress) using Remote Desktop Connection..." "INFO"
    try {
        Start-Process mstsc.exe -ArgumentList "/v:$hostname"

        Write-Log "Successfully connected to $hostname (IP: $ipAddress) using Remote Desktop Connection." "INFO"
    }
    catch {
        Write-Log "Failed to connect to $hostname (IP: $ipAddress) using Remote Desktop Connection: $_" "ERROR"
    }
}
else {
    Write-Log "No available or checked-out VM found. Exiting script." "WARNING"
}
