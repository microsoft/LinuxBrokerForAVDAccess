# Installs and configures the necessary packages for Linux Broker for AVD Access on the AVD host
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "The base URL for the Linux Broker API, e.g. https://your-broker.domain.com/api")]
    [ValidateNotNullOrEmpty()]
    [string]$LinuxBrokerApiBaseUrl
)

$sourceName = "LinuxBrokerScript"
$logName = "Application"
$moduleName = "SqlServer"
# URL of the script to download
$url = "https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/refs/heads/main/avd_host/broker/Connect-LinuxBroker.ps1"

# Function to write logs to console and event log
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$Level = 'Information'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    switch ($Level) {
        'Information' { Write-Host $logMessage -ForegroundColor Cyan }
        'Warning' { Write-Host $logMessage -ForegroundColor Yellow }
        'Error' { Write-Host $logMessage -ForegroundColor Red }
    }
    
    if ([System.Diagnostics.EventLog]::SourceExists($sourceName)) {
        $eventType = switch ($Level) {
            'Information' { [System.Diagnostics.EventLogEntryType]::Information }
            'Warning' { [System.Diagnostics.EventLogEntryType]::Warning }
            'Error' { [System.Diagnostics.EventLogEntryType]::Error }
        }
        
        try {
            Write-EventLog -LogName $logName -Source $sourceName -EventId 1000 -EntryType $eventType -Message $logMessage
        }
        catch {
            Write-Host "Failed to write to event log: $_" -ForegroundColor Red
        }
    }
}

# Create event log source if it doesn't exist
if (-not [System.Diagnostics.EventLog]::SourceExists($sourceName)) {
    try {
        New-EventLog -LogName $logName -Source $sourceName -ErrorAction Stop
        Write-Log "Event source '$sourceName' created successfully."
    }
    catch {
        Write-Host "Failed to create event source '$sourceName': $_" -ForegroundColor Red
        exit 1
    }
}
else {
    Write-Log "Event source '$sourceName' already exists."
}

# Ensure NuGet provider is installed
Write-Log "Checking for NuGet provider..."
if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue | 
        Where-Object { $_.Version -ge [Version]"2.8.5.201" })) {
    try {
        Write-Log "NuGet provider not found or outdated. Installing NuGet provider..."
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
        Write-Log "NuGet provider installed successfully."
    }
    catch {
        Write-Log "Failed to install NuGet provider. Error: $_" -Level Error
        exit 1
    }
}
else {
    Write-Log "NuGet provider is already installed and up-to-date."
}

# Set PSGallery as trusted
if ((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') {
    try {
        Write-Log "Setting PSGallery as a trusted repository..."
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Write-Log "PSGallery set as trusted successfully."
    }
    catch {
        Write-Log "Failed to set PSGallery as trusted. Error: $_" -Level Warning
        # Continue execution, as this is not critical
    }
}

# Validate the LinuxBrokerApiBaseUrl parameter
if (-not $LinuxBrokerApiBaseUrl.StartsWith("https://")) {
    Write-Log "LinuxBrokerApiBaseUrl must start with https://" -Level Error
    exit 1
}

# Check if the folder exists, if not, create it
$folderPath = "C:\Temp"
if (-Not (Test-Path -Path $folderPath)) {
    try {
        New-Item -Path $folderPath -ItemType Directory -Force | Out-Null
        Write-Log "Folder $folderPath created successfully."
    }
    catch {
        Write-Log "Failed to create folder $folderPath. Error: $_" -Level Error
        exit 1
    }
}
else {
    Write-Log "Folder $folderPath already exists."
}

# Output path for the downloaded script
$outputPath = "$folderPath\Connect-LinuxBroker.ps1"

# Check if the CredentialManager module is installed, if not, install it
try {
    if (-not (Get-Module -ListAvailable -Name CredentialManager)) {
        Write-Log "CredentialManager module is not installed. Attempting to install..."
        Install-Module -Name CredentialManager -Force -ErrorAction Stop
        Write-Log "CredentialManager module installed successfully."
    }
    else {
        Write-Log "CredentialManager module is already installed."
    }
}
catch {
    Write-Log "Failed to install CredentialManager module. Error: $_" -Level Error
    exit 1
}

# Check if the CredentialManager module is already imported, if not, import it
try {
    if (-not (Get-Module -Name CredentialManager)) {
        Write-Log "Importing CredentialManager module..."
        Import-Module CredentialManager -Force -ErrorAction Stop
        Write-Log "CredentialManager module imported successfully."
    }
    else {
        Write-Log "CredentialManager module is already imported."
    }
}
catch {
    Write-Log "Failed to import CredentialManager module. Error: $_" -Level Error
    exit 1
}

# Download the script using Invoke-WebRequest with retry logic
$maxRetries = 3
$retryCount = 0
$success = $false

while (-not $success -and $retryCount -lt $maxRetries) {
    try {
        Write-Log "Downloading script from $url to $outputPath"
        Invoke-WebRequest -Uri $url -OutFile $outputPath -UseBasicParsing -ErrorAction Stop
        $success = $true
        Write-Log "Script downloaded successfully to $outputPath"

        # Unblock the downloaded file to clear the "Mark of the Web"
        Unblock-File -Path $outputPath -ErrorAction Stop
        Write-Log "The downloaded script has been unblocked successfully."
    }
    catch {
        $retryCount++
        Write-Log "Attempt $retryCount of $maxRetries failed: $_" -Level Warning
        if ($retryCount -lt $maxRetries) {
            Start-Sleep -Seconds (2 * $retryCount)
        }
        else {
            Write-Log "Failed to download script after $maxRetries attempts" -Level Error
            exit 1
        }
    }
}

# Modify the API base URL in the script
try {
    Write-Log "Updating API Base URL in script to: $LinuxBrokerApiBaseUrl"
    [System.IO.File]::WriteAllText($outputPath, ([System.IO.File]::ReadAllText($outputPath) -replace 'https://your_linuxbroker_api_base_url/api', $LinuxBrokerApiBaseUrl))
    Write-Log "Updated API Base URL in $outputPath successfully."
}
catch {
    Write-Log "Failed to update API Base URL. Error: $_" -Level Error
    exit 1
}

# Check if Azure CLI is already installed before downloading
if (Get-Command az -ErrorAction SilentlyContinue) {
    Write-Log "Azure CLI is already installed."
}
else {
    try {
        Write-Log "Downloading Azure CLI installer..."
        Invoke-WebRequest -Uri https://aka.ms/installazurecliwindowsx64 -OutFile .\AzureCLI.msi -ErrorAction Stop
        
        Write-Log "Installing Azure CLI..."
        $process = Start-Process msiexec.exe -ArgumentList '/I AzureCLI.msi /quiet' -Wait -PassThru -ErrorAction Stop
        if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
            throw "Azure CLI installation failed with exit code: $($process.ExitCode)"
        }
        
        Write-Log "Cleaning up installer..."
        Remove-Item .\AzureCLI.msi -ErrorAction Stop
        
        Write-Log "Azure CLI installed successfully. Refreshing environment variables..."
        
        # Refresh environment PATH to make the 'az' command available in current session
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        
        Start-Sleep -Seconds 5
    }
    catch {
        Write-Log "Failed during Azure CLI installation process: $_" -Level Error
    }
}

