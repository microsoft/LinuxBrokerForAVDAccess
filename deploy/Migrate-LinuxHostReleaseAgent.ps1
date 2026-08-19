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
    [string[]]$LinuxHostNames,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 300)]
    [int]$WatcherDebounceSeconds = 10,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 60)]
    [int]$WatcherSettleSeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Get-AzdEnvValue {
    param([Parameter(Mandatory = $true)][string]$Key)

    if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
        return ''
    }

    $value = azd env get-value $Key --environment $EnvironmentName 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ''
    }

    return ($value | Out-String).Trim()
}

function ConvertTo-BashSingleQuotedLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    $replacement = "'" + '"' + "'" + '"' + "'"

    return "'" + ($Value -replace "'", $replacement) + "'"
}

function Invoke-RunCommandWithRetry {
    param(
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

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $message = az vm run-command invoke `
            --resource-group $ResourceGroupName `
            --name $VmName `
            --command-id RunShellScript `
            --scripts $Script `
            --query 'value[0].message' `
            --output tsv `
            --only-show-errors 2>&1 | Out-String

        if ($LASTEXITCODE -eq 0) {
            return $message.Trim()
        }

        $lastError = $message.Trim()
        if ($attempt -ge $MaxAttempts) {
            break
        }

        $delaySeconds = [Math]::Min($InitialDelaySeconds * [Math]::Pow(2, $attempt - 1), 30)
        Write-Warning "Linux host migration failed on '$VmName' attempt $attempt of $MaxAttempts. Retrying in $([int]$delaySeconds) seconds."
        if (-not [string]::IsNullOrWhiteSpace($lastError)) {
            Write-Warning $lastError
        }

        Start-Sleep -Seconds ([int]$delaySeconds)
    }

    if ([string]::IsNullOrWhiteSpace($lastError)) {
        throw "Linux host migration failed on '$VmName'."
    }

    throw "Linux host migration failed on '$VmName'. Last error: $lastError"
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $ResourceGroupName = Get-AzdEnvValue -Key 'resourceGroupName'
}

if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $SubscriptionId = Get-AzdEnvValue -Key 'AZURE_SUBSCRIPTION_ID'
}

if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $SubscriptionId = $env:AZURE_SUBSCRIPTION_ID
}

if ([string]::IsNullOrWhiteSpace($ApiBaseUrl)) {
    $ApiBaseUrl = Get-AzdEnvValue -Key 'apiUrl'
}

if ([string]::IsNullOrWhiteSpace($ApiClientId)) {
    $ApiClientId = Get-AzdEnvValue -Key 'apiClientId'
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName) -or [string]::IsNullOrWhiteSpace($ApiBaseUrl) -or [string]::IsNullOrWhiteSpace($ApiClientId)) {
    throw 'Linux host migration inputs could not be fully resolved from parameters or azd environment values.'
}

$ScriptSourceRoot = $ScriptSourceRoot.TrimEnd('/')

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    az account set --subscription $SubscriptionId | Out-Null
}

$linuxHosts = az vm list --resource-group $ResourceGroupName --show-details --output json | ConvertFrom-Json |
    Where-Object { $_.tags.'broker-role' -eq 'linux-host' }

if (-not $linuxHosts) {
    Write-Host "No Linux host VMs found in resource group '$ResourceGroupName'."
    exit 0
}

if ($LinuxHostNames -and $LinuxHostNames.Count -gt 0) {
    $requestedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $LinuxHostNames) {
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            [void]$requestedNames.Add($name)
        }
    }

    $filteredHosts = @($linuxHosts | Where-Object { $requestedNames.Contains($_.name) })
    foreach ($name in $requestedNames) {
        if (-not ($filteredHosts | Where-Object { $_.name -eq $name })) {
            Write-Warning "Requested Linux host '$name' was not found in resource group '$ResourceGroupName'."
        }
    }

    $linuxHosts = $filteredHosts
}

if (-not $linuxHosts) {
    Write-Host 'No Linux hosts matched the requested migration scope.'
    exit 0
}

$remoteScript = @'
set -euo pipefail

api_base_url=__API_BASE_URL__
api_client_id=__API_CLIENT_ID__
script_source_root=__SCRIPT_SOURCE_ROOT__
watcher_debounce_seconds='__WATCHER_DEBOUNCE__'
watcher_settle_seconds='__WATCHER_SETTLE__'

state_directory='/var/lib/linuxbroker-release-session'
output_directory='/usr/local/bin'
release_script="$output_directory/release-session.sh"
watcher_script="$output_directory/logind-session-watcher.sh"
xorg_script="$output_directory/xrdp-who-xorg.sh"
create_user_script="$output_directory/create-user.sh"
manage_lease_script="$output_directory/manage-lease.sh"
release_service_name='linuxbroker-release-session.service'
release_timer_name='linuxbroker-release-session.timer'
watcher_service_name='linuxbroker-release-session-watcher.service'
release_service_path="/etc/systemd/system/$release_service_name"
release_timer_path="/etc/systemd/system/$release_timer_name"
watcher_service_path="/etc/systemd/system/$watcher_service_name"
log_file='/var/log/release-session.log'
current_users_file="$state_directory/current_users.txt"
previous_users_file="$state_directory/previous_users.txt"
disconnected_users_file="$state_directory/disconnected_users.tsv"
sudoers_path='/etc/sudoers.d/avdadmin'

ensure_command() {
    local binary="$1"
    local package_name="$2"

    if command -v "$binary" >/dev/null 2>&1; then
        return 0
    fi

    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y "$package_name"
        return 0
    fi

    if command -v dnf >/dev/null 2>&1; then
        dnf install -y "$package_name"
        return 0
    fi

    if command -v yum >/dev/null 2>&1; then
        yum install -y "$package_name"
        return 0
    fi

    echo "Unable to install required command '$binary'."
    return 1
}

download_file() {
    local url="$1"
    local destination="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$destination"
        return 0
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -qO "$destination" "$url"
        return 0
    fi

    echo 'Neither curl nor wget is available for downloads.'
    return 1
}

ensure_command curl curl
ensure_command jq jq

if [ -r /etc/os-release ]; then
    . /etc/os-release
else
    echo 'Missing /etc/os-release. Unable to determine Linux distribution.'
    exit 1
fi

release_variant='RHEL'
case "${ID:-}" in
    ubuntu|debian)
        release_variant='Ubuntu'
        ;;
    rhel|almalinux|centos|rocky)
        release_variant='RHEL'
        ;;
    *)
        if [[ "${ID_LIKE:-}" == *'debian'* ]]; then
            release_variant='Ubuntu'
        fi
        ;;
esac

release_script_url="$script_source_root/linux_host/session_release_buffer/${release_variant}/release-session.sh"
xorg_script_url="$script_source_root/linux_host/session_release_buffer/xrdp-who-xorg.sh"
watcher_script_url="$script_source_root/linux_host/session_release_buffer/logind-session-watcher.sh"
create_user_script_url="$script_source_root/linux_host/create-user.sh"
manage_lease_script_url="$script_source_root/linux_host/manage-lease.sh"

mkdir -p "$output_directory" "$state_directory" "$state_directory/leases"

download_file "$release_script_url" "$release_script"
download_file "$xorg_script_url" "$xorg_script"
download_file "$watcher_script_url" "$watcher_script"
download_file "$create_user_script_url" "$create_user_script"
download_file "$manage_lease_script_url" "$manage_lease_script"

chmod +x "$release_script" "$xorg_script" "$watcher_script" "$create_user_script" "$manage_lease_script"

sed -i "s|YOUR_LINUX_BROKER_API_CLIENT_ID|$api_client_id|g" "$release_script"
sed -i "s|YOUR_LINUX_BROKER_API_BASE_URL|$api_base_url|g" "$release_script"
sed -i "s|YOUR_LINUX_BROKER_API_URL|$api_base_url|g" "$release_script"

touch "$log_file" "$current_users_file" "$previous_users_file" "$disconnected_users_file"
chmod 600 "$log_file" "$current_users_file" "$previous_users_file" "$disconnected_users_file"

if ! id avdadmin >/dev/null 2>&1; then
    useradd avdadmin
fi

# Only the commands the broker API actually invokes with sudo. Privileged file work
# (mount, chown, chmod, lease markers) happens inside the two allowlisted scripts.
sudoers_commands=()
for command_name in userdel groupadd usermod chpasswd; do
    resolved_command=$(command -v "$command_name" || true)
    if [ -n "$resolved_command" ]; then
        sudoers_commands+=("$resolved_command")
    fi
done
sudoers_commands+=("$create_user_script" "$manage_lease_script")

sudoers_tmp="${sudoers_path}.tmp"
(
    IFS=,
    printf 'avdadmin ALL=(ALL) NOPASSWD: %s\n' "${sudoers_commands[*]}" > "$sudoers_tmp"
)
chmod 440 "$sudoers_tmp"
if visudo -c -f "$sudoers_tmp" >/dev/null 2>&1; then
    mv "$sudoers_tmp" "$sudoers_path"
else
    rm -f "$sudoers_tmp"
    echo 'Generated sudoers policy failed validation.'
    exit 1
fi

if command -v crontab >/dev/null 2>&1; then
    tmp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v -F "$release_script" > "$tmp_cron" || true
    if [ -s "$tmp_cron" ]; then
        crontab "$tmp_cron"
    else
        crontab -r 2>/dev/null || true
    fi
    rm -f "$tmp_cron"
fi

if command -v pkill >/dev/null 2>&1; then
    pkill -f "$release_script" || true
fi

cat <<EOF > "$release_service_path"
[Unit]
Description=Linux Broker Release Agent
After=network-online.target xrdp.service
Wants=network-online.target
ConditionPathExists=$release_script

[Service]
Type=oneshot
User=root
WorkingDirectory=$state_directory
ExecStart=$release_script --systemd-timer
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF > "$release_timer_path"
[Unit]
Description=Run Linux Broker Release Agent every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=1s
Persistent=true
Unit=$release_service_name

[Install]
WantedBy=timers.target
EOF

cat <<EOF > "$watcher_service_path"
[Unit]
Description=Linux Broker logind Session Watcher
After=network-online.target systemd-logind.service
Wants=network-online.target
ConditionPathExists=$watcher_script

[Service]
Type=simple
User=root
WorkingDirectory=$state_directory
Environment=LINUXBROKER_LOGIND_WATCHER_DEBOUNCE_SECONDS=$watcher_debounce_seconds
Environment=LINUXBROKER_LOGIND_WATCHER_SETTLE_SECONDS=$watcher_settle_seconds
ExecStart=$watcher_script
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl disable --now "$watcher_service_name" >/dev/null 2>&1 || true
systemctl disable --now "$release_timer_name" >/dev/null 2>&1 || true
systemctl disable --now "$release_service_name" >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl reset-failed "$release_service_name" >/dev/null 2>&1 || true
systemctl reset-failed "$watcher_service_name" >/dev/null 2>&1 || true
systemctl enable --now "$release_timer_name"
systemctl enable --now "$watcher_service_name"
systemctl start "$release_service_name"

printf 'Migrated release agent on %s\n' "$(hostname)"
printf 'Release service: %s\n' "$(systemctl is-active "$release_service_name" || true)"
printf 'Release timer: %s / %s\n' "$(systemctl is-enabled "$release_timer_name" || true)" "$(systemctl is-active "$release_timer_name" || true)"
printf 'Watcher service: %s / %s\n' "$(systemctl is-enabled "$watcher_service_name" || true)" "$(systemctl is-active "$watcher_service_name" || true)"
'@

$remoteScript = $remoteScript.Replace('__API_BASE_URL__', (ConvertTo-BashSingleQuotedLiteral -Value $ApiBaseUrl))
$remoteScript = $remoteScript.Replace('__API_CLIENT_ID__', (ConvertTo-BashSingleQuotedLiteral -Value $ApiClientId))
$remoteScript = $remoteScript.Replace('__SCRIPT_SOURCE_ROOT__', (ConvertTo-BashSingleQuotedLiteral -Value $ScriptSourceRoot))
$remoteScript = $remoteScript.Replace('__WATCHER_DEBOUNCE__', $WatcherDebounceSeconds.ToString())
$remoteScript = $remoteScript.Replace('__WATCHER_SETTLE__', $WatcherSettleSeconds.ToString())

foreach ($linuxHost in $linuxHosts) {
    Write-Host "Migrating Linux host '$($linuxHost.name)'..."
    $message = Invoke-RunCommandWithRetry -VmName $linuxHost.name -Script $remoteScript
    if (-not [string]::IsNullOrWhiteSpace($message)) {
        Write-Host $message
    }
}