# Verify Azure CLI is available
if (!(Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Log "Azure CLI is not available in PATH. Checking for installation..." -Level Warning
    
    # Look for Azure CLI in typical installation locations
    $azPath = $null
    $possiblePaths = @(
        "${env:ProgramFiles}\Azure CLI\wbin\",
        "${env:ProgramFiles(x86)}\Azure CLI\wbin\",
        "${env:ProgramFiles}\Microsoft SDKs\Azure\CLI2\wbin\"
    )
    
    foreach ($path in $possiblePaths) {
        if (Test-Path "$path\az.cmd") {
            $azPath = $path
            Write-Log "Found Azure CLI at: $azPath"
            break
        }
    }
    
    if ($azPath) {
        # Add to current session PATH
        $env:Path += ";$azPath"
        Write-Log "Added Azure CLI location to PATH for current session."
    }
    else {
        Write-Log "Azure CLI installation not found. SSH extension cannot be installed." -Level Error
    }
}

# Install Azure CLI SSH extension
try {
    Write-Log "Installing Azure CLI SSH extension..."
    $result = (az extension add --name ssh) 2>&1
    Write-Log "Azure CLI SSH extension installed successfully."
}
catch {
    Write-Log "Failed to install the SSH extension: $_" -Level Error
}

# Install SqlServer module if not already installed
if (-not (Get-Module -ListAvailable -Name $moduleName)) {
    Write-Log "SqlServer module is not installed. Attempting to install..."
    
    try {
        Import-Module PowerShellGet -ErrorAction Stop
        Write-Log "PowerShellGet module has been loaded."
        Install-Module -Name $moduleName -Scope CurrentUser -AllowClobber -Force -ErrorAction Stop
        Import-Module $moduleName -ErrorAction Stop
        Write-Log "SqlServer module has been successfully installed and imported."
    }
    catch {
        Write-Log "Failed to install the SqlServer module: $_" -Level Error
    }
}
else {
    Write-Log "SqlServer module is already installed."
}

# Set registry key for RDP authentication level
try {
    Write-Log "Setting RDP authentication level registry key..."
    reg add "HKEY_CURRENT_USER\Software\Microsoft\Terminal Server Client" /v "AuthenticationLevelOverride" /t "REG_DWORD" /d 0 /f | Out-Null
    Write-Log "Successfully set the AuthenticationLevelOverride registry key."
}
catch {
    Write-Log "Failed to set the AuthenticationLevelOverride registry key: $_" -Level Error
}

Write-Log "Configuration complete! Linux Broker API Base URL set to: $LinuxBrokerApiBaseUrl"